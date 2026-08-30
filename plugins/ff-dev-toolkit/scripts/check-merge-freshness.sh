#!/usr/bin/env bash
#
# check-merge-freshness.sh — 「リモート先端 == ゲート実測対象」をマージ直前に照合する
#
# 使い方:
# --- usage:start ---
#   check-merge-freshness.sh --remote-head <SHA40> [--measured <SHA40>]
#                            [--record <パス>] [--fetch] [--remote <名前>]
#   check-merge-freshness.sh --print-record [--record <パス>]
#
#   --remote-head  マージ対象 PR の先端（`gh pr view --json headRefOid --jq .headRefOid`）
#   --measured     実測対象のコミット。省略時は record-gate-head.sh が書いた記録から読む。
#                  **これは自己申告であり、記録経路の汚れ検査を通らない。** 判定不能に
#                  当たったからといって、この引数で緑に付け替えないこと（実在しない SHA は
#                  一致経路で弾くが、「汚れた木で測ったのに clean と申告する」は防げない）
#   --record       記録ファイルのパス（既定は record-gate-head.sh --print-path と同じ）
#   --fetch        関係の分類前に `git fetch <remote>` を行う（リモートのコミットが
#                  手元に無いと ancestor / divergent を区別できないため）
#   --remote       fetch 先のリモート名（既定 origin）
#   --print-record 照合せず、記録の中身（ゲート名・モード・結果・時刻）を出力する。
#                  一致時の無出力を崩さずに、報告へ実測の素性を載せるための入口
# --- usage:end ---
#
# 記録の **MODE は判定に使わない**（高速モードの記録でも一致なら exit 0）。全件実行が
# 要るのは週次 CI と定期実行点の代替経路であって、マージのたびではない（ADR-037 / ADR-039）。ここで
# モードを合否に混ぜると、この検査が実行モードの方針を二重に持つことになる。代わりに
# `--print-record` でモードを報告へ回し、「93/93」と過大に述べない材料にする。
#
# **部分実行の判別も MODE ではなく `STATUS=partial` で行う**（同上の契約をそのまま維持
# する）。MODE は自由文字列で allowlist を持たないため、`MODE=explicit` を判定に使うと
# 「未知の MODE は全件扱い」という fail-open が入口として残る。加えて記録先は checkout の
# git dir 配下だが照合器はインストール済みプラグイン側でありうる（記録器 = 新 /
# 照合器 = 旧 が常態）ので、`STATUS=pass` のまま新キーで部分性を表すと、旧照合器は
# その行を読み飛ばして部分記録を全件緑として通す。`partial` は旧照合器の STATUS
# allowlist の `*)` に落ちるので、知らない版に食わせても判定不能にしかならない。
# **「MODE で判定すれば単純」と後から畳まないこと。** 単純になるのと引き換えに、
# この検査が塞いでいる false green の入口が 2 つ開く。
#
# 守っている窓:
#   ローカルで回したゲートの結果は**特定コミットに対する実測**である。実測とマージの
#   あいだにリモートが進んでいると、squash merge は未実測のコミットまで畳み込み、
#   ゲートを回した意味が消える。実測では、cloud セッションが作った PR をローカルで
#   引き取って作業しているあいだに、同じセッションが同じブランチへ別方向の修正を
#   push していた（気付いたのは push が non-fast-forward で拒否されたとき）。
#
#   `gh pr merge --match-head-commit` が守るのは **AC 照合の後に追加 push された内容**で、
#   照合より前にリモートが進んでいた場合は守らない（`headRefOid` はそのドリフトの
#   後に読まれるため、既に進んだ先端がそのまま「照合済み」として通る）。本検査は
#   その手前、**実測とリモート先端のあいだ**を見る。両者は別の窓を塞ぐ。
#
# 比較の材料をどこから取るか:
#   リモート先端は **API の値（`gh pr view --json headRefOid`）を渡すこと**。
#   `git fetch` + `git rev-parse origin/<branch>` を比較の材料にしてはいけない —
#   remote-tracking ref は前回 fetch 時点のスナップショットで、fetch を忘れた回や
#   fetch が失敗した回に「古い先端 == 古い実測対象」で一致してしまい、この検査が
#   いちばん守りたい経路で fail-open する。fetch はあくまで**関係の分類**に使う。
#
# 終了コード（呼び出し側の扱いを分けるため 判定不能 と 検査不成立 を区別する）:
#   0 = 一致（実測対象 == リモート先端）。**無出力**でマージへ進む
#   1 = 不一致。マージを止め、取り込んで測り直す
#   2 = 判定不能（記録が無い / 汚れた木で測った / **部分実行の記録である** /
#       記録の内容を信頼できない）。マージは止めないが、「実測対象を特定できないため
#       マージ前の再実行を推奨」と **完了報告へ明示する**。静かに素通りさせないことが
#       この終了コードの役割
#
#       部分実行（`STATUS=partial`）は「リモート先端 == 実測対象」が成り立っていても
#       判定不能へ倒す。名指しした suite しか回っていない記録を全件緑へ昇格させないため
#       であって、その記録が信用できないという意味ではない。だから REASON は
#       **何を検証したのか**（`SUITES=` の中身・ゲート名・実測時刻）を名指しし、
#       ACTION は「その範囲で差分の意味を検査できているならマージしてよい」と述べる
#       — 毎回同じ黄色い警告を出すだけのゲートは、そのうち読まれなくなる
#
#       旧版のインストールへ `STATUS=partial` の記録を食わせると、STATUS allowlist の
#       `*)` に落ちて「記録のゲート結果を解釈できません」という文言で exit 2 を返す。
#       **判定（判定不能）は正しく、文言だけが不正確**である（バグ報告として立てる前に
#       照合器の版を確認すること）。判別子を STATUS へ置いたのは、まさにこの
#       「知らない版でも構造的に昇格できない」性質を取るためである
#   3 = 検査不成立（使い方の誤り・git 不在・SHA 形式不正）。停止する
#
#   2 で止めないのは、記録の仕組みを持たないプロジェクトでは判定不能が常態であり、
#   そこで無条件にマージを止めると検査ごと迂回されるため。見逃しのコストが高い窓
#   なので、**黙って緑を返さない**ことを最低線として守る。
#
# 出力（照合モード。`--print-record` は下記のとおり別の契約を持つ）:
#   exit 0 … 無出力（常時ノイズにしない。一致は「何も言わない」で表す）
#   exit 1/2/3 … stdout へ `KEY=値` の機械可読行
#     FRESHNESS=MISMATCH|UNDETERMINED|ERROR
#     MEASURED=<SHA>      （分かる場合）
#     REMOTE=<SHA>        （分かる場合）
#     RELATION=ancestor|unpushed|divergent|unknown  （MISMATCH のとき）
#     REASON=<日本語>
#     ACTION=<日本語>
#
#   `--print-record` の契約:
#     exit 0 … 既知のキー（RECORD_VERSION / STATUS / COMMIT / BRANCH / DIRTY / GATE / MODE /
#              SUITES / RESULT / RECORDED_AT）を `KEY=値` で出力する
#     exit 2 … 記録が無い / 版を解釈できない / 既知のキーが 1 つも無い。
#              FRESHNESS=UNDETERMINED + REASON + ACTION を出す
#
# 実装上の制約:
#   - macOS 標準の bash 3.2 で動くこと（連想配列・`${var,,}` を使わない）
#   - `sed` の BRE で交替（バックスラッシュ + 縦棒）を使わない。BSD sed は交替として
#     解釈せず、一致 0 件のまま exit 0 になる（無音の破損）。分岐が要る走査は awk を使う
#   - 記録の読み取りに eval を使わない（記録ファイルは書き換え可能な入力である）

