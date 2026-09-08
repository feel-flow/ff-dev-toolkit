#!/usr/bin/env bash
#
# hooks/check-skill-drift.sh（スキル実体ドリフト検査、Issue #656 / #998）の回帰検証。
#
# 実 ~/.claude には触れない。FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT と
# FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME で fixture を注入する。
#
# 固定する経路（Issue の 4 GWT + 配線 + 検出力）:
#   - リポジトリのスキル集合がどのインストール実体より多い → 欠けているスキル名を
#     名指しし、リポジトリ version とインストール実体の version を併記する
#   - インストール実体が複数バージョン併存 → 全パスと version を列挙する
#     （1 つだけを見て「最新」と判定しない）
#   - version とスキル集合が一致する 1 実体 → 無出力
#   - インストール実体 0 件 → 「検出不能」を報告して exit 0
#   - 更新案内は素の plugin 名に依存しない（掃除手順と検出不能の両方。
#     marketplace update → plugin list → 確認した ID で plugin update）
#   - hooks.json の SessionStart 配線・timeout・実行権限
#   - スキル集合差分検出を落とす変異 / 併存列挙を 1 件に潰す変異が、
#     それぞれ報告を消す（検出力の実測）
#   - 登録 ID 形式の案内を除く変異は形式説明だけを消し、欠落スキル /
#     検出不能の報告は残す（単独で赤）
#
# すべての経路で exit 0 と stderr 無出力を検査する（fail-open 契約）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/check-skill-drift.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ hooks/check-skill-drift.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です（通知 JSON の構文検証に使用）" >&2; exit 1; }

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi

FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ skill-drift-check: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

make_named_plugin() {
  # $1 dest  $2 plugin name  $3 version  remaining: skill names
  local dest="$1" pname="$2" ver="$3" skill
  shift 3
  mkdir -p "$dest/.claude-plugin" "$dest/skills"
  printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$pname" "$ver" > "$dest/.claude-plugin/plugin.json"
  for skill in "$@"; do
    mkdir -p "$dest/skills/$skill"
    printf '%s\n' "---" "name: ${skill}" "description: fixture" "---" "# ${skill}" > "$dest/skills/${skill}/SKILL.md"
  done
}

make_plugin() {
  # $1 dest  $2 version  remaining: skill names
  local dest="$1" ver="$2"
  shift 2
  make_named_plugin "$dest" "ff-dev-toolkit" "$ver" "$@"
}

OUT=""
ERR=""
RC=0
run_hook() {
  # 呼び出し側環境の CLAUDE_PLUGIN_ROOT / オプトアウト / シームを打ち消してから
  # 明示 env を載せる。
  RC=0
  OUT="$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CONFIG_DIR \
    -u FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK \
    -u FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT \
    -u FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME \
    HOME="$TMP/fake-home" \
    "$@" bash "$HOOK" 2>"$TMP/stderr")" || RC=$?
  ERR="$(cat "$TMP/stderr" 2>/dev/null || true)"
}

assert_clean() {
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then
    ok "$1: exit 0 + stderr 無出力"
  else
    bad "$1: exit=$RC stderr=[$ERR]"
  fi
}

assert_json() {
  if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
    && [ "$(printf '%s' "$OUT" | jq -s 'length')" = "1" ]; then
    ok "$1: 出力が単一の valid JSON オブジェクト"
  else
    bad "$1: 出力が単一 JSON として解析できない: $OUT"
  fi
}

sysmsg() {
  printf '%s' "$OUT" | jq -er '.systemMessage' 2>/dev/null || true
}

addctx() {
  printf '%s' "$OUT" | jq -er '.hookSpecificOutput.additionalContext' 2>/dev/null || true
}

