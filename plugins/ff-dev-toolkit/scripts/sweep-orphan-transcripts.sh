#!/usr/bin/env bash
# sweep-orphan-transcripts.sh — 既存の孤児 Claude Code トランスクリプトを回収する
#
# Issue #280 / 公開 feel-flow/ff-dev-toolkit#8 の残課題。
# /merge-cleanup Step 5.5 は「今回削除した worktree の分」だけを回収する。
# 本スクリプトは <config>/projects/ 全体を走査し、jsonl の cwd がすべて
# 現存しないディレクトリだけを候補にする（証拠が無いものは触らない）。
#
# 保護の多層化（feel-flow/ff-dev-toolkit#13）: cwd 判定の前に、
#  (1) ディレクトリ名が現存パスへ解決できる（プロジェクトのルートが生存）
#  (2) 空でない memory/ が同居する（次回セッションが読む永続資産）
# のいずれかに当たれば触らない。ルート起動→worktree 作業→worktree 削除で
# cwd が全滅しても名前は生き続ける乖離から memory/ を守る。
#
# 既定は dry-run（一覧と見込み容量のみ）。破壊は --apply を明示したときだけ。
#
# 使い方:
#   bash scripts/sweep-orphan-transcripts.sh              # dry-run
#   bash scripts/sweep-orphan-transcripts.sh --apply      # アーカイブ + 元削除
#   bash scripts/sweep-orphan-transcripts.sh --help
#
# 環境変数:
#   CLAUDE_CONFIG_DIR                 既定 ~/.claude
#   FF_SWEEP_PROJECTS_DIR             projects の上書き
#   FF_SWEEP_ARCHIVE_DIR              アーカイブ先（既定 <config>/transcript-archives）
#
# 終了コード:
#   0  成功（dry-run / 回収完了 / 候補 0）
#   1  失敗（走査エラー・アーカイブ失敗など 1 件以上）
#   2  用法エラー
#
# bash 3.2 互換（macOS 標準 /bin/bash）。

set -euo pipefail

MODE="dry-run"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help)
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1（--apply / --dry-run / --help のみ）" >&2
      exit 2
      ;;
  esac
done

