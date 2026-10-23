#!/usr/bin/env python3
"""Detector self-test: exact file/operation/reason, with positive decoy proof."""
import importlib.util
import re
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('routes', HERE / 'github_routes.py')
routes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routes)
passed = 0


def check(label, condition):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('  ✓ github-routes: ' + label)


fixture = (HERE / 'fixtures/github-route.md').read_text()
unit = next(u for _, _, u in routes.blocks(fixture)[0] if routes.GH.search(u))
route = ('<!--' + routes.signature(unit) + '-->\nMCP: '
         '取得値: MCP の Issue number/body/state。形式: 全文 JSON を保存。'
         '渡し先: AC の照合へ渡す。不足時: 必須の MCP field 不足は停止。')
clean = fixture.replace('ROUTE_PLACEHOLDER', route)
path = 'skills/example/SKILL.md'
errors, count = routes.audit_document(path, clean)
check('positive fixture actually contains executable gh and adjacent route', count == 1 and not errors and 'gh issue view 42' in clean)


def red(label, text, reason, op='gh issue view'):
    errors, _ = routes.audit_document(path, text)
    check(label, any(e.startswith(path + ':') and op + ':' in e and e.endswith(reason) for e in errors))


red('alternative missing', clean.replace(route, ''), 'MISSING_ADJACENT_ROUTE')
red('alternative moved to a different step', clean.replace(route, '') + '\n' + route + '\n', 'MISSING_ADJACENT_ROUTE')
red('same command name but arguments/body changed', clean.replace('number,body,state', 'number,title'), 'SOURCE_CHANGED')
quoted = unit.replace('--json number,body,state', '--json number,body,state --jq \'"a  b"\'')
quoted_note = route.replace(routes.signature(unit), routes.signature(quoted))
red('spaces inside a quoted argument change source identity', clean.replace(unit, quoted).replace(route, quoted_note).replace('a  b', 'a b'), 'SOURCE_CHANGED')
for field in ['取得値', '形式', '渡し先', '不足時']:
    red('missing ' + field, clean.replace(field + ': ', field + '-gone: '), 'MISSING_' + field)
generic = ('<!--' + routes.signature(unit) + '-->\nMCP: 取得値: MCPで同等操作を実施。'
           '形式: JSONの同等データを用意。渡し先: MCPへ同じものを渡す。'
           '不足時: MCP不足なら同様に停止。')
red('generic MCP/JSON wording carries no actual fields', clean.replace(route, generic), 'GENERIC_READ')
red('generic destination names no consumer', clean.replace(route, generic), 'GENERIC_DESTINATION')
red('unclosed long fence cannot swallow operations', clean.replace('```bash', '````bash', 1), 'UNCLOSED_FENCE', 'gh-context')
red('unreadable input is not zero matches', None, 'UNREADABLE', 'gh-context')
unknown_unit = unit.replace('gh issue view', 'gh issue destroy')
unknown_route = route.replace(routes.signature(unit), routes.signature(unknown_unit))
red('unknown action cannot inherit an old route', clean.replace(unit, unknown_unit).replace(route, unknown_route), 'UNKNOWN_OPERATION', 'gh issue destroy')
unknown_family = unit.replace('gh issue view', 'gh workflow run')
red('unknown command family is red even without option spelling', clean.replace(unit, unknown_family).replace(route, route.replace(routes.signature(unit), routes.signature(unknown_family))), 'UNKNOWN_OPERATION', 'gh-context')
for label, text in [('CRLF', clean.replace('\n', '\r\n')),
                    ('tilde fence', clean.replace('```', '~~~')),
                    ('long fence', clean.replace('```', '`````'))]:
    # A deliberate formatting change needs a new source signature; it must not
    # weaken the actual operation or move the explanation.
    changed_unit = next(u for _, _, u in routes.blocks(text)[0] if routes.GH.search(u))
    text = text.replace(routes.signature(unit), routes.signature(changed_unit))
    errors, count = routes.audit_document(path, text)
    check(label + ' actual operation preserved and accepted', count == 1 and 'gh issue view 42' in text and not errors)

decoy = ('This is a prohibited secret example: `gh auth token` (実行しない).')
excluded = decoy + '\n\n<!--' + routes.signature(decoy) + '-->\n分類: 禁止例: secret の例示であり取得指示ではない。MCP token 取得へ置換しない\n'
errors, count = routes.audit_document(path, excluded)
check('forbidden decoy exists and is correctly classified', count == 1 and 'gh auth token' in excluded and not errors)
active = decoy.replace('prohibited secret example:', 'command:').replace(' (実行しない)', '')
red('classification cannot survive changed operation context', excluded.replace(decoy, active), 'SOURCE_CHANGED', 'gh auth token')

root = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='ff-github-routes-') as directory:
    copy = Path(directory) / 'plugin'
    # Markdown resources only: no executable scripts/node_modules/Git/runtime.
    for relative in ['skills', 'docs-template', 'tests', 'scripts']:
        source = root / relative
        if source.is_dir():
            for file in source.rglob('*.md'):
                target = copy / file.relative_to(root)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(file, target)
        else:
            target = copy / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    errors, total, documents = routes.audit_tree(copy)
    check('live copy has real operation population and required controls', not errors and total > 0 and documents > 0)

    def mutation(relative, content, reason):
        file = copy / relative
        original = file.read_bytes()
        try:
            if content is None:
                file.unlink()
            else:
                file.write_text(content)
            errors, _, _ = routes.audit_tree(copy)
            check(relative + ' -> ' + reason, any(e.startswith(relative + ':') and e.endswith(reason) for e in errors))
        finally:
            file.write_bytes(original)

    ref_skill = copy / 'skills/reference-only/SKILL.md'
    ref_skill.parent.mkdir()
    ref_skill.write_text('# Reference-only skill\n\nRead [the operation](references/nested/operation.md).\n')
    ref = ref_skill.parent / 'references/nested/operation.md'
    ref.parent.mkdir(parents=True)
    ref.write_text(clean)
    errors, reference_total, _ = routes.audit_tree(copy)
    check('non-control nested reference-only operation is discovered', not errors and reference_total == total + 1)
    mutation(str(ref.relative_to(copy)), clean.replace(route, ''), 'MISSING_ADJACENT_ROUTE')
    link_examples = (clean + '\n\n````markdown\n[fenced](../missing-fenced.md)\n````\n\n'
                     '`[inline](../missing-inline.md)`\n\n[template](../<category>.md)\n\n'
                     '[actual](../../../close-issue/references/merge-gate.md#github-file-input)\n')
    ref.write_text(link_examples)
    errors, _, _ = routes.audit_tree(copy)
    check('real relative target and fenced/inline/parameterized link decoys remain green', not errors and all(
        token in ref.read_text() for token in ('missing-fenced.md', 'missing-inline.md', '<category>.md', '#github-file-input')))

    wrong_note = ('MCP: 取得値: MCP PR diff/body/state を取得。形式: 全文 JSON を保存。'
                  '渡し先: AC の照合へ渡す。不足時: 必須の MCP field 不足は停止。')
    for relative, start in [
            ('skills/close-issue/references/effort.md', 'MCP: 取得値: MCP で同じ PR の additions'),
            ('skills/close-issue/references/effort.md', 'MCP: 取得値: MCP で同じ Issue の body'),
            ('skills/ace-curate/references/curate.md', 'MCP: 取得値: MCP の repo nameWithOwner')]:
        text = (copy / relative).read_text()
        note_line = next(line for line in text.splitlines() if line.startswith(start))
        mutation(relative, text.replace(note_line, wrong_note), 'WRONG_OPERATION_ROUTE')
    relative = 'skills/merge-cleanup/references/steps.md'
    text = (copy / relative).read_text()
    mutation(relative, text.replace('../../close-issue/references/merge-gate.md', '../close-issue/references/merge-gate.md'), 'MISSING_RELATIVE_TARGET')
    outside = Path(directory) / 'outside.md'
    outside.write_text('# Existing file outside the plugin\n')
    mutation(str(ref.relative_to(copy)), link_examples + '\n[outside](../../../../../outside.md)\n', 'ESCAPES_PLUGIN_ROOT')
    for relative, before, after, key in [
            ('skills/close-issue/references/effort.md', 'additions,deletions,commits,reviews', 'commits,additions,deletions,reviews', 'effort-evidence'),
            ('skills/close-issue/references/effort.md', '--deploy-check', '--deployment-check', 'deploy-check'),
            ('skills/ace-curate/references/curate.md', 'knowledge-commit probe', 'knowledge-commit  probe', 'knowledge-protection')]:
        text = (copy / relative).read_text()
        unit = next(unit for _, _, unit in routes.blocks(text)[0] if before in unit)
        changed = unit.replace(before, after)
        text = text.replace(unit, changed).replace(routes.signature(unit), routes.signature(changed))
        if key == 'effort-evidence':
            note = next(line for line in text.splitlines() if line.startswith('MCP: 取得値: MCP で同じ PR の additions'))
            bad_merge = ('MCP: 取得値: MCP PR head / subject / body を取得。形式: merge_pull_request の構造化引数。'
                         '渡し先: merge_pull_request へ渡す。不足時: MCP 必須値不足は停止。')
            text = text.replace(note, bad_merge)
        mutation(relative, text, 'MISSING_CONSUMER_OPERATION_' + key)

    mutation('skills/create-issue/SKILL.md', None, 'MISSING_REQUIRED_SKILL')
    mutation('skills/create-issue/SKILL.md', '', 'EMPTY_OR_STUB_DOCUMENT')
    mutation('skills/create-issue/SKILL.md', '# Command removed\n\n' + 'No executable operation. ' * 8, 'ZERO_GH_UNITS')
    mutation('skills/close-issue/references/merge-gate.md', '# MCP merge\n', 'EMPTY_OR_STUB_DOCUMENT')
    workflow = copy / 'docs-template/05-operations/deployment/git-workflow.md'
    mutation(str(workflow.relative_to(copy)), workflow.read_text().replace('expected_head_sha', 'same-name-but-empty'), 'MISSING_expected_head_sha')
    unreadable = copy / 'skills/knowledge-lookup/SKILL.md'
    unreadable.chmod(0)
    errors, _, _ = routes.audit_tree(copy)
    check('unreadable target cannot disappear under privileged test runner', any(e == 'skills/knowledge-lookup/SKILL.md:gh-context:UNREADABLE' for e in errors))
    unreadable.chmod(0o644)
    empty = Path(directory) / 'empty'
    empty.mkdir()
    errors, _, _ = routes.audit_tree(empty)
    check('empty skill collection is red', errors == ['skills:gh-context:EMPTY_SKILL_SET'])
    # Retain the controls by name but remove all executable/mention targets.
    for file in (copy / 'skills').rglob('*.md'):
        file.write_text('# Empty operation population\n\n' + 'No GitHub command here. ' * 6 + '\n')
    errors, total, _ = routes.audit_tree(copy)
    check('zero matches is red even with all skill names retained', total == 0 and 'skills:gh-context:ZERO_GH_UNITS' in errors)
print(f'github-routes self-test: {passed} passed')