assert_update_guidance() {
  # $1 = 経路ラベル。marketplace update → plugin list → 確認した ID で
  # plugin update。素の名前と marketplace 名の固定を禁じる。
  local ac missing frag
  ac="$(addctx)"
  missing=""
  for frag in "claude plugin marketplace update" "claude plugin list" "claude plugin update"; do
    printf '%s' "$ac" | grep -F "$frag" >/dev/null || missing="$missing [$frag]"
  done
  if [ -z "$missing" ]; then
    ok "$1: additionalContext に更新手順 3 段を含む"
  else
    bad "$1: additionalContext に欠けている案内:$missing"
  fi
  if printf '%s' "$ac" | grep -F "claude plugin update に" >/dev/null \
    && printf '%s' "$ac" | grep -F "確認した ID を渡す" >/dev/null; then
    ok "$1: 確認した登録 ID を update に渡す手順を案内している"
  else
    bad "$1: 確認した登録 ID を update に渡す手順が無い"
  fi
  # 対照が経路へ届いていること（ACE-924-2）。空出力への否定は空振りする。
  # grep -q は使わない（TESTING.md: パイプ下流の早期終了が SIGPIPE で反転する）。
  if [ -z "$OUT" ]; then
    bad "$1: 案内コマンド: 対照が経路へ届いていない（否定の主張が空振りする）"
  elif printf '%s' "$OUT" | grep -E 'claude plugin update ff-dev-toolkit([^@]|$)' >/dev/null; then
    bad "$1: 案内コマンド: 素の plugin 名で update を案内している（not found になる）"
  else
    ok "$1: 素の plugin 名での update を案内していない"
  fi
  if [ -z "$OUT" ]; then
    :
  elif printf '%s' "$OUT" | grep -F "marketplace update ff-dev-toolkit" >/dev/null; then
    bad "$1: marketplace 名を固定した更新コマンドを案内している"
  else
    ok "$1: marketplace 名を固定していない"
  fi
  if printf '%s' "$ac" | grep -F 'プラグイン名@marketplace名' >/dev/null; then
    ok "$1: 登録 ID が plugin@marketplace 形式であることを案内している"
  else
    bad "$1: 登録 ID の形式説明が無い"
  fi
}

FIX="$TMP/plugin"
mkdir -p "$FIX/hooks" "$FIX/.claude-plugin"
cp "$TARGET" "$FIX/hooks/check-skill-drift.sh"
cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$FIX/hooks/asdd-hook-gate.sh"
printf '{\n  "name": "ff-dev-toolkit",\n  "version": "0.40.0"\n}\n' > "$FIX/.claude-plugin/plugin.json"
HOOK="$FIX/hooks/check-skill-drift.sh"
chmod +x "$HOOK"

echo "== skill-drift-check =="

# ---- 1. リポジトリのスキル集合がインストール実体より多い ----------------------
REPO="$TMP/repo-extra"
CLAUDE="$TMP/claude-extra"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta extra-skill
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha beta
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
assert_clean "スキル集合差分"
assert_json "スキル集合差分"
if sysmsg | grep -F "extra-skill" >/dev/null \
  && sysmsg | grep -F "v0.40.0" >/dev/null \
  && sysmsg | grep -F "v0.28.0" >/dev/null; then
  ok "スキル集合差分: 欠けているスキル名と双方の version を名指しする"
else
  bad "スキル集合差分: 名指しが不足: $(sysmsg)"
fi
if sysmsg | grep -F "無いスキル: extra-skill" >/dev/null \
  && ! sysmsg | grep -E '無いスキル:.*\balpha\b' >/dev/null \
  && ! sysmsg | grep -E '無いスキル:.*\bbeta\b' >/dev/null; then
  ok "スキル集合差分: 存在するスキルを欠けていると誤報しない"
else
  bad "スキル集合差分: 欠けていないスキルまで名指ししている: $(sysmsg)"
fi
if [ "$(printf '%s' "$OUT" | jq -er '.hookSpecificOutput.hookEventName' 2>/dev/null)" = "SessionStart" ]; then
  ok "スキル集合差分: hookEventName が SessionStart"
else
  bad "スキル集合差分: hookEventName が不正"
fi
assert_update_guidance "スキル集合差分"
# 実ホームの Claude 設定を見に行った退行。リテラルのホームパスは公開対象の
# 禁止パターンに当たるので、実行時の HOME から組み立てて照合する。
REAL_CLAUDE_HOME="${HOME}/.claude"
if printf '%s' "$OUT" | grep -F "$REAL_CLAUDE_HOME" >/dev/null; then
  bad "スキル集合差分: 実 Claude 設定ディレクトリを走査している"
else
  ok "スキル集合差分: 実 Claude 設定ディレクトリを走査していない"
fi

# ---- 2. インストール実体の複数バージョン併存 ---------------------------------
REPO="$TMP/repo-coexist"
CLAUDE="$TMP/claude-coexist"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.19.0" "0.19.0" alpha beta
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
assert_clean "併存列挙"
assert_json "併存列挙"
MSG="$(sysmsg)"
if printf '%s' "$MSG" | grep -F "0.28.0" >/dev/null \
  && printf '%s' "$MSG" | grep -F "0.19.0" >/dev/null; then
  ok "併存列挙: 全 version を列挙する（1 つだけを最新と判定しない）"
else
  bad "併存列挙: version の列挙が不足: $MSG"
