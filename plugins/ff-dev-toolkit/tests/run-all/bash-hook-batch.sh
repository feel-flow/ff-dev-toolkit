#!/usr/bin/env bash
# 集約入口の拒否・警告保存と実登録を検査する。
# 空振り検出: 登録12本の通常はrc0、新guardだけを登録から外す/集約子の引数集合を0件にする各単独変異は登録集合assertでrc1（2026-10-22 macOS実測、構文rc0）。存在しない/空の子は無検査を診断する。
# 変異検出: 拒否時の未実行注記を JSON の permissionDecisionReason から外す / 終了コード2の stderr 末尾から外す / 出力0件 / 解釈できる出力0件の経路で finish を通さず exit する、の4変異がそれぞれ赤（2026-10-02 実測）。
# 変異検出: 時間切れの知らせを集約 JSON の systemMessage と additionalContext から外すと、打ち切りのケースが赤になる。stderr の診断行だけでは通さない（2026-10-27 Linux 実測）。
# 変異検出: 終了コード2と打ち切りが重なる回で json_timeout を空にする分岐、および解釈できる出力0件経路の emit_timeout_only を外すとそれぞれ赤（2026-10-27 Linux 実測）。
# 変異検出: reject_rewrite の jq から json_timeout（systemMessage / additionalContext）を外すと、打ち切り×解釈不能 updatedInput のケースが赤（2026-10-27 Linux 実測）。
# 変異検出: Windows の Git Bash（MSYS / Cygwin）の子の枠 25 秒を外して 10 秒へ戻すと、12 秒かかる子の msys ケースが赤（Issue `#2377`。2026-10-26 WSL 実測）。
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
# -X utf8: Windows の Python の既定は cp932 で、子の日本語の stderr の復号でも落ちる（Issue `#2022`）
python3 -X utf8 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

# Windows のプロセス起動は PATH より先に System32 を探し、素の 'bash' は WSL の bash.exe になる。
# 子へ渡すパスも '/' 区切りにする（'\' だけのパスでは子の "${BASH_SOURCE%/*}" が効かない）。
BASH = shutil.which('bash') or 'bash'
root = Path(sys.argv[1])
runner = root / 'hooks/run-bash-hooks.sh'
config = json.loads((root / 'hooks/hooks.json').read_text(encoding='utf-8'))  # Windows の既定は cp932
group = next(g for g in config['hooks']['PreToolUse'] if g['matcher'] == 'Bash')
assert len(group['hooks']) == 1, 'ホスト入口が1本ではない'
entry = group['hooks'][0]
args = shlex.split(entry['command'].replace('${CLAUDE_PLUGIN_ROOT}', str(root)))
expected = ['guard-checkout-restore', 'guard-pr-followup', 'guard-background-cwd',
            'guard-long-gate-background', 'guard-effort-actual', 'guard-merge-closing-keyword',
            'guard-issue-labels',
            'guard-sub-issue-id', 'guard-exit-code', 'guard-zsh-glob',
            'guard-literal-write', 'guard-credential-output', 'guard-wsl-shell',
            'record-effort-wallclock']
# Path 同士で比べる（Windows では hooks.json から組んだ文字列だけ '/' と '\' が混ざる）
assert args[0] == 'bash' and Path(args[1]) == runner
assert [Path(a) for a in args[2:]] == [root / 'hooks' / (name + '.sh') for name in expected], 'Bash集約子の登録集合が期待と違う'
assert entry['timeout'] == 30
assert sum(len(g['hooks']) for g in config['hooks']['PreToolUse']
           if 'Bash' in g['matcher'].split('|')) == 2

