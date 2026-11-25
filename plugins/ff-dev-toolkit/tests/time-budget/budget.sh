#!/usr/bin/env bash
#
# budget.sh — suite ごとの時間予算（CPU 秒）を判定する CLI（Issue `#3005`。親 `#2989`）
#
# tests/run-all.sh が既定一覧の実行の終わりに 1 回だけ呼ぶ。run-all.sh 側は「各 suite の
# `times` の子プロセス行を集めて渡す」ことだけを受け持ち、較正・正規化・基線との照合は
# ここに閉じる（4,000 行を超えた runner へ判定ロジックを足さない。入出力は標準入力・
# 標準出力・終了コードだけが契約）。
#
# 使い方:
# --- usage:start ---
#   budget.sh judge  --baseline <FILE>              # 標準入力: <suite>\t<times の子の行 or ->\t<pass|other>
#   budget.sh report                                # 標準入力は judge と同じ。観測行だけ出す
#   budget.sh calibrate                             # 較正の CPU ミリ秒を 1 行出す
#   budget.sh compare --base <FILE> --head <FILE> [--tests-dir <DIR>]   # 基線の緩和（引き上げ）を検出する
#   budget.sh check-raise --baseline <FILE> [--tests-dir <DIR>]   # merge-base 時点の版と compare する
#   budget.sh validate --baseline <FILE> --tests-dir <DIR>   # 形式と suite 名の実在を見る
#   budget.sh print-baseline --calibration-ms <N> [--current <FILE>] [--allow-growth]
#                                                   # 標準入力: <suite>\t<CPU ミリ秒>
#   budget.sh print-baseline --from-log <ゲートのログ> [--current <FILE>] [--allow-growth]
#                                                   # ログの最後の cpu-sec: 行と同じ回の time-budget: 行の較正値を使う
# --- usage:end ---
#
#   標準入力の 3 列目は判定に使うかどうか（pass = 通過した suite。other = 落ちた・skip した suite。
#   落ちた suite は途中で止まって安く見えるので判定に使わない）。計測値が無い行は 2 列目を `-` にする
#   （空欄にしない。TAB は IFS の空白扱いで連続が畳まれ、列がずれる）。
#   FF_TIME_BUDGET_CALIBRATION_MS=<整数> は judge の較正を測らずにその値を使う（fixture で
#   正規化を決定的にするための口）。tests/run-all.sh はゲートの判定を呼ぶときにこの変数を
#   必ず落とす（export したままのシェルで予算を素通りさせない）。
#
# ── 指標: CPU 秒（user + sys）を較正で正規化した値 ─────────────────────────────
# 経過秒（壁時計）は並列の負荷で単独実行の 2〜3 倍に揺れる（`#1907` の実測）。上限の判定が
# その揺れで赤と緑を行き来するとゲートにならないので、suite のプロセス木が使った CPU 秒
# （`times` の子プロセス行 = 回収済みの子孫すべての user + sys）を測る。
# CPU 秒は機械の速さで変わる（基線を測った機械より遅い機械では、どの suite も上限を超える）。
# そこで判定のたびに固定の仕事（較正。suite と同じくプロセスの起動とパイプ越しの小さな
# テキスト処理が主の処理。ファイルは作らない）を走らせ、その CPU ミリ秒 `now` と、基線を
# 測った機械での値 `@calibration-ms`（ref）の比で揃える:  正規化した CPU 秒 = 生の CPU 秒 × ref ÷ now
# 較正は CALIBRATION_REPS 回の最小値を使う（割り込みや効率コアへの割り当てで伸びた回を捨てる）。
#
# ── 基線（tests/time-budget/baseline.tsv）──────────────────────────────────────
#   `#` で始まる行は注釈。`@calibration-ms<TAB><整数>`・`@default-limit<TAB><整数>` が 1 行ずつ、
#   残りは `<suite 名><TAB><上限の正規化 CPU 秒（整数）>`。
#   基線に無い suite（新設）の上限は @default-limit（導入時の値は `#1907` の実績値から取った）。
#   縮める方向にしか動かさない。緩める変更（上限の引き上げ・@default-limit の引き上げ・
#   @calibration-ms の引き下げ = 正規化した値が小さく出る側・@default-limit を超える新しい行・
#   上限が @default-limit 未満の実在する suite の行の削除）は compare が赤にする
#   （tests/time-budget/verify.sh が merge-base と照合する）。
#   比べる相手は merge-base(origin/HEAD の指す既定ブランチ, HEAD)。PR の向け先が既定ブランチで
#   あることを前提にする（このリポジトリは develop、公開リポジトリは main で、どちらも既定ブランチ）。
#   比べられないもの: 較正の仕事（calibration_workload）の変更と、suite の改名（旧名の行を外して
#   新しい名前を新設扱いにする）。どちらも基線の差分には出ないので、PR のレビューで止める。
#
# ── 終了コード ───────────────────────────────────────────────────────────────
#   judge:          0 = 全 suite が上限内 / 1 = 上限超過あり / 2 = 判定できない
#                   （基線が無い・読めない・空・形式違反、較正が取れない、計測値が取れない
#                   suite がある、入力が空）。判定できない回を緑へ倒さない
#   report:         0（観測行を出すだけ。計測値が読めない suite は載せない）
#   calibrate:      0 = 出力した / 2 = 測れなかった
#   compare:        0 = 緩和なし / 1 = 緩和あり / 2 = どちらかの基線が読めない
#   check-raise:    compare と同じ。加えて 3 = 比較 base を決められない（origin/HEAD が無い・
#                   merge-base が取れない・git 管理外）。base 側にファイルが無い（初版）は 0
#   validate:       0 = 形式どおりで suite 名がすべて実在 / 1 = 実在しない suite 名がある /
#                   2 = 基線が読めない・形式違反
#   print-baseline: 0 = 出力した / 1 = --current より上限が増える suite がある（--allow-growth
#                   を付けた回だけ出す。縮小のみの基線を取り直す口を増加の抜け道にしない）/
#                   2 = 入力・較正値が不正
#   使い方の誤り（未知のサブコマンド・フラグ）は 2。
#
#   観測行: `cpu-sec:` は判定に使う（pass の）suite の生の CPU 秒、`cpu-sec-other:` はそれ以外。
#   print-baseline --from-log は `cpu-sec:` だけを読む（落ちた・skip した suite の安い値で上限を縮めない）。
#
# 実装上の制約: macOS 標準の bash 3.2 で動くこと。一時ファイルを作らない（run-all.sh の逐次実行の
# 経路が持つ read-only 制約を、較正を含めて守る。here-document / here-string は bash 3.2 で一時ファイルを
# 作るので使わない）。

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
CALIBRATION_REPS=7
# print-baseline が上限を決める規則（取り直しのときだけ使う。判定は基線の値をそのまま使う）。
# 上限 = max(切り上げ(正規化 CPU 秒 × MARGIN_PERCENT ÷ 100), FLOOR_SEC)
MARGIN_PERCENT=150
FLOOR_SEC=10
# --current を渡さずに基線を新しく作るときの @default-limit（`#1907` の実績値）。以後の正本は基線の行
INITIAL_DEFAULT_LIMIT=180

