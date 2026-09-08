#!/usr/bin/env bash
#
# hooks/check-update.sh（更新通知フック、Issue #165）の回帰検証。
#
# 実ネットワークには触れない。tests/changelog-public-tags-selftest と同じ手法で、
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
#     notified 記録（<現在版> <最新版> <epoch>）による TTL 付き抑止と、TTL 超過 /
#     現在版の変化 / 新しい版での再通知、旧形式・壊れた記録の自己修復
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
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。必須へ昇格するなら REQUIRED_SUITES へ移す）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/check-update.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

[ -f "$TARGET" ] || { echo "✗ hooks/check-update.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ git が必要です" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です（通知 JSON の構文検証に使用）" >&2; exit 1; }

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
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
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ update-check: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

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
  ff_git_fixture_init "$TMP/work" "update-check-test" "test@example.com"
  cd "$TMP/work"
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
  ff_git_fixture_init "$TMP/work-0100" "update-check-test" "test@example.com"
  cd "$TMP/work-0100"
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
  ff_git_fixture_init "$TMP/work-nosemver" "update-check-test" "test@example.com"
  cd "$TMP/work-nosemver"
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
# シームを打ち消し、出力を ${OUT}、stderr を ${ERR}、終了コードを $RC に入れる
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
    -u FF_DEV_TOOLKIT_UPDATE_TTL_NOTIFIED \
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
# 素の plugin 名は pin しない（Issue #943: それは not found で失敗する形）。
# 案内が 3 段（marketplace 更新 → 登録 ID の確認 → その ID で update）揃うことを見る。
AC="$(printf '%s' "$OUT" | jq -er '.hookSpecificOutput.additionalContext' 2>/dev/null || echo '')"
MISSING=""
for FRAG in "claude plugin marketplace update" "claude plugin list" "claude plugin update"; do
  printf '%s' "$AC" | grep -F "$FRAG" >/dev/null || MISSING="$MISSING [$FRAG]"
done
if [ -z "$MISSING" ]; then
  ok "新版検出: additionalContext に更新手順 3 段を含む"
else
  bad "新版検出: additionalContext に欠けている案内:$MISSING"
fi
# 素の名前での update を禁じる（<plugin>@<marketplace> 形式は正しい案内）。実測
# （Issue #943）: `claude plugin update ff-dev-toolkit` は Plugin not found で失敗する。
# 正の断片検査の隣に置く — 離すと、片方の削除でもう片方が黙って無効化される。
# 対照が経路へ届いていること（$OUT が空でないこと）を先に固定する（ACE-924-2）。
if [ -z "$OUT" ]; then
  bad "案内コマンド: 対照が経路へ届いていない（否定の主張が空振りする）"
elif printf '%s' "$OUT" | grep -Eq 'claude plugin update ff-dev-toolkit([^@]|$)'; then
  bad "案内コマンド: 素の plugin 名で update を案内している（not found になる）: [$OUT]"
else
  ok "案内コマンド: 素の plugin 名での update を案内していない"
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
# 記録は `<現在版> <最新版> <epoch>` の 3 欄。latest 単独では「更新したか」を
# 判別できず、抑止が「一生に一度」に化ける（Issue #943）。
if [ -f "$CACHE/notified" ] && grep -Eq '^0\.13\.3 0\.14\.0 [0-9]+$' "$CACHE/notified"; then
  ok "新版検出: notified に (現在版, 最新版, 時刻) を記録した"
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

# ---- 2b. 通知の再開: 同じ組み合わせでも TTL を超えたら再通知する -------------
# 旧実装は notified を latest 単独キーの永続ファイルにしていたため、一度通知した
# 版については更新の有無に関わらず永久に無音だった（Issue #943 の実測: 実行中
# v0.14.0 / notified 0.61.0 のまま 1 か月無通知）。抑止は TTL で時間を区切る。
#
# 以下すべての run_hook に assert_clean を付ける。notified 由来の値は
# `$((now - 10#$n_ts))` で算術へ入るため、壊れ方は「通知しない」ではなく
# 「hook が非 0 で死ぬ + stderr を汚す」として現れる（非対話シェルは算術展開
#  エラーで即終了する）。$OUT の grep だけでは両者を区別できない。
run_hook "$REPO" "$CACHE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "通知の再開: TTL 内は無出力（compact 再注入の防止は保たれる）"
else
  bad "通知の再開: TTL 内で出力された: exit=$RC output=[$OUT] stderr=[$ERR]"
fi
# 前回通知が TTL より古い記録へ差し替える（既定 TTL のまま経過だけを進める）。
# epoch を変数に取り、再通知後に「値が変わったこと」まで見る — 事前状態がそのまま
# 判定の正規表現に一致すると、記録を書かない変異が緑のまま通る（空振り）。
STALE_TS="$(( $(date +%s) - 200000 ))"
printf '0.13.3 0.14.1 %s\n' "$STALE_TS" > "$CACHE/notified"
run_hook "$REPO" "$CACHE"
assert_clean "通知の再開: TTL 超過"
if printf '%s' "$OUT" | grep -F "v0.14.1" >/dev/null; then
  ok "通知の再開: TTL 超過で再通知する（見逃した利用者へ届き続ける）"
else
  bad "通知の再開: TTL 超過でも通知されない: [$OUT]"
fi
if grep -Eq '^0\.13\.3 0\.14\.1 [0-9]+$' "$CACHE/notified" 2>/dev/null \
  && ! grep -Fq " $STALE_TS" "$CACHE/notified"; then
  ok "通知の再開: 再通知で記録の時刻が実際に書き換わる"
else
  bad "通知の再開: 再通知後の notified が不正または未更新: $(cat "$CACHE/notified" 2>/dev/null || echo '<missing>')"
fi
# TTL は環境変数で上書きできる（0 は「毎回通知」）。fixture はリテラルで置く —
# 直前の書き込み結果を使い回すと、書き込み側が壊れた変異でタプル不一致になり、
# TTL 上書きではなく別の理由で通知が出て緑になる（vacuous pass）。
printf '0.13.3 0.14.1 %s\n' "$(date +%s)" > "$CACHE/notified"
run_hook "$REPO" "$CACHE" FF_DEV_TOOLKIT_UPDATE_TTL_NOTIFIED=0
assert_clean "通知の再開: TTL 上書き"
if printf '%s' "$OUT" | grep -F "v0.14.1" >/dev/null; then
  ok "通知の再開: TTL の環境変数上書きが効く"
else
  bad "通知の再開: TTL=0 でも通知されない: [$OUT]"
fi
# 抑止キーの「現在版」成分。ここが無いと、中間版へ更新した利用者に対して
# より新しい版の存在が TTL いっぱい伏せられる。書き側（記録形式）は上で固定して
# いるが、読み側の比較はこの 1 件でしか測れない。
printf '0.13.3 0.14.1 %s\n' "$(date +%s)" > "$CACHE/notified"
set_version "0.13.4"          # 中間版へ部分更新した利用者
run_hook "$REPO" "$CACHE"
assert_clean "通知の再開: 現在版が変わった"
if printf '%s' "$OUT" | grep -F "v0.14.1" >/dev/null; then
  ok "通知の再開: 現在版が変われば TTL 内でも通知する（抑止キーの現在版成分）"
else
  bad "通知の再開: 部分更新した利用者へ新版が伏せられた: [$OUT]"
fi
set_version "0.13.3"          # 後続セクションへ漏らさない
# 未来 timestamp（clock skew / 共有 cache）。`-ge 0` ガードが無いと n_age が負に
# なり常に TTL 内と判定され、時計が追いつくまで永久に沈黙する = #943 の再発。
# update-check キャッシュ側は既に同型を固定済み（下の case 7b）。
printf '0.13.3 0.14.1 %s\n' "$(( $(date +%s) + 999999 ))" > "$CACHE/notified"  # 判定は通知の有無なので値の捕捉は不要
run_hook "$REPO" "$CACHE"
assert_clean "通知の再開: 未来 timestamp"
if printf '%s' "$OUT" | grep -F "v0.14.1" >/dev/null; then
  ok "通知の再開: 未来 timestamp の記録を信用せず通知する"
else
  bad "通知の再開: 未来 timestamp で沈黙した: [$OUT]"
fi

# ---- 2c. 記録の自己修復: 旧形式・壊れた記録は「未通知」として扱う ------------
# 形式が変わった直後の利用者は旧形式のファイルを持っている。ここで無音に倒れると
# 移行した瞬間から通知が消えるので、解析できない記録は必ず通知側へ倒す。
# `08` は先頭ゼロ epoch: is_digits は通すので `10#` の八進数対策が実際に効いており、
# 外すと `value too great for base` で hook が非 0 で死ぬ（assert_clean が拾う）。
for BROKEN in "0.14.1" "0.13.3 0.14.1" "0.13.3 0.14.1 abc" "0.13.3 0.14.1 08" ""; do
  printf '%s\n' "$BROKEN" > "$CACHE/notified"
  run_hook "$REPO" "$CACHE"
  assert_clean "記録の自己修復 [$BROKEN]"
  if printf '%s' "$OUT" | grep -F "v0.14.1" >/dev/null; then
    ok "記録の自己修復: 解析できない記録 [$BROKEN] は通知する"
  else
    bad "記録の自己修復: [$BROKEN] で通知されない: [$OUT]"
  fi
done
# 余剰フィールドは **新鮮な epoch** と組み合わせて測る。古い epoch と組み合わせると、
# 欄数ガードを外しても TTL 超過で通知されてしまい、この検査の検出力が 0 になる
# （変異注入で実測。ACE-924-2「否定の主張は対照が経路へ届くことを先に固定する」）。
printf '0.13.3 0.14.1 %s junk\n' "$(date +%s)" > "$CACHE/notified"
run_hook "$REPO" "$CACHE"
assert_clean "記録の自己修復: 余剰フィールド"
if printf '%s' "$OUT" | grep -F "v0.14.1" >/dev/null; then
  ok "記録の自己修復: 余剰フィールドは TTL 内でも通知する（欄数ガードの到達性つき）"
else
  bad "記録の自己修復: 余剰フィールド + 新鮮な epoch で通知されない: [$OUT]"
fi
if [ -f "$CACHE/notified" ] && grep -Eq '^0\.13\.3 0\.14\.1 [0-9]+$' "$CACHE/notified"; then
  ok "記録の自己修復: 通知後に新形式へ書き直される"
else
  bad "記録の自己修復: 新形式へ直っていない: $(cat "$CACHE/notified" 2>/dev/null || echo '<missing>')"
fi
# notified がディレクトリ化した病的状態。除去しないと mv がその中へ潜り込んで
# rc=0 を返し、記録が永久に成立せず毎セッション再通知になる（抑止が完全に無効）。
rm -f "$CACHE/notified"; mkdir -p "$CACHE/notified"
run_hook "$REPO" "$CACHE"
assert_clean "記録の自己修復: notified がディレクトリ"
run_hook "$REPO" "$CACHE"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "記録の自己修復: ディレクトリ化した notified を除去して記録が成立する"
else
  bad "記録の自己修復: ディレクトリ化後も抑止が効かない: exit=$RC output=[$OUT] stderr=[$ERR]"
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
# 未来の epoch は変数で捕まえる。`$(( now + 999999 ))` の計算結果に "999999" という
# 部分文字列は現れないので、リテラルで grep すると修復の検査が常に真になる（空振り）。
FUTURE_TS="$(( $(date +%s) + 999999 ))"
printf 'fail - %s\n' "$FUTURE_TS" > "$CACHE/update-check"
run_hook "$REPO" "$CACHE"
if printf '%s' "$OUT" | grep "systemMessage" >/dev/null; then
  ok "未来 timestamp: 信用せず再試行して通知が出る"
else
  bad "未来 timestamp: 遠未来キャッシュで沈黙した: exit=$RC output=[$OUT]"
fi
# 通知が出ることだけでは足りない。write_cache が遠未来の記録を「並行セッションの
# 新しい結果」として守り続けると、fail マーカーも ok も永久に書けず、キャッシュが
# 二度と修復されないまま毎セッション ls-remote を払う（ヘッダーが述べる逆転そのもの）。
# 版番号は suite のこの時点のタグに依存するので pin しない。見るのは
# 「遠未来の記録が残っていないこと」= 修復が起きたことだけ。
if grep -Eq '^(ok|fail) [0-9.-]+ [0-9]+$' "$CACHE/update-check" 2>/dev/null \
  && ! grep -Fq " $FUTURE_TS" "$CACHE/update-check"; then
  ok "未来 timestamp: キャッシュを上書き修復した（毎セッション再取得に陥らない）"
else
  bad "未来 timestamp: キャッシュが修復されない: $(cat "$CACHE/update-check" 2>/dev/null || echo '<missing>')"
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

# ---- 8b. 認証失敗（配布リポジトリが Private のとき）: 無出力 + exit 0 + fail 記録 ----
# 配布リポジトリが Private のとき（ADR-049 で一時的にそうだった。ADR-050 で Public へ
# 戻したが回帰ガードとして残す）、HTTPS の認証ヘルパーが無い環境では ls-remote が
# 「terminal prompts disabled」で即失敗する。stub git でその
# 失敗を再現し、(a) 無出力・exit 0、(b) プロンプト封じの env（GIT_TERMINAL_PROMPT /
# GIT_ASKPASS / GIT_SSH_COMMAND）が渡っている、(c) fail キャッシュが残り TTL 内は
# 再試行しない、を固定する。case 8 の「存在しないローカル path」では GitHub 側の
# 認証要求を模せず、プロンプト抑止の env が落ちても素通りするため別ケースにする。
mkdir -p "$TMP/authstub"
cat > "$TMP/authstub/git" <<'STUB'
#!/bin/sh
# ls-remote だけ認証失敗を模す。env の記録は検査用（実 git は呼ばない）
case "$1" in
  ls-remote)
    printf 'GIT_TERMINAL_PROMPT=%s\nGIT_ASKPASS=%s\nGIT_SSH_COMMAND=%s\n' \
      "${GIT_TERMINAL_PROMPT-<unset>}" "${GIT_ASKPASS-<unset>}" "${GIT_SSH_COMMAND-<unset>}" \
      >> "$AUTHSTUB_ENV_LOG"
    echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
    exit 128 ;;
