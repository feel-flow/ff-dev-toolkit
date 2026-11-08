# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# case 16・18・19・22・26・27・29: 高速モードの除外と既定一覧
#
# verify.sh から source される（ok / bad / expect_* / run_runner / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2696`）。

echo "== case 16: 高速モードの除外境界（除外・skip との別勘定・名指しの警告） =="

# 前提の実測（case 16・19・22・26・27 が依存する）: 除外判定は「`-selftest` 終端 かつ 対になる
# 本体 suite が実在する」で導出される（ADR-031）ので、fixtures/pass の実在と fixtures/orphan の
# 不在が検査の分岐そのものを決める。片方でも崩れると、以下は緑のまま逆側の分岐を検査し始める。
if [ -f "$FIXTURES/pass/verify.sh" ]; then
  ok "前提: fixtures/pass が実在する（pass-selftest は「対を持つ selftest」= 除外側）"
else
  bad "前提が崩れている: fixtures/pass が無い（pass-selftest が除外されなくなる）"
fi
if [ -e "$FIXTURES/orphan" ]; then
  bad "前提が崩れている: fixtures/orphan がある（orphan-selftest が除外側へ移る）"
else
  ok "前提: fixtures/orphan は存在しない（orphan-selftest は「対を持たない selftest」= 実行側）"
fi

# 16-A: 高速モードの中心契約（Issue `#600` / `#602`）。suite 名（親ディレクトリ名）が `-selftest` で
# 終わり、かつ対になる本体 suite が実在する suite を実行対象から外し、残りはすべて実行する。除外は
# total にも skipped にも数えない —「意図的な除外」と「環境都合の skip」を混ぜると必須 skip 判定の
# 意味が壊れる。ADR-034 で明示引数の既定は「名指ししたものを走らせる」へ変わったが、
# FF_RUN_ALL_FAST=1 を**明示**したときだけは従来どおり除外が掛かる（この口を完全に適用外にすると
# case 19 の fail-closed 経路が検査不能になる）。残した口で「名指ししたのに走らない」を黙って
# 通さないことも同時に固定する（警告の不在側は case 27）。
RUN_FAST=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc 0 "高速モードで本体 suite が全 pass なら rc=0"
expect_has '^FIXTURE-PASS-EXECUTED$' "本体 suite は実行される"
expect_lacks 'FIXTURE-PASS-SELFTEST-EXECUTED' "-selftest suite は実行されない"
expect_lacks '^== pass-selftest ==' "-selftest suite の見出しも出ない（起動自体がされない）"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' "除外 suite は total にも skipped にも数えない（環境都合の skip と別勘定）"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "サマリーが除外件数を明示する"
expect_has 'これらが担う検査〔対の本体 suite に対するゲート検出力' "サマリーから何を検証していないかが読み取れる"
expect_has 'pass-selftest$' "サマリーが除外した suite 名を明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "高速モード（selftest 未実行）で全体 pass を名乗らない"
expect_has '^実行した 1 suite は全て通過（高速モード' "高速モード専用の完了文言を出す"
expect_has '^⚠️  明示引数で名指しした suite のうち 1 件を高速モードが除外しました' "明示引数で名指しした suite が除外されたら警告する"

# 16-B: 除外（検証しないと決めた）と skip（検証したかったが環境都合で出来なかった）を 1 回の実行の
# 中で同時に発生させ、別々の行で報告されることを実測する。
RUN_FAST=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc 0 "除外 + 環境都合 skip の併存でも rc=0（pass があるため）"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' "skipped に数えられるのは環境都合の skip だけ（除外は含まれない）"
expect_has '^○ skipped (環境都合で検証本体が未実行): skip$' "環境都合の skip は従来の行で名指しされる"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外は skip とは別の行で報告される"

# 16-C: 必須 skip 判定（REQUIRED_SKIPPED）は SKIPPED 配列だけから導出される（構造の固定）。上の
# 実測で「除外は SKIPPED に入らない」ことが示されているので、両者を合成すると「高速モードの意図的な
# 除外は、必須 suite の skip として赤にならない」が成立する。既定一覧との結合は case 26 が実測する。
expect_src 'for _s in "\$\{SKIPPED\[@\]\}"; do' "$TESTS_DIR/run-all.sh" \
  "必須 skip 判定が SKIPPED だけを走査する（高速モードの除外は判定対象外）" \
  "必須 skip 判定の走査元が SKIPPED でなくなった（除外との競合を要再確認）"
# 走査元の行が残っていても、REQUIRED_SKIPPED の導出ブロックへ FAST_EXCLUDED を合流させる第 2
# ループの**追加**は上の grep では検出できない。ブロックを抽出して否定側も固定する。
_req_derive_block="$(awk '
  /^REQUIRED_SKIPPED=\(\)/ { inside=1 }
  inside { print }
  inside && /^fi$/ { exit }