set -uo pipefail

REMOTE_HEAD=""
MEASURED=""
RECORD_PATH=""
DO_FETCH=0
PRINT_RECORD=0
REMOTE_NAME="origin"

# 記録が部分実行（STATUS=partial）だったか。一致判定の**後**に見る（理由は下の
# 部分性の判定を参照）。--measured を明示した経路では記録を読まないので 0 のまま。
RECORD_PARTIAL=0
RECORD_SUITES=""
RECORD_MODE=""

SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

usage_error() {
  printf 'FRESHNESS=ERROR\n'
  printf 'REASON=%s\n' "$*"
  printf 'ACTION=%s\n' "使い方: check-merge-freshness.sh --remote-head <SHA40> [--measured <SHA40>] [--record <パス>] [--fetch]。検査は成立していないので一致として扱わないこと"
  exit 3
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-head) [[ $# -ge 2 ]] || usage_error "--remote-head に値がありません"; REMOTE_HEAD="$2"; shift 2 ;;
    --measured)    [[ $# -ge 2 ]] || usage_error "--measured に値がありません"; MEASURED="$2"; shift 2 ;;
    --record)      [[ $# -ge 2 ]] || usage_error "--record に値がありません"; RECORD_PATH="$2"; shift 2 ;;
    --remote)      [[ $# -ge 2 ]] || usage_error "--remote に値がありません"; REMOTE_NAME="$2"; shift 2 ;;
    --fetch)       DO_FETCH=1; shift ;;
    --print-record) PRINT_RECORD=1; shift ;;
    -h|--help)     sed -n '/^# --- usage:start/,/^# --- usage:end/p' "$SELF"; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done

is_sha40() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
    ????????????????????????????????????????) return 0 ;;
    *) return 1 ;;
  esac
}