esac
exit 0
STUB
chmod +x "$TMP/authstub/git"
CACHE="$TMP/cache8b"
AUTHSTUB_ENV_LOG="$TMP/authstub.env"
: > "$AUTHSTUB_ENV_LOG"
run_hook "https://github.com/feel-flow/ff-dev-toolkit.git" "$CACHE" \
  PATH="$TMP/authstub:$PATH" AUTHSTUB_ENV_LOG="$AUTHSTUB_ENV_LOG"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "認証失敗: 無出力 + exit 0 + stderr 無出力（ハングせず無音で抜ける）"
else
  bad "認証失敗: exit=$RC output=[$OUT] stderr=[$ERR]"
fi
if [ -s "$AUTHSTUB_ENV_LOG" ] \
  && grep -q '^GIT_TERMINAL_PROMPT=0$' "$AUTHSTUB_ENV_LOG" \
  && grep -q '^GIT_ASKPASS=/usr/bin/false$' "$AUTHSTUB_ENV_LOG" \
  && grep -q '^GIT_SSH_COMMAND=ssh -oBatchMode=yes$' "$AUTHSTUB_ENV_LOG"; then
  ok "認証失敗: プロンプト封じの env（GIT_TERMINAL_PROMPT / GIT_ASKPASS / GIT_SSH_COMMAND）が ls-remote へ渡る"
