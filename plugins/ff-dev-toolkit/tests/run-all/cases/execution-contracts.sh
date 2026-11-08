# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# case 48〜51・53: 境界の継承・起動順・再実行コマンド
#
# verify.sh から source される（ok / bad / expect_* / run_runner / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2696`）。

echo ""
echo "== case 48: asdd-hook-gate はルートまで遡っても '//' で始まるパスを検査しない =="
# Windows の Git Bash は先頭の '//' を UNC（\\.asdd）と読み、git 管理外の cwd から hook を起動するたびに
# ネットワーク上の共有を照会して遅くなり、ときどき設定ありと判定していた（Issue `#2020`）。
# git 管理外の一時ディレクトリを cwd にして xtrace を取り、遡りがルートの '/.asdd' まで届いたこと（針）と、
# '//' で始まるパスを作っていないことを見る。
# $1 = asdd-hook-gate.sh。ASDD_WALK_TRACE に xtrace を入れる
asdd_walk_trace() {
  ASDD_WALK_TRACE="$(cd "$ASDD_WALK_DIR" && bash -xc '. "$1"; asdd_hook_enabled hooks' _ "$1" 2>&1 >/dev/null)" || :
}
ASDD_WALK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ff-asdd-walk.XXXXXX" 2>&1)" || ASDD_WALK_DIR=""
if [ -z "$ASDD_WALK_DIR" ] || [ ! -d "$ASDD_WALK_DIR" ]; then
  bad "case 48: 一時領域を作成できず、遡りを実測できません: $ASDD_WALK_DIR"
else
  asdd_walk_trace "$TESTS_DIR/../hooks/asdd-hook-gate.sh"
  case "$ASDD_WALK_TRACE" in
    *' -e /.asdd/config.json '*) asdd_walk_reached=1 ;;
    *) asdd_walk_reached=0 ;;
  esac
  case "$ASDD_WALK_TRACE" in
    *'//.asdd'* | *'//.git'*) asdd_walk_unc=1 ;;
    *) asdd_walk_unc=0 ;;
  esac
  if [ "$asdd_walk_unc" -eq 1 ]; then
    bad "asdd-hook-gate が '//' で始まるパスを検査している（Windows では UNC になる）"
  elif [ "$asdd_walk_reached" -eq 0 ]; then
    bad "case 48: 遡りがルートの '/.asdd' まで届いていない（一時領域が git 管理下、または xtrace が取れていない）"
  else
    ok "asdd-hook-gate はルートの '/.asdd' まで遡り、'//' で始まるパスを作らない"
  fi
  # 変異: ルートで '//' を作る元の形へ戻すと赤になる（検査の検出力）
  cp "$TESTS_DIR/../hooks/asdd-hook-gate.sh" "$ASDD_WALK_DIR/gate-mut.sh"
  sed 's/^    base="\${root%\/}"$/    base="$root"/' "$ASDD_WALK_DIR/gate-mut.sh" > "$ASDD_WALK_DIR/gate-mut.sh.new"
  mv -f "$ASDD_WALK_DIR/gate-mut.sh.new" "$ASDD_WALK_DIR/gate-mut.sh"
  if grep -qx '    base="$root"' "$ASDD_WALK_DIR/gate-mut.sh"; then
    asdd_walk_trace "$ASDD_WALK_DIR/gate-mut.sh"
    case "$ASDD_WALK_TRACE" in
      *'//.asdd'*) ok "case 48 の変異: ルートで '//' を作る形へ戻すと検出できる" ;;
      *) bad "case 48 の変異: ルートで '//' を作る形へ戻しても '//' が xtrace に現れない（検出力なし）" ;;
    esac
  else
    bad "case 48 の変異が当たっていない（base の代入行が見つからない）"
  fi
  rm -rf "$ASDD_WALK_DIR"
fi

# case 49: resource の root handoff を suite 全体へ渡した回は起動前に止める。
echo "== case 49: root handoff の継承を起動境界で検出する =="
HANDOFF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/root-handoff.XXXXXX" 2>&1)" || HANDOFF_DIR=""
if [ -z "$HANDOFF_DIR" ] || [ ! -d "$HANDOFF_DIR" ]; then
  bad "case 49: 一時領域を作れず root handoff の起動境界を実測できません"
else
cp "$RUNNER" "$HANDOFF_DIR/run-all.sh"
cat > "$HANDOFF_DIR/sentinel.sh" <<'SH'
#!/usr/bin/env bash
printf 'launched\n' >> "$ROOT_PROBE_SENTINEL"
SH
chmod +x "$HANDOFF_DIR/sentinel.sh"