resolve_dir() {
  ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

# $1: 候補ディレクトリ
# 戻り値:
#   0 = 孤児（cwd は 1 件以上あり、いずれも現存しない）
#   2 = cwd を記録した jsonl が無い（触らない）
#   3 = 現存する cwd がある（稼働中の可能性 → 触らない）
#   4 = 走査エラー（触らない + 失敗報告）
collect_cwds() {
  local dir="$1"
  local scan_err="$WORK_TMP/scan_err"
  local values="" line="" value=""

  : > "$scan_err"
  : > "$WORK_TMP/cwds"
  values="$( { find "$dir" -type f -name '*.jsonl' -exec grep -oh '"cwd":"[^"]*"' {} + | sort -u ; } 2>"$scan_err" )" || true
  if [ -s "$scan_err" ]; then
    return 4
  fi
  [ -n "$values" ] || return 2

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    value="${line#\"cwd\":\"}"
    value="${value%\"}"
    [ -n "$value" ] || continue
    printf '%s\n' "$value" >> "$WORK_TMP/cwds"
  done <<< "$values"

  [ -s "$WORK_TMP/cwds" ] || return 2

  while IFS= read -r value; do
    [ -n "$value" ] || continue
    # 存在するディレクトリが 1 つでもあれば live
    if [ -d "$value" ]; then
      return 3
    fi
  done < "$WORK_TMP/cwds"

  return 0
}

# name_resolves_to_live: プロジェクトディレクトリ名（cwd の絶対パスを / → - で
# エンコードしたもの）を、実ファイルシステムを辿って現存パスへ解決できるか判定する。
#
# なぜ「名前をパスへ戻して現存確認」が正当なのか（PR #279 / ACE-279-1 との関係）:
#   #279 は「候補名は削除対象パスから機械的に導出したものなので、名前へのパターン
#   照合は入力の言い換えにすぎず対象の同一性を確認していない」として、削除の根拠を
#   名前に置く経路を全廃した。本関数はその逆で、削除ではなく保護の根拠として名前を
#   使い、しかも照合先は名前パターンではなく実ファイルシステム（対象から独立した外部
#   世界）である。名前が指すパスが今この瞬間に現存するかは、対象が記録した情報ではなく
#   OS へ問い合わせて初めて分かる事実であり、入力の再表示ではない。
#
# エンコードは非可逆（/ . - がいずれも - になり得る）なので tr '-' '/' では戻せない。
# しかも実測では 1 通りに定まらない — ドット始まりディレクトリ `.claude` は環境/時期で
# `-.claude`（ドット保持）と `--claude`（ドットも - 化）の両方が現れる。そこで「エンコード
# を逆算」せず、**先頭 `-` を `/` 起点にし、残り文字列を `-` 境界で最長優先に区切りながら、
# その prefix が指す実ディレクトリを直接 -d で確かめて降りる**。実ディレクトリに当たった
# パスだけが前進なので、判定材料は常に実ファイルシステム。子名にハイフンが含まれても
# 境界の取り方（最長→短）で取りこぼさない。行き止まりはバックトラックする。
#
# 子ディレクトリの列挙はしない（意図的）。~/.claude 配下には T/（4000+ エントリ）のような
# 極端に広い階層が実在し、階層ごとに全子を列挙して再エンコード照合すると非解決名で
# 事実上ハングする（実測）。rest から候補パスを構成して直接 stat する方式は、階層あたりの
# 分岐が「境界数 × ドット綴り 2」に限られ、広い階層でも一定時間で終わる。
#
# 既知の制約: セグメント内部のドット（`Finder.app` → `Finder-app`）は復元しない。
# ドット補完はセグメント先頭（`.claude` 等、ドット始まりディレクトリ）に限る。内部ドットの
# プロジェクトは名前解決では守れないが、これは fail-closed 側（memory ガード / 従来 cwd
# 判定へ委譲）に倒れるだけで、削除方向の誤りにはならない。実データでも稀。
#
# 例: -ROOT-x-ai-feel-chatbot は ROOT/x/ai/feel/chatbot（非現存・素朴分割）ではなく
#     ROOT/x/ai-feel-chatbot（現存・子名にハイフン）へ解決される（ROOT は絶対パス起点）。
#
# 三値判定（fail-closed の要）: 破壊的ツールなので「解決できない」と「判定できなかった」を
# 分ける。予算超過は「判定不能」であって「非現存の証拠」ではない。
#   0 = 現存パスへ解決できた（保護）
#   1 = 解決できない（従来 cwd 判定へ委ねる）
#   2 = 判定不能（予算超過）→ 呼び出し側で保護 + 報告（削除経路へ落とさない）
#
# 探索の総ステップ予算。深く分岐の多い非解決名でバックトラックが膨らんでも必ず停止する
# よう上限を設ける。超過は 1（非解決）ではなく 2（判定不能）で返し fail-closed 側（保護）へ
# 倒す。実在プロジェクト名は浅く各階層で一意に近いので正常系は遠く及ばない。
# テストが極小値を注入して予算切れ経路を検証できるよう env 上書きを許す（既定 4000）。
NAME_RESOLVE_BUDGET="${NAME_RESOLVE_BUDGET:-4000}"

# $1: プロジェクトディレクトリ名（basename）
# 戻り値: 0 = 解決（保護）/ 1 = 非解決（従来判定へ）/ 2 = 判定不能（保護 + 報告）
name_resolves_to_live() {
  local name="$1"
  # 絶対パス起点（先頭 -）のみ対象。相対名は解決不能扱い。
  # 先頭 - を除いた残りが空（name が "-" 単体）も対象外: ルート / への解決は
  # 「対象の同一性」を何も確認しないので生存とみなさない（少なくとも 1 セグメント
  # を実ディレクトリとして辿れたときだけ保護する）。
  case "$name" in
    -?*) ;;
    *) return 1 ;;
  esac
  NAME_RESOLVE_STEPS=0
  _name_resolve_rec "/" "${name#-}"
}

