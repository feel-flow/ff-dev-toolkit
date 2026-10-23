#!/usr/bin/env python3
"""Static, local documentation audit; never invokes GitHub or interprets shell.

The signature binds an adjacent explanation to its paragraph/table/fence, not to a
line number or to a runtime capability. Meaning still requires human review.
"""
import hashlib
import re
import sys
from pathlib import Path

CONTROLS = set('ace-curate close-issue create-issue init-docs knowledge-lookup '
               'merge-cleanup multi-review out-of-scope-issue refine-issue '
               'retrospective setup-ai-config setup-github-labels workflow-doctor'.split())
GH = re.compile(r'(?<![\w/-])gh(?![\w/-])')
MARKER = re.compile(r'^\s*<!--([0-9a-f]{16})-->$')
NOTE = re.compile(r'^\s*(MCP|分類): (.+)$')
COMMAND = re.compile(r'\bgh\s+(issue|pr|label|repo|api|auth|run)(?:\s+([a-z][a-z-]*))?')
KNOWN = {'issue': {'view', 'list', 'create', 'edit', 'comment', 'close', 'reopen'},
         'pr': {'view', 'list', 'diff', 'checkout', 'edit', 'merge', 'create', 'ready', 'checks'},
         'label': {'list', 'create', 'edit'}, 'repo': {'view'},
         'auth': {'status', 'login', 'setup-git', 'token'}, 'run': {'list'}}


def signature(text):
    return hashlib.sha256(text.replace('\r\n', '\n').encode()).hexdigest()[:16]


def blocks(text):
    """Return paragraph/table/fence units, including executable fence contents.

    Blank lines inside a fence do not split it. Backticks/tilde, longer closers,
    CRLF, nested shorter fences and unclosed fences follow the old scanner rule.
    The old path scanner remains separate and continues to exclude all fences.
    """
    lines = text.splitlines()
    start = 0
    if lines and lines[0] == '---':
        try:
            start = lines.index('---', 1) + 1
        except ValueError:
            return [], ['FRONTMATTER_UNCLOSED']
    result, current, opened = [], [], None
    begin = start
    for i in range(start, len(lines)):
        line = lines[i]
        fence = re.match(r'^\s*(`{3,}|~{3,})(.*)$', line)
        if opened:
            current.append(line)
            if fence and fence[1][0] == opened[0] and len(fence[1]) >= len(opened) and not fence[2].strip():
                result.append((begin, i + 1, '\n'.join(current)))
                current, opened = [], None
        elif fence:
            if current:
                result.append((begin, i, '\n'.join(current)))
            current, opened, begin = [line], fence[1], i
        elif not line.strip() or line.startswith('#') or MARKER.fullmatch(line) or NOTE.fullmatch(line):
            if current:
                result.append((begin, i, '\n'.join(current)))
                current = []
        else:
            if not current:
                begin = i
            current.append(line)
    if current:
        result.append((begin, len(lines), '\n'.join(current)))
    return result, ['UNCLOSED_FENCE'] if opened else []


def operation(text):
    found = list(COMMAND.finditer(text))
    return ','.join(dict.fromkeys('gh ' + m[1] + (' ' + m[2] if m[2] else '') for m in found)) or 'gh-context'


def consumer_route(unit):
    """Known copied-route regressions; callers also require live trigger hits."""
    if 'additions,deletions,commits,reviews' in unit:
        return 'effort-evidence', ('additions', 'deletions', 'commits', 'reviews', 'effort_evidence')
    if '--deploy-check' in unit and 'gh issue view' in unit:
        return 'deploy-check', ('body', 'BODY_ORIG', '--deploy-check', 'effort_deploy=unavailable', '継続')
    if 'knowledge-commit probe' in unit and 'gh api' in unit:
        return 'knowledge-protection', ('knowledge.repo', 'knowledge.classic-protection', 'knowledge.rulesets', '--github-input', 'unknown')
    return None, ()