# --print-record は照合を行わない読み出し専用の入口。報告に実測モードやゲート名を
# 載せるために使う（一致時の無出力を崩さずに、記録の中身を報告へ回す手段）。
if [[ "$PRINT_RECORD" -eq 1 ]]; then
  command -v git >/dev/null 2>&1 || usage_error "git が見つかりません"
  if [[ -z "$RECORD_PATH" ]]; then
    RECORD_PATH="$(bash "${SCRIPT_DIR}/record-gate-head.sh" --print-path 2>/dev/null || true)"
  fi
  if [[ -z "$RECORD_PATH" || ! -f "$RECORD_PATH" ]]; then
    printf 'FRESHNESS=UNDETERMINED\n'
    printf 'REASON=%s\n' "実測対象の記録がありません: ${RECORD_PATH:-記録先を解決できません}"
    printf 'ACTION=%s\n' "実測対象を特定できないため、マージ前にゲートを再実行すること"
    exit 2
  fi
  # 読み出し口でも版を検証する。照合本体が v1 しか信じないのに読み出しだけ無検証だと、
  # 解釈できない記録の中身が「実測の素性」として報告へ載る。
  PR_VERSION="$(sed -n 's/^RECORD_VERSION=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"
  if [[ "$PR_VERSION" != "1" ]]; then
    printf 'FRESHNESS=UNDETERMINED\n'
    printf 'REASON=%s\n' "記録の形式を解釈できません（RECORD_VERSION=${PR_VERSION:-なし}）: ${RECORD_PATH}"
    printf 'ACTION=%s\n' "実測対象を特定できないため、マージ前にゲートを再実行すること"
    exit 2
  fi
  # 既知のキーだけを写す（記録に無関係な行が混ざっても報告へ流し込まない）。
  # `sed` の BRE で交替（バックスラッシュ + 縦棒）を使わない — BSD sed はこれを
  # 交替として解釈せず、**無出力のまま exit 0** になる（macOS が主対象なので致命的）。
  RECORD_BODY="$(LC_ALL=C awk '/^(RECORD_VERSION|STATUS|COMMIT|BRANCH|DIRTY|GATE|MODE|SUITES|RESULT|RECORDED_AT)=/ { print }' "$RECORD_PATH")"
  if [[ -z "$RECORD_BODY" ]]; then
    printf 'FRESHNESS=UNDETERMINED\n'
    printf 'REASON=%s\n' "記録に既知のキーがありません: ${RECORD_PATH}"
    printf 'ACTION=%s\n' "実測対象を特定できないため、マージ前にゲートを再実行すること"
    exit 2
  fi
  printf '%s\n' "$RECORD_BODY"
  exit 0
