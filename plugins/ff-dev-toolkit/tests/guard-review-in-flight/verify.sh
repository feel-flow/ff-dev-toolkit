#!/usr/bin/env bash
# Runtime contract for the review in-flight / dirty guard hook.
#
# 配布物 hooks/guard-review-in-flight.sh を stdin JSON で直接駆動し、受け入れ条件を
# 固定する。
#   A) 走行中ロック: `.review-results/.review-in-flight` があり PID 生存中は編集系ツールと
#      git 書き込みコマンドを deny / FF_REVIEW_LOCK_OVERRIDE=1 で通る / ロック無しは無音 /
#      stale PID は警告のみ（deny しない）/ 上限より古いロックは PID 生存でも警告のみ /
#      heredoc 本文・別リポジトリの `git -C`・read-only な git は誤爆しない
#   K) Bash 経由の作業ツリー書き込み（Issue `#1710`。判定は tests/lib/review-write-scan.sh）:
#      走行中はリダイレクト / `tee` / `sed -i` / `cp` `mv` `rm` 等 / 書き込みマーカーを含む
#      インタプリタのプログラム（heredoc・-c・script ファイル・`$(…)` の本文・`source`）を deny し、
#      ツリー外（scratchpad / mktemp）・`.review-results/`・読み取り専用の形・ロック無しは無音。
#      書き込み先を判定できない形（変数展開・読めないスクリプト・未終端 heredoc・cd 先不明の
#      相対パス・走査ライブラリ不在）は走行中に限り deny 側。区間分割は引用符・`$(…)` を保ち、
#      単独の `&` で割る。サブシェル・子シェルの `cd` は親へ漏れない。override は区間ごと
#   B) 起動時 dirty: `Agent`（`Task`）+ `subagent_type` が `pr-review-toolkit:` + dirty で
#      permissionDecision "ask" / clean は無音 / gitignore 済み成果物だけなら無音
#   C) サブエージェント経路の走行中レーン: レビュー用サブエージェントの起動ごとに
#      `.review-results/.review-in-flight.d/` へレーンが 1 本開き、生きている間は A と同じ
#      deny が出る / **1 本の SubagentStop では解けず、全レーンが終端して初めて解ける** /
#      解放は `SubagentStart` で書き込んだ `agent_id` で対応づけ、同じ `agent_id` の
#      2 回目以降は no-op / 取得は `tool_use_id` に対して冪等 / isolation=worktree・名簿外の
#      subagent はレーンを取らない / PermissionDenied はレーンをその場で閉じる /
#      上限を過ぎたレーンは走査で自動回収され、**回収したことを必ず出力する** /
#      レーン置き場が symlink のときは何も触らない / レーンの記帳が B の dirty 判定を
#      誤爆させない / 名簿の型で動いているレビュアー自身の編集は deny しない
#   N) 巡回カウンタ（tests/lib/review-round-counter.sh）: 同じブランチで異なる HEAD に対する
#      レビュー起動を巡として数え、上限（既定 2）を超える巡の起動（Agent の名簿型・隔離起動・
#      委譲レビュー / Bash の multi-review.sh・codex-review.sh・multi-agent.sh --task review）を
#      deny してレーンを取らない / 同じ HEAD の起動は同じ巡 / --dry-run・--staged・コマンド位置に
#      無い言及は数えない / 1 回限りの通過口（Bash の区間先頭・Agent の prompt 行頭の
#      FF_REVIEW_ROUND_ACK=1。セッション環境は読まない）/ 記録が無い・読めない・detached HEAD・
#      ライブラリ不在は判定不能 = 通す + 警告 / 残件数は FF_JEV_MODE=on のときだけ畳み込み後を読む /
#      統合ブランチ上は数えない / 記録は git common dir 配下で --fresh の実際の退避を経ても残る /
#      ask の出口では記録しない / 配布文書の起動形（if ! ・行継続・timeout / nice・--task 無し）も数える /
#      multi-agent.sh の review 本体（multi-review.sh 経由・直接起動）も同じ記録で 3 巡目を exit 4 で止める /
#      ask の出口は仮記録して PermissionDenied で取り消す / linked worktree 間で記録を共有する /
#      ライブラリ不在は Bash の起動にも警告する
# あわせて hooks.json への登録を静的照合する。
#
# 変異検出（2026-09-12 実測。変異 → suite 実行 → 復元の 1 検査 1 変異。全 14 件赤）:
#   - acquire_lane の書き出しを no-op にする                      → 赤（(h) の deny / レーン数）
#   - guard の判定から LANE_LIVE を落とす                         → 赤（(h) の deny）
#   - scan_lanes の寿命判定（自動回収）を落とす                   → 赤（(h4)）
#   - B の dirty 判定から出力先の pathspec 除外を落とす           → 赤（(h6)）
#   - 解放を「同型の最も古い 1 本」へ戻す（agent_id 対応づけを外す）→ 赤（(h7)）
#   - フォールバックを対応づけ済みレーンにも広げる                → 赤（(h7)）
#   - 回収時の systemMessage を消す                               → 赤（(h4) / (h11)）
#   - 既定の寿命上限 14400 を 7200 / 28800 へ変える               → 赤（(h11) の境界・両向き）
#   - 未対応づけレーンの短い上限（1800）を外す                    → 赤（(h12)）
#   - acquire_lane の冪等判定を外す                               → 赤（(h8)）
#   - lane_dir_is_safe の symlink / 物理パス判定を外す            → 赤（(h9)）
#   - 解放の rename claim を「選んでから rm」に戻す               → 赤（(h10) 同時終端 4/8 回）
#   - acquire_lane の atomic publish（tmp → rename）を外す         → 赤（(h10) 同時取得）
#   - 名簿一致の呼び出し元の素通しを外す                          → 赤（(h13)）
#
# 変異検出（(h14) 名簿の追随 / (h15) 委譲レビュー経路。2026-09-13 実測）:
#   委譲レビューの識別を無効化 → 3 件赤。委譲レーンを汎用型で記帳する → 1 件赤。
#   委譲プロンプトの実在検査を外す → 1 件赤。出力先の条件を落とす → 1 件赤。
#   行頭アンカーを case と抽出の両方で緩める → 1 件赤。マーカーの綴りを hook 側だけ変える → 6 件赤。
#   agent_id / lane_key の正規化から衝突回避を外す → 各 1 件赤。名簿を 1 本減らす → 1 件赤。
#   名簿の 1 本を同数のまま別名へ差し替える → 1 件赤。除外リストを空にする → 1 件赤。
#   実体 0 件を一致へ倒す → 1 件赤。改行入りファイル名の検査を外す → 1 件赤。
#   名簿分割の glob 抑止を外す → 1 件赤。出力先への書き込み免除を外す → 2 件赤。
#   相対パスの正規化を外す → 1 件赤。免除の錨（このリポジトリの出力先）を緩める → 1 件赤。
#   回収時の委譲レーン解放を無効化 → 1 件赤。同じ解放を全レーンへ広げる → 1 件赤。
#
#   **赤転しなかった変異を 2 つ記録する（どちらも二重防御の片側で、単独では観測できない）**:
#   (1) `SubagentStart` の名簿ゲートを外す → 緑。委譲レーンを専用型で記帳しているので、
#       ゲートを外しても同型フォールバックが掴まない。記帳型そのものを見る針が別に在る。
#   (2) 行頭アンカーを `case` だけ緩める → 緑。抽出（`${line#マーカー: }`）が行頭でない行を
#       弾くので、`case` は前段の絞りにすぎない。両方を緩めると赤になる。
#   二重防御では「片方を外す変異が緑」は検出力の欠如ではない。**どちらの層を観測しているか**を
#   針ごとに決め、どちらでもない層は単独変異で測れないことを記録しておく。
#
# 変異検出（(k) Bash 書き込み走査 = tests/lib/review-write-scan.sh。2026-09-17 実測。ライブラリの
# コピーへ変異 → suite 実行 → 復元。数字は赤になった (k) の針の件数）:
#   ws_scan_code を常に非 hit へ倒す → 96。`.review-results/` の免除を外す → 2。
#   判定不能（resolve 失敗）を素通しへ → 4。インタプリタ本文から heredoc を外す → 8。
#   script ファイルの読み込みを外す → 5。`mv` を移動先だけに → 1。`sed` の `-i` 判定を外す → 2。
#   `cd` 追跡を外す → 4。マーカー `write_text` を消す → 6。マーカー行のリテラル抽出を外す
#   （一致で即 deny）→ 2。単独 `&` の区切りを外す → 1。引用符を無視して区切る → 5。
#   子シェル（bash -c / $(…)）の状態復元を外す → 1。サブシェル `( )` の状態復元を外す → 1。
#   override を区間先頭で確定しない → 2。mktemp テンプレートの配置先を見ない → 1。
#   出力リダイレクト語を引数から除かない → 4。grep 失敗をマーカー無しに畳む → 2。
#   $(…) の本文を走査しない → 3。制御語（do / then）を剥がさない → 2。
#   引用符付きの密着リダイレクト（`>"f"`）を判定しない → 1。最初のマーカーだけで判定する → 2。
#   override 区間で走査を打ち切る → 2。パイプ・条件付き区間の cd を親へ漏らす → 4。
#   background 区間の cd を親へ漏らす → 1。
#   ライブラリ不在 / heredoc ヘルパ不在は変異ではなく直接検査（コピーへ置かない）。
#   lane_dir_is_safe の (h9) は「symlink 検査（-L）」と「物理パス包含（path_within）」の二重で、
#   phys_dir / path_within へ括り出した後も両方を外すと赤（3 件）のまま。
#
#   名簿の崩壊床は件数ではなく**名前の並び**で持つ: (h14) の突き合わせは実体側の fixture を
#   hook の名簿から作るので、名簿が縮んでも差し替わっても fixture が追随して一致する
#   （実測: 件数だけの床では同数の名前置換が緑で通った）。派生させない並びを別に置く。
#   実測で分かった 3 つの取りこぼし:
#   1. 最初の設計では (h2) の 2 本が別々の観点だったため「同型を全部閉じる」への退化が
#      現れなかった。同型 2 本のケースを足して初めて赤になる。
#   2. (h10) の走査側を**回数で打ち切る**と、負荷次第で書き手より先に走り終えて競合が
#      起きず、atomic publish の変異が 3 回中 2 回すり抜けた。走査は書き手が全員終わるまで
#      回し続ける（終了合図はファイル）。
#   3. atomic publish の変異は「最終パスへ追記で書く」形だと**赤にならない** — 走査に
#      消されても後続の `>>` がファイルを作り直し、started_epoch を含む形で復活するため。
#      実装が本当に失う形（走査に消されたら以後の書き込みが落ちる）で模さないと測れない。
#   レーン取得を `git status` の**あと**へ戻す順序変更は (h16) が赤にする。時間ではなく
#   因果で測る — `git status` を解放の合図まで返らないシムにすると、順序が正しければ
#   レーンは status へ入る前に存在し、逆なら status から返れないので永久に現れない。
#   「10 秒かかる status」を再現する形は機械の速さに依存して flaky になり、赤が
#   「またフレーキーか」と読まれて検出力を失う。シムが呼ばれたことも併せて確かめる
#   （呼ばれないまま緑になる形を残さない）。
#
# hook ごとに suite を分ける既存慣行（guard-checkout-restore / guard-pr-followup /
# guard-background-cwd）に合わせて 1 本立てる。
#
# run-all-required: no — jq / git 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。既存の Bash ガード suite と同じ扱い）
# 空振り検出: 検査対象 hooks/guard-review-in-flight.sh を「exit 0 だけ」の空ファイルへ差し替えると (a)〜(m) の 188 件が赤になる（2026-09-18 実測。先頭は (a)「Edit が deny される」。対象の不在・無出力を「発火しないのが正しい」へ倒さないことの実測）。
# 空振り検出: ignored 判定の rc 分岐で 127 を ignored 側へ畳む変異（tests/lib/review-write-scan.sh の `0) return 0` へ `127) return 0` を足す）を入れると (m)「check-ignore を起動できない回は ignored と読まずに deny」と (m)「Bash 経路でも check-ignore 不能なら deny」の 2 件が赤になる（2026-09-18 実測。判定の口が失敗した回を「ignored」へ畳むと許可側へ緩むため、起動不能を deny 側で固定している）。
# 変異検出（(n) 巡回カウンタ。2026-09-24 実測。scripts/mutation-harness.sh で 1 件ずつ作業ツリーの写しへ
# 適用 → 内容ハッシュで適用確認 → 本 suite。15 件すべて赤、誤検知確認 1 件は緑。数字は赤になった針の件数）:
#   lib: deny を pass へ倒す → 20。記録不在の警告を消す → 2。読めない記録を 0 巡として続行 → 2。
#   異なる HEAD でなく行数で数える → 1。prompt 中の ACK を部分一致で拾う → 1。セッション環境の ACK を
#   読む → 2。既定上限 2 を 3 へ → 18。off で畳み込み後の件数を読む → 1。コマンド位置を見ず末尾の語で
#   起動を判定 → 7。--dry-run を数える → 1。
#   hook: 隔離起動を数えない → 赤（記録が作られず (n8) で suite が止まる）。Bash 経路の配線を外す → 6。
#   ask の出口で警告を落とす → 1。無音の出口で警告を落とす（EXIT trap を外す）→ 15。レーン取得の後に
#   判定する → 6。
#   誤検知確認: deny 文の説明句（「<上限> 巡目の fix の後にレビューを重ねない」）を消す → 緑（文面の針は
#   案内の要所 = 巡目・bundle 統合・通過口だけに置いている）。
# 変異検出（(n13)〜(n16)。2026-09-24 実測。scripts/mutation-harness.sh、11 件すべて赤。数字は赤の針の件数）:
#   統合ブランチを除外しない → 2。記録を出力先（.review-in-flight.d/rounds）へ戻す → 赤（(n7) 以降で
#   suite が止まる）。ask の出口で記録する → 1。multi-agent.sh を --task review 明示時だけ数える → 13。
#   timeout / gtimeout を剥がさない → 2。制御の接頭辞を剥がさない → 2。行継続をつながない → 1。
#   --print-toolkit-root を数える → 1。multi-review.sh の巡回検査を外す → 3。multi-review.sh が
#   FF_REVIEW_ROUND_ACK を読まない → 2。
# 変異検出（2 巡目の fix。2026-09-24 実測。scripts/mutation-harness.sh、7 件すべて赤）: ask の出口で仮記録しない
#   → 1。PermissionDenied で仮記録を取り消さない → 1。ライブラリ不在の Bash 起動を無警告にする → 1。
#   multi-agent.sh の review 本体の巡回検査を外す → 4。記録を worktree ごとの git dir へ置く → 1（(n17)）。
#   環境代入を剥がさない → 3。
# 空振り検出: 巡回の記録が無い回を「0 巡」と見なして警告なしで通す変異（記録不在の rr_warn を消す）を入れると (n1) と (n11) の 2 件が赤になる（2026-09-24 実測。記録不在・読めない記録は判定不能 = 通す + 警告で固定し、黙って 0 巡から数えない）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-review-in-flight.sh"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$TARGET" ] || { echo "✗ guard-review-in-flight.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません: $MULTI_AGENT" >&2; exit 1; }
# 巡回カウンタ（(n) 節）の入力をホストの環境から隔離する。(a)〜(m) は巡回上限と直交する契約
# （凍結・dirty・レーン）を測るので上限を 0（無効）へ固定し、(n) だけが区間ごとに外して
# 既定値で測る。有効のままだと、レーンを消すたびに「記録が無い」警告が無音の針へ混ざる。
unset FF_REVIEW_ROUND_ACK FF_JEV_MODE
export FF_REVIEW_ROUND_LIMIT=0
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-review-in-flight は未検査のままです）"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が見つからないためスキップ（guard-review-in-flight は未検査のままです）"
  exit 0
fi

# fixture リポジトリの identity を呼び出し元へ漏らさない
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-rif.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  # 物理パスへ正規化する（macOS の $TMPDIR は /var → /private/var の symlink で、
  # git rev-parse --show-toplevel が返す root と文字列比較できなくなる）
  TEST_TMP="$(cd "$_ff_mktemp_out" && pwd -P)"
else
  echo "○ skip: 一時ディレクトリを作成できません（guard-review-in-flight は未検査のままです）: $_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
# (h16) が背景で起こす hook の PID と、そのシムを解放する合図ファイル。中断
# （SIGINT / SIGTERM / 想定外の set -e 終了）で置き去りにすると、子は消えた合図ファイルを
# 待ち続ける。cleanup から解放 → 短い待ち → kill の順で必ず終わらせる。
SLOW_HOOK_PID=""
SLOW_GIT_RELEASE=""
reap_slow_hook() { # 解放して終わらせる。<期限内に終わったか> を rc で返す
  local w=0
  [ -n "$SLOW_HOOK_PID" ] || return 0
  [ -n "$SLOW_GIT_RELEASE" ] && : > "$SLOW_GIT_RELEASE" 2>/dev/null
  while kill -0 "$SLOW_HOOK_PID" 2>/dev/null && [ "$w" -lt 100 ]; do
    sleep 0.1
    w=$((w + 1))
  done
  if kill -0 "$SLOW_HOOK_PID" 2>/dev/null; then
    kill -TERM "$SLOW_HOOK_PID" 2>/dev/null || true
    wait "$SLOW_HOOK_PID" 2>/dev/null || true
    SLOW_HOOK_PID=""
    return 1
  fi
  SLOW_HOOK_RC=0
  wait "$SLOW_HOOK_PID" 2>/dev/null || SLOW_HOOK_RC=$?
  SLOW_HOOK_PID=""
  return 0
}
SLOW_HOOK_RC=0
cleanup() {
  local rc=$?
  reap_slow_hook >/dev/null 2>&1 || true
  cd /
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-review-in-flight: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

REPO="$TEST_TMP/repo"
ff_git_fixture_init "$REPO" "guard-review-in-flight-test" "test@example.com" \
  || { echo "○ skip: git fixture を作れません（guard-review-in-flight は未検査のままです）"; REACHED_END=1; exit 0; }
git -C "$REPO" config commit.gpgsign false
mkdir -p "$REPO/src"
printf 'base\n' > "$REPO/src/app.txt"
# 出力先の無視は**アンカー付き**（先頭 `/`）で書く。素の `.review-results/` は任意の
# 深さの同名ディレクトリに当たるので、「出力先だから免除された」のか「gitignore 済み
# だから免除された」のかを区別できなくなる（Issue `#1756` で ignored も免除側へ入った）。
# アンカー付きなら `src/.review-results/` は ignored でないツリー内のパスとして残り、
# (h15) の錨の針が成立する。
printf '/.review-results/\nbuild/\ncache/\n' > "$REPO/.gitignore"
# ignore パターン（`build/`）に当たる **tracked** なファイルを 1 つ置く。`git check-ignore`
# が index を見る（= tracked なら「ignored ではない」と答える）ことに (m) の判定が依存して
# いるので、その依存を fixture で持つ。
# `build/` は**丸ごと ignored のまま**にして、tracked な針は別の ignored ディレクトリ
# （`cache/`）へ置く。`build/` の中に tracked を混ぜると `rm -rf build/` が tracked を
# 巻き込む形になり、「ignored なディレクトリごと消す」の許可検査と主題が混ざる。
#
# **`$REPO/build` はディスク上に実在させる（この mkdir が必要）。** `git check-ignore` は
# 素のディレクトリ名を、それが実在するときだけ ignored と答える。この mkdir を落とすと
# `rm -rf build/` の許可検査が黙って deny 側へ倒れる（fixture と検査の結合点）。
mkdir -p "$REPO/build" "$REPO/cache"
printf 'tracked\n' > "$REPO/cache/keep.txt"
git -C "$REPO" add -A
git -C "$REPO" add -f "$REPO/cache/keep.txt"
git -C "$REPO" commit -qm init

LOCK_DIR="$REPO/.review-results"
LOCK="$LOCK_DIR/.review-in-flight"
mkdir -p "$LOCK_DIR"

# 生存 PID として自分自身を使う（kill -0 が必ず通る）。stale 側は「割り当てられて
# いない PID」を探して使う — 固定値だと環境によっては実在してしまう。
LIVE_PID=$$
DEAD_PID=0
for candidate in 99991 99992 99993 65533 65534; do
  if ! kill -0 "$candidate" 2>/dev/null; then
    DEAD_PID="$candidate"
    break
  fi
done
if [ "$DEAD_PID" -eq 0 ]; then
  echo "○ skip: 生存していない PID を確保できません（guard-review-in-flight は未検査のままです）"
  REACHED_END=1
  exit 0
fi

write_lock() { # <pid> [経過秒（既定 42）]
  printf 'pid=%s\ntask=review\nhead=abcdef1234567890\nstarted=2026-09-10T00:00:00Z\nstarted_epoch=%s\nperspectives=code-review,security\n' \
    "$1" "$(($(date -u +%s) - ${2:-42}))" > "$LOCK"
}
clear_lock() { rm -f "$LOCK"; }

# C（サブエージェント経路のレーン）の操作。hook が置く実体をテスト側から直接触るのは
# 「何本残っているか」を数える 1 点だけで、開け閉めは必ず hook 経由で行う。
LANE_DIR="$LOCK_DIR/.review-in-flight.d"
clear_lanes() { rm -rf "$LANE_DIR"; }
lane_count_for_key() { # <鍵（tool_use_id）> このケースが開いたレーンだけを数える
  local n=0
  n="$(ls -1 "$LANE_DIR/$1".*.lane 2>/dev/null | grep -c . 2>/dev/null)" || n=0
  printf '%s' "${n:-0}" | tr -d '[:space:]'
}
lane_count() {
  # grep -c はパイプを最後まで読むので書き手へ SIGPIPE を投げない（run-all の禁止形を避ける）。
  # 0 件のとき grep -c は rc=1 を返すので、set -e / pipefail 下では明示的に受ける。
  local n=0
  n="$(ls -1 "$LANE_DIR"/*.lane 2>/dev/null | grep -c . 2>/dev/null)" || n=0
  printf '%s' "${n:-0}" | tr -d '[:space:]'
}
age_lanes() { # <何秒前に開いたことにするか>
  local f base
  base="$(($(date -u +%s) - $1))"
  for f in "$LANE_DIR"/*.lane; do
    [ -f "$f" ] || continue
    sed "s/^started_epoch=.*/started_epoch=${base}/" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}

OUT=""
RC=0
MESSAGE=""
DECISION=""
REASON=""

run_hook() { # <json> [env "NAME=VALUE [NAME2=VALUE2 ...]"]
  local json="$1" extra_env="${2:-}"
  RC=0
  if [ -n "$extra_env" ]; then
    # shellcheck disable=SC2086 # 空白区切りで複数の環境代入を渡す（値に空白は含めない）
    OUT="$(printf '%s' "$json" | env $extra_env bash "$TARGET" 2>/dev/null)" || RC=$?
  else
    OUT="$(printf '%s' "$json" | bash "$TARGET" 2>/dev/null)" || RC=$?
  fi
  MESSAGE="$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)"
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

edit_json() { jq -n --arg d "$REPO" \
  '{tool_name: "Edit", tool_input: {file_path: "src/app.txt", old_string: "a", new_string: "b"}, cwd: $d, hook_event_name: "PreToolUse"}'; }
bash_json() { jq -n --arg c "$1" --arg d "$REPO" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}'; }
agent_json() { # <subagent_type> [tool_name] [tool_use_id] [isolation]
  jq -n --arg s "$1" --arg d "$REPO" --arg t "${2:-Agent}" --arg u "${3:-}" --arg iso "${4:-}" \
  '{tool_name: $t, tool_input: ({subagent_type: $s, description: "review", prompt: "review the diff"}
      + (if $iso == "" then {} else {isolation: $iso} end)), cwd: $d, hook_event_name: "PreToolUse"}
   + (if $u == "" then {} else {tool_use_id: $u} end)'; }
# 汎用 `subagent_type` + 任意の prompt（委譲レビューの識別を測るため）。
generic_agent_json() { # <prompt> [tool_use_id] [subagent_type]
  jq -n --arg d "$REPO" --arg p "$1" --arg u "${2:-}" --arg s "${3:-general-purpose}" \
  '{tool_name: "Agent", tool_input: {subagent_type: $s, description: "delegated", prompt: $p},
    cwd: $d, hook_event_name: "PreToolUse"}
   + (if $u == "" then {} else {tool_use_id: $u} end)'; }
subagent_start_json() { # <agent_type> [agent_id]
  jq -n --arg d "$REPO" --arg t "$1" --arg a "${2:-agent-1}" \
  '{hook_event_name: "SubagentStart", cwd: $d, agent_id: $a, agent_type: $t}'; }
subagent_stop_json() { # <agent_type> [agent_id]
  jq -n --arg d "$REPO" --arg t "$1" --arg a "${2:-agent-1}" \
  '{hook_event_name: "SubagentStop", cwd: $d, agent_id: $a, agent_type: $t, stop_hook_active: false}'; }
# 呼び出し元（そのツールを実行しているエージェント）の agent_type を載せた Edit。
# PreToolUse の共通部は「これから起動する側」ではなく「呼んでいる側」の id / type を持つ。
edit_json_as() { # <呼び出し元の agent_type>
  jq -n --arg d "$REPO" --arg a "$1" \
  '{tool_name: "Edit", tool_input: {file_path: "src/app.txt", old_string: "a", new_string: "b"},
    cwd: $d, hook_event_name: "PreToolUse", agent_id: "caller-1", agent_type: $a}'; }
permission_denied_json() { jq -n --arg d "$REPO" --arg s "$1" --arg u "$2" \
  '{tool_name: "Agent", tool_use_id: $u, hook_event_name: "PermissionDenied", reason: "user declined", cwd: $d,
    tool_input: {subagent_type: $s, description: "review", prompt: "review the diff"}}'; }

assert_deny() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}
assert_ask() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "ask" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}
assert_silent() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1: exit=$RC out=[$OUT]"; fi
}
assert_warn_only() { # <label>
  if [ "$RC" -eq 0 ] && [ -n "$MESSAGE" ] && [ -z "$DECISION" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}

echo "guard-review-in-flight: (a) ロックあり + PID 生存で編集を止める"
write_lock "$LIVE_PID"
run_hook "$(edit_json)"
assert_deny "(a) Edit が deny される"
case "$REASON" in
  *abcdef1234567890*) ok "(a) 拒否理由が開始 SHA を名指しする" ;;
  *) bad "(a) 拒否理由に開始 SHA が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"経過"*) ok "(a) 拒否理由が経過時間を出す" ;;
  *) bad "(a) 拒否理由に経過時間が無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_REVIEW_LOCK_OVERRIDE*) ok "(a) 拒否理由が解除手段を案内する" ;;
  *) bad "(a) 拒否理由に解除手段が無い: [$REASON]" ;;