die_usage() {
  echo "budget.sh: $*" >&2
  echo "  使い方は budget.sh の先頭コメント（usage）を参照" >&2
  exit 2
}

# `times` の子プロセス行（例: `0m1.234s 0m0.567s`。bash 4 以降はロケールで小数点が `,` に
# なりうる）を user + sys のミリ秒にする。読めなければ非 0。読み方の正本は measurements_to_ms の
# to_ms（較正もそこを通す。読み方を 2 か所に持たない）。
times_line_to_ms() { # <line>
  local ms
  ms="$(printf 'x\t%s\tpass\n' "$1" | measurements_to_ms | LC_ALL=C awk -F'\t' 'NR == 1 { print $2 }')"
  case "$ms" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$ms"
}

# 較正の 1 回分の仕事。suite の大半と同じく、bash の起動・コマンド置換・パイプ越しの
# grep / awk / sed の起動が主になるようにしてある。ファイルは作らない（一時領域の無い環境でも測れる）。
# 変えると基線の @calibration-ms と比べられなくなる。変えるときは、基線を測った機械で新しい仕事の
# 値を測り直して @calibration-ms を同じ PR で更新する（compare は値の引き下げしか見ないので、
# 仕事の変更そのものは赤にならない。レビューで止める）。
calibration_workload() {
  local i x
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    x="$(printf 'line %s\nother %s\n' "$i" "$i")" || return 1
    bash -c 'y="$(printf "%s\n" "$1" | grep -c line)" && [ "$y" = 1 ]' _ "$x" || return 1
    printf '%s\n' "$x" | awk '{n++} END {print n}' >/dev/null || return 1
    printf '%s\n' "$x" | sed -n '1p' >/dev/null || return 1
  done
}

