# shellcheck shell=bash
# 鍵 issue-assign: hooks/guard-issue-assign.sh（PreToolUse(Bash)）。止める効果 = deny。
# gh は作業ディレクトリの stub。open かつ未アサインの Issue へのブランチ作成だけ止める。
fx_owners='hooks/guard-issue-assign.sh'
fx_setup() {
  mkdir -p "$fx_wk/bin" "$fx_wk/repo" || return 1
  cat > "$fx_wk/bin/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *"api "*"user"*) printf '%s\n' tester; exit 0 ;;
  *"issue view"*) printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$fx_wk/bin/gh" || return 1
  fx_bash_input "git switch -c 'feature/#9-new'" "$fx_wk/repo" > "$fx_wk/in.json"
}
fx_run() {
  PATH="$fx_wk/bin:$PATH" fx_hook hooks/guard-issue-assign.sh
}
fx_judge() { fx_judge_deny; }
