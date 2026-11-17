# shellcheck shell=bash
# 鍵 issue-collision: hooks/guard-issue-collision.sh（PreToolUse(Bash)）。止める効果 = deny。
# git と gh は作業ディレクトリの stub。リモートに同じ番号のブランチがあるときだけ止める。
fx_owners='hooks/guard-issue-collision.sh'
fx_setup() {
  mkdir -p "$fx_wk/bin" "$fx_wk/repo" || return 1
  cat > "$fx_wk/bin/git" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -C) shift 2; continue ;;
    *) break ;;
  esac
done
case "$*" in
  *ls-remote*) printf 'abc\trefs/heads/feature/#9-other\n'; exit 0 ;;
  *symbolic-ref*) printf '%s\n' develop; exit 0 ;;
esac
exit 0
EOF
  cat > "$fx_wk/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' '[]'
exit 0
EOF
  chmod +x "$fx_wk/bin/git" "$fx_wk/bin/gh" || return 1
  fx_bash_input "git switch -c 'feature/#9-new'" "$fx_wk/repo" > "$fx_wk/in.json"
}
fx_run() {
  PATH="$fx_wk/bin:$PATH" fx_hook hooks/guard-issue-collision.sh
}
fx_judge() { fx_judge_deny; }
