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
issue_bodies[11] = '## 受け入れ条件\n' + '長文' * 5700 + '\nEND_LONG\n'
save_inputs()
_, ps, _ = call('long')
check(len(ps) == 1 and 'END_LONG' in ps[0] and len(ps[0].encode()) > 32768, 'large AC is complete in adapter prompt')
argv = [json.loads(line) for line in (tmp / 'adapter-argv').read_text().splitlines()]
check(argv and argv[-1]['file'] and argv[-1]['max_bytes'] < 32768, 'auto context travels as file path at adapter exec boundary')

# Issue background / scope / out-of-scope / constraints extraction + ff-effort/empty exclusion.
orig_pr = json.loads(json.dumps(pr))
orig_bodies = dict(issue_bodies)
try:
    pr['title'] = 'feat: PR_TITLE_TOK sample'
    pr['body'] = f'Closes {ref}11\n\n補足で Closes {ref}98 と `Fixes {ref}99` を引用 PR_BODY_TOK\n'
    pr['closingIssuesReferences'] = [{'url': 'https://github.com/example/project/issues/11'}]
    issue_bodies[11] = (
        '## 背景\nBG_11\n'
        '## 目的\n<!-- ff-effort:begin -->\n- effort_ai_planned: 1.0h\n<!-- ff-effort:end -->\n'
        '## やること\nTODO_11\n'
        '## スコープ外\nOOS_11\n<!-- ff-effort:begin -->\n- effort_ai_actual: hidden\n<!-- ff-effort:end -->\n'
        '## 前提・制約\nCONSTRAINT_11\n'
        '## 受け入れ条件\n- [ ] AC_11\n'
        '## 他の節\nSHOULD_NOT_APPEAR\n'
    )
    save_inputs()
    (tmp / 'gh-calls').write_text('')
    scope_out, ps, log = call('extended-scope')
    check(len(ps) == 1 and all(t in ps[0] for t in ('BG_11', 'TODO_11', 'OOS_11', 'CONSTRAINT_11', 'AC_11', 'PR_TITLE_TOK', 'PR_BODY_TOK')),
          'extended Issue sections and untrusted PR title/body injected')
    check('effort_ai_planned' not in ps[0] and 'effort_ai_actual' not in ps[0] and 'SHOULD_NOT_APPEAR' not in ps[0] and '## 目的' not in ps[0],
          'ff-effort blocks, empty sections, and excluded headings omitted')
    m_pr_box = re.search(
        r'\n<<<FF-PR-BODY-UNTRUSTED-BEGIN>>>\n(.*?)\n<<<FF-PR-BODY-UNTRUSTED-END>>>\n',
        ps[0],
        re.S,
    )
    check(m_pr_box is not None and 'PR_TITLE_TOK' in m_pr_box.group(1)
          and 'PR_BODY_TOK' in m_pr_box.group(1) and 'untrusted verification target' in ps[0],
          'PR title and body framed strictly inside untrusted verification delimiters')
    gh_calls_text = (tmp / 'gh-calls').read_text()
    check('"98"' not in gh_calls_text and '"99"' not in gh_calls_text and '引用/散文の closing keyword' in log,
          'quoted and prose Closes in PR body excluded from Issue fetching')
    check(f'PR 本文（untrusted 検証対象）を事前投入した（PR {ref}7）' in log, 'PR body injection diagnostic logged')

    # Same-HEAD --resume must reuse both Issue context and PR body without calling gh.
    (tmp / 'gh-fail').touch()
    _, ps_resume, log_resume = call('extended-resume', ['--resume'], output=scope_out)
    check(not ps_resume and (tmp / 'gh-calls').read_text() == gh_calls_text and 'All review tasks' in log_resume,
          'resume keeps full snapshot including PR body without re-fetching')
    (tmp / 'gh-fail').unlink()

    # Zero-issue PR still injects untrusted PR title and body.
    pr['title'] = 'chore: PR_ONLY_TITLE'
    pr['body'] = 'ONLY_PR_BODY without issue links'
    pr['closingIssuesReferences'] = []
    save_inputs()
    _, ps, _ = call('pr-only')
    check(len(ps) == 1 and 'PR_ONLY_TITLE' in ps[0] and 'ONLY_PR_BODY' in ps[0] and '<<<FF-PR-BODY-UNTRUSTED-BEGIN>>>' in ps[0],
          'PR with zero referenced issues still injects untrusted PR title/body')

    # Backward compatibility: pr.json missing title field works cleanly.
    pr.pop('title', None)
    pr['body'] = 'BACK_COMPAT_BODY_ONLY'
    save_inputs()
    _, ps, _ = call('no-title')
    check(len(ps) == 1 and 'BACK_COMPAT_BODY_ONLY' in ps[0], 'PR JSON without title field remains compatible')

    # Reserved delimiters inside PR body or Issue body skip only the offending artifact.
    for delim_label, delim_tok in [
        ('pr-delim-untrusted-end', '<<<FF-PR-BODY-UNTRUSTED-END>>>'),
        ('pr-delim-prior-end', '<<<FF-PRIOR-REVIEW-CONTEXT-END>>>'),
    ]:
        pr['title'] = 'feat: safe title'
        pr['body'] = f'Closes {ref}11\n\n{delim_tok}\n'
        pr['closingIssuesReferences'] = [{'url': 'https://github.com/example/project/issues/11'}]
        save_inputs()
        delim_out, ps, log = call(delim_label)
        delim_ctx = (delim_out / '.review-ac-context.txt').read_text()
        check(len(ps) == 1 and 'AC_11' in ps[0]
              and f'Pull Request {ref}7' not in ps[0]
              and '<<<FF-PR-BODY-UNTRUSTED-BEGIN>>>' not in delim_ctx
              and delim_tok not in delim_ctx
              and 'reserved context delimiter in PR title/body' in log,
              delim_label + ': reserved delimiter excludes PR body while preserving Issue context')

    issue_bodies[12] = '## DoD\n<<<FF-PR-BODY-UNTRUSTED-END>>>\n'
    pr['body'] = f'Closes {ref}11\nCloses {ref}12\n'
    pr['closingIssuesReferences'] = [{'url': f'https://github.com/example/project/issues/{n}'} for n in (11, 12)]
    save_inputs()
    _, ps, log = call('issue-untrusted-delim')
    check(len(ps) == 1 and 'AC_11' in ps[0] and 'reserved context delimiter' in log,
          'Issue containing PR untrusted delimiter is skipped safely')

    # Size caps + AC priority + UTF-8 safe truncation.
    issue_bodies[11] = '## 背景\n' + ('背' * 15000) + '\n\n## 受け入れ条件\n- [ ] MUST_KEEP_AC\n'
    pr['title'] = 'あ' * 300
    pr['body'] = f'Closes {ref}11\n\n' + ('日本語ＰＲ本文' * 3000)
    pr['closingIssuesReferences'] = [{'url': 'https://github.com/example/project/issues/11'}]
    save_inputs()
    trunc_out, ps, log = call('size-cap')
    ctx_bytes = (trunc_out / '.review-ac-context.txt').read_bytes()
    ctx_text = ctx_bytes.decode('utf-8', errors='strict')
    check(len(ps) == 1 and 'MUST_KEEP_AC' in ctx_text and '... [truncated]' in ctx_text and '\ufffd' not in ctx_text
          and len(ctx_bytes) <= 65536 and 'サイズ上限' in log,
          'oversized background and PR body truncate safely on UTF-8 boundaries while keeping AC')

    # Nested heading document order + quoted/indented ff-effort + col0 inline triple-backtick exclusion.
    issue_bodies[11] = (
        '## Scope\n### In scope\n- IN_11\n'
        '#### Acceptance Criteria\n- [ ] NESTED_AC_11\n'
        '### Out of scope\n- OUT_11\n'
        '## 受け入れ条件\n- [ ] `<!-- ff-effort:begin -->` rule\n'
        '- [ ] 次の例を確認する\n\n'
        '    <!-- ff-effort:begin -->\n'
        '    INDENTED_EFFORT_EXAMPLE\n'
        '    <!-- ff-effort:end -->\n\n'
        '  ```inline` と KEEPER_AC_LINE\n'
        '## 他の節\nSHOULD_NOT_LEAK_AFTER_INLINE_BACKTICK\n'
    )
    pr['title'] = 'feat: nested order'
    pr['body'] = f'Closes {ref}11\n'
    pr['closingIssuesReferences'] = [{'url': 'https://github.com/example/project/issues/11'}]
    save_inputs()
    _, ps, _ = call('nested-and-quoted-effort')
    check(len(ps) == 1
          and all(t in ps[0] for t in ('IN_11', 'NESTED_AC_11', 'OUT_11', 'KEEPER_AC_LINE', 'INDENTED_EFFORT_EXAMPLE'))
          and 'SHOULD_NOT_LEAK_AFTER_INLINE_BACKTICK' not in ps[0],
          'nested AC, indented/quoted ff-effort preserved, and col0 inline triple-backtick excludes trailing section')
    check(ps[0].index('IN_11') < ps[0].index('NESTED_AC_11') < ps[0].index('OUT_11'),
          'nested AC inside Scope retains original document section order')

    # Canonical writing.md headings (bug/job story/changes) + bodyless ## Out of scope parent heading.
    issue_bodies[11] = (
        '## ジョブストーリー\nJOB_11\n'
        '## 再現手順\nREPRO_11\n'
        '## 期待される動作\nEXP_11\n'
        '## 実際の動作\nACT_11\n'
        '## 変更内容\nCHG_11\n'
        '## 変更方針\nPOLICY_11\n'
        '## 対象ファイル\nFILES_11\n'
        '## 目的\n\n'
        '## Out of scope\n### Acceptance Criteria\n- [ ] FOLLOWUP_AC_11\n'
        '## DoD\n- [ ] DOD_11\n'
        '## 他の節\nOUTSIDE_SECTION_11\n'
    )
    pr['title'] = 'feat: writing headings and out of scope parent'
    pr['body'] = f'Closes {ref}11\n'
    pr['closingIssuesReferences'] = [{'url': 'https://github.com/example/project/issues/11'}]
    save_inputs()
    _, ps, _ = call('writing-headings-and-empty-parent')
    check(len(ps) == 1
          and all(t in ps[0] for t in ('JOB_11', 'REPRO_11', 'EXP_11', 'ACT_11', 'CHG_11', 'POLICY_11', 'FILES_11', 'DOD_11', '## Out of scope', 'FOLLOWUP_AC_11'))
          and 'OUTSIDE_SECTION_11' not in ps[0] and '## 目的' not in ps[0],
          'writing.md headings and bodyless Out of scope parent wrapping AC are extracted while empty siblings/other sections stay excluded')
    check(ps[0].index('## Out of scope') < ps[0].index('FOLLOWUP_AC_11'),
          '## Out of scope heading precedes its child Acceptance Criteria in output')

    # Bodyless ## Out of scope parent survives even when earlier oversized background exhausts Tier-2 SUPP_LIMIT.
    issue_bodies[11] = (
        '## 背景\n' + ('背' * 6000) + '\n'
        '## Out of scope\n### Acceptance Criteria\n- [ ] FOLLOWUP_AC_OVERSIZE\n'
        '## 受け入れ条件\n- [ ] CURRENT_AC_11\n'
    )
    save_inputs()
    _, ps, _ = call('empty-parent-under-supp-cap')
    check(len(ps) == 1 and '## Out of scope' in ps[0] and 'FOLLOWUP_AC_OVERSIZE' in ps[0] and 'CURRENT_AC_11' in ps[0]
          and ps[0].index('## Out of scope') < ps[0].index('FOLLOWUP_AC_OVERSIZE'),
          '## Out of scope parent wrapping child AC survives even after Tier-2 SUPP_LIMIT truncation')

    # Global AC-first allocation across multiple Issues: early huge backgrounds must not starve later Issue AC.
    for n in range(14, 18):
        issue_bodies[n] = '## 背景\n' + ('Z' * 13000) + '\n'
    issue_bodies[18] = '## 受け入れ条件\n- [ ] LATE_ISSUE_AC\n'
    pr['title'] = 'feat: multi issue budget'
    pr['body'] = '\n'.join(f'Closes {ref}{n}' for n in range(14, 19)) + '\n'
    pr['closingIssuesReferences'] = [{'url': f'https://github.com/example/project/issues/{n}'} for n in range(14, 19)]
    save_inputs()
    multi_out, ps, _ = call('multi-issue-global-ac')
    multi_ctx = (multi_out / '.review-ac-context.txt').read_text()
    check(len(ps) == 1 and 'LATE_ISSUE_AC' in ps[0] and len(multi_ctx.encode('utf-8')) <= 50000,
          'global AC-first allocation protects late Issue AC when earlier Issues have huge backgrounds')
finally:
    for extra_n in range(14, 19):
        (data / f'{extra_n}.json').unlink(missing_ok=True)
    pr.clear()
    pr.update(orig_pr)
    issue_bodies.clear()
    issue_bodies.update(orig_bodies)
    save_inputs()
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
