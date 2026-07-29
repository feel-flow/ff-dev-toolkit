#!/usr/bin/env bash
#
# hooks/check-update.sh（更新通知フック、Issue #165）の回帰検証。
#
# 実ネットワークには触れない。tests/changelog-links-selftest と同じ手法で、
# ローカルのタグ付き bare git リポジトリを FF_DEV_TOOLKIT_UPDATE_REPO_URL で
# フックに渡し、キャッシュディレクトリも FF_DEV_TOOLKIT_UPDATE_CACHE_DIR で
# 一時領域へ隔離する。フック本体は fixture のプラグイン構造
# （<tmp>/plugin/hooks/ + <tmp>/plugin/.claude-plugin/plugin.json）へコピーして
# 実行し、スクリプト位置からの plugin.json 解決と sed による version 抽出も
# 本番経路のまま検証する。CLAUDE_PLUGIN_ROOT 経路は、fixture 外に置いた detached
# コピー（スクリプト相対解決では plugin.json に到達できない配置）で別途固定する。
#
# 固定する経路:
#   - 新版検出時の通知 JSON（jq で構文検証・単一オブジェクト検証 + 内容）と
#     notified 記録による「同一バージョンは一度だけ」の抑制、新しい版での再通知
#   - 最新版・ローカル先行時の完全無出力
#   - SemVer の数値比較（0.9.9 < 0.10.0、0.99.99 < 1.0.0。辞書順比較への退行防止）
#   - 成功キャッシュ TTL 内はネットワークへ出ない（到達不能 URL でも通知が出ることで証明）
#   - 失敗キャッシュ TTL 内は再試行しない（正常 URL でも無出力であることで証明）
#   - 失敗キャッシュ期限切れ・未来 timestamp（clock skew）後は再試行して復帰する
#   - 悲観的 fail マーカー（ネットワーク取得「前」に書く。timeout kill 相当の
#     SIGKILL でも fail が残ることを stub git で証明）
#   - オフライン（到達不能）時は無出力 + exit 0 + fail キャッシュ記録
#   - 到達可能だが SemVer タグが 1 件も無いリポジトリでは通知せず fail が残る
#   - FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1 はキャッシュ作成すら行わず即終了
#   - SemVer 3 要素でないタグ（v1.2.3-rc.1 等）の除外（peeled ref は fixture の
#     annotated tag で ls-remote 出力に並ぶ状態を作っている。$ アンカー除去の
#     退行はこの rc タグ検査が拾う）
#   - plugin.json から version が読めない場合の silent skip
#   - 壊れたキャッシュの自己修復（1 語 garbage / 余剰フィールド / 先頭ゼロ epoch /
#     "ok - <ts>" 形。いずれもネットワーク経路へ落ちて上書き）
#   - 非数値 TTL 環境変数は既定値へフォールバックし stderr を汚さない
#   - hooks.json の静的整合（JSON 構文・SessionStart 登録・スクリプト実在・timeout）
#
# すべての経路で exit 0 と stderr 無出力を検査する（fail-open 契約。非 0 exit や
# stderr 漏れはユーザーのセッション起動を汚すため、それ自体が回帰）。
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/check-update.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ hooks/check-update.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ git が必要です" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です（通知 JSON の構文検証に使用）" >&2; exit 1; }

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- fixture: タグ付き bare リポジトリ ---------------------------------------
# v0.14.0 は annotated tag にして peeled ref（refs/tags/v0.14.0^{}）も ls-remote に
# 並ぶ状態を作る。v0.15.0-rc.1 は「SemVer 3 要素でないタグは無視」の検査用。
# 空 bare リポジトリの clone は git が warning を stderr へ出すため封じる
# （run-all.sh は stderr を suite 出力へ合流させるので報告ノイズになる）。
git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
(
  cd "$TMP/work"
  git config user.email "test@example.com"
  git config user.name "update-check-test"
  git config commit.gpgsign false
  printf '%s\n' "base" > README.md
  git add README.md
  git commit -qm "base"
  git tag v0.9.9
  git tag v0.13.3
  git tag -a v0.14.0 -m "release v0.14.0"
  git tag "v0.15.0-rc.1"
  git push -q origin HEAD --tags
)
REPO="$TMP/origin.git"