fi
if printf '%s' "$MSG" | grep -F "cache/mp/ff-dev-toolkit/0.28.0" >/dev/null \
  && printf '%s' "$MSG" | grep -F "cache/mp/ff-dev-toolkit/0.19.0" >/dev/null; then
  ok "併存列挙: 全パスを列挙する"
else
  bad "併存列挙: パスの列挙が不足: $MSG"
fi
if [ -d "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" ] \
  && [ -d "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.19.0" ]; then
  ok "併存列挙: インストール実体を削除しない"
else
  bad "併存列挙: 検査後にインストール実体が消えている"
fi
assert_update_guidance "併存列挙"

# 同一 version の cache + marketplace は Claude Code の通常構成 → 無音
REPO="$TMP/repo-mp"
CLAUDE="$TMP/claude-mp"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.40.0" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/marketplaces/mp/plugins/ff-dev-toolkit" "0.40.0" alpha beta
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
assert_clean "同一 version の cache+marketplace"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "同一 version の cache+marketplace: 無出力（通常構成）"
else
  bad "同一 version の cache+marketplace: 誤って併存通知した: output=[$OUT]"
fi

# version が違えば cache と marketplace の両方を列挙する
REPO="$TMP/repo-mp-diff"
CLAUDE="$TMP/claude-mp-diff"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha beta
make_plugin "$CLAUDE/plugins/marketplaces/mp/plugins/ff-dev-toolkit" "0.40.0" alpha beta
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
assert_clean "異 version の cache+marketplace"
if sysmsg | grep -F "cache/mp/ff-dev-toolkit/0.28.0" >/dev/null \
  && sysmsg | grep -F "marketplaces/mp/plugins/ff-dev-toolkit" >/dev/null \
  && sysmsg | grep -F "0.28.0" >/dev/null \
  && sysmsg | grep -F "0.40.0" >/dev/null; then
  ok "異 version の cache+marketplace: 全パスと version を列挙する"
else
  bad "異 version の cache+marketplace: 列挙が不足: $(sysmsg)"
fi

# 隣の別プラグインは数えない（name フィルタ）
REPO="$TMP/repo-neighbor"
CLAUDE="$TMP/claude-neighbor"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.40.0" "0.40.0" alpha beta
make_named_plugin "$CLAUDE/plugins/cache/mp/other-plugin/1.0.0" "other-plugin" "1.0.0" gamma
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "隣の別プラグイン: 無出力（name フィルタ）"
else
  bad "隣の別プラグイン: 誤って併存通知した: output=[$OUT]"
fi

# union: 実体A と B でスキルが分かれていても、欠けていないスキルは報告しない
REPO="$TMP/repo-union"
CLAUDE="$TMP/claude-union"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.19.0" "0.19.0" beta
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
assert_clean "スキル union"
if sysmsg | grep -F "0.28.0" >/dev/null \
  && sysmsg | grep -F "0.19.0" >/dev/null \
  && ! sysmsg | grep -F "無いスキル:" >/dev/null; then
  ok "スキル union: 併存は報告し、欠けていないスキルは名指ししない"
else
  bad "スキル union: 欠落の誤報または併存漏れ: $(sysmsg)"
fi

# ---- 3. 一致している 1 実体は無出力 ------------------------------------------
REPO="$TMP/repo-match"
CLAUDE="$TMP/claude-match"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.40.0" "0.40.0" alpha beta
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "一致: 無出力 + exit 0"
else
  bad "一致: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# version だけ違う 1 実体（スキル集合は一致）もこの hook は無音。更新通知は別 hook。
REPO="$TMP/repo-ver"
CLAUDE="$TMP/claude-ver"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha beta
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "version のみ不一致: 無出力（更新通知 hook の管轄）"
else
  bad "version のみ不一致: 誤って通知した: output=[$OUT]"
fi

# ---- 4. インストール実体 0 件は検出不能 + exit 0 -------------------------------
REPO="$TMP/repo-none"
CLAUDE="$TMP/claude-none"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
mkdir -p "$CLAUDE"
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
assert_clean "検出不能"
assert_json "検出不能"
if sysmsg | grep -F "検出不能" >/dev/null; then
  ok "検出不能: systemMessage に「検出不能」を含む"
else
  bad "検出不能: 文言が無い: $(sysmsg)"
fi
assert_update_guidance "検出不能"

# リポジトリ skills/ が無い（配布先）は無音
REPO="$TMP/repo-consumer"
mkdir -p "$REPO"
CLAUDE="$TMP/claude-consumer"
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.40.0" "0.40.0" alpha
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "配布先（repo skills なし）: 無出力 + exit 0"
else
  bad "配布先: 誤って通知した: output=[$OUT]"
