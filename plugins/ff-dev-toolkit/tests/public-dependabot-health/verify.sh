#!/usr/bin/env bash
#
# public-dependabot-health: 公開リポジトリの Dependabot 健全性検知（Issue #472）。
#
# 背景: 公開リポジトリ feel-flow/ff-dev-toolkit は依存グラフが無効なまま
# Dependabot alerts だけが有効という状態にあり、改名で消えた旧 manifest パスへ
# 紐づく alert が発行され続けた。本 suite はその再発検知
# （scripts/check-public-dependabot-health.sh + .claude/hooks/session-start-dependabot-health.sh）
# の分岐を固定する。
#
# 固定する契約:
#   - 健全（グラフ生存 + open 0 件）なら hook は**無音**。ただし「無音」の検査は
#     それ自体が空振りしうる — checker を起動できていないだけでも無音になる。
#     スタブにマーカーを作らせ、**実際に走ったうえでの無音**であることを積極確認する。
#   - グラフ無効（登録 manifest 0）は #472 の根本原因そのものの再発として名指しする。
#   - 幽霊 alert（manifest_path がデフォルトブランチに実在しない）は、実在する
#     manifest に紐づく通常の alert と**別物として**数え、別の文言で報告する。
#     両者を混ぜると「dismiss すればよい」という誤った対処へ誘導してしまう。
#   - 幽霊と通常は同時に存在しうる。片方で打ち切らず**両方**報告する。
#   - グラフ無効と幽霊も同時に起こりうる（#472 の実際の状態）。両方報告する。
#   - 実在確認を完遂できなかった場合（tree が truncated）は幽霊数を断定せず、
#     **その注意書きが hook の通知本文まで到達する**こと。checker 側だけ検査しても
#     hook が握り潰す退行は捕まらない（実際にその形で 1 件すり抜けた）。
#   - checker の失敗理由は hook の通知本文まで届くこと。「原因不明」に潰すと
#     認証切れ・リポジトリ消失・rate limit が切り分け不能になる。
#   - 必須キーが非数値なら通知して止まること。算術比較 `[[ "$x" -eq 0 ]]` は
#     非数値を変数名として評価し、set -u 下ではシェルごと即死して**無音**になる。
#   - hook は cwd ではなく自身の配置からリポジトリルートを解決すること（Issue #474）。
#
# 対象は SSOT リポジトリのスクリプトと hook（公開配布物ではない）。それらが無い
# チェックアウト（公開リポジトリ等）では ○ skip。
#
# gh は DEPENDABOT_HEALTH_GH のスタブへ差し替えるため、本 suite はネットワークに
# 触れない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
CHECKER="${REPO_ROOT:+$REPO_ROOT/scripts/check-public-dependabot-health.sh}"
HOOK="${REPO_ROOT:+$REPO_ROOT/.claude/hooks/session-start-dependabot-health.sh}"

if [ -z "$REPO_ROOT" ] || [ ! -f "$CHECKER" ] || [ ! -f "$HOOK" ]; then
  echo "○ skip: 検知スクリプト／hook が無いチェックアウトのためスキップ（本 suite は SSOT リポジトリ専用の検査です）"
  FF_REACHED_END=1
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（hook の通知 JSON は未検査のままです）"
  FF_REACHED_END=1
  exit 0
fi

if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi

# 途中死を沈黙させない（claude-hooks-path と同じ規律）。トラップ突入時の $? は
# `set -u` 死でも 0 になるため、「rc=0 なのに最後まで到達していない」を中断として扱う。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ public-dependabot-health: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- gh スタブ -----------------------------------------------------------------
# 実 gh の呼び分けを引数で再現する。fixture は env で与える:
#   STUB_MANIFESTS       GraphQL の totalCount（`none` なら totalCount を含まない応答）
#   STUB_GRAPH_FAIL=1    GraphQL 呼び出しを非 0 で失敗させる
#   STUB_ALERT_PATHS     open alert の manifest_path（改行区切り。空なら 0 件）
#   STUB_ALERTS_FAIL=1   alert 取得を非 0 で失敗させる
#   STUB_TREE_PATHS      リポジトリに実在する blob パス（改行区切り）
#   STUB_TREE_TRUNCATED  tree 応答の truncated 値（既定 false）
#   STUB_TREE_FAIL=1     tree 取得を非 0 で失敗させる
#   STUB_MARKER          呼び出されたら touch するファイル（checker の起動を実証する）
STUB="$TMP/gh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
[ -n "${STUB_MARKER:-}" ] && : > "$STUB_MARKER"
case "$args" in
  *graphql*)
    if [ "${STUB_GRAPH_FAIL:-0}" = 1 ]; then
      echo "gh: stubbed graphql failure" >&2
      exit 1
    fi
    if [ "${STUB_MANIFESTS:-0}" = none ]; then
      # 権限不足時の GitHub の挙動: HTTP 200 + errors で totalCount を含まない
      printf '%s\n' '{"data":{"repository":null},"errors":[{"message":"stubbed"}]}'
    else
      printf '{"data":{"repository":{"dependencyGraphManifests":{"totalCount":%s}}}}\n' "${STUB_MANIFESTS:-0}"
    fi
    exit 0
    ;;
  *dependabot/alerts*)
    if [ "${STUB_ALERTS_FAIL:-0}" = 1 ]; then
      echo "gh: stubbed alerts failure" >&2
      exit 1
    fi
    [ -n "${STUB_ALERT_PATHS:-}" ] && printf '%s\n' "$STUB_ALERT_PATHS"
    exit 0
    ;;
  *git/trees/*)
    if [ "${STUB_TREE_FAIL:-0}" = 1 ]; then
      echo "gh: stubbed tree failure" >&2
      exit 1
    fi
    printf 'TRUNCATED=%s\n' "${STUB_TREE_TRUNCATED:-false}"
    [ -n "${STUB_TREE_PATHS:-}" ] && printf '%s\n' "$STUB_TREE_PATHS"
    exit 0
    ;;
esac
echo "gh: unexpected stub invocation: $args" >&2
exit 1
STUBEOF
chmod +x "$STUB"

run_checker() { # env は呼び出し側で指定 / stdout: checker 出力, 戻り値: rc
  DEPENDABOT_HEALTH_GH="$STUB" DEPENDABOT_HEALTH_PUBLIC_REPO="feel-flow/ff-dev-toolkit" \
    bash "$CHECKER" 2>/dev/null
}

run_hook() { # stdout: hook の通知 JSON（無音なら空）
  DEPENDABOT_HEALTH_GH="$STUB" DEPENDABOT_HEALTH_PUBLIC_REPO="feel-flow/ff-dev-toolkit" \
    bash "$HOOK" 2>/dev/null
}

hook_ctx() { # stdin: hook 出力 / stdout: additionalContext 文字列
  jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true
}

# 幽霊パスの fixture は「デフォルトブランチに実在しない」ことだけが要件で、
# 実際の歴史的パスである必要はない。**改名で退役した旧公開名をここに書かないこと** —
# このファイルは公開同期対象で、同期スクリプトの禁止パターン検査が旧名を
# fail-closed で弾き、公開が丸ごと止まる（実際に止めた）。再現性を上げるつもりで
# 実パスへ戻すと、同じ形で同期が再びブロックされる。
GHOST_A="plugins/retired-plugin/mcp/package-lock.json"
GHOST_B="plugins/retired-plugin/mcp/package.json"
LIVE_1="plugins/ff-dev-toolkit/mcp/package-lock.json"
LIVE_2="plugins/ff-dev-toolkit/mcp/package.json"
TREE="$LIVE_1
$LIVE_2
README.md"

echo "public-dependabot-health verify:"

# --- ケース 1: 健全（グラフ生存 + open 0 件）--------------------------------------
out="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="" run_checker)"
if grep -qx 'GRAPH_MANIFESTS=2' <<<"$out" \
  && grep -qx 'OPEN_ALERTS=0' <<<"$out" \
  && grep -qx 'GHOST_ALERTS=0' <<<"$out"; then
  ok "健全時: GRAPH_MANIFESTS/OPEN_ALERTS/GHOST_ALERTS を規定どおり出力する"
else
  bad "健全時の checker 出力が想定と違う: $(tr '\n' ' ' <<<"$out")"
fi

# 「無音」の検査が空振りしないことを固定する。checker を起動できていないだけでも
# 無音にはなるので、スタブが実際に呼ばれた証跡を併せて要求する。
MARKER="$TMP/ran.marker"
rm -f "$MARKER"
hout="$(STUB_MARKER="$MARKER" STUB_MANIFESTS=2 STUB_ALERT_PATHS="" run_hook)"
if [ -z "$hout" ] && [ -f "$MARKER" ]; then
  ok "健全時: hook は無音（かつ checker が実際に起動したことを実証）"
elif [ ! -f "$MARKER" ]; then
  bad "健全時: checker が起動していない（無音は空振り。hook のルート解決を疑う）"
else
  bad "健全時に hook が出力した: $hout"
fi

# --- ケース 2: グラフ無効 → #472 根本原因の再発として名指しする -----------------
out="$(STUB_MANIFESTS=0 STUB_ALERT_PATHS="" run_checker)"
if grep -qx 'GRAPH_MANIFESTS=0' <<<"$out"; then
  ok "グラフ無効: GRAPH_MANIFESTS=0 を出力する"
else
  bad "グラフ無効を GRAPH_MANIFESTS=0 として出力しない: $(tr '\n' ' ' <<<"$out")"
fi

ctx="$(STUB_MANIFESTS=0 STUB_ALERT_PATHS="" run_hook | hook_ctx)"
if grep -q '依存グラフが無効化' <<<"$ctx" && grep -q '#472' <<<"$ctx"; then
  ok "グラフ無効: hook が根本原因の再発として #472 を名指しで通知する"
else
  bad "グラフ無効時の hook 通知が想定と違う: $ctx"
fi
if grep -q 'PATCH /repos' <<<"$ctx"; then
  ok "グラフ無効: 200 を返して無視される PATCH 経路の罠を通知に含める"
else
  bad "グラフ無効通知に PATCH 経路の警告がない（次の対応者が最初に踏む）: $ctx"
fi

# --- ケース 3: 幽霊 alert（実在しないパスに紐づく open alert） -------------------
out="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$GHOST_A
$GHOST_A
$GHOST_A" STUB_TREE_PATHS="$TREE" run_checker)"
if grep -qx 'OPEN_ALERTS=3' <<<"$out" \
  && grep -qx 'GHOST_ALERTS=3' <<<"$out" \
  && grep -qxF "GHOST_PATH=${GHOST_A}" <<<"$out"; then
  ok "幽霊 alert: 同一パスに紐づく複数 alert を数え、パスを名指しする"
else
  bad "幽霊 alert の集計が想定と違う: $(tr '\n' ' ' <<<"$out")"
fi

ctx="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$GHOST_A" STUB_TREE_PATHS="$TREE" run_hook | hook_ctx)"
if grep -q '実在しない' <<<"$ctx" && grep -qF "$GHOST_A" <<<"$ctx"; then
  ok "幽霊 alert: hook が実在しないパスを名指しして通知する"
else
  bad "幽霊 alert の hook 通知が想定と違う: $ctx"
fi
if grep -q 'dismiss は症状対処' <<<"$ctx"; then
  ok "幽霊 alert: hook が dismiss へ誘導しない"
else
  bad "幽霊 alert 通知に dismiss 抑止の文言がない: $ctx"
fi

# --- ケース 4: 実在する manifest に紐づく通常の alert は幽霊扱いしない -----------
out="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$LIVE_1
$LIVE_1" STUB_TREE_PATHS="$TREE" run_checker)"
if grep -qx 'OPEN_ALERTS=2' <<<"$out" && grep -qx 'GHOST_ALERTS=0' <<<"$out"; then
  ok "通常 alert: 実在パスに紐づく alert を幽霊として数えない"
else
  bad "通常 alert を幽霊と誤判定した: $(tr '\n' ' ' <<<"$out")"
fi

ctx="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$LIVE_1" STUB_TREE_PATHS="$TREE" run_hook | hook_ctx)"
if grep -q '実データに基づく指摘' <<<"$ctx" && ! grep -q '実在しない' <<<"$ctx"; then
  ok "通常 alert: hook が幽霊とは別の文言で報告する"
else
  bad "通常 alert の hook 通知が幽霊と混同されている: $ctx"
fi

# --- ケース 5: 幽霊と通常の混在（異なる幽霊パスを全て名指しし、両方を報告する）---
MIXED="$GHOST_A
$GHOST_A
$GHOST_B
$LIVE_1"
out="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$MIXED" STUB_TREE_PATHS="$TREE" run_checker)"
if grep -qx 'OPEN_ALERTS=4' <<<"$out" && grep -qx 'GHOST_ALERTS=3' <<<"$out" \
  && grep -qxF "GHOST_PATH=${GHOST_A}" <<<"$out" && grep -qxF "GHOST_PATH=${GHOST_B}" <<<"$out"; then
  ok "混在: 幽霊のみを数え(3/4)、異なる幽霊パスを全て名指しする"
else
  bad "混在時の集計が想定と違う: $(tr '\n' ' ' <<<"$out")"
fi

ctx="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$MIXED" STUB_TREE_PATHS="$TREE" run_hook | hook_ctx)"
if grep -q '実在しない' <<<"$ctx" && grep -q '実データに基づく指摘' <<<"$ctx" \
  && grep -q 'dependabot/alerts' <<<"$ctx"; then
  ok "混在: 幽霊があっても実データ alert とその確認コマンドを隠さない"
else
  bad "混在時に実データ alert の報告が幽霊に飲まれた: $ctx"
fi

# --- ケース 6: グラフ無効 + 幽霊の同時発生（#472 の実際の状態）------------------
ctx="$(STUB_MANIFESTS=0 STUB_ALERT_PATHS="$GHOST_A
$GHOST_B" STUB_TREE_PATHS="$TREE" run_hook | hook_ctx)"
if grep -q '依存グラフが無効化' <<<"$ctx" && grep -q '実在しない' <<<"$ctx" \
  && grep -qF "$GHOST_A" <<<"$ctx" && grep -qF "$GHOST_B" <<<"$ctx"; then
  ok "同時発生: 根本原因と症状の両方を報告し、幽霊パスを全て列挙する"
else
  bad "同時発生時に根本原因か幽霊パスが欠落した: $ctx"
fi

# --- ケース 7: 実在確認を完遂できないとき断定せず、注意書きが通知まで届く -------
out="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$LIVE_1" STUB_TREE_TRUNCATED=true run_checker)"
if grep -qx 'GHOST_UNVERIFIED=1' <<<"$out" && grep -qx 'GHOST_ALERTS=0' <<<"$out"; then
  ok "tree が truncated: 幽霊と断定せず GHOST_UNVERIFIED=1 で可視化する"
else
  bad "tree truncated 時の checker 出力が想定と違う: $(tr '\n' ' ' <<<"$out")"
fi

ctx="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$LIVE_1" STUB_TREE_TRUNCATED=true run_hook | hook_ctx)"
if grep -q '実在確認を完遂できません' <<<"$ctx" && grep -q '下限値' <<<"$ctx"; then
  ok "tree が truncated: 判定不能の注意書きが hook の通知本文まで到達する"
else
  bad "判定不能なのに通知へ到達していない: $ctx"
fi
if ! grep -q '実データに基づく指摘' <<<"$ctx"; then
  ok "tree が truncated: 未確認の alert を「実在する manifest に紐づく」と断定しない"
else
  bad "確認していない alert を実在と断定した（#269 の dismiss 誘導に戻る）: $ctx"
fi

# --- ケース 8: tree 取得の失敗は truncation ではなく判定不能（SKIP）--------------
if out="$(STUB_MANIFESTS=2 STUB_ALERT_PATHS="$LIVE_1" STUB_TREE_FAIL=1 run_checker)"; then
  bad "tree 取得失敗時に checker が exit 0 を返した: $(tr '\n' ' ' <<<"$out")"
else
  if grep -q '^SKIP_REASON=.*tree' <<<"$out" && ! grep -q 'GHOST_UNVERIFIED' <<<"$out"; then
    ok "tree 取得失敗: truncation へ畳まず SKIP_REASON で判定不能を返す"
  else
    bad "tree 取得失敗の扱いが想定と違う: $(tr '\n' ' ' <<<"$out")"
  fi
fi

# --- ケース 9: API 失敗の診断が hook の通知本文まで伝播する ---------------------
if out="$(STUB_GRAPH_FAIL=1 run_checker)"; then
  bad "GraphQL 失敗時に checker が exit 0 を返した: $(tr '\n' ' ' <<<"$out")"
else
  if grep -q '^SKIP_REASON=' <<<"$out" && grep -q 'stubbed graphql failure' <<<"$out"; then
    ok "GraphQL 失敗: SKIP_REASON に gh の stderr を診断として載せる"
  else
    bad "GraphQL 失敗時の SKIP_REASON が診断情報を持たない: $(tr '\n' ' ' <<<"$out")"
  fi
fi

ctx="$(STUB_GRAPH_FAIL=1 run_hook | hook_ctx)"
if grep -q 'スキップ' <<<"$ctx" && grep -q 'このセッションでの対応は不要' <<<"$ctx"; then
  ok "checker 失敗: hook が無音にせず、即対応不要と添えて可視化する（ACE-72-2）"
else
  bad "checker 失敗時の hook 通知が想定と違う: $ctx"
fi
if grep -q 'stubbed graphql failure' <<<"$ctx"; then
  ok "checker 失敗: 失敗理由が hook 通知本文まで届く（原因の切り分けが可能）"
else
  bad "失敗理由が hook 通知で失われている（認証切れ・消失・rate limit が同一文言になる）: $ctx"
fi

if out="$(STUB_ALERTS_FAIL=1 STUB_MANIFESTS=2 run_checker)"; then
  bad "alert 取得失敗時に checker が exit 0 を返した: $(tr '\n' ' ' <<<"$out")"
else
  if grep -q '^SKIP_REASON=.*Dependabot alert 取得に失敗' <<<"$out"; then
    ok "alert 取得失敗: グラフ取得成功と区別した SKIP_REASON を返す"
  else
    bad "alert 取得失敗の SKIP_REASON が想定と違う: $(tr '\n' ' ' <<<"$out")"
  fi
fi

# --- ケース 10: GraphQL が 200 でも totalCount 不在なら 0 と混同しない ----------
if out="$(STUB_MANIFESTS=none run_checker)"; then
  bad "totalCount 不在時に checker が exit 0 を返した（0 件と混同）: $(tr '\n' ' ' <<<"$out")"
else
  if grep -q '^SKIP_REASON=.*totalCount' <<<"$out"; then
    ok "totalCount 不在: グラフ無効(0)と判定不能を混同せず skip する"
  else
    bad "totalCount 不在時の SKIP_REASON が想定と違う: $(tr '\n' ' ' <<<"$out")"
  fi
fi

# --- ケース 11: hook のプロトコル検査（キー欠落 / 非数値 / checker 不在）--------
FAKE_ROOT="$TMP/fakeroot"
mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/.claude/hooks"
git -C "$FAKE_ROOT" init -q 2>/dev/null
cp "$HOOK" "$FAKE_ROOT/.claude/hooks/"
FAKE_CHECKER="$FAKE_ROOT/scripts/check-public-dependabot-health.sh"
FAKE_HOOK="$FAKE_ROOT/.claude/hooks/session-start-dependabot-health.sh"

write_fake_checker() { printf '%s\n' '#!/usr/bin/env bash' "$@" 'exit 0' > "$FAKE_CHECKER"; chmod +x "$FAKE_CHECKER"; }

write_fake_checker 'echo "UNRELATED_KEY=1"'
ctx="$(bash "$FAKE_HOOK" 2>/dev/null | hook_ctx)"
if grep -q '数値として解析できなかった' <<<"$ctx"; then
  ok "プロトコル不整合: exit 0 でも必須キーが無ければ無音にしない（ACE-72-2）"
else
  bad "プロトコル不整合を無音にした: '$ctx'"
fi

# 非数値は算術比較で set -u 即死（＝無音）を招く。通知して止まること。
write_fake_checker 'echo "GRAPH_MANIFESTS=abc"' 'echo "OPEN_ALERTS=0"' 'echo "GHOST_ALERTS=0"'
ctx="$(bash "$FAKE_HOOK" 2>/dev/null | hook_ctx)"
if grep -q '数値として解析できなかった' <<<"$ctx"; then
  ok "非数値: 算術比較の前に弾いて通知する（set -u による無音の即死を防ぐ）"
else
  bad "非数値を弾かず無音で落ちた: '$ctx'"
fi

rm -f "$FAKE_CHECKER"
ctx="$(bash "$FAKE_HOOK" 2>/dev/null | hook_ctx)"
if grep -q '検査スクリプトが存在しないか実行権限がない' <<<"$ctx"; then
  ok "checker 不在: settings.json 登録済みなのに実体が無い状態を名指しする"
else
  bad "checker 不在を可視化しない: '$ctx'"
fi

# --- ケース 12: hook は cwd ではなく自身の配置からルートを解決する（#474）-------
# 非 git ディレクトリを cwd にしても、hook の隣にある checker を使えること。
NONGIT="$TMP/nongit"
mkdir -p "$NONGIT"
write_fake_checker 'echo "GRAPH_MANIFESTS=0"' 'echo "OPEN_ALERTS=0"' 'echo "GHOST_ALERTS=0"'
ctx="$(cd "$NONGIT" && GIT_CEILING_DIRECTORIES="$TMP" env -u GIT_DIR -u GIT_WORK_TREE \
  bash "$FAKE_HOOK" 2>/dev/null | hook_ctx)"
if grep -q '依存グラフが無効化' <<<"$ctx"; then
  ok "ルート解決: 非 git ディレクトリが cwd でも hook 自身の配置から checker を見つける"
else
  bad "cwd 依存のルート解決で無音終了した（#474 と同型の退行）: '$ctx'"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ public-dependabot-health verify: ${FAIL} 件 fail / ${PASS} 件 pass" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ public-dependabot-health verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
exit 0