# _name_resolve_rec: base（確定済み実パス）配下で、rest の先頭を '-' 境界で最長優先に
# 区切りながら、その prefix が指す実ディレクトリへ直接降りる（子は列挙しない）。
# ドット始まりディレクトリ（`.claude` が `-.claude` とも `--claude` とも綴られる実測差）に
# 対応するため、各セグメント候補を「そのまま」と「先頭にドットを補う」の 2 通りで試す。
# rest は非空で呼ばれる。1 セグメント以上辿れたときだけ成功する。
# 戻り値: 0 = 解決 / 1 = 非解決 / 2 = 判定不能（予算超過が探索中に起きた）
# $1: 確定済み実パス（"/" または末尾スラッシュ無しの絶対パス）
# $2: 残りエンコード文字列（先頭に区切り無し。空でない）
_name_resolve_rec() {
  local base="$1" rest="$2"
  # rest が '-' で始まる = 直前の境界が '--'（元パスのドット始まりディレクトリを
  # ドットごと - 化した綴り）。先頭 '-' を剥がし、次のセグメントは「ドット始まり必須」
  # として解決する。これで `--claude` → `.claude` を辿れる。
  local force_dot=0
  if [ "${rest#-}" != "$rest" ]; then
    rest="${rest#-}"
    force_dot=1
  fi
  [ -n "$rest" ] || return 1
  local n="${#rest}" k seg nextrest trypath cand rc saw_undecided=0
  for (( k=n; k>=1; k-- )); do
    # 予算切れは「判定不能(2)」で返す。非解決(1)ではないので削除経路へ落とさない。
    NAME_RESOLVE_STEPS=$((NAME_RESOLVE_STEPS + 1))
    if [ "$NAME_RESOLVE_STEPS" -gt "$NAME_RESOLVE_BUDGET" ]; then
      return 2
    fi
    if [ "$k" -eq "$n" ]; then
      seg="${rest:0:k}"; nextrest=""
    else
      # 境界文字は '-' でなければならない
      if [ "${rest:k:1}" != "-" ]; then
        continue
      fi
      seg="${rest:0:k}"; nextrest="${rest:k+1}"
    fi
    # seg の綴りは 2 系統だけ:
    #  - force_dot=0（区切りが単一 '-'）: セグメントはそのまま。ドット始まりディレクトリ
    #    `.claude` は `-.claude` と綴られ、境界後の seg が既に ".claude"（ドット込み）に
    #    なるので bare で解ける。ここで無条件に ".$seg" を試すと、通常名 plain が隠し
    #    ディレクトリ .plain へ誤解決する過剰保護（真の孤児が消えない）を生むので試さない。
    #  - force_dot=1（区切りが '--'）: ドット始まり確定。".$seg" だけを試す（`--claude`→.claude）。
    if [ "$force_dot" -eq 1 ]; then
      cand=".$seg"
    else
      cand="$seg"
    fi
    # ".<空>" = "." / ".." は自己参照・親参照でループの元。1 セグメント以上前進を要求。
    case "$cand" in ''|.|..) continue ;; esac
    if [ "$base" = "/" ]; then
      trypath="/$cand"
    else
      trypath="$base/$cand"
    fi
    # symlink は辿らない（実体のみ）。外部脱出とループを防ぐ。
    if [ -d "$trypath" ] && [ ! -L "$trypath" ]; then
      if [ -z "$nextrest" ]; then
        return 0
      fi
      _name_resolve_rec "$trypath" "$nextrest"; rc=$?
      if [ "$rc" -eq 0 ]; then
        return 0
      elif [ "$rc" -eq 2 ]; then
        saw_undecided=1   # この枝は判定不能。他枝で解決できなければ 2 を返す。
      fi
    fi
  done
  [ "$saw_undecided" -eq 1 ] && return 2
  return 1
}

# has_nonempty_memory: 候補配下に空でない memory/ があるか。
# 名前解決が失敗しても、保護すべき資産（次回セッションが読む永続メモリ）そのものを
# 直接見て守るための安価なガード。memory/ 配下の任意の深さに 1 つでも非ディレクトリ
# 実体（ファイル・symlink 等）があれば「空でない」。
# 三値（collect_cwds の走査エラー扱いに揃える）:
#   0 = 空でない memory/ あり（保護）
#   1 = memory/ が無い or 空（従来判定へ委ねる）
#   2 = memory/ はあるが走査に失敗（判定不能）→ 呼び出し側で保護 + 報告
# $1: 候補の実パス
has_nonempty_memory() {
  local dir="$1"
  [ -d "$dir/memory" ] || return 1
  # find の失敗（権限等）を「memory 無し」に握り潰すと、守るべき資産を守れないまま
  # 削除経路へ落ちうる（silent fail-open）。stderr の有無で「空」と「読めない」を分け、
  # 読めないときは 2 を返して保護側へ倒す（collect_cwds と同じ思想）。
  local found="" merr="$WORK_TMP/memory_scan_err"
  : > "$merr"
  found="$(find "$dir/memory" -mindepth 1 ! -type d -print -quit 2>"$merr")" || true
  if [ -s "$merr" ]; then
    return 2
  fi
  [ -n "$found" ]
}

