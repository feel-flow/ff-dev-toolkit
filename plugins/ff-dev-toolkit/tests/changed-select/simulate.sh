#!/usr/bin/env bash
#
# simulate.sh — 評価集合（過去の PR）へ今の部分ゲートの選択を当て、回す秒数の全件比を出す（Issue `#3006`）
#
# suite は実行しない。各 PR の変更一覧（`git show --name-only`）を tests/run-all.sh の試算モード
# （FF_RUN_ALL_SELECT_ONLY=1 + FF_RUN_ALL_CHANGED_FILES_FROM）へ渡し、ランナーそのものが返す選択を
# suite ごとの秒数のスナップショットで足し合わせる。選択の仕組みや宣言を変えたら、これで前後を比べる。
# --expect では、決めた変更で決めた suite が選ばれるかを照合する（選択の漏れの回帰検査）。
#
# 使い方:
# --- usage:start ---
#   simulate.sh [--eval <FILE>] [--secs <FILE>] [--limit <N>] [--max-avg <%>] [--md-only <PR,...> --max-md <%>]
#               [--runner <FILE>] [--tests-dir <DIR>]
#   simulate.sh --expect <FILE> [--runner <FILE>] [--tests-dir <DIR>]
# --- usage:end ---
#
#   既定の --eval / --secs は同じディレクトリの data/eval-set.tsv（<SHA><TAB><PR 番号>。SHA はこのスクリプトの
#   あるリポジトリのコミット）と data/suite-seconds.tsv（<suite><TAB><秒>）。--limit は先頭の N 本だけを当てる
#   （手早い確認用）。--max-avg を渡すと、PR 1 本あたりの全件比の平均がそれを超えたら終了コード 1。--md-only と
#   --max-md を渡すと、名指しした PR の全件比がどれか 1 本でもそれを超えたら終了コード 1。比較は秒数の比そのもの
#   で行う（表示は小数 1 桁へ切り捨てるが、50.04% は 50% を超えたと判定する）。
#   --runner / --tests-dir はランナーと登録一覧（<DIR>/<名前>/verify.sh の実行できるもの）の差し替え口（検査用）。
#   判定できない回は終了コード 2: 評価集合や秒数を読めない・PR のコミットが手元に無い・変更一覧が空・ランナーが
#   選択を返さない・選んだ件数（`select-only: mode=changed selected=N`）と suite の行の数が合わない。
#   使い方の誤り（値の無いオプション・数でない値）は終了コード 64。
#
#   --expect は「このファイルが変わったら、この suite は選ばれなければならない」の照合（漏れの回帰検査）。
#   <FILE> の各行は <変更パス><TAB><suite><TAB><出典>。変更パスは宣言と同じ書き方（プラグインルート相対。`/` で
#   始めるとリポジトリルート相対）。変更パスごとにそのパスだけを変えた変更一覧へランナーの選択を当て、suite が
#   選ばれる（または全件へ倒れる。倒れた理由を行に添える）ことを確かめる。照合するのは依存の宣言
#   （`# run-all-depends:`）を持つ suite の行だけで、宣言の無い suite の行は数えて飛ばす（字面の照合は宣言の
#   仕組みの外）。選ばれない行が 1 つでもあれば終了コード 1。判定できない回は終了コード 2: ファイルを読めない・
#   列が欠けた行・読み込んだ行の数がデータ行の数と合わない（改行で終わらない最終行を落とした等）・変更パスが
#   実在しない（行が古い）・suite が登録に無い・suite のファイルを列挙できない／読めない・ランナーが選択を
#   返さない（モードが full / changed のどちらでもない回を含む）・選んだ件数と suite の行の数が合わない・照合した
#   行が 0 件（宣言のある suite の行が 1 つも無い）。リポジトリルート相対の行は開発元の配置を前提にするので、changed-select は公開リポジトリの
#   suite セットから外している（公開 workflow の EXCLUDED_SSOT_SUITES）。
#
# 近似（読むときの注意）:
#   - suite の集合・字面・宣言は今の木で導出する（PR 当時の木ではない）
#   - 秒数は 1 回の全件ゲートの経過秒（5 並列の負荷込み）。スナップショットに無い suite は 0 秒と数え、
#     名前を出す（新しい suite を足したら、スナップショットを取り直す）。例外の行（changed-select）は単体の
#     実測で、理由は data/suite-seconds.tsv のコメント
#   - 全件（分母）は、今の登録一覧のうち選択に入れない suite（public-layout）を除いた合計
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$HERE/.." && pwd)"
RUNNER=""
EVAL="$HERE/data/eval-set.tsv"
SECS="$HERE/data/suite-seconds.tsv"
LIMIT=0
MAX_AVG=""
MD_ONLY=""
MAX_MD=""
EXPECT=""