# 「最新が 0.10.0」の辞書順比較検査用リポジトリ（0.9.9 と共存させると
# 数値比較でも 0.10.0 が最大になり検査にならないため分離する）
git init --bare -q "$TMP/origin-0100.git"
git clone -q "$TMP/origin-0100.git" "$TMP/work-0100" 2>/dev/null
(
  cd "$TMP/work-0100"
  git config user.email "test@example.com"
  git config user.name "update-check-test"
  git config commit.gpgsign false
  printf '%s\n' "base" > README.md
  git add README.md
  git commit -qm "base"
  git tag v0.9.9
  git tag v0.10.0
  git push -q origin HEAD --tags
)
REPO_0100="$TMP/origin-0100.git"

# SemVer 3 要素タグを 1 つも持たないリポジトリ（到達可能・タグ解析不能の経路用）
git init --bare -q "$TMP/origin-nosemver.git"
git clone -q "$TMP/origin-nosemver.git" "$TMP/work-nosemver" 2>/dev/null
(
  cd "$TMP/work-nosemver"
  git config user.email "test@example.com"
  git config user.name "update-check-test"
  git config commit.gpgsign false
  printf '%s\n' "base" > README.md
  git add README.md
  git commit -qm "base"
  git tag "v1.0.0-rc.1"
  git tag "release-2026"
  git push -q origin HEAD --tags
)
REPO_NOSEMVER="$TMP/origin-nosemver.git"

# ---- fixture: フックのプラグイン構造コピー -----------------------------------
FIX="$TMP/plugin"
mkdir -p "$FIX/hooks" "$FIX/.claude-plugin"
cp "$TARGET" "$FIX/hooks/check-update.sh"
HOOK="$FIX/hooks/check-update.sh"

set_version() {
  printf '{\n  "name": "ff-dev-toolkit",\n  "version": "%s"\n}\n' "$1" > "$FIX/.claude-plugin/plugin.json"
}

# フック実行ヘルパー。呼び出し側環境の CLAUDE_PLUGIN_ROOT / オプトアウト / TTL
# シームを打ち消し、出力を $OUT、stderr を $ERR、終了コードを $RC に入れる
# （set -e 下でも落ちない形）。
OUT=""
ERR=""
RC=0
run_hook() {
  # 引数: <repo_url> <cache_dir> [追加の env VAR=VALUE ...]
  local repo="$1" cache="$2"
  shift 2
  RC=0
  OUT="$(env -u CLAUDE_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK \
    -u FF_DEV_TOOLKIT_UPDATE_TTL_OK -u FF_DEV_TOOLKIT_UPDATE_TTL_FAIL \
    FF_DEV_TOOLKIT_UPDATE_REPO_URL="$repo" \
    FF_DEV_TOOLKIT_UPDATE_CACHE_DIR="$cache" \
    "$@" bash "$HOOK" 2>"$TMP/stderr")" || RC=$?
  ERR="$(cat "$TMP/stderr" 2>/dev/null || true)"
}

# exit 0 + stderr 無出力（fail-open 契約）をまとめて検査する
assert_clean() {
  # 引数: <検査名>
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then
    ok "$1: exit 0 + stderr 無出力"
  else
    bad "$1: exit=$RC stderr=[$ERR]"
  fi
}

echo "== update-check =="

# ---- 1. 新版検出: 通知 JSON が出る -------------------------------------------
set_version "0.13.3"
CACHE="$TMP/cache1"
run_hook "$REPO" "$CACHE"
assert_clean "新版検出"
if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
  && [ "$(printf '%s' "$OUT" | jq -s 'length')" = "1" ]; then
  ok "新版検出: 出力が単一の valid JSON オブジェクト"
else
  bad "新版検出: 出力が単一 JSON として解析できない: $OUT"
