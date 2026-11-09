"""Real wrapper/orchestrator/adapters, fake gh/model executables; no network or paid CLI."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

root, tmp = map(Path, sys.argv[1:])
plugin, repo, bin_dir = tmp / 'plugin', tmp / 'repo', tmp / 'bin'
shutil.copytree(root / 'scripts', plugin / 'scripts')
shutil.copytree(root / '.claude-plugin', plugin / '.claude-plugin')
(plugin / 'tests/lib').mkdir(parents=True)
shutil.copy2(root / 'tests/lib/review-round-counter.sh', plugin / 'tests/lib/review-round-counter.sh')
bin_dir.mkdir()
captures, data = tmp / 'captures', tmp / 'data'
captures.mkdir()
data.mkdir()
env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], HOME=str(tmp / 'home'),
           FF_DEV_TOOLKIT_ROOT=str(plugin), FF_DEV_TOOLKIT_PROJECT_ROOT=str(repo),
           FF_DEV_TOOLKIT_SKIP='codex-auto-update', FF_REVIEW_ROUND_LIMIT='0',
           MULTI_AGENT_AC_FIXTURE=str(tmp))


def git(*args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


git('config', 'core.hooksPath', '/dev/null')
git('config', 'commit.gpgsign', 'false')
git('switch', '-c', 'develop')
(repo / 'app.txt').write_text('base\n')
git('add', 'app.txt')
git('commit', '-qm', 'base')
git('switch', '-c', 'feature/ac')
(repo / 'app.txt').write_text('base\nchange\n')
git('add', 'app.txt')
git('commit', '-qm', 'change')
git('remote', 'add', 'origin', 'https://github.com/Example/Project.git')
ref = '#'
pr = dict(number=7, url='https://github.com/Example/Project/pull/7', headRefName='feature/ac',
          body=f'Closes {ref}11\nCloses {ref}12\nRefs {ref}12\nRef Other/Project{ref}13\nRefs {ref}11\n裸 {ref}99\n関連 {ref}98',
          closingIssuesReferences=[dict(url=f'https://github.com/example/project/issues/{n}') for n in (11, 12)])
issue_bodies = {
    11: '# Intro\r\ntext\r\n## 受け入れ条件（AC）\r\n- [ ] 日本語 AC11\r\n### nested\r\nkeep\r\n## 他の節\r\nNOT_CONTEXT\r\n',
    12: '```md <!--\n## 受け入れ条件\nFAKE_FENCE <!--\n```\n<!--\n## DoD\nFAKE_COMMENT\n-->\n## Definition of Done\n- DoD12\n',
    13: '## Acceptance Criteria\n- AC13\n## DoD\n- DoD13\n',
}


def save_inputs():
    (data / 'pr.json').write_text(json.dumps(pr))
    for number, body in issue_bodies.items():
        slug = 'other/project' if number == 13 else 'example/project'
        (data / f'{number}.json').write_text(json.dumps(dict(
            number=number, url=f'https://github.com/{slug.upper()}/issues/{number}', body=body)))


save_inputs()
stub = '''#!/usr/bin/env python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['MULTI_AGENT_AC_FIXTURE']); args=sys.argv[1:]; name=pathlib.Path(sys.argv[0]).name
if '--version' in args:
 print(name+' 999.0.0'); sys.exit(0)
if name=='gh':
 with (p/'gh-calls').open('a') as f: f.write(json.dumps(args)+'\\n')
 if (p/'gh-bad-utf8').exists():
  sys.stderr.buffer.write(b'no pull requests found for branch "' + bytes([0xe3, 0x81]) + bytes([0xe3, 0x81, 0x82])*40 + b'"\\n')
  sys.exit(1)
 if (p/'gh-fail').exists(): sys.exit(1)
 if args[:2]==['pr','view']: file=p/'data/pr.json'
 elif args[:2]==['issue','view']: file=p/('data/'+args[2]+'.json')
 else: sys.exit(9)
 if not file.is_file(): sys.exit(1)
 sys.stdout.buffer.write(file.read_bytes()); sys.exit(0)
if name != 'gh' and (p / 'model-fail').exists():
 print('forced model failure', file=sys.stderr); sys.exit(1)
content=sys.stdin.read()
if not content:
 # Claude may carry a prompt path; fixture must fail rather than claim a missing prompt passed.
 for a in args:
  if pathlib.Path(a).is_file(): content=pathlib.Path(a).read_text(); break
if not content: print('no prompt',file=sys.stderr); sys.exit(9)
import uuid
(p/'captures'/(name+'-'+uuid.uuid4().hex+'.txt')).write_text(content)
print('## Review\\n\\n### Summary\\n- Critical: 0\\n- verdict: none')
'''
for name in ('gh', 'claude', 'codex'):
    path = bin_dir / name
    path.write_text(stub)
    path.chmod(0o755)
bash_shim = bin_dir / 'bash'
bash_shim.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
a=sys.argv[1:]
if a and '/scripts/adapters/' in a[0]:
 p=pathlib.Path(os.environ['MULTI_AGENT_AC_FIXTURE'])/'adapter-argv'
 with p.open('a') as f: f.write(json.dumps(dict(file='--description-file' in a, max_bytes=max(map(lambda x:len(x.encode()),a))))+'\\n')
 # Deterministically exercise the transport under a smaller host argv boundary.
 if any(len(x.encode())>32767 for x in a): sys.exit(88)
os.execv('/bin/bash', ['/bin/bash']+a)
''')
bash_shim.chmod(0o755)
passed = 0


def check(condition, message):
    global passed
    if not condition:
        raise AssertionError(message)
    passed += 1
    print('PASS:', message, flush=True)


def call(label, extra=(), *, full=False, output=None, direct=False, expected=0):
    out = output or tmp / ('out-' + label)
    args = ['bash', str(plugin / 'scripts' / ('multi-agent.sh' if direct else 'multi-review.sh'))]
    args += ['--task', 'review'] if direct else ['--route', 'full' if full else 'none']
    args += ['--base', 'develop', '--sequential', '--timeout', '10', '--output-dir', str(out)]
    if not full:
        args += ['--mode', 'distributed', '--cli', 'codex-cli', '--perspective', 'code-review']
    args += list(extra)
    before = set(captures.iterdir())
    result = subprocess.run(args, cwd=repo, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    (tmp / (label + '.log')).write_text(result.stdout + result.stderr)
    if result.returncode != expected:
        print((result.stdout + result.stderr)[-5000:], file=sys.stderr)
    check(result.returncode == expected, f'{label}: rc={result.returncode}, expected={expected}; log={tmp / (label+".log")}')
    return out, [p.read_text() for p in sorted(set(captures.iterdir()) - before)], result.stdout + result.stderr


out, prompts, log = call('full', full=True)
check(len(prompts) == 5, 'all five real lanes executed')
expected_tokens = ('AC11', 'DoD12', 'AC13', 'DoD13', 'nested', *(f'{ref}{n}' for n in (11, 12, 13)))
check(all(all(t in p for t in expected_tokens) for p in prompts), 'all lanes receive every Issue and nested section')
check(all('NOT_CONTEXT' not in p and 'FAKE_FENCE' not in p and 'FAKE_COMMENT' not in p for p in prompts), 'non-context and fake headings excluded')
context = (out / '.review-ac-context.txt').read_text()
check(context.count('日本語 AC11') == 1, 'duplicate references deduplicated')
check(all(f'AC を事前投入した（#{n}）' in log for n in (11, 12, 13)), 'injection log names each Issue')
calls = (tmp / 'gh-calls').read_bytes()
for label, description in [('explicit', "明示 ' \" $() `literal`\n\n"), ('empty', '')]:
    _, ps, _ = call(label, ['--description', description])
    _, direct_ps, _ = call(label + '-direct', ['--description', description], direct=True)
    check(len(ps) == len(direct_ps) == 1 and ps[0] == direct_ps[0], label + ': prompt byte equality with direct legacy path')
    check((tmp / 'gh-calls').read_bytes() == calls, label + ': zero gh calls')
_, _, log = call('dry', ['--dry-run'])
check((tmp / 'gh-calls').read_bytes() == calls, 'dry-run performs no acquisition')
for label, flag in [('help', '--help'), ('list', '--list-perspectives')]:
    _, ps, _ = call(label, [flag])
    check(not ps and (tmp / 'gh-calls').read_bytes() == calls, label + ': no acquisition or model dispatch')
# Exercise the CI shape: gh and required tools share one directory. Reuse the
# established removal helper (ACE-1866-2), never assume a system directory has no gh.
nogh = tmp / 'nogh'
nogh.mkdir()
original_path = env['PATH']
system_bin = tmp / 'system-bin'
system_bin.mkdir()
commands = ('awk', 'base64', 'basename', 'bash', 'cat', 'chmod', 'cksum', 'cmp',
            'cp', 'cut', 'date', 'diff', 'dirname', 'du', 'env', 'expr', 'find',
            'getconf', 'git', 'grep', 'head', 'hostname', 'iconv', 'jq', 'kill',
            'ln', 'ls', 'mkdir', 'mktemp', 'mv', 'nproc', 'od', 'paste', 'perl',
            'pgrep', 'pkill', 'printf', 'ps', 'python3', 'readlink', 'realpath',
            'rm', 'rmdir', 'sed', 'seq', 'sh', 'shasum', 'sha256sum', 'sleep',
            'sort', 'stat', 'sysctl', 'tail', 'tee', 'touch', 'tr', 'uname',
            'uniq', 'wc', 'which', 'xargs', 'yq', 'claude', 'codex')
for name in (*commands, 'gh'):
    resolved = shutil.which(name, path=original_path)
    if resolved:
        (system_bin / name).symlink_to(resolved)
        if name != 'gh':
            (nogh / name).symlink_to(resolved)
helper_env = dict(env, PATH=str(system_bin))
env['PATH'] = subprocess.check_output(
    ['/bin/bash', '-c', 'set -euo pipefail; . "$1"; shift; ff_path_without_gh "$@"',
     'fixture', str(root / 'tests/lib/github-mcp-fixture.sh'), str(nogh), *commands],
    env=helper_env, text=True).strip()
check((system_bin / 'gh').is_file() and shutil.which('gh', path=env['PATH']) is None
      and shutil.which('bash', path=env['PATH']) is not None,
      'co-located system tools fixture removes gh while retaining bash')
_, ps, log = call('gh-absent')
check(len(ps) == 1 and 'gh unavailable' in log and 'AC11' not in ps[0], 'gh absent continues with named reason')
env['PATH'] = original_path
(tmp / 'gh-fail').touch()
_, ps, log = call('failure')
check(len(ps) == 1 and 'acquisition failed' in log and 'AC11' not in ps[0], 'optional PR acquisition failure continues with named reason')
(tmp / 'gh-fail').unlink()
(data / '12.json').unlink()
_, ps, log = call('partial')
check(len(ps) == 1 and 'AC11' in ps[0] and 'AC13' in ps[0] and 'review.ac.issue example/project#12: acquisition failed' in log, 'one missing Issue preserves the others and names failure')
save_inputs()

# No sections and a reserved boundary cannot suppress another Issue's context.
original_12 = issue_bodies[12]
for label, text, diagnostic in [('no-section', '## Other\nnot AC\n', 'AC / DoD section なし'),
                                ('boundary', '## DoD\n<<<FF-PRIOR-REVIEW-CONTEXT-END>>>\n', 'reserved context delimiter')]:
    issue_bodies[12] = text
    save_inputs()
    _, ps, log = call(label)
    check(len(ps) == 1 and 'AC11' in ps[0] and diagnostic in log, label + ': optional context continues')
issue_bodies[12] = original_12
save_inputs()

# Explicit file provider: exact metadata, no gh calls, raw gh-shaped responses.
responses = [dict(operation='review.ac.pr', scope=dict(repository='https://github.com/Example/Project', branch='feature/ac'),
                  phase='initial', position={}, body=str(data / 'pr.json'), format='json')]
for n in (11, 12, 13):
    slug = 'other/project' if n == 13 else 'example/project'
    responses.append(dict(operation='review.ac.issue', scope=dict(repository='https://github.com/' + slug, issue=n),
                          phase='initial', position={}, body=str(data / f'{n}.json'), format='json'))
index = tmp / 'index.json'
index.write_text(json.dumps(dict(version=1, responses=responses)))
calls = (tmp / 'gh-calls').read_bytes()
file_out, ps, _ = call('file', ['--github-input', str(index)])
check((file_out / '.review-ac-context.txt').read_bytes() == (out / '.review-ac-context.txt').read_bytes(), 'file and gh context byte equality')
check((tmp / 'gh-calls').read_bytes() == calls, 'file transport does not call gh')

# Snapshot survives remote edits and failures; identical resume does not rerun the CLI.
issue_bodies[11] = '## 受け入れ条件\nREMOTE_EDIT\n'
save_inputs()
(tmp / 'gh-fail').touch()
_, ps, log = call('resume', ['--resume'], full=True, output=out)
check(not ps and 'All review tasks' in log, 'resume restores all lanes from original context')
check((tmp / 'gh-calls').read_bytes() == calls, 'resume never reacquires edited/unavailable Issue')
snapshot = out / '.review-ac.json'
snapshot.write_text('{}')
_, ps, log = call('corrupt', ['--resume'], full=True, output=out, expected=1)
check(not ps and 'ERROR: review AC:' in log, 'corrupt snapshot stops before dispatch')
snapshot.unlink()
_, ps, log = call('missing-snapshot', ['--resume'], full=True, output=out, expected=1)
check(not ps and 'snapshot missing' in log, 'missing same-run snapshot stops before dispatch')
(tmp / 'gh-fail').unlink()

# Delegation collection without --resume must also preserve the original snapshot.
delegated, _, log = call('delegate', ['--delegate-to-host=codex-cli'], expected=3)
requests = list(delegated.glob('codex-cli/.delegated/generations/*/*.request'))
check(len(requests) == 1, 'one real host-delegation request produced')
# The handoff is authoritative for the response path; do not infer it from request naming.
paths = re.findall(r'^\s*output-file=(.+)$', log, re.M)
check(len(paths) == 1, 'handoff names one response file')
response = Path(paths[0].strip())
response.write_text('## Review\n### Summary\n- Critical: 0\n- verdict: none\n')
calls = (tmp / 'gh-calls').read_bytes()
(tmp / 'gh-fail').touch()
_, ps, log = call('collect', ['--delegate-to-host=codex-cli'], output=delegated)
check(not ps and (tmp / 'gh-calls').read_bytes() == calls, 'host collection preserves original input without reacquisition')
(tmp / 'gh-fail').unlink()

# Switching through an explicit run ends the previous automatic acquisition run.
call('switch-explicit', ['--description', 'manual context'], output=file_out)
before_switch = (tmp / 'gh-calls').read_bytes()
_, ps, _ = call('switch-auto', ['--resume'], output=file_out)
check(len(ps) == 1 and 'REMOTE_EDIT' in ps[0] and (tmp / 'gh-calls').read_bytes() != before_switch,
      'auto after explicit run acquires fresh context rather than an older same-HEAD snapshot')

# A long auto-input must travel through the real adapter path, never body argv.
issue_bodies[11] = '## 受け入れ条件\n' + '長文' * 90000 + '\nEND_LONG\n'
save_inputs()
_, ps, _ = call('long')
check(len(ps) == 1 and 'END_LONG' in ps[0] and len(ps[0].encode()) > 500000, 'large AC is complete in adapter prompt')
argv = [json.loads(line) for line in (tmp / 'adapter-argv').read_text().splitlines()]
check(argv and argv[-1]['file'] and argv[-1]['max_bytes'] < 32768, 'auto context travels as file path at adapter exec boundary')
for name, replacement in [('github-input.sh', None), ('merge-message.sh', b'')]:
    helper = plugin / 'scripts/lib' / name
    original, mode = helper.read_bytes(), helper.stat().st_mode
    try:
        if replacement is None:
            helper.unlink()
        else:
            helper.write_bytes(replacement)
        _, ps, log = call('dependency-' + name, ['--description', ''], expected=2)
        check(not ps and '依存 helper' in log, name + ': absent/empty dependency stops explicitly before any model')
    finally:
        helper.write_bytes(original)
        helper.chmod(mode)
keyword_helper = plugin / 'scripts/check-closing-keywords.sh'
keyword_bytes, keyword_mode = keyword_helper.read_bytes(), keyword_helper.stat().st_mode
keyword_helper.unlink()
try:
    _, ps, log = call('keyword-missing')
    check(len(ps) == 1 and 'AC11' not in ps[0] and 'DoD12' not in ps[0],
          'missing keyword helper continues without AC')
    check('check-closing-keywords.sh unavailable' in log, 'missing keyword helper names the reason')
finally:
    keyword_helper.write_bytes(keyword_bytes)
    keyword_helper.chmod(keyword_mode)
keyword_helper.write_text('#!/bin/sh\nprintf "NotAKeyword\\n"\n')
keyword_helper.chmod(0o755)
try:
    _, ps, log = call('keyword-malformed')
    check(len(ps) == 1 and 'AC11' not in ps[0] and 'DoD12' not in ps[0],
          'malformed keyword list continues without AC')
    check('closing keyword set unavailable' in log, 'malformed keyword list names the reason')
finally:
    keyword_helper.write_bytes(keyword_bytes)
    keyword_helper.chmod(keyword_mode)
(tmp / 'model-fail').touch()
try:
    _, _, log = call('advice-auto', expected=1)
    advice = [line for line in log.splitlines() if 'multi-agent.sh' in line]
    check(advice and all('日本語 AC11' not in line and '--description' not in line for line in advice)
          and any('--review-ac-auto' in line for line in advice),
          'auto failure advice refetches and does not embed the AC body')
    _, _, log = call('advice-explicit', ['--description', 'KEEP_DESC_TOKEN'], expected=1)
    advice = [line for line in log.splitlines() if 'multi-agent.sh' in line]
    check(any('KEEP_DESC_TOKEN' in line and '--description' in line for line in advice)
          and all('--review-ac-auto' not in line for line in advice),
          'explicit failure advice keeps the given description')
    _, _, log = call('advice-index', ['--github-input', str(index)], expected=1)
    advice = [line for line in log.splitlines() if 'multi-agent.sh' in line]
    check(any('--review-ac-auto' in line and '--github-input' in line and str(index) in line for line in advice)
          and all('日本語 AC11' not in line for line in advice),
          'auto failure advice keeps the file provider index')
finally:
    (tmp / 'model-fail').unlink()
(tmp / 'gh-bad-utf8').touch()
try:
    _, ps, log = call('bad-utf8')
    check(ps and 'acquisition failed' in log and 'Aborted before running any task' not in log,
          'invalid UTF-8 fetch error does not abort the review')
finally:
    (tmp / 'gh-bad-utf8').unlink()

# python3 is optional for an omitted description. Stubs keep an absolute interpreter
# so removing python3 from PATH does not stop the model. A same-HEAD resume still refuses.
real_py = shutil.which('python3')
check(real_py is not None, 'fixture host has python3')
for stub_name in ('gh', 'claude', 'codex', 'bash'):
    stub_path = bin_dir / stub_name
    stub_path.write_text(stub_path.read_text().replace('#!/usr/bin/env python3', '#!' + real_py, 1))
nopy = tmp / 'nopy'
nopy.mkdir()
for name in commands:
    if name == 'python3':
        continue
    resolved = shutil.which(name, path=original_path)
    if resolved:
        (nopy / name).symlink_to(resolved)
nopy_path = str(bin_dir) + os.pathsep + str(nopy)
check(shutil.which('python3', path=nopy_path) is None and shutil.which('bash', path=nopy_path) is not None,
      'python3-absent fixture keeps bash and the model stubs')
env['PATH'] = nopy_path
nopy_out, ps, log = call('python-absent')
check(len(ps) == 1 and 'python3 unavailable' in log and 'AC11' not in ps[0]
      and 'Aborted before running any task' not in log,
      'missing python3 continues without AC')
check('review-ac=unavailable' in (nopy_out / '.resume-cache/last-inputs').read_text(),
      'a run that continued without AC records review-ac=unavailable, not auto')
# 初回も再開も python3 が無い回。auto と記録すると、無い snapshot を要求して再開が必ず止まる。
_, ps, log = call('python-absent-resume-nopy', ['--resume'], output=nopy_out)
check('AC なしで継続した回のため' in log and 'refusing to resume' not in log
      and 'Aborted before running any task' not in log,
      'a run that continued without AC resumes without AC on the same HEAD')
shim = nopy / 'python3'
shim.write_text('#!/bin/sh\nexit 127\n')
shim.chmod(0o755)
_, ps, log = call('python-stub')
check(len(ps) == 1 and 'python3 failed to check the snapshot' in log and 'AC11' not in ps[0],
      'python3 that fails to start continues without AC and names the failed check')
shim.unlink()
_, ps, log = call('python-absent-resume', ['--resume'], full=True, output=out, expected=1)
check(not ps and 'refusing to resume without the original snapshot' in log
      and 'Aborted before running any task' in log,
      'missing python3 refuses a same-HEAD resume that would drop the original AC')
env['PATH'] = original_path
# python3 が戻っても、AC なしで続行した回の再開は取得し直さない（入力が変わり再開できなくなる）。
_, ps, log = call('python-restored-resume', ['--resume'], output=nopy_out)
check('AC なしで継続した回のため' in log and 'Aborted before running any task' not in log,
      'restoring python3 keeps the resume of a run that continued without AC')
check(passed > 20, 'case collection is not empty')
print(f'review-ac-context: {passed} passed', flush=True)
