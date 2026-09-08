#!/usr/bin/env bash
#
# base ブランチ解決が「古くないほうの ref」を選ぶことの回帰テスト。
#
# 塞いでいる事故: PR ブランチを origin/<base> へ rebase した直後にローカル <base> を
# pull し忘れると、resolve_base_branch_ref がローカル ref を無条件で返し、
# `<base>...HEAD` の三点比較へ rebase で取り込んだ他ブランチのコミットが混入する。
# レビューの指摘が丸ごと「自分の差分に無いファイル」へ向く。
#
# 検査する分岐:
#   (1) ローカルが origin の真の祖先（stale） → origin/<base> を採り、混入が消える
#   (2) ローカルと origin が一致            → 従来どおりローカル（選択行も出さない）
#   (3) ローカルが origin より先行          → ローカルを尊重する（未 push の base 更新）
#   (4) 選択行が local / origin と両者の short SHA を名乗る
#   (5) ローカルと origin が分岐            → ローカルを維持する（保守的）
#   (6) ローカル不在 / 未知の名前           → 従来どおりの fallback
#   (7) multi-agent.sh の --base も同じ解決を通る
#   (8) 分岐時は解決がローカルを維持し、混入件数つきの鮮度警告が残る
#   (9) 選択行は 1 実行につき 1 行だけ（使わない既定 base の行を出さない）
#  (10) レビュー系列 ID は base の鮮度で変わらない（pull しただけで別系列にしない）
#  (11) 祖先関係を確認できないとき（rc が 0/1 以外）は「判定できなかった」と名乗る
#  (12) アダプタ直叩き（parse_adapter_args）の --base も同じ解決を通る
#
# ネットワークには触らない（fetch でリモートへ出ない）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$ADAPTER_COMMON" ] || { echo "✗ adapter-common.sh が見つかりません" >&2; exit 1; }
[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません" >&2; exit 1; }

# 実行環境からの分離。本 suite が orchestrator を起動するのは (7) の 1 回だけで、
# 見るのは実行計画の「Base branch:」行のみ — アダプタの env 配線は 1 つも通らない。
# そのため共通ライブラリ（tests/lib/adapter-env-isolation.sh）は使わず、実行計画の
# 到達性に効く 2 つだけをその場で外す。ホストが設定していれば、設定ファイルの
# 差し替えで早期終了したり、base の既定が変わったりして (7) の前提が崩れる。
ORCHESTRATOR_ENV=(env -u MULTI_AGENT_CONFIG -u MULTI_AGENT_BASE_BRANCH)

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# mktemp の stderr は捨てない（read-only 以外の失敗を skip へ誤帰属させない）。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
trap 'cd /; rm -rf "$TMP"' EXIT

# 全 CLI を「導入済み」に見せる stub（dry-run なので起動はされない）。これが無いと
# 実行計画が空 → rc=1 になり、(7)/(8) が「環境都合の skip」で通ってしまう
# （orchestrator が実際に何を base として名乗るかを一度も検査できない）。
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
for _cli in claude codex copilot grok; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$STUB/$_cli"
  chmod +x "$STUB/$_cli"
done

# orchestrator を dry-run で回して stdout+stderr を返す。rc は呼び出し側へ渡す
# （`|| true` で握り潰すと、実行計画が出ない失敗が部分 skip のまま成功になる）。
run_orchestrator() { # $1: 出力ファイル, $2..: multi-agent 引数
  local out="$1"
  shift
  "${ORCHESTRATOR_ENV[@]}" PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --mode distributed --strategy balanced --dry-run "$@" >"$out" 2>&1
}

STDERR_FILE="$TMP/resolve-stderr.txt"

# 被検体の関数だけを読み込んで呼ぶ。stdout（解決した ref）と stderr（選択行）を分ける。
resolve() {
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  ( . "$ADAPTER_COMMON"; resolve_base_branch_ref "$1" ) 2>"$STDERR_FILE"
}

# ---- fixture: bare origin + clone -------------------------------------------
#
# origin/develop に「他 PR のマージ」を 1 件積み、作業側のローカル develop はその手前で
# 止める。feature は origin/develop（新しい方）から切る = rebase 直後の状態を再現する。

git init --bare -q "$TMP/origin.git"
# 空リポジトリの clone 警告は仕様どおりなので捨てる（suite の出力を汚さない）
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
ff_git_fixture_init "$TMP/work" "base-ref-freshness-test" "test@example.com"
cd "$TMP/work"
git config commit.gpgsign false

git switch -q -c develop
echo base > README.md
git add README.md
git commit -qm "init"
git push -qu origin develop

echo other > other.txt
git add other.txt
git commit -qm "other PR merged into develop"
git push -q origin develop
ORIGIN_SHA="$(git rev-parse HEAD)"

git switch -q -c feature/topic
echo mine > mine.txt
git add mine.txt
git commit -qm "my change"

# ローカル develop だけ 1 つ前に取り残す = pull し忘れ
git branch -qf develop "${ORIGIN_SHA}^"
LOCAL_SHA="$(git rev-parse refs/heads/develop)"

# ---- (1) stale なローカル → origin を採る ------------------------------------

RESOLVED="$(resolve develop)"
if [ "$RESOLVED" = "origin/develop" ]; then
  ok "(1) ローカル develop が origin より古いとき origin/develop を採る"
else
  bad "(1) stale なローカルを採った: '${RESOLVED}'（期待 origin/develop）"
fi

# grep -q へパイプで流し込まない（上流を SIGPIPE で殺す形は run-all の再混入ガードが
# 禁じている）。いったん変数へ受けて here-string で渡す。
DIFF_RESOLVED="$(git diff --name-only "${RESOLVED}...HEAD")"
DIFF_LOCAL="$(git diff --name-only "develop...HEAD")"
if grep -qx 'other.txt' <<<"$DIFF_RESOLVED"; then
  bad "(1) 解決した base の diff に他 PR の other.txt が混入した"
else
  ok "(1) 解決した base の diff に他 PR のコミットが混入しない"
fi

# 対照: stale なローカルを base にすると実際に混入する（fixture が事故を再現している証拠）
if grep -qx 'other.txt' <<<"$DIFF_LOCAL"; then
  ok "(1) 対照: ローカル develop 基準では other.txt が混入する（fixture 妥当）"
else
  bad "(1) 対照: fixture が混入を再現できていない（この suite に検出力が無い）"
fi

# ---- (4) 選択行 --------------------------------------------------------------

if grep -q 'origin/develop' "$STDERR_FILE" && grep -q 'local' "$STDERR_FILE"; then
  ok "(4) 選択行が local / origin のどちらを採ったかを名乗る"
else
  bad "(4) 選択行に local / origin の名乗りが無い: '$(cat "$STDERR_FILE")'"
fi
if grep -q "$(printf '%.7s' "$LOCAL_SHA")" "$STDERR_FILE" \
  && grep -q "$(printf '%.7s' "$ORIGIN_SHA")" "$STDERR_FILE"; then
  ok "(4) 選択行が local / origin 両者の short SHA を出す"
else
  bad "(4) 選択行に両者の short SHA が無い: '$(cat "$STDERR_FILE")'"
fi

# ---- (2) 一致 → ローカル -----------------------------------------------------

git branch -qf develop "$ORIGIN_SHA"
RESOLVED="$(resolve develop)"
if [ "$RESOLVED" = "develop" ]; then
  ok "(2) ローカルと origin が一致するときはローカルを採る"
else
  bad "(2) 一致しているのにローカルを採らなかった: '${RESOLVED}'"
fi
if [ -s "$STDERR_FILE" ]; then
  bad "(2) 同一コミットなのに選択行を出した: '$(cat "$STDERR_FILE")'"
else
  ok "(2) 同一コミットのときは選択行を出さない（常設ノイズにしない）"
fi

# ---- (3) ローカルが先行 → ローカル -------------------------------------------

git switch -q develop
echo local-only > local-only.txt
git add local-only.txt
git commit -qm "unpushed base update"
AHEAD_SHA="$(git rev-parse HEAD)"
git switch -q feature/topic
RESOLVED="$(resolve develop)"
if [ "$RESOLVED" = "develop" ]; then
  ok "(3) ローカルが origin より先行しているときはローカルを尊重する"
else
  bad "(3) 未 push の base 更新を捨てて origin を採った: '${RESOLVED}'"
fi

# ---- (5) 分岐 → ローカル維持 -------------------------------------------------
#
# ローカル develop（AHEAD_SHA）はそのまま、remote-tracking ref だけを別系統へ動かす。
# update-ref で直接書くのはネットワークへ出ないため（fetch/push はしない）。

git switch -q -c origin-side "$ORIGIN_SHA"
echo origin-only > origin-only.txt
git add origin-only.txt
git commit -qm "origin-side commit"
DIVERGED_SHA="$(git rev-parse HEAD)"
git switch -q feature/topic
git branch -q -D origin-side
git branch -qf develop "$AHEAD_SHA"
git update-ref refs/remotes/origin/develop "$DIVERGED_SHA"
RESOLVED="$(resolve develop)"
if [ "$RESOLVED" = "develop" ]; then
  ok "(5) ローカルと origin が分岐しているときはローカルを維持する"
else
  bad "(5) 分岐しているのに origin へ倒した: '${RESOLVED}'（未 push のコミットが落ちる）"
fi

# ---- (6) fallback ------------------------------------------------------------

RESOLVED="$(resolve no-such-branch-anywhere)"
if [ "$RESOLVED" = "no-such-branch-anywhere" ]; then
  ok "(6) ローカルも origin も無い名前は素通しする"
else
  bad "(6) 未知の base を書き換えた: '${RESOLVED}'"
fi

git update-ref refs/remotes/origin/clone-only "$ORIGIN_SHA"
RESOLVED="$(resolve clone-only)"
if [ "$RESOLVED" = "origin/clone-only" ]; then
  ok "(6) ローカルが無い場合は remote-tracking ref へ倒す（clone 直後）"
else
  bad "(6) ローカル不在時の fallback が壊れた: '${RESOLVED}'"
fi

# ---- (7) multi-agent.sh --base も同じ解決を通る ------------------------------
#
# stale なローカル develop を作り直し、--dry-run の実行計画が名乗る base を見る。

git update-ref refs/remotes/origin/develop "$ORIGIN_SHA"
git branch -qf develop "${ORIGIN_SHA}^"
PLAN_LOG="$TMP/plan-stale.log"
PLAN_RC=0
run_orchestrator "$PLAN_LOG" --base develop || PLAN_RC=$?
PLAN_OUT="$(cat "$PLAN_LOG")"
if [ "$PLAN_RC" -ne 0 ]; then
  bad "(7) multi-agent.sh --dry-run が rc=${PLAN_RC} で失敗した（実行計画を検査できていない）"
  tail -5 "$PLAN_LOG" | sed 's/^/    | /' >&2
elif ! grep -q 'Base branch:' <<<"$PLAN_OUT"; then
  bad "(7) 実行計画に 'Base branch:' 行が出ていない（base の名乗りを検査できていない）"
  tail -5 "$PLAN_LOG" | sed 's/^/    | /' >&2
elif grep -q 'Base branch: origin/develop' <<<"$PLAN_OUT"; then
  ok "(7) multi-agent.sh --base develop が origin/develop へ解決される"
else
  bad "(7) --base が解決を通らずローカル ref のまま: $(grep -m1 'Base branch:' <<<"$PLAN_OUT")"
fi

# ---- (9) 選択行は 1 実行につき 1 行だけ --------------------------------------
#
# 既定 base（init）と --base（パース時）の両方で解決していた頃は、同じ実行で
# 選択行が 2 行出た。しかも別 base を指定した実行では「使われない既定 base」の行が
# 混じり、どちらが実際に使われたのか読み手に判別できない。

SELECT_LINES="$(grep -c 'base ref: ' "$PLAN_LOG" || true)"
if [ "$SELECT_LINES" -eq 1 ]; then
  ok "(9) --base 指定時の選択行はちょうど 1 行"
else
  bad "(9) 選択行が ${SELECT_LINES} 行出た（期待 1 行）"
  grep -n 'base ref: ' "$PLAN_LOG" | sed 's/^/    | /' >&2
fi

# 別 base を指定したときに、使われない既定 base（develop）の行が出ないこと
git branch -qf other-base "$ORIGIN_SHA"
OTHER_LOG="$TMP/plan-other-base.log"
OTHER_RC=0
run_orchestrator "$OTHER_LOG" --base other-base || OTHER_RC=$?
OTHER_SELECT="$(grep -c 'base ref: ' "$OTHER_LOG" || true)"
if [ "$OTHER_RC" -ne 0 ]; then
  bad "(9) --base other-base の dry-run が rc=${OTHER_RC} で失敗した"
  tail -5 "$OTHER_LOG" | sed 's/^/    | /' >&2
elif [ "$OTHER_SELECT" -eq 0 ] && ! grep -q 'base ref: .*develop' "$OTHER_LOG"; then
  ok "(9) 別 base 指定では使われない既定 base（develop）の選択行を出さない"
else
  bad "(9) 使われない既定 base の選択行が出た（${OTHER_SELECT} 行）"
  grep -n 'base ref: ' "$OTHER_LOG" | sed 's/^/    | /' >&2
fi
git branch -q -D other-base

# ---- (10) レビュー系列 ID は base の鮮度で変わらない -------------------------
#
# 系列 ID に**解決後**の base 名を混ぜると、stale のまま 1 回目 → git pull 後の
# 2 回目で develop ↔ origin/develop が入れ替わり、同じブランチ・同じ base・同じ
# scope のレビューが「another branch/base/scope」と判定される（未解決 Critical を
# 引き継げず強制フルレビューになる偽陽性）。被検体の 2 関数だけを取り出して固定する。

sed -n '/^finalize_base_branch() {/,/^}/p' "$MULTI_AGENT" > "$TMP/fn-finalize.sh"
sed -n '/^current_review_series_id() {/,/^}/p' "$MULTI_AGENT" > "$TMP/fn-series.sh"
series_id_now() {
  (
    set -euo pipefail
    . "$ADAPTER_COMMON"
    . "$TMP/fn-finalize.sh"
    . "$TMP/fn-series.sh"
    REPO_ROOT="$TMP/work"
    STAGED_DIFF=false
    BASE_BRANCH="develop"
    BASE_BRANCH_IDENTITY=""
    finalize_base_branch 2>/dev/null
    current_review_series_id
  )
}
if [ -s "$TMP/fn-finalize.sh" ] && [ -s "$TMP/fn-series.sh" ]; then
  # 1 回目: ローカル develop は stale（解決は origin/develop を採る）
  SERIES_STALE="$(series_id_now)"
  # 2 回目: 追従した（解決はローカル develop を採る）
  git branch -qf develop "$ORIGIN_SHA"
  SERIES_SYNCED="$(series_id_now)"
  git branch -qf develop "${ORIGIN_SHA}^"
  if [ -n "$SERIES_STALE" ] && [ "$SERIES_STALE" = "$SERIES_SYNCED" ]; then
    ok "(10) base を pull しても系列 ID は変わらない（stale=${SERIES_STALE}）"
  else
    bad "(10) base の鮮度だけで系列 ID が変わった（stale='${SERIES_STALE}' synced='${SERIES_SYNCED}'）"
  fi
else
  bad "(10) 被検体の関数を multi-agent.sh から抽出できなかった（関数名が変わった可能性）"
fi

# ---- (11) 祖先関係を確認できないとき（rc が 0/1 以外）------------------------
#
# shallow clone では共通祖先まで履歴が無く `git merge-base --is-ancestor` が 128 で
# 落ちる。これを rc=1 と同じ扱いにすると「origin より stale ではない」と断言してしまい、
# 実際に混入が起きても利用者が原因へ辿り着けない。ローカル維持は同じでも名乗りを分ける。
# 実 shallow clone を作らず、rc だけを差し替えて分岐を直接突く。
resolve_with_undecidable_ancestor() { # <base>
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    . "$ADAPTER_COMMON"
    git() {
      if [ "${1:-}" = "merge-base" ] && [ "${2:-}" = "--is-ancestor" ]; then
        return 128
      fi
      command git "$@"
    }
    resolve_base_branch_ref "$1"
  ) 2>"$STDERR_FILE"
}
RESOLVED="$(resolve_with_undecidable_ancestor develop)"
if [ "$RESOLVED" = "develop" ]; then
  ok "(11) 祖先関係を確認できないときはローカルを維持する"
