import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/review-evidence.py'
REPORT = '# Multi-CLI Review — Integrated Report\n\nvalid report\n'


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

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

    def mutate(self, fn, path=None):
        path = path or self.receipt
        record = json.loads(path.read_text())
        fn(record)
        path.write_text(json.dumps(record))

    def commit_diff(self):
        Path('file.txt').write_text('content')
        # The pinned producer runs as `python3 -` (stdin) from the reviewed repository, whose
        # cwd would shadow the standard library without isolation (-I).
        Path('json.py').write_text('raise SystemExit("standard library shadowed by the reviewed repository")\n')
        self.git('add', 'file.txt', 'json.py')
        self.git('commit', '-qm', 'real diff')

    def plugin_copy(self, name):
        """The installed layout a review run reads, outside the repo and the output dir."""
        source = SCRIPT.parents[1]
        base = self.tmp.parent / ('evidence-roots-' + self.tmp.name)
        if not base.exists():
            base.mkdir()
            self.addCleanup(shutil.rmtree, base, True)
        root = base / name
        shutil.copytree(source / 'scripts', root / 'scripts')
        (root / '.claude-plugin').mkdir()
        shutil.copy2(source / '.claude-plugin/plugin.json', root / '.claude-plugin/plugin.json')
        (root / 'tests/lib').mkdir(parents=True)
        shutil.copy2(source / 'tests/lib/review-round-counter.sh', root / 'tests/lib')
        return root

    def stub(self, name, delete=None, rewrite=None):
        """codex stub: counts review calls (`codex exec`). On the first one, before printing its
        findings, it removes `delete` or overwrites the file `rewrite` in place."""
        stub = self.tmp.parent / ('evidence-stub-' + self.tmp.name + '-' + name)
        stub.mkdir()
        self.addCleanup(shutil.rmtree, stub, True)
        count, marker = stub / 'review-calls', stub / 'root-changed'
        if delete:
            change = 'rm -rf %s' % shlex.quote(str(delete))
        elif rewrite:
            change = "printf 'raise SystemExit(\"rewritten producer ran\")\\n' > %s" % shlex.quote(str(rewrite))
        remove = ('if [ ! -e %s ]; then %s && : > %s; fi\n' % (
            shlex.quote(str(marker)), change, shlex.quote(str(marker)))) if delete or rewrite else ''
        cli = stub / 'bin/codex'
        cli.parent.mkdir()
        cli.write_text('#!/bin/sh\ncat >/dev/null\nif [ "$1" = exec ]; then\nprintf x >> %s\n%sfi\n'
                       'printf "## Findings\\n- verdict: none\\n"\n' % (shlex.quote(str(count)), remove))
        cli.chmod(0o755)
        return cli.parent, count, marker

    def review(self, root, stub_bin, *extra):
        # Scrub every handoff the start guard compares (this suite also runs inside a host
        # session), then hand over the root under test the way a skill does.
        env = {k: v for k, v in os.environ.items() if not k.startswith(tuple('_'.join(parts) + '_' for parts in [
            ('MULTI', 'AGENT'), ('FF', 'DEV', 'TOOLKIT'), ('FF', 'REVIEW')]))
               and k not in ('CLAUDE_PLUGIN_ROOT', 'GROK_PLUGIN_ROOT')}
        env.update(PATH=str(stub_bin) + ':' + env['PATH'], FF_REVIEW_ROUND_LIMIT='0',
                   FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE='1', FF_DEV_TOOLKIT_ROOT=str(root))
        cmd = ['bash', str(root / 'scripts/multi-review.sh'), '--cli', 'codex-cli',
               '--perspective', 'code-review', '--base', 'develop', '--evidence', *extra]
        return subprocess.run(cmd, capture_output=True, text=True, env=env)

    def test_root_removed_after_the_last_cli_still_issues_evidence(self):
        # The host updated the plugin and deleted the start-time cache once the CLIs ran. The
        # stub removes the root during the only CLI call, before it prints its findings — a
        # stricter point than "after every CLI finished". Keep the plan to one task so that
        # call is the last one. The finish must run from the producer bytes pinned at start.
        self.commit_diff()
        root = self.plugin_copy('installed')
        stub_bin, count, marker = self.stub('vanish', delete=root)
        result = self.review(root, stub_bin, '--fresh')
        self.assertTrue(marker.exists(), 'the stub never removed the root: ' + result.stderr[-3000:])
        self.assertFalse(root.exists())
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        self.assertEqual(count.read_text(), 'x')
        self.assertIn('changed while it ran', result.stderr)
        self.assertIn('/installed/scripts/review-evidence.py is gone', result.stderr)
        self.assertIn('re-invoke the skill', result.stderr)
        self.assertNotIn("can't open file", result.stderr)
        self.assertNotIn('typo?', result.stderr)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['producer_sha256'], sha256(SCRIPT))
        self.assertEqual(receipt['results'], {'codex-cli:code-review': 'complete'})
        self.assertEqual(receipt['plan'], ['codex-cli:code-review'])
        self.assertEqual(receipt['subject']['head'], subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], text=True).strip())
        self.assertEqual(receipt['report_sha256'], sha256(self.output / 'integrated-report.md'))
        # The same verifier accepts it as it accepts any other receipt.
        self.call('verify', '--required', 'code-review')

    def test_producer_rewritten_in_place_is_not_run(self):
        # The path survives but its bytes change (an in-place update). A finish that ran the
        # path again would run the rewritten file; the pinned bytes must run instead.
        self.commit_diff()
        root = self.plugin_copy('installed')
        producer = root / 'scripts/review-evidence.py'
        stub_bin, _, marker = self.stub('rewrite', rewrite=producer)
        result = self.review(root, stub_bin, '--fresh')
        self.assertTrue(marker.exists(), 'the stub never rewrote the producer: ' + result.stderr[-3000:])
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        self.assertNotIn('rewritten producer ran', result.stderr)
        self.assertIn('/installed/scripts/review-evidence.py no longer reads back as the bytes read at start',
                      result.stderr)
        self.assertEqual(json.loads(self.receipt.read_text())['producer_sha256'], sha256(SCRIPT))
        self.call('verify', '--required', 'code-review')

    def test_success_without_a_receipt_is_a_failure(self):
        # A producer that does nothing still exits 0; the run must not report success.
        self.commit_diff()
        root = self.plugin_copy('installed')
        (root / 'scripts/review-evidence.py').write_text('# does nothing\n')
        stub_bin, _, _ = self.stub('noop')
        result = self.review(root, stub_bin, '--fresh')
        self.assertEqual(result.returncode, 1, result.stderr[-3000:])
        self.assertIn('wrote no receipt', result.stderr)
        self.assertIn('Review evidence was not issued', result.stderr)
        self.assertFalse(self.receipt.exists())

    def test_unreadable_producer_stops_before_any_cli(self):
        self.commit_diff()
        # A byte-identical installed copy sits right next to it and must not be picked up.
        spare = self.plugin_copy('spare')
        for case in ('missing', 'symlink', 'empty', 'unreadable'):
            with self.subTest(case=case):
                root = self.plugin_copy('installed-' + case)
                producer = root / 'scripts/review-evidence.py'
                if case in ('missing', 'symlink'):
                    producer.unlink()
                if case == 'symlink':
                    producer.symlink_to(spare / 'scripts/review-evidence.py')
                elif case == 'empty':
                    producer.write_text('')
                elif case == 'unreadable':
                    producer.chmod(0)
                    self.addCleanup(producer.chmod, 0o644)
                    if os.access(producer, os.R_OK):
                        # root and Windows read a mode-0 file; this case cannot be built there.
                        self.skipTest('mode 0 does not make the producer unreadable for this user')
                stub_bin, count, _ = self.stub(case)
                result = self.review(root, stub_bin, '--fresh')
                self.assertEqual(result.returncode, 2, result.stderr[-3000:])
                self.assertIn(str(producer), result.stderr)
                self.assertIn('再呼び出してください', result.stderr)
                self.assertNotIn(str(spare), result.stderr)
                self.assertFalse(count.exists())
                self.assertFalse(self.receipt.exists())

    def test_finish_failure_keeps_inputs_and_resume_reissues(self):
        self.commit_diff()
        root = SCRIPT.parents[1]
        stub_bin, count, _ = self.stub('finish')
        # A file where finish archives the report: every CLI completes, then finish fails.
        blocker = self.output / '.evidence'
        blocker.write_text('not a directory')
        result = self.review(root, stub_bin)
        self.assertEqual(result.returncode, 1, result.stderr[-4000:])
        self.assertIn('ERROR: review evidence:', result.stderr)
        self.assertIn('Review evidence was not issued', result.stderr)
        self.assertFalse(self.receipt.exists())
        starts = list(self.output.glob('.evidence-start.*.json'))
        rows = list(self.output.glob('.evidence-results.*'))
        self.assertEqual((len(starts), len(rows)), (1, 1))
        start = json.loads(starts[0].read_text())
        self.assertEqual(start['plan'], ['codex-cli:code-review'])
        self.assertEqual(start['subject']['head'], subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], text=True).strip())
        self.assertEqual(start['producer_sha256'], sha256(SCRIPT))
        self.assertEqual(rows[0].read_text(), 'codex-cli:code-review\tcomplete\n')
        for needle in (starts[0].name, rows[0].name,
                       'integrated-report.md (sha256 %s)' % sha256(self.output / 'integrated-report.md'),
                       'Re-run scope', '     codex-cli:code-review'):
            self.assertIn(needle, result.stderr)
        calls = count.read_text()
        blocker.unlink()
        result = self.review(root, stub_bin, '--resume')
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        self.assertEqual(count.read_text(), calls, 'resume ran the CLI again')
        # An unchanged root is not reported as changed.
        self.assertNotIn('changed while it ran', result.stderr)
        self.call('verify', '--required', 'code-review')

    def test_finish_rejects_a_start_record_that_is_not_an_object(self):
        (self.output / 'integrated-report.md').write_text(REPORT)
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        self.file.write_text('[]')
        result = self.call('finish', '--results', str(self.output / 'results'), success=False)
        self.assertIn('ERROR: review evidence: invalid review evidence start record', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_orchestrator_hands_the_generation_digest_to_finish(self):
        # No run can edit the report between generate_report and finish, so pin the wiring:
        # the digest is taken right after generation and is what finish compares against.
        text = (SCRIPT.parent / 'multi-agent.sh').read_text()
        generated = text.index('  generate_report || exit 1\n')
        digest = text.index('    if ! evidence_report_sha="$(python3 -I -c ', generated)
        finish = text.index('run_review_evidence finish ', digest)
        self.assertIn('--report-sha256 "$evidence_report_sha"', text[finish:text.index('\n', text.index('\n', finish) + 1)])

    def test_finish_rejects_results_outside_the_plan(self):
        for results in ('codex-cli:test-analysis\tcomplete\n',
                        'codex-cli:code-review\tcomplete\ncodex-cli:test-analysis\tcomplete\n', ''):
            with self.subTest(results=results):
                self.call('begin', '--plan', 'codex-cli:code-review')
                (self.output / 'integrated-report.md').write_text(REPORT)
                (self.output / 'results').write_text(results)
                result = self.call('finish', '--results', str(self.output / 'results'), success=False)
                self.assertIn('task results do not match the review plan', result.stderr)
                self.assertFalse(self.receipt.exists())

    def test_finish_rejects_report_changed_after_generation(self):
        self.call('begin', '--plan', 'codex-cli:code-review')
        report = self.output / 'integrated-report.md'
        report.write_text(REPORT)
        generated = sha256(report)
        report.write_text(REPORT + 'edited after generation\n')
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        args = ('--results', str(self.output / 'results'), '--report-sha256', generated)
        result = self.call('finish', *args, success=False)
        self.assertIn('integrated report changed after it was generated', result.stderr)
        self.assertFalse(self.receipt.exists())
        report.write_text(REPORT)
        self.call('finish', *args)
        self.call('verify', '--required', 'code-review')

    def test_finish_requires_the_producer_that_began(self):
        began, other = 'a' * 64, 'b' * 64
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        results = ('--results', str(self.output / 'results'))
        for start, finish in ((began, other), (began, ''), ('', began)):
            with self.subTest(start=start, finish=finish):
                self.call('begin', '--plan', 'codex-cli:code-review',
                          *(('--producer-sha256', start) if start else ()))
                (self.output / 'integrated-report.md').write_text(REPORT)
                result = self.call('finish', *results, *(('--producer-sha256', finish) if finish else ()),
                                   success=False)
                self.assertIn('producer changed between begin and finish', result.stderr)
                self.assertFalse(self.receipt.exists())
        result = self.call('begin', '--plan', 'codex-cli:code-review', '--producer-sha256', 'A' * 64,
                           success=False)
        self.assertIn('invalid producer digest', result.stderr)
        self.call('begin', '--plan', 'codex-cli:code-review', '--producer-sha256', began)
        self.call('finish', *results, '--producer-sha256', began)
        self.assertEqual(json.loads(self.receipt.read_text())['producer_sha256'], began)
        # Provenance only: the verifier takes no producer argument and accepts the receipt.
        self.call('verify', '--required', 'code-review')

    def test_finish_rejects_tampered_start_record(self):
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        results = ('--results', str(self.output / 'results'))
        for key, value in (('head', '0' * 40), ('base', '0' * 40),
                           ('remotes', 'remote.origin.url https://github.com/other/repo.git')):
            with self.subTest(key=key):
                self.call('begin', '--plan', 'codex-cli:code-review')
                (self.output / 'integrated-report.md').write_text(REPORT)
                self.mutate(lambda r: r['subject'].update({key: value}), self.file)
                result = self.call('finish', *results, success=False)
                self.assertIn('repository changed during review', result.stderr)
                self.assertFalse(self.receipt.exists())
        self.call('begin', '--plan', 'codex-cli:code-review')
        self.mutate(lambda r: r.update(plan=['codex-cli:test-analysis']), self.file)
        result = self.call('finish', *results, success=False)
        self.assertIn('task results do not match the review plan', result.stderr)
        self.assertFalse(self.receipt.exists())

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