fi

# ---- 5. オプトアウト ----------------------------------------------------------
REPO="$TMP/repo-skip"
CLAUDE="$TMP/claude-skip"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha extra-skill
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha
run_hook \
  FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1 \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "オプトアウト: 無出力 + exit 0"
else
  bad "オプトアウト: exit=$RC output=[$OUT]"
fi

# ---- 6. CLAUDE_PLUGIN_ROOT もインストール実体に数える --------------------------
REPO="$TMP/repo-root"
CLAUDE="$TMP/claude-root"
DETACHED="$TMP/detached-root"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta extra-skill
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha beta
make_plugin "$DETACHED" "0.14.0" alpha
run_hook \
  CLAUDE_PLUGIN_ROOT="$DETACHED" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
assert_clean "CLAUDE_PLUGIN_ROOT"
if sysmsg | grep -F "extra-skill" >/dev/null \
  && sysmsg | grep -F "0.14.0" >/dev/null \
  && sysmsg | grep -F "0.28.0" >/dev/null; then
  ok "CLAUDE_PLUGIN_ROOT: cache と別実体として列挙される"
else
  bad "CLAUDE_PLUGIN_ROOT: 別実体として列挙されない: $(sysmsg)"
fi

# CLAUDE_PLUGIN_ROOT が cache と同じ実体なら重複しない
REPO="$TMP/repo-dedup"
CLAUDE="$TMP/claude-dedup"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.40.0" "0.40.0" alpha beta
run_hook \
  CLAUDE_PLUGIN_ROOT="$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.40.0" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "CLAUDE_PLUGIN_ROOT=cache: 同一実体は 1 件に畳んで無出力"
else
  bad "CLAUDE_PLUGIN_ROOT=cache: 重複列挙した: output=[$OUT]"
fi

# ---- 7. hooks.json の静的整合 -------------------------------------------------
if jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json: valid JSON"
else
  bad "hooks.json: JSON として解析できない"
fi
if jq -r '.hooks.SessionStart[0].hooks[] | .command' "$HOOKS_JSON" 2>/dev/null \
  | grep "check-skill-drift.sh" >/dev/null; then
  ok "hooks.json: SessionStart に check-skill-drift.sh が command 登録されている"
else
  bad "hooks.json: SessionStart の command 登録が不正"
fi
SKILL_DRIFT_TIMEOUT="$(jq -r '.hooks.SessionStart[0].hooks[] | select(.command | contains("check-skill-drift.sh")) | .timeout' "$HOOKS_JSON" 2>/dev/null)"
if [ "$SKILL_DRIFT_TIMEOUT" = "5" ]; then
  ok "hooks.json: timeout が 5"
else
  bad "hooks.json: timeout が 5 ではない（${SKILL_DRIFT_TIMEOUT}）"
fi
if jq -r '.hooks.SessionStart[0].hooks[] | select(.command | contains("check-skill-drift.sh")) | .command' "$HOOKS_JSON" 2>/dev/null \
  | grep -F '${CLAUDE_PLUGIN_ROOT}/hooks/check-skill-drift.sh' >/dev/null; then
  ok "hooks.json: command が CLAUDE_PLUGIN_ROOT 経由"
else
  bad "hooks.json: command が CLAUDE_PLUGIN_ROOT 経由ではない"
fi
if jq -r '.hooks.SessionStart[0].hooks[] | select(.command | contains("check-update.sh")) | .command' "$HOOKS_JSON" 2>/dev/null \
  | grep "check-update.sh" >/dev/null; then
  ok "hooks.json: check-update.sh も SessionStart に残っている"
else
  bad "hooks.json: check-update.sh の登録が消えている"
fi
if [ -x "$TARGET" ]; then
  ok "check-skill-drift.sh: 実行権限がある"
else
  bad "check-skill-drift.sh: 実行権限が無い"
fi

# ---- 7b. 掃除手順の順序（Issue #999） ------------------------------------------
# 旧手順は削除を (1) に置いており、稼働中セッションがロードしているバージョンの
# 実体まで削除対象に入った（hook は発火のたびに起動時スナップショットのディスク
# 実体を読むため、削除後は SessionStart / Stop hook がそのセッションの残りの間
# ずっと壊れる — 2026-08-29 実測）。「更新 → 再起動 → 再起動後に削除」の順序と
# ロード中バージョンの除外文言を、案内文そのものに対して固定する。
# needle は説明コメントではなくコード行（ctx への連結行）に一致させる（ACE-156-1）。
CLEANUP_NEEDLE='古いキャッシュは自動削除しない。掃除手順'
cleanup_line="$(grep -F "$CLEANUP_NEEDLE" "$TARGET" | grep -v '^#' | head -1)"
if [ -n "$cleanup_line" ]; then
  ok "掃除手順の案内文がコード行に存在する"