fi
if printf '%s' "$OUT" | jq -er '.systemMessage' 2>/dev/null | grep "v0.14.0" >/dev/null \
  && printf '%s' "$OUT" | jq -er '.systemMessage' 2>/dev/null | grep "v0.13.3" >/dev/null; then
  ok "新版検出: systemMessage に最新版と現行版の両方を含む"
else
  bad "新版検出: systemMessage の内容が不正: $OUT"
fi
if [ "$(printf '%s' "$OUT" | jq -er '.hookSpecificOutput.hookEventName' 2>/dev/null)" = "SessionStart" ]; then
  ok "新版検出: hookEventName が SessionStart"
else
  bad "新版検出: hookEventName が不正"
fi
if printf '%s' "$OUT" | jq -er '.hookSpecificOutput.additionalContext' 2>/dev/null | grep "claude plugin update ff-dev-toolkit" >/dev/null; then
  ok "新版検出: additionalContext に更新コマンドを含む"
else
  bad "新版検出: additionalContext に更新コマンドが無い"
fi
# marketplace 名を固定した案内への退行防止（登録名はユーザー依存のため）
if printf '%s' "$OUT" | grep "marketplace update ff-dev-toolkit" >/dev/null; then
  bad "新版検出: marketplace 名を固定した更新コマンドを案内している"
else
  ok "新版検出: marketplace 名を固定していない"
fi
# v0.15.0-rc.1 が最新として採用されていないこと（SemVer 3 要素限定の固定）
if printf '%s' "$OUT" | grep -F "0.15.0" >/dev/null; then
  bad "新版検出: SemVer 3 要素でないタグ（v0.15.0-rc.1）を最新と誤認した"
else
  ok "新版検出: SemVer 3 要素でないタグを無視した"
fi
if [ -f "$CACHE/update-check" ] && grep -q "^ok 0.14.0 " "$CACHE/update-check"; then
  ok "新版検出: 成功キャッシュを記録した"
else
  bad "新版検出: 成功キャッシュが不正: $(cat "$CACHE/update-check" 2>/dev/null || echo '<missing>')"
fi
if [ -f "$CACHE/notified" ] && [ "$(cat "$CACHE/notified")" = "0.14.0" ]; then
  ok "新版検出: notified に通知済みバージョンを記録した"
else
  bad "新版検出: notified が不正: $(cat "$CACHE/notified" 2>/dev/null || echo '<missing>')"
fi

# ---- 2. 通知済み抑制: 同一バージョンは一度だけ -------------------------------
run_hook "$REPO" "$CACHE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "通知済み抑制: 2 回目は無出力（compact 再注入の防止）"
else
  bad "通知済み抑制: exit=$RC output=[$OUT] stderr=[$ERR]"
fi
# 新しい版が出たら再通知する（notified は「そのバージョンを」通知済みなだけ）
git -C "$TMP/work" tag v0.14.1
git -C "$TMP/work" push -q origin v0.14.1
rm -f "$CACHE/update-check"   # TTL を待たずネットワーク経路へ
run_hook "$REPO" "$CACHE"
if printf '%s' "$OUT" | grep -F "v0.14.1" >/dev/null; then
  ok "通知済み抑制: さらに新しい版は再通知する"
else
  bad "通知済み抑制: 新しい版 v0.14.1 が通知されない: [$OUT]"
fi

# ---- 3. 最新版・ローカル先行: 完全無出力 -------------------------------------
set_version "0.14.1"
run_hook "$REPO" "$TMP/cache3"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "最新版: 無出力 + exit 0"
else
  bad "最新版: exit=$RC output=[$OUT] stderr=[$ERR]"
fi
set_version "0.99.0"
run_hook "$REPO" "$TMP/cache3b"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "ローカル先行: 無出力 + exit 0"
else
  bad "ローカル先行: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# ---- 4. SemVer 数値比較（辞書順比較への退行防止） ----------------------------
set_version "0.9.9"
run_hook "$REPO_0100" "$TMP/cache4"
assert_clean "SemVer 比較 0.9.9→0.10.0"
if printf '%s' "$OUT" | grep -F "v0.10.0" >/dev/null; then
  ok "SemVer 比較: 0.9.9 → 0.10.0 を新版と判定（数値比較）"