else
  bad "(11) 判定不能なのに base を差し替えた: '${RESOLVED}'"
fi
if grep -q '鮮度を判定できませんでした' "$STDERR_FILE" \
  && ! grep -q 'stale ではない' "$STDERR_FILE"; then
  ok "(11) 判定不能は「stale ではない」と断言せず、判定できなかったと名乗る"
else
  bad "(11) 判定不能の名乗りが無い: '$(cat "$STDERR_FILE")'"
fi

# ---- (12) アダプタ直叩きの --base も解決を通る -------------------------------
#
# parse_adapter_args の --base が verbatim 代入だと、orchestrator を介さない直接起動
# （codex-adapter.sh --base develop 等）だけが stale なローカル ref のまま diff を取る。

adapter_base_for() { # <--base に渡す値>
  (
    set -euo pipefail
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    . "$ADAPTER_COMMON"
    # 位置引数 2 つ（perspective ファイル / 出力先）は必須。値は解決に無関係なので
    # 実在しないパスで良い（パーサーは開かない）。
    parse_adapter_args perspective.md output.md --base "$1" >/dev/null 2>&1
    printf '%s\n' "$BASE_BRANCH"
  )
}
ADAPTER_BASE="$(adapter_base_for develop)"
if [ "$ADAPTER_BASE" = "origin/develop" ]; then
  ok "(12) parse_adapter_args --base develop も origin/develop へ解決される"
