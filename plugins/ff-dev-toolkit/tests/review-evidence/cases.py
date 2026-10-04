import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/review-evidence.py'

class Evidence(unittest.TestCase):
    def setUp(self):
        for name in list(os.environ):
            if name.startswith('GIT_'):
                os.environ.pop(name)
        os.environ.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
        self.tmp = Path(tempfile.mkdtemp())
        self.before = os.getcwd()
        os.chdir(self.tmp)
        self.git('init', '-q', '-b', 'develop')
        self.git('config', 'user.name', 'fixture')
        self.git('config', 'user.email', 'fixture@example.test')
        self.git('remote', 'add', 'origin', 'https://github.com/example/fixture.git')
        Path('.gitignore').write_text('.review-results/\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.git('switch', '-qc', 'feature/test')
        self.git('commit', '-qm', 'change', '--allow-empty')
        self.output = self.tmp / '.review-results'
        self.output.mkdir()
        self.file = self.output / 'start.json'
        self.receipt = self.output / 'review-evidence.json'

    def tearDown(self):
        os.chdir(self.before)
        shutil.rmtree(self.tmp)

    def git(self, *args):
        subprocess.check_call(['git', *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def call(self, action, *args, success=True):
        result = subprocess.run(['python3', str(SCRIPT), action, '--file', str(
            self.receipt if action == 'verify' else self.file), '--output', str(self.output),
            '--base', 'develop', *args], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def record(self, plan='codex-cli:code-review', results='codex-cli:code-review\tcomplete\n',
               extra=(), text='# Multi-CLI Review — Integrated Report\n\nvalid report\n'):
        self.call('begin', '--plan', plan, *extra)
        (self.output / 'integrated-report.md').write_text(text)
        (self.output / 'results').write_text(results)
        self.call('finish', '--results', str(self.output / 'results'))

    def mutate(self, fn):
        record = json.loads(self.receipt.read_text())
        fn(record)
        self.receipt.write_text(json.dumps(record))

    def test_producer_integration_and_prior_rejection(self):
        Path('file.txt').write_text('content')
        self.git('add', 'file.txt')
        self.git('commit', '-qm', 'real diff')
        stub = self.tmp.parent / ('evidence-stub-' + self.tmp.name)
        stub.mkdir()
        try:
            cli = stub / 'codex'
            cli.write_text('#!/bin/sh\ncat >/dev/null\nprintf "## Findings\\n- verdict: none\\n"\n')
            cli.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if not k.startswith(tuple('_'.join(parts) + '_' for parts in [
                ('MULTI', 'AGENT'), ('FF', 'DEV', 'TOOLKIT'), ('FF', 'REVIEW')]))}
            env.update(PATH=str(stub) + ':' + env['PATH'], FF_REVIEW_ROUND_LIMIT='0',
                       FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE='1')
            cmd = ['bash', str(SCRIPT.parent / 'multi-review.sh'), '--cli', 'codex-cli',
                   '--perspective', 'code-review', '--base', 'develop', '--evidence', '--fresh']
            result = subprocess.run(cmd, capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr[-4000:])
            self.call('verify', '--required', 'code-review')
            claude = stub / 'claude'
            claude.write_text(cli.read_text())
            claude.chmod(0o755)
            cli.write_text('#!/bin/sh\ncat >/dev/null\necho "ERROR: You have reached your usage limit for this period" >&2\nexit 1\n')
            pair = ['bash', str(SCRIPT.parent / 'multi-review.sh'), '--route', 'full',
                    '--base', 'develop', '--evidence', '--fresh']
            result = subprocess.run(pair, capture_output=True, text=True, env=env)
            states = json.loads(self.receipt.read_text())['results']
            self.assertEqual(states['codex-cli:comprehensive-review'], 'unavailable', result.stderr[-3000:])
            self.assertTrue(all(state == 'complete' for task, state in states.items() if task.startswith('claude-code:')))
            self.call('verify', '--required', 'code-review,comprehensive-review')
            cli.write_text('#!/bin/sh\ncat >/dev/null\necho "ordinary failure" >&2\nexit 1\n')
            subprocess.run(cmd, capture_output=True, text=True, env=env)
            self.assertEqual(json.loads(self.receipt.read_text())['results']['codex-cli:code-review'], 'incomplete')
            self.call('verify', success=False)
            self.git('commit', '-qm', 'different head', '--allow-empty')
            result = subprocess.run(cmd[:-1] + ['--require-prior-review', str(self.receipt)],
                                    capture_output=True, text=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('review evidence', result.stderr)
        finally:
            shutil.rmtree(stub)

    def test_subdirectory_dirty_sibling(self):
        Path('a').mkdir()
        Path('b').mkdir()
        self.record()
        Path('b/dirty').write_text('untracked')
        os.chdir('a')
        self.call('verify', success=False)

    def test_tracked_output_change_is_dirty(self):
        (self.output / 'tracked').write_text('tracked')
        self.git('add', '-f', '.review-results/tracked')
        self.git('commit', '-qm', 'tracked output')
        self.call('begin', '--plan', 'codex-cli:code-review')
        (self.output / 'tracked').write_text('changed')
        self.call('begin', '--plan', 'codex-cli:code-review', success=False)

    def test_external_output_and_no_remote(self):
        external = Path(tempfile.mkdtemp())
        try:
            self.output = external
            self.file = external / 'start.json'
            self.receipt = external / 'review-evidence.json'
            self.git('remote', 'remove', 'origin')
            self.record()
            self.call('verify', '--required', 'code-review')
        finally:
            shutil.rmtree(external)

    def test_schema_and_archive_required(self):
        for schema in (None, 2):
            self.record()
            self.mutate(lambda r: r.update(schema=schema))
            self.call('verify', success=False)
        self.record()
        Path(json.loads(self.receipt.read_text())['report']).unlink()
        self.call('verify', success=False)

    def test_missing_prior_and_coverage(self):
        self.record()
        self.call('verify', '--prior-required', 'security-analysis', success=False)
        prior = self.output / 'prior.json'
        shutil.copyfile(self.receipt, prior)
        self.record(extra=('--prior', str(prior)))
        self.call('verify', '--prior-required', 'security-analysis', success=False)

    def test_head_changed_during_run(self):
        self.call('begin', '--plan', 'codex-cli:code-review')
        (self.output / 'integrated-report.md').write_text('# Multi-CLI Review — Integrated Report\n')
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        self.git('commit', '-qm', 'changed during run', '--allow-empty')
        result = self.call('finish', '--results', str(self.output / 'results'), success=False)
        self.assertIn('repository changed during review', result.stderr)
        self.assertFalse(self.receipt.exists())

    def test_prior_cached_resume_and_fresh_continuation_rejected(self):
        runner = SCRIPT.parent / 'multi-agent.sh'
        for flags in (['--resume', '--require-prior-review', 'prior.json'],
                      ['--resume', '--continue-review', 'parent.json'],
                      ['--fresh', '--continue-review', 'parent.json'],
                      ['--fresh', '--require-prior-review', 'prior.json']):
            result = subprocess.run(['bash', str(runner), '--task', 'review', *flags],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('cannot be combined', result.stderr)

    def test_pass_and_untouched_report(self):
        self.record()
        self.call('verify', '--required', 'code-review')
        self.assertEqual((self.output / 'integrated-report.md').read_text(),
                         '# Multi-CLI Review — Integrated Report\n\nvalid report\n')

    def test_receipt_copied_to_another_output_is_rejected(self):
        self.record()
        source = self.receipt
        other = self.output / 'other'
        other.mkdir()
        self.output = other
        self.receipt = other / 'review-evidence.json'
        shutil.copyfile(source, self.receipt)
        (other / 'integrated-report.md').write_text(
            '# Multi-CLI Review — Integrated Report\n<!-- CRITICAL_BLOCK -->\n')
        result = self.call('verify', success=False)
        self.assertIn('review evidence report path mismatch', result.stderr)

    def test_resolved_output_alias_is_accepted(self):
        self.record()
        self.call('verify', '--output', '.review-results')
        alias = self.output / 'alias'
        alias.symlink_to(self.output, target_is_directory=True)
        self.call('verify', '--output', str(alias))

    def test_prior_and_parent_from_different_outputs(self):
        self.record()
        prior = self.receipt
        for name, extra in [('main', ('--prior', str(prior))),
                            ('partial', None)]:
            parent = self.receipt
            output = self.tmp / '.review-results' / name
            output.mkdir()
            self.output = output
            self.file = output / 'start.json'
            self.receipt = output / 'review-evidence.json'
            self.record(extra=extra if extra else (
                '--prior', str(prior), '--parent', str(parent)))
            self.call('verify', '--required', 'code-review', '--prior-required', 'code-review')

    def test_missing_evidence(self):
        self.call('verify', success=False)

    def test_missing_plan_and_result(self):
        self.call('begin', '--plan', '', success=False)
        self.record()
        self.mutate(lambda r: r['results'].clear())
        self.call('verify', success=False)

    def test_same_head_other_branch(self):
        self.record()
        self.git('switch', '-qc', 'other')
        self.call('verify', success=False)

    def test_stale_head_base_and_remote(self):
        for change in ('head', 'base', 'remote'):
            with self.subTest(change=change):
                self.record()
                if change == 'head':
                    self.git('commit', '-qm', 'fix', '--allow-empty')
                elif change == 'base':
                    self.git('branch', '-f', 'develop', 'HEAD')
                else:
                    self.git('remote', 'set-url', 'origin', 'https://github.com/other/repo.git')
                self.call('verify', success=False)

    def test_dirty(self):
        self.record()
        Path('dirty').write_text('new')
        self.call('verify', success=False)

    def test_mutated_report(self):
        self.record()
        (self.output / 'integrated-report.md').write_text('changed')
        self.call('verify', success=False)

    def test_incomplete_and_blocking_critical(self):
        self.record(results='codex-cli:code-review\tincomplete\n')
        self.call('verify', success=False)
        self.record(text='# Multi-CLI Review — Integrated Report\n<!-- CRITICAL_BLOCK -->\n')
        self.call('verify', success=False)

    def test_missing_perspective(self):
        self.record()
        self.call('verify', '--required', 'test-analysis', success=False)

    def test_prior_and_order(self):
        self.record(plan='codex-cli:security-analysis', results='codex-cli:security-analysis\tcomplete\n')
        prior = self.output / 'prior.json'
        shutil.copyfile(self.receipt, prior)
        self.record(extra=('--prior', str(prior)))
        self.call('verify', '--prior-required', 'security-analysis')
        self.mutate(lambda r: r['prior'].update(finished_ns=r['started_ns'] + 1))
        self.call('verify', success=False)

    def test_shared_prior_is_not_a_cycle(self):
        self.record()
        prior = self.output / 'prior.json'
        shutil.copyfile(self.receipt, prior)
        self.record(extra=('--prior', str(prior)))
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        self.record(extra=('--prior', str(prior), '--parent', str(parent)))
        self.call('verify', '--required', 'code-review', '--prior-required', 'code-review')
        self.mutate(lambda r: r['prior'].update(id=r['id']))
        self.call('verify', success=False)

    def test_partial_lineage(self):
        self.record(plan='codex-cli:code-review\ncodex-cli:comment-analysis',
                    results='codex-cli:code-review\tcomplete\ncodex-cli:comment-analysis\tcomplete\n')
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        self.git('commit', '-qm', 'fix', '--allow-empty')
        self.record(plan='codex-cli:comment-analysis', results='codex-cli:comment-analysis\tcomplete\n',
                    extra=('--parent', str(parent)))
        self.call('verify', '--required', 'code-review,comment-analysis')
        self.mutate(lambda r: r['parent']['subject'].update(base='0' * 40))
        self.call('verify', success=False)

    def test_partial_new_perspective_rejected(self):
        self.record()
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        self.git('commit', '-qm', 'fix', '--allow-empty')
        self.record(plan='codex-cli:test-analysis', results='codex-cli:test-analysis\tcomplete\n',
                    extra=('--parent', str(parent)))
        self.call('verify', success=False)

    def test_unavailable_main_and_sub(self):
        plan='claude-code:code-review\ncodex-cli:comprehensive-review'
        self.record(plan=plan, results='claude-code:code-review\tcomplete\ncodex-cli:comprehensive-review\tunavailable\n',
                    extra=('--main', 'claude-code'))
        self.call('verify', '--required', 'code-review')
        self.call('verify', '--required', 'comprehensive-review')
        self.mutate(lambda r: r.update(main='codex-cli'))
        self.call('verify', success=False)

if __name__ == '__main__':
    unittest.main()