' "$TESTS_DIR/run-all.sh")"
if [ -z "$_req_derive_block" ]; then
  bad "REQUIRED_SKIPPED 導出ブロックを抽出できなかった（この否定検査は成立していない）"
elif [ "$(printf '%s\n' "$_req_derive_block" | grep -c 'FAST_EXCLUDED')" -eq 0 ]; then
  ok "必須 skip 判定の導出ブロックに FAST_EXCLUDED への言及が無い（除外の合流なし）"
else
  bad "必須 skip 判定の導出ブロックが FAST_EXCLUDED を参照している（除外が判定へ流入）"
fi

# 16-D: 高速モードでの除外は「対になる selftest を実行しない」だけであり、実行された本体 suite の
# 失敗は従来どおり終了コードへ効く（除外判定と失敗判定が同じ FAST_MODE 分岐へ合流していないこと）。
# 旧 case 17 の検出対象（高速モードで本体 suite が落ちても非 0 で終わる）をここへ引き継ぐ。
RUN_FAST=1 run_runner "$FIXTURES/fail/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc nz "高速モードでも本体 suite の失敗は非 0"
expect_has '^suites: total=1 run=1 passed=0 failed=1 skipped=0 not-run=0$' "失敗の集計が高速モードでも従来どおり"

echo ""
echo "== case 18: 明示引数は環境変数なしなら名指しした -selftest も実行する =="

# ADR-034 の分岐点。既定一覧は高速モードになったが、**明示引数は名指ししたものを走らせる**。ここが
# 除外側へ倒れると `bash run-all.sh tests/<名>-selftest/verify.sh` が名指ししたのに何も実行しない形に
# なる（既定反転で最も踏みやすい退行）。FF_RUN_ALL_FAST の値解釈（0 / 空 / 不正値）は既定一覧で
# しか分岐の生死が観測できないため case 26-C / 26-F が測る。
run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc 0 "明示引数（環境変数なし）の全 pass 実行が rc=0"
expect_has '^FIXTURE-PASS-SELFTEST-EXECUTED$' "明示引数では名指しした -selftest も実行される"
expect_has '^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$' "明示引数の集計に除外が無い"
expect_has '^checks-skipped: total=0 suites=0$' "部分skipが無い実行も0件を明示する（旧 case 3）"
expect_lacks '^⚡' "明示引数（環境変数なし）で高速モードの文言を出さない"
expect_has '^All ff-dev-toolkit fixture checks passed\.$' "明示引数（環境変数なし）の全 pass も全体 pass を名乗る（除外が掛かっていない実行だから）"

# 全件実行の明示指定（FF_RUN_ALL_FULL=1）でも同じであること。明示引数へ除外が掛からないのは
# 「環境変数なし」の帰結ではなく全件実行そのものの帰結だ、という側も縛る。
RUN_FULL=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/pass-selftest/verify.sh"
expect_has '^FIXTURE-PASS-SELFTEST-EXECUTED$' "FF_RUN_ALL_FULL=1 でも名指しした -selftest が実行される"
expect_lacks '^⚡' "FF_RUN_ALL_FULL=1 で高速モードの文言を出さない"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FULL=1 は正当な値なので警告しない"

echo ""
echo "== case 19: 高速モードの除外で実行対象が 0 件なら非 0 =="

# 検査 0 件を成功として記録しない（run-all の「pass 0 で skip のみは非 0」と同じ思想）。
RUN_FAST=1 run_runner "$FIXTURES/pass-selftest/verify.sh"

expect_rc nz "実行対象 0 件は非 0 で終わる"
expect_has '実行対象が 0 件になりました' "0 件になった理由を明示する"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "全体 pass を名乗らない"
# 名指しが全件除外された回は、この警告が最も要る場面である。0 件判定の exit 1 より前に出していないと
# 到達せず、API.md の無条件の契約（名指しが除外されたら stderr へ 1 行警告）が破れる。case 16-A は
# 本体 suite を併記した経路しか通らないので、この分岐はここでしか縛れない。
expect_has '^⚠️  明示引数で名指しした suite のうち 1 件を高速モードが除外しました' "名指しが全件除外された回も警告する（0 件判定の exit 1 より前に出る）"

echo ""
echo "== case 22: 除外は終端一致のみ（名前の途中の -selftest は除外しない） =="

# 判定 glob が *-selftest から *selftest* へ広がる変異を検出する。部分一致になると、名前に selftest を
# 含むだけの本体 suite まで意図せず除外される。
RUN_FAST=1 run_runner "$FIXTURES/pass-selftest-extra/verify.sh" "$FIXTURES/pass-selftest/verify.sh"