else
  bad "(12) アダプタ直叩きの --base が解決を通らない: '${ADAPTER_BASE}'"
fi
ADAPTER_BASE="$(adapter_base_for origin/develop)"
if [ "$ADAPTER_BASE" = "origin/develop" ]; then
  ok "(12) 解決済みの値を再度渡しても冪等（二重解決しない）"
else
  bad "(12) origin/develop の再解決で値が変わった: '${ADAPTER_BASE}'"
fi

# ---- (8) 分岐したローカル base は警告に残る ----------------------------------
#
# 解決が origin へ倒さない分岐ケースでは混入がありうる。orchestrator の鮮度警告
# （warn_if_stale_local_base）が実効的に残っていることを、混入件数つきで固定する。
# ここを失うと、自動解決の導入で警告が丸ごと死んでいても誰も気付かない。
#
# 形: origin/develop = C1、feature は C1 から、ローカル develop は C0 + 独自コミット。
# merge-base(local, HEAD)=C0 ≠ merge-base(origin, HEAD)=C1 なので混入 1 件。

git init --bare -q "$TMP/origin-b.git"
git clone -q "$TMP/origin-b.git" "$TMP/work-b" 2>/dev/null
ff_git_fixture_init "$TMP/work-b" "base-ref-freshness-test" "test@example.com"
cd "$TMP/work-b"
git config commit.gpgsign false