cmd_calibrate() {
  local r out line ms min=""
  for ((r = 0; r < CALIBRATION_REPS; r++)); do
    # コマンド置換のサブシェルの `times` は、そのサブシェルが回収した子（= 仕事をする bash）
    # の CPU だけを数える（fork した子の累計は 0 から始まる）。仕事が失敗した回は times を
    # 出さずに非 0 で抜ける（失敗した仕事の短い CPU 時間を較正値として採らない）。
    out="$(bash "$SELF" __calibration-workload >/dev/null 2>&1 || exit 2; times)" || return 2
    line="$(printf '%s\n' "$out" | sed -n '2p')"
    ms="$(times_line_to_ms "$line")" || return 2
    [[ "$ms" -gt 0 ]] || return 2
    if [[ -z "$min" || "$ms" -lt "$min" ]]; then
      min="$ms"
    fi
  done
  [[ -n "$min" ]] || return 2
  printf '%s\n' "$min"
}

# 基線を読み、正規化した形で出す（@calibration-ms / @default-limit / suite 行）。
# 形式違反・重複・欠落は理由を stderr に出して非 0。
read_baseline() { # <file> -> stdout "K<TAB>V" 行
  local file="$1"
  # 通常ファイルに限らない（check-raise は base 側の版をプロセス置換 /dev/fd/N で渡す）
  if [[ ! -e "$file" || ! -r "$file" || -d "$file" ]]; then
    echo "✗ 時間予算: 基線を読めません: $file" >&2
    return 2
  fi
  LC_ALL=C awk -F'\t' -v file="$file" '
    { sub(/\r$/, "") }
    /^#/ || /^[[:space:]]*$/ { next }
    {
      if (NF != 2 || $1 == "" || $2 !~ /^[0-9]+$/) {
        printf "✗ 時間予算: 基線の %s 行目が形式（<名前><TAB><整数>）に合いません: %s\n", NR, $0 > "/dev/stderr"
        bad = 1; next
      }
      if ($1 in seen) {
        printf "✗ 時間予算: 基線に同じ名前が 2 行あります: %s\n", $1 > "/dev/stderr"
        bad = 1; next
      }
      seen[$1] = 1
      if ($1 ~ /^@/ && $1 != "@calibration-ms" && $1 != "@default-limit") {
        printf "✗ 時間予算: 基線の未知の設定です: %s\n", $1 > "/dev/stderr"
        bad = 1; next
      }
      if ($1 !~ /^@/ && $1 !~ /^[A-Za-z0-9._-]+$/) {
        printf "✗ 時間予算: 基線の suite 名に使えない文字があります: %s\n", $1 > "/dev/stderr"
        bad = 1; next
      }
      if ($2 + 0 <= 0) {
        printf "✗ 時間予算: 基線の値は 1 以上の整数にしてください: %s\n", $0 > "/dev/stderr"
        bad = 1; next
      }
      print $1 "\t" $2
      if ($1 !~ /^@/) suites++
    }
    END {
      if (!("@calibration-ms" in seen)) { print "✗ 時間予算: 基線に @calibration-ms がありません" > "/dev/stderr"; bad = 1 }
      if (!("@default-limit" in seen)) { print "✗ 時間予算: 基線に @default-limit がありません" > "/dev/stderr"; bad = 1 }
      if (suites == 0) { print "✗ 時間予算: 基線に suite の行が 1 つもありません（空の基線は判定に使えません）" > "/dev/stderr"; bad = 1 }
      if (bad) exit 2
    }
  ' "$file"
}