handoff_probe() {
  local runner="$1" mode="$2" rc=0 output
  rm -f "$HANDOFF_DIR/sentinel"
  if [ "$mode" = default ]; then
    output="$(env -u FF_RUN_ALL_NESTED FF_DEV_TOOLKIT_ROOT=handoff-sensitive-value ROOT_PROBE_SENTINEL="$HANDOFF_DIR/sentinel" FF_GATE_RECORD=0 bash "$runner" 2>&1)" || rc=$?
  else
    output="$(FF_DEV_TOOLKIT_ROOT=handoff-sensitive-value ROOT_PROBE_SENTINEL="$HANDOFF_DIR/sentinel" FF_GATE_RECORD=0 bash "$runner" "$HANDOFF_DIR/sentinel.sh" 2>&1)" || rc=$?
  fi
  [[ "$rc" -eq 3 && ! -e "$HANDOFF_DIR/sentinel" \
    && "$output" == *FF_DEV_TOOLKIT_ROOT* && "$output" == *'env -u FF_DEV_TOOLKIT_ROOT'* \
    && "$output" != *handoff-sensitive-value* ]]
}
for _handoff_mode in default explicit; do
  if handoff_probe "$HANDOFF_DIR/run-all.sh" "$_handoff_mode"; then
    ok "root handoff / ${_handoff_mode}: rc3・suite未起動・変数名と解除方法・値を非表示"
  else
    bad "root handoff / ${_handoff_mode}: 起動前停止の契約が崩れた"
  fi
done

for _handoff_env in unset empty; do
  rm -f "$HANDOFF_DIR/sentinel"
  _handoff_rc=0
  if [ "$_handoff_env" = unset ]; then
    env -u FF_DEV_TOOLKIT_ROOT ROOT_PROBE_SENTINEL="$HANDOFF_DIR/sentinel" FF_GATE_RECORD=0 bash "$HANDOFF_DIR/run-all.sh" "$HANDOFF_DIR/sentinel.sh" > "$HANDOFF_DIR/clean.out" 2>&1 || _handoff_rc=$?
  else
    FF_DEV_TOOLKIT_ROOT='' ROOT_PROBE_SENTINEL="$HANDOFF_DIR/sentinel" FF_GATE_RECORD=0 bash "$HANDOFF_DIR/run-all.sh" "$HANDOFF_DIR/sentinel.sh" > "$HANDOFF_DIR/clean.out" 2>&1 || _handoff_rc=$?
  fi
  if [[ "$_handoff_rc" -eq 0 && -s "$HANDOFF_DIR/sentinel" ]]; then
    ok "root handoff / ${_handoff_env}: 明示suiteは従来どおり実行される"
  else
    bad "root handoff / ${_handoff_env}: 正常実行を誤拒否した"
  fi
done

# 既定・検査専用モードはトップレベル起動を測るため、外側の入れ子防止フラグだけ解除する。
# suite を実行しない宣言ダンプ・登録照合は、実体のツリーで従来の早期終了を測る。
for _handoff_meta in FF_RUN_ALL_DUMP_DECLARATIONS FF_RUN_ALL_CHECK_REGISTRATION; do
  if env -u FF_RUN_ALL_NESTED FF_DEV_TOOLKIT_ROOT=handoff-sensitive-value "${_handoff_meta}=1" bash "$TESTS_DIR/run-all.sh" > "$HANDOFF_DIR/meta.out" 2>&1 && [ -s "$HANDOFF_DIR/meta.out" ]; then
    ok "root handoff: ${_handoff_meta} の検査専用モードを誤拒否しない"
  else
    bad "root handoff: ${_handoff_meta} の早期終了が失敗・空振り"
  fi
done

# 診断と同じ root 固定を、同梱 resource 単体で使う正規経路は止めない。
_handoff_plugin="$(cd "$TESTS_DIR/.." && pwd -P)"
if FF_DEV_TOOLKIT_ROOT="$_handoff_plugin" bash "$_handoff_plugin/scripts/finish.sh" knowledge-commit status > "$HANDOFF_DIR/resource.out" 2>&1; then
  ok "root handoff: resource 単体の正規な固定契約を維持"
else
  bad "root handoff: resource 単体の正規経路が失敗"
fi

# 針の不在・改名・書式変更は成功と読まない。診断を外した写しは検査が落ちることも実測する。
# 変異の対象となるシェル変数式を展開せず照合する。
# shellcheck disable=SC2016
_handoff_predicate='if [[ -n "${FF_DEV_TOOLKIT_ROOT:-}" ]]; then'
if [ "$(grep -cFx -- "$_handoff_predicate" "$RUNNER")" -eq 1 ]; then
  # 本文中の変数式を変異対象のリテラルとして扱う。
  # shellcheck disable=SC2016
  sed 's/^if \[\[ -n "${FF_DEV_TOOLKIT_ROOT:-}" \]\]; then$/if false; then/' "$RUNNER" > "$HANDOFF_DIR/mutant.sh"
  if cmp -s "$RUNNER" "$HANDOFF_DIR/mutant.sh"; then
    bad "root handoff: 診断除去の変異が適用されていない"
  elif handoff_probe "$HANDOFF_DIR/mutant.sh" explicit; then
    bad "root handoff: 診断を除去しても検査が緑（検出力なし）"
  else
    ok "root handoff: 診断除去の変異は起動前停止の検査を赤にする"
  fi