dir_kb() {
  local kb=""
  kb="$(du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')" || kb=""
  if [ -z "$kb" ]; then
    echo 0
  else
    echo "$kb"
  fi
}

archive_and_remove() {
  # $1: CAND_NAME  $2: CAND_PATH  $3: CAND_REAL  $4: PROJECTS_REAL  $5: ARCHIVE_DIR
  local CAND_NAME="$1" CAND_PATH="$2" CAND_REAL="$3" PROJECTS_REAL="$4" ARCHIVE_DIR="$5"
  local CAND_KB ARCHIVE_STAMP ARCHIVE_FILE ARCHIVE_SEQ ARCHIVE_TMP
  local ARCHIVE_LIST ARCHIVE_ERR ARCHIVE_MARKER TAR_OUT ARCHIVE_FAIL
  local SRC_ENTRIES ARC_ENTRIES RECHECK_REAL ARCHIVE_KB

  CAND_KB="$(dir_kb "$CAND_REAL")"

  ARCHIVE_STAMP="$(date +%Y%m%d-%H%M%S)"
  ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP.tar.gz"
  ARCHIVE_SEQ=1
  while [ -e "$ARCHIVE_FILE" ] || [ -L "$ARCHIVE_FILE" ]; do
    ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP-$ARCHIVE_SEQ.tar.gz"
    ARCHIVE_SEQ=$((ARCHIVE_SEQ + 1))
  done

  ARCHIVE_TMP=""
  if ! ARCHIVE_TMP="$(mktemp "$ARCHIVE_DIR/.sweep-orphan-archive-XXXXXX")"; then
    echo "  ❌ 作業ファイルを作成できません: $CAND_NAME" >&2
    return 1
  fi
  ARCHIVE_LIST="$WORK_TMP/archive_list"
  ARCHIVE_ERR="$WORK_TMP/archive_error"
  ARCHIVE_MARKER="$WORK_TMP/archive_marker"
  : > "$ARCHIVE_MARKER"
  TAR_OUT=""
  ARCHIVE_FAIL=""

  if ! TAR_OUT="$(tar -czf "$ARCHIVE_TMP" -C "$PROJECTS_REAL" "./$CAND_NAME" 2>&1)"; then
    ARCHIVE_FAIL="tar が失敗しました"
  elif ! tar -tzf "$ARCHIVE_TMP" > "$ARCHIVE_LIST" 2>"$ARCHIVE_ERR"; then
    TAR_OUT="$(cat "$ARCHIVE_ERR")"
    ARCHIVE_FAIL="アーカイブを読み直せませんでした"
  else
    SRC_ENTRIES=""
    SRC_ENTRIES="$(find "$CAND_REAL" ! -type d 2>/dev/null | wc -l | tr -d ' ')" || SRC_ENTRIES=""
    ARC_ENTRIES="$(grep -cv '/$' "$ARCHIVE_LIST" || true)"
    if [ -z "$SRC_ENTRIES" ] || [ "$SRC_ENTRIES" != "$ARC_ENTRIES" ]; then
      TAR_OUT="元 ${SRC_ENTRIES:-?} 件 / アーカイブ ${ARC_ENTRIES} 件"
      ARCHIVE_FAIL="アーカイブの件数が元と一致しません"
    elif [ -n "$(find "$CAND_REAL" ! -type d -newer "$ARCHIVE_MARKER" -print -quit 2>/dev/null)" ]; then
      TAR_OUT="アーカイブ中に更新されたファイルがあります"
      ARCHIVE_FAIL="アーカイブ中に元が変更されました"
    fi
  fi

  if [ -n "$ARCHIVE_FAIL" ]; then
    echo "  ❌ ${ARCHIVE_FAIL}。元は残します: $CAND_NAME" >&2
    printf '%s\n' "$TAR_OUT" | sed 's/^/     /' >&2 || true
    rm -f "$ARCHIVE_TMP" || true
    return 1
  fi

  if ! mv "$ARCHIVE_TMP" "$ARCHIVE_FILE"; then
    echo "  ❌ アーカイブの確定に失敗。元は残します: $CAND_NAME" >&2
    rm -f "$ARCHIVE_TMP" || true
    return 1
  fi

  RECHECK_REAL=""
  if [ -L "$CAND_PATH" ] \
    || ! RECHECK_REAL="$(resolve_dir "$CAND_PATH")" \
    || [ "$RECHECK_REAL" != "$CAND_REAL" ] \
    || [ "$(dirname "$RECHECK_REAL")" != "$PROJECTS_REAL" ]; then
    echo "  ⚠️ 削除直前の再確認に失敗したため元は残します: $CAND_NAME" >&2
    echo "     アーカイブは作成済み: $ARCHIVE_FILE" >&2
    return 1
  fi

  if ! rm -rf "$CAND_REAL"; then
    echo "  ❌ アーカイブ後の削除に失敗（二重残存）: $CAND_REAL" >&2
    return 1
  fi

  ARCHIVE_KB="$(dir_kb "$ARCHIVE_FILE")"
  echo "  ✓ archived: $CAND_NAME (${CAND_KB} KB → ${ARCHIVE_KB} KB)"
  ARCHIVED_KB=$((ARCHIVED_KB + CAND_KB))
  ARCHIVE_OUT_KB=$((ARCHIVE_OUT_KB + ARCHIVE_KB))
  ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
  return 0
}