else
  bad "SemVer 比較: 0.10.0 を新版と判定できない（辞書順比較の疑い）: [$OUT]"
fi
set_version "0.99.99"
git -C "$TMP/work" tag v1.0.0
git -C "$TMP/work" push -q origin v1.0.0
run_hook "$REPO" "$TMP/cache4b"
assert_clean "SemVer 比較 0.99.99→1.0.0"
if printf '%s' "$OUT" | grep -F "v1.0.0" >/dev/null; then
  ok "SemVer 比較: 0.99.99 → 1.0.0 を新版と判定"
else
  bad "SemVer 比較: 1.0.0 を新版と判定できない: [$OUT]"
fi

# ---- 5. 成功キャッシュ TTL 内はネットワークへ出ない --------------------------
# 到達不能 URL を渡しても、キャッシュだけで通知が出る = ls-remote を呼んでいない。
# さらにキャッシュが fail で上書きされていないことも検査する（「毎回ネットワークを
# 試み、失敗時のみキャッシュへ fallback」という退行はここで red になる）。
set_version "0.13.3"
CACHE="$TMP/cache5"
mkdir -p "$CACHE"
printf 'ok 0.14.0 %s\n' "$(date +%s)" > "$CACHE/update-check"
run_hook "$TMP/no-such-repo" "$CACHE"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | grep -F "v0.14.0" >/dev/null \
  && grep -q "^ok 0.14.0 " "$CACHE/update-check"; then
  ok "成功キャッシュ: TTL 内はネットワーク不要で通知が出てキャッシュも保たれる"
else
  bad "成功キャッシュ: exit=$RC output=[$OUT] stderr=[$ERR] cache=$(cat "$CACHE/update-check" 2>/dev/null)"
fi

# ---- 6. 失敗キャッシュ TTL 内は再試行しない ----------------------------------
# 正常な URL + 新版ありでも、fail キャッシュが新鮮なら無出力 = 再試行していない
CACHE="$TMP/cache6"
mkdir -p "$CACHE"
printf 'fail - %s\n' "$(date +%s)" > "$CACHE/update-check"
run_hook "$REPO" "$CACHE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "失敗キャッシュ: TTL 内は再試行しない"
else
  bad "失敗キャッシュ: TTL 内に再試行した: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# ---- 7. 失敗キャッシュ期限切れ・未来 timestamp は再試行して復帰する ----------
CACHE="$TMP/cache7"
mkdir -p "$CACHE"
printf 'fail - %s\n' "$(( $(date +%s) - 7200 ))" > "$CACHE/update-check"
run_hook "$REPO" "$CACHE"
assert_clean "失敗キャッシュ期限切れ"
if printf '%s' "$OUT" | grep "systemMessage" >/dev/null; then
  ok "失敗キャッシュ期限切れ: 再試行して通知が出る"
else
  bad "失敗キャッシュ期限切れ: 復帰しない: exit=$RC output=[$OUT]"
fi
# 未来 timestamp（clock skew で書かれた遠未来キャッシュ）を信用すると、負の age が
# 常に TTL 内と判定され通知が長期沈黙する。ガード -ge 0 の退行防止。
CACHE="$TMP/cache7b"
mkdir -p "$CACHE"
printf 'fail - %s\n' "$(( $(date +%s) + 999999 ))" > "$CACHE/update-check"
run_hook "$REPO" "$CACHE"
if printf '%s' "$OUT" | grep "systemMessage" >/dev/null; then
  ok "未来 timestamp: 信用せず再試行して通知が出る"
else
  bad "未来 timestamp: 遠未来キャッシュで沈黙した: exit=$RC output=[$OUT]"
fi

# ---- 8. オフライン: 無出力 + exit 0 + fail キャッシュ記録 --------------------
CACHE="$TMP/cache8"
run_hook "$TMP/no-such-repo" "$CACHE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "オフライン: 無出力 + exit 0 + stderr 無出力"
else
  bad "オフライン: exit=$RC output=[$OUT] stderr=[$ERR]"
