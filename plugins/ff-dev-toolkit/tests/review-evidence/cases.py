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
        self.output.mkdir(mode=0o700)
        # Authorize the empty namespace before an evidence fixture adds content.
        subprocess.run(['bash', '-c',
                        '. "$1" && ff_review_output_prepare "$2" "$3" false review',
                        'evidence-output', str(SCRIPT.parent / 'lib/multi-agent-boundary.sh'),
                        str(self.tmp), str(self.output)],
                       check=True, capture_output=True, text=True)
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
        if extra == ('--archive-only',):
            cmd = ['bash', str(root / 'scripts/multi-review.sh'), '--base', 'develop', '--archive-only']
        else:
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

    def test_retained_cache_refuses_unknown_and_unsafe_entries_before_archive(self):
        self.commit_diff()
        root = SCRIPT.parents[1]
        stub_bin, count, _ = self.stub('retained-cache')
        result = self.review(root, stub_bin)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        baseline = self.tmp.parent / ('evidence-baseline-' + self.tmp.name)
        shutil.copytree(self.output, baseline)
        self.addCleanup(shutil.rmtree, baseline, True)
        victim_dir = self.tmp.parent / ('evidence-victim-' + self.tmp.name)
        victim_dir.mkdir(mode=0o700)
        self.addCleanup(shutil.rmtree, victim_dir, True)
        victim = victim_dir / 'canary'
        victim.write_bytes(b'UNCHANGED')
        calls = count.read_text()
        probes = 0
        kinds = ['unknown-name', 'directory-link', 'leaf-link', 'directory-leaf', 'hardlink']
        if hasattr(os, 'mkfifo'):
            kinds.append('fifo')
        for kind in kinds:
            with self.subTest(kind=kind):
                shutil.rmtree(self.output)
                shutil.copytree(baseline, self.output)
                cache = self.output / '.evidence'
                candidate = cache / ('0' * 32)
                if kind == 'unknown-name':
                    (cache / 'unrelated.txt').write_text('user note')
                elif kind == 'directory-link':
                    candidate.symlink_to(victim_dir, target_is_directory=True)
                else:
                    candidate.mkdir(mode=0o700)
                    leaf = candidate / 'report.md'
                    if kind == 'leaf-link':
                        leaf.symlink_to(victim)
                    elif kind == 'directory-leaf':
                        leaf.mkdir()
                    elif kind == 'hardlink':
                        os.link(victim, leaf)
                    else:
                        os.mkfifo(leaf)
                before_report = (self.output / 'integrated-report.md').read_bytes()
                result = self.review(root, stub_bin, '--archive-only')
                self.assertNotEqual(result.returncode, 0, result.stderr[-4000:])
                self.assertIn(str(cache.resolve()), result.stderr)
                self.assertTrue('cannot archive previous review output' in result.stderr or
                                'unsafe review output boundary' in result.stderr, result.stderr)
                self.assertEqual((self.output / 'integrated-report.md').read_bytes(), before_report)
                self.assertEqual(count.read_text(), calls)
                self.assertEqual(victim.read_bytes(), b'UNCHANGED')
                self.assertEqual(list(self.output.glob('.prev-*')), [])
                probes += 1
        self.assertGreaterEqual(probes, 5, 'retained cache case collection is empty/incomplete')

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
            prior_report = Path(json.loads(self.receipt.read_text())['report'])
            prior_bytes = prior_report.read_bytes()
            claude = stub / 'claude'
            claude.write_text(cli.read_text())
            claude.chmod(0o755)
            cli.write_text('#!/bin/sh\ncat >/dev/null\necho "ERROR: You have reached your usage limit for this period" >&2\nexit 1\n')
            pair = ['bash', str(SCRIPT.parent / 'multi-review.sh'), '--route', 'full',
                    '--base', 'develop', '--evidence', '--fresh']
            result = subprocess.run(pair, capture_output=True, text=True, env=env)
            self.assertEqual(prior_report.read_bytes(), prior_bytes)
            states = json.loads(self.receipt.read_text())['results']
            self.assertIn('codex-cli:comprehensive-review', states, result.stderr[-4000:])
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

    def delegated_continuation(self, boundary=False, fresh_prior=True):
        """Successful parent fixture plus a real two-perspective delegated fix run."""
        self.commit_diff()
        parent_plan = ('claude-code:code-review\nclaude-code:test-analysis\n'
                       'claude-code:comment-analysis\ncodex-cli:comprehensive-review')
        parent_results = ''.join(task + '\tcomplete\n' for task in parent_plan.splitlines())
        previous_prior = self.output / 'previous prior.json'
        if boundary:
            self.record()
            shutil.copyfile(self.receipt, previous_prior)
        self.record(plan=parent_plan, results=parent_results,
                    extra=('--prior', str(previous_prior)) if boundary else ())
        parent = self.output / "previous review's.json"
        shutil.copyfile(self.receipt, parent)
        parent_record = json.loads(parent.read_text())
        # Seed the full parent HEAD through the canonical counter, with its default
        # limit (2) and no ACK. The actual partial run and its advertised rerun must
        # both fit in round 2, rather than spending an extra round for delegation.
        seed_env = {k: v for k, v in os.environ.items()
                    if not k.startswith('_'.join(('FF', 'REVIEW')) + '_')}
        seeded = subprocess.run(['bash', '-c',
            '. "$1"; [ "$(rr_limit)" = 2 ] || exit 1; ff_review_round_script_gate --task review',
            'fixture-parent-round', str(SCRIPT.parents[1] / 'tests/lib/review-round-counter.sh')],
            capture_output=True, text=True, env=seed_env, timeout=120)
        self.assertEqual(seeded.returncode, 0, seeded.stderr)
        round_files = list((self.tmp / '.git/ff-review-rounds').glob('*.tsv'))
        self.assertEqual(len(round_files), 1, 'canonical parent round was not recorded')
        round_file = round_files[0]
        self.assertEqual([line.split('\t')[:2] for line in round_file.read_text().splitlines()[1:]],
                         [['1', parent_record['subject']['head']]])
        self.git('commit', '-qm', 'partial fix', '--allow-empty')
        prior = self.output / "current prior's.json"
        if boundary and fresh_prior:
            self.record()
            shutil.copyfile(self.receipt, prior)
        root = self.plugin_copy("installed root's")
        stub_bin, calls, _ = self.stub('continuation')
        host_calls = stub_bin.parent / 'host-review-calls'
        host = stub_bin / 'claude'
        host.write_text('#!/bin/sh\nfor arg do\nif [ "$arg" = -p ]; then\n'
                        'printf x >> %s\nfi\ndone\ncat >/dev/null\n'
                        'printf "## Findings\\n- verdict: none\\n"\n' % shlex.quote(str(host_calls)))
        host.chmod(0o755)
        home = stub_bin.parent / 'home'
        home.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(tuple('_'.join(parts) + '_' for parts in [
            ('MULTI', 'AGENT'), ('FF', 'DEV', 'TOOLKIT'), ('FF', 'REVIEW')]))
               and k not in ('CLAUDE_PLUGIN_ROOT', 'GROK_PLUGIN_ROOT')}
        env.update(PATH=str(stub_bin) + ':' + env['PATH'], HOME=str(home),
                   FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE='1',
                   FF_DEV_TOOLKIT_ROOT=str(root), MULTI_AGENT_REVIEW_MAIN='claude-code',
                   MULTI_AGENT_REVIEW_SUB='codex-cli', MULTI_AGENT_CROSS_REVIEW='auto')
        self.output = self.output / "partial output's"
        self.receipt = self.output / 'review-evidence.json'
        sentinel = stub_bin.parent / 'command-substitution-must-not-run'
        description = "AC's quoted text; $(touch %s)\nSecond AC line" % shlex.quote(str(sentinel))
        cmd = ['bash', str(root / 'scripts/multi-review.sh'), '--route', 'none', '--mode', 'pair',
               '--base', 'develop', '--evidence', '--continue-review', str(parent),
               '--perspective', 'code-review,test-analysis,comprehensive-review',
               '--delegate-to-host=claude-code', '--output-dir', str(self.output),
               '--description', description, '--sequential']
        if boundary and fresh_prior:
            cmd.extend(('--require-prior-review', str(prior)))
        self.assertNotIn('FF_REVIEW_ROUND_LIMIT', env)
        self.assertNotIn('FF_REVIEW_ROUND_ACK', env)
        return dict(cmd=cmd, env=env, calls=calls, host_calls=host_calls, sentinel=sentinel,
                    rounds=round_file, parent=parent_record,
                    prior=json.loads(prior.read_text()) if prior.exists() else None)

    def continuation_handoff(self, context):
        result = subprocess.run(context['cmd'], capture_output=True, text=True,
                                env=context['env'], timeout=600)
        self.assertEqual(result.returncode, 3, result.stderr[-4000:])
        self.assertTrue(self.receipt.is_file(), 'run did not issue evidence in the selected output directory')
        context['rounds_after_first'] = context['rounds'].read_bytes()
        expected_rounds = [['1', context['parent']['subject']['head']],
                           ['2', json.loads(self.receipt.read_text())['subject']['head']]]
        self.assertEqual([line.split('\t')[:2] for line in context['rounds'].read_text().splitlines()[1:]],
                         expected_rounds, 'partial fix did not become exactly round 2')
        self.assertFalse(context['host_calls'].exists(), 'delegated host CLI was launched')
        self.assertEqual(context['calls'].read_text(), context.get('expected_calls', 'x'),
                         'nondelegated task was not executed for every invocation')
        self.assertEqual(result.stdout.count('<<<FF-DELEGATED-TASKS>>>'), 1)
        self.assertEqual(result.stdout.count('<<<END-FF-DELEGATED-TASKS>>>'), 1)
        block = result.stdout.split('<<<FF-DELEGATED-TASKS>>>', 1)[1].split('<<<END-FF-DELEGATED-TASKS>>>', 1)[0]
        sections = block.split('--- task ---')
        count = [line for line in sections[0].splitlines() if line.startswith('count=')]
        self.assertEqual(count, ['count=2'], 'missing/empty/changed delegated task set')
        tasks = [dict(line.split('=', 1) for line in section.splitlines() if '=' in line)
                 for section in sections[1:]]
        self.assertEqual({task['perspective'] for task in tasks}, {'code-review', 'test-analysis'})
        self.assertEqual(len(tasks), 2, 'duplicate/missing delegated tasks')
        for task in tasks:
            self.assertEqual(task['cli'], 'claude-code')
            self.assertEqual(task['handoff-format'], '2')
            self.assertTrue(Path(task['prompt-file']).is_file())
            self.assertEqual(Path(task['output-file']).name, task['perspective'] + '.response.md')
            self.assertEqual(Path(task['prompt-file']).parent, Path(task['output-file']).parent)
        self.assertIn('Wait until ALL pending delegated responses have been written', result.stderr)
        self.assertIn('WITHOUT --resume', result.stderr)
        self.assertIn('Every non-delegated task runs again', result.stderr)
        self.assertNotIn('WITH --resume to adopt', result.stderr)
        command_lines = result.stderr.split('   Re-run command:\n')
        self.assertEqual(len(command_lines), 2, 'no unique executable rerun command')
        command = command_lines[1].split('\n      Keep the original model/config-selection environment;', 1)[0].strip()
        self.assertEqual(shlex.split(command), context['cmd'], 'quoted command changed the original arguments')
        self.assertNotIn('--resume', shlex.split(command))
        report = (self.output / 'integrated-report.md').read_text()
        self.assertEqual(report.count('DELEGATED — pending host execution'), 2)
        self.assertEqual(report.count('Wait until ALL pending delegated responses have been written'), 2)
        self.assertEqual(report.count('original command below **WITHOUT `--resume`**'), 2)
        self.assertNotIn('**with `--resume`**', report)
        self.assertEqual(report.count('Every non-delegated task runs again'), 2)
        self.assertEqual(report.count('Keep the original model/config-selection environment; '
                                      'this command does not restore it.'), 2)
        report_commands = report.split('\nRe-run command:\n\n')[1:]
        self.assertEqual(len(report_commands), 2, 'each pending section must give the legal command')
        for section in report_commands:
            lines = section.split('\n\n', 1)[0].splitlines()
            self.assertTrue(all(line.startswith('    ') for line in lines))
            report_command = '\n'.join(line[4:] for line in lines)
            self.assertEqual(shlex.split(report_command), context['cmd'])
        recovery_advice = (
            'If only part of the batch was adopted, keep this output directory intact.',
            'Choose an external or gitignored directory so the evidence worktree stays clean.',
            'Restart with a new empty --output-dir appended to the original command; keep every',
            'other argument and the original environment. Run ALL newly generated prompts,',
            'write the entire new batch, then re-run that new command WITHOUT --resume.')
        for advice in recovery_advice:
            self.assertIn(advice, result.stderr)
            self.assertEqual(report.replace('`', '').count(advice), 2)
        for task in tasks:
            self.assertIn(task['prompt-file'], report)
            self.assertIn(task['output-file'], report)
        pending = json.loads(self.receipt.read_text())
        self.assertEqual(set(pending['results'].values()), {'complete', 'incomplete'})
        self.call('verify', success=False)
        return tasks, command

    def finish_continuation_handoff(self, context, tasks, command, skip=(), expected_calls='xx'):
        # Host writes the actual advertised response slots. The displayed command is
        # consumed as a user would copy it; runtime never evals/sources display data.
        for task in tasks:
            if task['perspective'] not in skip:
                Path(task['output-file']).write_text(
                    '## Findings\n- verdict: none\nHOST-' + task['perspective'] + '\n')
        result = subprocess.run(['bash', '-c', command], capture_output=True, text=True,
                                env=context['env'], timeout=600)
        self.assertFalse(context['sentinel'].exists(), 'quoted description executed shell syntax')
        self.assertFalse(context['host_calls'].exists(), 'delegated host CLI was launched')
        self.assertEqual(context['calls'].read_text(), expected_calls, 'nondelegated task reused a cache')
        self.assertEqual(context['rounds'].read_bytes(), context['rounds_after_first'],
                         'advertised rerun changed the round-2 counter without a new HEAD')
        return result

    def test_continued_host_delegation_adopts_all_from_the_advertised_command(self):
        context = self.delegated_continuation()
        tasks, command = self.continuation_handoff(context)
        result = self.finish_continuation_handoff(context, tasks, command)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        self.assertNotIn('<<<FF-DELEGATED-TASKS>>>', result.stdout)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(len(receipt['plan']), 3)
        self.assertEqual(set(receipt['results'].values()), {'complete'})
        self.assertEqual(receipt['parent']['id'], context['parent']['id'])
        self.assertEqual(receipt['parent']['subject']['head'], context['parent']['subject']['head'])
        self.assertNotEqual(receipt['subject']['head'], receipt['parent']['subject']['head'])
        self.assertIsNone(receipt['prior'])
        for task in tasks:
            accepted = self.output / task['cli'] / (task['perspective'] + '.md')
            self.assertIn('HOST-' + task['perspective'], accepted.read_text())
            self.assertIn('<!-- Status: complete -->', accepted.read_text())
            self.assertFalse(Path(task['output-file']).exists())
        coverage = self.call('verify', '--required', 'code-review,test-analysis,comment-analysis,comprehensive-review')
        self.assertEqual(set(coverage.stdout.strip().split(',')),
                         {'code-review', 'test-analysis', 'comment-analysis', 'comprehensive-review'})

    def test_continued_host_delegation_preserves_fresh_boundary_prior(self):
        context = self.delegated_continuation(boundary=True)
        tasks, command = self.continuation_handoff(context)
        result = self.finish_continuation_handoff(context, tasks, command)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['parent']['id'], context['parent']['id'])
        self.assertEqual(receipt['prior']['id'], context['prior']['id'])
        self.assertEqual(receipt['prior']['subject'], receipt['subject'])
        self.assertLessEqual(receipt['prior']['finished_ns'], receipt['started_ns'])
        self.call('verify', '--required', 'code-review,test-analysis,comment-analysis,comprehensive-review',
                  '--prior-required', 'code-review')

    def test_prior_only_host_delegation_uses_the_same_safe_batch_advice(self):
        context = self.delegated_continuation(boundary=True)
        parent_index = context['cmd'].index('--continue-review')
        del context['cmd'][parent_index:parent_index + 2]
        tasks, command = self.continuation_handoff(context)
        result = self.finish_continuation_handoff(context, tasks, command)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        receipt = json.loads(self.receipt.read_text())
        self.assertIsNone(receipt['parent'])
        self.assertEqual(receipt['prior']['id'], context['prior']['id'])
        coverage = self.call('verify', '--required', 'code-review,test-analysis,comprehensive-review',
                             '--prior-required', 'code-review')
        self.assertEqual(set(coverage.stdout.strip().split(',')),
                         {'code-review', 'test-analysis', 'comprehensive-review'})

    def test_continued_host_delegation_does_not_waive_missing_boundary_prior(self):
        context = self.delegated_continuation(boundary=True, fresh_prior=False)
        tasks, command = self.continuation_handoff(context)
        result = self.finish_continuation_handoff(context, tasks, command)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        rejected = self.call('verify', success=False)
        self.assertIn('partial review lost required prior review', rejected.stderr)

    def test_continued_host_delegation_missing_response_is_not_complete(self):
        context = self.delegated_continuation(boundary=True)
        tasks, command = self.continuation_handoff(context)
        result = self.finish_continuation_handoff(context, tasks, command, skip=('test-analysis',))
        self.assertEqual(result.returncode, 3, result.stderr[-4000:])
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['results']['claude-code:code-review'], 'complete')
        self.assertEqual(receipt['results']['claude-code:test-analysis'], 'incomplete')
        rejected = self.call('verify', success=False)
        self.assertIn('incomplete review task', rejected.stderr)
        # Filling only the pending response clears and delegates the consumed one
        # again. Preserve that failed run and follow the advertised fresh-directory
        # recovery instead of copying old responses into a different generation.
        pending = next(task for task in tasks if task['perspective'] == 'test-analysis')
        Path(pending['output-file']).write_text('## Findings\n- verdict: none\nPENDING-ONLY\n')
        result = subprocess.run(['bash', '-c', command], capture_output=True, text=True,
                                env=context['env'], timeout=600)
        self.assertEqual(result.returncode, 3, result.stderr[-4000:])
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['results']['claude-code:code-review'], 'incomplete')
        self.assertEqual(receipt['results']['claude-code:test-analysis'], 'complete')
        old_output = self.output
        preserved = {str(path.relative_to(old_output)): path.read_bytes()
                     for path in old_output.rglob('*') if path.is_file()}
        rounds_before_recovery = context['rounds'].read_bytes()
        self.output = old_output.with_name("fresh recovery output's")
        self.assertFalse(self.output.exists(), 'recovery output directory is not empty')
        self.receipt = self.output / 'review-evidence.json'
        context['cmd'].extend(('--output-dir', str(self.output)))
        context['expected_calls'] = 'xxxx'
        recovered_tasks, recovered_command = self.continuation_handoff(context)
        self.assertTrue(all(self.output.resolve() in Path(task['output-file']).resolve().parents
                            for task in recovered_tasks))
        self.assertTrue({task['output-file'] for task in tasks}.isdisjoint(
            task['output-file'] for task in recovered_tasks))
        result = self.finish_continuation_handoff(context, recovered_tasks, recovered_command,
                                                  expected_calls='xxxxx')
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        self.assertNotIn('<<<FF-DELEGATED-TASKS>>>', result.stdout)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(set(receipt['results'].values()), {'complete'})
        self.assertEqual(receipt['parent']['id'], context['parent']['id'])
        self.assertEqual(receipt['prior']['id'], context['prior']['id'])
        self.assertEqual(context['rounds'].read_bytes(), rounds_before_recovery)
        for task in recovered_tasks:
            accepted = self.output / task['cli'] / (task['perspective'] + '.md')
            self.assertIn('HOST-' + task['perspective'], accepted.read_text())
            self.assertFalse(Path(task['output-file']).exists())
        self.assertNotIn('PENDING-ONLY', (self.output / 'integrated-report.md').read_text())
        self.assertEqual(preserved, {str(path.relative_to(old_output)): path.read_bytes()
                                    for path in old_output.rglob('*') if path.is_file()},
                         'fresh-directory recovery changed the original run')
        self.call('verify', '--required', 'code-review,test-analysis,comment-analysis,comprehensive-review',
                  '--prior-required', 'code-review')

    def test_ordinary_host_delegation_report_keeps_resume_and_partial_adoption(self):
        context = self.delegated_continuation()
        parent_index = context['cmd'].index('--continue-review')
        del context['cmd'][parent_index:parent_index + 2]
        result = subprocess.run(context['cmd'], capture_output=True, text=True,
                                env=context['env'], timeout=600)
        self.assertEqual(result.returncode, 3, result.stderr[-4000:])
        self.assertIn('WITH --resume to adopt', result.stderr)
        report = (self.output / 'integrated-report.md').read_text()
        self.assertEqual(report.count('**with `--resume`**'), 2)
        self.assertNotIn('WITHOUT', report)
        block = result.stdout.split('<<<FF-DELEGATED-TASKS>>>', 1)[1].split('<<<END-FF-DELEGATED-TASKS>>>', 1)[0]
        tasks = [dict(line.split('=', 1) for line in section.splitlines() if '=' in line)
                 for section in block.split('--- task ---')[1:]]
        self.assertEqual({task['perspective'] for task in tasks}, {'code-review', 'test-analysis'})
        rounds_before_resume = context['rounds'].read_bytes()
        first, last = tasks
        Path(first['output-file']).write_text('## Findings\n- verdict: none\nORDINARY-FIRST\n')
        result = subprocess.run([*context['cmd'], '--resume'], capture_output=True, text=True,
                                env=context['env'], timeout=600)
        self.assertEqual(result.returncode, 3, result.stderr[-4000:])
        self.assertEqual(result.stdout.count('--- task ---'), 1)
        accepted = self.output / first['cli'] / (first['perspective'] + '.md')
        accepted_bytes = accepted.read_bytes()
        self.assertIn(b'ORDINARY-FIRST', accepted_bytes)
        Path(last['output-file']).write_text('## Findings\n- verdict: none\nORDINARY-LAST\n')
        result = subprocess.run([*context['cmd'], '--resume'], capture_output=True, text=True,
                                env=context['env'], timeout=600)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        self.assertEqual(accepted.read_bytes(), accepted_bytes)
        self.assertEqual(context['calls'].read_text(), 'x')
        self.assertFalse(context['host_calls'].exists())
        self.assertEqual(context['rounds'].read_bytes(), rounds_before_resume)
        self.assertFalse(context['sentinel'].exists())
        receipt = json.loads(self.receipt.read_text())
        self.assertIsNone(receipt['parent'])
        self.assertIsNone(receipt['prior'])
        self.call('verify', '--required', 'code-review,test-analysis,comprehensive-review')

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

    def non_utf8_env(self):
        # Copy the fixture's GIT_* isolation. -I ignores PYTHONUTF8, so UTF-8 mode is
        # disabled on the command line. Since Python 3.7 (PEP 540), a C or POSIX
        # locale enables UTF-8 mode by itself; -X utf8=0 turns that off.
        env = os.environ.copy()
        env.update(LC_ALL='C', LANG='C', PYTHONUTF8='0')
        env.pop('PYTHONIOENCODING', None)
        return env

    def run_non_utf8(self, *args):
        # Same stdin entry as the producer (`python3 -I -`), plus -X utf8=0.
        return subprocess.run(['python3', '-I', '-X', 'utf8=0', '-', *args],
                              input=SCRIPT.read_bytes(), capture_output=True,
                              env=self.non_utf8_env())

    def require_non_utf8_preferred_encoding(self):
        probe = subprocess.run(
            ['python3', '-I', '-X', 'utf8=0', '-c',
             'import locale\nprint(locale.getpreferredencoding(False), end="")\n'],
            capture_output=True, env=self.non_utf8_env())
        detail = probe.stderr.decode('ascii', 'replace')
        if probe.returncode != 0:
            self.fail('preferred encoding probe failed (not a skip): ' + detail)
        encoding = probe.stdout.decode('ascii', 'replace').strip()
        token = encoding.lower().replace('-', '').replace('_', '')
        if token in ('utf8', 'utf8sig', ''):
            self.fail('non-UTF-8 preferred encoding was not reproduced with '
                      'python3 -I -X utf8=0 and LC_ALL=C (PYTHONUTF8 is ignored by -I). '
                      'locale.getpreferredencoding(False)=%r. Refusing to skip.' % encoding)
        return encoding

    def archived_report_bytes(self, receipt):
        record = json.loads(Path(receipt).read_bytes().decode('utf-8'))
        return Path(record['report']).read_bytes()

    def test_non_utf8_preferred_encoding_verifies_emdash_prior_and_parent(self):
        # Windows cp932 and UTF-8 mode off both fail read_text() on U+2014 (UTF-8 e2 80 94).
        # cp932 is not installed here; ANSI_X3.4-1968 is the non-UTF-8 locale this host can make.
        encoding = self.require_non_utf8_preferred_encoding()
        self.record()
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        self.git('commit', '-qm', 'follow-up', '--allow-empty')
        self.record()
        prior = self.output / 'prior.json'
        shutil.copyfile(self.receipt, prior)
        for receipt in (parent, prior):
            first = self.archived_report_bytes(receipt).splitlines()[0]
            self.assertIn('—'.encode('utf-8'), first)
        # begin is the pre-CLI gate for --require-prior-review and --continue-review.
        begin = self.run_non_utf8(
            'begin', '--file', str(self.file), '--output', str(self.output),
            '--base', 'develop', '--plan', 'codex-cli:code-review',
            '--prior', str(prior), '--parent', str(parent))
        self.assertEqual(begin.returncode, 0,
                         'encoding=%s stderr=%s' % (encoding, begin.stderr.decode('ascii', 'replace')))
        self.record(extra=('--prior', str(prior), '--parent', str(parent)))
        self.assertIn('—'.encode('utf-8'), self.archived_report_bytes(self.receipt).splitlines()[0])
        accepted = self.run_non_utf8(
            'verify', '--file', str(self.receipt), '--output', str(self.output),
            '--base', 'develop', '--required', 'code-review', '--prior-required', 'code-review')
        accepted_err = accepted.stderr.decode('ascii', 'replace')
        self.assertEqual(accepted.returncode, 0, 'encoding=%s stderr=%s' % (encoding, accepted_err))
        self.assertNotIn('codec', accepted_err.lower())
        self.assertEqual(accepted.stdout.decode('ascii'), 'code-review\n')
        denied = self.run_non_utf8(
            'verify', '--file', str(self.receipt), '--output', str(self.output),
            '--base', 'develop', '--required', 'not-a-perspective')
        denied_err = denied.stderr.decode('ascii', 'replace')
        self.assertNotEqual(denied.returncode, 0, denied_err)
        self.assertIn('missing required review perspectives', denied_err)
        self.assertNotIn("can't decode", denied_err)

    def test_non_utf8_round_trips_json_text_and_results(self):
        # inspect() is reached by the em-dash report test. load() and write() need a
        # real U+2014 inside the JSON. A non-ASCII directory name does not: under
        # -X utf8=0 the path arrives as surrogateescape and write_text(encoding='utf-8')
        # rejects it even with the encoding set. An extra JSON field is ignored by
        # inspect and is preserved when begin stores the prior. The results line is
        # rejected after it has been decoded, which is not a decode error.
        encoding = self.require_non_utf8_preferred_encoding()
        marker = '\u2014'.encode('utf-8')
        self.record()
        prior_record = json.loads(self.receipt.read_bytes().decode('utf-8'))
        prior_record['note'] = '\u2014'
        prior = self.output / 'prior.json'
        prior.write_bytes((json.dumps(prior_record, ensure_ascii=False) + '\n').encode('utf-8'))
        self.assertIn(marker, prior.read_bytes())
        begin = self.run_non_utf8(
            'begin', '--file', str(self.file), '--output', str(self.output),
            '--base', 'develop', '--plan', 'codex-cli:code-review',
            '--prior', str(prior))
        self.assertEqual(begin.returncode, 0,
                         'encoding=%s stderr=%s' % (encoding, begin.stderr.decode('ascii', 'replace')))
        self.assertIn(marker, self.file.read_bytes())
        bad = self.output / 'results-bad'
        bad.write_bytes(b'codex-cli:code-review\tcomplete\nnote ' + marker + b' extra\n')
        rejected = self.run_non_utf8(
            'finish', '--file', str(self.file), '--output', str(self.output),
            '--base', 'develop', '--results', str(bad))
        rejected_err = rejected.stderr.decode('ascii', 'replace')
        self.assertNotEqual(rejected.returncode, 0, rejected_err)
        self.assertIn('invalid/duplicate task result', rejected_err)
        self.assertNotIn("can't decode", rejected_err)
        good = self.output / 'results'
        good.write_bytes(b'codex-cli:code-review\tcomplete\n')
        (self.output / 'integrated-report.md').write_bytes(REPORT.encode('utf-8'))
        finished = self.run_non_utf8(
            'finish', '--file', str(self.file), '--output', str(self.output),
            '--base', 'develop', '--results', str(good))
        self.assertEqual(finished.returncode, 0,
                         'encoding=%s stderr=%s' % (encoding, finished.stderr.decode('ascii', 'replace')))
        self.assertIn(marker, self.receipt.read_bytes())
        accepted = self.run_non_utf8(
            'verify', '--file', str(self.receipt), '--output', str(self.output),
            '--base', 'develop', '--required', 'code-review', '--prior-required', 'code-review')
        accepted_err = accepted.stderr.decode('ascii', 'replace')
        self.assertEqual(accepted.returncode, 0, 'encoding=%s stderr=%s' % (encoding, accepted_err))
        self.assertNotIn('codec', accepted_err.lower())
        self.assertEqual(accepted.stdout.decode('ascii'), 'code-review\n')

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
