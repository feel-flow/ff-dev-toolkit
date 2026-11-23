# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# case 57: ランナーの自己検証（tests/run-all/verify.sh）とゲート間の排他の境界（ADR-095）
#
# verify.sh から source される（ok / bad / expect_* / RUN_OUT / RUN_RC / RUNNER / RUN_WORK を共有）。
#
# 境界は 2 つの向きを持つ。
#   - 自己検証 → ゲート: 自己検証は観測を自分の系譜へ閉じる（verify.sh の冒頭。case 52 / 55-I が
#     写しの起動で確かめる）。ここでは、この suite がいま使っている ps そのものを実プロセスで測る
#   - ゲート → 自己検証: ランナーの並走検出（ff_startup_other_gates）は、自己検証が fixture へ起動した
#     run-all.sh を別のゲートに数えない。自己検証を suite として抱えるゲート自身は従来どおり数える
#
# 並走検出は run-all.sh から関数だけを取り出し、合成したプロセス一覧（ps の stub）を読ませて測る。
# 本物の run-all.sh は起動しない。
#
# 変異検出（57-D が同じ一覧で実測する）:
#   - 候補から「自己検証の子孫」を外す条件を消すと、fixture のランナーが並走として現れる（57-A が赤）

echo ""
echo "== case 57: 自己検証とゲート間の排他の境界 =="

_c57_fx="$RUN_WORK/c57"
mkdir -p "$_c57_fx/bin"
_c57_fn="$_c57_fx/other-gates-fn.sh"
_c57_rows="$_c57_fx/rows"
_c57_real_ps="$(command -v ps)"
if awk '
  BEGIN { found = 0 }
  /^# >>> ff-startup-other-gates$/ { grab = 1; next }
  /^# <<< ff-startup-other-gates$/ { if (grab) found = 1; exit }
  grab { print }
  END { if (!found) exit 2 }