def audit_document(path, text):
    if text is None:
        return [f'{path}:gh-context:UNREADABLE'], 0
    units, errors = blocks(text)
    errors = [f'{path}:gh-context:{e}' for e in errors]
    lines = text.splitlines()
    used, count = set(), 0
    for begin, end, unit in units:
        if not GH.search(unit):
            continue
        count += 1
        op = operation(unit)
        prefix = f'{path}:{begin + 1}:{op}:'
        j = end
        while j < len(lines) and not lines[j].strip():
            j += 1
        marker = MARKER.fullmatch(lines[j]) if j < len(lines) else None
        match = NOTE.fullmatch(lines[j + 1]) if marker and j + 1 < len(lines) else None
        if not match or not marker:
            errors.append(prefix + 'MISSING_ADJACENT_ROUTE')
            continue
        used.update((j, j + 1))
        if marker[1] != signature(unit):
            errors.append(prefix + 'SOURCE_CHANGED')
            continue
        kind, note = match[1], match[2]
        if kind == '分類':
            category, _, reason = note.partition(': ')
            valid = category in {'非操作', '禁止例', 'CLI固有'} and len(reason) >= 12
            if category == 'CLI固有':
                valid &= any(s in path for s in ('gh-auth-doctor/', 'check-plugin-versions/', 'setup-github-labels/'))
                valid &= 'MCP' in reason and ('代替' in reason or '復旧' in reason)
            elif category == '禁止例':
                valid &= bool(re.search(r'禁止|使わない|実行しない|secret|旧文言|否定|組み立てない|例示', unit))
            elif category == '非操作':
                valid &= not COMMAND.search(unit) or bool(re.search(r'過去|読まなかった|発火|痕跡|read-only|例示|禁止|叩かない|旧文言|の\*\*前', unit))
            if not valid:
                errors.append(prefix + 'INVALID_CLASSIFICATION')
            continue
        # Each dimension must carry concrete content. A bare MCP mention or
        # labels with generic "対応する" text do not constitute an alternative.
        for label in ('取得値', '形式', '渡し先', '不足時'):
            value = re.search(label + r': ([^。]+)', note)
            if not value or len(value[1]) < 8 or not re.search(r'[A-Za-z0-9_/<@]', value[1]):
                errors.append(prefix + 'MISSING_' + label)
        if 'MCP' not in note or not re.search(r'停止|SKIP|未確認|unknown|unavailable|省略', note):
            errors.append(prefix + 'MISSING_FAILURE_POLICY')
        read = re.search(r'取得値: ([^。]+)', note)
        destination = re.search(r'渡し先: ([^。]+)', note)
        if not read or not re.search(r'number|body|state|title|head|oid|OID|raw|label|login|comment|thread|repo|PR|SHA|diff', read[1]):
            errors.append(prefix + 'GENERIC_READ')
        if not destination or not re.search(r'_[a-z]+|[a-z]+\.sh|--[a-z]+|precheck|AC|owner|PLAN|PR_NUMBER|PR\b|Issue|SUGGEST|Git|手順7|MCP merge|read-only|抽出|候補|判断|見積|統合|照合|報告|SSOT|knowledge-commit|repo / num|6観点|label.*作成|実測|判定|反映', destination[1]):
            errors.append(prefix + 'GENERIC_DESTINATION')
        # Concrete regressions: adjacent notes copied from unrelated operations.
        # These consumer checks do not claim general semantic equivalence.
        _, required = consumer_route(unit)
        if any(value not in note for value in required):
            errors.append(prefix + 'WRONG_OPERATION_ROUTE')
        for command in COMMAND.finditer(unit):
            family, verb = command[1], command[2]
            if family != 'api' and verb and verb not in KNOWN[family]:
                errors.append(prefix + 'UNKNOWN_OPERATION')
        if re.search(r'\bgh\s+(?!issue\b|pr\b|label\b|repo\b|api\b|auth\b|run\b)[a-z][a-z-]*\b', unit):
            errors.append(prefix + 'UNKNOWN_OPERATION')
    for i, line in enumerate(lines):
        if (NOTE.fullmatch(line) or MARKER.fullmatch(line)) and i not in used:
            errors.append(f'{path}:{i + 1}:gh-context:ORPHAN_ROUTE')
    return errors, count


