# shellcheck shell=bash
# ACK issue-label: hooks/guard-issue-labels.sh。入力: 区間の先頭の前置でのラベルの無い `gh issue create --title t`。
# 旧名は名簿の skip-legacy（同じ鍵の kind=skip の旧名を 1 回分の前置として読む）。hook の環境に置く形は
# kind=skip の鍵 issue-label が受ける（skip の表が見る）。gh は tests/guard-issue-labels の stub。
fx_owners='hooks/guard-issue-labels.sh'
fx_forms='prefix'
fx_setup() { :; }
fx_input() { fx_bash_input "${fx_ack_prefix-}gh issue create --title t" "$fx_wk" > "$fx_wk/in.json"; }
fx_run() { PATH="$fx_plugin/tests/guard-issue-labels/fixtures/bin:$PATH" fx_hook hooks/guard-issue-labels.sh; }
