#!/usr/bin/env python3
"""Real-runner startup diagnostics; no network, time-based performance assertions or host writes."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import nullcontext

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent.parent
RUNNER = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else PLUGIN / 'tests/run-all.sh'
ORCHESTRATOR = PLUGIN / 'scripts/lib/multi-agent-prepare.sh'
GIT_HELPER = PLUGIN / 'tests/lib/git-fixture.sh'


def require(condition, description):
    if not condition:
        raise AssertionError(description)
    print('✓ ' + description, flush=True)


def function(source, name):
    matches = re.findall(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}\n', source, re.M | re.S)
    if len(matches) != 1:
        raise AssertionError(f'function missing/ambiguous: {name}')
    return matches[0]


for target in [RUNNER, ORCHESTRATOR, GIT_HELPER]:
    if not target.is_file() or not target.read_bytes():
        raise AssertionError(f'source missing/empty: {target}')
source = RUNNER.read_text()
original = ORCHESTRATOR.read_text()
mapping = {'load_gate_sysctl': 'ff_startup_sysctl', 'measure_load_average': 'ff_startup_measure_load',
           'measure_cpu_cores': 'ff_startup_measure_cores', 'FF_MULTI_AGENT_LOAD_SAMPLE': 'FF_RUN_ALL_LOAD_SAMPLE'}
for name in ['load_gate_sysctl', 'measure_load_average', 'measure_cpu_cores']:
    expected = function(original, name)
    for old, new in mapping.items():
        expected = expected.replace(old, new)
    require(expected == function(source, mapping[name]), '既存方式と同一: ' + name)
require(re.search(r'^LOAD_GATE_DEFAULT_PER_CORE=10$', original, re.M) is not None
        and re.search(r'^FF_STARTUP_LOAD_PER_CORE=10$', source, re.M) is not None,
        '閾値係数は既存と同じ10')
detector = function(source, 'ff_startup_other_gates')

env = dict(os.environ)
for key in list(env):
    if key.startswith(('FF_RUN_ALL_', 'FF_TEST_', 'FF_DEV_TOOLKIT_', 'GIT_')) or key in [
            'BASH_ENV', 'CLAUDE_PLUGIN_ROOT', 'GROK_PLUGIN_ROOT', 'MULTI_AGENT_CONFIG', 'FF_MULTI_AGENT_LOAD_SAMPLE', 'ENV']:
        env.pop(key, None)
env['LC_ALL'] = 'C'
env['TZ'] = 'UTC0'

prepared_root = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
temporary = nullcontext(str(prepared_root)) if prepared_root else tempfile.TemporaryDirectory(prefix='ff-startup-load.')
with temporary as temp:
    root = Path(temp).resolve()
    probe = root / 'probe/tests/run-all.sh'
    probe.parent.mkdir(parents=True)
    probe.write_text(source)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    getconf = bin_dir / 'getconf'
    getconf.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "${FF_TEST_CORES:-2}"\n')
    getconf.chmod(0o755)
    for name in ['nproc', 'sysctl']:
        path = bin_dir / name
        path.write_text('#!/usr/bin/env bash\nexit 1\n')
        path.chmod(0o755)
    # Keep the whole process tree for ancestry, hiding only unrelated host gates.
    # Every real candidate inside this fixture remains visible in fixture mode.
    bash_env = root / 'isolate.sh'
    bash_env.write_text(r'''ps() {
  if [ "$*" = '-ww -eo pid=,ppid=,args=' ]; then
    [ "${FF_TEST_PROCESS_MODE:-clean}" != fail ] || return 1
    if [ "${FF_TEST_PROCESS_MODE:-clean}" = clean ]; then
      printf '%s %s bash fixture-probe.sh\n' "$$" "$PPID"
      return 0
    fi
    command ps "$@" | awk -v self="$$" -v root="$FF_TEST_GATE_ROOT" -v visible="${TEST_VISIBLE_PID:-}" -v mode="${FF_TEST_PROCESS_MODE:-clean}" '
      $1 != self && $1 != visible && index($0,"run-all.sh") && (mode=="clean" || !index($0,root)) { print $1, $2, "fixture-hidden-command"; next }
      { print }
    '
  else command ps "$@"; fi
}
''')
    base = dict(env, PATH=str(bin_dir) + ':' + env.get('PATH', '/usr/bin:/bin'),
                BASH_ENV=str(bash_env), FF_TEST_GATE_ROOT=str(root), FF_RUN_ALL_LOAD_SAMPLE='0')
    cases = root / 'cases'
    for label, rc in [('pass', 0), ('fail', 7)]:
        script = cases / label / 'verify.sh'
        script.parent.mkdir(parents=True)
        script.write_text(f'#!/usr/bin/env bash\nprintf "FIXTURE-{label.upper()}\\n"\nexit {rc}\n')
        script.chmod(0o755)

    def run(label='pass', load='0', cores='2', process='clean', runner=probe, extra=None):
        run_env = dict(base, FF_RUN_ALL_LOAD_SAMPLE=load, FF_TEST_CORES=cores,
                       FF_TEST_PROCESS_MODE=process)
        if extra:
            run_env.update(extra)
        result = subprocess.run(['bash', str(runner), str(cases / label / 'verify.sh')],
                                env=run_env, text=True, capture_output=True, timeout=30)
        require(result.returncode == (0 if label == 'pass' else 1),
                f'{label}/{load}/{cores}/{process}: 終了コードを維持')
        require('suites: total=1 run=1 ' in result.stdout, '実suiteを1件実行しsummaryへ到達')
        return result

    for label in ['pass', 'fail']:
        low = run(label)
        require('startup-load:' not in low.stdout and '起動時の負荷:' not in low.stderr
                and '単体で再実行して切り分け' not in low.stdout, '通常時は追加出力なし: ' + label)
        high = run(label, load='20.01')
        require('起動時の負荷: load average 20.01; 閾値 20（2 コア × 10）; 他ゲート none' in high.stderr
                and high.stderr.count('起動時の負荷:') == 1, '高負荷を開始時stderrへ1回警告: ' + label)
        require('startup-load: load=20.01 cores=2 threshold=20 other-gates=none' in high.stdout,
                '起動時の測定値をsummaryへ残す: ' + label)
        require(('単体で再実行して切り分け' in high.stdout) == (label == 'fail'),
                '実測高負荷かつ失敗時だけ再実行案内: ' + label)
        unknown = run(label, load='not-a-number')
        require('startup-load: load=unknown cores=2 threshold=20 other-gates=none' in unknown.stdout
                and '起動時の負荷:' not in unknown.stderr
                and '単体で再実行して切り分け' not in unknown.stdout,
                'load取得不能を正常や高負荷へ置換しない: ' + label)
        proc_unknown = run(label, process='fail')
        require('other-gates=unknown' in proc_unknown.stdout and '起動時の負荷:' not in proc_unknown.stderr
                and '単体で再実行して切り分け' not in proc_unknown.stdout,
                'プロセス取得不能を他ゲート0へ置換しない: ' + label)
    equal = run(load='20')
    require('startup-load:' not in equal.stdout and '起動時の負荷:' not in equal.stderr, '閾値と等値は通常')
    cores_unknown = run(cores='invalid')
    require('load=0 cores=unknown threshold=unknown' in cores_unknown.stdout, 'コア不明を4へ補完しない')
    huge_cores = run(cores='999999999999999999999999')
    require('cores=unknown threshold=unknown' in huge_cores.stdout, '巨大なコア応答で算術を壊さない')
    comparison_error = subprocess.run(['bash', '-c', function(source, 'ff_capture_startup_load') + r'''
FF_STARTUP_LOAD_PER_CORE=10
ff_startup_measure_load() { echo 0; }
ff_startup_measure_cores() { echo 2; }
ff_startup_other_gates() { return 0; }
awk() { return 2; }
ff_capture_startup_load
printf '%s %s\n' "$FF_STARTUP_LOAD" "$FF_STARTUP_REPORT"
'''], env=env, text=True, capture_output=True, timeout=10)
    require(comparison_error.returncode == 0 and comparison_error.stdout.strip() == 'unknown 1',
            '比較器の異常も正常負荷へ倒さずゲートを止めない')

    # Test the selector with the actual production function and a living unrelated
    # PID, so a broadened name-match mutation cannot hide behind a dead-PID check.
    sleeper = subprocess.Popen(['sleep', '60'], env=env)
    try:
        synthetic = r'''
ps() {
  if [ "$*" = '-ww -eo pid=,ppid=,args=' ]; then
    case "$TEST_GRAPH" in
      ancestor) printf '%s %s bash probe.sh\n' "$$" "$TEST_PID"; printf '%s 1 %s\n' "$TEST_PID" "$TEST_COMMAND" ;;
      descendant) printf '%s 1 bash probe.sh\n' "$$"; printf '%s %s %s\n' "$TEST_PID" "$$" "$TEST_COMMAND" ;;
      sibling) printf '10 1 bash /outer/run-all.sh\n20 10 bash suite.sh\n%s 20 bash probe.sh\n30 10 bash suite.sh\n%s 30 %s\n' "$$" "$TEST_PID" "$TEST_COMMAND" ;;
      missing) printf '1 0 init\n' ;;
      empty) : ;;
      malformed) printf 'broken snapshot\n' ;;
      partial) printf '%s 1 bash probe.sh\n' "$$"; printf '%s 1 %s\n' "$TEST_PID" "$TEST_COMMAND"; printf '%s 1 bash /unreadable/run-all.sh\n' "$TEST_UNREADABLE_PID" ;;
      *) printf '%s 1 bash probe.sh\n' "$$"; printf '%s 1 %s\n' "$TEST_PID" "$TEST_COMMAND" ;;
    esac
  elif [ "$TEST_GRAPH" = dead ]; then return 1
  elif [ "$TEST_GRAPH" = reused ]; then printf '%s\n' 'bash /other.sh'
  elif [ "$TEST_GRAPH" = partial ] && [ "${5:-}" = "$TEST_UNREADABLE_PID" ]; then return 1
  else printf '%s\n' "$TEST_COMMAND"; fi
}
ff_startup_other_gates
'''
        for command in ['rg run-all.sh', 'bash -c echo /x/run-all.sh', 'bash -lc echo /x/run-all.sh',
                        'bash /other.sh /x/run-all.sh', 'bash /x/run-all.sh.extra']:
            result = subprocess.run(['bash', '-c', detector + synthetic], env=dict(
                env, TEST_PID=str(sleeper.pid), TEST_COMMAND=command, TEST_GRAPH='independent'),
                text=True, capture_output=True, timeout=10)
            require(result.returncode == 0 and not result.stdout, '名前だけの一致を除外: ' + command)
        positive = subprocess.run(['bash', '-c', detector + synthetic], env=dict(
            env, TEST_PID=str(sleeper.pid), TEST_COMMAND='bash /x/run-all.sh', TEST_GRAPH='independent'),
            text=True, capture_output=True, timeout=10)
        require(positive.returncode == 0 and positive.stdout.strip() == f'{sleeper.pid}:/x/run-all.sh',
                '生きた独立PIDを選ぶ肯定対照')
        options = subprocess.run(['bash', '-c', detector + synthetic], env=dict(
            env, TEST_PID=str(sleeper.pid), TEST_COMMAND='bash -O extglob /x/run-all.sh', TEST_GRAPH='independent'),
            text=True, capture_output=True, timeout=10)
        require(options.returncode == 0 and options.stdout.strip() == f'{sleeper.pid}:/x/run-all.sh',
                'shellオプションの値をscript名と取り違えない')
        cwd_unknown = subprocess.run(['bash', '-c', detector + 'lsof() { return 1; }\n' + synthetic], env=dict(
            env, TEST_PID='99999999', TEST_COMMAND='bash missing directory/run-all.sh', TEST_GRAPH='independent'),
            text=True, capture_output=True, timeout=10)
        require(cwd_unknown.returncode != 0 and not cwd_unknown.stdout,
                '空白を含む相対候補のcwd取得不能を並走なしへ落とさない')
        tail = 'ff_startup_other_gates\n'
        assert synthetic.endswith(tail)
        partial_code = detector + function(source, 'ff_capture_startup_load') + synthetic[:-len(tail)] + r'''
FF_STARTUP_LOAD_PER_CORE=10
ff_startup_measure_load() { echo 0; }
ff_startup_measure_cores() { echo 2; }
ff_capture_startup_load
printf '%s pressure=%s\n' "$FF_STARTUP_OTHER_GATES" "$FF_STARTUP_PRESSURE"
'''
        partial = subprocess.run(['bash', '-c', partial_code], env=dict(
            env, TEST_PID=str(sleeper.pid), TEST_UNREADABLE_PID=str(os.getpid()),
            TEST_COMMAND='bash /x/run-all.sh', TEST_GRAPH='partial'), text=True, capture_output=True, timeout=10)
        require(partial.returncode == 0 and partial.stdout.strip() == f'{sleeper.pid}:/x/run-all.sh,unknown pressure=1'
                and '起動時の負荷:' in partial.stderr,
                '一部PID照会が失敗しても確認済みの並走を捨てずunknownを併記')
        for graph in ['ancestor', 'descendant', 'sibling', 'dead', 'reused']:
            result = subprocess.run(['bash', '-c', detector + synthetic], env=dict(
                env, TEST_PID='99999999' if graph == 'dead' else str(sleeper.pid),
                TEST_COMMAND='bash /x/run-all.sh', TEST_GRAPH=graph), text=True, capture_output=True, timeout=10)
            require(result.returncode == 0 and not result.stdout, '同一ゲート系列・終了済み・別commandのPIDを並走と数えない: ' + graph)
        for graph in ['missing', 'empty', 'malformed']:
            result = subprocess.run(['bash', '-c', detector + synthetic], env=dict(
                env, TEST_PID=str(sleeper.pid), TEST_COMMAND='bash /x/run-all.sh', TEST_GRAPH=graph),
                text=True, capture_output=True, timeout=10)
            require(result.returncode != 0 and not result.stdout, 'プロセス集合の空振りは未測定: ' + graph)
    finally:
        sleeper.terminate()
        sleeper.wait(timeout=10)

    def git(*args, cwd):
        return subprocess.run(['git', *args], cwd=cwd, env=env, text=True,
                              capture_output=True, check=True, timeout=30).stdout.strip()

    def new_repo(path):
        subprocess.run(['bash', '-c', '. "$1"; ff_git_fixture_init "$2"',
                        'fixture', str(GIT_HELPER), str(path)], env=env,
                       check=True, capture_output=True, timeout=30)
        git('-c', 'core.hooksPath=/dev/null', 'commit', '--allow-empty', '-qm', 'fixture', cwd=path)

    repo = root / 'repo'
    if prepared_root:
        require((repo / '.git').is_dir(), 'wrapperが隔離helperで準備したrepoを使う')
        git('-c', 'core.hooksPath=/dev/null', 'commit', '--allow-empty', '-qm', 'fixture', cwd=repo)
    else:
        new_repo(repo)
    worktree = root / 'other worktree'
    git('-c', 'core.hooksPath=/dev/null', 'worktree', 'add', '--detach', str(worktree), 'HEAD', cwd=repo)
    other_repo = root / 'other-repo'
    new_repo(other_repo)
    require(git('rev-parse', '--path-format=absolute', '--git-common-dir', cwd=repo)
            == git('rev-parse', '--path-format=absolute', '--git-common-dir', cwd=worktree),
            'live対照は同じcommon dirの別worktree')
    require(git('rev-parse', '--absolute-git-dir', cwd=repo)
            != git('rev-parse', '--absolute-git-dir', cwd=other_repo), 'live対照の別repoは独立Git dir')
    try:
        native_ps = subprocess.run(['ps', '-ww', '-eo', 'pid=,ppid=,args='], env=env,
                                   text=True, capture_output=True, timeout=10)
        live_available = native_ps.returncode == 0 and any(
            line.split()[:1] == [str(os.getpid())] for line in native_ps.stdout.splitlines())
    except OSError:
        live_available = False
    if not live_available:
        print('  ○ skip: POSIX形式psを取得できず、別worktree/repoのlive並走は未検証（注入対照とunknownの検査は実施）', flush=True)
    actors = [(worktree, False), (other_repo, False), (other_repo, True)] if live_available else []
    for index, (actor_root, relative) in enumerate(actors):
        actor_runner = actor_root / ('relative gate/run-all.sh' if relative else 'plugins/ff-dev-toolkit/tests/run-all.sh')
        actor_runner.parent.mkdir(parents=True, exist_ok=True)
        actor_runner.write_text(source)
        actor_suite = actor_root / 'wait/verify.sh'
        actor_suite.parent.mkdir(exist_ok=True)
        ready, release = root / f'ready-{index}', root / f'release-{index}'
        actor_suite.write_text('#!/usr/bin/env bash\nprintf ready > "$FF_TEST_READY"\n'
                               'for ((i=0;i<1500;i++)); do [ ! -e "$FF_TEST_RELEASE" ] || exit 0; sleep 0.02; done\nexit 91\n')
        actor_suite.chmod(0o755)
        log = root / f'actor-{index}.log'
        with log.open('w') as stream:
            actor_path = str(actor_runner.relative_to(actor_root)) if relative else str(actor_runner)
            actor = subprocess.Popen(['bash', actor_path, str(actor_suite)], cwd=actor_root,
                                     env=dict(base, FF_TEST_READY=str(ready), FF_TEST_RELEASE=str(release)),
                                     stdout=stream, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 15
                while not ready.exists():
                    if actor.poll() is not None or time.monotonic() > deadline:
                        raise AssertionError('live gate did not reach suite: ' + log.read_text())
                    time.sleep(0.02)
                require(actor.poll() is None, '実ゲートがsuite待機中（時間推定に頼らない）')
                for label in ['pass', 'fail']:
                    result = run(label, process='fixture', extra={'TEST_VISIBLE_PID': str(actor.pid)})
                    require(f'{actor.pid}:{actor_path}' in result.stderr
                            and f'{actor.pid}:{actor_path}' in result.stdout,
                            f'別worktree/repoのlive gateを名指し: {index}/{label}')
                    require(('単体で再実行して切り分け' in result.stdout) == (label == 'fail'),
                            '並走時も失敗回だけ案内')
            finally:
                release.touch()
                try:
                    actor.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    actor.terminate()
                    actor.wait(timeout=10)
            require(actor.returncode == 0, '自分の待機ゲートを正常終了し回収')
    # A real host measurement remains callable independently of the injection.
    measurement = ''.join(function(source, mapping[x]) for x in ['load_gate_sysctl', 'measure_load_average', 'measure_cpu_cores'])
    measured = subprocess.run(['bash', '-c', measurement + '\nff_startup_measure_load\nff_startup_measure_cores\n'],
                              env=env, text=True, capture_output=True, timeout=10)
    legacy = ''.join(function(original, x) for x in ['load_gate_sysctl', 'measure_load_average', 'measure_cpu_cores'])
    expected = subprocess.run(['bash', '-c', legacy + '\nmeasure_load_average\nmeasure_cpu_cores\n'],
                              env=env, text=True, capture_output=True, timeout=10)
    # Live load can change between calls. Compare availability and shape, not the
    # numerical value of two measurements taken at different instants.
    shape = lambda result: (result.returncode, [bool(re.fullmatch(r'[0-9]+(?:[.][0-9]+)?', x))
                                              for x in result.stdout.splitlines()])
    require(shape(measured) == shape(expected), '注入なしの実ホスト測定も既存方式と同じ取得可否・形')

print('startup-load checks: all passed', flush=True)