git switch -q -c develop
echo c0 > app.txt
git add app.txt
git commit -qm "C0"
git push -qu origin develop
C0_SHA="$(git rev-parse HEAD)"
echo c1 > other.txt
git add other.txt
git commit -qm "C1 other work"
git push -q origin develop

git switch -q -c feature/diverged
echo mine >> app.txt
git add app.txt
git commit -qm "feature change"

git switch -q develop
git reset -q --hard "$C0_SHA"
echo local-only > local-only.txt
git add local-only.txt
git commit -qm "local-only base commit"
git switch -q feature/diverged

DIVERGED_LOG="$TMP/plan-diverged.log"
DIVERGED_RC=0
run_orchestrator "$DIVERGED_LOG" --base develop || DIVERGED_RC=$?
PLAN_OUT="$(cat "$DIVERGED_LOG")"
if [ "$DIVERGED_RC" -ne 0 ]; then
  bad "(8) multi-agent.sh --dry-run が rc=${DIVERGED_RC} で失敗した（分岐時の挙動を検査できていない）"
  tail -5 "$DIVERGED_LOG" | sed 's/^/    | /' >&2
elif ! grep -q 'Base branch:' <<<"$PLAN_OUT"; then
  bad "(8) 実行計画に 'Base branch:' 行が出ていない（分岐時の base を検査できていない）"
  tail -5 "$DIVERGED_LOG" | sed 's/^/    | /' >&2
else
  if grep -q 'Base branch: develop' <<<"$PLAN_OUT"; then
    ok "(8) 分岐時は実行計画もローカル develop を base として名乗る"
  else
    bad "(8) 分岐時に base がローカルでない: $(grep -m1 'Base branch:' <<<"$PLAN_OUT")"
  fi
  if grep -q '他ブランチのマージ済みコミット 1 件が diff に混入します' <<<"$PLAN_OUT"; then
    ok "(8) 分岐時は混入件数つきの鮮度警告が残る"
  else
    bad "(8) 分岐時の鮮度警告が失われた（自動解決の導入で警告が死んでいる）"
  fi
fi

echo ""
echo "  passed: ${PASS} / failed: ${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
