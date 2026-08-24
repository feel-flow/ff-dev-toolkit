#!/usr/bin/env bash
#
# workflow-tier.sh — Git Workflow の実行段階を変更規模で決める分類器
#
# 使い方:
#   workflow-tier.sh [--base <ref>]            … 差分から判定する（確定判定）
#   workflow-tier.sh <path> [<path> ...]       … 渡した path 一覧で判定する（暫定判定）
#   workflow-tier.sh --paths-from <file|->     … 同上（1 行 1 path。`-` は stdin）
#   workflow-tier.sh --list-rules              … 判定規則そのものを出力する
#
# 何のためにあるか:
#   ワークフローの段は「変更規模に関わらず全部通す」運用だった。typo 修正と公開
#   リリースが同じ段数を通る一方で、段の一覧は 4 つの文書に別々の数で写されていた。
#   分類を機械側へ置き、文書は**判定規則だけ**を書く形にするのが本スクリプトの役割。
#   段の内容（各 tier で何をするか）は docs/05-operations/DEPLOYMENT.md
#   §主要ステップ（配布物では docs-template/05-operations/DEPLOYMENT.md）が正本。
#
# 判定規則（上から順に評価し、**最初に一致した tier を採る**）:
#   1. full     … 配布・リリースへ影響する path を含む
#   2. light    … 変更が `.md` のみ（1 に当たらない）
#   3. standard … 上記以外（実装変更）
#
#   順序を固定するのが要点。`docs-template/**.md` は 1 と 2 の両方に当たるが、
#   配布物なので full が勝つ。「どちらにも当たる場合どうするか」を運用者の判断に
#   委ねると、tier は自己申告へ戻る。
#
#   判定は**ディレクトリの所属ではなく「配布・リリースへの影響」**で行う。
#   「公開同期対象（PUBLIC_TARGETS）配下なら full」という素朴な規則は、
#   ツールキット自身のリポジトリでは skills・tests・hooks が丸ごと公開対象配下に
#   あるため全 PR が full へ落ちて機能しない（実測で棄却した）。
#
# full の判定パターンは差し替えられる:
#   既定は本スクリプトを配る側（プラグイン / docs-template を持つリポジトリ）の形に
#   合わせてある。利用者プロジェクトは `docs-template/` を持たず、代わりに配布物や
#   リリース成果物が別の場所にある。`WORKFLOW_TIER_FULL_PATTERNS` に ERE を
#   1 行 1 件で与えると既定を置き換えられる（`--list-rules` で実効値を確認できる）。
#
# 暫定判定と確定判定:
#   着手時点（`/spec-driven` のモード判定など）は差分がまだ無いため、予定している
#   変更対象を path 一覧として渡す**暫定判定**しかできない。暫定判定は自己申告と
#   同じ弱さを持つ（申告漏れは軽い側へ倒れる）ので、**PR を出す前に引数なしで
#   実行した確定判定が拘束する**。暫定 light が確定 standard/full と食い違った場合は
#   確定側へ合わせる（暫定を追認しない）。
#
# 出力プロトコル（stdout、行頭一致で機械可読）:
#   exit 0:
#     WORKFLOW_TIER=full|light|standard
#     REASON=<判定理由>
#     SOURCE=diff|args|stdin|file
#     CHANGED=<判定に使った path 件数>
#     MATCHED=<full を決めた path>   … full のときだけ
#   exit 2（判定材料が取れない。fail-closed だが「検査不能」として区別する）:
#     WORKFLOW_TIER=unknown
#     SKIP_REASON=<原因>
#   exit 0（分類以外の 2 形。いずれも WORKFLOW_TIER= 行を出さない）:
#     --list-rules … RULE=<順>|<tier>|<説明> と FULL_PATTERN=<ERE>
#     -h / --help  … usage を stdout へ
#   exit 64: 使い方の誤り（usage を stderr へ）
#
#   差分が空のときは fail-closed で standard を返す（「変更が無いから軽い」と
#   読み替えない。空差分は判定材料が無いのと同じで、軽い側へ倒す根拠にならない）。
#
# 制約: bash 3.2 互換（連想配列・mapfile 禁止）。一時ファイルを作らない。
set -uo pipefail