with tempfile.TemporaryDirectory(prefix='ff-batch-test-') as temp:
    temp = Path(temp)
    env = os.environ.copy()
    # 利用者の opt-out を引き継いで偽緑/偽赤にしない。
    for key in list(env):
        if key.split('_')[:4] == ['FF', 'DEV', 'TOOLKIT', 'SKIP'] or key == 'FF_EXIT_CODE_ACK':
            env.pop(key)
    env['TMPDIR'] = str(temp)
    env['CLAUDE_PLUGIN_ROOT'] = root.as_posix()

    def run(hooks, payload='{}', ostype=None, limit=15):
        child_env = env if ostype is None else {**env, 'OSTYPE': ostype}
        return subprocess.run([BASH, runner.as_posix(), *(Path(h).as_posix() for h in hooks)],
                              input=payload, text=True, capture_output=True, env=child_env, cwd=temp,
                              timeout=limit)

    def stub(name, body):
        path = temp / (name + '.sh')
        # 早期終了する子でも親は先に大入力を読み終えている必要がある。
        path.write_text('#!/usr/bin/env bash\n' + body + '\n', newline='\n')
        return path

    def output(name, value):
        return stub(name, 'printf "%s\\n" ' + shlex.quote(json.dumps(value)))

    def decision(kind, reason):
        return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                'permissionDecision': kind, 'permissionDecisionReason': reason}}

    silent = stub('silent', 'exit 0')
    assert run([silent], 'x' * 300000).stdout == ''
    assert run([silent], 'x' * 300000).returncode == 0
    for hooks in ([], [temp / 'absent'], [stub('empty', '')]):
        if hooks and hooks[0].name == 'empty.sh':
            hooks[0].write_text('')
        result = run(hooks)
        assert result.returncode == 0 and result.stderr and not result.stdout
    env['TMPDIR'] = str(temp / 'missing')
    result = run([silent])
    assert result.returncode == 0 and '一時領域' in result.stderr
    env['TMPDIR'] = str(temp)
    warning = output('warning', {'systemMessage': '注意1'})
    warning2 = output('warning2', {'systemMessage': '注意2'})
    deny = output('deny', decision('deny', '拒否1'))
    deny2 = output('deny2', decision('deny', '拒否2'))
    # 子1本の欠落と未知の拡張キーが、正常な拒否を消さないことを確認する。
    for missing in (temp / 'absent', temp / 'empty.sh'):
        result = run([missing, deny])
        assert '読み込めません' in result.stderr
        assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'] == 'deny'
    extended = decision('deny', '拡張付き拒否')
    extended['suppressOutput'] = True
    extended['hookSpecificOutput']['additionalContext'] = 'context'
    result = run([output('extended', extended)])
    assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'] == 'deny'

    ask = output('ask', decision('ask', '確認'))
    allow = output('allow', decision('allow', '許可'))
    result = run([warning, allow, deny, warning2, ask, deny2])
    assert result.returncode == 0, result.stderr
    value = json.loads(result.stdout)
    assert value['systemMessage'] == '注意1\n注意2'
    assert value['hookSpecificOutput']['permissionDecision'] == 'deny'
    assert all(s in value['hookSpecificOutput']['permissionDecisionReason']
               for s in ('拒否1', '拒否2', '確認', '許可'))
    assert json.loads(run([allow, ask]).stdout)['hookSpecificOutput']['permissionDecision'] == 'ask'
    assert json.loads(run([allow]).stdout) == decision('allow', '許可')
    assert json.loads(run([warning]).stdout) == {'systemMessage': '注意1'}
    for code in (1, 2, 7):
        failure = stub('failure', f'echo failure >&2\nexit {code}')
        result = run([failure, deny])
        assert result.returncode == (2 if code == 2 else 0) and 'failure' in result.stderr
        if code == 2:
            assert '拒否1' in result.stderr
        else:
            assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'] == 'deny'
    # 拒否時だけ、前段も未実行である旨が理由文の末尾に1回付く。
    note = ('この呼び出しは 1 つも実行されていません（同じ呼び出しの前段で作るつもりだった'
            'ファイル・書き込みも存在しません）。生成と、ガードに当たる反映は別の呼び出しに分けて'
            '再実行してください。')
    reason = json.loads(run([deny, ask, deny2]).stdout)['hookSpecificOutput']['permissionDecisionReason']
    assert reason.splitlines()[-1] == note and reason.count(note) == 1, reason
    blocked = stub('blocked', 'echo 止めた >&2\nexit 2')
    for hooks in ([blocked], [blocked, deny], [blocked, warning],
                  [blocked, stub('unparsable', 'echo invalid')]):
        result = run(hooks)
        assert result.returncode == 2 and result.stderr.splitlines()[-1] == note, result.stderr
        assert result.stderr.count(note) == 1 and note not in result.stdout, result.stderr
    for hooks in ([allow], [allow, ask], [ask], [warning], [silent], [stub('failure', 'exit 1')]):
        result = run(hooks)
        assert note not in result.stdout + result.stderr, (hooks, result.stdout, result.stderr)
    for body in ('echo invalid', 'echo null', 'echo "[]"', 'echo "{\\"unknown\\":true}"'):
        result = run([stub('invalid', body), deny])
        assert result.returncode == 0 and '除外' in result.stderr
        assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'] == 'deny'
    # 子の完了順でメッセージの順序が変わらず、他の子の exit にも巻き込まれない。
    delayed = stub('delayed', 'sleep 0.1\nprintf "%s" \'{"systemMessage":"遅い"}\'')
    assert json.loads(run([delayed, warning]).stdout)['systemMessage'] == '遅い\n注意1'
    # 子へ umask を上書きせず、タイムアウトした1本だけを無視して拒否を届ける。
    mode = stub('mode', 'umask >&2')
    direct = subprocess.run([BASH, mode.as_posix()], capture_output=True, text=True)
    assert run([mode]).stderr == direct.stderr
    slow = stub('slow', 'while :; do :; done')
    notice = 'ff-dev-toolkit: hook 1 は時間内に完了しませんでした'
    start = time.monotonic()
    result = run([slow, warning, deny], ostype='linux-gnu')
    assert 9 <= time.monotonic() - start < 14
    assert result.returncode == 0 and '時間内' in result.stderr
    assert result.stderr.count(notice) == 1
    value = json.loads(result.stdout)
    assert value['hookSpecificOutput']['permissionDecision'] == 'deny'
    assert value['systemMessage'] == '注意1\n' + notice
    assert value['hookSpecificOutput']['additionalContext'] == notice
    assert value['hookSpecificOutput']['permissionDecisionReason'] == '拒否1\n' + note
    assert notice not in value['hookSpecificOutput']['permissionDecisionReason']
    # 出力が無い打ち切りでも、同じ文面を JSON へ載せる。拒否にはしない。
    start = time.monotonic()
    result = run([slow], ostype='linux-gnu')
    assert 9 <= time.monotonic() - start < 14
    assert result.returncode == 0 and result.stderr.count(notice) == 1
    assert json.loads(result.stdout) == {
        'systemMessage': notice,
        'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'additionalContext': notice},
    }
    assert note not in result.stdout and note not in result.stderr
    # 終了コード 2 と打ち切りが重なる回: JSON へは重ねず、stderr の診断行と未実行注記だけ。
    start = time.monotonic()
    result = run([slow, blocked, warning], ostype='linux-gnu')
    assert 9 <= time.monotonic() - start < 14
    assert result.returncode == 2
    assert result.stderr.count(notice) == 1
    assert notice not in result.stdout
    assert result.stderr.splitlines()[-1] == note
    assert result.stderr.count(note) == 1
    # 解釈できる出力が 0 件の経路（2 か所目の emit_timeout_only）でも JSON へ載せる。
    start = time.monotonic()
    result = run([slow, stub('invalid', 'echo invalid')], ostype='linux-gnu')
    assert 9 <= time.monotonic() - start < 14
    assert result.returncode == 0
    assert '除外' in result.stderr and result.stderr.count(notice) == 1
    assert json.loads(result.stdout) == {
        'systemMessage': notice,
        'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'additionalContext': notice},
    }
    # 書き換え拒否（解釈不能 updatedInput）でも時間切れの知らせを JSON へ載せる（reject_rewrite）。
    bad_rw = output('bad-rw', {'hookSpecificOutput': {
        'hookEventName': 'PreToolUse', 'updatedInput': {'command': ''}}})
    start = time.monotonic()
    result = run([slow, bad_rw], ostype='linux-gnu')
    assert 9 <= time.monotonic() - start < 14
    assert result.returncode == 0
    assert result.stderr.count(notice) == 1
    value = json.loads(result.stdout)
    assert value['hookSpecificOutput']['permissionDecision'] == 'deny'
    assert '解釈できない' in value['hookSpecificOutput']['permissionDecisionReason']
    assert value['hookSpecificOutput']['permissionDecisionReason'].endswith(note)
    assert value['systemMessage'] == notice
    assert value['hookSpecificOutput']['additionalContext'] == notice
    # 競合する書き換え×打ち切りも同じ契約（reject_rewrite の別呼び出し）。
    rw_a = output('rw-a', {'hookSpecificOutput': {
        'hookEventName': 'PreToolUse', 'updatedInput': {'command': 'echo a'}}})
    rw_b = output('rw-b', {'hookSpecificOutput': {
        'hookEventName': 'PreToolUse', 'updatedInput': {'command': 'echo b'}}})
    start = time.monotonic()
    result = run([slow, rw_a, rw_b], ostype='linux-gnu',
                 payload=json.dumps({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                                     'tool_input': {'command': 'echo x'}}))
    assert 9 <= time.monotonic() - start < 14
    assert result.returncode == 0
    assert result.stderr.count(notice) == 1
    value = json.loads(result.stdout)
    assert value['hookSpecificOutput']['permissionDecision'] == 'deny'
    assert '競合する入力書き換え' in value['hookSpecificOutput']['permissionDecisionReason']
    assert value['systemMessage'] == notice
    assert value['hookSpecificOutput']['additionalContext'] == notice
    # Windows の Git Bash（MSYS / Cygwin）では子の枠が 25 秒（Issue `#2377`）。12 秒かかる子も打ち切らない
    late = stub('late', 'sleep 12\nprintf "%s" \'{"systemMessage":"遅い子"}\'')
    start = time.monotonic()
    result = run([late, warning], ostype='msys', limit=40)
    assert 11 <= time.monotonic() - start < 25
    assert result.returncode == 0 and '時間内' not in result.stderr
    assert json.loads(result.stdout)['systemMessage'] == '遅い子\n注意1'
    assert not list(temp.glob('ff-bash-hooks.*')), '一時入力が残っている'

    payload = {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
               'cwd': str(temp), 'tool_input': {'command': 'git status --short'}}
    result = run(args[2:], json.dumps(payload))
    assert result.returncode == 0 and result.stdout == '', result.stderr
    # 実際の静的検出器を通して、入力されたコマンドは実行せず deny されることを見る。
    payload['tool_input']['command'] = 'npm test | tail -20; echo "EXIT=$?"'
    result = run(args[2:], json.dumps(payload))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'] == 'deny'
    assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecisionReason'].endswith(note)
    payload['tool_input']['command'] = 'gh api repos/o/r/issues/1/sub_issues -f sub_issue_id=123'
    result = run(args[2:], json.dumps(payload))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'] == 'deny'
print('✅ bash-hook-batch: 登録・大入力・拒否優先・全警告・未実行注記・時間切れの JSON・子失敗・実ガード検証 passed')
PY