fi

[[ -n "$REMOTE_HEAD" ]] || usage_error "--remote-head は必須です（gh pr view --json headRefOid の値）"
is_sha40 "$REMOTE_HEAD" \
  || usage_error "--remote-head は 40 桁の完全な SHA で渡してください（受領: ${REMOTE_HEAD}）"
if [[ -n "$MEASURED" ]]; then
  is_sha40 "$MEASURED" \
    || usage_error "--measured は 40 桁の完全な SHA で渡してください（受領: ${MEASURED}）"
fi

command -v git >/dev/null 2>&1 || usage_error "git が見つかりません"

undetermined() { # <reason> <action>
  printf 'FRESHNESS=UNDETERMINED\n'
  # 実測対象が分かっている段階で落ちた場合は、それも報告へ残す（何を測ったのかが
  # 操作者の手元に残らないと、次の一手が「とりあえず再実行」しか無くなる）。
  [[ -z "$MEASURED" ]] || printf 'MEASURED=%s\n' "$MEASURED"
  printf 'REMOTE=%s\n' "$REMOTE_HEAD"
  printf 'REASON=%s\n' "$1"
  printf 'ACTION=%s\n' "$2"
  exit 2
}

# ---- 実測対象の特定 ---------------------------------------------------------
# --measured が明示されていればそれを使う。無ければ記録から読む。
if [[ -z "$MEASURED" ]]; then
  if [[ -z "$RECORD_PATH" ]]; then
    # 失敗理由を捨てない。記録器の欠落・git リポジトリ外・bash の失敗がすべて空文字へ
    # 潰れると、REASON が原因を取り違えたまま「判定不能」を返し続ける。
    RESOLVE_ERR="$(bash "${SCRIPT_DIR}/record-gate-head.sh" --print-path 2>&1)" && RECORD_PATH="$RESOLVE_ERR" || RECORD_PATH=""
  fi
  [[ -n "$RECORD_PATH" ]] \
    || undetermined "実測対象の記録先を解決できません（${RESOLVE_ERR:-理由なし}）" \
                    "リポジトリ内でゲートを再実行するか、--measured で実測対象を明示すること"
  [[ -f "$RECORD_PATH" ]] \
    || undetermined "実測対象の記録がありません: ${RECORD_PATH}" \
                    "実測対象を特定できないため、マージ前にゲートを再実行すること（記録はゲートの通過時に書かれる）"

  RECORD_VERSION="$(sed -n 's/^RECORD_VERSION=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"
  [[ "$RECORD_VERSION" == "1" ]] \
    || undetermined "記録の形式を解釈できません（RECORD_VERSION=${RECORD_VERSION:-なし}）: ${RECORD_PATH}" \
                    "実測対象を特定できないため、マージ前にゲートを再実行すること"

  RECORD_STATUS="$(sed -n 's/^STATUS=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"
  RECORD_DIRTY="$(sed -n 's/^DIRTY=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"
  RECORD_COMMIT="$(sed -n 's/^COMMIT=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"
  RECORD_GATE="$(sed -n 's/^GATE=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"
  RECORD_AT="$(sed -n 's/^RECORDED_AT=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"
  # 部分実行の報告材料。**判定には使わない**（MODE を判定に混ぜない契約はヘッダ参照）。
  RECORD_SUITES="$(sed -n 's/^SUITES=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"
  RECORD_MODE="$(sed -n 's/^MODE=//p' "$RECORD_PATH" 2>/dev/null | head -n 1)"

  is_sha40 "${RECORD_COMMIT:-}" \
    || undetermined "記録のコミットが読めません（COMMIT=${RECORD_COMMIT:-なし}）: ${RECORD_PATH}" \
                    "実測対象を特定できないため、マージ前にゲートを再実行すること"

  # 汚れた木での実測は「どのコミットに対する実測でもない」。記録されたコミットと
  # リモート先端が一致していても、実際に測った内容はそのコミットではない。
  #
  # 判定は **`no` だけを許容**する allowlist にする。「`yes` でなければ clean」と書くと、
  # 欠落・空・未知の値を持つ壊れた記録が clean として通り、未実測のコミットが一致に
  # なる（この検査でいちばん避けたい false green）。
  # 赤い回のゲートは実測対象を**無効化**する。書かずに済ませると、同じコミットで
  # 前回通った記録がそのまま残り、照合は無出力の exit 0 を返す（「一度通った
  # コミット」が「いま通るコミット」に化ける）。ここも allowlist で受ける。
  #
  # `partial` は「通ったが名指しした一部だけ」。ここでは pass 相当に受けてフラグだけ
  # 立て、**コミット比較を通した後**で判定不能へ落とす（理由は下の部分性の判定）。
  case "$RECORD_STATUS" in
    pass) : ;;
    partial) RECORD_PARTIAL=1 ;;
    fail)
      undetermined "直近のゲートが失敗しています（${RECORD_GATE:-gate} / ${RECORD_AT:-時刻不明}）" \
                   "ゲートを通してから記録を更新すること"
      ;;
    *)
      undetermined "記録のゲート結果を解釈できません（STATUS=${RECORD_STATUS:-なし}）: ${RECORD_PATH}" \
                   "実測対象を特定できないため、マージ前にゲートを再実行すること"
      ;;
  esac

  case "$RECORD_DIRTY" in
    no) : ;;
    yes)
      undetermined "実測時に作業ツリーが汚れていました（${RECORD_GATE:-gate} / ${RECORD_AT:-時刻不明}）。記録されたコミットは実測対象を表しません" \
                   "コミットを確定させてからゲートを再実行すること"
      ;;
    *)
      undetermined "記録の作業ツリー状態を解釈できません（DIRTY=${RECORD_DIRTY:-なし}）: ${RECORD_PATH}" \
                   "実測対象を特定できないため、マージ前にゲートを再実行すること"
      ;;
  esac

  MEASURED="$RECORD_COMMIT"
