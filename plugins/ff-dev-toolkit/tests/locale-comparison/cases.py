#!/usr/bin/env python3
"""Exercise source functions; never replace the caller's UTF-8 locale globally."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

PLUGIN = Path(sys.argv.pop(1)).resolve()
REPO = PLUGIN.parent.parent if PLUGIN.parent.name == "plugins" else PLUGIN
AVAILABLE = subprocess.run(["locale", "-a"], capture_output=True, text=True, check=True, encoding='utf-8').stdout.splitlines()
LOCALES = [("C", {"LANG": "C"})]
for name in ("en_US.UTF-8", "ja_JP.UTF-8"):
    if name in AVAILABLE:
        LOCALES.append((name, {"LANG": name}))
if "en_US.UTF-8" in AVAILABLE:
    LOCALES.append(("inherited-LC_ALL", {"LANG": "ja_JP.UTF-8", "LC_ALL": "en_US.UTF-8"}))
for name in ("en_US.UTF-8", "ja_JP.UTF-8"):
    if name not in AVAILABLE:
        print(f"  ○ skip: locale-comparison の {name} は locale -a に無い（C の実関数検証は実行）")


def function(relative, name):
    text = (PLUGIN / relative).read_text(encoding='utf-8')
    matches = list(re.finditer(r"^" + re.escape(name) + r"\(\) \{[^\n]*\n.*?^\}", text, re.M | re.S))
    if len(matches) != 1:
        raise AssertionError(f"function extraction expected one {relative}:{name}, got {len(matches)}")
    return matches[0].group()


def run(body, args=(), stdin=None, variables=None, settings=None):
    env = os.environ.copy()
    for key in ("LANG", "LANGUAGE", "LC_ALL", "LC_COLLATE", "LC_CTYPE"):
        env.pop(key, None)
    env.update(settings or {})
    prefix = "\n".join(f"{key}={shlex.quote(str(value))}" for key, value in (variables or {}).items())
    script = 'ok() { :; }; bad() { printf "%s\\n" "$*" >&2; };\n' + prefix + "\n" + body
    return subprocess.run(["bash", "-c", script, "locale-case", *map(str, args)], input=stdin,
                          capture_output=True, text=True, env=env, timeout=30, encoding='utf-8')


class LocaleComparison(unittest.TestCase):
    def each(self, body, args=(), stdin=None, variables=None, expected="", rc=0):
        for label, settings in LOCALES:
            with self.subTest(locale=label):
                result = run(body, args, stdin, variables, settings)
                self.assertEqual(result.returncode, rc, result.stderr)
                self.assertEqual(result.stdout, expected, result.stderr)

    def test_h2_sections_keep_distinct_japanese_headings(self):
        fixture = "## 記録\nwrong\n## 承認\nwanted\n## 終端\n"
        for relative, name in (("tests/review-freeze-contract/verify.sh", "extract_h2_section"),
                               ("tests/long-task-commit-contract/verify.sh", "extract_section"),
                               ("tests/worktree-preflight-contract/verify.sh", "extract_section"),
                               ("tests/background-child-reclaim-contract/verify.sh", "extract_section"),
                               ("tests/review-severity-scope/verify.sh", "extract_h2_section")):
            with self.subTest(source=relative), tempfile.TemporaryDirectory() as tmp:
                source = Path(tmp) / "source.md"
                source.write_text(fixture, encoding='utf-8')
                self.each(function(relative, name) + '\n' + name + ' "$@"', ["## 承認", source], expected="wanted\n")

    def test_step_sections_and_terminator_keep_distinct_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.md"
            source.write_text("### ステップ6: 記録\nwrong\n### ステップ5: 別の終端\n### ステップ6: 承認\nwanted\n### ステップ7: 終端\n", encoding='utf-8')
            for name, expected in (("extract_section", "wanted\n"), ("section_terminator", "### ステップ7: 終端\n")):
                self.each(function("tests/review-freeze-contract/verify.sh", name) + '\n' + name + ' "$@"',
                          ["### ステップ6: 承認", source], expected=expected)

    def test_document_fences_keep_distinct_japanese_headings(self):
        for relative, name, lang in (("tests/docs-gates-runtime/verify.sh", "extract_bash_fence", "bash"),
                                    ("tests/docs-gates-runtime/ci-example-cases.sh", "extract_yaml_fence", "yaml")):
            with self.subTest(source=relative), tempfile.TemporaryDirectory() as tmp:
                source, output = Path(tmp) / "source.md", Path(tmp) / "out"
                source.write_text(f"### 記録\n```{lang}\nwrong\n```\n### 承認\n```{lang}\nwanted\n```\n", encoding='utf-8')
                self.each(function(relative, name) + '\n' + name + ' "$@" && cat "$3"',
                          [source, "### 承認", output], expected="wanted\n")

    def test_yaml_steps_keep_distinct_japanese_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / "source.yml", Path(tmp) / "out"
            source.write_text("      - name: 記録\n        run: wrong\n      - name: 承認\n        run: wanted\n      - name: end\n        run: end\n", encoding='utf-8')
            for name, expected in (("extract_yaml_run_step", "wanted\n"),
                                   ("extract_yaml_named_step", "      - name: 承認\n        run: wanted\n")):
                self.each(function("tests/docs-gates-runtime/ci-example-cases.sh", name) + '\n' + name + ' "$@" && cat "$3"',
                          [source, "承認", output], expected=expected)

    def test_typed_report_sections_keep_distinct_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "report.md"
            source.write_text("## 記録\nwrong\n## 承認\nwanted\n## 終端\n", encoding='utf-8')
            self.each(function("tests/multi-agent-critical-marker/verify.sh", "section_of") + '\nsection_of "$@"',
                      ["## 承認"], variables={"REPORT": source}, expected="wanted\n")

    def test_docs_mutation_reference_requires_exact_japanese_wording(self):
        text = (PLUGIN / "tests/docs-gates/verify.sh").read_text(encoding='utf-8')
        assignments = re.findall(r"^\s*(mutation_battery_reference='[^'\n]*')$", text, re.M)
        commands = [line.strip() for line in text.splitlines() if 'mutation_battery_reference_count="$(' in line]
        self.assertEqual(len(assignments), 1, "reference assignment must be uniquely extractable")
        self.assertEqual(len(commands), 1, "reference count command must be uniquely extractable")
        reference = shlex.split(assignments[0])[0].split("=", 1)[1]
        self.assertEqual(reference.count("複製せず"), 1, "Japanese alteration must change the actual reference")
        altered = reference.replace("複製せず", "複製し", 1)
        body = assignments[0] + '\n' + commands[0] + '\nprintf "%s\n" "$mutation_battery_reference_count"'
        for section, expected in ((reference, "1\n"), (altered, "0\n"),
                                   (reference + "\n" + reference, "2\n"), ("", "0\n")):
            with self.subTest(section=section):
                self.each(body, variables={"mutation_battery_section": section}, expected=expected)

    def test_docs_direct_guard_exception_requires_exact_japanese_heading(self):
        text = (PLUGIN / "tests/docs-gates/verify.sh").read_text(encoding='utf-8')
        blocks = re.findall(r'^unguarded_direct_commands=".*?^\x27 \{\} \+\)"', text, re.M | re.S)
        self.assertEqual(len(blocks), 1, "direct guard assignment must be uniquely extractable")
        headings = re.findall(r'in_pre_push = \(\$0 == "([^"]+)"\)', blocks[0])
        self.assertEqual(len(headings), 1, "exception heading must be uniquely extractable")
        heading = headings[0]
        self.assertEqual(heading.count("統合"), 1, "Japanese alteration must change the actual heading")
        command = 'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh"'
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "multi-cli-review-orchestration.md"
            for value, expected in ((heading, ""), (heading.replace("統合", "記録", 1), f"{source}:3:{command}")):
                source.write_text(value + "\n```bash\n" + command + "\n```\n", encoding='utf-8')
                self.each(blocks[0] + '\nprintf "%s" "$unguarded_direct_commands"',
                          variables={"DOCS": tmp}, expected=expected)

    def test_hook_axis_table_keeps_distinct_axes(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "labels.md"
            source.write_text("| 軸 | names |\n| 承認 | `priority:high` |\n| 記録 | `chore` |\n", encoding='utf-8')
            self.each(function("hooks/guard-issue-labels.sh", "extract_axis_labels") + '\nextract_axis_labels "$@"',
                      ["承認"], variables={"SKILL_MD": source}, expected="priority:high\n")

    def test_deploy_check_distinguishes_filled_and_placeholder(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "body.md"
            for value, expected in (("なし（コードのみ・反映を伴わない）", "present"),
                                    ("　（未記入）　", "unfilled"), ("(未記入)", "unfilled")):
                source.write_text(f"<!-- ff-effort:begin -->\n- effort_deploy: {value}\n<!-- ff-effort:end -->\n", encoding='utf-8')
                self.each(function("scripts/effort-report.sh", "deploy_check_report") + '\ndeploy_check_report "$@"',
                          [source], expected=f"effort_deploy={expected}\n")

    def test_transcript_cwd_set_preserves_live_japanese_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "記録"
            live.mkdir()
            for relative, name in (("scripts/sweep-orphan-transcripts.sh", "collect_cwds"),
                                   ("scripts/merge-cleanup.sh", "transcript_cwd_verdict")):
                # The earlier absent name collates equal to the live name in macOS en_US.
                records = root / "records"
                records.mkdir(exist_ok=True)
                (records / "a.jsonl").write_text(json.dumps({"cwd": str(root / "承認")}, ensure_ascii=False, separators=(",", ":")) + "\n" + json.dumps({"cwd": str(live)}, ensure_ascii=False, separators=(",", ":")) + "\n", encoding='utf-8')
                if name == "collect_cwds":
                    body = function(relative, name) + '\ncollect_cwds "$1"; rc=$?; cat "$WORK_TMP/cwds"; exit "$rc"'
                    self.each(body, [records], variables={"WORK_TMP": root},
                              expected=str(root / "承認") + "\n" + str(live) + "\n", rc=3)
                else:
                    body = function(relative, name) + '\ntranscript_cwd_verdict "$1" "$2"; rc=$?; cat "$WORK_TMP/transcript_foreign_cwd"; exit "$rc"'
                    self.each(body, [records, root / "承認"], variables={"WORK_TMP": root}, expected=str(live) + "\n")

    def test_release_bump_distinguishes_japanese_categories(self):
        relative = REPO / "scripts/release-dev-toolkit.sh"
        if not relative.is_file():
            self.skipTest("root release orchestrator is outside the public plugin layout")
        text = relative.read_text(encoding='utf-8')
        match = re.search(r"^bump_level\(\) \{[^\n]*\n.*?^\}", text, re.M | re.S)
        self.assertIsNotNone(match, "function extraction expected bump_level")
        for stdin, expected in (("修正\n", "patch\n"), ("追加\n", "minor\n"), ("修正\n追加\n", "minor\n")):
            self.each(match.group() + '\nbump_level', stdin=stdin, expected=expected)

    def test_metrics_gate_and_branch_filters_keep_distinct_repository_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            wanted, other = "/repo/承認/.git", "/repo/記録/.git"
            (root / "gate.tsv").write_text(f"777\tgate\t100\tiso\t60\tfull\tpass\tfix/#777-one\t{wanted}\n777\tgate\t100\tiso\t600\tfull\tpass\tfix/#777-two\t{other}\n", encoding='utf-8')
            self.each(function("scripts/effort-report.sh", "metrics_gate_minutes") + '\nmetrics_gate_minutes "$@"',
                      ["777", root, wanted], expected="gate_runs=1\ngate_minutes=1\n")
            wc = root / "wallclock.tsv"
            wc.write_text(f"777\tstart\t100\tiso\ts1\tfix/#777-one\t{wanted}\n777\tstart\t100\tiso\ts2\tfix/#777-two\t{other}\n", encoding='utf-8')
            self.each(function("scripts/effort-report.sh", "metrics_issue_branches") + '\nmetrics_issue_branches "$@"',
                      ["777", root, wc, wanted], expected="fix/#777-one\n")

    def test_metrics_report_keeps_wallclock_and_instruction_repositories_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            wanted, other = "/repo/承認/.git", "/repo/記録/.git"
            (root / "wallclock.tsv").write_text(f"777\tstart\t100\tstart\ts1\tbranch\t{wanted}\n777\tend\t200\tend\ts1\tbranch\t{wanted}\n777\tstart\t10\twrong\ts2\tbranch\t{other}\n777\tend\t4000\twrong\ts2\tbranch\t{other}\n", encoding='utf-8')
            (root / "instruction-bytes.tsv").write_text(f"777\ts1\t11\tiso\tx\t{wanted}\n777\ts2\t99\tiso\tx\t{other}\n", encoding='utf-8')
            helpers = 'metrics_repo_key() { printf "%s" "$1"; }; metrics_reflog_start() { :; }; metrics_review_rounds() { :; }; metrics_gate_minutes() { :; };\n'
            body = helpers + function("scripts/effort-report.sh", "metrics_issue_report") + '\nmetrics_issue_report "$@"'
            expected = f"issue=777\nmetrics_dir={root}\nrepo={wanted}\nwallclock_source=hook\nwallclock_start=start\nwallclock_end=end\nwallclock_actual_h=0.0\ninstruction_bytes=11\n"
            self.each(body, ["777", root, wanted], expected=expected)

    def test_native_detector_does_not_end_japanese_heredoc_at_another_word(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "input.sh"
            source.write_text("cat <<承認\n記録\ncodex exec secret\n承認\n", encoding='utf-8')
            self.each(function("tests/review-wrapper-shim/direct-cli-detector-cases.sh", "detects_direct_cli") + '\ndetects_direct_cli "$@"',
                      [source], variables={"DIRECT_CLI_DETECTOR": PLUGIN / "tests/review-wrapper-shim/direct-cli-detector.awk"}, rc=1)

    def test_knowledge_pending_update_preserves_other_japanese_path(self):
        text = (PLUGIN / "scripts/knowledge-commit.sh").read_text(encoding='utf-8')
        lines = text.splitlines()
        candidates = [i for i, line in enumerate(lines) if "-v p=\"$p\"" in line and "OFS = FS" in line]
        self.assertEqual(len(candidates), 1, "pending path update must be uniquely extractable")
        body = "\n".join(lines[candidates[0]:candidates[0] + 2]) + '\ncat "$pending"'
        with tempfile.TemporaryDirectory() as tmp:
            pending = Path(tmp) / "pending.tsv"
            for label, settings in LOCALES:
                with self.subTest(locale=label):
                    pending.write_text("P\t承認.md\tfirst\nP\t記録.md\tsecond\n", encoding='utf-8')
                    result = run(body, variables={"pending": pending, "p": "承認.md"}, settings=settings)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "P\t記録.md\tsecond\n")

    def test_custom_sandbox_preserves_unrelated_japanese_sibling_grant(self):
        text = (PLUGIN / "scripts/adapters/grok-cli-adapter.sh").read_text(encoding='utf-8')
        start = text.index('  sandbox_verdict="$(printf')
        end = text.index(' || sandbox_verdict="awk-failed"', start)
        body = text[start:end] + '\nprintf "%s\\n" "$sandbox_verdict"'
        workspace = "/repo/承認"
        for grant, expected in (("/repo/記録", "confirmed\n"), (workspace, "write-granted\n"), ("/repo", "write-granted\n")):
            event = json.dumps({"event_type": "ProfileApplied", "profile": "readonly-custom", "workspace": workspace,
                                "enforced": True, "read_write_paths": [grant]}, ensure_ascii=False, separators=(",", ":"))
            self.each(body, variables={"new_sandbox_events": event, "sandbox_workspace": workspace,
                                      "sandbox_profile": "readonly-custom", "sandbox_custom": "true"}, expected=expected)

    def test_cleanup_sort_producers_preserve_distinct_japanese_branch_names(self):
        for relative, target, with_oid in (("scripts/lib/merge-cleanup-remote.sh", "MERGED_LIST", True),
                                           ("scripts/lib/merge-cleanup-remote.sh", "OPEN_LIST", False),
                                           ("scripts/lib/merge-cleanup-local.sh", "REMOTE_LIST", True)):
            with self.subTest(producer=target), tempfile.TemporaryDirectory() as tmp:
                text = (PLUGIN / relative).read_text(encoding='utf-8')
                lines = [line for line in text.splitlines() if "sort -u" in line and f'> "${target}"' in line]
                self.assertEqual(len(lines), 1, "cleanup producer command must be uniquely extractable")
                command = lines[0].rsplit("|", 1)[-1].strip()
                suffix = "\t" + "a" * 40 if with_oid else ""
                expected = "\n".join(name + suffix for name in ("承認", "記録")) + "\n"
                self.each(command + f'\ncat "${target}"', stdin=expected,
                          variables={target: Path(tmp) / "branches"}, expected=expected)

    def test_cleanup_intersection_keeps_distinct_japanese_branch_names(self):
        text = (PLUGIN / "scripts/lib/merge-cleanup-local.sh").read_text(encoding='utf-8')
        lines = [line for line in text.splitlines() if 'LEFTOVER="$(' in line and "comm -12" in line]
        self.assertEqual(len(lines), 1, "cleanup intersection command must be unique")
        with tempfile.TemporaryDirectory() as tmp:
            left, right = Path(tmp) / "left", Path(tmp) / "right"
            left.write_text("承認\t" + "a" * 40 + "\n", encoding='utf-8')
            right.write_text("記録\t" + "a" * 40 + "\n", encoding='utf-8')
            self.each(lines[0] + '\nprintf "%s" "$LEFTOVER"', variables={"MERGED_LIST": left, "REMOTE_LIST": right})

    def test_review_failure_file_count_preserves_distinct_japanese_diff_headers(self):
        text = (PLUGIN / "scripts/lib/multi-agent-failure.sh").read_text(encoding='utf-8')
        lines = [line for line in text.splitlines() if 'files="$(' in line and "sort -u" in line]
        self.assertEqual(len(lines), 1, "review failure diff count command must be unique")
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "diff"
            source.write_text("diff --git a/承認 b/承認\ndiff --git a/記録 b/記録\n", encoding='utf-8')
            self.each(lines[0] + '\nprintf "%s\\n" "$files"', variables={"FIXED_DIFF_FILE": source}, expected="2\n")

    def test_referenced_heading_counts_keep_other_japanese_headings_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, refs = root / "source.md", root / "refs"
            refs.mkdir()
            source.write_text("### 承認\n", encoding='utf-8')
            (refs / "other.md").write_text("### 記録\n", encoding='utf-8')
            for relative in ("tests/retrospective-contract/verify.sh", "tests/out-of-scope-routing/verify.sh"):
                lines = [line for line in (PLUGIN / relative).read_text(encoding='utf-8').splitlines() if 'n="$(' in line and '-v h="$heading"' in line]
                self.assertEqual(len(lines), 1, "referenced heading counter must be unique")
                variables = {"heading": "### 承認", "SKILL": source, "SKILL_REFS": refs, "other": refs / "other.md"}
                self.each(lines[0] + '\nprintf "%s\\n" "$n"', variables=variables,
                          expected="1\n" if "retrospective" in relative else "0\n")

    def test_default_playbook_lookup_keeps_other_japanese_path_separate(self):
        text = (PLUGIN / "scripts/knowledge-lookup.sh").read_text(encoding='utf-8')
        lines = [line for line in text.splitlines() if 'src="$(' in line and 'ace-record-hits' in line]
        self.assertEqual(len(lines), 1, "recorded default path command must be unique")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ace-record-hits").write_text("wrong\t/repo/承認.md\nright\t/repo/記録.md\n", encoding='utf-8')
            self.each(lines[0] + '\nprintf "%s\\n" "$src"', variables={"TMP": root, "def": "/repo/記録.md"}, expected="right\n")

    def test_release_tag_difference_keeps_distinct_japanese_names(self):
        source = REPO / "scripts/release-dev-toolkit.sh"
        if not source.is_file():
            self.skipTest("root release orchestrator is outside the public plugin layout")
        lines = [line for line in source.read_text(encoding='utf-8').splitlines() if 'missing="$(' in line and 'comm -23' in line]
        self.assertEqual(len(lines), 1, "tag difference command must be unique")
        self.each(lines[0] + '\nprintf "%s" "$missing"',
                  variables={"tags": "承認\n記録", "rels": "記録"}, expected="承認")

    def test_absent_heading_is_rejected_instead_of_selecting_another_word(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.md"
            source.write_text("## 記録\nwrong\n## 終端\n", encoding='utf-8')
            self.each(function("tests/review-freeze-contract/verify.sh", "extract_h2_section") + '\nextract_h2_section "$@"',
                      ["## 承認", source], rc=1)

    def test_empty_source_is_not_a_successful_extraction(self):
        with self.assertRaises(AssertionError):
            function("tests/locale-comparison/verify.sh", "extract_h2_section")


if __name__ == "__main__":
    unittest.main(verbosity=2)