esac
# 編集系ツール（Edit / Write）は hook のセッション環境を継承するだけで、環境変数を
# その場で足せない。tool 非依存の復旧手順（ロックの実体を rm する）が先に来ること。
# パスに空白や glob が入りうるので、案内はそのまま貼って実行できる引用形で出す。
case "$REASON" in
  *"rm -- '${LOCK}'"*) ok "(a) 拒否理由が tool 非依存の復旧手順（rm -- '<ロック>'）をクォート付きで出す" ;;
  *) bad "(a) 拒否理由に引用付きの rm <ロック> が無い: [$REASON]" ;;
esac
case "$REASON" in
  *code-review*) ok "(a) 拒否理由が観点一覧を出す" ;;
  *) bad "(a) 拒否理由に観点一覧が無い: [$REASON]" ;;
esac
run_hook "$(bash_json 'git commit -m "wip"')"
assert_deny "(a) Bash の git commit も deny される"
run_hook "$(bash_json 'git switch develop')"
assert_deny "(a) Bash の git switch も deny される"

echo "guard-review-in-flight: 書き込み系でない Bash は素通しする（誤爆させない）"
run_hook "$(bash_json 'git status --porcelain')"
assert_silent "git status は無音"
run_hook "$(bash_json 'npm test')"
assert_silent "git を含まないコマンドは無音"
run_hook "$(bash_json 'echo git commit -m x')"
assert_silent "コマンド位置に無い git（echo git commit）は無音"

echo "guard-review-in-flight: (b) FF_REVIEW_LOCK_OVERRIDE=1 で通る"
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_OVERRIDE=1'
assert_silent "(b) FF_REVIEW_LOCK_OVERRIDE=1 なら deny しない"
run_hook "$(edit_json)" 'FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1'
assert_silent "hook 全体の opt-out でも deny しない"

echo "guard-review-in-flight: (c) ロック無しで通る"
clear_lock
run_hook "$(edit_json)"
assert_silent "(c) ロックが無ければ無音"
run_hook "$(bash_json 'git commit -m "wip"')"
assert_silent "(c) ロックが無ければ git commit も無音"

echo "guard-review-in-flight: (d) stale PID は警告のみ"
write_lock "$DEAD_PID"
run_hook "$(edit_json)"
assert_warn_only "(d) PID が死んでいれば deny せず警告だけを出す"
case "$MESSAGE" in
  *"rm -- '${LOCK}'"*) ok "(d) 警告がロックの実体パスを引用付きで名指しする" ;;
  *) bad "(d) 警告に引用付きのロックのパスが無い: [$MESSAGE]" ;;
esac
clear_lock

echo "guard-review-in-flight: (d2) 上限を超えて古いロックは PID 生存でも警告のみ"
# PID 再利用（走行終了後に同じ PID が別プロセスへ割り当てられる）を、ロックが元から
# 持っている started_epoch で緩和する。既定の上限は 14400 秒。
write_lock "$LIVE_PID" 20000
run_hook "$(edit_json)"
assert_warn_only "(d2) 既定上限（14400 秒）より古いロックは deny せず警告だけを出す"
case "$MESSAGE" in
  *20*) ok "(d2) 警告が経過秒を出す" ;;
  *) bad "(d2) 警告に経過秒が無い: [$MESSAGE]" ;;
esac
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_MAX_AGE_SECONDS=30000'
assert_deny "(d2) 上限を伸ばせば同じロックで deny に戻る（判定材料が経過時間であることの裏取り）"
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_MAX_AGE_SECONDS=not-a-number'
assert_warn_only "(d2) 上限が数値でなければ既定 14400 秒へ倒す"
clear_lock

echo "guard-review-in-flight: (d3) heredoc 本文の git は deny しない"
# メモ書きの出力先はツリー外（(k) がツリー内へのリダイレクトを止めるようになったため）
TEST_OUT="$TEST_TMP/out"
mkdir -p "$TEST_OUT"
write_lock "$LIVE_PID"
run_hook "$(bash_json "$(printf 'cat <<%sEOF%s > %s/notes.md\ngit commit -m x\nEOF\n' "'" "'" "$TEST_OUT")")"
assert_silent "(d3) heredoc 本文の git commit は無音（メモ書きを止めない）"
run_hook "$(bash_json "$(printf 'cat <<-EOF > %s/notes.md\n\tgit commit -m x\nEOF\n' "$TEST_OUT")")"
assert_silent "(d3) <<- 形式の heredoc 本文も無音"
run_hook "$(bash_json "$(printf 'cat <<%sEOF%s > %s/notes.md\ngit commit -m x\nEOF\ngit switch develop\n' "'" "'" "$TEST_OUT")")"
assert_deny "(d3) 終端行のあとに戻ったコマンド位置の git は deny される（本文の読み飛ばしが終端で止まる）"
run_hook "$(bash_json 'git commit -m "$(cat <<<hello)"')"
assert_deny "(d3) here-string（<<<）は heredoc として扱わない"

echo "guard-review-in-flight: (d4) 別リポジトリを指す git -C は対象外"
OTHER_REPO="$TEST_TMP/other"
if ff_git_fixture_init "$OTHER_REPO" "guard-review-in-flight-other" "test@example.com"; then
  git -C "$OTHER_REPO" config commit.gpgsign false
  printf 'x\n' > "$OTHER_REPO/f.txt"
  git -C "$OTHER_REPO" add -A
  git -C "$OTHER_REPO" commit -qm init
  run_hook "$(bash_json "git -C $OTHER_REPO commit -m x")"
  assert_silent "(d4) ロックを持つリポジトリ以外を指す git -C は無音"
  run_hook "$(bash_json "git -C $REPO commit -m x")"
  assert_deny "(d4) 同じリポジトリを指す git -C は従来どおり deny"
  run_hook "$(bash_json 'git -C . commit -m x')"
  assert_deny "(d4) 相対の -C は cwd 基準で解決する"
else
  echo "  ○ skip: 2 つ目の git fixture を作れません（(d4) は未検査）"
fi

echo "guard-review-in-flight: (d5) read-only な git は deny しない"
run_hook "$(bash_json 'git stash list')"
assert_silent "(d5) git stash list は無音"
run_hook "$(bash_json 'git stash show -p')"
assert_silent "(d5) git stash show は無音"
run_hook "$(bash_json 'git stash')"
assert_deny "(d5) 引数無しの git stash（= push）は deny"
run_hook "$(bash_json 'git stash push -- src/app.txt')"
assert_deny "(d5) git stash push は deny"
run_hook "$(bash_json 'git restore --staged src/app.txt')"
assert_silent "(d5) git restore --staged（--worktree なし）は index だけなので無音"
run_hook "$(bash_json 'git restore --staged --worktree src/app.txt')"
assert_deny "(d5) --worktree 併用の restore は deny"
run_hook "$(bash_json 'git restore src/app.txt')"
assert_deny "(d5) 素の git restore は deny"

echo "guard-review-in-flight: (d6) Bash はコマンド先頭の環境代入でも解除できる"
run_hook "$(bash_json 'FF_REVIEW_LOCK_OVERRIDE=1 git commit -m x')"
assert_silent "(d6) 対象 git コマンド先頭の FF_REVIEW_LOCK_OVERRIDE=1 で通る"
run_hook "$(bash_json 'echo FF_REVIEW_LOCK_OVERRIDE=1 && git commit -m x')"
assert_deny "(d6) 別セグメントに現れるだけの解除指定は効かない"
clear_lock

echo "guard-review-in-flight: (e) Agent + pr-review-toolkit + dirty で確認を出す"
printf 'dirty\n' >> "$REPO/src/app.txt"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_ask "(e) dirty なら permissionDecision ask"
case "$REASON" in
  *'git diff <base>...HEAD'*) ok "(e) 理由文に「エージェントは git diff <base>...HEAD を見る」が入る" ;;
  *) bad "(e) 理由文に diff の理由が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"レビュー待ち時間の使い方"*) ok "(e) 理由文が待ち時間の使い方の節を参照する" ;;
  *) bad "(e) 理由文に待ち時間の参照が無い: [$REASON]" ;;
esac
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' 'Task')"
assert_ask "(e) 旧名 Task でも同じ判定になる"
run_hook "$(agent_json 'general-purpose')"
assert_silent "(e) pr-review-toolkit 以外の subagent_type は無音"

echo "guard-review-in-flight: (e2) 走行中なら確認理由の先頭でそれを伝える"
write_lock "$LIVE_PID"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_ask "(e2) 走行中 + dirty でも確認（ask）のまま"
case "$REASON" in
  "⏳ レビュー走行中です"*) ok "(e2) 理由文の先頭行が走行中であることを言う" ;;
  *) bad "(e2) 理由文の先頭が走行中の告知でない: [$REASON]" ;;
esac
case "$REASON" in
  *abcdef1234567890*) ok "(e2) 走行中の告知が開始 SHA を含む" ;;
  *) bad "(e2) 走行中の告知に開始 SHA が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"経過 4"*) ok "(e2) 走行中の告知が経過秒を含む" ;;
  *) bad "(e2) 走行中の告知に経過秒が無い: [$REASON]" ;;
esac
clear_lock
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
case "$REASON" in
  "⏳"*) bad "(e2) ロックもレーンも無いのに走行中の告知が出た: [$REASON]" ;;
  *) ok "(e2) ロックもレーンも無ければ走行中の告知は出ない" ;;
esac

echo "guard-review-in-flight: (f) clean なら無警告"
clear_lanes
git -C "$REPO" checkout -- src/app.txt
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_silent "(f) clean な作業ツリーでは無音"

echo "guard-review-in-flight: (g) gitignore 済み成果物だけなら発火しない"
clear_lanes
mkdir -p "$REPO/build"
printf 'artifact\n' > "$REPO/build/out.txt"
printf 'leftover\n' > "$LOCK_DIR/stale-report.md"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_silent "(g) gitignore 済みの成果物だけでは無音（判定は git status --porcelain の出力有無）"
rm -f "$LOCK_DIR/stale-report.md"

echo "guard-review-in-flight: fail-open"
clear_lanes
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "壊れた stdin JSON は無出力 exit 0"; else bad "壊れた stdin: exit=$RC out=[$OUT]"; fi
RC=0
OUT="$(printf '' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "空の stdin も無出力 exit 0"; else bad "空の stdin: exit=$RC out=[$OUT]"; fi
write_lock "$LIVE_PID"
run_hook "$(jq -n --arg d "$TEST_TMP" '{tool_name: "Edit", tool_input: {file_path: "x"}, cwd: $d, hook_event_name: "PreToolUse"}')"
assert_silent "git リポジトリ外は無音（fail-open）"
printf 'pid=not-a-number\n' > "$LOCK"
run_hook "$(edit_json)"
assert_silent "PID を読めないロックは無音（fail-open）"
# PATH が空・壊れた環境で stdin を drain しないと書き手が EPIPE / SIGPIPE を受ける。
# payload をパイプバッファ（64 KiB）より大きくして、どの OS でも決定的に赤にする。
BIG_PAYLOAD="$(edit_json)$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "jq が PATH に無い環境は stdin を読み切ったうえで無出力 exit 0（書き手に EPIPE を返さない）"
else
  bad "jq 不在: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
clear_lock

echo "guard-review-in-flight: (h) ホストのサブエージェント経路でもレーンで止まる"
# A のロックは multi-agent.sh が走っている間しか置かれないので、ホストのサブエージェントで
# レビューする経路では 1 度も発火しなかった（実測での再発元）。ここはその経路の固定。
clear_lock
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-1)"
assert_silent "(h) clean な作業ツリーでのレビュー起動は無音のまま（レーン取得は出力契約を変えない）"
run_hook "$(agent_json 'pr-review-toolkit:silent-failure-hunter' Agent tu-2)"
assert_silent "(h) 2 本目の起動も無音"
LANES="$(lane_count)"
if [ "$LANES" = "2" ]; then
  ok "(h) 起動 2 本ぶんのレーンが開く"
else
  bad "(h) レーン数が 2 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_deny "(h) レーンが生きている間は Edit が deny される（orchestrator のロックが無い経路でも止まる）"
case "$REASON" in
  *"一部のレビュアーが返ってきただけでは凍結は解けません"*) ok "(h) 拒否理由が「部分完了は解除ではない」を言う" ;;
  *) bad "(h) 拒否理由に部分完了の説明が無い: [$REASON]" ;;
esac
case "$REASON" in
  *pr-review-toolkit:silent-failure-hunter*) ok "(h) 拒否理由が未終端のレビュアー名を挙げる" ;;
  *) bad "(h) 拒否理由に未終端のレビュアー名が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"rm -rf -- '${LANE_DIR}'"*) ok "(h) 拒否理由がレーンの回収手順（実パス）をクォート付きで出す" ;;
  *) bad "(h) 拒否理由にレーンの回収手順が無い: [$REASON]" ;;
esac
run_hook "$(bash_json 'git commit -m "wip"')"
assert_deny "(h) Bash の git commit もレーンで deny される"
run_hook "$(bash_json 'git status --porcelain')"
assert_silent "(h) read-only な git はレーンがあっても無音（既存の線引きを変えない）"
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_OVERRIDE=1'
assert_silent "(h) FF_REVIEW_LOCK_OVERRIDE=1 はレーンにも効く（抜け道が 1 組で済む）"
run_hook "$(edit_json)" 'FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1'
assert_silent "(h) hook 全体の opt-out もレーンに効く"

echo "guard-review-in-flight: (h2) 一部のレビュアーの終端では凍結が解けない"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-h2a)"
assert_silent "(h2) SubagentStop は permissionDecision を出さない（解放専用の入口）"
LANES="$(lane_count)"
if [ "$LANES" = "1" ]; then
  ok "(h2) 終端した 1 本ぶんだけレーンが閉じる"
else
  bad "(h2) 1 本終端後のレーン数が 1 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_deny "(h2) レーンが 1 本でも残っていれば Edit は deny のまま（機械的判定で守る本体）"
run_hook "$(subagent_stop_json 'pr-review-toolkit:silent-failure-hunter' agent-h2b)"
LANES="$(lane_count)"
if [ "$LANES" = "0" ]; then
  ok "(h2) 全レーンが終端するとレーンが空になる"
else
  bad "(h2) 全終端後のレーン数が 0 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_silent "(h2) 全レーン終端後の Edit は通る"
run_hook "$(subagent_stop_json 'general-purpose' agent-h2c)"
assert_silent "(h2) 名簿外の SubagentStop は無音（レーンを持たないので閉じるものが無い）"

# 同型が 2 本走っている形は、観点名でしか照合できない SubagentStop の解放が
# 「同型を全部閉じる」に退化していないかを測る唯一のケース（観点が全部違うと退化が見えない）。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-2a)"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-2b)"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-h2d)"
LANES="$(lane_count)"
if [ "$LANES" = "1" ]; then
  ok "(h2) 同型が 2 本のときも 1 終端で閉じるのは 1 本だけ（解放は必ずレーン単位）"
else
  bad "(h2) 同型 2 本で 1 終端した後のレーン数が 1 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_deny "(h2) 同型の残り 1 本でも Edit は deny のまま"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-h2e)"
LANES="$(lane_count)"
if [ "$LANES" = "0" ]; then
  ok "(h2) 同型 2 本目の終端でレーンが空になる"
else
  bad "(h2) 同型 2 本を終端した後のレーン数が 0 でない: [$LANES]"
fi
run_hook "$(edit_json)"
assert_silent "(h2) 同型 2 本がすべて終端したら Edit は通る"

echo "guard-review-in-flight: (h3) レーンを取らない起動"
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-3 worktree)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h3) isolation=worktree の隔離起動はレーンを取らない（親と作業ツリーを共有しないため凍結の対象外）"
else
  bad "(h3) 隔離起動でレーンが開いた: [$(lane_count)]"
fi
run_hook "$(agent_json 'general-purpose' Agent tu-4)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h3) レビュー以外の subagent はレーンを取らない"
else
  bad "(h3) 非レビュー subagent でレーンが開いた: [$(lane_count)]"
fi
run_hook "$(agent_json 'pr-review-toolkit:code-simplifier' Agent tu-5)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h3) 共有ツリーを編集する code-simplifier は名簿外（自分のロックで自分の編集を止めない）"
else
  bad "(h3) code-simplifier でレーンが開いた: [$(lane_count)]"
