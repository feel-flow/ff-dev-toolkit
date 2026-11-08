"""Host delegation cases of review-evidence (split from cases.py, Issue `#2695`).

Evidence in cases.py inherits this mixin, so these tests run through `python3 cases.py`
with the same setUp and helpers.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/review-evidence.py'


class HostDelegationCases:
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