fi
if [ -f "$CACHE/update-check" ] && grep -q "^fail - " "$CACHE/update-check"; then
  ok "オフライン: fail キャッシュを記録した"
else
  bad "オフライン: fail キャッシュが不正: $(cat "$CACHE/update-check" 2>/dev/null || echo '<missing>')"
fi

# ---- 9. 到達可能だが SemVer タグ 0 件: 通知せず fail が残る ------------------
CACHE="$TMP/cache9"
run_hook "$REPO_NOSEMVER" "$CACHE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] \
  && grep -q "^fail - " "$CACHE/update-check" 2>/dev/null; then
  ok "SemVer タグ 0 件: 無出力で fail キャッシュが残る"
else
  bad "SemVer タグ 0 件: exit=$RC output=[$OUT] cache=$(cat "$CACHE/update-check" 2>/dev/null || echo '<missing>')"
fi

# ---- 10. 悲観的 fail マーカー: 取得中に kill されても fail が残る ------------
# git を sleep する stub に差し替え、取得中のフックを SIGKILL する（hooks.json の
# timeout による打ち切りの再現）。マーカーがネットワーク取得の「前」に書かれて
# いれば fail が残り、次セッションは TTL でスキップされる。
mkdir -p "$TMP/stubbin"
printf '#!/bin/sh\nsleep 30\n' > "$TMP/stubbin/git"
chmod +x "$TMP/stubbin/git"
CACHE="$TMP/cache10"
env -u CLAUDE_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK \
  -u FF_DEV_TOOLKIT_UPDATE_TTL_OK -u FF_DEV_TOOLKIT_UPDATE_TTL_FAIL \
  FF_DEV_TOOLKIT_UPDATE_REPO_URL="$REPO" \
  FF_DEV_TOOLKIT_UPDATE_CACHE_DIR="$CACHE" \
  PATH="$TMP/stubbin:$PATH" bash "$HOOK" >/dev/null 2>&1 &
HOOK_PID=$!
sleep 1
kill -9 "$HOOK_PID" 2>/dev/null || true
wait "$HOOK_PID" 2>/dev/null || true
if [ -f "$CACHE/update-check" ] && grep -q "^fail - " "$CACHE/update-check"; then
  ok "悲観的 fail マーカー: 取得中に kill されても fail が残る"
else
  bad "悲観的 fail マーカー: kill 後にキャッシュが無い/不正: $(cat "$CACHE/update-check" 2>/dev/null || echo '<missing>')"
fi

# ---- 11. オプトアウト: 一切の処理を行わない ----------------------------------
CACHE="$TMP/cache11"
run_hook "$REPO" "$CACHE" FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ ! -e "$CACHE" ]; then
  ok "オプトアウト: 無出力 + キャッシュディレクトリ未作成"
else
  bad "オプトアウト: exit=$RC output=[$OUT] cache_exists=$([ -e "$CACHE" ] && echo yes || echo no)"
fi

# ---- 12. plugin.json から version が読めない: silent skip --------------------
printf '{\n  "name": "ff-dev-toolkit"\n}\n' > "$FIX/.claude-plugin/plugin.json"
run_hook "$REPO" "$TMP/cache12"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "version 欠落: 無出力 + exit 0"
else
  bad "version 欠落: exit=$RC output=[$OUT] stderr=[$ERR]"
fi
set_version "0.13.3"

# ---- 13. 壊れたキャッシュの自己修復（stderr を汚さない） ---------------------
# (a) 1 語 garbage、(b) 余剰フィールド（算術式エラーの温床）、(c) 先頭ゼロ epoch
# （八進数解釈エラーの温床）、(d) "ok - <ts>"（パース成功・検証失敗の隙間に落ちて
# TTL 満了まで沈黙するゾンビ形）。いずれもネットワーク経路へ落ちて上書き修復する。
for corrupt in "garbage" "ok 0.14.0 123 junk" "ok 0.14.0 08" "ok - 1785076003"; do
  CACHE="$TMP/cache13"
  rm -rf "$CACHE"
  mkdir -p "$CACHE"
  printf '%s\n' "$corrupt" > "$CACHE/update-check"
  rm -f "$CACHE/notified"
  run_hook "$REPO" "$CACHE"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | grep "systemMessage" >/dev/null \
    && grep -q "^ok " "$CACHE/update-check"; then
    ok "壊れたキャッシュ [$corrupt]: stderr を汚さず自己修復して通知した"
  else
    bad "壊れたキャッシュ [$corrupt]: exit=$RC stderr=[$ERR] output=[${OUT:0:80}] cache=$(cat "$CACHE/update-check" 2>/dev/null)"
  fi