else
  bad "root handoff: 対象の条件が不在・重複・改名（空振り）"
fi
rm -rf "$HANDOFF_DIR"
fi

echo "== case 50: 並列実行は前回の経過秒の長い順に起動し、出力は登録順のまま（Issue \`#2535\`） =="
# 起動順は slow-a〜d の probe ログ（開始の `S <名前>` 行）から読む。同時実行数 2 で 4 本を渡すと、
# 最初の 2 本が同時に起動し、残りの 2 本はどちらかが終わる 2 秒後まで起動しない。そこで「最初の
# 2 本の集合」だけを比べる（同時に起動した 2 本の間の前後は競合で揺れるので比べない）。並列の回は
# FF_RUN_ALL_PROBE_RENDEZVOUS=1 で、先に起動した 1 本がもう 1 本の開始を待ってから眠るようにする
# （負荷で 2 本目の起動が 2 秒を超えて遅れても、3 本目が先に「最初の 2 本」へ紛れ込まない）。
# 入れ子判定に当たらないよう FF_RUN_ALL_NESTED を落とし、外側から記録の上書きが漏れないよう
# FF_RUN_ALL_ELAPSED_RECORD も落としてから、必要な回だけ与える。
_lo_dir=""
if _lo_dir="$(mktemp -d "${TMPDIR:-/tmp}/ff-run-all-launch.XXXXXX")" && [ -d "$_lo_dir" ]; then
  _lo_run() { # <記録のパス（空なら与えない）> <同時実行数> [追加の env 代入...]
    local rec="$1" jobs="$2" rv=0
    shift 2
    [ "$jobs" -gt 1 ] && rv=1
    : > "$_lo_dir/probe.log"
    if [ -n "$rec" ]; then
      if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ELAPSED_RECORD \
        "$@" FF_RUN_ALL_JOBS="$jobs" FF_RUN_ALL_PROBE_LOG="$_lo_dir/probe.log" FF_RUN_ALL_PROBE_RENDEZVOUS="$rv" \
        FF_RUN_ALL_ELAPSED_RECORD="$rec" FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" \
        "$FIXTURES/slow-a/verify.sh" "$FIXTURES/slow-b/verify.sh" \
        "$FIXTURES/slow-c/verify.sh" "$FIXTURES/slow-d/verify.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
    else
      if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ELAPSED_RECORD \
        "$@" FF_RUN_ALL_JOBS="$jobs" FF_RUN_ALL_PROBE_LOG="$_lo_dir/probe.log" FF_RUN_ALL_PROBE_RENDEZVOUS="$rv" \
        FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" \
        "$FIXTURES/slow-a/verify.sh" "$FIXTURES/slow-b/verify.sh" \
        "$FIXTURES/slow-c/verify.sh" "$FIXTURES/slow-d/verify.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
    fi
  }
  # 最初に起動した 2 本を名前順に空白区切りで返す。probe ログが 4 本分そろっていなければ空を返す
  # （空のログ・欠けたログを「どちらの順でもない」まま緑にしない）。
  _lo_first2() {
    awk '$1 == "S" { n++; if (n <= 2) f[n] = $2 } END { if (n != 4) exit; if (f[1] > f[2]) { t = f[1]; f[1] = f[2]; f[2] = t } print f[1] " " f[2] }' \
      "$_lo_dir/probe.log" 2>/dev/null || true
  }
  _lo_expect_first2() { # <期待（名前順・空白区切り）> <検査名>
    local got
    got="$(_lo_first2)"
    if [ "$got" = "$1" ]; then
      ok "$2"
    else
      bad "$2 — 最初に起動した 2 本: '${got:-（probe ログが欠けている）}'"
      sed 's/^/    | /' "$_lo_dir/probe.log" >&2 || true
    fi
  }
  _lo_rows() { awk 'END { print NR }' "$1" 2>/dev/null || echo 0; }
  _lo_headers="== slow-a ==