expect_rc 0 "終端一致の除外後も本体 suite の実行で rc=0"
expect_has '^FIXTURE-SELFTEST-MIDNAME-EXECUTED$' "-selftest を途中に含むだけの suite は高速モードでも実行される"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' "除外されるのは終端一致の 1 件だけ"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外件数が 1 件（終端一致のみ）"

echo ""
echo "== case 26: 既定一覧の統合動作とモード行列（複製木への引数なし実行） =="

# 既定一覧の実行は入れ子ガード（case 8）により本 suite からは直接回せない。case 13 の登録照合と
# 同じ流儀で run-all.sh を一時木へ複製し、実在の suite 名を写した stub 群に対して実行する（stub は
# 即終了するので数秒で完走する）。ここで初めて「登録照合 → 高速フィルタ → 実行 → 必須 skip 判定」の
# 全経路が既定一覧の形で結合される。**既定一覧でしか観測できないモード解決（ADR-034 の既定反転・
# FF_RUN_ALL_FULL・FF_RUN_ALL_FAST=0・矛盾指定・不正値）もここで実測する** — 明示引数の実行は
# モードに依らず名指しを走らせるため、そちらでは差が出ない。
_fast_fx="$RUN_WORK/ff-fast-integration"
rm -rf "$_fast_fx"
mkdir -p "$_fast_fx"
cp "$TESTS_DIR/run-all.sh" "$_fast_fx/run-all.sh"
# stub は即終了するが、**必須名簿の逆向き導出の材料だけは実体から写す** — run-all.sh は
# 「suite 全体の skip 経路の有無」と `run-all-required:` 宣言から必須集合を導出して名簿と
# 突き合わせるので、材料を落とすと複製木では必須集合が空になり、モード行列の観測より前に
# 登録照合が落ちる。
#
# 材料の判定は **run-all.sh 自身に出させる**（`FF_RUN_ALL_DUMP_DECLARATIONS=1` が
# `<名前>:<skip>:<yes>:<no>:<bad>:<probe>` を返す）。ここへ判定述語を書き写すと「述語を変えるときは
# 2 箇所同時」の結合が生まれ、片方だけ直すと複製木の導出集合がずれて case 26 が原因の
# 読めない赤になる（実測。導出述語は run-all.sh 側の単一定義に保つ）。
if _fast_decl_raw="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_DUMP_DECLARATIONS=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
  bash "$TESTS_DIR/run-all.sh" 2>&1)"; then _fast_decl_rc=0; else _fast_decl_rc=$?; fi
# case14bと同じく、負荷warningをstub名へ変換せず機械行だけを材料にする。
_fast_decl_valid="$(printf '%s\n' "$_fast_decl_raw" \
  | awk '/^[A-Za-z0-9._-]+:[01]:[01]:[01]:[01]:[01]$/')"
_fast_decl_n="$(printf '%s\n' "$_fast_decl_valid" \
  | awk '/^[A-Za-z0-9._-]+:[01]:[01]:[01]:[01]:[01]$/ { n++ } END { print n + 0 }')"
if [ "$_fast_decl_rc" -eq 0 ] && [ "$_fast_decl_n" -ge 1 ]; then
  ok "宣言ダンプが ${_fast_decl_n} 件の導出材料を返す（複製木は実装側の述語を使う）"
else
  bad "宣言ダンプ (FF_RUN_ALL_DUMP_DECLARATIONS=1) が材料を返さない (rc=${_fast_decl_rc})"
  printf '%s\n' "$_fast_decl_raw" | sed 's/^/    | /' >&2
fi
for _fast_entry in $_fast_decl_valid; do
  _fast_n="${_fast_entry%%:*}"
  _fast_flags="${_fast_entry#*:}"
  _fast_skip="${_fast_flags%%:*}"
  _fast_rest="${_fast_flags#*:}"
  _fast_yes="${_fast_rest%%:*}"
  _fast_rest="${_fast_rest#*:}"
  _fast_no="${_fast_rest%%:*}"
  _fast_rest="${_fast_rest#*:}"
  _fast_probe="${_fast_rest#*:}"
  mkdir -p "$_fast_fx/$_fast_n"
  # skip の材料は **実行されない分岐**（`if false; then ... fi`）として置く。出力文の形は
  # 保つ（導出はそこを見る）が実行しても何も出ないので、複製木の集計が skip 側へ倒れて
  # 26-A 以降の期待値を壊すことがない。
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$_fast_yes" = "1" ]; then
      printf '# run-all-required: yes — 複製木 stub（実体の宣言を写した導出材料）\n'
    fi
    if [ "$_fast_no" = "1" ]; then
      printf '# run-all-required: no — 複製木 stub（実体の宣言を写した導出材料）\n'
    fi
    if [ "$_fast_probe" = "1" ]; then
      printf '# 空振り検出: 複製木 stub（実体の宣言を写した導出材料）\n'
    fi
    if [ "$_fast_skip" = "1" ]; then
      printf 'if false; then echo "○ skip: 逆向き導出の材料（この stub は skip を出力しない）"; fi\n'
    fi
    printf 'exit 0\n'
  } > "$_fast_fx/$_fast_n/verify.sh"
  chmod +x "$_fast_fx/$_fast_n/verify.sh"