WORK_TMP=""
WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-orphan-XXXXXX")" || {
  echo "ERROR: 一時ディレクトリを作成できません" >&2
  exit 1
}
trap 'rm -rf "$WORK_TMP"' EXIT

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
PROJECTS_DIR="${FF_SWEEP_PROJECTS_DIR:-$CLAUDE_HOME/projects}"
ARCHIVE_DIR="${FF_SWEEP_ARCHIVE_DIR:-$CLAUDE_HOME/transcript-archives}"

PROJECTS_REAL=""
if ! PROJECTS_REAL="$(resolve_dir "$PROJECTS_DIR")"; then
  echo "ERROR: projects ディレクトリを解決できません: $PROJECTS_DIR" >&2
  exit 1
fi

echo "🗂 孤児トランスクリプト sweep"
echo "   mode: $MODE"
echo "   projects: $PROJECTS_REAL"
echo "   archive: $ARCHIVE_DIR"
echo ""

ORPHAN_COUNT=0
ORPHAN_KB=0
SKIP_LIVE=0
SKIP_NO_CWD=0
SKIP_SYMLINK=0
SKIP_PATH=0
SKIP_NAME_ALIVE=0
SKIP_MEMORY=0
FAIL_COUNT=0
ARCHIVED_COUNT=0
ARCHIVED_KB=0
ARCHIVE_OUT_KB=0
ARCHIVE_DIR_READY=0