== slow-b ==
== slow-c ==
== slow-d ==
== summary =="

  # 50-A: 記録のある 4 本は秒の降順（数値として比べる。100 秒 > 9 秒）に起動し、見出しと
  # elapsed-sec は登録順のまま
  printf 'slow-d\t9\nslow-c\t100\nslow-b\t5\nslow-a\t7\nother-suite\t99\n' > "$_lo_dir/rec.tsv"
  _lo_run "$_lo_dir/rec.tsv" 2
  expect_rc 0 "50-A: 並べ替えた並列実行で 4 本すべてが pass なら rc=0"
  expect_has '^🧵 起動順: 前回の経過秒の長い順（記録なし 0 件を先に、記録あり 4 件を秒の降順で起動）$' \
    "50-A: 並べ替えた回は起動順を 1 行で名乗る"
  _lo_expect_first2 "slow-c slow-d" "50-A: 前回の経過秒が長い 2 本（slow-c 100 秒 / slow-d 9 秒）を先に起動する（文字列ではなく数値で比べる）"
  if [ "$(printf '%s\n' "$RUN_OUT" | grep '^== ' || true)" = "$_lo_headers" ]; then
    ok "50-A: 起動順を変えても見出しは登録順に並ぶ"
  else
    bad "50-A: 起動順を変えた回の見出しが登録順でない"
  fi
  expect_has '^elapsed-sec: slow-a=[0-9]* slow-b=[0-9]* slow-c=[0-9]* slow-d=[0-9]*$' \
    "50-A: elapsed-sec の並びは登録順のまま"

  # 50-B: 実行後の記録は今回の 4 本を書き換え、今回走らなかった suite の行を残す
  if [ "$(awk -F '\t' '$1 ~ /^slow-[abcd]$/ && $2 ~ /^[0-9]+$/ && $2 + 0 >= 1 { n++ } END { print n + 0 }' "$_lo_dir/rec.tsv")" -eq 4 ] \
    && [ "$(awk -F '\t' '$1 == "slow-c" { print $2 }' "$_lo_dir/rec.tsv")" != "100" ] \
    && [ "$(awk -F '\t' '$1 == "other-suite" && $2 == "99" { n++ } END { print n + 0 }' "$_lo_dir/rec.tsv")" -eq 1 ] \
    && [ "$(_lo_rows "$_lo_dir/rec.tsv")" -eq 5 ]; then
    ok "50-B: 実行後の記録は今回の経過秒で上書きし、走らなかった suite の行を残す"
  else
    bad "50-B: 実行後の記録が期待と違う"
    sed 's/^/    | /' "$_lo_dir/rec.tsv" >&2 || true
  fi

  # 50-C: 記録に無い suite は記録のある suite より先に起動する
  printf 'slow-a\t10\nslow-b\t20\n' > "$_lo_dir/rec.tsv"
  _lo_run "$_lo_dir/rec.tsv" 2
  expect_has '^🧵 起動順: 前回の経過秒の長い順（記録なし 2 件を先に、記録あり 2 件を秒の降順で起動）$' \
    "50-C: 記録なしの件数を名乗る"
  _lo_expect_first2 "slow-c slow-d" "50-C: 記録に無い 2 本（slow-c / slow-d）を記録のある 2 本より先に起動する"

  # 50-I: 同じ秒数どうしは登録順を保つ（安定な並べ替え）
  printf 'slow-a\t10\nslow-b\t10\nslow-c\t10\nslow-d\t50\n' > "$_lo_dir/rec.tsv"
  _lo_run "$_lo_dir/rec.tsv" 2
  _lo_expect_first2 "slow-a slow-d" "50-I: 同じ秒数どうしは登録順（slow-d の次は同順位の先頭 slow-a）"

  # 50-D: 記録が無い回は登録順で起動して理由を出し、実行後に記録を作る
  rm -f "$_lo_dir/rec.tsv"
  _lo_run "$_lo_dir/rec.tsv" 2
  expect_rc 0 "50-D: 記録が無い回も rc=0"
  expect_has '^🧵 起動順: 登録順（前回の経過秒の記録がありません: ' "50-D: 記録が無い回は登録順と理由を出す"
  _lo_expect_first2 "slow-a slow-b" "50-D: 記録が無い回は登録順（slow-a / slow-b が先）"
  if [ -f "$_lo_dir/rec.tsv" ] && [ "$(_lo_rows "$_lo_dir/rec.tsv")" -eq 4 ]; then
    ok "50-D: 記録が無い回の実行後に 4 本分の記録を作る"
  else
    bad "50-D: 記録が無い回の実行後に記録が作られていない"
  fi

  # 50-E: 1 行でも形式が崩れた記録は使わず登録順で起動し、実行後は正しい行だけで書き直す。
  # 崩れた行だけを読み飛ばして残りを使う実装なら slow-c / slow-d が先になるので、起動順で区別できる。
  # 走らなかった suite の崩れた行（other-suite）も持ち越さない。
  printf 'slow-c\t40\nslow-d\t30\nslow-b\t5\nslow-a\tten\nother-suite\tbad\n' > "$_lo_dir/rec.tsv"
  _lo_run "$_lo_dir/rec.tsv" 2
  expect_rc 0 "50-E: 形式の崩れた記録でも rc=0"
  expect_has '^🧵 起動順: 登録順（前回の経過秒の記録を読めないか、形式が崩れています: ' \
    "50-E: 形式の崩れた記録は登録順と理由を出す"
  _lo_expect_first2 "slow-a slow-b" "50-E: 形式の崩れた記録は部分的に使わず登録順で起動する"
  if [ "$(awk -F '\t' 'NF == 2 && $1 ~ /^slow-[abcd]$/ && $2 ~ /^[0-9]+$/ { n++ } END { print n + 0 }' "$_lo_dir/rec.tsv")" -eq 4 ] \
    && [ "$(_lo_rows "$_lo_dir/rec.tsv")" -eq 4 ]; then
    ok "50-E: 崩れた記録は捨て、今回の 4 本だけで書き直す（走らなかった suite の崩れた行も持ち越さない）"
  else
    bad "50-E: 崩れた記録の書き直しが期待と違う"
    sed 's/^/    | /' "$_lo_dir/rec.tsv" >&2 || true
  fi

  # 50-E2: 空の記録も形式の崩れとして扱う（記録なしの suite として全件を並べ替えた形にしない）
  : > "$_lo_dir/rec.tsv"
  _lo_run "$_lo_dir/rec.tsv" 2
  expect_has '^🧵 起動順: 登録順（前回の経過秒の記録を読めないか、形式が崩れています: ' \
    "50-E2: 空の記録は登録順と理由を出す"
  _lo_expect_first2 "slow-a slow-b" "50-E2: 空の記録は登録順で起動する"

  # 50-F: 記録を与えない明示引数の実行は従来どおり（起動順の行を出さず、登録順）
  _lo_run "" 2
  expect_lacks '^🧵 起動順' "50-F: 記録を与えない明示引数の実行は起動順の行を出さない"
  _lo_expect_first2 "slow-a slow-b" "50-F: 記録を与えない明示引数の実行は登録順で起動する"

  # 50-G: 逐次実行と入れ子の実行は記録を読まず、書き換えもしない
  printf 'slow-d\t40\nslow-c\t30\nslow-b\t20\nslow-a\t10\n' > "$_lo_dir/rec.tsv"
  cp "$_lo_dir/rec.tsv" "$_lo_dir/rec.orig"
  _lo_run "$_lo_dir/rec.tsv" 1
  expect_lacks '^🧵 起動順' "50-G: 逐次実行（FF_RUN_ALL_JOBS=1）は起動順の行を出さない"
  if cmp -s "$_lo_dir/rec.tsv" "$_lo_dir/rec.orig"; then
    ok "50-G: 逐次実行は記録を書き換えない"
  else
    bad "50-G: 逐次実行が記録を書き換えた"
  fi
  _lo_run "$_lo_dir/rec.tsv" 2 FF_RUN_ALL_NESTED=1
  expect_lacks '^🧵 起動順' "50-G: 入れ子の実行は起動順の行を出さない"
  _lo_expect_first2 "slow-a slow-b" "50-G: 入れ子の実行は記録があっても登録順で起動する"
  if cmp -s "$_lo_dir/rec.tsv" "$_lo_dir/rec.orig"; then
    ok "50-G: 入れ子の実行は記録を書き換えない"
  else
    bad "50-G: 入れ子の実行が記録を書き換えた"
  fi

  # 50-H: 記録を書けない回（置き場がファイルで塞がれている）も終了コードを変えない
  : > "$_lo_dir/blocked"
  _lo_run "$_lo_dir/blocked/rec.tsv" 2
  expect_rc 0 "50-H: 記録を書けない回も rc=0（記録は検証結果ではない）"
  expect_has '^suites: total=4 run=4 passed=4 failed=0 skipped=0 not-run=0$' "50-H: 記録を書けない回も 4 本すべてを実行する"

  # 50-H2: 記録の場所がディレクトリ（読めない記録）なら登録順で理由を出し、その中へ書き込まない
  mkdir -p "$_lo_dir/recdir"
  _lo_run "$_lo_dir/recdir" 2
  expect_rc 0 "50-H2: 記録の場所がディレクトリでも rc=0"
  expect_has '^🧵 起動順: 登録順（前回の経過秒の記録を読めないか、形式が崩れています: ' \
    "50-H2: 記録の場所がディレクトリなら読めない記録として登録順と理由を出す"
  if [ -z "$(ls -A "$_lo_dir/recdir" 2>/dev/null)" ]; then
    ok "50-H2: 記録の場所がディレクトリなら、その中へ一時ファイルを残さない"
  else
    bad "50-H2: 記録の場所のディレクトリの中にファイルが作られた: $(ls -A "$_lo_dir/recdir")"
  fi

  # 50-H3: 書けない既存ディレクトリ（read-only の環境）でも、シェルのエラー文を出さない
  mkdir -p "$_lo_dir/rodir"
  chmod 555 "$_lo_dir/rodir"
  if [ -w "$_lo_dir/rodir" ]; then
    echo "  ○ skip: 書き込み権限を外せない実行者（root など）のため 50-H3 を実測できません"
  else
    _lo_run "$_lo_dir/rodir/rec.tsv" 2
    expect_rc 0 "50-H3: 書けない既存ディレクトリでも rc=0"
    expect_lacks 'rec\.tsv\.tmp\.' "50-H3: 一時ファイルを作れないシェルのエラー文を出さない（黙って何もしない）"
  fi
  chmod 755 "$_lo_dir/rodir"

  # 50-K: 記録へ載せるのは pass した suite だけ（赤の短い秒数で、直った次の回に後ろへ回さない）
  rm -f "$_lo_dir/rec.tsv"
  if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_PROBE_LOG \
    FF_RUN_ALL_JOBS=2 FF_RUN_ALL_ELAPSED_RECORD="$_lo_dir/rec.tsv" FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
    bash "$RUNNER" "$FIXTURES/slow-a/verify.sh" "$FIXTURES/fail/verify.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
  expect_rc 1 "50-K: 赤を含む並べ替え実行は非 0"
  if [ "$(awk -F '\t' '$1 == "slow-a" { n++ } END { print n + 0 }' "$_lo_dir/rec.tsv" 2>/dev/null)" -eq 1 ] \
    && [ "$(awk -F '\t' '$1 == "fail" { n++ } END { print n + 0 }' "$_lo_dir/rec.tsv" 2>/dev/null)" -eq 0 ]; then
    ok "50-K: 記録には pass した suite だけを載せ、赤の suite は載せない"
  else
    bad "50-K: 赤の suite の秒数が記録に載った、または pass の行が無い"
    sed 's/^/    | /' "$_lo_dir/rec.tsv" >&2 || true
  fi

  rm -rf "$_lo_dir"
