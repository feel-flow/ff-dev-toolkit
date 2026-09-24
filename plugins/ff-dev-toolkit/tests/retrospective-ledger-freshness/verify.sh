#!/usr/bin/env bash
#
# /retrospective の「記録の前に base の先行を照合する」フェンスを、SKILL.md から抽出して
# 隔離 git fixture で**実際に動かす**（Issue `#1570`）。
#
# 固定文言の針（tests/retrospective-contract の検査 E）は「文言が在る」ことしか見ない。
# `merge-base --is-ancestor` の引数を逆転させても、pathspec を cwd 相対へ戻しても、
# `exit 1` を `exit 0` へ倒しても、needle は全部一致したままである。実際に走らせる層が
# 要る（tests/ace-refine の「base 鮮度ガードの振る舞い」と同じ発想）。
#
# **tests/retrospective-contract から分けてある理由**: 向こうは一時領域不要の文言 gate で、
# 1 秒未満で終わる。振る舞い検査は git fixture の構築を払うので、層を分けて文言 gate を
# 速いまま保つ（フェンスのコード行に文言の針を張らないのも、ここが実行で見ているため）。
#
# 検査:
#   S0. 構造 — フェンスの停止点が 6 箇所あり、すべて `exit 1` である（`exit 0` は 0 箇所）。
#       到達可能な状況を fixture で作れない停止点（remote-tracking ref の解決失敗は、
#       fetch が成功した時点で ref が在るため原理的に作れない）を、帰結の書き換えから守る
#       唯一の層。行削除ではなく `exit 1` → `exit 0` の変異はここでしか死なない
#   S1〜S11. 振る舞い — 下の各シナリオ。停止する回は **rc だけでなく停止理由**まで照合する。
#       rc だけを見ると 6 つの停止点が互いに入れ替わっても緑で、実際に 2 件の変異が生存した
#       （origin/HEAD 解決失敗を既定値へ倒す / rev-parse 失敗を `exit 0` へ倒す）
#
# 変異検出（2026-09-15 実測。変異は 1 件ずつ当て、前後で対照を取る。赤転しなかった変異は無し）:
#           `merge-base --is-ancestor` の引数を逆転させると 2 件が赤（ローカル先行 / remote 先行）。
#           diverge のシナリオは赤くならない — 引数を逆にしても diverge では止まるためで、
#           向きの検査はローカル先行のシナリオだけが担っている。
#           pathspec の `:(top)` を落として cwd 相対へ戻すと 1 件が赤。ルートからの実行は
#           通ってしまうので、**サブディレクトリ実行のシナリオが唯一の検出点**である。
#           `[[ -z "$ledger_status" ]]` を `-n` へ反転させると 9 件が赤。
#           `git status` の rc を受けない `[[ -z "$(git status …)" ]]` の形へ戻すと 2 件が赤
#           （構造検査のみ。rc を捨てる形は git が失敗しても「空 = clean」と読む）。
#           origin/HEAD 解決失敗の `exit 1` を既定値 `default_ref="origin/main"` へ倒すと 2 件が赤。
#           **この変異は分離前の contract 側では生存していた** — rc だけを見て停止理由を
#           照合していなかったため、別の停止点で止まった回と区別できていなかった。
#           fetch 失敗の `exit 1` を `exit 0` へ倒すと 3 件が赤。
#           rev-parse 失敗の `exit 1` を `exit 0` へ倒すと 2 件が赤（構造検査のみ）。**この変異も
#           分離前は生存していた** — fetch が成功した時点で remote-tracking ref は在るので、
#           この停止点へ到達する状況は fixture で作れない。構造検査（停止点の本数と `exit 0`
#           の不在）が、到達不能な停止点を帰結の書き換えから守る唯一の層である。
#           先行判定の `exit 1` を `exit 0` へ倒すと 4 件が赤。
#
# 節の切り出しは tests/lib/section-scope.sh へ寄せる（同ファイルのヘッダが「呼び出し側で
# awk を書き直さない」と規定している）。本 suite が自前で持つのは**フェンスの取り出し**だけで、
# 節の定義は複製しない。
#
# git と一時領域が要る。どちらかが無い環境では suite 全体を `○ skip` する（列 0）。
# run-all-required: yes — フェンスを実際に走らせる層はここだけで、skip すると
#                   「引数の向き・fail-open・cwd 依存」の検出力が丸ごと消える。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/section-scope.sh
. "$SCRIPT_DIR/../lib/section-scope.sh"