' "$RUNNER" > "$_c57_fn" && [ "$(grep -c '^ff_startup_other_gates() {$' "$_c57_fn")" -eq 1 ]; then
  ok "57: 並走検出の関数を run-all.sh から取り出せた"
else
  bad "57: 並走検出の関数を run-all.sh から取り出せない（以降の検査は成立していません）"
fi

# 合成したプロセス一覧を返す ps。全列挙の形は「観測者の祖先（名前は observer）+ 一覧ファイルの行」、
# 個別の PID の args は一覧ファイルから返す。一覧ファイルは `PID|PPID|args` の行。
cat > "$_c57_fx/bin/ps" <<'STUB'
#!/usr/bin/env bash
real_ps="${C57_REAL_PS:?}"
rows="${C57_ROWS:?}"
if [ "${1:-}" = "-ww" ] && [ "${2:-}" = "-eo" ]; then
  pid="$PPID"
  i=0
  while [ "$i" -lt 8 ] && [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
    printf "%s 1 bash observer\n" "$pid"
    pid="$("$real_ps" -o ppid= -p "$pid" 2>/dev/null | tr -d "[:space:]")" || exit 1
    i=$((i + 1))
  done
  while IFS='|' read -r fp fpp fa || [ -n "${fp:-}" ]; do
    [ -n "${fp:-}" ] || continue
    printf "%s %s %s\n" "$fp" "$fpp" "$fa"
  done < "$rows"
  exit 0
fi
if [ "${1:-}" = "-ww" ] && [ "${2:-}" = "-o" ] && [ "${3:-}" = "args=" ] && [ "${4:-}" = "-p" ]; then
  while IFS='|' read -r fp _fpp fa || [ -n "${fp:-}" ]; do
    if [ "$fp" = "${5:-}" ]; then
      printf "%s\n" "$fa"
      exit 0
    fi
  done < "$rows"
  exit 1
fi
exec "$real_ps" "$@"
STUB
chmod +x "$_c57_fx/bin/ps"

# 取り出した関数を、合成した一覧の下で 1 回呼ぶ。出力は「PID:ランナーのパス」の行。
_c57_observe() { # [関数ファイル]
  if RUN_OUT="$(C57_REAL_PS="$_c57_real_ps" C57_ROWS="$_c57_rows" PATH="$_c57_fx/bin:$PATH" \
    bash -c '. "$1" && ff_startup_other_gates' _ "${1:-$_c57_fn}" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}
_c57_expect() { # <期待する出力（行を空白区切りで。空なら 0 件）> <検査名>
  if [ "$RUN_RC" -eq 0 ] && [ "$(printf '%s\n' "$RUN_OUT" | sort | tr '\n' ' ' | sed 's/ *$//')" = "$1" ]; then
    ok "$2"
  else
    bad "$2 — rc=${RUN_RC} 出力=[$(printf '%s' "$RUN_OUT" | tr '\n' ' ')] 期待=[$1]"
  fi
}

# 57-A: 単体の自己検証（4194100）が fixture へ起動したランナー（4194101）は数えない。自己検証を
# suite として抱えるゲート（4194120）は数え、その自己検証（4194121）の fixture ランナー（4194122）は
# 数えない。
cat > "$_c57_rows" <<'ROWS'
4194100|1|bash /w/a/plugins/ff-dev-toolkit/tests/run-all/verify.sh
4194101|4194100|bash /w/a/plugins/ff-dev-toolkit/tests/run-all.sh /tmp/fx/probe/verify.sh
4194120|1|bash /w/b/plugins/ff-dev-toolkit/tests/run-all.sh
4194121|4194120|bash /w/b/plugins/ff-dev-toolkit/tests/run-all/verify.sh
4194122|4194121|bash /w/b/plugins/ff-dev-toolkit/tests/run-all.sh /tmp/fx2/probe/verify.sh
ROWS
_c57_observe
_c57_expect "4194120:/w/b/plugins/ff-dev-toolkit/tests/run-all.sh" \
  "57-A: 自己検証の fixture ランナーは並走に数えず、自己検証を抱えるゲート自身は数える"

# 57-B: 自己検証として読む起動形（相対パス・sh とオプション・直接実行・複製木の中のランナー）。
cat > "$_c57_rows" <<'ROWS'
4194100|1|bash plugins/ff-dev-toolkit/tests/run-all/verify.sh
4194101|4194100|bash /w/a/plugins/ff-dev-toolkit/tests/run-all.sh /tmp/fx/probe/verify.sh
4194102|1|sh -e -u tests/run-all/verify.sh
4194103|4194102|bash /tmp/copy/tests/run-all.sh
4194104|1|/w/c/tests/run-all/verify.sh
4194105|4194104|bash -e /w/c/tests/run-all.sh /tmp/fx/probe/verify.sh
4194106|4194105|bash /tmp/deep/tests/run-all.sh /tmp/fx/probe/verify.sh
ROWS
_c57_observe
_c57_expect "" "57-B: 相対パス・sh とオプション・直接実行の自己検証と、その孫のランナーまで並走に数えない"

# 57-C: 自己検証として読めない形は、従来どおり並走に数える（少なく数える側へ倒さない）。
#   - 作業ディレクトリからの起動（`bash verify.sh`。パスから suite を特定できない）
#   - `-c` に続く語がそのパスである形（`-c` をオプションとして読み飛ばすと、次の語を suite のパスと
#     読んで子を外してしまう。`-c` の判定を消した変異はこの行が赤にする）
#   - 別の suite（run-all 以外）と、名前が後方一致するだけのディレクトリ（xrun-all）
cat > "$_c57_rows" <<'ROWS'
4194100|1|bash verify.sh
4194101|4194100|bash /w/a/tests/run-all.sh /tmp/fx/probe/verify.sh
4194102|1|bash -c tests/run-all/verify.sh
4194103|4194102|bash /w/b/tests/run-all.sh
4194104|1|bash /w/c/tests/public-layout/verify.sh
4194105|4194104|bash /w/c/public/tests/run-all.sh
4194106|1|bash /w/d/tests/xrun-all/verify.sh
4194107|4194106|bash /w/d/tests/run-all.sh
ROWS
_c57_observe
_c57_expect "4194101:/w/a/tests/run-all.sh 4194103:/w/b/tests/run-all.sh 4194105:/w/c/public/tests/run-all.sh 4194107:/w/d/tests/run-all.sh" \
  "57-C: 自己検証として読めない親（cwd 起動・-c の文字列・別 suite・名前の後方一致）の子は並走に数える"

# 57-D: 変異 — 候補から「自己検証の子孫」を外す条件を消すと、57-A の一覧で fixture のランナーが
# 並走として現れる（57-A はその変異を赤にする）。条件の行が 1 つでなければ空振りとして赤。
_c57_mut="$_c57_fx/other-gates-fn.mut.sh"
sed 's/ && !underunit(pid)) gates\[pid\]=1/) gates[pid]=1/' "$_c57_fn" > "$_c57_mut"
if [ "$(grep -c ' && !underunit(pid)) gates\[pid\]=1' "$_c57_fn")" -eq 1 ] \
  && [ "$(grep -c ' && !underunit(pid)) gates\[pid\]=1' "$_c57_mut")" -eq 0 ]; then
  cat > "$_c57_rows" <<'ROWS'
4194100|1|bash /w/a/plugins/ff-dev-toolkit/tests/run-all/verify.sh
4194101|4194100|bash /w/a/plugins/ff-dev-toolkit/tests/run-all.sh /tmp/fx/probe/verify.sh
4194120|1|bash /w/b/plugins/ff-dev-toolkit/tests/run-all.sh
4194121|4194120|bash /w/b/plugins/ff-dev-toolkit/tests/run-all/verify.sh
4194122|4194121|bash /w/b/plugins/ff-dev-toolkit/tests/run-all.sh /tmp/fx2/probe/verify.sh
ROWS
  _c57_observe "$_c57_mut"
  _c57_expect "4194101:/w/a/plugins/ff-dev-toolkit/tests/run-all.sh 4194120:/w/b/plugins/ff-dev-toolkit/tests/run-all.sh" \
    "57-D: 自己検証の子孫を外す条件を消した変異では、fixture のランナーが並走として現れる（57-A が赤にする）"
else
  bad "57-D: 並走検出の条件行を変異できない（該当行が 1 行ではないか、置換が当たっていない。検査が空振りしている）"
fi

# 57-E: この suite がいま使っている ps（verify.sh が PATH の先頭へ置いたもの）を実プロセスで測る。
# 親を失った孤児（系譜の外）は全列挙に現れず、この suite の子（系譜の中）は現れる。孤児は
# 個別の PID を問う形（ホストの ps へそのまま渡る）では生きて見えるので、「居ないから見えない」
# ではないことも同時に確かめる。
_c57_orphan_file="$_c57_fx/orphan.pid"
rm -f "$_c57_orphan_file"
( sleep 60 >/dev/null 2>&1 & printf '%s\n' "$!" > "$_c57_orphan_file" )
sleep 60 >/dev/null 2>&1 &
_c57_child=$!
_c57_orphan="$(cat "$_c57_orphan_file" 2>/dev/null || true)"
# 起動に使ったサブシェルは上の行で終了済みなので、孤児の親はこの suite の外へ付け替わっている。
_c57_listing="$(LC_ALL=C ps -ww -eo pid=,ppid=,args= 2>/dev/null)" || _c57_listing=""
_c57_has_pid() { # <一覧> <PID>
  printf '%s\n' "$1" | awk -v p="$2" '$1 == p { found = 1 } END { exit found ? 0 : 1 }'
}
if [ -n "$_c57_orphan" ] && [ -n "$_c57_listing" ] \
  && kill -0 "$_c57_orphan" 2>/dev/null && kill -0 "$_c57_child" 2>/dev/null \
  && [ -n "$(ps -o pid= -p "$_c57_orphan" 2>/dev/null | tr -d '[:space:]')" ]; then
  if _c57_has_pid "$_c57_listing" "$$"; then
    ok "57-E: この suite の ps の全列挙に、この suite 自身が現れる"
  else
    bad "57-E: この suite の ps の全列挙に、この suite 自身の PID が現れない"
  fi
  if _c57_has_pid "$_c57_listing" "$_c57_child"; then
    ok "57-E: この suite の子プロセス（系譜の中）は全列挙に現れる"
  else
    bad "57-E: この suite の子プロセス（${_c57_child}）が全列挙に現れない（絞り込みが広すぎる）"
  fi
  if _c57_has_pid "$_c57_listing" "$_c57_orphan"; then
    bad "57-E: 系譜の外の孤児（${_c57_orphan}）が全列挙に現れた（観測が閉じていない）"
  else
    ok "57-E: 系譜の外のプロセス（孤児）は全列挙に現れない（個別の PID を問えば生きて見える）"
  fi
else
  bad "57-E: 実プロセスの対照を用意できない（孤児=${_c57_orphan:-なし} / 一覧の取得・生存確認に失敗。検査は成立していません）"
fi
kill "$_c57_child" 2>/dev/null || true
[ -z "$_c57_orphan" ] || kill "$_c57_orphan" 2>/dev/null || true
wait "$_c57_child" 2>/dev/null || true

# 57-F: verify.sh の置く ps が絞るのは「全プロセスを列挙する 2 つの形」だけ。ランナーと待機 lib が全プロセス
# の列挙に使う形がその 2 つから外れると、ps は素通しになり、内側の観測へ別セッションのゲートが混ざる
# のにどの検査も赤にならない。列挙の形（-e / -A を含む起動）を実装から拾い、ps が絞る形と突き合わせる。
_c57_shim_case="  '-ww -eo pid=,ppid=,args=' | '-eo pid=,ppid=') ;;"
if [ "$(grep -cxF -- "$_c57_shim_case" "$SCRIPT_DIR/verify.sh")" -eq 1 ]; then
  ok "57-F: verify.sh の ps が絞る形の定義（2 つ）を特定できた"
else
  bad "57-F: verify.sh の ps が絞る形の定義行を特定できない（定義を変えたら、この検査の許容する形も合わせる）"
fi
_c57_forms_n=0
_c57_forms_bad=""
while IFS= read -r _c57_line; do
  [ -n "$_c57_line" ] || continue
  _c57_forms_n=$((_c57_forms_n + 1))
  _c57_args="${_c57_line#*ps }"
  _c57_args="${_c57_args%% 2>*}"
  case "$_c57_args" in
    '-ww -eo pid=,ppid=,args=' | '-eo pid=,ppid=') ;;
    *) _c57_forms_bad="${_c57_forms_bad:+${_c57_forms_bad} / }${_c57_args}" ;;
  esac
done <<C57_FORMS
$(grep -hE '(^|[^[:alnum:]_])ps[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[eA][A-Za-z]*([[:space:]]|$)' "$RUNNER" "$TESTS_DIR/lib/gate-in-flight.sh" | grep -v '^[[:space:]]*#' || true)
C57_FORMS
if [ "$_c57_forms_n" -ge 4 ] && [ -z "$_c57_forms_bad" ]; then
  ok "57-F: ランナーと待機 lib が全プロセスを列挙する ${_c57_forms_n} 箇所は、すべて ps が絞る 2 つの形で起動している"
else
  bad "57-F: 全プロセスを列挙する起動が ps の絞る形から外れているか、列挙箇所を拾えない（拾えた ${_c57_forms_n} 箇所 / 外れた形: ${_c57_forms_bad:-なし}。4 箇所未満なら検査が空振りしている）"
fi
rm -rf "$_c57_fx"
# suite-cases-end: unit-isolation.sh