usage() { sed -n '/^# --- usage:start ---$/,/^# --- usage:end ---$/p' "$0" | sed '1d;$d;s/^#//' >&2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --eval|--secs|--limit|--max-avg|--md-only|--max-md|--runner|--tests-dir|--expect)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "simulate.sh: $1 に値が無い" >&2; usage; exit 64; fi
      case "$1" in
        --expect) EXPECT="$2" ;;
        --eval) EVAL="$2" ;;
        --secs) SECS="$2" ;;
        --limit) LIMIT="$2" ;;
        --max-avg) MAX_AVG="$2" ;;
        --md-only) MD_ONLY="$2" ;;
        --max-md) MAX_MD="$2" ;;
        --runner) RUNNER="$2" ;;
        --tests-dir) TESTS_DIR="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "simulate.sh: 未知の引数: $1" >&2; usage; exit 64 ;;
  esac
done
case "$LIMIT" in ''|*[!0-9]*) echo "simulate.sh: --limit は 0 以上の整数" >&2; exit 64 ;; esac
for v in "$MAX_AVG" "$MAX_MD"; do
  case "$v" in ''|[0-9]|[0-9][0-9]|100) ;; *) echo "simulate.sh: 閾値は 0〜100 の整数: ${v}" >&2; exit 64 ;; esac