def audit_tree(root):
    skills = sorted((root / 'skills').glob('*/SKILL.md'))
    errors, total, documents, consumers = [], 0, [], set()
    if not skills:
        return ['skills:gh-context:EMPTY_SKILL_SET'], 0, 0
    names = {p.parent.name for p in skills}
    for name in sorted(CONTROLS - names):
        errors.append(f'skills/{name}/SKILL.md:gh-context:MISSING_REQUIRED_SKILL')
    targets = set()
    for skill in skills:
        try:
            if not skill.stat().st_mode & 0o444:
                raise OSError('no read bit')
            text = skill.read_text()
        except (OSError, UnicodeError):
            errors.append(f'{skill.relative_to(root)}:gh-context:UNREADABLE')
            continue
        references = sorted(skill.parent.glob('references/**/*.md'))
        if GH.search(re.sub(r'\A---\n.*?\n---\n', '', text, flags=re.S)) or skill.parent.name in CONTROLS:
            targets.add(skill)
            targets.update(references)
        else:
            # Progressive disclosure can put every GitHub operation in a ref.
            for reference in references:
                try:
                    if not reference.stat().st_mode & 0o444:
                        raise OSError('no read bit')
                    reference_text = reference.read_text()
                except (OSError, UnicodeError):
                    errors.append(f'{reference.relative_to(root)}:gh-context:UNREADABLE')
                    continue
                if GH.search(reference_text):
                    targets.add(reference)
    for path in sorted(targets):
        label = str(path.relative_to(root))
        try:
            if not path.stat().st_mode & 0o444:
                raise OSError('no read bit')
            text = path.read_text()
        except (OSError, UnicodeError):
            text = None
        if text is not None and len(text.strip()) < 80:
            errors.append(f'{label}:gh-context:EMPTY_OR_STUB_DOCUMENT')
        found, count = audit_document(label, text)
        errors.extend(found)
        if text is not None:
            consumers.update((label, consumer_route(unit)[0]) for _, _, unit in blocks(text)[0] if GH.search(unit))
        if text is not None and 'references' in path.parts:
            for _, _, unit in blocks(text)[0]:
                if re.match(r'^\s*(`{3,}|~{3,})', unit):
                    continue
                prose = re.sub(r'`[^`]*`', '', unit)
                for destination in re.findall(r'\[[^\]]+\]\(([^ )]+)\)', prose):
                    relative = destination.split('#', 1)[0]
                    # Parameterized documentation examples are not concrete paths.
                    if (not relative or re.match(r'^[\w+.-]+:', relative)
                            or any(c in relative for c in '<>{}')):
                        continue
                    if relative.endswith('.md'):
                        target = (path.parent / relative).resolve()
                        try:
                            target.relative_to(root.resolve())
                        except ValueError:
                            errors.append(f'{label}:references:ESCAPES_PLUGIN_ROOT')
                            continue
                        if not target.is_file():
                            errors.append(f'{label}:references:MISSING_RELATIVE_TARGET')
        if path.name == 'SKILL.md' and path.parent.name in CONTROLS and text is not None and count == 0:
            errors.append(f'{label}:gh-context:ZERO_GH_UNITS')
        total += count
        documents.append(label)
    if total == 0:
        errors.append('skills:gh-context:ZERO_GH_UNITS')
    for relative, key in (
            ('skills/close-issue/references/effort.md', 'effort-evidence'),
            ('skills/close-issue/references/effort.md', 'deploy-check'),
            ('skills/ace-curate/references/curate.md', 'knowledge-protection')):
        if (relative, key) not in consumers:
            errors.append(f'{relative}:gh-context:MISSING_CONSUMER_OPERATION_{key}')
    # A reference that still exists by name must retain the actual merge
    # contract. This does not assert that any connector executed it live.
    contracts = {
        'skills/close-issue/references/merge-gate.md': ('## MCP merge', '### raw と writer の受け渡し'),
        'docs-template/05-operations/deployment/git-workflow.md': ('#### gh 不在時の MCP merge', '#### `--delete-branch`'),
    }
    needles = ('repository_full_name', 'pr_number', 'expected_head_sha', 'merge_method',
               'commit_title', 'commit_message', 'host', 'port', 'parse/eval/unquote',
               '2a/2b', 'merged=true', 'finish-delete-merged-head.sh', 'fork', 'lease', '停止')
    for relative, (start, stop) in contracts.items():
        path = root / relative
        try:
            text = path.read_text()
        except (OSError, UnicodeError):
            errors.append(f'{relative}:mcp-merge:UNREADABLE')
            continue
        if text.count(start) != 1 or stop not in text.split(start, 1)[-1]:
            errors.append(f'{relative}:mcp-merge:MISSING_SECTION')
            continue
        section = text.split(start, 1)[1].split(stop, 1)[0]
        for needle in needles:
            if needle not in section:
                errors.append(f'{relative}:mcp-merge:MISSING_{needle}')
    return errors, total, len(documents)


if __name__ == '__main__':
    errors, total, documents = audit_tree(Path(sys.argv[1]))
    for error in errors:
        print(error)
    print(f'github-routes: documents={documents} gh-units={total} errors={len(errors)}')
    sys.exit(bool(errors))