DEFAULT_FULL_PATTERNS='(^|/)docs-template/
(^|/)\.claude-plugin/
(^|/)plugin\.json$
(^|/)package\.json$'

# `:-` ではなく `-` を使う。`:-` だと **明示的に空を渡した上書き**（`WORKFLOW_TIER_FULL_PATTERNS=`）
# が黙って既定へ落ち、「full 判定を無効にしたつもり」と「既定のまま」が区別できない。
# 未設定なら既定、設定されていれば（空でも）その値を使い、空は下の検証で弾く。
FULL_PATTERNS="${WORKFLOW_TIER_FULL_PATTERNS-${DEFAULT_FULL_PATTERNS}}"
# 前後の空白を落とし、空白だけの行は捨てる。空白だけのパターンは ERE としては妥当
# （空白そのものへの一致）なので検証を素通りするが、path パターンとしては意味を持たず、
# 「full に当たる path が 1 件も無い」状態を黙って作る。ここで正規化して、下の
# validate_full_patterns の件数 0 判定へ落とす。
FULL_PATTERNS="$(printf '%s\n' "${FULL_PATTERNS}" \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | grep -v '^$' || true)"
BASE="${WORKFLOW_TIER_BASE:-origin/develop}"

# here-doc は使わない。bash 5.1 未満（macOS 標準の 3.2 を含む）は here-document を
# 一時ファイルへ書き出すため、書き込み不可の TMPDIR では usage() だけが落ちる
# ＝ **誤用を報告しようとした瞬間にだけ発火する**壊れ方になる（下の分類ループが
# here-doc を避けているのと同じ理由。ACE-279-2 の「失敗報告パスだけで発火する」型）。
usage() {
  printf '%s\n' \
    'workflow-tier.sh — Git Workflow の実行段階を変更規模で決める分類器' \
    '' \
    '  workflow-tier.sh [--base <ref>]         差分から判定する（確定判定）' \
    '  workflow-tier.sh <path> [<path> ...]    渡した path 一覧で判定する（暫定判定）' \
    '  workflow-tier.sh --paths-from <file|->  同上（1 行 1 path。`-` は stdin）' \
    '  workflow-tier.sh --list-rules           判定規則そのものを出力する' \
    '' \
    '環境変数:' \
    '  WORKFLOW_TIER_BASE           確定判定の base ref（既定 origin/develop）' \
    '  WORKFLOW_TIER_FULL_PATTERNS  full 判定の ERE を 1 行 1 件で置き換える'
}

die_usage() {
  echo "✗ $1" >&2
  usage >&2
  exit 64
}

unavailable() {
  echo "WORKFLOW_TIER=unknown"
  echo "SKIP_REASON=$1"
  # stdout を捨てて呼ぶ使い方（`workflow-tier.sh >/dev/null`）でも理由が見えるように、
  # 人間向けの 1 行は stderr へも出す。機械可読の契約は stdout 側だけが持つ。
  echo "✗ workflow-tier: $1" >&2
  exit 2
}