else
  bad "case 50: 一時領域を作成できず、起動順を実測できません"
fi

# 50-J: 既定一覧の実行は <git common dir>/ff-dev-toolkit/run-all-elapsed.tsv を読み書きし、同じ
# リポジトリの別 worktree からもその記録を使う。既定一覧の形は case 39 と同じ awk で SCRIPTS などを
# 差し替えた複製ランナーを、隔離した一時 git リポジトリへ置いて作る（本リポジトリの記録に触れない）。
if ! command -v git >/dev/null 2>&1; then
  echo "  ○ skip: git が無いため既定一覧の記録の置き場を実測できません（50-J の検査は 1 件も実行していません）"
else
  _lj_fx="$RUN_WORK/ff-run-all-launch-default"
  rm -rf "$_lj_fx"
  mkdir -p "$_lj_fx/repo/tests/slow-a" "$_lj_fx/repo/tests/slow-b" "$_lj_fx/repo/tests/lj-required-probe" "$_lj_fx/repo/scripts"
  cp "$FIXTURES/slow-a/verify.sh" "$_lj_fx/repo/tests/slow-a/verify.sh"
  cp "$FIXTURES/slow-b/verify.sh" "$_lj_fx/repo/tests/slow-b/verify.sh"
  # REQUIRED_SUITES は空にできない（case 39 と同じ理由）ので、実行されない skip 分岐を持つ材料を 1 本置く。
  cat > "$_lj_fx/repo/tests/lj-required-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