# 照合フェンスは本線から条件付き reference（references/ledger.md）へ移した。抽出元はその reference。
SKILL="$PLUGIN_ROOT/skills/retrospective/references/ledger.md"
GUARD_SECTION="## 記録の前に base の先行を照合する"
EXPECTED_STOPS=6

PASS=0
FAIL=0

ok() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}

bad() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

echo "== retrospective 台帳 base 先行ガードの振る舞い =="

if [[ ! -f "$SKILL" ]]; then
  bad "SKILL.md が見つかりません: $SKILL"
  echo ""
  echo "✗ retrospective ledger freshness verify: 1 件失敗 / 0 件成功" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が無いため振る舞い検査を実行できません（この suite は 1 件も検査していません）"
  exit 0
fi
if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/retro-ledger-freshness.XXXXXX" 2>&1)" || [ ! -d "$TMP" ]; then
  # 診断を捨てると不正 TMPDIR と read-only を区別できないため、成功時のパスと失敗時の理由を
  # 同じ変数へ受ける。rc=0 でも -d を検査する（2>&1 の合流で警告文が混入する環境がある）。
  echo "○ skip: 一時ディレクトリを作成できないため振る舞い検査を実行できません"
  printf '  mktemp: %s\n' "$TMP"
  exit 0
fi
# 途中死（`set -u` / `set -e` による死）を rc=0 で終わらせない。EXIT トラップは
# **関数形でも**素の `rm -rf` 形でも終了ステータスを握り潰す（2026-09-15 実測: どちらも
# rc=0）。`set -u` の死ではトラップ突入時の $? が 0 になるため、rc の保存だけでも足りない。
# 到達フラグを立てた回だけ本来の rc で終わり、それ以外は 1 で終わる。
FINISHED=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$FINISHED" -ne 1 ]]; then
    echo "✗ retrospective ledger freshness verify: suite が途中で終了しました（rc=${rc}）" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

finish() { FINISHED=1; exit "$1"; }

# ── フェンスの抽出（節の切り出しは共通ヘルパへ寄せる） ───────────────────────
if ! SECTION_BODY="$(section_scope_extract "$SKILL" "$GUARD_SECTION")"; then
  bad "照合フェンスの節を切り出せません — ${SECTION_BODY}"
  echo ""
  echo "✗ retrospective ledger freshness verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  finish 1
fi

GUARD="$TMP/guard.sh"
printf '%s\n' "$SECTION_BODY" | awk '
  !in_fence && /^```bash$/ { in_fence = 1; next }
  in_fence && /^```/ { exit }
  in_fence { print }
' > "$GUARD"

if ! /usr/bin/grep -qF 'merge-base --is-ancestor' "$GUARD"; then
  bad "節から bash フェンスを取り出せません（この suite は空振りします）"
  echo ""
  echo "✗ retrospective ledger freshness verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  finish 1
fi

# ── S0: 構造（停止点の本数と帰結） ───────────────────────────────────────────
# 到達可能な状況を fixture で作れない停止点（rev-parse 失敗）を守る唯一の層。
STOP_COUNT="$(/usr/bin/grep -c '^ *exit 1$' "$GUARD" || true)"
PASSTHRU_COUNT="$(/usr/bin/grep -c 'exit 0' "$GUARD" || true)"
if [[ "$STOP_COUNT" -eq "$EXPECTED_STOPS" ]]; then
  ok "構造: フェンスの停止点が ${EXPECTED_STOPS} 箇所（増減時はこの suite の EXPECTED_STOPS も更新すること）"
else
  bad "構造: フェンスの停止点が ${EXPECTED_STOPS} 箇所（実際: ${STOP_COUNT} 箇所 — 停止点の削除、または追加時の期待値未更新）"
fi
if [[ "$PASSTHRU_COUNT" -eq 0 ]]; then
  ok "構造: フェンスに素通りする帰結（exit 0）が無い"
else
  bad "構造: フェンスに素通りする帰結（exit 0）が無い（実際: ${PASSTHRU_COUNT} 箇所 — 停止が fail-open へ倒れています）"