else
  bad "掃除手順の案内文が見つからない"
fi
cleanup_pos() { # $1: 部分文字列。見つからなければ 0
  printf '%s\n' "$cleanup_line" | awk -v s="$1" '{ print index($0, s) }'
}
POS_UPDATE="$(cleanup_pos '(1) claude plugin marketplace update')"
POS_LIST="$(cleanup_pos 'claude plugin list')"
POS_PLUGIN_UPDATE="$(cleanup_pos 'claude plugin update')"
POS_RESTART="$(cleanup_pos '再起動が必要')"
POS_DELETE="$(cleanup_pos '手動で削除する')"
POS_AFTER_RESTART="$(cleanup_pos '再起動後に')"
if [ "$POS_UPDATE" -gt 0 ] && [ "$POS_DELETE" -gt 0 ] && [ "$POS_UPDATE" -lt "$POS_DELETE" ]; then
  ok "掃除手順: 手順の先頭が削除ではなく marketplace update（削除は後段）"
else
  bad "掃除手順: 削除が marketplace update より前にある（update=${POS_UPDATE} delete=${POS_DELETE}）"
fi
# 中間手順（plugin list → plugin update）の存在と順序も固定する。ここが欠落・
# 再起動後へ移動しても他検査は緑のままで、「更新せず古い実体だけ消させる」案内へ
# 退行しうる（Codex test-analysis 指摘）
if [ "$POS_LIST" -gt 0 ] && [ "$POS_PLUGIN_UPDATE" -gt 0 ] && [ "$POS_RESTART" -gt 0 ] \
  && [ "$POS_UPDATE" -lt "$POS_LIST" ] && [ "$POS_LIST" -lt "$POS_PLUGIN_UPDATE" ] \
  && [ "$POS_PLUGIN_UPDATE" -lt "$POS_RESTART" ]; then
  ok "掃除手順: marketplace update → plugin list → plugin update → 再起動 の順序が保たれている"
else
  bad "掃除手順: 中間手順の欠落または順序退行（update=${POS_UPDATE} list=${POS_LIST} pupdate=${POS_PLUGIN_UPDATE} restart=${POS_RESTART}）"
fi
if [ "$POS_RESTART" -gt 0 ] && [ "$POS_AFTER_RESTART" -gt 0 ] && [ "$POS_DELETE" -gt 0 ] \
  && [ "$POS_RESTART" -lt "$POS_DELETE" ] && [ "$POS_AFTER_RESTART" -lt "$POS_DELETE" ]; then
  ok "掃除手順: 削除は再起動（と「再起動後に」の明示）の後に置かれている"
else
  bad "掃除手順: 削除が再起動の後に置かれていない（restart=${POS_RESTART} after=${POS_AFTER_RESTART} delete=${POS_DELETE}）"
fi
if printf '%s\n' "$cleanup_line" | grep -F 'そのセッションがロードしているバージョンは削除しない' >/dev/null; then
  ok "掃除手順: ロード中バージョンの除外が案内文に含まれる"
else
  bad "掃除手順: ロード中バージョンの除外文言が無い"
fi

# ---- 8. 検出力の変異注入 ------------------------------------------------------
DIFF_NEEDLE='if [ -n "$missing_joined" ]; then'
COEXIST_NEEDLE='cat "$work/installs" > "$work/installs.report"'
# check-skill-drift.sh のコメント行に ID_NEEDLE と同一文字列を置かない
# （ACE-156-1。この suite のコメントでは変数名で指す）。
# 検出不能案内と掃除手順の 2 箇所。
ID_NEEDLE='ID は プラグイン名@marketplace名 の形式で、素の名前を渡すと Plugin not found で失敗する'
diff_hits="$(grep -cF "$DIFF_NEEDLE" "$TARGET" || true)"
coexist_hits="$(grep -cF "$COEXIST_NEEDLE" "$TARGET" || true)"
id_hits="$(grep -cF "$ID_NEEDLE" "$TARGET" || true)"
if [ "$diff_hits" -eq 1 ]; then
  ok "変異対象: スキル集合差分の条件が 1 箇所"
else
  bad "変異対象: スキル集合差分の条件が ${diff_hits} 箇所（期待 1）"
fi
if [ "$coexist_hits" -eq 1 ]; then
  ok "変異対象: 併存列挙のコピーが 1 箇所"
