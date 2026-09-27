#!/usr/bin/env bash
# 集約入口の拒否・警告保存と実登録を検査する。
# 空振り検出: 登録9本の欠落は赤。引数0件・存在しない/空の子は無検査を診断する。
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
runner = root / 'hooks/run-bash-hooks.sh'
config = json.loads((root / 'hooks/hooks.json').read_text())
group = next(g for g in config['hooks']['PreToolUse'] if g['matcher'] == 'Bash')
assert len(group['hooks']) == 1, 'ホスト入口が1本ではない'
entry = group['hooks'][0]
args = shlex.split(entry['command'].replace('${CLAUDE_PLUGIN_ROOT}', str(root)))
expected = ['guard-checkout-restore', 'guard-pr-followup', 'guard-background-cwd',
            'guard-long-gate-background', 'guard-effort-actual', 'guard-issue-labels',
            'guard-sub-issue-id', 'guard-exit-code', 'record-effort-wallclock']
assert args[:2] == ['bash', str(runner)]
assert args[2:] == [str(root / 'hooks' / (name + '.sh')) for name in expected]
assert entry['timeout'] == 15
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
    env['CLAUDE_PLUGIN_ROOT'] = str(root)

    def run(hooks, payload='{}'):
        return subprocess.run(['bash', str(runner), *map(str, hooks)], input=payload,
                              text=True, capture_output=True, env=env, cwd=temp, timeout=15)

    def stub(name, body):
        path = temp / (name + '.sh')
        # 早期終了する子でも親は先に大入力を読み終えている必要がある。
        path.write_text('#!/usr/bin/env bash\n' + body + '\n')
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
    for body in ('echo invalid', 'echo null', 'echo "[]"', 'echo "{\\"unknown\\":true}"'):
        result = run([stub('invalid', body), deny])
        assert result.returncode == 0 and '除外' in result.stderr
        assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'] == 'deny'
    # 子の完了順でメッセージの順序が変わらず、他の子の exit にも巻き込まれない。
    delayed = stub('delayed', 'sleep 0.1\nprintf "%s" \'{"systemMessage":"遅い"}\'')
    assert json.loads(run([delayed, warning]).stdout)['systemMessage'] == '遅い\n注意1'
    # 子へ umask を上書きせず、タイムアウトした1本だけを無視して拒否を届ける。
    mode = stub('mode', 'umask >&2')
    direct = subprocess.run(['bash', str(mode)], capture_output=True, text=True)
    assert run([mode]).stderr == direct.stderr
    slow = stub('slow', 'while :; do :; done')
    start = time.monotonic()
    result = run([slow, warning, deny])
    assert 9 <= time.monotonic() - start < 14
    assert result.returncode == 0 and '時間内' in result.stderr
    value = json.loads(result.stdout)
    assert value['hookSpecificOutput']['permissionDecision'] == 'deny'
    assert value['systemMessage'] == '注意1'
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
    payload['tool_input']['command'] = 'gh api repos/o/r/issues/1/sub_issues -f sub_issue_id=123'
    result = run(args[2:], json.dumps(payload))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'] == 'deny'
print('✅ bash-hook-batch: 登録・大入力・拒否優先・全警告・子失敗・実ガード検証 passed')
PY