fi
# `git status` の rc を捨てる形（`[[ -z "$(git status …)" ]]`）は、git 側が失敗しても
# 出力が空 = clean と読む。rc を受ける形であることを構造として見る。
if /usr/bin/grep -q 'ledger_status="\$(git status' "$GUARD"; then
  ok "構造: 台帳 status は rc を受けてから空判定する"
else
  bad "構造: 台帳 status は rc を受けてから空判定する（不足: ledger_status への代入形）"
fi

# ── fixture ─────────────────────────────────────────────────────────────────
g() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
LEDGER="docs/08-knowledge/OBSERVATIONS.md"
WORK="$TMP/work"

setup_failed=0
g init -q --bare "$TMP/remote.git" >/dev/null 2>&1 || setup_failed=1
g clone -q "$TMP/remote.git" "$WORK" >/dev/null 2>&1 || setup_failed=1
( cd "$WORK" \
  && mkdir -p docs/08-knowledge sub \
  && printf 'seed\n' > seed.txt \
  && printf 'keep\n' > sub/keep.txt \
  && g add -A >/dev/null 2>&1 \
  && g commit -qm seed >/dev/null 2>&1 \
  && g push -q origin main >/dev/null 2>&1 ) || setup_failed=1
g -C "$WORK" remote set-head origin main >/dev/null 2>&1 || setup_failed=1
if [[ "$setup_failed" -ne 0 ]]; then
  bad "git fixture を構築できません（振る舞いの実測が 1 件も成立していません）"
  echo ""
  echo "✗ retrospective ledger freshness verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  finish 1
fi

RC=0
ERR=""
run_guard() { # $1=work からの相対 cwd（既定はルート）
  local sub="${1:-.}"
  RC=0
  ERR="$( cd "$WORK/$sub" && bash "$GUARD" 2>&1 >/dev/null )" || RC=$?
}

expect_pass() { # $1=ラベル $2=通らなかったときの診断 $3=相対 cwd
  run_guard "${3:-.}"
  if [[ "$RC" -eq 0 ]]; then
    ok "$1"
  else
    bad "$1"
    printf '    %s（rc=%s / %s）\n' "$2" "$RC" "$ERR" >&2
  fi
}

expect_stop() { # $1=ラベル $2=停止理由の針 $3=通ってしまったときの診断 $4=相対 cwd
  run_guard "${4:-.}"
  if [[ "$RC" -eq 0 ]]; then
    bad "$1"
    printf '    %s（ガードが通しました）\n' "$3" >&2
  elif [[ "$ERR" != *"$2"* ]]; then
    bad "$1"
    printf '    別の停止点で止まっています（期待する理由: %s / 実際: %s）\n' "$2" "$ERR" >&2
  else
    ok "$1"
  fi
}

# 前提の構築が失敗したまま先へ進むと、検査が前シナリオの複製へ静かに縮退する
# （例: ローカルコミットが失敗すると「ローカル先行」が「同一 HEAD」の再実行になり、
# 引数逆転の変異を振る舞い側で 1 件も殺せなくなる）。前提は必ず機械で確かめる。
require() { # $1=ラベル $2... = 満たすべきコマンド
  local label="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    bad "fixture 前提: ${label}（この前提が崩れると後続シナリオが別物になります）"
    return 1
  fi
  return 0
}

ledger_is_clean() { [[ -z "$(g -C "$WORK" status --porcelain --untracked-files=all -- ":(top)$LEDGER")" ]]; }
head_is_ancestor_of_origin() { g -C "$WORK" merge-base --is-ancestor HEAD origin/main; }

# ── S1: 台帳が未作成でも通す（初回導入。記録手順 0 が cp する前） ────────────
expect_pass "台帳が未作成のリポジトリでも通す（記録手順 0 が作成する前）" \
  "台帳の作成前に止めると、全新規導入リポジトリの初回振り返りが記録できない"

( cd "$WORK" && printf '# ledger\n' > "$LEDGER" && g add -A >/dev/null 2>&1 \
  && g commit -qm ledger >/dev/null 2>&1 && g push -q origin main >/dev/null 2>&1 ) \
  || bad "fixture 前提: 台帳を作成して push できません"

# ── S2〜S3: 正常系 ───────────────────────────────────────────────────────────
expect_pass "同一 HEAD・台帳 clean は通す" "ガードが正常系を止めている（記録が一度も通らない）"