fi
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-6)" 'FF_REVIEW_SUBAGENT_LOCK_TYPES=not-a-reviewer:*'
if [ "$(lane_count)" = "0" ]; then
  ok "(h3) 名簿（FF_REVIEW_SUBAGENT_LOCK_TYPES）を差し替えれば対象から外れる"
else
  bad "(h3) 名簿を差し替えてもレーンが開いた: [$(lane_count)]"
fi

echo "guard-review-in-flight: (h4) 取りこぼしたレーンは寿命で自動回収され、回収は必ず通知される"
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-7)"
age_lanes 99999
run_hook "$(edit_json)"
# **無出力で通してはいけない**: 回収は「誰にも知らせずに凍結が解ける」ことなので、
# A の stale ロック（警告のみで通す）と同じ形へ揃える。
assert_warn_only "(h4) 上限より古いレーンは deny しないが、回収したことを systemMessage で出す"
case "$MESSAGE" in
  *"回収しました"*) ok "(h4) 通知が回収した事実を言う" ;;
  *) bad "(h4) 通知に回収の記述が無い: [$MESSAGE]" ;;
esac
case "$MESSAGE" in
  *"$LANE_DIR"*) ok "(h4) 通知がレーン置き場の実パスを名指しする" ;;
  *) bad "(h4) 通知にレーン置き場が無い: [$MESSAGE]" ;;
esac
if [ "$(lane_count)" = "0" ]; then
  ok "(h4) 走査のたびに古いレーンが削除される（解放イベントを取りこぼしても自力で開く）"
else
  bad "(h4) 古いレーンが回収されない: [$(lane_count)]"
fi
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-8)"
age_lanes 5000
run_hook "$(edit_json)" 'FF_REVIEW_SUBAGENT_LOCK_MAX_AGE_SECONDS=100000 FF_REVIEW_SUBAGENT_LOCK_PENDING_SECONDS=100000'
assert_deny "(h4) 上限を伸ばせば同じ古さのレーンで deny に戻る（判定材料が経過時間であることの裏取り）"
clear_lanes

echo "guard-review-in-flight: (h5) 起動しなかったレーンは PermissionDenied で閉じる"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-9)"
run_hook "$(permission_denied_json 'pr-review-toolkit:code-reviewer' tu-9)"
assert_silent "(h5) PermissionDenied は permissionDecision を出さない"
if [ "$(lane_count)" = "0" ]; then
  ok "(h5) 確認を断った起動のレーンはその場で閉じる（ask を断った直後の commit を止めない）"
else
  bad "(h5) PermissionDenied でレーンが閉じない: [$(lane_count)]"
fi
clear_lanes

echo "guard-review-in-flight: (h6) レーンの記帳が dirty ガードを誤爆させない"
# 利用者のリポジトリがレビュー出力先を gitignore しているとは限らない。除外しないと
# hook 自身が置いたレーンで `git status --porcelain` が dirty になり、以後のレビュー起動が
# 毎回 ask になる（自分の記帳で自分のガードを誤爆させる形）。
NOIGN_REPO="$TEST_TMP/noignore"
if ff_git_fixture_init "$NOIGN_REPO" "guard-review-in-flight-noignore" "test@example.com"; then
  git -C "$NOIGN_REPO" config commit.gpgsign false
  printf 'base\n' > "$NOIGN_REPO/app.txt"
  git -C "$NOIGN_REPO" add -A
  git -C "$NOIGN_REPO" commit -qm init
  NOIGN_JSON="$(jq -n --arg d "$NOIGN_REPO" \
    '{tool_name: "Agent", tool_use_id: "tu-n1", tool_input: {subagent_type: "pr-review-toolkit:code-reviewer", description: "review", prompt: "review the diff"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook "$NOIGN_JSON"
  assert_silent "(h6) 1 本目の起動は無音（出力先は未作成）"
  NOIGN_JSON2="$(jq -n --arg d "$NOIGN_REPO" \
    '{tool_name: "Agent", tool_use_id: "tu-n2", tool_input: {subagent_type: "pr-review-toolkit:silent-failure-hunter", description: "review", prompt: "review the diff"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook "$NOIGN_JSON2"
  assert_silent "(h6) 出力先を gitignore していないリポジトリでも、レーンの記帳では ask にならない"
else
  echo "  ○ skip: gitignore 無しの git fixture を作れません（(h6) は未検査）"
fi

echo "guard-review-in-flight: (h7) 解放は agent_id で対応づける"
# SubagentStop はサブエージェントが 1 回応答を終えるたびに発火する（SendMessage で継続
# されたレビュアーは 1 本で複数回出す）。解放が「同型の最も古い 1 本」だと、多ターンの
# レビュアー 1 本が、まだ走っている別のレビュアーのレーンまで削る。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-a1)"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-a2)"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-A)"
assert_silent "(h7) SubagentStart は permissionDecision を出さない（対応づけ専用の入口）"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-B)"
if [ "$(lane_count)" = "2" ]; then
  ok "(h7) 対応づけはレーンを消さない（本数は変わらない）"
else
  bad "(h7) 対応づけ後のレーン数が 2 でない: [$(lane_count)]"
fi
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-ZZ)"
if [ "$(lane_count)" = "2" ]; then
  ok "(h7) 対応づいていない agent_id の終端は、対応づけ済みのレーンを奪わない"
else
  bad "(h7) 見知らぬ agent_id の終端でレーンが減った: [$(lane_count)]"
fi
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-A)"
if [ "$(lane_count)" = "1" ]; then
  ok "(h7) agent_id が一致するレーンだけが閉じる"
else
  bad "(h7) agent-A の終端後のレーン数が 1 でない: [$(lane_count)]"
fi
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-A)"
if [ "$(lane_count)" = "1" ]; then
  ok "(h7) 同じ agent_id の 2 回目の終端は no-op（多ターンのレビュアーが他人のレーンを削らない）"
else
  bad "(h7) 2 回目の SubagentStop でレーンが減った: [$(lane_count)]"
fi
run_hook "$(edit_json)"
assert_deny "(h7) 残っている agent-B のレーンで Edit は deny のまま"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-B)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h7) 対応づいた全レーンが終端するとレーンが空になる"
else
  bad "(h7) agent-B の終端後のレーン数が 0 でない: [$(lane_count)]"
fi

echo "guard-review-in-flight: (h8) 取得は tool_use_id に対して冪等"
# ハーネスには同じ tool_use_id で PreToolUse をもう一度流す再試行経路がある
# （auto mode の拒否に対して hook が retry: true を返す形）。冪等でないと 1 回の起動で
# 2 本開き、解放イベント 1 回では 1 本しか閉じない。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-dup)"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-dup)"
if [ "$(lane_count)" = "1" ]; then
  ok "(h8) 同じ tool_use_id の PreToolUse が 2 回来てもレーンは 1 本"
else
  bad "(h8) 同じ tool_use_id で複数のレーンが開いた: [$(lane_count)]"
fi
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-dup)"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' agent-dup)"
if [ "$(lane_count)" = "0" ]; then
  ok "(h8) 1 回の終端で閉じ切る（再試行ぶんが凍結として残らない）"
else
  bad "(h8) 再試行ぶんのレーンが残った: [$(lane_count)]"
fi
clear_lanes

echo "guard-review-in-flight: (h9) レーン置き場が symlink なら何も触らない"
# 走査は上限を超えたレーンを削除するので、置き場が外部を指す symlink だとリポジトリ外の
# ファイルを消しうる。symlink・ROOT 外の物理パスでは取得・走査・解放をすべて行わない。
LINK_REPO="$TEST_TMP/linkrepo"
OUTSIDE="$TEST_TMP/outside"
if ff_git_fixture_init "$LINK_REPO" "guard-review-in-flight-link" "test@example.com"; then
  git -C "$LINK_REPO" config commit.gpgsign false
  printf 'base
' > "$LINK_REPO/app.txt"
  git -C "$LINK_REPO" add -A
  git -C "$LINK_REPO" commit -qm init
  mkdir -p "$OUTSIDE/.review-in-flight.d"
  printf 'writer_pid=1
task=subagent-review
head=x
started=x
started_epoch=1
perspectives=pr-review-toolkit:code-reviewer
agent_id=
'     > "$OUTSIDE/.review-in-flight.d/foreign.lane"
  ln -s "$OUTSIDE" "$LINK_REPO/.review-results"
  LINK_EDIT="$(jq -n --arg d "$LINK_REPO"     '{tool_name: "Edit", tool_input: {file_path: "app.txt", old_string: "a", new_string: "b"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook "$LINK_EDIT"
  assert_silent "(h9) symlink 越しのレーン置き場では deny も警告も出さない（素通し）"
  if [ -f "$OUTSIDE/.review-in-flight.d/foreign.lane" ]; then
    ok "(h9) リポジトリ外の *.lane を削除しない（走査対象にしない）"
  else
    bad "(h9) リポジトリ外の *.lane が削除された"
  fi
  LINK_AGENT="$(jq -n --arg d "$LINK_REPO"     '{tool_name: "Agent", tool_use_id: "tu-link", tool_input: {subagent_type: "pr-review-toolkit:code-reviewer", description: "review", prompt: "review"}, cwd: $d, hook_event_name: "PreToolUse"}')"
  run_hook "$LINK_AGENT"
  LINK_NEW=0
  for f in "$OUTSIDE/.review-in-flight.d"/tu-link.*.lane; do
    [ -f "$f" ] && LINK_NEW=$((LINK_NEW + 1))
  done
  if [ "$LINK_NEW" -eq 0 ]; then
    ok "(h9) symlink 越しの置き場へレーンを書き込まない"
  else
    bad "(h9) symlink 越しの置き場へレーンが書かれた"
  fi
else
  echo "  ○ skip: symlink 検査用の git fixture を作れません（(h9) は未検査）"
fi

echo "guard-review-in-flight: (h10) 同時実行（取得と走査 / 同型の同時終端）"
# 逐次実行だけでは、書込み途中のレーンが走査に消される形も、同型 2 本の同時終端で
# 1 本しか閉じない形も現れない。同期点（バリアファイル）で本当に競合させる。
BARRIER="$TEST_TMP/barrier"
spawn_hook() { # <json>
  (
    while [ ! -f "$BARRIER" ]; do sleep 0.02; done
    printf '%s' "$1" | bash "$TARGET" >/dev/null 2>&1
  ) &
}
# 走査側は**書き手が全員終わるまで回し続ける**。回数で打ち切ると、負荷次第で走査が
# 先に終わり「書込み途中のレーンを消す」退化（最終パスへ直接書く形）が現れない回が出る
# （回数版で実測。3 回中 2 回すり抜けた）。終了合図はファイルで渡す。
CONC_DONE="$TEST_TMP/conc-done"
spawn_scan_loop() {
  (
    while [ ! -f "$BARRIER" ]; do sleep 0.02; done
    k=1
    while [ ! -f "$CONC_DONE" ] && [ "$k" -le 500 ]; do
      printf '%s' "$CONC_EDIT" | bash "$TARGET" >/dev/null 2>&1
      k=$((k + 1))
    done
  ) &
}
spawn_hook_delayed() { # <json>
  (
    while [ ! -f "$BARRIER" ]; do sleep 0.02; done
    sleep 0.1
    printf '%s' "$1" | bash "$TARGET" >/dev/null 2>&1
  ) &
}
clear_lanes
rm -f "$BARRIER" "$CONC_DONE"
CONC_EDIT="$(edit_json)"
WRITER_PIDS=""
i=1
while [ "$i" -le 6 ]; do
  spawn_hook_delayed "$(agent_json 'pr-review-toolkit:code-reviewer' Agent "tu-p$i")"
  WRITER_PIDS="$WRITER_PIDS $!"
  i=$((i + 1))
done
i=1
while [ "$i" -le 3 ]; do
  spawn_scan_loop
  i=$((i + 1))
done
: > "$BARRIER"
for wpid in $WRITER_PIDS; do
  wait "$wpid" || true
done
: > "$CONC_DONE"
wait || true
rm -f "$CONC_DONE"
if [ "$(lane_count)" = "6" ]; then
  ok "(h10) 同時取得 6 本が、並行する走査に消されずに 6 本残る（書込み途中を公開しない）"
else
  bad "(h10) 同時取得後のレーン数が 6 でない: [$(lane_count)]"