# projects 直下だけ（サブディレクトリの再帰は projects の構造上不要）
# bash 3.2: mapfile 無し。nullglob 相当は手動。
shopt -s nullglob
for CAND_PATH in "$PROJECTS_DIR"/*; do
  CAND_NAME="$(basename "$CAND_PATH")"
  case "$CAND_NAME" in
    ''|.|..) continue ;;
  esac

  if [ ! -d "$CAND_PATH" ]; then
    continue
  fi

  if [ -L "$CAND_PATH" ]; then
    SKIP_SYMLINK=$((SKIP_SYMLINK + 1))
    continue
  fi

  CAND_REAL=""
  if ! CAND_REAL="$(resolve_dir "$CAND_PATH")" \
    || [ "$(dirname "$CAND_REAL")" != "$PROJECTS_REAL" ]; then
    SKIP_PATH=$((SKIP_PATH + 1))
    echo "  ○ projects 直下へ解決されないためスキップ: $CAND_NAME"
    continue
  fi

  # Issue #13: cwd 判定より前に、保護を強める 2 つのガードを OR で入れる（どちらか一方
  # でも当たれば保護）。いずれも fail-closed 側で、cwd が「孤児」と言っても上書きして守る。
  # 各ガードは三値: 0=保護 / 1=従来判定へ委ねる / 2=判定不能（保護 + FAIL 計上して報告）。
  # 「解決できない(1)」と「判定できなかった(2)」を分け、破壊的ツールとして 2 は削除経路へ
  # 落とさず必ず保護する。
  # (1) ディレクトリ名が現存パスへ解決できる = そのプロジェクトのルートは生存中。
  #     worktree から起動して worktree を消すと cwd は全滅するが名前は生き続ける乖離を捕まえる。
  NAME_VERDICT=0
  name_resolves_to_live "$CAND_NAME" || NAME_VERDICT=$?
  if [ "$NAME_VERDICT" -eq 0 ]; then
    SKIP_NAME_ALIVE=$((SKIP_NAME_ALIVE + 1))
    continue
  elif [ "$NAME_VERDICT" -eq 2 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  ⚠️ 名前解決が判定不能（予算超過/走査エラー）のため保護: $CAND_NAME" >&2
    continue
  fi
  # (2) 空でない memory/ が同居する = 次回セッションが読む永続資産がある。
  #     名前解決が失敗しても、守るべき資産そのものを直接見て守る最後の砦。
  MEM_VERDICT=0
  has_nonempty_memory "$CAND_REAL" || MEM_VERDICT=$?
  if [ "$MEM_VERDICT" -eq 0 ]; then
    SKIP_MEMORY=$((SKIP_MEMORY + 1))
    continue
  elif [ "$MEM_VERDICT" -eq 2 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  ⚠️ memory/ の走査が判定不能（読み取り不可）のため保護: $CAND_NAME" >&2
    continue
  fi

  VERDICT=0
  collect_cwds "$CAND_REAL" || VERDICT=$?
  case "$VERDICT" in
    0)
      KB="$(dir_kb "$CAND_REAL")"
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
      ORPHAN_KB=$((ORPHAN_KB + KB))
      SAMPLE="$(head -3 "$WORK_TMP/cwds" | tr '\n' ' ')"
      if [ "$MODE" = "dry-run" ]; then
        echo "  · orphan (${KB} KB): $CAND_NAME"
        echo "      cwd 例: $SAMPLE"
      else
        if [ "$ARCHIVE_DIR_READY" != "1" ]; then
          if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
            echo "ERROR: アーカイブ先を作成できません: $ARCHIVE_DIR" >&2
            exit 1
          fi
          ARCHIVE_DIR_READY=1
        fi
        echo "  → 回収: $CAND_NAME (${KB} KB)"
        if ! archive_and_remove "$CAND_NAME" "$CAND_PATH" "$CAND_REAL" "$PROJECTS_REAL" "$ARCHIVE_DIR"; then
          FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
      fi
      ;;
    2)
      SKIP_NO_CWD=$((SKIP_NO_CWD + 1))
      ;;
    3)
      SKIP_LIVE=$((SKIP_LIVE + 1))
      ;;
    4)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  ⚠️ jsonl 走査エラーのため保護: $CAND_NAME" >&2
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  ⚠️ 想定外の判定 ($VERDICT): $CAND_NAME" >&2
      ;;
  esac
done
shopt -u nullglob

echo ""
echo "=== サマリー ==="
echo "mode: $MODE"
echo "孤児候補: ${ORPHAN_COUNT} 件 / ${ORPHAN_KB} KB"
echo "スキップ live(cwd 現存): ${SKIP_LIVE}"
echo "スキップ 名前生存(名前→現存パス): ${SKIP_NAME_ALIVE}"
echo "スキップ memory 保護(空でない memory/): ${SKIP_MEMORY}"
echo "スキップ cwd 無し: ${SKIP_NO_CWD}"
echo "スキップ symlink: ${SKIP_SYMLINK}"
echo "スキップ path 保護: ${SKIP_PATH}"
echo "失敗: ${FAIL_COUNT}"
# スキップ理由は上から順（symlink/path → 名前生存 → memory → cwd）に先勝ちで数える。
# 名前が現存パスへ解決される稼働中プロジェクトは「名前生存」に入り、cwd 現存判定
# （live）まで到達しないため、live は「名前非解決 かつ memory 無し かつ cwd 現存」の残余。
echo "（スキップ理由は先勝ち。名前生存/memory は cwd 判定より前に評価される）"
if [ "$MODE" = "apply" ]; then
  echo "アーカイブ回収: ${ARCHIVED_COUNT} 件 / 元 ${ARCHIVED_KB} KB → 書庫 ${ARCHIVE_OUT_KB} KB"
else
  echo "（dry-run のため削除していません。回収するには --apply を付けて再実行）"
fi

# subagents 方針の短い注記（Issue #281）
echo ""
echo "注: 孤児と判定したプロジェクトディレクトリ全体（配下の subagents/ を含む）を回収します。"
echo "    稼働中プロジェクト内の subagents/ だけを年齢で消すことはしません（所有証拠が無いため）。"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