else
  bad "変異対象: 併存列挙のコピーが ${coexist_hits} 箇所（期待 1）"
fi
if [ "$id_hits" -eq 2 ]; then
  ok "変異対象: 登録 ID 形式の案内が 2 箇所"
else
  bad "変異対象: 登録 ID 形式の案内が ${id_hits} 箇所（期待 2）"
fi
id_comment_hits="$(grep -E '^[[:space:]]*#' "$TARGET" | grep -cF "$ID_NEEDLE" || true)"
id_comment_hits="${id_comment_hits:-0}"
if [ "$id_comment_hits" -gt 0 ]; then
  bad "変異対象: 登録 ID 案内の needle がコメント行にも居る（ACE-156-1 の空回り）"
else
  ok "変異対象: 登録 ID 案内の needle はコード行のみ"
fi

prepare_mut_plugin() {
  # $1 dest plugin root
  mkdir -p "$1/hooks" "$1/.claude-plugin"
  cp "$TARGET" "$1/hooks/check-skill-drift.sh"
cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$1/hooks/asdd-hook-gate.sh"
  printf '{\n  "name": "ff-dev-toolkit",\n  "version": "0.40.0"\n}\n' > "$1/.claude-plugin/plugin.json"
  chmod +x "$1/hooks/check-skill-drift.sh"
}

MUT_ROOT="$TMP/mut-diff/plugin"
prepare_mut_plugin "$MUT_ROOT"
HOOK="$MUT_ROOT/hooks/check-skill-drift.sh"
REPO="$TMP/repo-mut-diff"
CLAUDE="$TMP/claude-mut-diff"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha extra-skill
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if printf '%s' "$OUT" | grep -F "extra-skill" >/dev/null; then
  ok "変異対照: 未変異の隔離コピーは欠けているスキルを報告する"
else
  echo "✗ 変異対照: 未変異コピーが報告しない（plugin.json 不在の疑い）: output=[$OUT]" >&2
  exit 1
fi
# クォート済みヒアドキュメントで変異ファイルを作り、出現回数を検査してから適用する
# （シェル補間で変異を書くと適用失敗が「緑」と区別できない。TESTING.md §10）
cat > "$TMP/mut-diff.sed" << 'MUT_DIFF'
s/if \[ -n "\$missing_joined" \]; then/if false; then/
MUT_DIFF
sed_hits="$(grep -cF "$DIFF_NEEDLE" "$HOOK" || true)"
if [ "$sed_hits" -ne 1 ]; then
  echo "✗ スキル集合差分の変異対象が ${sed_hits} 件（期待 1）。適用せず終了" >&2
  exit 1
fi
sed -f "$TMP/mut-diff.sed" "$HOOK" > "$HOOK.mut"
mv -f "$HOOK.mut" "$HOOK"
after_hits="$(grep -cF "$DIFF_NEEDLE" "$HOOK" || true)"
if [ "$after_hits" -ne 0 ]; then
  echo "✗ スキル集合差分の変異が当たっていません" >&2
  exit 1
fi
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if printf '%s' "$OUT" | grep -F "extra-skill" >/dev/null; then
  bad "スキル集合差分を落とす変異: 欠けているスキルがまだ報告される（検出力なし）"
else
  ok "スキル集合差分を落とす変異: 欠けているスキルの報告が消える（検出力の実測）"
fi

MUT_ROOT="$TMP/mut-coexist/plugin"
prepare_mut_plugin "$MUT_ROOT"
HOOK="$MUT_ROOT/hooks/check-skill-drift.sh"
REPO="$TMP/repo-mut-coexist"
CLAUDE="$TMP/claude-mut-coexist"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha beta
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.19.0" "0.19.0" alpha beta
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if printf '%s' "$OUT" | grep -F "0.28.0" >/dev/null \
  && printf '%s' "$OUT" | grep -F "0.19.0" >/dev/null; then
  ok "変異対照: 未変異の隔離コピーは両 version を列挙する"
else
  echo "✗ 変異対照: 未変異コピーが両 version を列挙しない: output=[$OUT]" >&2
  exit 1
fi
cat > "$TMP/mut-coexist.sed" << 'MUT_COEXIST'
s/cat "\$work\/installs" > "\$work\/installs.report"/head -n 1 "$work\/installs" > "$work\/installs.report"/
MUT_COEXIST
sed_hits="$(grep -cF "$COEXIST_NEEDLE" "$HOOK" || true)"
if [ "$sed_hits" -ne 1 ]; then
  echo "✗ 併存列挙の変異対象が ${sed_hits} 件（期待 1）。適用せず終了" >&2
  exit 1