# 標準入力（<suite>\t<times の子の行 or ->\t<pass|other>）を <suite>\t<ミリ秒 or ->\t<pass|other> にする。
# 読めない計測値は `-`。3 列目が other 以外（省略を含む）は pass。awk の -F'\t' で列を切る
# （bash の `IFS=$'\t' read` は連続した TAB を 1 つに畳むので、空の列があると後ろの列がずれる）。
measurements_to_ms() {
  LC_ALL=C awk -F'\t' '
    function to_ms(line,    n, f, s, m, sec, tot, part) {
      n = split(line, part, " ")
      if (n != 2) return "-"
      tot = 0
      for (f = 1; f <= 2; f++) {
        s = part[f]
        gsub(/,/, ".", s)
        if (s !~ /^[0-9]+m[0-9]+([.][0-9]+)?s$/) return "-"
        m = s; sub(/m.*$/, "", m)
        sec = s; sub(/^[0-9]+m/, "", sec); sub(/s$/, "", sec)
        tot += m * 60 + sec
      }
      return sprintf("%d", tot * 1000 + 0.5)
    }
    { sub(/\r$/, "") }
    $1 == "" { next }
    { print $1 "\t" to_ms($2) "\t" (($3 == "other") ? "other" : "pass") }
  '
}

# 観測行（run-all.sh の elapsed-sec と同じく指紋ブロックの外に出る）。cpu-sec は pass の suite、
# cpu-sec-other はそれ以外（取り直しの材料にしない側）
emit_cpu_line() { # <ms_table>
  local out
  out="$(printf '%s\n' "$1" | LC_ALL=C awk -F'\t' '
    $2 ~ /^[0-9]+$/ && $3 == "pass" { p = p (p == "" ? "" : " ") sprintf("%s=%.1f", $1, $2 / 1000) }
    $2 ~ /^[0-9]+$/ && $3 == "other" { o = o (o == "" ? "" : " ") sprintf("%s=%.1f", $1, $2 / 1000) }
    END {
      if (p != "") print "cpu-sec: " p
      if (o != "") print "cpu-sec-other: " o
    }
  ')"
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

cmd_report() {
  local table
  [[ $# -eq 0 ]] || die_usage "report は引数を取りません: $1"
  table="$(measurements_to_ms)"
  emit_cpu_line "$table"
  return 0
}

cmd_judge() {
  local baseline="" table base now rc
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --baseline) [[ $# -ge 2 ]] || die_usage "--baseline に値がありません"; baseline="$2"; shift 2 ;;
      *) die_usage "judge の未知の引数: $1" ;;
    esac
  done
  [[ -n "$baseline" ]] || die_usage "judge には --baseline が要ります"
  table="$(measurements_to_ms)"
  emit_cpu_line "$table"
  table="$(printf '%s\n' "$table" | LC_ALL=C awk -F'\t' '$3 == "pass"')"
  if [[ -z "$table" ]]; then
    echo "✗ 時間予算: 判定する suite（通過した suite）の行が 1 件もありません（空の入力を緑にしない）" >&2
    return 2
  fi
  base="$(read_baseline "$baseline")" || return 2
  if [[ -n "${FF_TIME_BUDGET_CALIBRATION_MS:-}" ]]; then
    now="$FF_TIME_BUDGET_CALIBRATION_MS"
    case "$now" in
      *[!0-9]*|0) echo "✗ 時間予算: FF_TIME_BUDGET_CALIBRATION_MS は正の整数で渡してください: $now" >&2; return 2 ;;
    esac
  elif ! now="$(cmd_calibrate)"; then
    echo "✗ 時間予算: 較正（固定の仕事の CPU 時間）を測れませんでした。正規化できないので判定しません" >&2
    return 2
  fi
  LC_ALL=C awk -F'\t' -v now="$now" '
    FNR == NR {
      if ($1 == "@calibration-ms") ref = $2 + 0
      else if ($1 == "@default-limit") deflim = $2 + 0
      else lim[$1] = $2 + 0
      next
    }
    {
      name = $1
      judged++
      if ($2 !~ /^[0-9]+$/) {
        printf "✗ 時間予算: %s の CPU 時間を計測できませんでした（計測値が無い suite を上限内と見なさない）\n", name > "/dev/stderr"
        missing++
        next
      }
      raw = $2 / 1000
      norm = raw * ref / now
      if (name in lim) { L = lim[name]; src = "基線" } else { L = deflim; src = "新設 suite の既定" }
      if (norm > L) {
        printf "✗ 時間予算: %s が上限 %d 秒（%s）を超えました: 実測 %.1f 秒（正規化後。生の CPU %.1f 秒 × 較正 %d / %d ms）\n", name, L, src, norm, raw, ref, now > "/dev/stderr"
        over++
      }
    }
    END {
      printf "time-budget: judged=%d over=%d unmeasured=%d calibration=%dms ref=%dms\n", judged, over + 0, missing + 0, now, ref
      if (missing) exit 2
      if (over) exit 1
    }
  ' <(printf '%s\n' "$base") <(printf '%s\n' "$table")
  rc=$?
  if [[ "$rc" -eq 1 ]]; then
    echo "  上限を超えた suite を速くしてください。基線の上限は縮める方向にしか動かせません（引き上げは tests/time-budget の検査が赤にします）。" >&2
    echo "  新しい検査は、既存の重い suite へ足すより、上限 @default-limit 以内の別 suite に分ける・判定を単体テストへ移すことを検討してください（docs/04-quality/TESTING.md「suite の時間予算」）。" >&2
  fi
  return "$rc"
}

cmd_compare() {
  local base_file="" head_file="" tests_dir="" base head alive="" k
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) [[ $# -ge 2 ]] || die_usage "--base に値がありません"; base_file="$2"; shift 2 ;;
      --head) [[ $# -ge 2 ]] || die_usage "--head に値がありません"; head_file="$2"; shift 2 ;;
      --tests-dir) [[ $# -ge 2 ]] || die_usage "--tests-dir に値がありません"; tests_dir="$2"; shift 2 ;;
      *) die_usage "compare の未知の引数: $1" ;;
    esac
  done
  [[ -n "$base_file" && -n "$head_file" ]] || die_usage "compare には --base と --head が要ります"
  base="$(read_baseline "$base_file")" || return 2
  head="$(read_baseline "$head_file")" || return 2
  # --tests-dir を渡した回は、base にあった行のうち suite が今も実在するものを数える。実在する suite の
  # 行を外すと、その上限は @default-limit へ戻る（上限が既定より小さかった suite では緩める変更になる）
  if [[ -n "$tests_dir" ]]; then
    while IFS=$'\t' read -r k _; do
      case "$k" in @*|'') continue ;; esac
      [[ ! -f "$tests_dir/$k/verify.sh" ]] || alive="${alive}A	${k}
"
    done < <(printf '%s\n' "$base")
  fi
  # 1 本の入力へ印を付けて流す（B = base / H = head / A = 実在する suite）
  { printf '%s\n' "$base" | sed 's/^/B	/'; printf '%s\n' "$head" | sed 's/^/H	/'; printf '%s' "$alive"; } | LC_ALL=C awk -F'\t' '
    $1 == "B" { b[$2] = $3 + 0; next }
    $1 == "H" { h[$2] = $3 + 0; next }
    $1 == "A" { alive[$2] = 1; next }
    END {
      hdef = h["@default-limit"]
      if (h["@default-limit"] > b["@default-limit"]) {
        printf "✗ 時間予算: @default-limit を引き上げています（%d → %d 秒）\n", b["@default-limit"], h["@default-limit"]
        loose++
      }
      if (h["@calibration-ms"] < b["@calibration-ms"]) {
        printf "✗ 時間予算: @calibration-ms を引き下げています（%d → %d ms。正規化した値が小さく出る = 緩める側）\n", b["@calibration-ms"], h["@calibration-ms"]
        loose++
      }
      for (k in h) {
        if (k ~ /^@/) continue
        if (k in b) {
          if (h[k] > b[k]) { printf "✗ 時間予算: %s の上限を引き上げています（%d → %d 秒）\n", k, b[k], h[k]; loose++ }
        } else if (h[k] > hdef) {
          printf "✗ 時間予算: 基線に新しく足した %s の上限 %d 秒が、新設 suite の上限 @default-limit（%d 秒）を超えています\n", k, h[k], hdef
          loose++
        }
      }
      for (k in b) {
        if (k ~ /^@/ || (k in h) || !(k in alive)) continue
        if (b[k] < hdef) {
          printf "✗ 時間予算: 実在する %s の行を外しています（上限が %d 秒から @default-limit の %d 秒へ緩む）\n", k, b[k], hdef
          loose++
        }
      }
      if (loose) exit 1
    }
  '
}

# 比較 base は merge-base(origin/HEAD の指す既定ブランチ, HEAD)。既定ブランチの先端と比べると、
# 分岐した後に既定ブランチ側で縮めた上限を「この枝が引き上げた」と読んでしまう。fetch はしない
# （local の origin ref の鮮度は git-workflow の base 追随確認が担う。docs-frontmatter-repo と同じ）。
cmd_check_raise() {
  local baseline="" tests_dir="" dir name prefix default_ref base_commit rc
  local -a extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --baseline) [[ $# -ge 2 ]] || die_usage "--baseline に値がありません"; baseline="$2"; shift 2 ;;
      --tests-dir) [[ $# -ge 2 ]] || die_usage "--tests-dir に値がありません"; tests_dir="$2"; shift 2 ;;
      *) die_usage "check-raise の未知の引数: $1" ;;
    esac
  done
  [[ -n "$baseline" ]] || die_usage "check-raise には --baseline が要ります"
  if [[ ! -f "$baseline" || ! -r "$baseline" ]]; then
    echo "✗ 時間予算: 基線を読めません: $baseline" >&2
    return 2
  fi
  dir="$(cd "$(dirname "$baseline")" && pwd -P)" || return 2
  name="$(basename "$baseline")"
  if ! prefix="$(git -C "$dir" rev-parse --show-prefix 2>/dev/null)"; then
    echo "比較 base を決められません: 基線が git 管理下にありません" >&2
    return 3
  fi
  if ! default_ref="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    echo "比較 base を決められません: origin/HEAD を解決できません" >&2
    return 3
  fi
  if ! base_commit="$(git -C "$dir" merge-base "$default_ref" HEAD 2>/dev/null)"; then
    echo "比較 base を決められません: ${default_ref} と HEAD の merge-base を取得できません" >&2
    return 3
  fi
  if ! git -C "$dir" cat-file -e "${base_commit}:${prefix}${name}" 2>/dev/null; then
    echo "比較 base（${default_ref} との merge-base）に基線がありません（初版）"
    return 0
  fi
  # base 側の版は一時ファイルを作らずプロセス置換で渡す
  rc=0
  [[ -z "$tests_dir" ]] || extra=(--tests-dir "$tests_dir")
  cmd_compare --base <(git -C "$dir" show "${base_commit}:${prefix}${name}") --head "$baseline" ${extra[@]+"${extra[@]}"} || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "比較 base（${default_ref} との merge-base）から基線を緩めていません"
  fi
  return "$rc"
}

cmd_validate() {
  local baseline="" tests_dir="" base missing=0 k
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --baseline) [[ $# -ge 2 ]] || die_usage "--baseline に値がありません"; baseline="$2"; shift 2 ;;
      --tests-dir) [[ $# -ge 2 ]] || die_usage "--tests-dir に値がありません"; tests_dir="$2"; shift 2 ;;
      *) die_usage "validate の未知の引数: $1" ;;
    esac
  done
  [[ -n "$baseline" && -n "$tests_dir" ]] || die_usage "validate には --baseline と --tests-dir が要ります"
  base="$(read_baseline "$baseline")" || return 2
  while IFS=$'\t' read -r k _; do
    case "$k" in @*|'') continue ;; esac
    if [[ ! -f "$tests_dir/$k/verify.sh" ]]; then
      echo "✗ 時間予算: 基線の suite が実在しません（消した・改名した suite の行は基線から外す）: $k" >&2
      missing=$((missing + 1))
    fi
  done < <(printf '%s\n' "$base")
  [[ "$missing" -eq 0 ]] || return 1
  return 0
}

cmd_print_baseline() {
  local cal="" current="" allow_growth=0 table cur="" from_log="" log_cal
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --calibration-ms) [[ $# -ge 2 ]] || die_usage "--calibration-ms に値がありません"; cal="$2"; shift 2 ;;
      --current) [[ $# -ge 2 ]] || die_usage "--current に値がありません"; current="$2"; shift 2 ;;
      --from-log) [[ $# -ge 2 ]] || die_usage "--from-log に値がありません"; from_log="$2"; shift 2 ;;
      --allow-growth) allow_growth=1; shift ;;
      *) die_usage "print-baseline の未知の引数: $1" ;;
    esac
  done
  if [[ -n "$from_log" ]]; then
    # ゲートのログの `cpu-sec:` 行（最後の 1 行。判定に使った pass の suite だけ）を計測値に、
    # `time-budget:` 行の calibration= を較正値に使う（--calibration-ms を明示した回はそちらを優先する）。
    # `cpu-sec-other:`（落ちた・skip した suite）は読まない — 安く見える値で上限を縮めると、
    # 次にその suite が全部走った回に赤になり、引き上げは L2 が止めるので戻せない
    if [[ ! -f "$from_log" || ! -r "$from_log" ]]; then
      echo "✗ 時間予算: ログを読めません: $from_log" >&2
      return 2
    fi
    # 計測値と較正値は同じ回のものを組にする（同じログへ別の回を追記したとき、ある回の計測値を
    # 別の回の較正値で正規化しない）。judge は 1 回の判定で cpu-sec → time-budget の順に出すので、
    # 最後の cpu-sec の後ろに time-budget（calibration=）が無い（その回の較正が取れていない）なら、
    # --calibration-ms を明示しない限り止める
    table="$(LC_ALL=C awk '/^cpu-sec: / { line = $0 } END { print line }' "$from_log" | LC_ALL=C awk '
      {
        for (i = 2; i <= NF; i++) {
          n = split($i, kv, "=")
          if (n == 2 && kv[2] ~ /^[0-9]+([.][0-9]+)?$/) printf "%s\t%d\n", kv[1], kv[2] * 1000 + 0.5
        }
      }')"
    log_cal="$(LC_ALL=C awk '
      /^cpu-sec: / { c = "" }
      /^time-budget: / { for (i = 2; i <= NF; i++) if ($i ~ /^calibration=[0-9]+ms$/) { v = $i; sub(/^calibration=/, "", v); sub(/ms$/, "", v); c = v } }
      END { print c }' "$from_log")"
    [[ -n "$cal" ]] || cal="$log_cal"
  else
    table="$(cat)"
  fi
  case "$cal" in ''|*[!0-9]*) echo "✗ 時間予算: --calibration-ms は正の整数で渡してください（--from-log のログに較正値の行が無いときも要ります）" >&2; return 2 ;; esac
  [[ "$cal" -gt 0 ]] || { echo "✗ 時間予算: --calibration-ms は正の整数で渡してください" >&2; return 2; }
  # rule の `exit` は END へ飛ぶだけで、END の `exit` が終了コードを上書きする。不正な行は印を
  # 残して END で判定する
  if ! printf '%s\n' "$table" | LC_ALL=C awk -F'\t' '
    NF == 0 { next }
    NF != 2 || $1 == "" || $2 !~ /^[0-9]+$/ { bad = 1; next }
    { n++ }
    END { exit ((bad || !n) ? 1 : 0) }
  '; then
    echo "✗ 時間予算: 入力は <suite>\\t<CPU ミリ秒> の行だけを 1 行以上並べてください（形式の違う行があります）" >&2
    return 2
  fi
  if [[ -n "$current" ]]; then
    cur="$(read_baseline "$current")" || return 2
  fi
  # 1 つ目の入力 = 現行の基線（無ければ空）+ 終端の印、2 つ目 = 今回の計測値。
  # 現行の基線を -v で渡さない（改行を含む値の扱いが awk の実装で揺れる）。
  printf '%s\n' "$table" | LC_ALL=C awk -F'\t' -v cal="$cal" -v margin="$MARGIN_PERCENT" -v floor="$FLOOR_SEC" \
    -v allow="$allow_growth" -v has_cur="$([[ -n "$cur" ]] && echo 1 || echo 0)" -v initdef="$INITIAL_DEFAULT_LIMIT" '
    function ceil(x) { return (x == int(x)) ? int(x) : int(x) + 1 }
    !started {
      if ($1 == "@@end") {
        started = 1
        ref = ("@calibration-ms" in c) ? c["@calibration-ms"] : cal
        deflim = ("@default-limit" in c) ? c["@default-limit"] : initdef + 0
        next
      }
      if ($1 != "") c[$1] = $2 + 0
      next
    }
    NF == 2 {
      seen_now[$1] = 1
      norm = ($2 / 1000) * ref / cal
      L = ceil(norm * margin / 100)
      if (L < floor) L = floor
      if (($1 in c) && L > c[$1]) {
        grow[++g] = sprintf("%s: %d → %d 秒", $1, c[$1], L)
        if (!allow) next
      } else if (($1 in c) && L < c[$1]) {
        # 縮める方向はそのまま採る
      } else if ($1 in c) {
        L = c[$1]
      } else if (has_cur && L > deflim) {
        grow[++g] = sprintf("%s: 基線に無い → %d 秒（@default-limit %d 秒超）", $1, L, deflim)
        if (!allow) next
      }
      out[++n] = $1 "\t" L
    }
    END {
      # 今回の計測に出てこなかった suite（高速モードで除外された selftest・落ちた / skip した suite は
      # 判定の対象外として cpu-sec に載らない）の現行の行は落とさずに残す。落とすと、その suite の
      # 上限が @default-limit へ緩む
      for (k in c) {
        if (k ~ /^@/ || (k in seen_now)) continue
        out[++n] = k "\t" c[k]
      }
      if (g && !allow) {
        print "✗ 時間予算: 取り直しで上限が増える suite があります（縮小のみの基線を取り直しで緩めない。意図した回だけ --allow-growth を付ける）:" > "/dev/stderr"
        for (i = 1; i <= g; i++) print "    " grow[i] > "/dev/stderr"
        exit 1
      }
      print "# suite ごとの時間予算（Issue `#3005`）。正本の説明は tests/time-budget/budget.sh の先頭コメント。"
      print "# 値は較正で正規化した CPU 秒の上限。縮める方向にしか動かさない（緩める変更は verify.sh が赤にする）。"
      printf "@calibration-ms\t%d\n", ref
      printf "@default-limit\t%d\n", deflim
      # suite 名の昇順（bash 3.2 の awk に asort は無いので単純な挿入で並べる）
      for (i = 2; i <= n; i++) { v = out[i]; j = i - 1; while (j > 0 && out[j] > v) { out[j + 1] = out[j]; j-- } out[j + 1] = v }
      for (i = 1; i <= n; i++) print out[i]
    }
  ' <(if [[ -n "$cur" ]]; then printf '%s\n' "$cur"; fi; printf '@@end\t0\n') -
}

sub="${1:-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  judge) cmd_judge "$@" ;;
  report) cmd_report "$@" ;;
  calibrate)
    [[ $# -eq 0 ]] || die_usage "calibrate は引数を取りません"
    cmd_calibrate || { echo "✗ 時間予算: 較正を測れませんでした" >&2; exit 2; }
    ;;
  compare) cmd_compare "$@" ;;
  check-raise) cmd_check_raise "$@" ;;
  validate) cmd_validate "$@" ;;
  print-baseline) cmd_print_baseline "$@" ;;
  __calibration-workload) calibration_workload ;;
  '') die_usage "サブコマンドがありません（judge / report / calibrate / compare / check-raise / validate / print-baseline）" ;;
  *) die_usage "未知のサブコマンド: $sub" ;;
esac
