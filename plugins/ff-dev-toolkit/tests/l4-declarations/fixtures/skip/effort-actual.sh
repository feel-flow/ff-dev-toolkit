# shellcheck shell=bash
# 鍵 effort-actual: hooks/guard-effort-actual.sh（PreToolUse(Bash)）。止める効果 = deny（閉じる Issue の
# ff-effort ブロックの effort_ai_actual が未記入のままのマージ）。
# 入力: `gh pr merge 42 --squash`。gh の stub は pr view 42 に Issue 900 を閉じる PR を、issue view 900 に
# 未記入のブロックを返す（番号の印は実行時に組む）。
fx_owners='hooks/guard-effort-actual.sh'
fx_setup() {
  local fx_h='#'
  mkdir -p "$fx_wk/bin" "$fx_wk/stub" || return 1
  {
    printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$fx_stub_dir/calls"' 'res="${1:-}"; verb="${2:-}"; shift 2 2>/dev/null || true; sel=""'
    printf '%s\n' 'while [ "$#" -gt 0 ]; do case "$1" in --json | --jq | --repo | -R) shift 2; continue ;; -*) shift; continue ;; *) [ -n "$sel" ] || sel="$1"; shift ;; esac; done'
    printf '%s\n' '[ "$verb" = view ] || exit 1' 'f="$fx_stub_dir/${res}-${sel:-current}.json"' '[ -f "$f" ] || exit 1' 'cat "$f"'
  } > "$fx_wk/bin/gh"
  chmod +x "$fx_wk/bin/gh"
  jq -n --arg b "Closes ${fx_h}900" '{number: 42, body: $b, url: "https://example.invalid/acme/widgets/pull/42",
    closingIssuesReferences: [{number: 900, url: "https://example.invalid/acme/widgets/issues/900"}]}' > "$fx_wk/stub/pr-42.json"
  jq -n --arg b '<!-- ff-effort:begin -->
- effort_human_planned: 1.0d
- effort_ai_planned: 0.5d
- effort_ai_actual: (未記入)
<!-- ff-effort:end -->' '{body: $b, state: "OPEN"}' > "$fx_wk/stub/issue-900.json"
  fx_bash_input 'gh pr merge 42 --squash' "$fx_wk" > "$fx_wk/in.json"
}
fx_run() { fx_stub_dir="$fx_wk/stub" PATH="$fx_wk/bin:$PATH" fx_hook hooks/guard-effort-actual.sh; }
fx_judge() { fx_judge_deny; }