fi

# ---- 一致判定 ---------------------------------------------------------------
if [[ "$MEASURED" == "$REMOTE_HEAD" ]]; then
  # 一致を返す**手前でだけ**、実測対象が手元に実在するコミットかを確かめる。
  # 存在しない SHA を `--measured` で渡せば、リモート先端と同じ文字列を自己申告する
  # だけでゲートを通せてしまう（記録経路では起きないが、明示指定は人の入力である）。
  #
  # この検査を比較より**前**に置いてはいけない。不一致（= 止めるべき状態）まで
  # 「手元に無いから判定不能」へ格下げされ、証拠がより弱いケースがより弱い判定を
  # 返す逆転が起きる。リポジトリの外から呼ばれた場合は確認しようがないので行わない。
  if git rev-parse --git-dir >/dev/null 2>&1 \
    && ! git cat-file -e "${MEASURED}^{commit}" 2>/dev/null; then
    undetermined "実測対象のコミットが手元にありません（MEASURED=${MEASURED}）" \
                 "実測対象を特定できないため、マージ前にゲートを再実行すること"
  fi

  # 部分実行の記録は、リモート先端と一致していても全件緑へ**昇格しない**。
  #
  # この判定を比較より**前**へ置いてはいけない。前に置くと「部分記録 × 分岐した先端」
  # （= 止めるべき状態）まで判定不能へ格下げされ、証拠がより強いケースがより弱い判定を
  # 返す逆転が起きる。実在確認を一致経路の内側に置いているのと同じ理由である。
  #
  # REASON は**何を検証したのか**を名指しする。毎回同じ黄色い警告を出すだけのゲートは
  # 読まれなくなり、赤で止まるゲートを黄色へ替えただけの劣化になる。
  if [[ "$RECORD_PARTIAL" -eq 1 ]]; then
    undetermined "記録は部分実行です（名指しした suite だけを実行した記録で、ゲートの既定一覧は回っていません）。検証済み: ${RECORD_SUITES:-（suite 名の記録なし）} / ゲート: ${RECORD_GATE:-不明} / モード: ${RECORD_MODE:-不明} / 実測: ${RECORD_AT:-時刻不明}" \
                 "上に名指しした suite で差分の意味を検査できている変更（CHANGELOG footer の追従など）なら、このままマージしてよい。それでは足りない差分なら、ゲートの既定一覧を回して記録を更新すること"
  fi
  exit 0