done
# 分類は複製木の**実体**から導出する（名簿を持たない = 実装と同じ導出規則）。コピーが終わってから
# 走査するのは、対の本体ディレクトリが未作成の時点で selftest を判定してしまうのを避けるため。
_fast_excl=0
_fast_orphan=0
_fast_body=0
_fast_excl_name=""
_fast_orphan_name=""
for _fast_dir in "$_fast_fx"/*/; do
  _fast_n="$(basename "$_fast_dir")"
  case "$_fast_n" in
    *-selftest)
      if [ -f "$_fast_fx/${_fast_n%-selftest}/verify.sh" ]; then
        _fast_excl=$((_fast_excl + 1))
        [ -n "$_fast_excl_name" ] || _fast_excl_name="$_fast_n"
      else
        _fast_orphan=$((_fast_orphan + 1))
        [ -n "$_fast_orphan_name" ] || _fast_orphan_name="$_fast_n"
      fi
      ;;
    *) _fast_body=$((_fast_body + 1)) ;;
  esac
done
_fast_run=$((_fast_body + _fast_orphan))
# 前提: 既定一覧に「対を持つ selftest」「対を持たない selftest」「本体」の 3 種が揃っている
# （どれかが 0 なら、この統合検査はその分岐を検査していない）。
if [ "$_fast_excl" -ge 1 ] && [ "$_fast_orphan" -ge 1 ] && [ "$_fast_body" -ge 1 ]; then
  ok "複製木に 対あり selftest ${_fast_excl} 件 / 対なし selftest ${_fast_orphan} 件 / 本体 ${_fast_body} 件が揃っている"
else
  bad "複製木の構成が前提を満たさない（対あり=${_fast_excl} 対なし=${_fast_orphan} 本体=${_fast_body}）"
fi

# 実体から導出した「全件実行時の suite 数」。「既定で走る分 + 除外分 = 全件」という、26-B 以降の
# アサートが依拠する関係そのものを式にする。
_fast_all=$((_fast_run + _fast_excl))

# 複製木を引数なしで実行する。入れ子ガードと ALLOW_SKIP は常に落とす（外側から漏れるとモード行列の
# 観測がその回だけ別物になる）。**モードは呼び出し側が env 引数で明示する。**
#
# 複製木は git リポジトリの外に在るので、dirty tree の起動ガードから見ると「汚れているか確認できない」
# = fail-closed で停止する対象になる。ここで測りたいのはモード解決であってガードではないので明示的に
# オプトアウトする（ガード自身の 4 ケースは case 39 が隔離した一時リポジトリで測る）。
# モード行列は逐次実行する。並列の集計・順序・上限は case 30 / 32 で全件確認する。
run_tree() {
  # 代入は "$@"（-u オプション列）の**後ろ**へ置く。env は最初の非オプション語より後を
  # コマンド引数として扱うため、代入を先頭に置くと以降の -u が env へ届かない。
  if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_ALLOW_SKIP "$@" FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=1 \
    bash "$_fast_fx/run-all.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}
# 「全件が走った」「既定（高速モード）ぶんだけ走った」のサマリー行は 26-B 以降で繰り返し使う。
expect_tree_all()  { expect_has "^suites: total=${_fast_all} run=${_fast_all} passed=${_fast_all} failed=0 skipped=0 not-run=0$" "$1"; }
expect_tree_fast() { expect_has "^suites: total=${_fast_run} run=${_fast_run} passed=${_fast_run} failed=0 skipped=0 not-run=0$" "$1"; }

# 26-A: 引数なし・環境変数なし = **新しい既定**（ADR-034）。登録照合を通過し、対を持つ selftest だけが
# 除外されて全 pass。ここが全件側へ倒れると既定反転そのものが消える。
run_tree -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL
expect_rc 0 "既定一覧の引数なし実行が rc=0"
expect_has "^⚡ 高速モードで selftest ${_fast_excl} 件を除外した" "引数なしの既定で「対を持つ selftest」が全件（実体と同数）除外される"
expect_has 'うち REQUIRED_SUITES 掲載 [1-9]' "除外のうち必須名簿掲載の件数が出る（既定では fail-closed 保護が及ばない重みを可視化する）"
expect_has '全件実行は FF_RUN_ALL_FULL=1' "不完全な実行であることと全件実行への導線がサマリーに出る"
expect_has "^⚡ ${KEPT_SELFTEST_HEAD} ${_fast_orphan} ${KEPT_SELFTEST_TAIL}" "既定一覧の「対を持たない selftest」は除外されずサマリーで名指しされる（ADR-031）"
# 明示引数の警告が既定一覧で鳴らないことを縛る。これが無いと run-all.sh 側の USING_DEFAULT_SCRIPTS
# ガードを消しても全ケースが緑のまま通り、既定一覧の高速モード実行が毎回「明示引数で名指しした…」と
# いう端的に虚偽の警告を出すようになる。
expect_lacks '^⚠️  明示引数' "既定一覧の実行では明示引数の警告を出さない（USING_DEFAULT_SCRIPTS ガードが効いている）"
expect_lacks '^🔎 全件実行' "既定（高速モード）では全件実行のマーカーを出さない"
expect_lacks "^== ${_fast_excl_name} ==" "対を持つ selftest（${_fast_excl_name}）の見出しは出ない"
expect_has "^== ${_fast_orphan_name} ==" "対を持たない selftest（${_fast_orphan_name}）は既定でも実行される"
expect_tree_fast "本体 + 対なし selftest がすべて実行される（実体からの導出値と一致）"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "既定（高速モード）は全体 pass を名乗らない"

# 26-B: 全件実行の明示指定（FF_RUN_ALL_FULL=1）— 登録されている suite が全部走る。「全件実行した」
# ことを ⚡ の**不在**でしか判別できないと、リリース前・公開同期前の全件実行（ADR-034 決定 2）の報告が
# 目視頼みになる。肯定的なマーカーの実在もここで縛る。
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1
expect_rc 0 "FF_RUN_ALL_FULL=1 の既定一覧実行が rc=0"
expect_has "^🔎 全件実行: 登録されている ${_fast_all} suite をすべて実行対象にします" "全件実行であることを肯定的に 1 行で出す（実体からの導出値と一致）"
expect_tree_all "FF_RUN_ALL_FULL=1 では登録されている suite が全件走る（実体からの導出値と一致）"
expect_has "^== ${_fast_excl_name} ==" "FF_RUN_ALL_FULL=1 では対を持つ selftest も実行される"
expect_lacks '^⚡' "FF_RUN_ALL_FULL=1 で高速モードの文言を出さない"
expect_has '^All ff-dev-toolkit fixture checks passed\.$' "全件実行の全 pass は従来の全体 pass を名乗る"

# 26-C: FF_RUN_ALL_FAST=0 は「明示的に高速モードでない」= 全件実行（ADR-034）。既定反転より前に
# `export FF_RUN_ALL_FAST=0` で全件実行を意図していた呼び出し側を、既定の変更で黙って高速モードへ
# 落とさない。ここが既定へ倒れると、対を持つ selftest ぶんの検出力が静かに消える。
run_tree -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=0
expect_rc 0 "FF_RUN_ALL_FAST=0 の既定一覧実行が rc=0"
expect_tree_all "FF_RUN_ALL_FAST=0 は全件実行（既定へ落とさない）"
expect_lacks '^⚡' "FF_RUN_ALL_FAST=0 で高速モードの文言を出さない"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FAST=0 は通常の off なので警告しない"

# 26-D: 矛盾する同時指定は黙って一方を採らず、fail-safe 側（全件実行）を採る。
run_tree FF_RUN_ALL_FULL=1 FF_RUN_ALL_FAST=1
expect_rc 0 "矛盾指定でも警告のみ（終了コードは変えない）"
expect_has '^⚠️  FF_RUN_ALL_FULL=1 と FF_RUN_ALL_FAST=1 が同時に指定されています' "矛盾する同時指定を 1 行警告する"
expect_tree_all "矛盾時は fail-safe 側（全件実行）を採る"

# 26-E: FF_RUN_ALL_FULL の値の解釈（`0` は通常の off で quiet、それ以外の非空値は警告 + fail-safe 側）。
# off 側を縛らないと、警告はいずれ無条件のノイズへ育つ。
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=0
expect_rc 0 "FF_RUN_ALL_FULL=0 の既定一覧実行が rc=0"
expect_tree_fast "FF_RUN_ALL_FULL=0 は通常の off（既定の高速モードのまま）"
expect_lacks '解釈できない値です' "FF_RUN_ALL_FULL=0 は通常の off なので警告しない"
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=true
expect_rc 0 "解釈できない FF_RUN_ALL_FULL 値は警告のみで実行は継続する"
expect_has 'FF_RUN_ALL_FULL="true" は解釈できない値です' "FF_RUN_ALL_FULL の解釈できない値は 1 行警告する"
expect_tree_all "解釈できない FF_RUN_ALL_FULL 値でも fail-safe 側（全件実行）で続行する"

# 26-F: FF_RUN_ALL_FAST の値の解釈を**既定一覧で**実測する。明示引数で回すと明示引数ルール
# （FAST_REQUESTED != 1 なら除外しない）が先に効いて同じ結果になり、「不正値を fail-safe 側へ倒す」
# 分岐を落とす変異が緑のまま通る（レビューで実測）。FULL 側（26-E）と対称にここへ置く。
for _tree_fast_v in "true" "2"; do
  run_tree -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST="$_tree_fast_v"
  expect_rc 0 "FF_RUN_ALL_FAST='${_tree_fast_v}' は警告のみで実行は継続する"
  expect_has "FF_RUN_ALL_FAST=\"${_tree_fast_v}\" は解釈できない値です" "既定一覧で FF_RUN_ALL_FAST='${_tree_fast_v}' を 1 行警告する"
  expect_tree_all "既定一覧で FF_RUN_ALL_FAST='${_tree_fast_v}' は fail-safe 側（全件実行）へ倒れる"
  expect_lacks '^⚡' "FF_RUN_ALL_FAST='${_tree_fast_v}' で高速モードにならない"
done

# 不正値経由で立った全件要求を矛盾警告が拾うと、利用者が書いていない `FULL=1` を事実として述べる
# 警告になる（レビュー指摘）。不正値の警告は出しつつ、矛盾警告は出さないことを縛る。
run_tree FF_RUN_ALL_FULL=true FF_RUN_ALL_FAST=1
expect_has 'FF_RUN_ALL_FULL="true" は解釈できない値です' "FULL が不正値 + FAST=1 でも不正値の警告は出る"
expect_lacks '^⚠️  FF_RUN_ALL_FULL=1 と FF_RUN_ALL_FAST=1 が同時に指定されています' \
  "FULL が不正値のときは矛盾警告を出さない（設定していない値を事実として述べない）"
expect_tree_all "FULL が不正値 + FAST=1 でも fail-safe 側（全件実行）"

# 26-G: 必須の本体 suite（markdownlint）が環境都合で skip → 既定（高速モード）でも赤。再現コマンドの
# 前置（既定は不要 / 全件実行では FF_RUN_ALL_FULL=1）もここで実測する — 案内をそのままコピペした
# 利用者が気づかずモードを落とす形を防ぐ。
printf '#!/usr/bin/env bash\necho "○ skip: stub（環境都合を模す）"\nexit 0\n' > "$_fast_fx/markdownlint/verify.sh"
run_tree -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL
expect_rc nz "既定（高速モード）でも必須の本体 suite の skip は非 0（fail-closed が生きている）"
expect_has '^✗ 環境都合で消してはいけない suite が skip しました: markdownlint$' "必須 skip の名指しに除外した selftest が混入しない"
expect_has '^    FF_RUN_ALL_ALLOW_SKIP="markdownlint" bash tests/run-all.sh$' "既定（高速モード）の再現コマンドに前置は要らない"
expect_lacks '^    FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP=' "既定の案内へ全件実行の前置を混ぜない（コピペで意図せず全件へ戻さない）"

# 26-H: 同じ木を全件実行で回す — selftest も走り、案内は全件実行を保つ形になる。既定との差を示す
# 見出しには**対を持つ** selftest（26-A で除外された側）を使う。
run_tree -u FF_RUN_ALL_FAST FF_RUN_ALL_FULL=1
expect_rc nz "全件実行の必須 skip fail-closed は従来どおり非 0"
expect_has "^== ${_fast_excl_name} ==" "全件実行では対を持つ selftest も実行される"
expect_has '^    FF_RUN_ALL_FULL=1 FF_RUN_ALL_ALLOW_SKIP="markdownlint" bash tests/run-all.sh$' "全件実行中の再現コマンドに FF_RUN_ALL_FULL=1 が前置される"
rm -rf "$_fast_fx"

echo ""
echo "== case 27: 対になる本体 suite を持たない -selftest は高速モードでも実行される =="

# 除外境界の本体（Issue `#602` / ADR-031）。命名規約だけで除外すると、live な検査を単独で担う selftest
# （release-required-selftest 等）まで消え、その検査対象を触った変更が無検査で通る。判定へ「対の実在」を
# 足したことを疑似 suite で両側から実測する。前提は case 16 でアサート済み。
RUN_FAST=1 run_runner \
  "$FIXTURES/pass/verify.sh" \
  "$FIXTURES/pass-selftest/verify.sh" \
  "$FIXTURES/orphan-selftest/verify.sh"

expect_rc 0 "対あり除外 + 対なし実行の混在で rc=0"
expect_has '^FIXTURE-ORPHAN-SELFTEST-EXECUTED$' "対になる本体 suite が無い -selftest は高速モードでも実行される"
expect_lacks 'FIXTURE-PASS-SELFTEST-EXECUTED' "対になる本体 suite がある -selftest は除外される"
expect_has '^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$' "対なし selftest は実行対象に数えられる（本体 1 + 対なし selftest 1）"
expect_has '^⚡ 高速モードで selftest 1 件を除外した' "除外は対を持つ 1 件だけ"
expect_has "^⚡ ${KEPT_SELFTEST_HEAD} 1 ${KEPT_SELFTEST_TAIL}" "除外しなかった selftest の件数と理由がサマリーに出る"
expect_has 'orphan-selftest$' "除外しなかった selftest 名が名指しされる"

# 対なし selftest だけを高速モードで渡す = 除外 0 件。実行対象 0 件（case 19）とは別の経路なので、
# こちらは通常どおり完走することを確かめる。除外 0 件の分岐（サマリーの else 側）と、明示引数の
# 警告の**不在**側もこの実行で同時に固定する。
RUN_FAST=1 run_runner "$FIXTURES/orphan-selftest/verify.sh"
expect_rc 0 "対なし selftest 単独の高速モード実行は rc=0（0 件実行にならない）"
expect_has '^FIXTURE-ORPHAN-SELFTEST-EXECUTED$' "対なし selftest が単独でも実行される"
expect_lacks '実行対象が 0 件になりました' "対なし selftest は 0 件実行の経路へ落ちない"
expect_has '^⚡ 高速モード: 除外対象の selftest は 0 件だった' "除外 0 件がサマリーへ明示される"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "除外 0 件でも高速モードは全体 pass を名乗らない"
expect_lacks '^⚠️  明示引数で名指しした suite' "名指しした suite が 1 件も除外されなければ警告しない"

echo ""
echo "== case 29: 走行中にランナー自身が書き換えられた実行は緑を名乗らない =="

# bash はスクリプトを一括で読まず**実行しながら読み進める**ため、走行中の書き換えは実行そのものを
# 壊す。実測（Issue `#885`）ではサマリー行を一切出さないまま exit 0 で終わり、破棄された実行が
# 「静かに終わった緑」として観測された。
#
# ここで測るのは **最終行まで到達できた回の保険**（run-all.sh の自己指紋照合）。照合は
# `ff_emit_summary_head` の中でサマリー行の出力と同居しており、bash が関数定義を読み込み時に本体ごと
# パースする性質から「サマリー行が出た ⟹ 照合を通った」が構造的に成り立つ。その同居は下の静的な針でも
# 固定する。疑似 suite が複製ランナーの**末尾へ追記**するので既存バイトのオフセットは動かず、実行は
# 壊れずに最後まで到達する = 検査の対象そのものを決定論的に作れる。
# 書き換えるのは複製だけで、実作業ツリーの run-all.sh には触れない。
_selfmut_fx="$RUN_WORK/ff-run-all-selfmut"
rm -rf "$_selfmut_fx"
mkdir -p "$_selfmut_fx/selfmut-mutator" "$_selfmut_fx/selfmut-quiet" "$_selfmut_fx/selfmut-samesize"
cp "$RUNNER" "$_selfmut_fx/run-all.sh"
# 疑似 suite は printf で組む（heredoc / here-string は一時ファイルを要求する。ACE-86-2）。
# samesize は同一バイト数のまま内容だけを変える（cksum 経路の針）。書き換えを一時ファイル + mv で
# 行うのは、走行中の bash が元の inode を読み続けて実行は壊れず、指紋照合は**パス**を読み直して
# 新しい内容を見るため = 検出器だけを決定論的に測れる。
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "\n# mutated mid-run\n" >> "$FF_SELFMUT_TARGET"' \
  'echo FIXTURE-SELFMUT-EXECUTED' > "$_selfmut_fx/selfmut-mutator/verify.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'echo FIXTURE-SELFMUT-QUIET-EXECUTED' > "$_selfmut_fx/selfmut-quiet/verify.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'LC_ALL=C sed "s/selfmut-pad-AAAA/selfmut-pad-BBBB/" "$FF_SELFMUT_TARGET" > "$FF_SELFMUT_TARGET.new"' \
  'mv "$FF_SELFMUT_TARGET.new" "$FF_SELFMUT_TARGET"' \
  'echo FIXTURE-SELFMUT-SAMESIZE-EXECUTED' > "$_selfmut_fx/selfmut-samesize/verify.sh"
chmod +x "$_selfmut_fx/selfmut-mutator/verify.sh" "$_selfmut_fx/selfmut-quiet/verify.sh" \
  "$_selfmut_fx/selfmut-samesize/verify.sh"
# パッド行は複製ランナーの末尾（コメント）に置く。起動時の指紋に含まれるので、同一バイト数の置換が
# 「内容の変化」として観測できる。
printf '# selfmut-pad-AAAA\n' >> "$_selfmut_fx/run-all.sh"

_selfmut_run() { # <疑似 suite path...>
  if RUN_OUT="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_NESTED \
      FF_SELFMUT_TARGET="$_selfmut_fx/run-all.sh" \
      FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
      bash "$_selfmut_fx/run-all.sh" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}

# 陰性対照を先に測る。複製ランナー自体が別の理由（記録器の不在など）で非 0 になるなら、下の赤は
# 「書き換えを検出したから」ではなくなる。
_selfmut_run "$_selfmut_fx/selfmut-quiet/verify.sh"
expect_rc 0 "書き換えなしの複製ランナーは従来どおり rc=0"
expect_has '^suites: total=1 run=1 passed=1 failed=0 skipped=0 not-run=0$' "書き換えなしの実行は従来どおりサマリーを出す"
expect_lacks '実行中にランナー自身が書き換えられました' "書き換えなしの実行は何も報告しない"
# 複製木には ../scripts/record-gate-head.sh が無いので、記録呼び出しへ到達した実行だけがこの警告を
# 出す。下の「書き換え回は記録へ到達しない」を**空振りさせない**ための前提。
expect_has '⚠️  記録器が見つかりません' "書き換えなしの実行はゲート記録の呼び出しまで到達する"

_selfmut_run "$_selfmut_fx/selfmut-mutator/verify.sh"
expect_rc nz "走行中に書き換えられた実行は非 0 で終わる"
expect_has '^FIXTURE-SELFMUT-EXECUTED$' "疑似 suite が実際に走った（書き換えの起きた回を測っている）"
expect_has '^✗ 実行中にランナー自身が書き換えられました' "書き換えをランナー名指しで報告する"
expect_has 'この実行の結果は証拠に使えません' "結果を証拠に使えない旨を報告する"
expect_lacks '^suites: total=' "サマリー行を出さない（ログ末尾だけを見る読み手に緑と誤読させない）"
expect_lacks 'All ff-dev-toolkit fixture checks passed' "全体 pass を名乗らない"
# 無効な実行がゲート実測記録を更新しないこと。異常終了だけ検出できても、記録が上書きされると鮮度照合が
# 「この実行」を根拠にしうる。到達の有無は陰性対照が出した記録器不在の警告の**不在**で測る。
expect_lacks '記録器が見つかりません' "書き換えを検出した実行はゲート記録の呼び出しへ到達しない"

# 同一バイト数のまま内容だけが変わる書き換え。指紋がバイト数だけへ退行しても末尾追記のケースは
# 通ってしまうので、内容差分を見ていることを別に測る。
if command -v cksum >/dev/null 2>&1; then
  _selfmut_run "$_selfmut_fx/selfmut-samesize/verify.sh"
  expect_rc nz "同一バイト数のまま内容だけ変わった書き換えも非 0 で落ちる（指紋が内容を見ている）"
else
  ok "cksum 不在のため同一バイト数の検出は対象外（指紋はバイト数のみへ縮退する仕様）"
fi

rm -rf "$_selfmut_fx"

# 構造の針: 照合とサマリー行の出力が同一関数に同居していること。上の実行検査は「照合が効いている」
# ことしか測れず、照合をサマリーの外の 1 行へ戻す変更を素通しする。一時ファイルを作らずマーカー範囲を
# awk の状態で切る（本 suite の read-only 制約）。
if LC_ALL=C awk '
  /^# >>> ff-summary-head-block/ { grab = 1 }
  /^# <<< ff-summary-head-block/ { grab = 0 }
  grab && /^ff_emit_summary_head\(\) \{$/ { infn = 1; next }
  grab && infn && /^\}$/ { infn = 0 }
  grab && infn && /実行中にランナー自身が書き換えられました/ { seen_check = 1 }
  grab && infn && /echo "suites: total=/ { seen_summary = 1 }
  END { exit (seen_check && seen_summary) ? 0 : 1 }
' "$RUNNER"; then
  ok "指紋照合とサマリー行の出力が同一関数に同居している（サマリー行 ⟹ 照合済み）"
else
  bad "ff-summary-head-block に照合とサマリー行が揃っていません（照合が位置依存へ戻っています）"
fi
# 関数の外にサマリー行の複製が無いこと。複製があると上の同居が迂回される。
if [ "$(LC_ALL=C grep -c 'echo "suites: total=' "$RUNNER")" -eq 1 ]; then
  ok "サマリー行の出力箇所は 1 つだけ（関数の外に複製がない）"
else
  bad "サマリー行の出力が複数箇所にあります（関数外の複製から偽の緑が出ます）"
fi


# suite-cases-end: fast-mode.sh
