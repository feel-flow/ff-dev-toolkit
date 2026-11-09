import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

# The sibling import below would otherwise leave __pycache__ in the suite directory.
sys.dont_write_bytecode = True
from cases_host_delegation import HostDelegationCases  # noqa: E402

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/review-evidence.py'
REPORT = '# Multi-CLI Review — Integrated Report\n\nvalid report\n'
# Runs the producer with its wall clock (time.time_ns) pinned: argv = ns, script, args...
CLOCK_AT = ('import runpy, sys, time\n'
            'ns = int(sys.argv[1])\n'
            'time.time_ns = lambda: ns\n'
            'sys.argv = sys.argv[2:]\n'
            'runpy.run_path(sys.argv[0], run_name="__main__")\n')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

class Evidence(HostDelegationCases, unittest.TestCase):
    def setUp(self):
        for name in list(os.environ):
            if name.startswith('GIT_'):
                os.environ.pop(name)
        os.environ.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
        self.tmp = Path(tempfile.mkdtemp())
        # Installed plugins/stubs must be outside the reviewed repository, but their
        # parent is still private: a predictable sibling of self.tmp can be pre-created.
        self.external = Path(tempfile.mkdtemp(prefix='evidence-external-'))
        self.addCleanup(shutil.rmtree, self.external, True)
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

    def call(self, action, *args, success=True, clock_ns=None):
        # clock_ns pins the producer's wall clock so clock steps are reproduced, not awaited.
        entry = [str(SCRIPT)] if clock_ns is None else ['-c', CLOCK_AT, str(clock_ns), str(SCRIPT)]
        result = subprocess.run(['python3', *entry, action, '--file', str(
            self.receipt if action == 'verify' else self.file), '--output', str(self.output),
            '--base', 'develop', *args], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def record(self, plan='codex-cli:code-review', results='codex-cli:code-review\tcomplete\n',
               extra=(), text='# Multi-CLI Review — Integrated Report\n\nvalid report\n',
               clock_ns=None):
        self.call('begin', '--plan', plan, *extra, clock_ns=clock_ns)
        (self.output / 'integrated-report.md').write_text(text)
        (self.output / 'results').write_text(results)
        self.call('finish', '--results', str(self.output / 'results'), clock_ns=clock_ns)

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
        base = self.external / 'plugins'
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

    def test_installed_fixture_ignores_precreated_shared_siblings(self):
        # A private directory models a shared /tmp without touching another user's files.
        with tempfile.TemporaryDirectory(prefix='evidence-shared-') as shared:
            shared = Path(shared)
            repository = shared / 'repo'
            repository.mkdir()
            legacy = shared / ('evidence-roots-' + repository.name)
            legacy_script = legacy / 'installed/scripts/multi-review.sh'
            legacy_script.parent.mkdir(parents=True)
            legacy_script.write_bytes(b'exit 91')
            legacy_stub = shared / ('evidence-stub-' + repository.name + '-precreated')
            legacy_stub.mkdir()
            sentinel = legacy_stub / 'sentinel'
            sentinel.write_bytes(b'UNCHANGED')
            original = self.tmp
            try:
                self.tmp = repository
                root = self.plugin_copy('installed')
                stub_bin, _, _ = self.stub('precreated')
            finally:
                self.tmp = original
            self.assertEqual(sha256(root / 'scripts/multi-review.sh'),
                             sha256(SCRIPT.parent / 'multi-review.sh'))
            self.assertEqual(root.parent, self.external / 'plugins')
            self.assertEqual(stub_bin.parent.parent, self.external)
            self.assertNotEqual(self.external.parent, repository)
            self.assertEqual(self.external.stat().st_mode & 0o777, 0o700)
            self.assertEqual(legacy_script.read_bytes(), b'exit 91')
            self.assertEqual(sentinel.read_bytes(), b'UNCHANGED')

    def test_shell_fixtures_ignore_precreated_shared_paths(self):
        sources = SCRIPT.parents[1] / 'tests'
        fields = {
            'RUN_GATE_RECORD': 'ff-run-all-gate-record',
            '_reg_fx': 'ff-registration-probe',
            '_pred_fx': 'ff-skip-predicate-probe',
            '_probe_fx': 'ff-miss-probe-registration',
            '_fast_fx': 'ff-fast-integration',
            '_selfmut_fx': 'ff-run-all-selfmut',
            '_mkchk_lx': 'ff-mkchk-layout',
            '_mkchk_fx': 'ff-mktemp-template-check',
            '_ff_missing_nm': 'ff-run-all-verify-missing-node_modules',
            '_ff_ready_mcp': 'ff-run-all-verify-ready-mcp',
            '_ff_partial_mcp': 'ff-run-all-verify-partial-mcp',
            '_fu_fx': 'ff-followup-unlisted-probe',
            '_dg_fx': 'ff-run-all-dirty-guard',
            '_mg_fx': 'ff-run-all-mcp-deps-guard',
            '_nt_fx': 'ff-node-test-guard',
        }
        self.assertEqual(len(fields), 15, 'fixture path collection is empty/incomplete')
        for suite, start, root_var, variables, names in (
                ('run-all', 'if _ff_tmp_probe=', 'RUN_WORK', list(fields), list(fields.values())),
                ('review-wrapper-shim', '_ff_mktemp_out=', 'WORK', [],
                 ['ff-review-wrapper-shim-no-grok'])):
            with self.subTest(suite=suite), tempfile.TemporaryDirectory(prefix='fixture-shared-') as shared:
                self.assertGreater(len(names), 0, 'precreated path collection is empty')
                # The suite body lives in verify.sh and the cases it sources (run-all, Issue `#2696`).
                source_files = [sources / suite / 'verify.sh', *sorted((sources / suite / 'cases').glob('*.sh'))]
                source = chr(10).join(path.read_text(encoding='utf-8') for path in source_files)
                begin = source.index(start)
                bootstrap = source[begin:source.index(chr(10) + 'PASS=0', begin)]
                assignments = []
                for variable in variables:
                    matches = [line.strip() for line in source.splitlines()
                               if line.strip().startswith(variable + '="')
                               and not line.strip().startswith(variable + '="$(')]
                    self.assertEqual(len(matches), 1, 'fixture assignment missing/ambiguous: ' + variable)
                    assignments.append(matches[0])
                # New predictable shared paths must not silently fall outside the collection.
                self.assertIsNone(re.search(r'^[^#]*\$\{TMPDIR:-/tmp\}/[^\n]*\$\$',
                                            source, re.MULTILINE), 'predictable shared fixture path')
                checks = ['[ -d "$GROK_HOME" ]', 'case "$GROK_HOME" in "$WORK"/*) ;; *) exit 91 ;; esac']
                if variables:
                    checks = []
                    for variable in variables:
                        checks.append('case "$' + variable + '" in "$' + root_var + '"/*) ;; *) exit 91 ;; esac')
                script = chr(10).join([
                    'set -euo pipefail',
                    'TMPDIR=' + shlex.quote(shared),
                    'SUITE_NAME=privacy-probe',
                    'for name in ' + ' '.join(names) + '; do',
                    '  mkdir "$TMPDIR/$name.$$"',
                    '  printf UNCHANGED > "$TMPDIR/$name.$$/sentinel"',
                    'done',
                    bootstrap, *assignments, *checks,
                    'for name in ' + ' '.join(names) + '; do',
                    '  [ "$(cat "$TMPDIR/$name.$$/sentinel")" = UNCHANGED ]',
                    'done',
                    'FF_REACHED_END=1',
                ])
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(list(Path(shared).glob('*/sentinel'))), len(names))

    def stub(self, name, delete=None, rewrite=None):
        """codex stub: counts review calls (`codex exec`). On the first one, before printing its
        findings, it removes `delete` or overwrites the file `rewrite` in place."""
        stub = self.external / ('stub-' + name)
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
                   FF_DEV_TOOLKIT_SKIP='codex-auto-update', FF_DEV_TOOLKIT_ROOT=str(root))
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
        baseline = self.external / 'baseline'
        shutil.copytree(self.output, baseline)
        self.addCleanup(shutil.rmtree, baseline, True)
        victim_dir = self.external / 'victim'
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
        stub = self.external / 'integration-stub'
        stub.mkdir()
        try:
            cli = stub / 'codex'
            cli.write_text('#!/bin/sh\ncat >/dev/null\nprintf "## Findings\\n- verdict: none\\n"\n')
            cli.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if not k.startswith(tuple('_'.join(parts) + '_' for parts in [
                ('MULTI', 'AGENT'), ('FF', 'DEV', 'TOOLKIT'), ('FF', 'REVIEW')]))}
            env.update(PATH=str(stub) + ':' + env['PATH'], FF_REVIEW_ROUND_LIMIT='0',
                       FF_DEV_TOOLKIT_SKIP='codex-auto-update')
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
                restore_base = None
                if change == 'head':
                    self.git('commit', '-qm', 'fix', '--allow-empty')
                elif change == 'base':
                    # An empty commit moved onto HEAD keeps the three-dot diff empty, so that
                    # move is an accepted base advance. A new root is not an ancestor.
                    # Restore it afterwards: later subtests record against develop.
                    restore_base = subprocess.check_output(
                        ['git', 'rev-parse', 'develop'], text=True).strip()
                    root = subprocess.check_output(
                        ['git', 'commit-tree', 'HEAD^{tree}', '-m', 'other root'], text=True).strip()
                    self.git('branch', '-f', 'develop', root)
                else:
                    self.git('remote', 'set-url', 'origin', 'https://github.com/other/repo.git')
                self.call('verify', success=False)
                if restore_base:
                    self.git('branch', '-f', 'develop', restore_base)

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

    def test_wall_clock_step_back_keeps_prior_and_parent_order(self):
        # The wall clock can step back between two reviews (observed under load in WSL).
        # begin read prior/parent as finished records, so the order must still verify.
        # The prior finishes last, so only raising the start to the prior's finish passes.
        self.record(clock_ns=1 * 10**9 + 500_000_000)
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        self.git('commit', '-qm', 'follow-up', '--allow-empty')
        self.record(clock_ns=1 * 10**9 + 900_000_000)
        prior = self.output / 'prior.json'
        shutil.copyfile(self.receipt, prior)
        self.record(extra=('--prior', str(prior), '--parent', str(parent)), clock_ns=10**9)
        self.call('verify', '--required', 'code-review', '--prior-required', 'code-review')
        # Tampering after begin stays visible: a prior finishing after this start is refused.
        self.mutate(lambda r: r['prior'].update(finished_ns=r['started_ns'] + 1))
        self.call('verify', success=False)

    def test_wall_clock_step_back_keeps_prior_order_alone(self):
        self.record(clock_ns=1 * 10**9 + 500_000_000)
        prior = self.output / 'prior.json'
        shutil.copyfile(self.receipt, prior)
        self.record(extra=('--prior', str(prior)), clock_ns=10**9)
        self.call('verify', '--required', 'code-review', '--prior-required', 'code-review')

    def test_finish_far_ahead_of_the_clock_is_not_absorbed(self):
        # Only a step up to 1 s is absorbed. A prior finishing further ahead of this review's
        # clock (just over 1 s, or 5 s) is not a step: the start stays and verify refuses it.
        for ahead in (10**9 + 1, 5 * 10**9):
            with self.subTest(ahead=ahead):
                self.record(clock_ns=10**9 + ahead)
                prior = self.output / 'prior.json'
                shutil.copyfile(self.receipt, prior)
                self.record(extra=('--prior', str(prior)), clock_ns=10**9)
                refused = self.call('verify', '--required', 'code-review', '--prior-required', 'code-review',
                                    success=False)
                self.assertIn('prior review order', refused.stderr)

    def test_wall_clock_step_back_keeps_partial_lineage(self):
        # The parent finishes exactly 1 s ahead: the upper edge of the absorbed step.
        self.record(plan='codex-cli:code-review\ncodex-cli:comment-analysis',
                    results='codex-cli:code-review\tcomplete\ncodex-cli:comment-analysis\tcomplete\n',
                    clock_ns=2 * 10**9)
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        self.git('commit', '-qm', 'fix', '--allow-empty')
        self.record(plan='codex-cli:comment-analysis', results='codex-cli:comment-analysis\tcomplete\n',
                    extra=('--parent', str(parent)), clock_ns=10**9)
        self.call('verify', '--required', 'code-review,comment-analysis')
        self.mutate(lambda r: r['parent'].update(finished_ns=r['started_ns'] + 1))
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

    def advance_develop_unrelated(self):
        self.git('switch', '-q', 'develop')
        Path('unrelated.txt').write_text('side\n')
        self.git('add', 'unrelated.txt')
        self.git('commit', '-qm', 'unrelated')
        self.git('switch', '-q', 'feature/test')

    def test_base_advance_same_diff_keeps_receipt_and_csv(self):
        self.commit_diff()
        self.record()
        receipt = self.receipt.read_bytes()
        report = (self.output / 'integrated-report.md').read_bytes()
        self.advance_develop_unrelated()
        result = self.call('verify', '--required', 'code-review')
        self.assertIn('base advanced, diff unchanged', result.stderr)
        self.assertNotIn('base advanced', result.stdout)
        self.assertEqual(result.stdout, 'code-review\n')
        self.assertEqual(self.receipt.read_bytes(), receipt)
        self.assertEqual((self.output / 'integrated-report.md').read_bytes(), report)

    def test_base_advance_that_shrinks_the_diff_is_rejected(self):
        self.commit_diff()
        self.record()
        self.git('branch', '-f', 'develop', 'HEAD')
        result = self.call('verify', success=False)
        self.assertIn('does not match', result.stderr)
        self.assertNotIn('base advanced, diff unchanged', result.stderr)

    def test_non_ancestor_base_is_rejected(self):
        self.commit_diff()
        self.record()
        root = subprocess.check_output(
            ['git', 'commit-tree', 'HEAD^{tree}', '-m', 'other root'], text=True).strip()
        self.git('branch', '-f', 'develop', root)
        result = self.call('verify', success=False)
        self.assertIn('does not match', result.stderr)

    def test_non_ancestor_move_with_the_same_diff_is_rejected(self):
        # 親を持たない root では merge base が無く diff の計算で落ちるので、祖先検査まで届かない。
        # merge base が残り三点 diff も同じ移動（develop を空コミットから親へ戻す）で、祖先検査そのものを見る。
        self.commit_diff()
        self.git('switch', '-q', 'develop')
        self.git('commit', '-q', '--allow-empty', '-m', 'empty on develop')
        self.git('switch', '-q', 'feature/test')
        self.record()
        self.git('branch', '-f', 'develop', 'develop^')
        result = self.call('verify', success=False)
        self.assertIn('does not match', result.stderr)
        self.assertNotIn('base advanced, diff unchanged', result.stderr)

    def test_continue_accepts_ancestor_base_at_the_recorded_head(self):
        self.commit_diff()
        self.record()
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        parent_bytes = parent.read_bytes()
        recorded_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        self.advance_develop_unrelated()
        # 空コミットでは現在 HEAD の三点 diff も記録 HEAD と一致し、比較対象の取り違えを通せます。
        Path('during-review.txt').write_text('later\n')
        self.git('add', 'during-review.txt')
        self.git('commit', '-qm', 'change the diff at the current head')
        current_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        self.assertNotEqual(current_head, recorded_head)
        result = self.call('begin', '--plan', 'codex-cli:code-review', '--parent', str(parent))
        self.assertIn('base advanced, diff unchanged', result.stderr)
        self.assertNotIn('previous review subject changed base', result.stderr)
        self.assertEqual(parent.read_bytes(), parent_bytes)

    def test_continue_finish_verify_keeps_parent_bytes(self):
        self.commit_diff()
        self.record()
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        parent_bytes = parent.read_bytes()
        self.advance_develop_unrelated()
        begin = self.call('begin', '--plan', 'codex-cli:code-review', '--parent', str(parent))
        self.assertIn('base advanced, diff unchanged', begin.stderr)
        (self.output / 'integrated-report.md').write_text(REPORT)
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        self.call('finish', '--results', str(self.output / 'results'))
        verified = self.call('verify', '--required', 'code-review')
        self.assertEqual(verified.stdout, 'code-review\n')
        self.assertEqual(parent.read_bytes(), parent_bytes)

    def test_continue_rejects_ancestor_base_when_parent_diff_changes(self):
        self.commit_diff()
        self.record()
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        self.git('branch', '-f', 'develop', 'HEAD')
        result = self.call('begin', '--plan', 'codex-cli:code-review', '--parent', str(parent), success=False)
        self.assertIn('previous review subject changed base', result.stderr)

    def test_embedded_parent_diff_change_is_lineage_rejection(self):
        self.commit_diff()
        self.record()
        parent = self.output / 'parent.json'
        shutil.copyfile(self.receipt, parent)
        self.call('begin', '--plan', 'codex-cli:code-review', '--parent', str(parent))
        (self.output / 'integrated-report.md').write_text(REPORT)
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        self.call('finish', '--results', str(self.output / 'results'))
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()

        def move(record):
            record['subject']['base'] = head

        self.mutate(move)
        result = self.call('verify', success=False)
        self.assertIn('partial review lineage changed base', result.stderr)

    def test_prior_accepts_same_head_base_advance(self):
        self.commit_diff()
        self.record()
        prior = self.output / 'prior.json'
        shutil.copyfile(self.receipt, prior)
        self.advance_develop_unrelated()
        begin = self.call('begin', '--plan', 'codex-cli:code-review', '--prior', str(prior))
        self.assertIn('base advanced, diff unchanged', begin.stderr)
        (self.output / 'integrated-report.md').write_text(REPORT)
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        self.call('finish', '--results', str(self.output / 'results'))
        self.call('verify', '--required', 'code-review', '--prior-required', 'code-review')

    def test_finish_rejects_in_run_base_advance(self):
        self.commit_diff()
        self.call('begin', '--plan', 'codex-cli:code-review')
        (self.output / 'integrated-report.md').write_text(REPORT)
        (self.output / 'results').write_text('codex-cli:code-review\tcomplete\n')
        self.advance_develop_unrelated()
        result = self.call('finish', '--results', str(self.output / 'results'), success=False)
        self.assertIn('repository changed during review', result.stderr)

if __name__ == '__main__':
    unittest.main()