# full 判定パターンの妥当性検査。`grep -E` は不正な ERE で終了コード 2 を返すが、
# 判定側は `grep ... | head -1` の形で使うためパイプの終了コードは head のものになり、
# **一致 0 件と区別が付かない**。検証を通さないと「壊れた上書きパターン → 一致なし →
# light/standard で exit 0」という fail-open になる（実測: `(^|/)docs-template/[` を
# 与えると配布物の変更が light になった）。path が 1 件以上あるときは分類の前に必ず通す
# （0 件は分類材料が無いので、パターンを見るまでもなく標準へ倒す）。
validate_full_patterns() {
  local pat count=0 old_ifs="${IFS}"
  set -f
  IFS='
'
  for pat in ${FULL_PATTERNS}; do
    IFS="${old_ifs}"
    if [ -n "${pat}" ]; then
      count=$((count + 1))
      printf '' | grep -E -- "${pat}" >/dev/null 2>&1
      case $? in
        0|1) ;;  # 一致 / 不一致 はどちらも「正規表現として妥当」
        *)
          set +f
          IFS="${old_ifs}"
          unavailable "full 判定パターンが正規表現として不正です: ${pat}（WORKFLOW_TIER_FULL_PATTERNS を確認してください）"
          ;;
      esac
    fi
    IFS='
'
  done
  set +f
  IFS="${old_ifs}"
  # 空の一覧は「full に当たる path が無い」= 全 PR が light/standard へ落ちる状態を
  # 黙って作る。設定ミスと区別できないので検査不能として止める。
  if [ "${count}" -eq 0 ]; then
    unavailable "full 判定パターンが 1 件もありません（空の上書きは全変更を軽い側へ倒すため受け付けません）"
  fi
}