fi
sed -f "$TMP/mut-coexist.sed" "$HOOK" > "$HOOK.mut"
mv -f "$HOOK.mut" "$HOOK"
after_hits="$(grep -cF "$COEXIST_NEEDLE" "$HOOK" || true)"
if [ "$after_hits" -ne 0 ]; then
  echo "✗ 併存列挙の変異が当たっていません（元の cat 行が残っている）" >&2
  exit 1
fi
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
has_028=0
has_019=0
printf '%s' "$OUT" | grep -F "0.28.0" >/dev/null && has_028=1
printf '%s' "$OUT" | grep -F "0.19.0" >/dev/null && has_019=1
if [ "$has_028" -eq 1 ] && [ "$has_019" -eq 1 ]; then
  bad "併存列挙を 1 件に潰す変異: 両方の version がまだ出る（検出力なし）"
else
  ok "併存列挙を 1 件に潰す変異: 全件列挙が崩れる（検出力の実測）"
fi

# 登録 ID 形式の案内を除く変異。3 段コマンドの断片検査だけでは、形式説明だけを
# 消した退行を通す。針は ID_NEEDLE（check-skill-drift.sh のコード行専用）。
MUT_ROOT="$TMP/mut-id/plugin"
prepare_mut_plugin "$MUT_ROOT"
HOOK="$MUT_ROOT/hooks/check-skill-drift.sh"
REPO="$TMP/repo-mut-id"
CLAUDE="$TMP/claude-mut-id"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha extra-skill
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.28.0" "0.28.0" alpha
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if printf '%s' "$OUT" | grep -F "$ID_NEEDLE" >/dev/null \
  && printf '%s' "$OUT" | grep -F "extra-skill" >/dev/null; then
  ok "変異対照: 未変異の隔離コピーは登録 ID 形式の案内と欠落スキルを出す"
else
  echo "✗ 変異対照: 未変異コピーが登録 ID 形式の案内または欠落スキルを出さない: output=[$OUT]" >&2
  exit 1
fi
cat > "$TMP/mut-id.sed" << 'MUT_ID'
s/ID は プラグイン名@marketplace名 の形式で、素の名前を渡すと Plugin not found で失敗する//
MUT_ID
sed_hits="$(grep -cF "$ID_NEEDLE" "$HOOK" || true)"
if [ "$sed_hits" -ne 2 ]; then
  echo "✗ 登録 ID 形式案内の変異対象が ${sed_hits} 件（期待 2）。適用せず終了" >&2
  exit 1
fi
sed -f "$TMP/mut-id.sed" "$HOOK" > "$HOOK.mut"
mv -f "$HOOK.mut" "$HOOK"
after_hits="$(grep -cF "$ID_NEEDLE" "$HOOK" || true)"
if [ "$after_hits" -ne 0 ]; then
  echo "✗ 登録 ID 形式案内の変異が当たっていません" >&2
  exit 1
fi
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if [ -z "$OUT" ]; then
  bad "登録 ID 形式の案内を除く変異: 対照が経路へ届いていない（否定の主張が空振りする）"
elif ! printf '%s' "$OUT" | grep -F "extra-skill" >/dev/null; then
  bad "登録 ID 形式の案内を除く変異: スキル欠落の報告まで消えた（単独でない）"
elif ! printf '%s' "$(addctx)" | grep -F "claude plugin list" >/dev/null; then
  bad "登録 ID 形式の案内を除く変異: 3 段案内まで消えた（単独でない）"
elif printf '%s' "$OUT" | grep -F "$ID_NEEDLE" >/dev/null; then
  bad "登録 ID 形式の案内を除く変異: 形式説明がまだ出る（検出力なし）"
else
  ok "登録 ID 形式の案内を除く変異: 形式説明が消え、欠落報告と 3 段案内は残る（単独で赤）"
fi
# 検出不能経路も同じ針。掃除手順側だけ直して検出不能側を残す退行を通さない。
REPO="$TMP/repo-mut-id-none"
CLAUDE="$TMP/claude-mut-id-none"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha
mkdir -p "$CLAUDE"
run_hook \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE"
if [ -z "$OUT" ]; then
  bad "登録 ID 形式の案内を除く変異（検出不能）: 対照が経路へ届いていない"
elif ! sysmsg | grep -F "検出不能" >/dev/null; then
  bad "登録 ID 形式の案内を除く変異（検出不能）: 検出不能の報告まで消えた"
elif ! printf '%s' "$(addctx)" | grep -F "claude plugin list" >/dev/null; then
  bad "登録 ID 形式の案内を除く変異（検出不能）: 3 段案内まで消えた"