fi
BROKEN=0
for f in "$LANE_DIR"/*.lane; do
  [ -f "$f" ] || continue
  # grep -q はパイプ入力を早期終了して書き手へ SIGPIPE を投げる（run-all の再混入ガードが
  # 禁じている形）。値を変数へ取ってから case で照合する。
  LANE_E="$(sed -n 's/^started_epoch=//p' "$f" | head -n 1)"
  case "$LANE_E" in
    '' | *[!0-9]*) BROKEN=$((BROKEN + 1)) ;;
  esac
done
if [ "$BROKEN" -eq 0 ]; then
  ok "(h10) 残ったレーンはすべて started_epoch を持つ（部分書込みが公開されていない）"
else
  bad "(h10) 壊れたレーンが ${BROKEN} 本ある"
fi
CONC_FAIL=0
round=1
while [ "$round" -le 8 ]; do
  clear_lanes
  run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent "tu-s${round}a")"
  run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent "tu-s${round}b")"
  rm -f "$BARRIER"
  spawn_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' "agent-s${round}a")"
  spawn_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' "agent-s${round}b")"
  : > "$BARRIER"
  wait || true
  [ "$(lane_count)" = "0" ] || CONC_FAIL=$((CONC_FAIL + 1))
  round=$((round + 1))
done
if [ "$CONC_FAIL" -eq 0 ]; then
  ok "(h10) 同型 2 本の同時終端で、8 回とも 2 本とも閉じる（選択→削除が排他化されている）"
else
  bad "(h10) 同型の同時終端で閉じ残りが ${CONC_FAIL}/8 回出た（選択→削除が競合している）"
fi
rm -f "$BARRIER"
clear_lanes

echo "guard-review-in-flight: (h11) 既定の寿命上限の境界"
# 上限を env で上書きした検査だけだと、既定値を別の値へ変異させても緑のままになる。
# ±5 秒は run_hook 1 回ぶんの実行ジッタぶんの余裕（1 秒刻みの epoch を使うため）。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-b1)"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-b1)"
age_lanes 14395
run_hook "$(edit_json)"
assert_deny "(h11) 既定上限（14400 秒）の手前は deny のまま"
age_lanes 14405
run_hook "$(edit_json)"
assert_warn_only "(h11) 既定上限を超えたら回収して通す（通知つき）"
if [ "$(lane_count)" = "0" ]; then
  ok "(h11) 上限超過のレーンは回収される"
else
  bad "(h11) 上限超過のレーンが残った: [$(lane_count)]"
fi

echo "guard-review-in-flight: (h12) 対応づいていないレーンは短い上限で回収する"
# PermissionDenied は auto mode の拒否でしか発火しない（手で断った起動には解放イベントが
# 1 つも来ない）。対応づかないレーンを短い上限で回収することがその受け皿。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-p1)"
age_lanes 1795
run_hook "$(edit_json)"
assert_deny "(h12) 未対応づけレーンも既定 1800 秒の手前は deny"
age_lanes 1805
run_hook "$(edit_json)"
assert_warn_only "(h12) 起動が手で拒否されたレーン（対応づかない）は 1800 秒で回収される"
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-p2)"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' agent-p2)"
age_lanes 1805
run_hook "$(edit_json)"
assert_deny "(h12) 対応づいたレーンは 1800 秒では回収されない（2 つの上限が別物であることの裏取り）"
clear_lanes

echo "guard-review-in-flight: (h13) レビュアー自身の編集は自分のレーンで止めない"
# 名簿の型はハーネス上「全ツール」を持ち、編集系の判定にパス条件が無い。除外が無いと
# レビュアーの一時ファイル書き出しが自分の起動で開いたレーンに deny され、しかも拒否理由が
# レーン置き場の rm を案内する（凍結の抜け道を凍結の対象者へ渡す形）。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-r1)"
run_hook "$(edit_json_as 'pr-review-toolkit:code-reviewer')"
assert_silent "(h13) 名簿の型で動いているレビュアー自身の Edit は deny しない"
run_hook "$(edit_json_as 'general-purpose')"
assert_deny "(h13) 名簿外の呼び出し元（ホスト本体）は従来どおり deny"
clear_lanes

echo "guard-review-in-flight: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher | test("Agent")) | .hooks[]
    | select(.command | contains("guard-review-in-flight.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse に guard-review-in-flight.sh が登録されている"
else
  bad "hooks.json の PreToolUse に guard-review-in-flight.sh が無い"
fi
for m in Edit Write MultiEdit NotebookEdit Bash Agent Task; do
  if jq -e --arg m "$m" '.hooks.PreToolUse[] | select(.hooks[]? | .command | contains("guard-review-in-flight.sh")) | select(.matcher | test($m))' "$HOOKS_JSON" >/dev/null 2>&1; then
    ok "matcher が $m を含む"
  else
    bad "matcher に $m が無い"
  fi
done
if jq -e '.description | test("review-in-flight")' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の description が走行中ロックに言及する"
else
  bad "hooks.json の description に走行中ロックの記述が無い"
fi
# レーンを閉じる入口が登録されていないと、取得だけが効いて凍結が寿命まで解けない。
for ev in SubagentStart SubagentStop PermissionDenied; do
  if jq -e --arg ev "$ev" '.hooks[$ev][]?.hooks[]? | select(.command | contains("guard-review-in-flight.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    ok "hooks.json の $ev に guard-review-in-flight.sh が登録されている（レーンの解放経路）"
  else
    bad "hooks.json の $ev に guard-review-in-flight.sh が無い（レーンが閉じられない）"
  fi
done

echo "guard-review-in-flight: orchestrator 側の契約（ロックの書き出しと必ずの削除）"
if grep -q 'write_run_in_flight' "$MULTI_AGENT" && grep -q 'remove_run_in_flight' "$MULTI_AGENT"; then
  ok "multi-agent.sh がロックの書き出しと削除を持つ"
else
  bad "multi-agent.sh に write_run_in_flight / remove_run_in_flight が無い"
fi
# grep -q はパイプ入力を早期終了するので書き手へ SIGPIPE が飛ぶ（run-all の
# 再混入ガードが禁じている形）。抜き出した本文を変数へ入れてから照合する。
EXIT_TRAP_BODY="$(awk '/^output_lock_exit\(\)/,/^}/' "$MULTI_AGENT")"
case "$EXIT_TRAP_BODY" in
  *remove_run_in_flight*) EXIT_TRAP_CALLS_REMOVE=1 ;;
  *) EXIT_TRAP_CALLS_REMOVE=0 ;;
esac
if [ "$EXIT_TRAP_CALLS_REMOVE" -eq 1 ]; then
  ok "削除が EXIT trap（output_lock_exit）から呼ばれる（3 経路すべてを 1 箇所で締める）"
else
  bad "output_lock_exit が remove_run_in_flight を呼んでいない"
fi

echo "guard-review-in-flight: ASDD ゲートの早期終了経路でも stdin を読み切る"
# 任意 Hook を止めるゲート（hooks/asdd-hook-gate.sh）は stdin を消費しない設計なので、
# 前置きが drain より前にあると「読まずに exit 0」する経路ができ、書き手がその場で
# EPIPE / SIGPIPE を受ける。ゲートが停止する 2 経路を fixture で作って固定する。
ASDD_ON="$TEST_TMP/asdd-hooks-on"
ASDD_OFF="$TEST_TMP/asdd-hooks-off"
mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true
ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload '{"tool_name":"Bash","tool_input":{"command":"echo ok"},"cwd":"/tmp","hook_event_name":"PreToolUse"}')"
ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok ".asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
else
  bad "ASDD ゲート（node 不在）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_OFF"
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "ASDD ゲート（feature 無効）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
  fi
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-review-in-flight の ASDD ゲート無効判定）"
fi

# ── (h16) レーン取得は `git status` より前 ─────────────────────────────────────
# この hook の登録 timeout は 10 秒で、`git status` は大きい・遅いリポジトリでそれを
# 使い切りうる。取得より先に status を読むと、timeout した回はレーンを 1 本も作らないまま
# レビューが起動する（ガードが最初から居ない）。
#
# **時間ではなく因果で測る。** 「10 秒かかる status」を再現しようとすると、機械の速さに
# 結果が依存して flaky になり、赤が「またフレーキーか」と読まれて検出力を失う。そこで
# `git status` を**進めなくする**（解放の合図が来るまで返らないシム）。順序が正しければ
# レーンは status へ入る前に存在し、順序が逆なら status から返れないので永久に現れない。
# 判定は「止まっている間にレーンが在るか」の 1 点で、**順序の判定を固定の待ち時間へ
# 依存させない**（プロセスの起動と取得到達には依存するので、そこには上限つきの生存確認を
# 置く。極端な CPU starvation では正しい実装でも赤になりうるが、その回は上限超過として
# 診断が出る）。
SLOW_GIT_DIR="$TEST_TMP/slow-git"
SLOW_GIT_ENTERED="$TEST_TMP/slow-git-entered"
SLOW_GIT_RELEASE="$TEST_TMP/slow-git-release"
mkdir -p "$SLOW_GIT_DIR"
_real_git="$(command -v git)"
if [ -z "$_real_git" ]; then
  bad "(h16) git の実体を解決できない（シムを作れない）"
else
  cat > "$SLOW_GIT_DIR/git" <<SHIM
#!/usr/bin/env bash
# status だけを解放の合図まで止める。他のサブコマンド（rev-parse 等）はそのまま通す。
for _a in "\$@"; do
  if [ "\$_a" = "status" ]; then
    : > "$SLOW_GIT_ENTERED"
    while [ ! -f "$SLOW_GIT_RELEASE" ]; do sleep 0.05; done
    break
  fi
done
exec "$_real_git" "\$@"
SHIM
  chmod +x "$SLOW_GIT_DIR/git"
  clear_lanes
  rm -f "$SLOW_GIT_ENTERED" "$SLOW_GIT_RELEASE"
  # 観測は**このケースが開いたレーン**（鍵 tu-slow）だけに限る。全レーンを数えると、
  # 取りこぼした別プロセスが後から書いた 1 本で緑になりうる。開始前に 0 本であることも
  # 確かめる（前のケースの残りを自分の成果と読まない）。
  if [ "$(lane_count_for_key tu-slow)" -ne 0 ] || [ "$(lane_count)" -ne 0 ]; then
    bad "(h16) 開始前にレーンが残っている（前のケースの残りを観測しうる）: [$(lane_count)]"
  fi
  ( PATH="$SLOW_GIT_DIR:$PATH" bash "$TARGET" >/dev/null 2>&1 <<HOOKIN
$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-slow)
HOOKIN
  ) &
  SLOW_HOOK_PID=$!
  # レーンが現れるまで待つ（上限つき）。正しい順序なら status へ入る前に現れるので
  # 実測は 1〜数回目の待機で終わる。上限は「現れない」を有限時間で結論するためだけの
  # もので、判定には使わない（レーンの有無だけで決める）。
  _waited=0
  while [ "$(lane_count_for_key tu-slow)" -eq 0 ] && [ "$_waited" -lt 100 ]; do
    sleep 0.1
    _waited=$((_waited + 1))
  done
  _lane_seen="$(lane_count_for_key tu-slow)"
  # 解放して hook を終わらせる。**期限つき**で刈り取る — 無期限の wait だと、解放後に
  # hook や git が固まった回に suite 自体が止まる（止まった suite は赤も緑も出さない）。
  _reap_ok=0
  reap_slow_hook || _reap_ok=1
  if [ ! -f "$SLOW_GIT_ENTERED" ]; then
    # シムが一度も呼ばれていない = この検査は何も測っていない（vacuous green を防ぐ）
    bad "(h16) 遅い git status のシムが呼ばれていない（検査が成立していない）"
  elif [ "$_reap_ok" -ne 0 ]; then
    bad "(h16) 解放後も hook が期限内に終わらなかった（固まっている）"
  elif [ "$SLOW_HOOK_RC" -ne 0 ]; then
    bad "(h16) hook が非 0 で終了した (rc=${SLOW_HOOK_RC})"
  elif [ "$_lane_seen" -eq 1 ]; then
    ok "(h16) git status が返らない間にレーンが存在する（取得が status より前）"
  else
    bad "(h16) git status が止まっている間にレーンが 1 本も無い（取得が status より後へ戻った）: [${_lane_seen}]"
  fi
  clear_lanes
  rm -f "$SLOW_GIT_ENTERED" "$SLOW_GIT_RELEASE"
fi

# ── (h15) 委譲レビュー（--delegate-to-host）経路のレーン ───────────────────────
# オーケストレータは rc=3 で終了し、ホストが**汎用の subagent_type** で自分のセッション
# へレビューを流す。名簿には載らないので、識別は「何の型で起動したか」ではなく
# 「何を渡されたか」で行う。prompt は自由文字列なので、識別は
#   (a) 行頭 `FF-REVIEW-DELEGATED: <パス>` / (b) パスが出力先の .delegated/ 配下 /
#   (c) そのパスが実在する通常ファイル
# の 3 つをすべて要求する。1 つでも緩めると、レビュー以外の委譲が最大 30 分凍結される。
DELEG_DIR="$REPO/.review-results/claude-code/.delegated"
mkdir -p "$DELEG_DIR"
printf '%s\n' '# delegated review prompt' > "$DELEG_DIR/code-review.prompt.md"
DELEG_MARK="FF-REVIEW-DELEGATED: $DELEG_DIR/code-review.prompt.md"

clear_lanes
run_hook "$(generic_agent_json "$DELEG_MARK")"
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) 委譲レビュー（行頭マーカー + 実在する委譲プロンプト）の汎用 Agent はレーンを取る"
else
  bad "(h15) 委譲レビューの起動でレーンが開かない: [$(lane_count)]"
fi

# レーンの**記帳型**を直接見る。汎用の subagent_type をそのまま書くと、同型フォールバック
# （同じ agent_type で対応づいていない最古のレーンを引き受ける）に拾われる。名簿ゲートと
# 二重防御になっているので、片方を外す変異は他方が受け止めてしまう — 記帳型そのものを
# 観測するこの針だけが、記帳側の退行を単独で赤にできる。
_deleg_lane_type=""
for _f in "$LANE_DIR"/*.lane; do
  [ -f "$_f" ] || continue
  _deleg_lane_type="$(sed -n 's/^perspectives=//p' "$_f" | head -n 1)"
  break
done
if [ "$_deleg_lane_type" = "delegated-review" ]; then
  ok "(h15) 委譲レーンは専用の型名で記帳される（同型フォールバックの対象にならない）"
else
  bad "(h15) 委譲レーンの記帳型が専用名でない: [${_deleg_lane_type}]（汎用型だと無関係な同型サブエージェントに奪われる）"
fi

# 委譲レビューのレーンが開いている間は編集が止まる（この経路の目的そのもの）
run_hook "$(edit_json_as 'main-agent')"
assert_deny "(h15) 委譲レビューが走っている間の編集は止まる"

# **無関係な汎用サブエージェントの終端でレーンが解けてはいけない。** 委譲レーンは専用の
# 型名で記帳してあり、同型フォールバック（同じ agent_type で対応づいていない最古の
# レーンを引き受ける）の対象にならない。ここが緩むと、レビュー中に凍結が消える。
run_hook "$(subagent_start_json 'general-purpose' agent-x1)"
run_hook "$(subagent_stop_json 'general-purpose' agent-x1)"
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) 無関係な汎用サブエージェントの Start/Stop では委譲レーンが解けない"
else
  bad "(h15) 無関係な汎用サブエージェントの終端で委譲レーンが解けた（レビュー中に凍結が消える）: [$(lane_count)]"
fi
# agent_id が空の Stop でも同じ（相関 ID が無い側から奪われない）
run_hook "$(subagent_stop_json 'general-purpose' '')"
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) agent_id が空の Stop でも委譲レーンが解けない"
else
  bad "(h15) agent_id が空の Stop で委譲レーンが解けた: [$(lane_count)]"
fi

# **委譲先は自分の結果ファイルを書ける。** ここを止めると、handoff の手順 2（結果を
# 出力先へ書く）が自分のレーンで自分をデッドロックさせる。線引きは dirty 判定の除外
# （出力先は「作業ツリーではない」）と同じで、そこへの書き込みはレビュー対象を動かさない。
run_hook "$(jq -n --arg d "$REPO" --arg f "$REPO/.review-results/claude-code/code-review.md" \
  '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Write", agent_type: "general-purpose",
    tool_input: {file_path: $f, content: "result"}}')"
assert_silent "(h15) 委譲レビューは自分の結果ファイル（出力先配下）を書ける"
# 相対パスでも同じ（ホストは cwd 相対で書くことがある）
run_hook "$(jq -n --arg d "$REPO" \
  '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Write", agent_type: "general-purpose",
    tool_input: {file_path: ".review-results/claude-code/code-review.md", content: "result"}}')"
assert_silent "(h15) 出力先配下への相対パスの書き込みも止めない"
# 出力先の外は従来どおり止まる（免除がレビュー対象へ広がっていないこと）
run_hook "$(jq -n --arg d "$REPO" --arg f "$REPO/src/app.ts" \
  '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Write", agent_type: "general-purpose",
    tool_input: {file_path: $f, content: "x"}}')"
assert_deny "(h15) 出力先の外への書き込みは従来どおり止まる"
# 免除の錨は**このリポジトリの**出力先。同じディレクトリ名を含むだけの**ツリー内**の
# パスまで免除すると、レビュー対象の外という理由が成り立たないまま穴が広がる。
# （リポジトリ外の同名パスは Issue `#1756` 以降そもそもツリー外として通る側なので、
# 錨の針はツリー内へ置く。ツリー外が通ること自体は (m) の
# 「Write: 作業ツリーの外（scratchpad 相当）は止めない」が対で固定する）
run_hook "$(jq -n --arg d "$REPO" --arg f "$REPO/src/.review-results/claude-code/x.md" \
  '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Write", agent_type: "general-purpose",
    tool_input: {file_path: $f, content: "x"}}')"
assert_deny "(h15) ツリー内の同名ディレクトリ（src/.review-results）への書き込みは免除しない"

# 起動が拒否された回は、同じ鍵の PermissionDenied で解放される（名簿外でも通す経路）。
clear_lanes
run_hook "$(generic_agent_json "$DELEG_MARK" tu-d9)"
if [ "$(lane_count)" -eq 1 ]; then
  run_hook "$(jq -n --arg d "$REPO" --arg p "$DELEG_MARK" \
    '{hook_event_name: "PermissionDenied", cwd: $d, tool_name: "Agent", tool_use_id: "tu-d9",
      tool_input: {subagent_type: "general-purpose", description: "delegated", prompt: $p}}')"
  if [ "$(lane_count)" -eq 0 ]; then
    ok "(h15) 起動が拒否された委譲レビューは同じ鍵の PermissionDenied で解放される"
  else
    bad "(h15) 拒否された委譲レビューのレーンが解放されない: [$(lane_count)]"
  fi
else
  bad "(h15) 拒否検査の前提（レーン 1 本）が作れない: [$(lane_count)]"
fi

# 以下は「取らない」側。1 つでも取ってしまうと、レビュー以外の委譲が凍結する。
clear_lanes
run_hook "$(generic_agent_json "リポジトリの依存関係を調べて要約してください")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) レビュー以外の汎用 Agent はレーンを取らない"
else
  bad "(h15) レビュー以外の汎用 Agent でレーンが開いた: [$(lane_count)]"
fi

clear_lanes
run_hook "$(generic_agent_json "用語集に FF-REVIEW-DELEGATED という語をそのまま残してください。レビューはしないでください。")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) マーカーの語が散文中に出るだけではレーンを取らない（行頭アンカー）"
else
  bad "(h15) 散文中のマーカーでレーンが開いた: [$(lane_count)]"
fi

clear_lanes
run_hook "$(generic_agent_json "参考までに以下を見てください: FF-REVIEW-DELEGATED: $DELEG_DIR/code-review.prompt.md")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) 行の途中に置かれたマーカー（実在パス付き）ではレーンを取らない"
else
  bad "(h15) 行頭でないマーカーでレーンが開いた（散文との衝突面が広がる）: [$(lane_count)]"
fi

clear_lanes
run_hook "$(generic_agent_json "FF-REVIEW-DELEGATED: $DELEG_DIR/no-such-perspective.prompt.md")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) 実在しない委譲プロンプトを名指す行ではレーンを取らない"
else
  bad "(h15) 実在しないパスでレーンが開いた: [$(lane_count)]"
fi

clear_lanes
mkdir -p "$REPO/docs/.delegated"
printf '%s\n' 'notes' > "$REPO/docs/.delegated/notes.prompt.md"
run_hook "$(generic_agent_json "FF-REVIEW-DELEGATED: $REPO/docs/.delegated/notes.prompt.md")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) レビュー出力先の外にある .delegated/ ではレーンを取らない"
else
  bad "(h15) 出力先の外の .delegated/ でレーンが開いた: [$(lane_count)]"
fi

clear_lanes
run_hook "$(generic_agent_json "次のプロンプトを実行してください: $DELEG_DIR/code-review.prompt.md")"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) パスだけを載せた形ではレーンを取らない（行頭マーカーを要求する）"
else
  bad "(h15) パスだけでレーンが開いた（自由文字列との衝突面が広がる）: [$(lane_count)]"
fi
clear_lanes

# 正常完了の出口は「委譲結果の回収」。回収の到達が「委譲したレビューは終わった」の宣言で、
# ここで消さないと 3 分のレビューのあと寿命上限（既定 1800 秒）まで凍結が残る。
# 委譲レーンを 1 本置いた状態で回収関数を呼び、消えることを実測する。
clear_lanes
run_hook "$(generic_agent_json "$DELEG_MARK" tu-d10)"
if [ "$(lane_count)" -eq 1 ]; then
  ( set -e
    OUTPUT_DIR="$REPO/.review-results"
    DELEGATE_TO_HOST=true
    # 回収本体は委譲状態を要求するので、レーン解放の関数だけを取り出して回す。
    eval "$(awk '/^release_delegated_review_lanes\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$MULTI_AGENT")"
    release_delegated_review_lanes )
  if [ "$(lane_count)" -eq 0 ]; then
    ok "(h15) 委譲結果の回収で委譲レーンが解放される（正常完了の出口）"
  else
    bad "(h15) 回収しても委譲レーンが残る（正常完了でも寿命上限まで凍結が続く）: [$(lane_count)]"
  fi
else
  bad "(h15) 回収検査の前提（レーン 1 本）が作れない: [$(lane_count)]"
fi
# 回収の解放は委譲レーンだけを対象にする（名簿の型のレーンまで消すと、走行中の
# レビュアーの凍結が消える）
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-d11)"
( set -e
  OUTPUT_DIR="$REPO/.review-results"
  eval "$(awk '/^release_delegated_review_lanes\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$MULTI_AGENT")"
  release_delegated_review_lanes )
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) 回収の解放は委譲レーンだけを消す（名簿の型のレーンは残る）"
else
  bad "(h15) 回収の解放が名簿の型のレーンまで消した: [$(lane_count)]"
fi
clear_lanes

# マーカーの綴りは hook と multi-agent.sh の **handoff を出す関数の中**で一致していなければ
# ならない。ファイル全体を grep すると、handoff 行が消えても説明文側の同じ語が残るだけで
# 緑になる（実際に識別へ効くのは handoff 行だけ）。
_marker_hook="$(sed -n 's/^REVIEW_DELEGATION_MARKER="\(.*\)"$/\1/p' "$TARGET" | head -n 1)"
_handoff_body="$(awk '/^print_delegation_handoff\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$MULTI_AGENT")"
case "$_marker_hook" in
  FF-*[A-Z]*) : ;;
  *) bad "(h15) 委譲マーカーが FF- 接頭辞の識別子でない: [${_marker_hook}]（自由文字列と衝突しやすい弱い語は使わない）" ;;
esac
if [ -z "$_marker_hook" ]; then
  bad "(h15) hook から委譲マーカーを抽出できない（綴りの一致を検査できない）"
elif [ -z "$_handoff_body" ]; then
  bad "(h15) multi-agent.sh の print_delegation_handoff を切り出せない"
else
  case "$_handoff_body" in
    *"${_marker_hook}: "*)
      ok "(h15) 委譲マーカーの綴りが hook と handoff 生成関数で一致している" ;;
    *)
      bad "(h15) 委譲マーカー（${_marker_hook}）が print_delegation_handoff の出力に無い" ;;
  esac
fi

# 鍵（tool_use_id）側にも同じ潰し衝突がある。記号だけが違う 2 つの起動が同じ鍵へ潰れると、
# 取得の冪等判定が 2 本目を「既に在る」と読んでレーンを 1 本落とし、1 本目の終端で凍結が解ける。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent 'tu!1')"
run_hook "$(agent_json 'pr-review-toolkit:silent-failure-hunter' Agent 'tu@1')"
if [ "$(lane_count)" -eq 2 ]; then
  ok "(h15) 記号だけが違う tool_use_id は別の鍵になる（レーンを落とさない）"
else
  bad "(h15) 記号だけが違う tool_use_id が同じ鍵へ潰れ、レーンが落ちた: [$(lane_count)]"
fi
clear_lanes

# 記号を削るだけの正規化だと、別の agent_id が同じ形へ潰れて無関係な終端が別レーンを
# 閉じる。名簿の型どうしでも起きるので、ここで固定する。
clear_lanes
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' Agent tu-c1)"
run_hook "$(subagent_start_json 'pr-review-toolkit:code-reviewer' 'collision!')"
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' 'collision@')"
if [ "$(lane_count)" -eq 1 ]; then
  ok "(h15) 記号だけが違う agent_id の終端では別レーンを閉じない（正規化の衝突）"
else
  bad "(h15) 記号だけが違う agent_id で他レーンが閉じた（走行中のレビューで凍結が解ける）: [$(lane_count)]"
fi
# 同じ id の終端では閉じる（衝突対策が正当な解放まで潰していないこと）
run_hook "$(subagent_stop_json 'pr-review-toolkit:code-reviewer' 'collision!')"
if [ "$(lane_count)" -eq 0 ]; then
  ok "(h15) 同じ agent_id の終端では従来どおり解放される"
else
  bad "(h15) 同じ agent_id の終端で解放されない（衝突対策が正当な解放を潰した）: [$(lane_count)]"
fi
clear_lanes

# ── (h14) 名簿の追随検査（scripts/check-review-roster-drift.sh） ────────────────
# レーンを取る subagent_type の名簿は**列挙**で、実体は別プラグインのレビュアー群にある。
# 実体が増えても列挙は自動では追随しないので、突き合わせる検査を置く。ここでは実体を
# fixture で作って全分岐を**常時**回す（ホストに当該プラグインが入っているかに依存させない。
# 実体との照合は同じスクリプトへ実配置のディレクトリを渡して行う）。
ROSTER_CHECK="$PLUGIN_ROOT/scripts/check-review-roster-drift.sh"
if [ ! -x "$ROSTER_CHECK" ]; then
  bad "(h14) 名簿の追随検査スクリプトがありません: $ROSTER_CHECK"
else
  ROSTER_FIX="$TEST_TMP/roster"
  # 名簿の既定値を hook から取り出し、fixture の実体を**そこから**作る。ここでリテラルを
  # 書き写すと、hook の名簿を変えたときに fixture だけが古いまま «常に一致» を出す。
  _roster_default="$(sed -n 's/^REVIEW_LOCK_TYPES="\${FF_REVIEW_SUBAGENT_LOCK_TYPES:-\(.*\)}"$/\1/p' "$TARGET" | head -n 1)"
  if [ -z "$_roster_default" ]; then
    bad "(h14) hook から名簿の既定値を抽出できません（fixture を実体から作れない）"
  else
    make_roster_fixture() { # <ディレクトリ> [追加の agent 名]...
      local dir="$1"; shift
      rm -rf "$dir"; mkdir -p "$dir"
      local t base
      set -f
      for t in $_roster_default; do
        base="${t##*:}"
        printf '%s\n' "# $base" > "$dir/$base.md"
      done
      set +f
      local extra
      for extra in "$@"; do
        printf '%s\n' "# $extra" > "$dir/$extra.md"
      done
    }
    # 出力の照合はシェルの glob で行う。`printf | grep -q` は grep が一致した時点で閉じるため
    # producer が SIGPIPE を受け、pipefail 下で「一致したのに失敗」へ反転しうる。
    roster_out_has() { case "$ROSTER_OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
    run_roster() { # <ディレクトリ> [追加引数]...
      local dir="$1"; shift
      ROSTER_OUT="$(bash "$ROSTER_CHECK" --agents-dir "$dir" --hook "$TARGET" "$@" 2>&1)" \
        && ROSTER_RC=0 || ROSTER_RC=$?
    }

    make_roster_fixture "$ROSTER_FIX/match"
    run_roster "$ROSTER_FIX/match"
    if [ "$ROSTER_RC" -eq 0 ] && roster_out_has 'ROSTER_CHECK=OK'; then
      ok "(h14) 実体が名簿どおりなら rc=0"
    else
      bad "(h14) 実体が名簿どおりなのに rc=${ROSTER_RC}（${ROSTER_OUT}）"
    fi

    # AC: レビュアーが 1 本増えた状態で赤になる（名簿が追随していないことが分かる）
    make_roster_fixture "$ROSTER_FIX/added" brand-new-reviewer
    run_roster "$ROSTER_FIX/added"
    if [ "$ROSTER_RC" -eq 1 ] && roster_out_has 'MISSING=' && roster_out_has 'brand-new-reviewer'; then
      ok "(h14) レビュアーが 1 本増えると rc=1 で、足す候補が名指しされる"
    else
      bad "(h14) レビュアーが増えても検出できない、または名前が出ない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 実体から 1 本消えた側も検出する（名簿だけが残ると、存在しない型を待ち続ける）
    make_roster_fixture "$ROSTER_FIX/removed"
    rm -f "$ROSTER_FIX/removed/$(printf '%s\n' $_roster_default | head -n 1 | sed 's/^.*://').md"
    run_roster "$ROSTER_FIX/removed"
    if [ "$ROSTER_RC" -eq 1 ] && roster_out_has 'EXTRA='; then
      ok "(h14) 実体から 1 本消えると rc=1 で、名簿側の余りが名指しされる"
    else
      bad "(h14) 実体から消えた名前を検出できない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 除外対象（共有ツリーを編集するレビュアー）は実体に在っても drift にしない
    make_roster_fixture "$ROSTER_FIX/excluded" code-simplifier
    run_roster "$ROSTER_FIX/excluded"
    if [ "$ROSTER_RC" -eq 0 ]; then
      ok "(h14) 除外対象（code-simplifier）は実体に在っても drift にならない"
    else
      bad "(h14) 除外対象が drift として報告された (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 判定不能は 0 へ倒さない（判定できないことを一致と読むと、名簿が腐っても緑が続く）
    run_roster "$ROSTER_FIX/no-such-dir"
    if [ "$ROSTER_RC" -eq 2 ] && roster_out_has 'ROSTER_CHECK=UNDETERMINED'; then
      ok "(h14) 実体のディレクトリが無い回は rc=2（一致へ倒さない）"
    else
      bad "(h14) 実体のディレクトリが無い回が rc=2 でない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 改行を含むファイル名は 1 件が複数行へ化け、行志向の突き合わせが別々のレビュアーと
    # して数える（実体 1 件で名簿 2 件を満たせる）。
    make_roster_fixture "$ROSTER_FIX/newline"
    if touch "$ROSTER_FIX/newline/$(printf 'a\npr-review-toolkit:zz').md" 2>/dev/null; then
      run_roster "$ROSTER_FIX/newline"
      if [ "$ROSTER_RC" -eq 2 ]; then
        ok "(h14) 実体のファイル名に改行があれば rc=2（行として突き合わせられない）"
      else
        bad "(h14) 改行入りのファイル名が rc=2 でない (rc=${ROSTER_RC}): ${ROSTER_OUT}"
      fi
    else
      bad "(h14) 改行を含むファイル名の fixture を作れない（この経路が未検査のまま）"
    fi

    mkdir -p "$ROSTER_FIX/empty"
    run_roster "$ROSTER_FIX/empty"
    if [ "$ROSTER_RC" -eq 2 ]; then
      ok "(h14) 実体が 0 件の回は rc=2（空ディレクトリを「名簿と一致」と読まない）"
    else
      bad "(h14) 実体 0 件が rc=2 でない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 名簿は glob を書ける契約なので、検査側が素のまま分割すると**呼び出し元 cwd の
    # ファイル名**が名簿として読まれ、cwd 次第で判定が反転する。
    printf '%s\n' '#!/usr/bin/env bash' \
      'REVIEW_LOCK_TYPES="${FF_REVIEW_SUBAGENT_LOCK_TYPES:-pr-review-toolkit:* }"' \
      > "$ROSTER_FIX/hook-glob.sh"
    mkdir -p "$ROSTER_FIX/cwd-decoy"
    : > "$ROSTER_FIX/cwd-decoy/pr-review-toolkit:decoy"
    ROSTER_OUT="$( cd "$ROSTER_FIX/cwd-decoy" && bash "$ROSTER_CHECK" \
      --agents-dir "$ROSTER_FIX/match" --hook "$ROSTER_FIX/hook-glob.sh" 2>&1 )" \
      && ROSTER_RC=0 || ROSTER_RC=$?
    if roster_out_has 'decoy'; then
      bad "(h14) 呼び出し元 cwd のファイル名が名簿として読まれた（glob が展開されている）: ${ROSTER_OUT}"
    else
      ok "(h14) 名簿の glob は展開せず、cwd のファイル名を名簿に混ぜない"
    fi

    # 名簿を抽出できない hook（書き方が変わった）も判定不能へ倒す
    printf '%s\n' '#!/usr/bin/env bash' 'REVIEW_LOCK_TYPES="$(derive_from_somewhere)"' > "$ROSTER_FIX/hook-changed.sh"
    ROSTER_OUT="$(bash "$ROSTER_CHECK" --agents-dir "$ROSTER_FIX/match" --hook "$ROSTER_FIX/hook-changed.sh" 2>&1)" \
      && ROSTER_RC=0 || ROSTER_RC=$?
    if [ "$ROSTER_RC" -eq 2 ]; then
      ok "(h14) hook から名簿を抽出できない回は rc=2（抽出失敗を一致と読まない）"
    else
      bad "(h14) 名簿を抽出できない hook が rc=2 でない (rc=$ROSTER_RC): $ROSTER_OUT"
    fi

    # 崩壊床: 名簿の件数そのものを独立した絶対数で縛る。上の突き合わせは実体を fixture から
    # 作るので、hook と fixture が同時に縮むと一致したまま通る（両方が同じ既定値から派生する
    # ため）。件数だけは派生させずに書く。
    # 崩壊床は**件数だけでは足りない**。上の突き合わせは実体側の fixture を hook の名簿から
    # 作るので、名簿の 1 本を別名へ差し替えても件数が同じなら一致したまま通る（実測）。
    # 名前そのものを、名簿から導出しない独立した並びとしてここに置く。名簿を変えるのは
    # 意図的な行為なので、同じ PR でこの並びも更新する。
    _roster_expected="pr-review-toolkit:code-reviewer
pr-review-toolkit:comment-analyzer
pr-review-toolkit:pr-test-analyzer
pr-review-toolkit:silent-failure-hunter
pr-review-toolkit:type-design-analyzer"
    set -f
    _roster_actual="$(printf '%s\n' $_roster_default | LC_ALL=C sort -u)"
    set +f
    if [ "$_roster_actual" = "$_roster_expected" ]; then
      ok "(h14) 名簿の中身が崩壊床（5 件の固定並び）と一致する"
    else
      bad "(h14) 名簿が崩壊床と食い違う — 意図した変更なら本検査の並びも同じ PR で更新すること"
      printf '    期待| %s\n' "$(printf '%s' "$_roster_expected" | tr '\n' ' ')" >&2
      printf '    実体| %s\n' "$(printf '%s' "$_roster_actual" | tr '\n' ' ')" >&2
    fi
  fi
fi

# ── (h17) 追随検査を実体に対して回す配線（hooks/check-review-roster-drift.sh） ──
# (h14) は突き合わせロジックを fixture で測る。ロジックが正しくても**実体に対して回す
# 経路が無ければ**、名簿の遅れは誰かが手で叩いた回にしか分からない。ここで測るのは
# 「SessionStart に登録されていること」と「実体不在・drift・判定不能の 3 分岐が
# セッション開始で正しく出ること」の 2 点。
ROSTER_HOOK="$PLUGIN_ROOT/hooks/check-review-roster-drift.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
if [ ! -x "$ROSTER_HOOK" ]; then
  bad "(h17) 追随検査を回す hook がありません（実行ビットを含む）: $ROSTER_HOOK"
elif [ ! -f "$HOOKS_JSON" ]; then
  bad "(h17) hooks.json がありません: $HOOKS_JSON"
elif [ -z "${_roster_default:-}" ]; then
  bad "(h17) 名簿の既定値を抽出できず、実体の fixture を作れません（h14 と同じ抽出に失敗）"
else
  # ── 配線そのもの ──────────────────────────────────────────────────────────
  # 部分一致（basename が command 文字列に含まれる）だけでは、`true # <名前>.sh` のように
  # **hook を実行しない** command でも緑になる。type / command / timeout を構造的な完全一致で
  # 見る（下の偽登録への変異注入がこの検出力を実測する）。
  roster_hook_registered() { # <hooks.json> <hook の basename>
    jq -e --arg b "$2" '
      [ (.hooks.SessionStart // [])[] | .hooks[]?
        | select(.type == "command")
        | select(.command == ("bash \"${CLAUDE_PLUGIN_ROOT}/hooks/" + $b + "\""))
        | select((.timeout | type) == "number" and .timeout > 0) ]
      | length == 1
    ' "$1" >/dev/null 2>&1
  }
  ROSTER_HOOK_BASE="$(basename "$ROSTER_HOOK")"
  if roster_hook_registered "$HOOKS_JSON" "$ROSTER_HOOK_BASE"; then
    ok "(h17) 追随検査が SessionStart へ構造的に登録されている（type / command / timeout・配線を外すと赤）"
  else
    bad "(h17) 追随検査が hooks.json の SessionStart に登録されていません（検査は在るが実体に対して回らない）"
  fi
  # 偽の参照（command が hook を実行せず、名前だけコメントに出てくる形）を配線と認めない。
  ROSTER_FAKE_JSON="$TEST_TMP/hooks-fake-registration.json"
  if jq --arg b "$ROSTER_HOOK_BASE" '
    .hooks.SessionStart |= map(.hooks |= map(
      if (.command // "") | contains($b) then .command = ("true # " + $b) else . end))
  ' "$HOOKS_JSON" > "$ROSTER_FAKE_JSON" 2>/dev/null; then
    if roster_hook_registered "$ROSTER_FAKE_JSON" "$ROSTER_HOOK_BASE"; then
      bad "(h17) hook を実行しない command（コメントに名前が出るだけ）を配線として緑にしています"
    else
      ok "(h17) hook を実行しない command は配線と認めない（偽の参照文字列への変異注入）"
    fi
  else
    bad "(h17) 偽登録の fixture を作れず、配線検査の検出力を実測できません"
  fi

  # ── 実体を与えた駆動 ──────────────────────────────────────────────────────
  ROSTER_HOME="$TEST_TMP/roster-home"
  # 実体の fixture は (h14) と同じく名簿の既定値から作る。**パスのプラグイン名も**
  # 名簿から導く — リテラルを書くと、名簿を別プラグインへ向け替えたときに
  # 「配線の欠陥ではない理由」で赤くなる。
  ROSTER_PLUGIN="${_roster_default%%:*}"
  make_agents_dir() { # <agents ディレクトリ> [追加の agent 名]...
    local dir="$1"; shift
    mkdir -p "$dir"
    local t base extra
    set -f
    for t in $_roster_default; do
      base="${t##*:}"
      printf '%s\n' "# $base" > "$dir/$base.md"
    done
    set +f
    for extra in "$@"; do
      printf '%s\n' "# $extra" > "$dir/$extra.md"
    done
  }
  cache_agents_dir() { # <Claude 設定ディレクトリ> <版ディレクトリ名>
    printf '%s' "$1/plugins/cache/mp/$ROSTER_PLUGIN/$2/agents"
  }
  make_home_fixture() { # <Claude 設定ディレクトリ> [追加の agent 名]...
    local home="$1"; shift
    rm -rf "$home"
    make_agents_dir "$(cache_agents_dir "$home" 1.0.0)" "$@"
  }
  run_roster_hook() { # <Claude 設定ディレクトリ> [<名簿を持つ hook のパス>]
    ROSTER_HOOK_OUT="$(printf '{}' | env \
      FF_DEV_TOOLKIT_ROSTER_DRIFT_CLAUDE_HOME="$1" \
      FF_DEV_TOOLKIT_ROSTER_DRIFT_HOOK="${2:-$TARGET}" \
      bash "$ROSTER_HOOK" 2>&1)" && ROSTER_HOOK_RC=0 || ROSTER_HOOK_RC=$?
  }
  roster_hook_msg() { printf '%s' "$ROSTER_HOOK_OUT" | jq -r '.systemMessage // empty' 2>/dev/null || true; }
  roster_expect_silent() { # <ラベル>
    if [ "$ROSTER_HOOK_RC" -eq 0 ] && [ -z "$ROSTER_HOOK_OUT" ]; then
      ok "(h17) $1"
    else
      bad "(h17) ${1}（無音であるべきなのに出力あり rc=${ROSTER_HOOK_RC}）: ${ROSTER_HOOK_OUT}"
    fi
  }
  roster_expect_msg() { # <ラベル> <systemMessage に期待する部分文字列>
    local m
    m="$(roster_hook_msg)"
    case "$m" in
      *"$2"*) ok "(h17) $1" ;;
      *) bad "(h17) ${1}（期待: ${2} / rc=${ROSTER_HOOK_RC}）: ${ROSTER_HOOK_OUT}" ;;
    esac
  }
  # 判定不能の経路は通知の出し方が 2 つある（走査を始められない回は単独の文面、実体ごとに
  # 成立しなかった回は drift との併記）。どちらも additionalContext に「一致」ではなく
  # 「判定不能」だと書くので、通知全体に対して照合する。
  roster_expect_out() { # <ラベル> <通知全体に期待する部分文字列>...
    local label="$1" needle
    shift
    for needle in "$@"; do
      case "$ROSTER_HOOK_OUT" in
        *"$needle"*) ;;
        *) bad "(h17) ${label}（期待: ${needle} / rc=${ROSTER_HOOK_RC}）: ${ROSTER_HOOK_OUT}"; return 0 ;;
      esac
    done
    ok "(h17) $label"
  }

  # AC: 当該プラグインが導入されていない環境は無音で抜ける（無関係な利用者を赤にしない）。
  # 実体不在を通知する実装へ変えると赤になる。
  mkdir -p "$ROSTER_HOME-absent/plugins/cache" "$ROSTER_HOME-absent/plugins/marketplaces"
  run_roster_hook "$ROSTER_HOME-absent"
  roster_expect_silent "レビュアー実体が無い環境は無音で exit 0（セッション開始を汚さない）"

  make_home_fixture "$ROSTER_HOME-match"
  run_roster_hook "$ROSTER_HOME-match"
  roster_expect_silent "名簿と実体が一致する環境も無音"

  # AC: レビュアーが 1 本増えた環境で、追随していないことが利用者に見える形で伝わる。
  make_home_fixture "$ROSTER_HOME-added" brand-new-reviewer
  run_roster_hook "$ROSTER_HOME-added"
  roster_expect_msg "レビュアーが 1 本増えると systemMessage で名指しされる" "brand-new-reviewer"

  # AC: 検査自体が成立しない環境では「一致」へ倒れない。以下 4 形はいずれも候補 0 件
  # または rc=2 として現れるので、無音（= 一致と区別できない緑）にしないことを固定する。
  rm -rf "$ROSTER_HOME-empty"
  mkdir -p "$(cache_agents_dir "$ROSTER_HOME-empty" 1.0.0)"
  run_roster_hook "$ROSTER_HOME-empty"
  roster_expect_out "レビュアー実体が 0 件の回は「判定不能」として伝わる（一致へ倒さない）" "判定不能"

  rm -rf "$ROSTER_HOME-noagents"
  mkdir -p "$ROSTER_HOME-noagents/plugins/cache/mp/$ROSTER_PLUGIN/1.0.0"
  run_roster_hook "$ROSTER_HOME-noagents"
  roster_expect_out "プラグイン実体はあるが agents/ が無い回も「判定不能」（未導入として無音にしない）" "判定不能"

  # 中間ディレクトリが「あるのに列挙できない」回。glob が空振りして「未導入」と同じ形に
  # なるので、権限で見分けられていなければここが赤になる。
  make_home_fixture "$ROSTER_HOME-midperm"
  if chmod 111 "$ROSTER_HOME-midperm/plugins/cache" 2>/dev/null && [ ! -r "$ROSTER_HOME-midperm/plugins/cache" ]; then
    run_roster_hook "$ROSTER_HOME-midperm"
    chmod 755 "$ROSTER_HOME-midperm/plugins/cache" 2>/dev/null || true
    roster_expect_out "中間ディレクトリを列挙できない回も「判定不能」（未導入と同じ無音にしない）" "判定不能"
  else
    chmod 755 "$ROSTER_HOME-midperm/plugins/cache" 2>/dev/null || true
    echo "  ○ skip: 読み取り不可のディレクトリを作れない（root 実行等）ため中間ディレクトリの経路は未検査"
  fi

  # 名簿側を読めない・抽出できない回も「一致」へ倒さない。
  run_roster_hook "$ROSTER_HOME-match" "$TEST_TMP/roster-no-such-hook.sh"
  roster_expect_msg "名簿を持つ hook を読めない回は「判定不能」" "判定できませんでした"
  printf '%s\n' '#!/usr/bin/env bash' 'REVIEW_LOCK_TYPES="$(derive_from_somewhere)"' \
    > "$TEST_TMP/roster-hook-changed.sh"
  run_roster_hook "$ROSTER_HOME-match" "$TEST_TMP/roster-hook-changed.sh"
  roster_expect_msg "名簿を抽出できない hook の回は「判定不能」" "判定できませんでした"

  # 版の併存を独立に突き合わせると、名簿を正しく直したあとも古い写しが EXTRA を出し続け、
  # **どの名簿値でも消せない通知**になる。グループ単位で 1 つの判定へ畳むことを固定する。
  rm -rf "$ROSTER_HOME-semver"
  make_agents_dir "$(cache_agents_dir "$ROSTER_HOME-semver" 2.0.0)"
  make_agents_dir "$(cache_agents_dir "$ROSTER_HOME-semver" 1.0.0)"
  rm -f "$(cache_agents_dir "$ROSTER_HOME-semver" 1.0.0)/${_roster_default##*:}.md"
  run_roster_hook "$ROSTER_HOME-semver"
  roster_expect_silent "SemVer で順序づく併存は最新版だけを見る（古い写しの欠落で鳴り続けない）"

  rm -rf "$ROSTER_HOME-semver-new"
  make_agents_dir "$(cache_agents_dir "$ROSTER_HOME-semver-new" 2.0.0)" brand-new-reviewer
  make_agents_dir "$(cache_agents_dir "$ROSTER_HOME-semver-new" 1.0.0)"
  run_roster_hook "$ROSTER_HOME-semver-new"
  roster_expect_msg "最新版で増えたレビュアーは併存していても名指しされる" "brand-new-reviewer"

  # 版を解釈できない併存（開発ホストの実体がこの形: 版ディレクトリ名が内容ハッシュで、
  # plugin.json に version が無い）は和集合へ畳む。片方に欠落があっても鳴らない。
  rm -rf "$ROSTER_HOME-union"
  make_agents_dir "$(cache_agents_dir "$ROSTER_HOME-union" 022b3c274938)"
  make_agents_dir "$(cache_agents_dir "$ROSTER_HOME-union" 0e3f501d0f4a)"
  rm -f "$(cache_agents_dir "$ROSTER_HOME-union" 0e3f501d0f4a)/${_roster_default##*:}.md"
  run_roster_hook "$ROSTER_HOME-union"
  roster_expect_silent "版を解釈できない併存は和集合で畳む（消せない EXTRA を作らない）"

  rm -rf "$ROSTER_HOME-union-new"
  make_agents_dir "$(cache_agents_dir "$ROSTER_HOME-union-new" 022b3c274938)" brand-new-reviewer
  make_agents_dir "$(cache_agents_dir "$ROSTER_HOME-union-new" 0e3f501d0f4a)"
  run_roster_hook "$ROSTER_HOME-union-new"
  roster_expect_msg "和集合へ畳んでも増えたレビュアーは名指しされる" "brand-new-reviewer"

  # drift と判定不能が同時に起きる回。先に見つかった方で早期に返すと、もう片方が届かない。
  rm -rf "$ROSTER_HOME-both"
  make_agents_dir "$ROSTER_HOME-both/plugins/cache/mp1/$ROSTER_PLUGIN/1.0.0/agents" brand-new-reviewer
  mkdir -p "$ROSTER_HOME-both/plugins/marketplaces/mp2/plugins/$ROSTER_PLUGIN/agents"
  run_roster_hook "$ROSTER_HOME-both"
  roster_expect_out "drift と判定不能が同時に起きたら 1 通へ併記する（片方で早期に返さない）" \
    "brand-new-reviewer" "判定不能"

  # 利用者向け opt-out（他の SessionStart hook と同じ形）。
  ROSTER_HOOK_OUT="$(printf '{}' | env \
    FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK=1 \
    FF_DEV_TOOLKIT_ROSTER_DRIFT_CLAUDE_HOME="$ROSTER_HOME-both" \
    FF_DEV_TOOLKIT_ROSTER_DRIFT_HOOK="$TARGET" \
    bash "$ROSTER_HOOK" 2>&1)" && ROSTER_HOOK_RC=0 || ROSTER_HOOK_RC=$?
  roster_expect_silent "FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK=1 で無音になる"
fi

echo "guard-review-in-flight: (k) Bash 経由の作業ツリー書き込み"
bash_json_at() { jq -n --arg c "$1" --arg d "$2" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}'; }
k_deny() { # <command> <label> [cwd]
  run_hook "$(bash_json_at "$1" "${3:-$REPO}")"
  assert_deny "(k) $2"
}
k_silent() { # <command> <label> [cwd]
  run_hook "$(bash_json_at "$1" "${3:-$REPO}")"
  assert_silent "(k) $2"
}
clear_lanes
clear_lock
write_lock "$LIVE_PID"
printf 'from pathlib import Path\nPath("a").write_text("x")\n' > "$REPO/patch.py"
printf 'print(open("README.md").read())\n' > "$REPO/read.py"
printf 'require("fs").writeFileSync("a", "x")\n' > "$REPO/fix.js"
printf 'x\n' > "$TEST_OUT/fix.diff"
K_POS_1="$(printf 'python3 - <<%sPY%s\nopen("a.txt","w").write("x")\nPY\n' "'" "'")"
K_POS_2="$(printf 'python3 - <<%sPY%s\nfrom pathlib import Path\nPath("a.txt").write_text("x")\nPY\n' "'" "'")"
K_POS_SUB="$(printf 'python3 - <<%sPY%s\nimport subprocess\nsubprocess.run(["x"])\nPY\n' "'" "'")"
K_POS_NOTES="$(printf 'cat <<%sEOF%s > notes.md\ngit commit -m x\nEOF\n' "'" "'")"
K_POS_UNTERM="$(printf 'cat <<%sEOF%s > %s/x\nno terminator\n' "'" "'" "$TEST_OUT")"
K_POS_SHDOC="$(printf 'bash <<%sEOF%s\necho x > f\nEOF\n' "'" "'")"
K_NEG_READ="$(printf 'python3 - <<%sPY%s\nprint(open("f").read())\nPY\n' "'" "'")"
K_NEG_BODY="$(printf 'cat > %s/notes.md <<%sEOF%s\nsed -i s/a/b/ README.md\ntee README.md\nEOF\n' "$TEST_OUT" "'" "'")"
K_NEG_GH="$(printf 'gh pr create --body "$(cat <<%sEOF%s\nsed -i s/a/b/ README.md\nEOF\n)"\n' "'" "'")"
K_NEG_SHDOC="$(printf 'bash -e <<%sEOF%s\ncd %s && echo x > f\nEOF\n' "'" "'" "$TEST_OUT")"
# 正の対照（走行中 → deny）
k_deny "$K_POS_1" "事故形: python3 の heredoc プログラムが open(…,\"w\") を持つ"
case "$REASON" in
  *"$REPO/a.txt"*'open('*'heredoc'*) ok "(k) 理由文がマーカー（open(…）と本文の出所（heredoc）と書き込み先の実パスを出す" ;;
  *) bad "(k) 理由文にマーカー / 出所 / 書き込み先が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'作業ツリーの外'*) ok "(k) 理由文が下書きの退避先（作業ツリーの外）を案内する" ;;
  *) bad "(k) 理由文に退避先の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"rm -- '$LOCK'"*) ok "(k) 理由文にロック削除の復旧手段が残る" ;;
  *) bad "(k) 理由文にロック削除の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'FF_REVIEW_LOCK_OVERRIDE=1 tee'*) ok "(k) 抜け道の案内が git 以外のコマンドにも及ぶ" ;;
  *) bad "(k) 抜け道の案内が git 限定のまま: [$REASON]" ;;
esac
k_deny "$K_POS_2" "事故形: Path.write_text を持つ heredoc プログラム"
k_deny "sed -i '' 's/a/b/' README.md" "sed -i（macOS 形）"
case "$REASON" in
  *"$REPO/README.md"*) ok "(k) sed -i の理由文が対象ファイルの実パスを出す（script 引数を対象と誤認しない）" ;;
  *) bad "(k) sed -i の理由文の対象が違う: [$REASON]" ;;
esac
k_deny "sed -i.bak 's/a/b/' README.md" "sed -i.bak（GNU 形）"
k_deny "tee README.md" "tee で作業ツリーへ"
case "$REASON" in
  *"$REPO/README.md"*) ok "(k) 理由文が書き込み先の実パスを出す" ;;
  *) bad "(k) 理由文に書き込み先が無い: [$REASON]" ;;
esac
k_deny "tee -a src/app.txt" "tee -a で作業ツリーへ"
k_deny "echo x > README.md" "リダイレクト >"
k_deny "echo x >> sub/file" "未作成ディレクトリ配下への >>（祖先を辿って解決）"
k_deny "echo x >README.md" "パス密着のリダイレクト"
k_deny "printf x 1> README.md" "fd 付きリダイレクト 1>"
k_deny "cmd &> log.txt" "&> リダイレクト"
k_deny "cp /tmp/x README.md" "cp の移動先が作業ツリー"
case "$REASON" in
  *"$REPO/README.md"*) ok "(k) cp の理由文が移動先の実パスを出す" ;;
  *) bad "(k) cp の理由文の対象が違う: [$REASON]" ;;
esac
k_deny "tee README.md 2>/dev/null" "tee + 2>/dev/null（stderr リダイレクトを対象と誤認せず README.md で止める）"
case "$REASON" in
  *"$REPO/README.md"*) ok "(k) tee 2>/dev/null の理由文が README.md を指す" ;;
  *) bad "(k) tee 2>/dev/null の理由文の対象が違う: [$REASON]" ;;
esac
k_deny "mv src/app.txt $TEST_OUT/app.txt" "mv の移動元が作業ツリー（移動先はツリー外）"
k_deny "rm README.md" "rm"
# gitignore 済みはリビジョン指紋に映らないので止めない（Issue `#1756`）。対で
# 「ignored でないディレクトリの rm -rf は従来どおり止まる」を置き、ignored の免除が
# ツリー全体へ広がっていないことを示す。
k_silent "rm -rf build/" "gitignore 済みのツリー内パスは止めない（指紋に映らない）"
k_deny "rm -rf src/" "対: ignored でないディレクトリの rm -rf は従来どおり止まる"
# ignore パターンに当たるディレクトリでも、中に tracked があれば `check-ignore` は
# 「ignored ではない」と答える（index を見るため）。`rm -rf` が tracked を巻き込む形は
# 指紋を動かすので止まる側で固定する。
k_deny "rm -rf cache/" "対: tracked を含む ignored ディレクトリの rm -rf は止まる"
k_deny "mv cache/ $TEST_OUT/cache" "対: tracked を含む ignored ディレクトリの移動も止まる"
k_deny "find . -name '*.pyc' -delete" "find -delete"
k_deny "mkdir newdir" "mkdir"
k_deny "touch new.txt" "touch"
k_deny "chmod +x s.sh" "chmod"
k_deny "python3 patch.py" "script ファイル（write_text を含む）を読んで判定"
k_deny "node fix.js" "node の script ファイル（writeFileSync）"
k_deny "python3 < patch.py" "< で流す script ファイル"
k_deny "bash -c 'echo x > f'" "bash -c のインライン本文を再帰走査"
k_deny "$K_POS_SHDOC" "bash の heredoc プログラムを再帰走査"
k_deny "cd src && echo x > f" "cd 追跡（ツリー内のサブディレクトリへ）"
k_deny 'cd "$(git rev-parse --show-toplevel)" && echo x > f' "cd 先がコマンド置換なら以後の相対パスは判定不能"
k_deny "cd $TEST_OUT && echo x > $REPO/README.md" "cd でツリー外へ出ても絶対パスの書き込み先は判定する"
k_deny 'O=src; echo x > "$O/x"' "コマンド内の代入を展開して判定する"
k_deny 'echo x > "$UNSET_VAR_FF_1710/x"' "未定義変数は判定不能"
case "$REASON" in
  *'判定できません'*) ok "(k) 判定不能の理由文がその旨を出す" ;;
  *) bad "(k) 判定不能の理由文が無い: [$REASON]" ;;
esac
k_deny 'python3 "$SCRIPT"' "script パスが変数なら判定不能"
k_deny 'tee $(mktemp -p .)' "コマンド置換の書き込み先は判定不能"
k_deny "python3 missing.py" "読めない script は判定不能"
k_deny "python3 -m mymod" "python3 -m は本文を取れないので判定不能"
k_deny "curl -s https://x | bash" "stdin から読む bash は判定不能"
k_deny "$K_POS_SUB" "subprocess を含むプログラムは判定不能側"
k_deny "$K_POS_UNTERM" "未終端 heredoc は判定不能"
k_deny "tee >(cat) README.md" "プロセス置換は判定不能"
k_deny "patch -p1 < $TEST_OUT/fix.diff" "patch は cwd へ書く"
k_deny "dd if=/dev/zero of=README.md" "dd of="
k_deny "git status && tee README.md" "read-only な git と並んだ tee（git 走査は無音、書き込み走査が止める）"
k_deny "echo x > ../README.md" "サブディレクトリ cwd からの ../ 参照" "$REPO/src"
# レビュー指摘（Codex / code-reviewer / silent-failure-hunter / test-analyzer。2026-09-17）で
# 取りこぼしていた形
k_deny "true & touch README.md" "単独の & で繋いだ後続コマンド"
k_deny "python3 -c 'import os; os.remove(\"src/app.txt\")'" "引用符の中の ; を含むインライン本文（区間が割れない）"
k_deny "python3 -c 'from pathlib import Path; Path(\"README.md\").write_text(\"x\")'" "インライン本文の write_text"
k_deny "node -e 'const fs=require(\"fs\"); fs.writeFileSync(\"src/app.txt\",\"x\")'" "node -e の複文本文"
k_deny "ruby -e 'x=1; File.write(\"a\",\"x\")'" "ruby -e の複文本文"
K_POS_MULTI="$(printf 'python3 -c %simport os\nos.remove("a")%s\n' "'" "'")"
k_deny "$K_POS_MULTI" "改行を含むインライン本文（引用符が行をまたぐ）"
k_deny "bash -c 'cd /tmp'; touch README.md" "子シェルの cd は親へ漏れない"
k_deny "( cd /tmp ); touch README.md" "サブシェルの cd は親へ漏れない"
k_deny "D=\"\$(mktemp -d ./draft.XXXXXX)\"; tee \"\$D/x\"" "mktemp のテンプレートが cwd 配下なら一時領域扱いにしない"
k_deny "FF_REVIEW_LOCK_OVERRIDE=1 true; echo x > README.md" "前区間の override は次の区間へ引き継がない"
k_deny "echo hi>src/app.txt" "語に密着したリダイレクト"
k_deny "echo x >| src/app.txt" ">| リダイレクト"
k_deny "RESULT=\$(python3 patch.py)" "代入値のコマンド置換の本文を走査する"
k_deny 'for f in README.md; do rm "$f"; done' "制御語（do）の後ろのコマンド（変数は判定不能側）"
k_deny 'if true; then rm README.md; fi' "制御語（then）の後ろのコマンド"
k_deny 'case x in x) rm README.md ;; esac' "case のパターンの後ろのコマンド"
k_deny 'echo "$(echo x > README.md)"' "引用文字列の中の \$(…) の本文"
k_deny 'echo `rm README.md`' "バッククォートの本文"
k_deny 'eval "rm README.md"' "eval は判定不能"
printf 'sed -i s/a/b/ README.md\n' > "$REPO/fix.sh"
printf '#!/usr/bin/env python3\nopen("a","w")\n' > "$REPO/patch2"
chmod +x "$REPO/patch2"
k_deny '. ./fix.sh' ". で読む sh 本文を再帰走査"
k_deny 'source fix.sh' "source で読む sh 本文を再帰走査"
k_deny './patch2' "直接実行するスクリプト（shebang で言語を決める）"
k_deny './missing.sh' "読めない直接実行は判定不能"
k_deny "awk '{print > \"src/app.txt\"}' src/app.txt" "awk の出力リダイレクト"
k_deny "tar -cf archive.tar src/" "tar -c のアーカイブ先"
k_deny "tar -C src -xf $TEST_OUT/a.tar" "tar の連結フラグ（-xf）と -C"
k_deny "gzip README.md" "gzip の in-place 圧縮"
k_deny "zip out.zip README.md" "zip"
k_deny "git rm README.md" "git rm（git 走査の名簿外だった形）"
k_deny "git clean -fdx" "git clean"
k_deny "bash -c 'git commit -m x'" "sh -c の内側の git 書き込み"
k_deny "python3 < patch.py" "< で流す script ファイル"
k_deny "perl -pi -e 's/a/b/' README.md" "perl -pi（クラスタに i）"
k_deny "curl -sSLo out.txt https://x" "curl の連結フラグ -o"
k_deny "curl -sO https://x" "curl -O（cwd へ保存）"
k_deny "sort -o README.md README.md" "sort -o"
k_deny 'echo x > $PWD/f' "\$PWD はツール側の cwd で解決"
k_deny "python3 -c 'open(p,\"w\").write(\"x\")'" "マーカー行に書き込み先リテラルが無ければ判定不能"
# Codex 2 巡目（2026-09-17）: 引用符付きの密着リダイレクト / プログラム内の複数書き込み先 /
# override 区間の後ろの書き込み / パイプ・background・条件付きの cd
k_deny 'echo x >"README.md"' "引用符付きの密着リダイレクト"
k_deny "python3 -c 'open(\"$TEST_OUT/d\",\"w\"); open(\"README.md\",\"w\")'" "最初の書き込み先がツリー外でも後続のツリー内書き込みで止める（同一行）"
K_POS_TWO="$(printf 'python3 - <<%sPY%s\nopen("%s/d","w")\nopen("README.md","w")\nPY\n' "'" "'" "$TEST_OUT")"
k_deny "$K_POS_TWO" "最初の書き込み先がツリー外でも後続のツリー内書き込みで止める（別行）"
k_deny "FF_REVIEW_LOCK_OVERRIDE=1 touch README.md; rm src/app.txt" "override 付き区間の後ろの override 無し書き込みは止める"
k_deny "FF_REVIEW_LOCK_OVERRIDE=1 tee README.md; touch src/app.txt" "override 付き区間で走査を打ち切らない"
k_deny "printf x | cd /tmp; touch README.md" "パイプ内の cd は親へ漏れない"
k_deny "cd /tmp & touch README.md" "background の cd は親へ漏れない"
k_deny "false && cd /tmp; touch README.md" "条件付き（&&）の cd は基準不明にする（deny 側）"
k_deny "true || cd /tmp; touch README.md" "条件付き（||）の cd は基準不明にする（deny 側）"
k_deny "true && cd $TEST_OUT; echo x > f" "条件付き cd の後の相対パスは判定不能（ツリー外へ動いたつもりでも止める）"
k_deny "node -e 'require(\"fs\").writeFileSync(path.join(a,b),\"x\")'" "書き込み先が式ならリテラルで許可しない（判定不能）"
K_POS_GLUED="$(printf 'cat <<EOF>README.md\nx\nEOF\n')"
k_deny "$K_POS_GLUED" "heredoc の opener に密着したリダイレクト"
k_deny "$K_POS_NOTES" "cat <<EOF > notes.md（ツリー内へのメモ書きは止める。本文の git ではなくリダイレクトが理由）"
case "$REASON" in
  *'リダイレクト'*) ok "(k) notes.md への deny の理由はリダイレクト（git commit の綴りではない）" ;;
  *) bad "(k) notes.md への deny の理由が違う: [$REASON]" ;;
esac
# 負の対照（走行中 → 無音）
k_silent "tee $TEST_OUT/draft.md" "ツリー外への tee（下書き）"
k_silent "node -e 'require(\"fs\").writeFileSync(\"$TEST_OUT/d\",\"x\")'" "マーカーの対象引数（\"fs\" ではなく書き込み先）で判定する"
k_silent "python3 -c 'open(\"$TEST_OUT/a\",\"w\"); open(\"$TEST_OUT/b\",\"w\")'" "複数の書き込み先がすべてツリー外なら通す"
k_silent "FF_REVIEW_LOCK_OVERRIDE=1 tee README.md; FF_REVIEW_LOCK_OVERRIDE=1 touch src/app.txt" "全区間に override が付いていれば通す"
k_silent "tee $TEST_OUT/x >/dev/null" "ツリー外への tee + >/dev/null（リダイレクト語を引数と誤認しない）"
k_silent "tee $TEST_OUT/x < README.md" "ツリー外への tee + < README.md（入力リダイレクトを対象と誤認しない）"
k_silent "rm -rf /tmp/x 2>/dev/null" "ツリー外の rm + 2>/dev/null"
k_silent "mkdir -p $TEST_OUT/a 2>/dev/null" "ツリー外の mkdir + 2>/dev/null"
k_silent "cp README.md $TEST_OUT/ 2>&1" "ツリー外への cp + 2>&1"
k_silent "FF_REVIEW_LOCK_OVERRIDE=1 echo x > README.md" "リダイレクトでも区間先頭の override が効く"
k_silent "D=\$(mktemp -d) && echo x > \$D/a.md" "引用符なしの mktemp -d 代入"
k_silent "D=\$(mktemp) && echo x > \$D" "引用符なしの mktemp 代入（ファイル）"
k_silent "python3 -c 'open(\"$TEST_OUT/draft.md\",\"w\").write(\"x\")'" "マーカー行の書き込み先リテラルがツリー外"
k_silent "echo 'sleep 1 & touch README.md; text'" "引用文字列の中の & と ; は区切らない"
k_silent "cd /tmp; touch draft.md" "cd の後の相対パスは cd 先で解決（ツリー外）"
k_silent "echo \"cost: \$(date)\"" "書き込みを含まないコマンド置換"
k_silent "perl -pe 's/a/b/' README.md" "perl -pe（i を含まないクラスタ）は読み取り"
k_silent "perl -ne 'print' README.md" "perl -ne は読み取り"
k_silent "perl -Mstrict -e 'print 1'" "-M のモジュール名に i があっても in-place ではない"
k_silent "python3 < read.py" "< で流す読み取り専用の script"
k_silent "awk '{ if (\$1 > 5) print }' README.md" "awk の比較演算子 > はリダイレクトではない"
k_silent "cd $TEST_OUT; echo x > \$PWD/f" "cd の後の \$PWD は cd 先"
k_silent "git stash list" "read-only な git（サブシェル走査側でも名簿外）"
k_silent "bash -c 'git status'" "sh -c の内側の read-only な git"
k_silent "sort README.md" "-o の無い sort"
k_silent "tar -tf $TEST_OUT/a.tar" "tar -t は読み取り"
k_silent "gzip -c README.md > $TEST_OUT/x.gz" "gzip -c は stdout（リダイレクト先はツリー外）"
K_NEG_MULTI="$(printf 'echo "a\nb"; ls\n')"
k_silent "$K_NEG_MULTI" "引用符が行をまたぐ読み取り専用コマンド"
k_silent "$K_NEG_BODY" "ツリー外へのメモ書き（本文に sed -i / tee の綴り）"
k_silent "echo x > /dev/null" "/dev/null"
k_silent "ls 2>/dev/null" "2>/dev/null"
k_silent "ls 2>&1" "2>&1 は fd 複製"
k_silent "echo x >&2" ">&2 は fd 複製"
k_silent "ls 2>&1 | tee $TEST_OUT/log" "パイプ先の tee がツリー外"
k_silent "sed -n '1,5p' README.md" "sed -n は読み取り"
k_silent "sed 's/a/b/' README.md" "-i の無い sed は読み取り"
k_silent "python3 -c 'print(1)'" "読み取り専用の python3 -c"
k_silent "python3 -c 'print(1 > 0)'" "引用文字列の中の > はリダイレクトではない"
k_silent "node -e 'console.log(1)'" "読み取り専用の node -e"
k_silent "$K_NEG_READ" "読み取りだけの heredoc プログラム（open の r モード）"
k_silent "python3 read.py" "読み取りだけの script ファイル"
k_silent "grep -r x . > $TEST_OUT/out" "検索結果をツリー外へ"
k_silent "$K_NEG_GH" "PR 本文の heredoc に sed -i の綴り（データ）"
k_silent "git status" "read-only な git"
k_silent "tee $REPO/.review-results/x.md" "レビュー出力先への tee（絶対パス）"
k_silent "echo x > .review-results/x.md" "レビュー出力先へのリダイレクト（相対パス）"
k_silent "rm -rf /tmp/x" "ツリー外の rm -rf"
k_silent "rm -rf $TEST_OUT/*" "glob の手前で切ってディレクトリ部分で判定"
k_silent "mkdir -p $TEST_OUT/a/b" "ツリー外の mkdir"
k_silent "cp README.md $TEST_OUT/c.md" "cp の移動先がツリー外（移動元は読むだけ）"
k_silent "bash -c 'echo x > /dev/null'" "bash -c の再帰走査で /dev/null"
k_silent "$K_NEG_SHDOC" "bash の heredoc プログラム内の cd 追跡（ツリー外）"
k_silent "cd $TEST_OUT && echo x > f" "cd でツリー外へ出た後の相対パス"
k_silent "O=$TEST_OUT; echo x > \"\$O/draft.md\"" "コマンド内の代入（ツリー外）を展開"
k_silent 'D="$(mktemp -d)"; tee "$D/x"' "mktemp -d の代入は一時領域（ツリー外）とみなす"
k_silent "mktemp" "引数無しの mktemp"
k_silent "mktemp -p $TEST_OUT" "ツリー外の mktemp -p"
k_silent "npm test" "ビルド・テストツールは対象外"
k_silent "curl -s https://example.com" "-o の無い curl"
k_silent "python3 --version" "バージョン表示だけのインタプリタ"
k_silent "echo 'a > b'" "引用文字列の中の >"
k_silent "echo FF_REVIEW_LOCK_OVERRIDE=1 && tee $TEST_OUT/x" "抜け道の綴りをデータとして出すだけ"
k_silent "FF_REVIEW_LOCK_OVERRIDE=1 tee README.md" "区間先頭の FF_REVIEW_LOCK_OVERRIDE=1 で通る（git 以外にも効く）"
run_hook "$(bash_json_at "tee README.md" "$REPO")" 'FF_REVIEW_LOCK_OVERRIDE=1'
assert_silent "(k) セッション環境の FF_REVIEW_LOCK_OVERRIDE=1 で通る"
# マーカー走査の grep が失敗する回（seam）は「マーカー無し」ではなく判定不能 → deny
run_hook "$(bash_json_at "$K_POS_1" "$REPO")" 'FF_WRITE_SCAN_GREP=/nonexistent/grep'
assert_deny "(k) マーカー走査の grep が失敗すると判定不能として deny（マーカー無しに畳まない）"
case "$REASON" in
  *'grep'*) ok "(k) grep 失敗の理由文がその旨を出す" ;;
  *) bad "(k) grep 失敗の理由文が違う: [$REASON]" ;;
esac
run_hook "$(bash_json_at "tee $TEST_OUT/x" "$REPO")" 'FF_WRITE_SCAN_GREP=/nonexistent/grep'
assert_silent "(k) grep 失敗でもマーカー走査に到達しないコマンドは影響を受けない"
run_hook "$(bash_json_at "echo x > README.md" "$REPO")" 'FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1'
assert_silent "(k) opt-out で無音"
# cwd がリポジトリへの symlink でも物理パスで判定する
ln -s "$REPO" "$TEST_TMP/repo-link"
k_silent "tee $TEST_OUT/x" "symlink 経由の cwd からツリー外への tee は無音" "$TEST_TMP/repo-link"
k_deny "tee README.md" "symlink 経由の cwd からツリー内への tee は deny（物理パスで判定）" "$TEST_TMP/repo-link"
# レーンだけが生きている状態でも同じ deny
clear_lock
run_hook "$(agent_json pr-review-toolkit:code-reviewer Agent k-lane-1)"
k_deny "tee README.md" "レーンだけが生きている状態でも Bash 書き込みは deny"
run_hook "$(subagent_start_json pr-review-toolkit:code-reviewer k-agent-1)"
run_hook "$(subagent_stop_json pr-review-toolkit:code-reviewer k-agent-1)"
clear_lanes
# stale ロックは警告のみ
write_lock "$DEAD_PID"
run_hook "$(bash_json_at "echo x > README.md" "$REPO")"
assert_warn_only "(k) stale なロックでは Bash 書き込みも警告のみ（deny しない）"
clear_lock
# ロック無しでは正例が全件無音（走査はロックがあるときだけ払うコスト）
k_nolock_bad=0
for k_cmd in "$K_POS_1" "sed -i '' 's/a/b/' README.md" "tee README.md" "echo x > README.md" "rm README.md" \
  "python3 patch.py" "python3 missing.py" 'echo x > "$UNSET_VAR_FF_1710/x"' "$K_POS_UNTERM" "bash -c 'echo x > f'" \
  "true & touch README.md" 'eval "rm README.md"'; do
  run_hook "$(bash_json_at "$k_cmd" "$REPO")"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then :; else k_nolock_bad=$((k_nolock_bad + 1)); bad "(k) ロック無しなのに出力あり: cmd=[$(printf '%s' "$k_cmd" | head -1)] out=[$OUT]"; fi
done
[ "$k_nolock_bad" -eq 0 ] && ok "(k) ロック無しでは Bash 書き込みの正例 12 件がすべて無音（判定不能形を含む）"
# 共有ライブラリが無いコピー: 走行中 + Bash コマンドは判定不能として deny、ロック無しは無音
# （heredoc 除去ヘルパ不在 / 書き込み走査ライブラリ不在の 2 通り）
K_COPY="$TEST_TMP/k-nohelper"
mkdir -p "$K_COPY/hooks" "$K_COPY/tests/lib"
cp "$TARGET" "$K_COPY/hooks/guard-review-in-flight.sh"
cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$K_COPY/hooks/"
cp "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$K_COPY/hooks/" 2>/dev/null || true
cp "$PLUGIN_ROOT/tests/lib/review-write-scan.sh" "$K_COPY/tests/lib/"
K_COPY2="$TEST_TMP/k-noscanlib"
mkdir -p "$K_COPY2/hooks" "$K_COPY2/tests/lib"
cp "$TARGET" "$K_COPY2/hooks/guard-review-in-flight.sh"
cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$K_COPY2/hooks/"
cp "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$K_COPY2/hooks/" 2>/dev/null || true
cp "$PLUGIN_ROOT/tests/lib/heredoc-strip.sh" "$K_COPY2/tests/lib/"
write_lock "$LIVE_PID"
K_OUT="$(printf '%s' "$(bash_json_at "tee $TEST_OUT/x" "$REPO")" | bash "$K_COPY/hooks/guard-review-in-flight.sh" 2>/dev/null)"
case "$(printf '%s' "$K_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" in
  deny) ok "(k) heredoc 除去ヘルパが無いと走行中の Bash コマンドは判定不能として deny（ツリー外でも）" ;;
  *) bad "(k) ヘルパ不在で素通し: out=[$K_OUT]" ;;
esac
K_OUT="$(printf '%s' "$(bash_json_at "tee $TEST_OUT/x" "$REPO")" | bash "$K_COPY2/hooks/guard-review-in-flight.sh" 2>/dev/null)"
case "$(printf '%s' "$K_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)" in
  *'走査ライブラリ'*) ok "(k) 書き込み走査ライブラリが無いと走行中の Bash コマンドは判定不能として deny（理由にライブラリの不在を出す）" ;;
  *) bad "(k) 走査ライブラリ不在で素通し / 理由が違う: out=[$K_OUT]" ;;
esac
K_OUT="$(printf '%s' "$(bash_json_at "git status" "$REPO")" | bash "$K_COPY2/hooks/guard-review-in-flight.sh" 2>/dev/null)"
case "$(printf '%s' "$K_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" in
  deny) ok "(k) 走査ライブラリ不在では走行中の read-only な git も判定不能として止まる（fail-closed の面は走行中の全 Bash）" ;;
  *) bad "(k) 走査ライブラリ不在で git status が素通し: out=[$K_OUT]" ;;
esac
clear_lock
K_OUT="$(printf '%s' "$(bash_json_at "tee $TEST_OUT/x" "$REPO")" | bash "$K_COPY/hooks/guard-review-in-flight.sh" 2>/dev/null)"
[ -z "$K_OUT" ] && ok "(k) ヘルパ不在でもロック無しは無音（fail-open 経路は変えない）" || bad "(k) ヘルパ不在 + ロック無しで出力: [$K_OUT]"
K_OUT="$(printf '%s' "$(bash_json_at "tee README.md" "$REPO")" | bash "$K_COPY2/hooks/guard-review-in-flight.sh" 2>/dev/null)"
[ -z "$K_OUT" ] && ok "(k) 走査ライブラリ不在でもロック無しは無音" || bad "(k) 走査ライブラリ不在 + ロック無しで出力: [$K_OUT]"
rm -f "$REPO/patch.py" "$REPO/read.py" "$REPO/fix.js" "$REPO/fix.sh" "$REPO/patch2"

echo "guard-review-in-flight: (m) 指紋に映らない書き込み先は止めない（Issue \`#1756\`）"
# 走行中に止める根拠は「レビュー対象の指紋が動くこと」。指紋（adapter-common.sh の
# capture_repo_snapshot）は status / diff HEAD / diff --cached / ls-files --exclude-standard の
# 4 つで、**ignored とツリー外はそのどれにも現れない**。ツール経路ではなく書き込み先で
# 判定する面を、編集系ツールと Bash の両方で固定する。
write_json() { # <file_path> [cwd]
  jq -n --arg f "$1" --arg d "${2:-$REPO}" \
    '{tool_name: "Write", tool_input: {file_path: $f, content: "x"}, cwd: $d, hook_event_name: "PreToolUse"}'
}
m_silent() { # <json> <label>
  run_hook "$1"
  assert_silent "(m) $2"
}
m_deny() { # <json> <label>
  run_hook "$1"
  assert_deny "(m) $2"
}
clear_lanes
clear_lock
write_lock "$LIVE_PID"

# --- 編集系ツール（報告された過剰 deny の本体）---
m_silent "$(write_json "$REPO/build/note.md")" "Write: gitignore 済みのツリー内パスは止めない"
m_silent "$(write_json "build/note.md")" "Write: 相対パスの gitignore 済みも止めない（cwd 基準で解決する）"
m_silent "$(write_json "$TEST_OUT/note.md")" "Write: 作業ツリーの外（scratchpad 相当）は止めない"
m_deny "$(write_json "$REPO/src/app.txt")" "対: tracked なファイルへの Write は従来どおり止まる"
m_deny "$(write_json "$REPO/src/new.txt")" "対: ignored でない未作成パスへの Write も止まる（指紋の untracked 出現に映る）"
# `.git/` は check-ignore が「ignored ではない」と答える（rc=1）。HEAD / ブランチは指紋の
# 一部なので、ここが免除側へ倒れると指紋そのものを書き換えられる。
m_deny "$(write_json "$REPO/.git/HEAD")" "対: .git 配下は ignored ではないので止まる（指紋の HEAD / ブランチを守る）"
# ignore パターンに当たっても **tracked** なら指紋に出る（status / diff HEAD が見る）。
# `git check-ignore` は既定で index を見るのでここは rc 1 になる。判定へ `--no-index` を
# 足すと純粋なパターン照合へ倒れ、この行が緑のまま fail-open になる。
m_deny "$(write_json "$REPO/cache/keep.txt")" "対: ignore パターンに当たる tracked ファイルは止まる（check-ignore が index を見ることに依存）"
# 編集系ツールの他の名前でも同じ面を通ること（免除が Write 限定にならない）
run_hook "$(jq -n --arg f "$REPO/build/note.md" --arg d "$REPO" \
  '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: []}, cwd: $d, hook_event_name: "PreToolUse"}')"
assert_silent "(m) MultiEdit でも同じ判定面を通る"
# **`NotebookEdit` は `file_path` を持たない** — パラメータは `notebook_path`（ツール
# schema）。`file_path` を組み立てた payload はハーネスが出さない形で、hook のどの分岐にも
# 当たらないまま緑になる（針が当たらない入力）。実在する形で測る。
notebook_json() { # <notebook_path>
  jq -n --arg f "$1" --arg d "$REPO" \
    '{tool_name: "NotebookEdit", tool_input: {notebook_path: $f, new_source: "x"}, cwd: $d, hook_event_name: "PreToolUse"}'
}
run_hook "$(notebook_json "$REPO/build/nb.ipynb")"
assert_silent "(m) NotebookEdit（notebook_path）でも同じ判定面を通る"
run_hook "$(notebook_json "$REPO/src/app.txt")"
assert_deny "(m) 対: NotebookEdit の notebook_path がツリー内なら止まる（空の file_path で素通ししていない）"
run_hook "$(notebook_json "$REPO/.review-results/claude-code/out.ipynb")"
assert_silent "(m) NotebookEdit も出力先へは書ける（委譲レビューの自己デッドロック回避）"

# --- 末端 symlink: 免除はリンク名ではなくリンク先で決まる ---
# ignored な名前の symlink が tracked を指すと、書き込みは tracked へ届いて指紋が動く
# （実測: ignored な symlink 経由の追記で `git diff HEAD` に tracked が出た）。
ln -sf "$REPO/src/app.txt" "$REPO/build/escape.txt"
printf 'plain\n' > "$REPO/build/plain.txt"
ln -sf "$REPO/build/plain.txt" "$REPO/build/toignored.txt"
ln -sf "$REPO/nowhere/missing.txt" "$REPO/build/broken.txt"
ln -sf "$REPO/src/app.txt" "$TEST_OUT/outside-escape.txt"
m_deny "$(write_json "$REPO/build/escape.txt")" "symlink: ignored な名前でもリンク先が tracked なら止まる"
m_silent "$(write_json "$REPO/build/toignored.txt")" "symlink: リンク先も ignored なら止めない"
m_deny "$(write_json "$REPO/build/broken.txt")" "symlink: 解決できない（壊れた）リンクは止まる"
m_deny "$(write_json "$TEST_OUT/outside-escape.txt")" "symlink: ツリー外の名前でもリンク先が tracked なら止まる"
k_deny "tee $REPO/build/escape.txt" "symlink: Bash 経路でも ignored な名前のリンク先で判定する"

# --- Bash 経路（2026-09-18 の実測形: gh の出力を ignored なパスへ受ける）---
k_silent "gh pr view 3019 --json body --jq .body > build/body.md" "gh の出力を gitignore 済みパスへリダイレクトできる"
k_silent "tee build/body.md" "tee で gitignore 済みパスへ書ける"
k_deny "tee src/app.txt" "対: ignored でないツリー内への tee は従来どおり止まる"

# --- 緩めていない側（判定不能は deny のまま）---
m_deny "$(write_json "")" "判定不能: file_path が空の編集系ツールは従来どおり止まる"
k_deny 'echo x > "$UNSET_VAR_FF_1756/note.md"' "判定不能: 変数展開の書き込み先は ignored かどうか以前に止まる"
k_deny 'echo x > "$(printf build)/note.md"' "判定不能: コマンド置換の書き込み先は止まる（ignored へ解決しうる形でも）"

# --- ignored 判定そのものが失敗する回は deny 側（fail-closed の実測）---
# 差し替え口 FF_WRITE_SCAN_GIT で `git check-ignore` を起動不能にする。rc 0 以外をすべて
# 「ignored ではない」へ倒しているので、判定できない回は緩まない。
run_hook "$(write_json "$REPO/build/note.md")" 'FF_WRITE_SCAN_GIT=/nonexistent/git'
assert_deny "(m) check-ignore を起動できない回は ignored と読まずに deny（判定不能を許可側へ倒さない）"
run_hook "$(bash_json_at "tee build/body.md" "$REPO")" 'FF_WRITE_SCAN_GIT=/nonexistent/git'
assert_deny "(m) Bash 経路でも check-ignore 不能なら deny"
run_hook "$(write_json "$TEST_OUT/note.md")" 'FF_WRITE_SCAN_GIT=/nonexistent/git'
assert_silent "(m) check-ignore 不能でも、ツリー外の判定はそれ以前に決まるので影響を受けない"

# --- 走査ライブラリを読めない編集系ツールは deny（Bash 経路と同じ fail-closed）---
M_OUT="$(printf '%s' "$(write_json "$REPO/build/note.md")" | bash "$K_COPY2/hooks/guard-review-in-flight.sh" 2>/dev/null)"
case "$(printf '%s' "$M_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)" in
  *'走査ライブラリ'*) ok "(m) 走査ライブラリが無いと ignored なパスへの Write も判定不能として deny（理由にライブラリの不在を出す）" ;;
  *) bad "(m) 走査ライブラリ不在で素通し / 理由が違う: out=[$M_OUT]" ;;
esac

# --- ロック無しでは (m) の deny 例も全件無音（fail-open 経路を変えない）---
clear_lock
run_hook "$(write_json "$REPO/src/app.txt")"
assert_silent "(m) ロック無しでは tracked への Write も無音"
run_hook "$(write_json "$REPO/build/note.md")" 'FF_WRITE_SCAN_GIT=/nonexistent/git'
assert_silent "(m) ロック無しでは check-ignore 不能でも無音"
rm -rf "$REPO/build/note.md" "$REPO/build/nb.ipynb"

# ---------------------------------------------------------------------------
# (n) 巡回カウンタ（tests/lib/review-round-counter.sh）。上限を超える巡の起動を deny し、
# 記録が無い・読めない回は「判定不能 = 通す + 警告」。ここから先は既定値（上限 2）で測るので、
# 冒頭で 0（無効）へ固定した FF_REVIEW_ROUND_LIMIT を区間ごとに外す（`env -u`）。
# ---------------------------------------------------------------------------
echo "guard-review-in-flight: (n) 巡回カウンタ（上限 2 巡 / 3 巡目の起動を deny）"
clear_lock
clear_lanes
git -C "$REPO" add -A
git -C "$REPO" commit -q --allow-empty -m "n: baseline"
# 巡は PR のブランチで数える（統合ブランチ上は判定不能 = 数えない。(n13)）。fixture の初期
# ブランチ名は git の既定（main / master）に依るので、PR 相当のブランチへ移ってから測る。
N_BASE_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
git -C "$REPO" branch n-base
git -C "$REPO" switch -q -c feature/n-rounds
N_DEF='-u FF_REVIEW_ROUND_LIMIT'
# 記録は git common dir 配下（出力先 `.review-results/` の外）。レーン置き場を消しても残る。
N_ROUNDS_DIR="$REPO/.git/ff-review-rounds"
n_reset() { clear_lanes; rm -rf "$N_ROUNDS_DIR"; }
n_file() { ls -1 "$N_ROUNDS_DIR"/*.tsv 2>/dev/null | head -n 1; }
n_heads() { # 記録の異なる HEAD の数
  local f
  f="$(n_file)"
  [ -n "$f" ] || { printf '0'; return 0; }
  awk -F '\t' 'NR > 1 && NF == 3 { s[$2] = 1 } END { n = 0; for (k in s) n++; print n }' "$f"
}
n_commit() { git -C "$REPO" commit -q --allow-empty -m "$1"; }
# 起動は隔離（isolation=worktree）を既定にする。隔離起動もレーンを取らないだけで巡としては
# 数えるので、同じ区間の Bash 起動が凍結（レーン）に当たらず、巡回の判定だけを観測できる。
n_agent() { agent_json "$1" Agent "" worktree; }
ack_agent_json() { # <prompt>
  jq -n --arg d "$REPO" --arg p "$1" \
  '{tool_name: "Agent", tool_input: {subagent_type: "pr-review-toolkit:code-reviewer", description: "review", prompt: $p, isolation: "worktree"},
    cwd: $d, hook_event_name: "PreToolUse"}'; }
assert_n_deny() { # <label>
  case "$REASON" in
    *'レビュー巡回の上限'*) assert_deny "$1" ;;
    *) bad "$1: 巡回上限の deny ではない: decision=[$DECISION] out=[$OUT]" ;;
  esac
}

# --- 記録が無い（初回 / 消えた）: 0 巡と見なさず、通す + 警告 + 1 巡目として記録 ---
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
case "$MESSAGE" in
  *'巡回の記録がありません'*'1 巡目として記録'*)
    if [ -z "$DECISION" ] && [ "$(n_heads)" = "1" ]; then
      ok "(n1) 記録が無い回は判定不能 = 通す + 警告し、この起動を 1 巡目として記録する"
    else
      bad "(n1) 記録不在の回の扱いが違う: decision=[$DECISION] heads=[$(n_heads)]"
    fi
    ;;
  *) bad "(n1) 記録が無い回に警告が出ない（0 巡と見なして黙って通した）: out=[$OUT]" ;;
esac

# --- 同じ HEAD の起動は同じ巡（並列起動の 2 本目・--resume・委譲のホスト側起動）---
run_hook "$(n_agent pr-review-toolkit:silent-failure-hunter)" "$N_DEF"
assert_silent "(n2) 記録済みの HEAD で起動した 2 本目は同じ巡として無音"
run_hook "$(bash_json 'bash scripts/multi-review.sh --base main')" "$N_DEF"
assert_silent "(n2) 同じ HEAD の Bash 起動（multi-review.sh）も同じ巡"
run_hook "$(n_agent pr-review-toolkit:pr-test-analyzer)" "$N_DEF"
if [ "$(n_heads)" = "1" ]; then ok "(n2) 同じ巡を何本起動しても数えるのは 1 巡（行数でなく異なる HEAD の数）"; else bad "(n2) 同じ HEAD が複数の巡に数えられた: heads=[$(n_heads)]"; fi

# --- fix を commit して 2 巡目: 上限内なので無音で記録 ---
n_commit "fix round 1"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
assert_silent "(n3) 2 巡目（上限内）の起動は無音"
if [ "$(n_heads)" = "2" ]; then ok "(n3) 2 巡目が記録される"; else bad "(n3) 2 巡目が記録されない: heads=[$(n_heads)]"; fi

# --- 2 巡目の fix の後: 3 巡目の起動を deny（レーンを取らない）---
n_commit "fix round 2"
N_LANES_BEFORE="$(lane_count)"
run_hook "$(agent_json pr-review-toolkit:code-reviewer "" n3-agent)" "$N_DEF"
assert_n_deny "(n4) 2 巡目の fix の後の 3 巡目（Agent 起動）を deny する"
case "$REASON" in
  *'3 巡目'*'/out-of-scope-issue'*'bundle'*'FF_REVIEW_ROUND_ACK=1'*) ok "(n4) deny 文が 3 巡目・bundle 統合への案内・1 回限りの通過口を出す" ;;
  *) bad "(n4) deny 文に案内が欠けている: reason=[$REASON]" ;;
esac
if [ "$(lane_count)" = "$N_LANES_BEFORE" ] && [ "$(n_heads)" = "2" ]; then
  ok "(n4) deny した起動（非隔離）はレーンも巡も残さない"
else
  bad "(n4) deny した起動がレーン / 巡を残した: lanes ${N_LANES_BEFORE}→$(lane_count) heads=[$(n_heads)]"
fi
run_hook "$(agent_json pr-review-toolkit:code-reviewer Agent n3-iso worktree)" "$N_DEF"
assert_n_deny "(n4) isolation=worktree の隔離起動も巡として数える（隔離既定の経路でゲートが空にならない）"
run_hook "$(bash_json 'FF_DEV_TOOLKIT_ROOT="/x" bash "/x/scripts/multi-review.sh" --base main')" "$N_DEF"
assert_n_deny "(n4) Bash の multi-review.sh 起動（環境代入 + 引用付きパス）も deny"
run_hook "$(bash_json 'bash /x/scripts/multi-agent.sh --task review --cli codex-cli')" "$N_DEF"
assert_n_deny "(n4) multi-agent.sh --task review（Codex 1 レーン）も deny"
run_hook "$(bash_json 'bash /x/scripts/codex-review.sh --base develop')" "$N_DEF"
assert_n_deny "(n4) codex-review.sh シムの起動も deny"

# --- レビューの起動ではないものは数えない ---
run_hook "$(bash_json 'grep -n review scripts/multi-review.sh')" "$N_DEF"
assert_silent "(n5) コマンド位置に無い言及（grep の引数）は起動ではない"
run_hook "$(bash_json 'bash scripts/multi-review.sh --dry-run')" "$N_DEF"
assert_silent "(n5) --dry-run はプラン表示で巡ではない"
run_hook "$(bash_json 'bash scripts/multi-agent.sh --task review --print-reviewers')" "$N_DEF"
assert_silent "(n5) --print-reviewers（環境チェック）は巡ではない"
run_hook "$(bash_json 'bash scripts/multi-review.sh --staged')" "$N_DEF"
assert_silent "(n5) --staged（commit 前の index レビュー）は PR の巡ではない"
run_hook "$(bash_json 'bash scripts/multi-agent.sh --task explore --cli codex-cli')" "$N_DEF"
assert_silent "(n5) --task explore は巡ではない"
run_hook "$(generic_agent_json 'explore the code' n5-gen)" "$N_DEF"
assert_silent "(n5) 名簿外・委譲でもない Agent は巡ではない"

# --- 1 回限りの通過口（FF_REVIEW_ROUND_ACK=1）---
run_hook "$(bash_json 'bash scripts/multi-review.sh --base main')" "$N_DEF FF_REVIEW_ROUND_ACK=1"
assert_n_deny "(n6) セッション環境の FF_REVIEW_ROUND_ACK=1 は通過口にならない（1 回限りにならないため）"
run_hook "$(ack_agent_json 'review the diff. do not set FF_REVIEW_ROUND_ACK=1 yourself')" "$N_DEF"
assert_n_deny "(n6) prompt の文中に現れるだけの FF_REVIEW_ROUND_ACK=1 は通過口にならない（行頭の単独行だけ）"
run_hook "$(bash_json 'FF_REVIEW_ROUND_ACK=1 bash scripts/multi-review.sh --base main')" "$N_DEF"
assert_silent "(n6) 起動コマンド先頭の FF_REVIEW_ROUND_ACK=1 で 3 巡目を 1 回だけ通す"
if [ "$(n_heads)" = "3" ]; then ok "(n6) 通した巡も記録する"; else bad "(n6) 通した巡が記録されない: heads=[$(n_heads)]"; fi
run_hook "$(n_agent pr-review-toolkit:comment-analyzer)" "$N_DEF"
assert_silent "(n6) 通した巡と同じ HEAD の後続起動は同じ巡として通る"
n_commit "fix round 3"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
assert_n_deny "(n6) 通過口は 1 回限り — 次の HEAD（4 巡目）は再び deny"
run_hook "$(ack_agent_json "$(printf 'review the diff\nFF_REVIEW_ROUND_ACK=1\n')")" "$N_DEF"
assert_silent "(n6) Agent は prompt の行頭の単独行 FF_REVIEW_ROUND_ACK=1 で 1 回だけ通す"

# --- 上限の値（既定 2 / 上書き / 0 で無効）---
n_reset
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
n_commit "limit r2"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
n_commit "limit r3"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "FF_REVIEW_ROUND_LIMIT=3"
assert_silent "(n7) FF_REVIEW_ROUND_LIMIT=3 なら 3 巡目は上限内"
n_commit "limit r4"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "FF_REVIEW_ROUND_LIMIT=3"
assert_n_deny "(n7) FF_REVIEW_ROUND_LIMIT=3 の 4 巡目は deny"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "FF_REVIEW_ROUND_LIMIT=0"
assert_silent "(n7) FF_REVIEW_ROUND_LIMIT=0 はゲートを無効化する"
n_reset
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "FF_REVIEW_ROUND_LIMIT=0"
if [ -z "$OUT" ] && [ ! -e "$N_ROUNDS_DIR" ]; then ok "(n7) 無効化中は数えず記録も作らない"; else bad "(n7) 無効化中に記録・出力がある: out=[$OUT]"; fi

# --- 記録が読めない: 通す + 警告、記録は書き換えない ---
n_reset
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
N_F="$(n_file)"
printf 'garbage line\n' >> "$N_F"
N_SUM_BEFORE="$(cksum < "$N_F")"
n_commit "unreadable r2"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
case "$MESSAGE" in
  *'巡回の記録を読めません'*)
    if [ -z "$DECISION" ] && [ "$(cksum < "$N_F")" = "$N_SUM_BEFORE" ]; then
      ok "(n8) 書式の壊れた記録は判定不能 = 通す + 警告し、記録を書き換えない"
    else
      bad "(n8) 壊れた記録の扱いが違う: decision=[$DECISION]"
    fi
    ;;
  *) bad "(n8) 壊れた記録で警告が出ない: out=[$OUT]" ;;
esac
if [ "$(id -u)" != "0" ]; then
  n_reset
  run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
  N_F="$(n_file)"
  chmod 000 "$N_F"
  n_commit "unreadable r3"
  run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
  chmod 600 "$N_F"
  case "$MESSAGE" in
    *'巡回の記録を読めません'*) [ -z "$DECISION" ] && ok "(n8) 読み取り権限の無い記録も判定不能 = 通す + 警告" || bad "(n8) 読めない記録で deny した: out=[$OUT]" ;;
    *) bad "(n8) 読めない記録で警告が出ない: out=[$OUT]" ;;
  esac
else
  ok "(n8) root 実行のため読み取り権限の検査は省略（書式違反の検査で同じ分岐を測っている）"
fi

# --- detached HEAD: PR を特定できないので通す + 警告 ---
n_reset
N_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
git -C "$REPO" checkout -q --detach
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
git -C "$REPO" checkout -q "$N_BRANCH"
case "$MESSAGE" in
  *'detached HEAD'*) [ -z "$DECISION" ] && ok "(n9) detached HEAD は判定不能 = 通す + 警告" || bad "(n9) detached HEAD で deny した: out=[$OUT]" ;;
  *) bad "(n9) detached HEAD で警告が出ない: out=[$OUT]" ;;
esac

# --- 残件数の受け口: FF_JEV_MODE=off（既定）では畳み込み後の件数を読まない（バイト同一）---
n_reset
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
n_commit "jev r2"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
n_commit "jev r3"
N_F="$(n_file)"
N_RES="${N_F%.tsv}.residual"
printf 'raw=5\n' > "$N_RES"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF -u FF_JEV_MODE"
N_REASON_RAW="$REASON"
printf 'raw=5\nfolded=3\n' > "$N_RES"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF -u FF_JEV_MODE"
N_REASON_UNSET="$REASON"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF FF_JEV_MODE=off"
N_REASON_OFF="$REASON"
case "$N_REASON_RAW" in
  *'残件: 5 件'*) ok "(n10) 残件数（raw）を deny 文へ載せる" ;;
  *) bad "(n10) 残件数が deny 文に無い: reason=[$N_REASON_RAW]" ;;
esac
if [ -n "$N_REASON_RAW" ] && [ "$N_REASON_UNSET" = "$N_REASON_RAW" ] && [ "$N_REASON_OFF" = "$N_REASON_RAW" ]; then
  ok "(n10) FF_JEV_MODE 未設定 / off では畳み込み後の件数を読まず、deny 文がバイト同一"
else
  bad "(n10) off で畳み込みの有無が deny 文を変えた: raw=[$N_REASON_RAW] unset=[$N_REASON_UNSET] off=[$N_REASON_OFF]"
fi
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF FF_JEV_MODE=on"
case "$REASON" in
  *'残件: 3 件（重複 finding の畳み込み後）'*) ok "(n10) FF_JEV_MODE=on かつ畳み込み後の件数があればそれを使う" ;;
  *) bad "(n10) on で畳み込み後の件数を使わない: reason=[$REASON]" ;;
esac
printf 'raw=5\n' > "$N_RES"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF FF_JEV_MODE=on"
case "$REASON" in
  *'残件: 5 件'*) ok "(n10) FF_JEV_MODE=on でも畳み込み後の件数が無ければ生の件数を使う" ;;
  *) bad "(n10) on で畳み込み後が無いときに生の件数へ落ちない: reason=[$REASON]" ;;
esac

# --- 警告は他の判定（B の ask）と同じ出力へ畳む ---
n_reset
printf 'dirty\n' >> "$REPO/src/app.txt"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
git -C "$REPO" checkout -q -- src/app.txt
case "$MESSAGE" in
  *'巡回の記録がありません'*) [ "$DECISION" = "ask" ] && ok "(n11) 判定不能の警告は dirty の ask と同じ出力へ systemMessage として載る" || bad "(n11) ask が消えた: out=[$OUT]" ;;
  *) bad "(n11) ask の出口で巡回の警告が落ちた: out=[$OUT]" ;;
esac
if [ "$(n_heads)" = "1" ]; then
  ok "(n11) ask の出口は巡を仮記録する（利用者が許可して起動した回を数え損ねない）"
else
  bad "(n11) ask の出口で巡が仮記録されない（許可した起動が上限を迂回する）: heads=[$(n_heads)]"
fi
run_hook "$(n_agent pr-review-toolkit:code-reviewer | jq '.hook_event_name = "PermissionDenied"')" "$N_DEF"
if [ "$(n_heads)" = "0" ]; then
  ok "(n11) 起動が拒否された（PermissionDenied が同じ鍵で来た）回は仮記録を取り消す"
else
  bad "(n11) PermissionDenied で仮記録が取り消されない: heads=[$(n_heads)]"
fi

# --- 並列起動が同じ巡を重複して書いた記録（同時の追記）も 1 巡と数える ---
n_reset
n_commit "dup r1"
N_H1="$(git -C "$REPO" rev-parse HEAD)"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
N_F="$(n_file)"
printf '1\t%s\t0\n1\t%s\t0\n' "$N_H1" "$N_H1" >> "$N_F"
n_commit "dup r2"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
assert_silent "(n2) 同じ HEAD の重複行は 1 巡と数える（行数で数えると 2 巡目が 3 巡目として deny される）"

# --- ライブラリを読めない: agent 経路は判定不能 = 通す + 警告 ---
n_reset
N_OUT="$(printf '%s' "$(n_agent pr-review-toolkit:code-reviewer)" | env -u FF_REVIEW_ROUND_LIMIT bash "$K_COPY2/hooks/guard-review-in-flight.sh" 2>/dev/null)"
case "$(printf '%s' "$N_OUT" | jq -r '.systemMessage // empty' 2>/dev/null)" in
  *'巡回カウンタ'*'読めない'*) ok "(n12) 巡回カウンタのライブラリが無いと、レビュー起動は判定不能として警告付きで通る" ;;
  *) bad "(n12) ライブラリ不在で無音 / 別の出力: out=[$N_OUT]" ;;
esac
N_OUT="$(printf '%s' "$(bash_json 'bash scripts/codex-review.sh --base develop')" | env -u FF_REVIEW_ROUND_LIMIT bash "$K_COPY2/hooks/guard-review-in-flight.sh" 2>/dev/null)"
case "$(printf '%s' "$N_OUT" | jq -r '.systemMessage // empty' 2>/dev/null)" in
  *'巡回カウンタ'*'読めない'*) ok "(n12) ライブラリが無いと、Bash のレビュー起動（codex-review.sh）も判定不能として警告付きで通る" ;;
  *) bad "(n12) ライブラリ不在の Bash 起動が無警告: out=[$N_OUT]" ;;
esac
N_OUT="$(printf '%s' "$(bash_json 'ls -la')" | env -u FF_REVIEW_ROUND_LIMIT bash "$K_COPY2/hooks/guard-review-in-flight.sh" 2>/dev/null)"
[ -z "$N_OUT" ] && ok "(n12) ライブラリが無くても、レビューの起動でない Bash は無音" || bad "(n12) 無関係な Bash に警告が出た: out=[$N_OUT]"
n_reset

# --- 統合ブランチ（develop / main / リモートの既定ブランチ）: PR の巡ではない = 判定不能 → 通す + 警告 ---
n_reset
git -C "$REPO" switch -q -C develop
N_INT_OK=1
for N_I in 1 2 3; do
  n_commit "develop r${N_I}"
  run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
  case "$MESSAGE" in
    *'統合ブランチ develop'*) [ -z "$DECISION" ] || N_INT_OK=0 ;;
    *) N_INT_OK=0 ;;
  esac
done
if [ "$N_INT_OK" -eq 1 ] && [ ! -e "$N_ROUNDS_DIR/develop.tsv" ]; then
  ok "(n13) develop 上の起動は 3 つの HEAD でも deny せず、警告して通し記録しない（PR をまたいで 1 本に数えない）"
else
  bad "(n13) develop 上の起動の扱いが違う: decision=[$DECISION] out=[$OUT]"
fi
git -C "$REPO" remote add origin "https://example.invalid/fixture.git" 2>/dev/null || true
git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
git -C "$REPO" switch -q -C trunk
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
case "$MESSAGE" in
  *'統合ブランチ trunk'*) [ -z "$DECISION" ] && ok "(n13) リモートの既定ブランチ（origin/HEAD → trunk）も統合ブランチとして数えない" || bad "(n13) 既定ブランチで deny: out=[$OUT]" ;;
  *) bad "(n13) リモートの既定ブランチを統合ブランチと見なさない: out=[$OUT]" ;;
esac
git -C "$REPO" switch -q feature/n-rounds

# --- 記録は出力先の外: レーン置き場の rm -rf と multi-agent.sh --fresh の退避を経ても 3 巡目を deny ---
n_reset
n_commit "fresh r1"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
n_commit "fresh r2"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
mkdir -p "$LANE_DIR"
printf 'marker\n' > "$LANE_DIR/marker.lane"
printf 'fresh\n' > "$REPO/src/fresh.txt"
git -C "$REPO" add src/fresh.txt
git -C "$REPO" commit -q -m "fresh r3 (real diff for the orchestrator)"
N_STUB="$TEST_TMP/n-stub"
mkdir -p "$N_STUB"
printf '#!/bin/sh\nexit 1\n' > "$N_STUB/codex"
chmod +x "$N_STUB/codex"
(
  cd "$REPO" || exit 1
  env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u MULTI_AGENT_CONFIG \
    PATH="$N_STUB:$PATH" bash "$MULTI_AGENT" --task review --mode cross-model --cli codex-cli \
    --perspective code-review --base n-base --fresh --timeout 5
) >/dev/null 2>"$TEST_TMP/n-fresh.err" || true
if [ ! -e "$LANE_DIR/marker.lane" ] && grep -q -- '--fresh: archived' "$TEST_TMP/n-fresh.err"; then
  ok "(n14) multi-agent.sh --fresh が出力先（レーン置き場を含む）を実際に退避した"
else
  bad "(n14) --fresh の退避が起きていない（統合検査の前提）: $(tail -n 3 "$TEST_TMP/n-fresh.err")"
fi
clear_lanes
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
assert_n_deny "(n14) --fresh の退避とレーン置き場の rm -rf を経ても、3 巡目の起動を deny する（記録は git common dir 配下）"
clear_lock

# --- 文書に載っている起動形（制御の接頭辞・行継続・ラッパー・--task 無し）も 3 巡目で deny ---
N_DOC_PRE_PUSH="$(printf '%s\n' 'if ! FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" \' '  --output-dir "$FF_REVIEW_OUTPUT" \' '  --cli grok-cli \' '  --sequential; then' '  exit 1' 'fi')"
run_hook "$(bash_json "$N_DOC_PRE_PUSH")" "$N_DEF"
assert_n_deny "(n15) 配布文書の起動形（if ! + 環境代入 + 行継続）も deny"
run_hook "$(bash_json 'bash /x/scripts/multi-agent.sh --base develop')" "$N_DEF"
assert_n_deny "(n15) --task 無しの multi-agent.sh（既定の task は review）も deny"
run_hook "$(bash_json 'timeout 600 bash /x/scripts/multi-review.sh --base develop')" "$N_DEF"
assert_n_deny "(n15) timeout <秒> ラッパー越しの起動も deny"
run_hook "$(bash_json 'gtimeout -k 5 10m bash /x/scripts/multi-review.sh')" "$N_DEF"
assert_n_deny "(n15) gtimeout -k <秒> <期間> ラッパー越しの起動も deny"
run_hook "$(bash_json 'nice -n 10 bash /x/scripts/codex-review.sh --base develop')" "$N_DEF"
assert_n_deny "(n15) nice -n <数値> ラッパー越しの起動も deny"
run_hook "$(bash_json 'until bash /x/scripts/multi-review.sh; do sleep 1; done')" "$N_DEF"
assert_n_deny "(n15) until の条件部の起動も deny"
run_hook "$(bash_json 'if ! toolkit_root="$(bash "$(git rev-parse --show-toplevel)/scripts/codex-review.sh" --print-toolkit-root)"; then exit 2; fi')" "$N_DEF"
assert_silent "(n15) シムの解決（--print-toolkit-root）は巡ではない"
run_hook "$(bash_json 'bash scripts/codex-review.sh --print-toolkit-root=kv')" "$N_DEF"
assert_silent "(n15) コマンド位置のシムでも --print-toolkit-root（解決だけ）は巡ではない"
run_hook "$(bash_json 'bash /x/scripts/multi-agent.sh --task=implement --description x')" "$N_DEF"
assert_silent "(n15) --task=implement は巡ではない"

# --- multi-agent.sh の review 本体の巡回検査（plugin hook が発火しないホストでも効く全ホスト共通の経路。
# multi-review.sh 経由も直接起動も同じ本体を通る）---
n_ma() { # [env...] -- <script> <引数...>
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  local script="$1"
  shift
  RC=0
  OUT="$(cd "$REPO" && env -u FF_REVIEW_ROUND_LIMIT -u FF_REVIEW_ROUND_ACK -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT \
    -u GROK_PLUGIN_ROOT -u MULTI_AGENT_CONFIG PATH="$N_STUB:$PATH" ${envs[@]+"${envs[@]}"} \
    bash "$PLUGIN_ROOT/scripts/$script" "$@" 2>"$TEST_TMP/n-ma.err")" || RC=$?
  N_MA_ERR="$(cat "$TEST_TMP/n-ma.err")"
}
N_MA_ARGS="--mode cross-model --cli codex-cli --perspective code-review --base n-base --timeout 5"
n_commit "script r4"
# shellcheck disable=SC2086 # N_MA_ARGS は語分割して渡す固定の引数列
n_ma -- multi-review.sh $N_MA_ARGS
case "$N_MA_ERR" in
  *'レビュー巡回の上限'*'3 巡目'*)
    if [ "$RC" -eq 4 ] && [ ! -e "$LOCK" ]; then ok "(n16) multi-review.sh 経由の 3 巡目を本体が exit 4 で止め、何も起動しない"; else bad "(n16) rc=$RC"; fi ;;
  *) bad "(n16) multi-review.sh 経由の 3 巡目が止まらない: rc=$RC err=[$N_MA_ERR]" ;;
esac
# shellcheck disable=SC2086
n_ma -- multi-agent.sh --task review $N_MA_ARGS
case "$N_MA_ERR" in
  *'レビュー巡回の上限'*) [ "$RC" -eq 4 ] && ok "(n16) multi-agent.sh --task review の直接起動も 3 巡目を exit 4 で止める" || bad "(n16) 直接起動 rc=$RC" ;;
  *) bad "(n16) multi-agent.sh の直接起動が 3 巡目を止めない: rc=$RC err=[$N_MA_ERR]" ;;
esac
n_ma -- multi-review.sh --dry-run --route fast --base n-base
case "$N_MA_ERR" in
  *'Dry run complete'*) [ "$RC" -eq 0 ] && ok "(n16) --dry-run は巡ではなく通す" || bad "(n16) dry-run rc=$RC" ;;
  *) bad "(n16) --dry-run が止まった: rc=$RC err=[$N_MA_ERR]" ;;
esac
N_HEADS_BEFORE="$(n_heads)"
# shellcheck disable=SC2086
n_ma FF_REVIEW_ROUND_ACK=1 -- multi-review.sh $N_MA_ARGS
case "$N_MA_ERR" in
  *'レビュー巡回の上限'*) bad "(n16) ACK 付きでも止まった: err=[$N_MA_ERR]" ;;
  *)
    if [ "$(n_heads)" = "$((N_HEADS_BEFORE + 1))" ]; then
      ok "(n16) プロセス環境の FF_REVIEW_ROUND_ACK=1 で 1 巡だけ通し、通した巡を記録する"
    else
      bad "(n16) ACK で通した巡が記録されない: heads ${N_HEADS_BEFORE}→$(n_heads)"
    fi
    ;;
esac
clear_lock
run_hook "$(bash_json 'bash scripts/multi-review.sh --base develop')" "$N_DEF"
assert_silent "(n16) 本体が記録した HEAD は hook からも同じ巡（二重に数えない）"
n_commit "script r5"
# shellcheck disable=SC2086
n_ma FF_REVIEW_ROUND_LIMIT=0 -- multi-review.sh $N_MA_ARGS
case "$N_MA_ERR" in
  *'レビュー巡回の上限'*) bad "(n16) FF_REVIEW_ROUND_LIMIT=0 でも止まった: rc=$RC" ;;
  *) [ "$RC" -ne 4 ] && ok "(n16) FF_REVIEW_ROUND_LIMIT=0 で本体側の検査も無効化する（pre-push のゲート等）" || bad "(n16) LIMIT=0 rc=4" ;;
esac
clear_lock

# --- linked worktree 間で記録を共有する（実装と仕上げで worktree が違っても数え直さない）---
n_reset
git -C "$REPO" switch -q feature/n-rounds
n_commit "wt r1"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
n_commit "wt r2"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
git -C "$REPO" checkout -q --detach
N_WT2="$TEST_TMP/n-wt2"
git -C "$REPO" worktree add -q "$N_WT2" feature/n-rounds 2>/dev/null
git -C "$N_WT2" commit -q --allow-empty -m "wt r3 (from the second worktree)"
N_WT2_JSON="$(jq -n --arg d "$N_WT2" \
  '{tool_name: "Agent", tool_input: {subagent_type: "pr-review-toolkit:code-reviewer", description: "review", prompt: "review the diff", isolation: "worktree"},
    cwd: $d, hook_event_name: "PreToolUse"}')"
run_hook "$N_WT2_JSON" "$N_DEF"
assert_n_deny "(n17) 第 2 の linked worktree から次の HEAD で起動しても、共有された記録で 3 巡目を deny する"
git -C "$REPO" worktree remove --force "$N_WT2" 2>/dev/null
git -C "$REPO" switch -q feature/n-rounds
n_reset

# --- env の後ろの代入も剥がす（`env FOO=bar bash …/multi-review.sh`）---
n_commit "env r1"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
n_commit "env r2"
run_hook "$(n_agent pr-review-toolkit:code-reviewer)" "$N_DEF"
n_commit "env r3"
run_hook "$(bash_json 'env FOO=bar bash /x/scripts/multi-review.sh --base develop')" "$N_DEF"
assert_n_deny "(n18) env のオプションと代入の後ろの起動も 3 巡目で deny"
run_hook "$(bash_json 'env -u X FF_REVIEW_ROUND_ACK=1 bash /x/scripts/multi-review.sh --base develop')" "$N_DEF"
assert_silent "(n18) env の後ろの FF_REVIEW_ROUND_ACK=1 も区間先頭の通過口として効く"
n_reset

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-review-in-flight: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-review-in-flight: all ${PASS} checks passed"
REACHED_END=1
exit 0