PATHS_FROM=""
LIST_RULES=0
BASE_EXPLICIT=0
ARG_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      shift
      [ $# -gt 0 ] || die_usage "--base に値がありません"
      BASE="$1"
      BASE_EXPLICIT=1
      ;;
    --paths-from)
      shift
      [ $# -gt 0 ] || die_usage "--paths-from に値がありません"
      PATHS_FROM="$1"
      ;;
    --list-rules) LIST_RULES=1 ;;
    -h|--help) usage; exit 0 ;;
    --)
      shift
      while [ $# -gt 0 ]; do ARG_PATHS+=("$1"); shift; done
      break
      ;;
    -*) die_usage "不明なオプション: $1" ;;
    *) ARG_PATHS+=("$1") ;;
  esac
  [ $# -gt 0 ] && shift
done

# ---- --list-rules: 判定規則そのものを出す ------------------------------------
# 文書側の tier 表とこのスクリプトが食い違っていないかを機械照合できるようにする
# （文書へ規則を書き写した瞬間に、それは腐りうる第 2 の正本になるため）。
if [ "${LIST_RULES}" -eq 1 ]; then
  validate_full_patterns
  echo "RULE=1|full|配布・リリースへ影響する path を含む"
  WT_OLD_IFS="${IFS}"
  set -f
  IFS='
'
  for pat in ${FULL_PATTERNS}; do
    [ -n "${pat}" ] || continue
    echo "FULL_PATTERN=${pat}"
  done
  IFS="${WT_OLD_IFS}"
  set +f
  echo "RULE=2|light|変更が .md のみ"
  # 説明文は実行時の REASON と同じ文字列にする（別々に書くと静かに drift する）
  echo "RULE=3|standard|実装ファイルを含む（上記以外）"
  exit 0
fi

# ---- 判定に使う path 一覧を集める --------------------------------------------
SOURCE=""
PATHS=""

# `--base` は確定判定（差分から導出）専用。path を渡す暫定判定では使われないので、
# 併用を黙って無視すると `--base main docs/a.md` を「main と比べた」と読む誤解が残る。
# `--paths-from` + path 引数を止めているのと同じ理由で、こちらも使い方の誤りとして扱う。
if [ "${BASE_EXPLICIT}" -eq 1 ] && { [ -n "${PATHS_FROM}" ] || [ ${#ARG_PATHS[@]} -gt 0 ]; }; then
  die_usage "--base は確定判定（引数なし）専用です。path を渡す暫定判定では使えません"
fi

if [ -n "${PATHS_FROM}" ]; then
  if [ ${#ARG_PATHS[@]} -gt 0 ]; then
    die_usage "--paths-from と path 引数は同時に使えません（判定材料の出所を 1 つに保つため）"
  fi
  # cat の終了コードを見る。読めなかった入力を握り潰すと「0 件 → standard」へ落ちるが、
  # それは**判定できた結果**として exit 0 を返す形になり、検査不能（exit 2）と区別が
  # 付かなくなる。`[ -f ]` を通っても読み取り権限が無い / 読み出しに失敗する経路は残る。
  if [ "${PATHS_FROM}" = "-" ]; then
    SOURCE="stdin"
    PATHS="$(cat)" || unavailable "stdin から path 一覧を読み出せませんでした"
  else
    [ -f "${PATHS_FROM}" ] || unavailable "path 一覧が読めません: ${PATHS_FROM}"
    SOURCE="file"
    PATHS="$(cat "${PATHS_FROM}" 2>&1)" || unavailable "path 一覧の読み出しに失敗しました: ${PATHS_FROM}（${PATHS}）"
  fi
elif [ ${#ARG_PATHS[@]} -gt 0 ]; then
  SOURCE="args"
  PATHS="$(printf '%s\n' "${ARG_PATHS[@]}")"
else
  SOURCE="diff"
  git rev-parse --git-dir >/dev/null 2>&1 || unavailable "git リポジトリの外で実行されました"
  git rev-parse --verify --quiet "${BASE}" >/dev/null 2>&1 \
    || unavailable "base ref を解決できません: ${BASE}（--base か WORKFLOW_TIER_BASE で指定してください）"
  # `--no-renames` は必須。rename 検出が効くと `--name-only` は**移動後の path しか
  # 出さない**ため、`docs-template/a.md` → `b.md` の移動が「.md のみ = light」へ化け、
  # 配布物からファイルが消えた変更が軽い側で通る（実測で確認）。分割して両方の path を
  # 出せば規則 1 が移動元を捕まえる。同型の実バグは ACE-460-1（パスで分類するツールは
  # `--no-renames` を付ける。`docs-template/08-knowledge/PLAYBOOK.md` にある**上流由来**の
  # エントリで、本リポジトリの playbook からは引けない）。
  # 成功経路では stderr を混ぜない（`warning:` の類が path 一覧へ紛れ込むため）。
  # 失敗したときだけ同じコマンドを stderr 取りで走らせ、理由を SKIP_REASON へ載せる。
  # ここへ来るのは rev-parse を通った後なので、「共通祖先が無い」など**理由を読まないと
  # 直せない**失敗が多い。コマンドラインの再掲だけでは運用者が動けない。
  # `core.quotepath=false` も必須。既定（true）では非 ASCII を含む path が
  # `"docs-template/\346\227\245.md"` の形で C クォートされて出るため、**前後の `"` で
  # 規則 1 の `(^|/)docs-template/` にも規則 2 の `\.md$` にも当たらなくなる**（実測）。
  # 配布物配下の日本語ファイル名の変更が full ではなく standard へ落ちる。
  # args / stdin 経路は生の path なので影響を受けない。
  if ! PATHS="$(git -c core.quotepath=false diff --no-renames --name-only "${BASE}...HEAD" 2>/dev/null)"; then
    DIFF_ERR="$(git -c core.quotepath=false diff --no-renames --name-only "${BASE}...HEAD" 2>&1 >/dev/null)"
    unavailable "git diff --no-renames --name-only ${BASE}...HEAD が失敗しました: ${DIFF_ERR:-理由なし}"
  fi
fi

# 判定材料が揃った時点で full パターンを検証する。空判定より**前**に置くのが要点で、
# 後ろに置くと「壊れた上書きパターン + 空差分」が exit 2 ではなく exit 0 standard を
# 返し、設定ミスが検査不能として報告されない。
validate_full_patterns

# 空行を落とす（引数の空文字列・末尾改行・空ファイルを件数に数えない）。
# `|| true` では grep の rc=1（全行が空行）と rc>=2（エラー）が同一視され、壊れた
# grep が「0 件 = 空差分」という**断定的な REASON** で報告される。rc を分ける。
PATHS_CLEAN="$(printf '%s\n' "${PATHS}" | grep -v '^[[:space:]]*$')"
GREP_RC=$?
if [ "${GREP_RC}" -gt 1 ]; then
  unavailable "path 一覧の整形に失敗しました（grep rc=${GREP_RC}）。0 件と区別が付かないため判定しません"
fi
PATHS="${PATHS_CLEAN}"

if [ -z "${PATHS}" ]; then
  echo "WORKFLOW_TIER=standard"
  echo "REASON=判定に使える path が 0 件のため fail-closed で標準にした（空差分を軽量と読み替えない）"
  echo "SOURCE=${SOURCE}"
  echo "CHANGED=0"
  exit 0
fi

CHANGED="$(printf '%s\n' "${PATHS}" | wc -l | tr -d ' ')"

# ---- 規則 1: full -------------------------------------------------------------
# パターンは改行区切りで回す。パイプ（`| while`）はサブシェルになって MATCHED が
# 呼び出し元へ戻らず、here-doc / here-string は bash が一時ファイルを作る（書き込み
# 不可の TMPDIR で落ちる）。IFS を改行に固定した for が両方を避ける。
# IFS を改行に固定した for が両方を避ける（プロセス置換でも避けられるが `/dev/fd` を要求する）。
# glob 展開は `set -f` で止める（パターンに `*` や `[` を含む上書きを壊さないため）。
MATCHED=""
WT_OLD_IFS="${IFS}"
set -f
IFS='
'
for pat in ${FULL_PATTERNS}; do
  [ -n "${pat}" ] || continue
  hit="$(printf '%s\n' "${PATHS}" | grep -E -- "${pat}" | head -1)"
  if [ -n "${hit}" ]; then
    MATCHED="${hit}"
    break
  fi
done
IFS="${WT_OLD_IFS}"
set +f

if [ -n "${MATCHED}" ]; then
  echo "WORKFLOW_TIER=full"
  echo "REASON=配布・リリースへ影響する path を含む"
  echo "SOURCE=${SOURCE}"
  echo "CHANGED=${CHANGED}"
  echo "MATCHED=${MATCHED}"
  exit 0
fi

# ---- 規則 2: light ------------------------------------------------------------
# 否定形（「.md 以外が 1 件も無い」）で書くと、grep が失敗したとき（rc=2 の regex /
# 入出力エラー、rc=127 の不在、ロケール由来の失敗）も「無い」と同じ空文字列になり、
# **最も軽い tier へ静かに落ちる**。規則 1 で潰したのと同型の穴で、しかも落ち先が
# standard ではなく light（= /spec-driven が G1〜G2 を簡略化する側）になる。
# 肯定形で数え、総数と一致するかで判定する。grep が壊れれば件数が合わず standard へ
# 倒れ、rc>=2 は検査不能として止まる。
MD_COUNT="$(printf '%s\n' "${PATHS}" | grep -c '\.md$')"
MD_RC=$?
if [ "${MD_RC}" -gt 1 ]; then
  unavailable ".md 判定に失敗しました（grep rc=${MD_RC}）。軽い側へ倒さないため判定しません"
fi
if [ "${MD_COUNT}" -eq "${CHANGED}" ]; then
  echo "WORKFLOW_TIER=light"
  echo "REASON=変更が .md のみ"
  echo "SOURCE=${SOURCE}"
  echo "CHANGED=${CHANGED}"
  exit 0
fi

# ---- 規則 3: standard ---------------------------------------------------------
echo "WORKFLOW_TIER=standard"
echo "REASON=実装ファイルを含む（上記以外）"
echo "SOURCE=${SOURCE}"
echo "CHANGED=${CHANGED}"
exit 0