fi

# ---- 不一致の分類 -----------------------------------------------------------
# 「祖先か（実測のあとに push された）」「未 push か」「分岐か」で次の一手が違う。
# 分岐の**原因**は 1 つに断定しない — 別セッションの push だけでなく、実測対象が
# マージ済み・削除済みのブランチ上にある場合も分岐になる（分類そのものは正しく、
# 原因を名指しした文言だけが誤りうる）。
# 区別にはリモートのコミットが手元に要るので、必要なら fetch する（比較そのものは
# 既に API の値で終わっている。fetch の成否は判定を変えない）。
RELATION="unknown"
FETCH_FAILED=0
if git rev-parse --git-dir >/dev/null 2>&1; then
  if [[ "$DO_FETCH" -eq 1 ]] && ! git cat-file -e "${REMOTE_HEAD}^{commit}" 2>/dev/null; then
    git fetch --quiet "$REMOTE_NAME" >/dev/null 2>&1 || FETCH_FAILED=1
  fi
  if git cat-file -e "${MEASURED}^{commit}" 2>/dev/null \
    && git cat-file -e "${REMOTE_HEAD}^{commit}" 2>/dev/null; then
    if git merge-base --is-ancestor "$MEASURED" "$REMOTE_HEAD" 2>/dev/null; then
      RELATION="ancestor"
    elif git merge-base --is-ancestor "$REMOTE_HEAD" "$MEASURED" 2>/dev/null; then
      RELATION="unpushed"
    else
      RELATION="divergent"
    fi
  fi
fi

case "$RELATION" in
  ancestor)
    REASON="実測対象はリモート先端の祖先です。実測のあとに push された差分がマージへ含まれます"
    ACTION="リモート先端を取り込んでゲートを再実行し、記録を更新してからマージすること"
    ;;
  unpushed)
    REASON="実測対象がリモート先端より先行しています（未 push のコミットを測っています）"
    ACTION="push してからゲートを再実行し、記録を更新してからマージすること"
    ;;
  divergent)
    REASON="実測対象とリモート先端が分岐しています（別セッションが同じブランチへ push した、実測対象がマージ済み・削除済みのブランチ上にある、など原因は複数ありえます）"
    ACTION="force-push で押し切らず、リモートのコミットの上に自分の変更を積んでからゲートを再実行すること"
    ;;
  *)
    REASON="実測対象とリモート先端が一致しません（両者の関係は手元のリポジトリから判定できませんでした）"
    ACTION="git fetch のうえ再実行し、リモート先端を取り込んでゲートを再実行してからマージすること"
    # 直前に fetch が失敗しているなら、その fetch をもう一度勧めない
    if [[ "$FETCH_FAILED" -eq 1 ]]; then
      REASON="${REASON}。${REMOTE_NAME} からの fetch も失敗しました"
      ACTION="fetch が通る状態にしてから再実行すること（認証・ネットワーク・リモート名を確認する）"
    fi
    ;;
esac

printf 'FRESHNESS=MISMATCH\n'
printf 'MEASURED=%s\n' "$MEASURED"
printf 'REMOTE=%s\n' "$REMOTE_HEAD"
printf 'RELATION=%s\n' "$RELATION"
printf 'REASON=%s\n' "$REASON"
printf 'ACTION=%s\n' "$ACTION"
exit 1