elif printf '%s' "$OUT" | grep -F "$ID_NEEDLE" >/dev/null; then
  bad "登録 ID 形式の案内を除く変異（検出不能）: 形式説明がまだ出る"
else
  ok "登録 ID 形式の案内を除く変異（検出不能）: 形式説明が消え、検出不能と 3 段案内は残る"
fi

# ---- ロード中のコピーに無いスキル（Issue #881）---------------------------------
# union（全インストール実体の和集合）との差分は「どこかに在れば無音」なので、
# **セッションが実際に読んでいるコピー**に無いスキルを取り逃がす。実測（#881）:
# ロード済みが v0.14.0（3 スキル）、キャッシュに v0.61.0（21 スキル）が併存する状態で
# `/retrospective` が Unknown skill になったのに、union には在るので無音だった。
#
# ここでは own_root（= CLAUDE_PLUGIN_ROOT）に skills/ を持たせた fixture を使う。
# 既定の $FIX は skills/ を持たない名前提供用のスタブなので、専用の root を作る。
LOADED="$TMP/loaded-old"
mkdir -p "$LOADED/hooks"
make_plugin "$LOADED" "0.14.0" alpha
cp "$TARGET" "$LOADED/hooks/check-skill-drift.sh"
cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$LOADED/hooks/asdd-hook-gate.sh"
chmod +x "$LOADED/hooks/check-skill-drift.sh"

REPO="$TMP/repo-loaded"
CLAUDE="$TMP/claude-loaded"
make_plugin "$REPO/plugins/ff-dev-toolkit" "0.40.0" alpha beta gamma
# キャッシュ側は全スキルを持つ = union では欠落なし（この検査が無いと無音になる形）
make_plugin "$CLAUDE/plugins/cache/mp/ff-dev-toolkit/0.40.0" "0.40.0" alpha beta gamma

LOADED_OUT="$(CLAUDE_PLUGIN_ROOT="$LOADED" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE" \
  bash "$LOADED/hooks/check-skill-drift.sh" 2>/dev/null)"

# 前提: union には欠落が無い（この検査だけが赤にできる状況であることの確認）。
# ここを測らずに下を読むと、union 差分が出した通知を「新しい検査が効いた」と読み違える。
if printf '%s' "$LOADED_OUT" | grep -F 'インストール実体に無いスキル' >/dev/null; then
  bad "ロード中コピー検査: union 差分が発火しており、この検査だけの効果を測れていない"
else
  ok "ロード中コピー検査: union には欠落が無い（前提の確認）"
fi
if printf '%s' "$LOADED_OUT" | grep -F 'いま読み込まれている ff-dev-toolkit' >/dev/null \
  && printf '%s' "$LOADED_OUT" | grep -E '無いスキルがあります: .*\bbeta\b' >/dev/null \
  && printf '%s' "$LOADED_OUT" | grep -E '無いスキルがあります: .*\bgamma\b' >/dev/null; then
  ok "ロード中コピー検査: 呼べないスキル名を名指しする"
else
  bad "ロード中コピー検査: 名指しが不足: $(printf '%s' "$LOADED_OUT" | head -c 400)"
fi
if printf '%s' "$LOADED_OUT" | grep -E '無いスキルがあります: .*\balpha\b' >/dev/null; then
  bad "ロード中コピー検査: ロード中コピーに在るスキルまで名指ししている"
else
  ok "ロード中コピー検査: ロード中コピーに在るスキルは名指ししない"
fi
if printf '%s' "$LOADED_OUT" | grep -F 'Unknown skill' >/dev/null; then
  ok "ロード中コピー検査: 呼び出しがどう失敗するかを述べている"
else
  bad "ロード中コピー検査: 失敗の形（Unknown skill）が伝わらない"
fi

# 一致していれば無出力（常時ノイズにしない。#881 の GWT 2 つ目）
make_plugin "$LOADED" "0.40.0" alpha beta gamma
SAME_OUT="$(CLAUDE_PLUGIN_ROOT="$LOADED" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$REPO" \
  FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$CLAUDE" \
  bash "$LOADED/hooks/check-skill-drift.sh" 2>/dev/null)"
if [ -z "$SAME_OUT" ]; then
  ok "ロード中コピー検査: 一致していれば無出力"
else
  bad "ロード中コピー検査: 一致しているのに通知した: $(printf '%s' "$SAME_OUT" | head -c 200)"
fi

echo
echo "skill-drift-check: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -gt 0 ] || { echo "✗ 1 件も検査が実行されていません" >&2; exit 1; }
FF_REACHED_END=1
exit 0