if false; then
  echo "○ skip: 名簿掲載の材料（この分岐は実行されない）"
  exit 0
fi
exit 0
PROBE
  chmod +x "$_lj_fx/repo/tests/slow-a/verify.sh" "$_lj_fx/repo/tests/slow-b/verify.sh" "$_lj_fx/repo/tests/lj-required-probe/verify.sh"
  awk '
    /^  SCRIPTS=\($/ {
      print
      print "    \"$SCRIPT_DIR/slow-a/verify.sh\""
      print "    \"$SCRIPT_DIR/slow-b/verify.sh\""
      print "    \"$SCRIPT_DIR/lj-required-probe/verify.sh\""
      in_scripts = 1
      next
    }
    in_scripts && /^  \)$/ { in_scripts = 0; print; next }
    in_scripts { next }
    /^REQUIRED_SUITES=\($/ { print; print "  lj-required-probe"; in_required = 1; next }
    in_required && /^\)$/ { in_required = 0; print; next }
    in_required { next }
    /^MISS_PROBE_BASELINE=\($/ { print; print "  slow-a"; print "  slow-b"; print "  lj-required-probe"; in_baseline = 1; next }
    in_baseline && /^\)$/ { in_baseline = 0; print; next }
    in_baseline { next }
    { print }
  ' "$RUNNER" > "$_lj_fx/repo/tests/run-all.sh"
  cp "$TESTS_DIR/../scripts/record-gate-head.sh" "$_lj_fx/repo/scripts/record-gate-head.sh"
  _lj_git() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
  _lj_setup_rc=0
  [ "$(grep -c '^  lj-required-probe$' "$_lj_fx/repo/tests/run-all.sh")" -eq 2 ] || _lj_setup_rc=1
  _lj_git -C "$_lj_fx/repo" init -q . >/dev/null 2>&1 || _lj_setup_rc=1
  _lj_git -C "$_lj_fx/repo" add -A >/dev/null 2>&1 || _lj_setup_rc=1
  _lj_git -C "$_lj_fx/repo" commit -qm "fixture" >/dev/null 2>&1 || _lj_setup_rc=1
  _lj_git -C "$_lj_fx/repo" worktree add -q -b wt "$_lj_fx/wt" >/dev/null 2>&1 || _lj_setup_rc=1
  _lj_common="$(cd "$_lj_fx/repo/.git" 2>/dev/null && pwd -P)" || _lj_setup_rc=1
  if [ "$_lj_setup_rc" -ne 0 ] || [ -z "${_lj_common:-}" ]; then
    bad "50-J: 既定一覧の複製リポジトリを用意できず実測できません（空振り）"
  else
    _lj_run() { # <ランナー>
      if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP \
        -u FF_RUN_ALL_ELAPSED_RECORD -u FF_RUN_ALL_PROBE_LOG FF_RUN_ALL_JOBS=2 FF_GATE_RECORD_FILE="$_lj_fx/gate-record" \
        bash "$1" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
    }
    _lj_rec="$_lj_common/ff-dev-toolkit/run-all-elapsed.tsv"
    _lj_run "$_lj_fx/repo/tests/run-all.sh"
    expect_rc 0 "50-J: 既定一覧（複製リポジトリ）の並列実行が rc=0"
    if out_matches "^🧵 起動順: 登録順（前回の経過秒の記録がありません: ${_lj_rec}）\$"; then
      ok "50-J: 既定一覧は <git common dir>/ff-dev-toolkit/run-all-elapsed.tsv を絶対パスで名指しする"
    else
      bad "50-J: 既定一覧の記録の場所が期待（${_lj_rec}）と違う"
      dump_out
    fi
    if [ "$(awk -F '\t' '$1 ~ /^(slow-a|slow-b|lj-required-probe)$/ && $2 ~ /^[0-9]+$/ { n++ } END { print n + 0 }' "$_lj_rec" 2>/dev/null)" -eq 3 ]; then
      ok "50-J: 既定一覧の実行後、common dir の記録に 3 本分を書く"
    else
      bad "50-J: 既定一覧の実行後に common dir の記録が書かれていない"
    fi
    _lj_run "$_lj_fx/wt/tests/run-all.sh"
    expect_rc 0 "50-J: 同じリポジトリの別 worktree の既定一覧も rc=0"
    expect_has '^🧵 起動順: 前回の経過秒の長い順（記録なし 0 件を先に、記録あり 3 件を秒の降順で起動）$' \
      "50-J: 別 worktree の既定一覧は common dir の記録を使って並べ替える"
  fi