( cd "$WORK" && printf 'unrelated\n' > unrelated.txt ) \
  || bad "fixture 前提: 無関係な dirty を作れません"
tree_has_dirt() { [[ -n "$(g -C "$WORK" status --porcelain --untracked-files=all)" ]]; }
require "作業ツリー全体は dirty" tree_has_dirt || true
require "台帳自身は clean" ledger_is_clean || true
expect_pass "台帳と無関係な dirty は通す（単独コミットの粒度）" \
  "台帳と無関係な dirty で止まっている（デフォルト統合ブランチ上の単独実行が記録できない）"
rm -f "$WORK/unrelated.txt"

# ── S4〜S5: 台帳自身の dirty（ルート / サブディレクトリ） ────────────────────
( cd "$WORK" && printf 'dirty\n' >> "$LEDGER" ) || bad "fixture 前提: 台帳を dirty にできません"
expect_stop "台帳自身の未コミット変更は止める" "台帳に未コミットの変更があります" \
  "他セッションの途中編集を knowledge: 単独コミットへ巻き込む"
# pathspec が cwd 相対だと、ここだけが緑から赤へ落ちる（ルートからの実行は通るため）。
expect_stop "サブディレクトリから実行しても台帳の未コミット変更を検出する" \
  "台帳に未コミットの変更があります" \
  "pathspec が cwd 相対で、リポジトリルート以外からは台帳 dirty を見落とす" \
  "sub"
if ! g -C "$WORK" checkout -- "$LEDGER" >/dev/null 2>&1; then
  bad "fixture 前提: 台帳を復元できません（以降のシナリオが台帳 dirty で止まり、別の理由で緑になります）"
fi
require "台帳が clean へ戻っている" ledger_is_clean || true

# ── S6: origin/HEAD を解決できない ──────────────────────────────────────────
if g -C "$WORK" symbolic-ref -d refs/remotes/origin/HEAD >/dev/null 2>&1; then
  expect_stop "origin/HEAD を解決できない回は止める" "origin/HEAD を解決できません" \
    "default branch を推測で決めている（AC が名指しする停止条件が働かない）"
  g -C "$WORK" remote set-head origin main >/dev/null 2>&1 \
    || bad "fixture 前提: origin/HEAD を復元できません"
else
  bad "fixture 前提: origin/HEAD を削除できません"
fi

# ── S7: remote だけが先行（HEAD が origin の祖先 = ff 可能） ─────────────────
# 別クローンを作らず、work から一時ブランチ経由で origin を 1 歩進める。
advance_remote() { # $1=コミットメッセージ
  ( cd "$WORK" \
    && g fetch -q origin main >/dev/null 2>&1 \
    && g checkout -q -B tmp-advance origin/main >/dev/null 2>&1 \
    && printf '%s\n' "$1" >> "$LEDGER" \
    && g add -A >/dev/null 2>&1 \
    && g commit -qm "$1" >/dev/null 2>&1 \
    && g push -q origin tmp-advance:main >/dev/null 2>&1 \
    && g checkout -q main >/dev/null 2>&1 )
}
if advance_remote "remote-ahead"; then
  require "HEAD が origin/main の祖先（ff 可能な先行）" head_is_ancestor_of_origin || true
  expect_stop "remote だけが先行している回を検出して止める" "が先行しています" \
    "古い台帳から同一性判定・Count・OBS ID が決まる"
  # AC の復帰分岐 (a): ff 可能なら取り込んで記録手順 0 からやり直せる。
  if g -C "$WORK" pull -q --ff-only >/dev/null 2>&1; then
    ok "復帰: ff 可能な先行は git pull --ff-only で取り込める"
  else
    bad "復帰: ff 可能な先行は git pull --ff-only で取り込める（不足: ff-only が失敗しました）"
  fi
else
  bad "fixture 前提: remote を先行させられません"
fi

# ── S8: ローカル先行（未 push）は通す ───────────────────────────────────────
( cd "$WORK" && printf 'local\n' > local.txt && g add -A >/dev/null 2>&1 \
  && g commit -qm local >/dev/null 2>&1 ) || bad "fixture 前提: ローカルコミットを作れません"