else
  bad "認証失敗: プロンプト封じの env が欠けている: $(cat "$AUTHSTUB_ENV_LOG" 2>/dev/null || echo '<missing>')"
fi
if [ -f "$CACHE/update-check" ] && grep -q "^fail - " "$CACHE/update-check"; then
  ok "認証失敗: fail キャッシュを記録した"
else
  bad "認証失敗: fail キャッシュが不正: $(cat "$CACHE/update-check" 2>/dev/null || echo '<missing>')"
fi
calls_before="$(grep -c '^GIT_TERMINAL_PROMPT=' "$AUTHSTUB_ENV_LOG")"
run_hook "https://github.com/feel-flow/ff-dev-toolkit.git" "$CACHE" \
  PATH="$TMP/authstub:$PATH" AUTHSTUB_ENV_LOG="$AUTHSTUB_ENV_LOG"
calls_after="$(grep -c '^GIT_TERMINAL_PROMPT=' "$AUTHSTUB_ENV_LOG")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ "$calls_after" -eq "$calls_before" ]; then
  ok "認証失敗: TTL 内の再実行は ls-remote を呼ばない（毎セッション認証失敗を払わない）"
else
  bad "認証失敗: TTL 内に再取得した: calls=${calls_before}→${calls_after} exit=$RC output=[$OUT]"
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
# notified 側の TTL 検証も同じ実行で測る。TTL 超過の記録を置くので通知条件は
# 変わらないが、is_digits の検証を外すと `[ 200000 -lt abc ]` が
# integer expression expected を stderr へ漏らし、下の [ -z "$ERR" ] が赤にする。
printf '0.13.3 0.14.0 %s\n' "$(( $(date +%s) - 200000 ))" > "$CACHE/notified"
run_hook "$TMP/no-such-repo" "$CACHE" FF_DEV_TOOLKIT_UPDATE_TTL_OK=abc FF_DEV_TOOLKIT_UPDATE_TTL_FAIL=-5 \
  FF_DEV_TOOLKIT_UPDATE_TTL_NOTIFIED=abc
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | grep -F "v0.14.0" >/dev/null; then
  ok "非数値 TTL: 3 つとも既定値で動作し stderr を汚さない"
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
FF_REACHED_END=1
exit 0
FF_REACHED_END=1