done

# ---- 14. 非数値 TTL は既定値へフォールバック ---------------------------------
# 新鮮な ok キャッシュ + 到達不能 URL + 非数値 TTL。既定 TTL(24h) が適用されれば
# キャッシュヒットで通知が出る。TTL 検証が壊れていれば算術/比較エラーが stderr に出る。
CACHE="$TMP/cache14"
mkdir -p "$CACHE"
printf 'ok 0.14.0 %s\n' "$(date +%s)" > "$CACHE/update-check"
run_hook "$TMP/no-such-repo" "$CACHE" FF_DEV_TOOLKIT_UPDATE_TTL_OK=abc FF_DEV_TOOLKIT_UPDATE_TTL_FAIL=-5
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | grep -F "v0.14.0" >/dev/null; then
  ok "非数値 TTL: 既定値で動作し stderr を汚さない"
else
  bad "非数値 TTL: exit=$RC stderr=[$ERR] output=[$OUT]"
fi

# ---- 15. CLAUDE_PLUGIN_ROOT 経路（本番で常用される分岐の固定） ---------------
# detached コピー（隣に .claude-plugin が無い配置）から実行し、CLAUDE_PLUGIN_ROOT
# 経由でのみ plugin.json に到達できる状態を作る。ここで通知が出る = env 経路が
# 実際に使われている証明（スクリプト相対 fallback では version が読めず沈黙する）。
mkdir -p "$TMP/detached"
cp "$TARGET" "$TMP/detached/check-update.sh"
CACHE="$TMP/cache15"
RC=0
OUT="$(env -u FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK \
  -u FF_DEV_TOOLKIT_UPDATE_TTL_OK -u FF_DEV_TOOLKIT_UPDATE_TTL_FAIL \
  CLAUDE_PLUGIN_ROOT="$FIX" \
  FF_DEV_TOOLKIT_UPDATE_REPO_URL="$REPO" \
  FF_DEV_TOOLKIT_UPDATE_CACHE_DIR="$CACHE" \
  bash "$TMP/detached/check-update.sh" 2>"$TMP/stderr")" || RC=$?
ERR="$(cat "$TMP/stderr" 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | grep "systemMessage" >/dev/null; then
  ok "CLAUDE_PLUGIN_ROOT: env 経由で plugin.json を解決して通知が出る"
else
  bad "CLAUDE_PLUGIN_ROOT: env 経路が機能していない: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# ---- 16. hooks.json の静的整合 -----------------------------------------------
if jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json: valid JSON"
else
  bad "hooks.json: JSON として解析できない"
fi
if [ "$(jq -r '.hooks.SessionStart[0].hooks[0].type' "$HOOKS_JSON" 2>/dev/null)" = "command" ] \
  && jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON" 2>/dev/null | grep "check-update.sh" >/dev/null; then
  ok "hooks.json: SessionStart に check-update.sh が command 登録されている"
else
  bad "hooks.json: SessionStart の command 登録が不正"
fi
if jq -e '.hooks.SessionStart[0].hooks[0].timeout | numbers' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json: timeout が数値で設定されている"
else
  bad "hooks.json: timeout が未設定または非数値"
fi
if [ -x "$TARGET" ]; then
  ok "check-update.sh: 実行権限がある"
else
  bad "check-update.sh: 実行権限が無い"
fi

# ---- 集計 --------------------------------------------------------------------
echo
echo "update-check: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -gt 0 ] || { echo "✗ 1 件も検査が実行されていません" >&2; exit 1; }
exit 0
