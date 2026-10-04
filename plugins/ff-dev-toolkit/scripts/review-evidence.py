#!/usr/bin/env python3
"""Producer-owned review evidence. Local provenance, not a signed attestation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid


def git(*args, allow_empty=False):
    result = subprocess.run(['git', *args], capture_output=True, text=True)
    if result.returncode and not (allow_empty and result.returncode == 1):
        # Ref/operation diagnostics, never remote values or command arguments.
        raise ValueError('git operation failed: ' + args[0])
    return result.stdout.strip()


def ancestor(old, new):
    result = subprocess.run(['git', 'merge-base', '--is-ancestor', old, new],
                            capture_output=True)
    if result.returncode:
        raise ValueError('previous review HEAD is not a readable ancestor')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + '.' + uuid.uuid4().hex)
    try:
        tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
        tmp.chmod(0o600)
        os.replace(tmp, target)
    finally:
        tmp.unlink(missing_ok=True)


def subject(base, output):
    root = git('rev-parse', '--show-toplevel')
    branch = git('branch', '--show-current')
    if not branch:
        raise ValueError('review evidence requires a branch')
    if Path(output).resolve() == Path(root).resolve():
        raise ValueError('output directory must not be the repository root')
    # Only ignored/external output is clean; tracked changes must never be excluded.
    status = git('-C', root, 'status', '--porcelain', '--untracked-files=all', '--', ':(top)**')
    if status:
        raise ValueError('review evidence requires a clean worktree; commit changes and gitignore the output directory or use an external --output-dir')
    return dict(root=root, branch=branch, head=git('rev-parse', 'HEAD'),
                base_ref=base, base=git('rev-parse', '--verify', base + '^{commit}'),
                remotes=git('config', '--get-regexp', r'^remote\..*\.(url|pushurl)$', allow_empty=True),
                diff=hashlib.sha256(subprocess.check_output(
                    ['git', 'diff', '--binary', base + '...HEAD'])).hexdigest())


def tasks_csv(value):
    values = value.split(',') if value else []
    if any(not x or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in x)
           for x in values):
        raise ValueError('invalid required perspectives')
    return set(values)


def inspect(record, seen=None):
    """Validate archived lineage; never infer successful tasks from Markdown prose."""
    seen = set() if seen is None else set(seen)
    if not isinstance(record, dict) or record.get('schema') != 1:
        raise ValueError('missing/unknown review evidence schema')
    rid = record['id']
    if rid in seen:
        raise ValueError('cyclic review evidence')
    seen.add(rid)
    if digest(record['report']) != record['report_sha256']:
        raise ValueError('review report changed')
    text = Path(record['report']).read_text()
    if text.splitlines()[0] != '# Multi-CLI Review — Integrated Report':
        raise ValueError('not an integrated review report')
    if '<!-- CRITICAL_BLOCK -->' in text.splitlines():
        raise ValueError('blocking Critical in review evidence')
    plan, results = record['plan'], record['results']
    if not plan or len(set(plan)) != len(plan) or set(plan) != set(results):
        raise ValueError('review evidence has missing/duplicate planned tasks')
    complete = set()
    for task, state in results.items():
        if state == 'complete':
            complete.add(task.split(':', 1)[1])
        elif state != 'unavailable':
            raise ValueError('incomplete review task: ' + task)
    if 'unavailable' in results.values():
        main = record['main']
        main_tasks = [task for task in plan if task.split(':', 1)[0] == main]
        if not main or not main_tasks or any(results[task] != 'complete' for task in main_tasks):
            raise ValueError('unavailable sub-CLI has no completed main review')
        if any(state == 'unavailable' and task.split(':', 1)[0] == main
               for task, state in results.items()):
            raise ValueError('main reviewer cannot be waived')
    if not complete:
        raise ValueError('no completed review tasks')
    complete |= {task.split(':', 1)[1] for task, state in results.items() if state == 'unavailable'}
    prior = record.get('prior')
    if prior:
        inspect(prior, seen)
        if prior['subject'] != record['subject'] or prior['finished_ns'] > record['started_ns']:
            raise ValueError('prior review order/subject mismatch')
    parent = record.get('parent')
    if parent:
        previous = inspect(parent, seen)
        for key in ('root', 'branch', 'base_ref', 'base', 'remotes'):
            if parent['subject'][key] != record['subject'][key]:
                raise ValueError('partial review lineage changed ' + key)
        ancestor(parent['subject']['head'], record['subject']['head'])
        if parent['finished_ns'] > record['started_ns'] or not complete <= previous:
            raise ValueError('partial review has no matching full-review coverage')
        # Boundary reviews require a fresh prior review at every new HEAD.
        if parent.get('prior') and not prior:
            raise ValueError('partial review lost required prior review')
        complete |= previous
    return complete


def verify(record, args, historical=False):
    coverage = inspect(record)
    current = subject(record['subject']['base_ref'], args.output)
    if historical:
        for key in ('root', 'branch', 'base_ref', 'base', 'remotes'):
            if current[key] != record['subject'][key]:
                raise ValueError('previous review subject changed ' + key)
        ancestor(record['subject']['head'], current['head'])
    elif current != record['subject']:
        raise ValueError('review evidence does not match current HEAD/base/repository')
    if args.base and git('rev-parse', args.base + '^{commit}') != record['subject']['base']:
        raise ValueError('review evidence base mismatch')
    if not tasks_csv(args.required) <= coverage:
        raise ValueError('missing required review perspectives')
    if args.prior_required:
        if not record.get('prior') or not tasks_csv(args.prior_required) <= inspect(record['prior']):
            raise ValueError('missing required prior review perspectives')
    return coverage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['begin', 'finish', 'verify'])
    parser.add_argument('--file', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--base', default='')
    parser.add_argument('--plan', default='')
    parser.add_argument('--main', default='')
    parser.add_argument('--results', default='')
    parser.add_argument('--prior', default='')
    parser.add_argument('--parent', default='')
    parser.add_argument('--required', default='')
    parser.add_argument('--prior-required', default='')
    args = parser.parse_args()
    if args.action == 'begin':
        prior = load(args.prior) if args.prior else None
        parent = load(args.parent) if args.parent else None
        if prior:
            verify(prior, args)
        if parent:
            verify(parent, args, historical=True)
        plan = args.plan.split()
        if not plan or len(set(plan)) != len(plan) or any(
                len(task.split(':')) != 2 or not all(task.split(':')) for task in plan):
            raise ValueError('missing review plan')
        write(args.file, dict(schema=1, id=uuid.uuid4().hex,
                             subject=subject(args.base, args.output), plan=plan, main=args.main,
                             prior=prior, parent=parent, started_ns=time.time_ns()))
    elif args.action == 'finish':
        record = load(args.file)
        if subject(record['subject']['base_ref'], args.output) != record['subject']:
            raise ValueError('repository changed during review')
        rows = [row.split('\t') for row in Path(args.results).read_text().splitlines()]
        if any(len(row) != 2 for row in rows) or len({row[0] for row in rows}) != len(rows):
            raise ValueError('invalid/duplicate task result')
        report = Path(args.output) / 'integrated-report.md'
        archive = Path(args.output) / '.evidence' / record['id'] / 'report.md'
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(report.read_bytes())
        archive.chmod(0o600)
        record.update(results=dict(rows), report=str(archive.resolve()),
                      source_report=str(report.resolve()), report_sha256=digest(archive),
                      finished_ns=time.time_ns())
        # Record unsuccessful runs too; verify refuses them. Never reuse previous success.
        write(Path(args.output) / 'review-evidence.json', record)
    else:
        record = load(args.file)
        coverage = verify(record, args)
        if Path(record['source_report']).resolve() != (Path(args.output) / 'integrated-report.md').resolve():
            raise ValueError('review evidence report path mismatch')
        if digest(record['source_report']) != record['report_sha256']:
            raise ValueError('current integrated report changed')
        print(','.join(sorted(coverage)))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, IndexError, TypeError, OSError,
            subprocess.CalledProcessError) as error:
        print('ERROR: review evidence: ' + str(error), file=sys.stderr)
        sys.exit(1)