fi

echo "== case 51: 赤の回は落ちた suite だけを回し直すコマンドを出し、そのまま実行できる（Issue \`#2533\`） =="
# 名指し実行は suite 名・ディレクトリを受けず verify.sh のパスしか受けない（OBS-282）。出したコマンドを
# 別の cwd から実際に実行し、1 本だけが走ること（not-run が 0）で「パスとして通る」ことを測る。
_rr_extract() { # 直前の RUN_OUT から再実行コマンド（案内行の次の行）を取り出す
  printf '%s\n' "$RUN_OUT" | awk 'f { sub(/^    /, ""); print; exit } /^  落ちた suite だけを回し直す（/ { f = 1 }'
}
# 51-A: 赤と緑の混在では、赤の suite だけを絶対パスで並べる
RUN_JOBS=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/fail/verify.sh"
expect_rc 1 "51-A: 赤を含む実行は非 0"
expect_has '^  落ちた suite だけを回し直す（部分実行。合格の証拠には通しの 1 回が別に要る）:$' "51-A: 赤の回は再実行の案内を出す"
_rr_cmd="$(_rr_extract)"
_rr_shape_ok=0
case "$_rr_cmd" in
  "bash /"*"/fixtures/fail/verify.sh")
    case "$_rr_cmd" in
      *"/fixtures/pass/verify.sh"*) bad "51-A: 再実行コマンドに緑の suite が混ざった: ${_rr_cmd}" ;;
      *) ok "51-A: 再実行コマンドは赤の suite だけを絶対パスで並べる"; _rr_shape_ok=1 ;;
    esac
    ;;
  *) bad "51-A: 再実行コマンドの形が違う: '${_rr_cmd:-（空）}'" ;;