done
if [ -n "$MD_ONLY" ] && [ -z "$MAX_MD" ]; then echo "simulate.sh: --md-only には --max-md が要る" >&2; exit 64; fi
# 10 進数へ正規化する（`08` を算術展開が 8 進数として読んで比較が落ち、終了コード 0 のまま通るのを防ぐ）
LIMIT=$((10#$LIMIT))
[ -z "$MAX_AVG" ] || MAX_AVG=$((10#$MAX_AVG))
[ -z "$MAX_MD" ] || MAX_MD=$((10#$MAX_MD))
[ -n "$RUNNER" ] || RUNNER="$TESTS_DIR/run-all.sh"
if [ -n "$EXPECT" ] && { [ -n "${MAX_AVG}${MD_ONLY}${MAX_MD}" ] || [ "$LIMIT" -gt 0 ]; }; then
  echo "simulate.sh: --expect は --max-avg / --md-only / --max-md / --limit と併用しない" >&2; exit 64
fi

if [ -z "$EXPECT" ]; then
  [ -r "$EVAL" ] && [ -s "$EVAL" ] || { echo "simulate.sh: 評価集合を読めない: ${EVAL}（判定不能）" >&2; exit 2; }
  [ -r "$SECS" ] && [ -s "$SECS" ] || { echo "simulate.sh: 秒数のスナップショットを読めない: ${SECS}（判定不能）" >&2; exit 2; }
fi
[ -r "$RUNNER" ] || { echo "simulate.sh: ランナーを読めない: ${RUNNER}（判定不能）" >&2; exit 2; }
[ -d "$TESTS_DIR" ] || { echo "simulate.sh: 登録一覧の置き場を読めない: ${TESTS_DIR}（判定不能）" >&2; exit 2; }
ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || { echo "simulate.sh: git リポジトリの中で回すこと（判定不能）" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-chgsel-sim.XXXXXX")" || { echo "simulate.sh: 一時領域を作れない（判定不能）" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

run_select() { # <変更一覧のファイル>  ランナーの試算の出力（標準出力・標準エラー）を返す。終了コードはランナーのもの
  # 標準入力は閉じる（--expect の読み込みループの中で呼ぶので、ランナーに残りの行を読ませない）
  (cd "$ROOT" && env -u FF_RUN_ALL_FULL -u FF_RUN_ALL_FAST -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_ALLOW_SKIP \
    -u FF_RUN_ALL_WAIT -u FF_DEV_TOOLKIT_ROOT \
    FF_RUN_ALL_CHANGED=1 FF_RUN_ALL_SELECT_ONLY=1 FF_RUN_ALL_CHANGED_FILES_FROM="$1" \
    FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 bash "$RUNNER" 2>&1) < /dev/null
}

# ── --expect: 「このファイルが変わったら、この suite は選ばれる」の照合 ─────────────────────────
if [ -n "$EXPECT" ]; then
  [ -r "$EXPECT" ] && [ -s "$EXPECT" ] || { echo "simulate.sh: 照合の行を読めない: ${EXPECT}（判定不能）" >&2; exit 2; }
  # 宣言のある suite（select.sh scan が返す suite のファイルのどれかに宣言の行がある）。行の形は select.sh の is_decl_line と同じ
  if ! bash "$HERE/select.sh" scan "$TESTS_DIR" > "$WORK/scan" 2> "$WORK/scan.err"; then
    echo "simulate.sh: suite のファイルを列挙できない（判定不能）" >&2
    sed 's/^/  | /' "$WORK/scan.err" >&2
    exit 2
  fi
  : > "$WORK/declared"
  while IFS= read -r f; do
    grep -qE '^[[:space:]]*#[[:space:]]*run-all-depends:' "$f"
    g=$?
    case "$g" in
      0) d="${f#"$TESTS_DIR"/}"; printf '%s\n' "${d%%/*}" >> "$WORK/declared" ;;
      1) ;;
      *) echo "simulate.sh: suite のファイルを読めない: ${f}（判定不能）" >&2; exit 2 ;; # 読めないを「宣言なし」へ倒さない
    esac
  done < "$WORK/scan"
  # 列の欠けた行は判定不能（黙って飛ばすと、壊れた行が「照合した」ことになる）
  bad_rows="$(awk -F'\t' '$0 !~ /^#/ && NF > 0 && (NF < 3 || $1 == "" || $2 == "") { print NR }' "$EXPECT" | head -n 3 | tr '\n' ' ')"
  [ -z "$bad_rows" ] || { echo "simulate.sh: 照合の行の列が欠けている（${EXPECT} の ${bad_rows}行目。判定不能）" >&2; exit 2; }
  # データ行の数。読み込みのループが処理した行数と最後に突き合わせる（改行で終わらない最終行などを黙って落とさない）
  rows="$(awk '$0 !~ /^#/ && NF > 0' "$EXPECT" | wc -l | tr -d ' ')"
  # 変更パスは宣言と同じ書き方（プラグインルート相対。`/` 始まりはリポジトリルート相対）。プラグインの接頭辞は
  # tests の置き場から求める（tests がリポジトリの外にある検査用の差し替えでは空）
  plugin_abs="$(cd "$TESTS_DIR/.." && pwd -P)"
  root_abs="$(cd "$ROOT" && pwd -P)"
  pfx=""
  case "$plugin_abs/" in "$root_abs"/*) pfx="${plugin_abs#"$root_abs"}"; pfx="${pfx#/}"; [ -z "$pfx" ] || pfx="$pfx/" ;; esac
  checked=0; skipped=0; miss=0; seen=0; prev=""; mode=""
  while IFS=$'\t' read -r spec suite src || [ -n "$spec" ]; do
    case "$spec" in ''|'#'*) continue ;; esac
    seen=$((seen + 1))
    case "$spec" in /*) path="${spec#/}" ;; *) path="${pfx}${spec}" ;; esac
    [ -x "$TESTS_DIR/$suite/verify.sh" ] || { echo "simulate.sh: 照合の行の suite が登録に無い: ${suite}（${src}。判定不能）" >&2; exit 2; }
    [ -e "$ROOT/$path" ] || { echo "simulate.sh: 照合の行の変更パスが実在しない: ${spec}（${src}。行が古い。判定不能）" >&2; exit 2; }
    if ! grep -qxF "$suite" "$WORK/declared"; then
      skipped=$((skipped + 1))
      printf 'skip\t%s\t%s\t（宣言なし: 字面の照合）\n' "$suite" "$path"
      continue
    fi
    if [ "$path" != "$prev" ]; then # 同じ変更パスの行が続く間はランナーを回し直さない
      printf '%s\n' "$path" > "$WORK/files.txt"
      run_select "$WORK/files.txt" > "$WORK/sel.out"
      rc=$?
      # モードは完全一致で読む（`mode=fullish` のような崩れた値を全件と取り違えない）
      mode="$(sed -n 's/^select-only: mode=\([a-z]*\)\( .*\)\{0,1\}$/\1/p' "$WORK/sel.out" | head -n 1)"
      case "$rc:$mode" in
        0:full|0:changed) ;;
        *)
          echo "simulate.sh: ${path} でランナーが選択を返さない（rc=${rc}・mode=${mode:-無し}。判定不能）" >&2
          tail -n 5 "$WORK/sel.out" | sed 's/^/  | /' >&2
          exit 2
          ;;
      esac
      if [ "$mode" = changed ]; then # 選んだ件数と suite の行の数を突き合わせる（出力が欠けた回を「選ばれない」と読まない）
        want="$(sed -n 's/^select-only: mode=changed selected=\([0-9][0-9]*\)\( .*\)\{0,1\}$/\1/p' "$WORK/sel.out" | head -n 1)"
        got="$(grep -c '^select-only: suite=' "$WORK/sel.out")"
        if [ -z "$want" ] || [ "$want" != "$got" ]; then
          echo "simulate.sh: ${path} で選択の件数が合わない（selected=${want:-不明} / suite の行 ${got}。判定不能）" >&2
          exit 2
        fi
      fi
      prev="$path"
    fi
    checked=$((checked + 1))
    if [ "$mode" = full ]; then
      reason="$(sed -n 's/^select-only: mode=full reason=//p' "$WORK/sel.out" | head -n 1)"
      printf 'ok\t%s\t%s\t（全件へ倒れる: %s）\n' "$suite" "$path" "${reason:-理由なし}"
    elif grep -qxF "select-only: suite=${suite}" "$WORK/sel.out"; then
      printf 'ok\t%s\t%s\n' "$suite" "$path"
    else
      miss=$((miss + 1))
      printf '✗ 漏れ\t%s\t%s\t（%s）\n' "$suite" "$path" "$src"
    fi
  done < "$EXPECT"
  [ "$seen" -eq "$rows" ] || { echo "simulate.sh: 照合の行を読み落とした（データ行 ${rows} / 読んだ行 ${seen}。判定不能）" >&2; exit 2; }
  echo "---"
  echo "expect: checked=${checked} skipped=${skipped} miss=${miss}"
  [ "$checked" -gt 0 ] || { echo "simulate.sh: 照合した行が 0 件（宣言のある suite の行が無い。判定不能）" >&2; exit 2; }
  [ "$miss" -eq 0 ] || exit 1
  exit 0
fi

secs_of() { awk -F'\t' -v s="$1" '$0 !~ /^#/ && $1 == s { print $2; f = 1; exit } END { if (!f) print "-" }' "$SECS"; }
pct1() { # <分子> <分母>  小数 1 桁へ切り捨てた百分率
  local pm=$((1000 * $1 / $2))
  printf '%d.%d' $((pm / 10)) $((pm % 10))
}

# 分母: 今の登録一覧（実行できる <名前>/verify.sh）から、選択に入れない suite を除いた合計
FULL=0
MISSING=""
NREG=0
for v in "$TESTS_DIR"/*/verify.sh; do
  [ -x "$v" ] || continue
  name="$(basename "$(dirname "$v")")"
  [ "$name" = public-layout ] && continue
  NREG=$((NREG + 1))
  s="$(secs_of "$name")"
  if [ "$s" = "-" ]; then MISSING="$MISSING $name"; s=0; fi
  FULL=$((FULL + s))
done
[ "$FULL" -gt 0 ] || { echo "simulate.sh: 全件の秒数が 0（スナップショットと登録一覧が噛み合わない。判定不能）" >&2; exit 2; }

printf 'PR\t全件比\t方式\t選んだ suite 数\n'
total=0; k=0; md_bad=""; md_seen=""
while IFS=$'\t' read -r sha pr _; do
  case "$sha" in ''|'#'*) continue ;; esac
  if [ "$LIMIT" -gt 0 ] && [ "$k" -ge "$LIMIT" ]; then break; fi
  if ! git -C "$ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    echo "simulate.sh: PR ${pr} のコミット ${sha} が手元に無い（判定不能）" >&2; exit 2
  fi
  git -C "$ROOT" -c core.quotePath=false show --name-only --no-renames --format= "$sha" > "$WORK/files.txt" \
    || { echo "simulate.sh: PR ${pr} の変更一覧を取れない（判定不能）" >&2; exit 2; }
  [ -s "$WORK/files.txt" ] || { echo "simulate.sh: PR ${pr} の変更一覧が空（マージコミット・空のコミット。判定不能）" >&2; exit 2; }
  out="$(run_select "$WORK/files.txt")"
  rc=$?
  mode="$(printf '%s\n' "$out" | sed -n 's/^select-only: mode=\([a-z]*\).*/\1/p' | head -n 1)"
  if [ "$rc" -ne 0 ] || [ -z "$mode" ]; then
    echo "simulate.sh: PR ${pr} でランナーが選択を返さない（rc=${rc}。判定不能）" >&2
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  | /' >&2
    exit 2
  fi
  if [ "$mode" = full ]; then
    sum=$FULL; n=$NREG
  else
    want="$(printf '%s\n' "$out" | sed -n 's/^select-only: mode=changed selected=\([0-9][0-9]*\) .*/\1/p' | head -n 1)"
    sum=0; n=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      s="$(secs_of "$name")"
      if [ "$s" = "-" ]; then
        case " ${MISSING} " in *" ${name} "*) ;; *) MISSING="$MISSING $name" ;; esac
        s=0
      fi
      sum=$((sum + s)); n=$((n + 1))
    done < <(printf '%s\n' "$out" | sed -n 's/^select-only: suite=//p')
    if [ -z "$want" ] || [ "$want" != "$n" ]; then
      echo "simulate.sh: PR ${pr} の選択の件数が合わない（selected=${want:-不明} / suite の行 ${n}。判定不能）" >&2
      exit 2
    fi
  fi
  printf '%s\t%s%%\t%s\t%d\n' "$pr" "$(pct1 "$sum" "$FULL")" "$mode" "$n"
  total=$((total + sum)); k=$((k + 1))
  if [ -n "$MD_ONLY" ]; then
    case ",${MD_ONLY}," in
      *",${pr},"*)
        md_seen="${md_seen} ${pr}"
        # 秒数の比そのもので比べる（100 * sum / FULL > MAX_MD ⇔ 100 * sum > MAX_MD * FULL）
        [ $((100 * sum)) -le $((MAX_MD * FULL)) ] || md_bad="${md_bad} ${pr}=$(pct1 "$sum" "$FULL")%"
        ;;
    esac
  fi
done < "$EVAL"
[ "$k" -gt 0 ] || { echo "simulate.sh: 評価集合に PR が 0 本（判定不能）" >&2; exit 2; }
echo "---"
echo "simulate: prs=${k} full-seconds=${FULL} average=$(pct1 "$total" $((k * FULL)))%"
[ -z "$MISSING" ] || echo "simulate: スナップショットに無い suite（0 秒と数えた）:${MISSING}"
rc=0
if [ -n "$MAX_AVG" ] && [ $((100 * total)) -gt $((MAX_AVG * k * FULL)) ]; then
  echo "✗ simulate: 平均の全件比 $(pct1 "$total" $((k * FULL)))% が上限 ${MAX_AVG}% を超えた"; rc=1
fi
if [ -n "$MD_ONLY" ]; then
  for p in $(printf '%s' "$MD_ONLY" | tr ',' ' '); do
    case " ${md_seen} " in *" ${p} "*) ;; *) echo "simulate.sh: --md-only の PR ${p} が評価集合（--limit の範囲）に無い（判定不能）" >&2; exit 2 ;; esac
  done
  if [ -n "$md_bad" ]; then echo "✗ simulate: .md だけの PR が上限 ${MAX_MD}% を超えた:${md_bad}"; rc=1; fi
fi
exit "$rc"