# 前提は成功時に数えない（この suite が数える「検査」は SKILL.md のフェンスに対する主張だけ）。
# 崩れたときだけ赤にする — 前提が崩れたまま緑になる形を残さないのが目的で、成功を検査として
# 数えると、同じラベルが検査総数へ紛れて「フェンスを何件検査したか」が読めなくなる。
head_strictly_ahead() {
  g -C "$WORK" merge-base --is-ancestor origin/main HEAD && ! head_is_ancestor_of_origin
}
require "HEAD が origin/main より厳密に先行している（同一 HEAD の再実行への縮退）" head_strictly_ahead || true
expect_pass "ローカル先行（未 push）は通す" \
  "正常なローカル先行を拒否している（merge-base の引数の向きが逆）"

# ── S9: fetch できない（remote-tracking ref は stale だが通る値） ────────────
# 順序が重要: ここで origin/main は HEAD の祖先＝「stale だが通る値」なので、止まるのは
# fetch 失敗の停止点だけになる。先に remote を先行させると先行判定の側で止まり、
# fetch 失敗の停止を削る変異が素通りする（tests/ace-refine で実測済みの生存パターン）。
if g -C "$WORK" remote set-url origin "$TMP/does-not-exist.git" >/dev/null 2>&1; then
  # set-url が効かなかった回は、fetch が成功して先行判定の側で止まる。それでも
  # 「止まった」だけは成立してしまうので、remote へ届かない状態そのものを確かめる。
  remote_unreachable() { ! g -C "$WORK" ls-remote origin; }
  require "remote へ到達できない状態になっている" remote_unreachable || true
  expect_stop "fetch できない回は stale 値へ fallback せず止める" "を取得できません" \
    "stale な remote-tracking ref のまま通している（fail-open）"
  g -C "$WORK" remote set-url origin "$TMP/remote.git" >/dev/null 2>&1 \
    || bad "fixture 前提: remote URL を復元できません"
else
  bad "fixture 前提: remote URL を壊せません"
fi

# ── S10: diverge（先行を検出し、取り込みは ff-only で失敗する） ──────────────
if advance_remote "diverged"; then
  expect_stop "diverge している回も先行として検出して止める" "が先行しています" \
    "diverge を素通りさせている"
  # AC の復帰分岐 (b): ff できないなら押し切らず停止し、記録を断念して報告する。
  if g -C "$WORK" pull -q --ff-only >/dev/null 2>&1; then
    bad "復帰: diverge では git pull --ff-only が失敗する（不足: ff-only が成功してしまいました）"
  else
    ok "復帰: diverge では git pull --ff-only が失敗する（押し切らず停止する側へ倒れる）"
  fi
else
  bad "fixture 前提: diverge 状態を作れません"
fi

# ── S11: 最終境界（照合を通した後に入った先行は push が弾く） ────────────────
# 照合点は「記録内容を作る前」にしか無いので、照合から push までの窓は覆えない。設計は
# その窓を **push の non-fast-forward** に預けている（書き込み節）。前提そのものが成り立つ
# ことを実測する — ここが通ってしまうなら、規定した復帰手順が呼ばれる機会が無い。
# S10 の diverge から抜けて、照合が通る状態（HEAD == origin/main・台帳 clean）へ戻す。
( cd "$WORK" && g fetch -q origin main >/dev/null 2>&1 && g reset -q --hard origin/main >/dev/null 2>&1 ) \
  || bad "fixture 前提: 最終境界のシナリオ開始状態へ戻せません"
if run_guard && [[ "$RC" -eq 0 ]]; then
  ( cd "$WORK" && printf "own observation\n" >> "$LEDGER" \
    && g commit -qm "knowledge: own" -- "$LEDGER" >/dev/null 2>&1 ) \
    || bad "fixture 前提: 台帳の単独コミットを作れません"
  if advance_remote "concurrent"; then
    if ( cd "$WORK" && g push -q origin main >/dev/null 2>&1 ); then
      bad "最終境界: 照合後に入った先行を push が弾く（不足: push が通ってしまいました）"
    else
      ok "最終境界: 照合後に入った先行を push が弾く（照合の窓の後段を覆う唯一の境界）"
    fi
  else
    bad "fixture 前提: 照合後の並行更新を作れません"
  fi
else
  bad "fixture 前提: 最終境界のシナリオ開始時にガードが通らない（rc=${RC} / ${ERR}）"
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "✓ retrospective ledger freshness verify: 全 ${PASS} 件 pass"
  finish 0
fi
echo "✗ retrospective ledger freshness verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
finish 1