esac
# 51-B: 出したコマンドを別の cwd から実行すると、赤の suite 1 本だけが走る。形が 51-A の期待どおりの
# ときだけ実行し、入れ子の印も付ける（引数の欠けたコマンドが既定一覧＝本 suite を再帰的に起動しないように。
# 入れ子の引数なし実行はランナーが拒否する）。
if [ "$_rr_shape_ok" -eq 1 ]; then
  if _rr_out="$(cd / && env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_NESTED=1 FF_RUN_ALL_JOBS=1 \
    FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash -c "$_rr_cmd" 2>&1)"; then _rr_rc=0; else _rr_rc=$?; fi
  if [ "$_rr_rc" -eq 1 ] && [ "$(printf '%s\n' "$_rr_out" | grep -c '^suites: total=1 run=1 passed=0 failed=1 skipped=0 not-run=0$')" -eq 1 ]; then
    ok "51-B: 再実行コマンドは別の cwd からでも赤の suite 1 本だけを走らせる"
  else
    bad "51-B: 再実行コマンドがそのまま実行できない（rc=${_rr_rc}）"
    printf '%s\n' "$_rr_out" | sed 's/^/    | /' >&2
  fi
else
  bad "51-B: 再実行コマンドの形が期待と違うため実行を試せない（空振り）"
fi
# 51-C: 相対パスで渡した suite も絶対パスへ直して出す
if RUN_OUT="$(cd "$FIXTURES" && env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_JOBS=1 \
  FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" fail/verify.sh 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
case "$(_rr_extract)" in
  "bash /"*" /"*"/fail/verify.sh") ok "51-C: 相対パスで渡した suite も絶対パスで出す" ;;
  *) bad "51-C: 相対パスの suite が絶対パスになっていない: '$(_rr_extract)'" ;;
esac
# 51-D: 緑の回は案内を出さない
RUN_JOBS=1 run_runner "$FIXTURES/pass/verify.sh"
expect_lacks '^  落ちた suite だけを回し直す' "51-D: 緑の回は再実行の案内を出さない"
# 51-E: 並列実行で赤が 2 本あれば、`✗ failed:` と同じ集合・同じ並びで両方を出す
RUN_JOBS=2 run_runner "$FIXTURES/fail/verify.sh" "$FIXTURES/pass/verify.sh" "$FIXTURES/stale/verify.sh"
_rr_failed="$(printf '%s\n' "$RUN_OUT" | awk '/^✗ failed: / { sub(/^✗ failed: /, ""); print; exit }')"
_rr_names="$(_rr_extract | awk '{ for (i = 3; i <= NF; i++) { n = $i; sub(/\/verify\.sh$/, "", n); sub(/^.*\//, "", n); printf "%s%s", (i == 3 ? "" : " "), n } }')"
if [ -n "$_rr_failed" ] && [ "$_rr_failed" = "fail stale" ] && [ "$_rr_names" = "$_rr_failed" ]; then
  ok "51-E: 並列実行の赤 2 本を、✗ failed: と同じ集合・同じ並びで再実行コマンドへ並べる"
else
  bad "51-E: 再実行コマンドの suite（${_rr_names:-空}）が ✗ failed:（${_rr_failed:-空}）と一致しない"
fi
# 51-F: 全件モードの回は前置 FF_RUN_ALL_FULL=1 を保つ（貼り直した再実行が別モードで緑に化けない）
RUN_FULL=1 RUN_JOBS=1 run_runner "$FIXTURES/fail/verify.sh"
case "$(_rr_extract)" in
  "FF_RUN_ALL_FULL=1 bash /"*"/fixtures/fail/verify.sh") ok "51-F: 全件モードの回は再実行コマンドに FF_RUN_ALL_FULL=1 を前置する" ;;
  *) bad "51-F: 全件モードの再実行コマンドに前置が無い: '$(_rr_extract)'" ;;
esac

# case 53: ゲートの記録の制御（FF_GATE_RECORD_FILE / FF_GATE_RECORD）を suite へ継承しない（OBS-414）。
suite_cases_source "$SCRIPT_DIR/cases" gate-record-scope.sh

# suite-cases-end: execution-contracts.sh
