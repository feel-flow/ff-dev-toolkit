# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# case 30・32・34・36: 並列実行と一時領域の検査
#
# verify.sh から source される（ok / bad / expect_* / run_runner / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2696`）。

echo ""
echo "== case 30: 並列実行が逐次と同じ結果・同じ並びを出し、suite 単位でまとまる =="
# 並列化で変わってよいのは所要時間だけで、実行対象・集計・出力の並びは変わらない（Issue `#595`）。
# 混在 fixture（fail / pass / skip / not-executable / missing）を同じ一覧で 2 回走らせ、逐次と並列の
# 出力を丸ごと突き合わせる。個別のアサートを並べる代わりに全文比較にするのは、**後から suite の
# 種別が増えても書き忘れが差分として出る**ため。比較では並列告知・計測行・起動時負荷診断・空行を除く。
_norm_run_out() { printf '%s\n' "$1" | grep -v '^🧵 ' | grep -v '^elapsed-sec:' | grep -v '^slowest:' | grep -v '^⚠️  起動時の負荷:' | grep -v '^startup-load:' | grep -vxF '⚠️  負荷の高い状態または別ゲートの並走中に開始しました。赤の suite は単体で再実行して切り分けてください。' | grep -v '^[[:space:]]*$' || true; }

# Host load and independently running gates can change between the two runs.
# Keep unrelated warnings and all suite/summary bytes in the comparison.
_par_norm_expected="$(printf '%s\n' 'FIXTURE-NORMALIZER-OUTPUT' '⚠️  unrelated warning must remain' 'suites: total=1 run=1 passed=0 failed=1 skipped=0 not-run=0')"
_par_norm_diagnostic="$(printf '%s\n' '⚠️  起動時の負荷: synthetic observation' 'startup-load: load=1 cores=1 threshold=10 other-gates=synthetic' '⚠️  負荷の高い状態または別ゲートの並走中に開始しました。赤の suite は単体で再実行して切り分けてください。' "$_par_norm_expected")"
if [ -n "$_par_norm_expected" ] && [ "$(_norm_run_out "$_par_norm_diagnostic")" = "$_par_norm_expected" ]; then
  ok "case 30: 負荷診断3形だけを除き、別の警告・suite出力・集計を保持する"
else
  bad "case 30: 負荷診断の正規化が空振り、または他の警告・suite出力・集計を落としている"
fi

RUN_JOBS=1 run_runner "${MIXED_FIXTURES[@]}"
_par_seq_rc="$RUN_RC"
_par_seq_out="$(_norm_run_out "$RUN_OUT")"

RUN_JOBS=4 run_runner "${MIXED_FIXTURES[@]}"
_par_par_rc="$RUN_RC"
_par_par_out="$(_norm_run_out "$RUN_OUT")"

# 並列で走ったことの確証。これが無いと「両方とも逐次だったので一致した」でも緑になる。
# 集計・skip 名指し・失敗名指し・後続実行の個別アサートは置かない — 逐次側は case 1 が同じ一覧
# （MIXED_FIXTURES）で固定しており、下の全文一致と合成すれば並列側でも成立する。
expect_has '^🧵 並列実行: 同時実行数 4' "FF_RUN_ALL_JOBS=4 が並列実行を選ぶ（比較が並列側を測っている）"
expect_rc 1 "並列実行でも失敗・未実行があれば終了コードが 1"

if [ "$_par_seq_rc" -eq "$_par_par_rc" ]; then
  ok "終了コードが逐次実行と一致する（rc=${_par_par_rc}）"
else
  bad "終了コードが逐次実行と食い違う（逐次=${_par_seq_rc} 並列=${_par_par_rc}）"
fi

if [ "$_par_seq_out" = "$_par_par_out" ]; then
  ok "出力（告知・計測・負荷診断・空行を除く全文）が逐次実行と一致する — 集計も suite の並びも変わらない"
else
  bad "並列実行の出力が逐次実行と一致しない"
  printf '%s\n' "-- 逐次:" >&2
  printf '%s\n' "$_par_seq_out" | sed 's/^/    | /' >&2
  printf '%s\n' "-- 並列:" >&2
  printf '%s\n' "$_par_par_out" | sed 's/^/    | /' >&2
fi

# 4 本の slow fixture は 2 秒かけて HEAD / TAIL の 2 行を出す。完了順にストリームする実装だと HEAD が
# 並んでから TAIL が並ぶ形になり、HEAD と TAIL の隣接が崩れる。**同時実行数（2）より多い 4 本を
# 渡す**のは、空いたスロットへ後続を投入する経路を通すため — 本数を同時実行数以下にすると再充填が
# 一度も起きず、「3 本目以降が起動されない / 無限ループする」退行を丸ごと見逃す。
#
# 並列で走ったことは所要時間の比較ではなく、fixture が probe ログへ追記する開始 / 終了行から数えた
# **最大同時実行数**で確かめる（Issue `#2062`）。所要時間の比較は、全件ゲートの 12 並列の中では並列側も
# CPU を取れずに逐次へ近づき、さらに壁時計の巻き戻し（WSL2 の時刻同期）で逐次側が実際より短く出て
# 「並列 3s / 逐次 3s」の偽赤を出した。rendezvous（fixture の冒頭説明）で 2 本目の開始を 1 本目の
# 終了前に揃えるので、正しい並列実行の最大同時実行数は負荷によらず 2、逐次化した退行では 1 になる。
_par_probe_stats() { # <log> -> stdout "<開始行数> <終了行数> <最大同時実行数>"。読めなければ非 0
  awk '
    $1 == "S" { s++; cur++; if (cur > max) max = cur }
    $1 == "E" { e++; cur-- }
    END { printf "%d %d %d\n", s, e, max }
  ' "$1"
}
_par_probe_dir=""
if _par_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/run-all-probe.XXXXXX" 2>&1)" \
  && [ -d "$_par_probe_dir" ]; then
  : >"$_par_probe_dir/parallel.log"
  : >"$_par_probe_dir/sequential.log"
else
  bad "case 30: probe ログの一時領域を作成できず、同時実行数を実測できません: ${_par_probe_dir}"
  _par_probe_dir=""
fi

export FF_RUN_ALL_PROBE_LOG="${_par_probe_dir:+$_par_probe_dir/parallel.log}"
export FF_RUN_ALL_PROBE_RENDEZVOUS=1
RUN_JOBS=2 run_runner \
  "$FIXTURES/slow-a/verify.sh" "$FIXTURES/slow-b/verify.sh" \
  "$FIXTURES/slow-c/verify.sh" "$FIXTURES/slow-d/verify.sh"
unset FF_RUN_ALL_PROBE_LOG FF_RUN_ALL_PROBE_RENDEZVOUS
_par_slow_out="$RUN_OUT"

expect_rc 0 "並列実行で 4 本すべてが pass なら rc=0"
expect_has '^suites: total=4 run=4 passed=4 failed=0 skipped=0 not-run=0$' \
  "同時実行数より多い suite を渡しても全件が実行され、集計に漏れがない（スロット再充填）"

# 1 つの suite の出力が他 suite の出力と行単位で混ざらない
_par_grouped=1
for _par_tag in A B C D; do
  case "$_par_slow_out" in
    *"SLOW-${_par_tag}-HEAD"$'\n'"SLOW-${_par_tag}-TAIL"*) : ;;
    *) _par_grouped=0 ;;
  esac
done
if [ "$_par_grouped" -eq 1 ]; then
  ok "各 suite の 2 行が隣接して出る（他 suite の出力が行間に割り込まない）"
else
  bad "並列実行で suite の出力が行単位で混ざった"
  printf '%s\n' "$_par_slow_out" | sed 's/^/    | /' >&2
fi

# 見出しは完了順ではなく登録順
_par_order="$(printf '%s\n' "$_par_slow_out" | grep '^== ' || true)"
if [ "$_par_order" = "== slow-a ==
== slow-b ==
== slow-c ==
== slow-d ==
== summary ==" ]; then
  ok "suite の見出しが完了順ではなく登録順に並ぶ（逐次実行と同じ並び）"
else
  bad "並列実行の見出しの並びが登録順でない"
  printf '%s\n' "$_par_order" | sed 's/^/    | /' >&2
fi

# 逐次側は probe の数え方そのものの対照（重なりの無い実行を 1 と数える）。rendezvous を付けると
# 1 本目が上限まで待つので付けない。2 本で足りる（4 本にしても同時実行数は変わらず 4 秒延びるだけ）。
if [ -n "$_par_probe_dir" ]; then
  export FF_RUN_ALL_PROBE_LOG="$_par_probe_dir/sequential.log"
  RUN_JOBS=1 run_runner "$FIXTURES/slow-a/verify.sh" "$FIXTURES/slow-b/verify.sh"
  unset FF_RUN_ALL_PROBE_LOG

  # ログが無い・読めない・開始 / 終了が本数に揃わない回は、針が当たっていないので赤（緑へ倒さない）。
  if _par_probe_par="$(_par_probe_stats "$_par_probe_dir/parallel.log" 2>&1)" \
    && [ "$_par_probe_par" = "4 4 2" ]; then
    ok "並列実行（同時実行数 2）で suite が実際に上限の 2 本まで同時に走り、3 本以上は重ならない（開始 / 終了 / 最大同時 = ${_par_probe_par}）"
  else
    bad "並列実行の最大同時実行数が 2 ではない、または probe ログが揃わない（開始 / 終了 / 最大同時 = ${_par_probe_par:-空}。期待 4 4 2）"
    sed 's/^/    | /' "$_par_probe_dir/parallel.log" >&2 2>/dev/null || true
  fi
  if _par_probe_seq="$(_par_probe_stats "$_par_probe_dir/sequential.log" 2>&1)" \
    && [ "$_par_probe_seq" = "2 2 1" ]; then
    ok "逐次実行の 2 本は重ならない（開始 / 終了 / 最大同時 = ${_par_probe_seq}）"
  else
    bad "逐次実行の最大同時実行数が 1 ではない、または probe ログが揃わない（開始 / 終了 / 最大同時 = ${_par_probe_seq:-空}。期待 2 2 1）"
    sed 's/^/    | /' "$_par_probe_dir/sequential.log" >&2 2>/dev/null || true
  fi
  rm -rf "$_par_probe_dir"
fi

echo ""
echo "== case 32: FF_RUN_ALL_JOBS の解決（逐次への復帰・不正値・未指定の既定） =="
RUN_JOBS=1 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_lacks '^🧵 並列実行' "FF_RUN_ALL_JOBS=1 は逐次実行へ戻る（並列の告知を出さない）"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' "逐次実行への復帰でも集計は変わらない"

# 解釈できない値は「黙って既定へ倒す」のではなく 1 行警告してから続行する（fail-safe 側）。実行を
# 止めないのは、同時実行数の指定ミスで検証そのものが失われるのを避けるため。
RUN_JOBS=zero run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_rc 0 "解釈できない FF_RUN_ALL_JOBS は実行を失敗させない"
expect_has '^⚠️  FF_RUN_ALL_JOBS を解釈できません' "解釈できない FF_RUN_ALL_JOBS を 1 行で警告する"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' "解釈できない値でも実行は続行し、集計は変わらない"

# run_runner はケース間の再現性のため既定で FF_RUN_ALL_JOBS=1 を注入する。したがって「未指定のとき
# 何が選ばれるか」（CPU 数由来・上限 5・入れ子なら逐次）は素の環境で測る。
_par_run_default() { # <env への追加指定...>（-u NAME でも NAME=VALUE でもよい）
  if _par_dflt_out="$(env -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_JOBS "$@" \
    FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$RUNNER" \
    "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh" 2>&1)"; then
    _par_dflt_rc=0
  else
    _par_dflt_rc=$?
  fi
}

_par_run_default -u FF_RUN_ALL_NESTED
if [ "$_par_dflt_rc" -eq 0 ]; then
  ok "FF_RUN_ALL_JOBS 未指定の実行が rc=0"
else
  bad "FF_RUN_ALL_JOBS 未指定の実行が非 0（rc=${_par_dflt_rc}）"
  printf '%s\n' "$_par_dflt_out" | sed 's/^/    | /' >&2
fi

# 上限 5 は「1 桁かつ 5 以下」で縛る。16 コア機なら `同時実行数 16` になって落ちるので、上限を外す
# 退行はここで赤くなる。論理 CPU が 1 の環境では並列にならないので、その回は告知が出ないことを
# 主張する（機械の性質で分岐するが、どちらも「既定の解決結果」を測る）。
_par_ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$_par_ncpu" in
  ''|*[!0-9]*) _par_ncpu=1 ;;
esac
if [ "$_par_ncpu" -gt 1 ]; then
  if [ "$(printf '%s\n' "$_par_dflt_out" | grep -c '^🧵 並列実行: 同時実行数 [1-5]（')" -gt 0 ]; then
    ok "未指定の既定は 1〜5 の同時実行数へ解決される（上限 5 が効いている。論理 CPU=${_par_ncpu}）"
  else
    bad "未指定の既定が 1〜5 の同時実行数にならない（論理 CPU=${_par_ncpu}）"
    printf '%s\n' "$_par_dflt_out" | grep '^🧵' | sed 's/^/    | /' >&2
  fi
else
  if [ "$(printf '%s\n' "$_par_dflt_out" | grep -c '^🧵 並列実行')" -eq 0 ]; then
    ok "論理 CPU が 1 の環境では既定でも並列にしない（告知を出さない）"
  else
    bad "論理 CPU が 1 なのに並列実行の告知が出た"
  fi
fi

# 入れ子（外側の run-all.sh から suite として呼ばれた回）は明示指定が無い限り逐次。外側と内側で
# 同時実行数が掛け算になるのを避ける規定（ヘッダー）。
_par_run_default FF_RUN_ALL_NESTED=1
if [ "$(printf '%s\n' "$_par_dflt_out" | grep -c '^🧵 並列実行')" -eq 0 ]; then
  ok "入れ子の実行は FF_RUN_ALL_JOBS 未指定なら逐次で走る"
else
  bad "入れ子の実行が既定で並列になった（外側と同時実行数が掛け算になる）"
  printf '%s\n' "$_par_dflt_out" | grep '^🧵' | sed 's/^/    | /' >&2
fi

# 上限を超える指定は「黙って逐次へ化ける」のではなく警告して既定へ倒す。桁数を見ずに算術比較へ
# 渡すと、64bit を折り返した値が `-gt 1` を偽にして無警告で逐次になる。
RUN_JOBS=9223372036854775808 run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_has '^⚠️  FF_RUN_ALL_JOBS が上限 [0-9]* を超えています' "上限を超える FF_RUN_ALL_JOBS を 1 行で警告する（無警告で逐次へ化けない）"
expect_has '^suites: total=2 run=2 passed=1 failed=0 skipped=1 not-run=0$' "上限超過でも実行は続行し、集計は変わらない"

echo ""
echo "== case 34: rc を残さず子が消えた suite は未実行として数える =="
# 並列経路の gone 判定（pass にも fail にも倒さず「未実行」へ数える）を実測する。fixture は自分の
# 親＝並列ラッパーの subshell を SIGKILL するので、rc が置かれない。
export FF_FIXTURE_KILL_PARENT=1
RUN_JOBS=2 run_runner \
  "$FIXTURES/pass/verify.sh" "$FIXTURES/kill-wrapper/verify.sh" "$FIXTURES/skip/verify.sh"
unset FF_FIXTURE_KILL_PARENT

expect_rc 1 "未実行が 1 件でもあれば終了コードが 1"
expect_has '^✗ suite プロセスが終了コードを残さずに消えました' "rc を残さず消えた suite を名指しで報告する"
expect_has 'kill-wrapper (process gone)' "未実行の一覧で名指しされる"
expect_has '^suites: total=3 run=2 passed=1 failed=0 skipped=1 not-run=1$' "消えた suite は passed でも failed でもなく not-run に数えられる"
expect_has '^== skip ==$' "子が消えても後続 suite の実行は止まらない"

echo ""
echo "== case 36: テンプレート付き mktemp -d が成功経路で実体を検査しない形の再混入ガード =="

# stdout と stderr を同じ変数へ合流させる形は、mktemp が rc=0 で成功しつつ stderr へ警告を出す
# 環境で変数が「警告文 + 改行 + パス」になる。以後の処理は存在しないパスを掴んで落ちるので、
# 読み手には「一時領域を用意できなかった」ではなく無関係な失敗に見える（実測）。case 15 は
# (a) 失敗理由を捨てる形 と (b) probe のテンプレート明示 しか見ないため、この形は誰も赤にしない。
#
# 判定は 1 行 grep では足りない — 代入の次行以降で実体を見る多行形や、rc を別変数へ退避してから
# 判定する形も「検査済み」に含まれる。同一行に加えて、代入直後 8 行以内の同変数 -d 検査も
# 検査済みと数える。走査対象は tests 直下の verify.sh・cases/*.sh とリポジトリ直下の scripts/*.sh
# （後者には materialize-dev-toolkit-changelog.sh の同型が含まれる）。
_mkchk_repo_root="$(cd "$TESTS_DIR/../../.." && pwd -P)"

# リポジトリ直下の scripts/ は SSOT にしか無い（同期対象の正本
# scripts/sync-dev-toolkit-to-public.sh の PUBLIC_TARGETS は plugins/ff-dev-toolkit と
# oss/ff-dev-toolkit の 2 つだけ）。glob をそのまま渡すと、配布先 checkout では展開されず
# リテラル `…/scripts/*.sh` が awk へ渡り fatal で suite ごと abort する
# （Issue `#1695`。2026-09-16 に公開 CI で実測）。
#
# 配置の判別は review-freeze-contract と同じ独立 2 標識の論理積で行い、**食い違いは赤にする**。
# 単一の存在確認で分岐すると、SSOT 側で scripts/ が改名・移動された回に黙って「配布先扱い」へ
# 落ち、materialize-dev-toolkit-changelog.sh の同型を走査しないまま緑になる（fail-open）。
#   標識 1: root に oss/ff-dev-toolkit がある。oss/ 配下は公開同期時に staging root へ展開
#           される（同期スクリプトの `oss/*` 分岐が tar --strip-components を付ける）ため、
#           配布先にこの path は残らない。
#   標識 2: plugins/ に ff-dev-toolkit 以外の**プラグイン実体**（.claude-plugin/plugin.json を
#           持つディレクトリ）がある。配布物は単体収録で、マーケットプレイス型モノレポだけが
#           複数を収録する。素のディレクトリ名で数えると、ツール生成物やスクラッチ
#           ディレクトリが 1 つ増えただけで「改名・移動された可能性」という的外れな
#           診断で赤くなる（レビュー実測）。
#
# **両標識が 0 でも配布先と断定しない。** XOR だけを赤にすると、SSOT 側で oss/ が改名され、かつ
# 収録プラグインが単体になった状態が「標識 0/0 = 配布先」へ黙って落ちる。そこで root scripts/ の
# 実在を配布先方向の反証に使い、配布先の標識なのに scripts/ が在る回も赤にする。
#
# 判定を関数へ切り出しているのは、下の「配置判定の回帰ケース」で合成ツリーに対する判定を
# 固定するため。インラインのままだと、ここで足した分岐を自動で踏む手段が無い（Codex 指摘）。
#   ssot              = SSOT 配置（root scripts/ も走査する）
#   dist              = 配布先 checkout（tests 側だけ走査する）
#   mismatch          = 標識が食い違う
#   ssot-no-scripts   = SSOT 配置なのに scripts/ が無い
#   dist-with-scripts = 配布先の標識なのに root scripts/ が在る
_mkchk_layout() {
  local _root="$1" _mark_oss=0 _mark_sibling=0 _d
  if [ -d "$_root/oss/ff-dev-toolkit" ]; then _mark_oss=1; fi
  for _d in "$_root"/plugins/*/; do
    [ -f "${_d}.claude-plugin/plugin.json" ] || continue
    [ "$(basename "$_d")" = "ff-dev-toolkit" ] && continue
    _mark_sibling=1
    break
  done
  if [ "$_mark_oss" -ne "$_mark_sibling" ]; then
    printf 'mismatch\n'
  elif [ "$_mark_oss" -eq 1 ]; then
    if [ -d "$_root/scripts" ]; then printf 'ssot\n'; else printf 'ssot-no-scripts\n'; fi
  else
    if [ -d "$_root/scripts" ]; then printf 'dist-with-scripts\n'; else printf 'dist\n'; fi
  fi
}

_mkchk_verdict="$(_mkchk_layout "$_mkchk_repo_root")"
_mkchk_root_scripts=""
case "$_mkchk_verdict" in
  ssot) _mkchk_root_scripts=1 ;;
  dist) ;;
  mismatch)
    bad "case 36: 配置の判別が食い違います（oss/ff-dev-toolkit と plugins/ の収録数が別の配置を示す）— どちらかの標識が改名・移動されたか、plugins/ 直下に想定外のプラグインが増えた可能性。配布先扱いへ倒さず赤にする" ;;
  ssot-no-scripts)
    bad "case 36: ソースリポジトリの配置なのに scripts/ がありません（改名・移動なら本 suite の走査対象も直すこと）" ;;
  dist-with-scripts)
    bad "case 36: 配布先の標識なのに root に scripts/ が在ります（標識側が改名・移動された可能性。走査対象を黙って落とさない）" ;;
  *)
    bad "case 36: 配置の判定結果を解釈できません（${_mkchk_verdict:-空}）" ;;
esac

# 走査本体。引数のファイルを読み、未検査を「UNCHECKED <path>:<行>」、総数を「TOTAL <n>」で出す。
_mkchk_scan() {
  awk '
    function report(  i, j, line, var, checked) {
      for (i = 1; i <= n; i++) {
        line = L[i]
        if (line ~ /^[[:space:]]*#/) continue
        if (line !~ /mktemp -d "/) continue
        if (line !~ /2>&1/) continue
        total++
        if (line ~ /\[[[:space:]]*!?[[:space:]]*-d[[:space:]]/) continue
        var = ""
        if (match(line, /[A-Za-z_][A-Za-z_0-9]*="\$\(mktemp -d/)) {
          var = substr(line, RSTART, RLENGTH)
          sub(/="\$\(mktemp -d$/, "", var)
        }
        checked = 0
        if (var != "") {
          for (j = i + 1; j <= i + 8 && j <= n; j++) {
            if (index(L[j], "-d \"$" var "\"") > 0 || index(L[j], "-d \"${" var "}\"") > 0) {
              checked = 1
              break
            }
          }
        }
        if (checked == 0) printf "UNCHECKED %s:%d\n", fname, i
      }
    }
    FNR == 1 { if (n > 0) report(); n = 0; fname = FILENAME }
    { L[++n] = $0 }
    END { if (n > 0) report(); printf "TOTAL %d\n", total }
  ' "$@"
}
# 件数だけを取り出す（grep -c は 0 件で rc=1 になり set -e に触れるので awk で数える）。
_mkchk_count() { printf '%s\n' "$1" | awk '$1 == "UNCHECKED" { n++ } END { print n + 0 }'; }

# **glob は必ず nullglob 下で配列へ展開し、0 件を明示的に赤にする。** 一致 0 件の glob を
# そのまま awk へ渡すと、リテラル文字列をファイル名として開こうとして fatal で suite ごと
# abort する — Issue `#1695` の実体がこれで、下限判定には**到達しない**（0 件は下限では捕まらない）。
# 下限が守るのは「1 件以上残ったまま縮退した」回だけである。tests 側の glob も同じ形なので
# 併せて塞ぐ（片方だけ直すと、次に TESTS_DIR の解決が壊れた回に同じ読み違いを再演する）。
# 公開ワークフローの suite 集合の組み立ても同じ nullglob + 0 件ガードの形を採っている。
# shopt -p は当該オプションが off のとき非 0 を返す。set -e 下では代入ごと落ちるので
# 明示的に握る（保存の失敗は復元の失敗であって検査の失敗ではない）。
_mkchk_saved_nullglob="$(shopt -p nullglob || true)"
shopt -s nullglob
# cases/ は verify.sh から分けた検査本体（Issue `#2692`）。ここを外すと移した mktemp が走査から落ちる。
_mkchk_targets=("$TESTS_DIR"/*/verify.sh "$TESTS_DIR"/*/cases/*.sh)
if [ -n "$_mkchk_root_scripts" ]; then
  _mkchk_targets+=("$_mkchk_repo_root"/scripts/*.sh)
fi
eval "$_mkchk_saved_nullglob"

if [ "${#_mkchk_targets[@]}" -eq 0 ]; then
  bad "case 36: 走査対象が 0 件（glob が 1 件も一致しない）— この検査は成立していない"
  _mkchk_out="TOTAL 0"
else
  _mkchk_out="$(_mkchk_scan "${_mkchk_targets[@]}")"
fi
_mkchk_total="$(printf '%s\n' "$_mkchk_out" | awk '$1 == "TOTAL" { print $2 + 0 }')"
_mkchk_bad="$(_mkchk_count "$_mkchk_out")"
# 下限は配置によらず 1 本にする。母集団の差は実測で 1 件だけ（SSOT 51 / 配布先 50。root
# scripts/ 側の寄与が 1 件）なので、配置別に緩い下限を置くと「配布先だけ半分の欠落を許す」
# ことになり、最も守りたい退行の回に最も緩くなる（レビュー実測）。
if [ "${_mkchk_total:-0}" -lt 30 ]; then
  bad "テンプレート付き mktemp -d を ${_mkchk_total:-0} 件しか走査できなかった（下限 30。この検査は成立していない）"
elif [ "$_mkchk_bad" -eq 0 ]; then
  ok "成功経路で実体を検査しない mktemp -d が無い（${_mkchk_total} 件走査）"
else
  bad "成功経路で実体（-d）を検査しない mktemp -d が再混入した"
  printf '%s\n' "$_mkchk_out" | awk '$1 == "UNCHECKED" { print "    | " $2 }' >&2
fi

# 配置判定の回帰ケース。上の分岐は通常の checkout では 1 つしか踏まれないため、合成ツリーで
# 5 通りすべての判定を固定する。これが無いと、配布先での未展開 glob による中断や、標識が
# 片方だけ立った回の誤った成功判定が再発しても検出できない（Codex 指摘）。
_mkchk_lx="$RUN_WORK/ff-mkchk-layout"
rm -rf "$_mkchk_lx"
# 合成ツリーを 1 つ作る。$1 = 名前 / $2 = oss を置くか / $3 = 兄弟プラグインを置くか /
# $4 = root scripts/ を置くか。プラグイン実体は .claude-plugin/plugin.json の実在で数えるので、
# 兄弟側にもそれを置く（素のディレクトリでは標識にならないことも下で対照にする）。
_mkchk_mktree() {
  local _name="$1" _oss="$2" _sib="$3" _scr="$4" _r="$_mkchk_lx/$1"
  mkdir -p "$_r/plugins/ff-dev-toolkit/.claude-plugin"
  printf '{}\n' > "$_r/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
  [ "$_oss" = "yes" ] && mkdir -p "$_r/oss/ff-dev-toolkit"
  if [ "$_sib" = "yes" ]; then
    mkdir -p "$_r/plugins/other-plugin/.claude-plugin"
    printf '{}\n' > "$_r/plugins/other-plugin/.claude-plugin/plugin.json"
  fi
  [ "$_scr" = "yes" ] && mkdir -p "$_r/scripts"
  printf '%s\n' "$_r"
}
_mkchk_expect_layout() {
  local _label="$1" _root="$2" _want="$3" _got
  _got="$(_mkchk_layout "$_root")"
  if [ "$_got" = "$_want" ]; then
    ok "配置判定: ${_label} → ${_want}"
  else
    bad "配置判定: ${_label} は ${_want} を期待したが ${_got} だった"
  fi
}
_mkchk_expect_layout "SSOT（oss + 兄弟プラグイン + scripts）" \
  "$(_mkchk_mktree ssot yes yes yes)" ssot
_mkchk_expect_layout "配布先（oss なし + 単体収録 + scripts なし）" \
  "$(_mkchk_mktree dist no no no)" dist
_mkchk_expect_layout "標識の食い違い（oss だけ）" \
  "$(_mkchk_mktree mismatch-oss yes no no)" mismatch
_mkchk_expect_layout "標識の食い違い（兄弟プラグインだけ）" \
  "$(_mkchk_mktree mismatch-sib no yes no)" mismatch
_mkchk_expect_layout "SSOT 配置なのに scripts/ が無い" \
  "$(_mkchk_mktree ssot-no-scripts yes yes no)" ssot-no-scripts
_mkchk_expect_layout "配布先の標識なのに root scripts/ が在る" \
  "$(_mkchk_mktree dist-with-scripts no no yes)" dist-with-scripts
# 標識 2 が「プラグイン実体」を数えていることの負の対照。plugin.json を持たない素の
# ディレクトリは標識にならない（ツール生成物で誤って mismatch にしない）。
_mkchk_lx_bare="$(_mkchk_mktree bare-dir no no no)"
mkdir -p "$_mkchk_lx_bare/plugins/tmp-artifact"
_mkchk_expect_layout "配布先 + plugins/ 直下の素のディレクトリ" "$_mkchk_lx_bare" dist
rm -rf "$_mkchk_lx"

# 検出器そのものが効くことを変異 fixture で実測する（構造検査が空振りしていないこと）。この
# verify.sh の複製から成功経路の -d 検査だけを落とし、複製を走査して赤くなることを見る。
_mkchk_fx="$RUN_WORK/ff-mktemp-template-check"
rm -rf "$_mkchk_fx"
mkdir -p "$_mkchk_fx"
cp "$SCRIPT_DIR/verify.sh" "$_mkchk_fx/control.sh"
sed -E 's/ && \[ -d "\$[A-Za-z_][A-Za-z_0-9]*" \]//' "$_mkchk_fx/control.sh" > "$_mkchk_fx/mutated.sh"
if cmp -s "$_mkchk_fx/control.sh" "$_mkchk_fx/mutated.sh"; then
  bad "変異 fixture を生成できなかった（検出力を測れていないので 0 件は主張できない）"
else
  _mkchk_ctl_bad="$(_mkchk_count "$(_mkchk_scan "$_mkchk_fx/control.sh")")"
  _mkchk_mut_bad="$(_mkchk_count "$(_mkchk_scan "$_mkchk_fx/mutated.sh")")"
  if [ "$_mkchk_ctl_bad" -eq 0 ]; then
    ok "変異前の複製は 0 件（赤くなる理由が変異そのものであることの対照）"
  else
    bad "変異前の複製が既に ${_mkchk_ctl_bad} 件（対照が成立していない）"
  fi
  if [ "$_mkchk_mut_bad" -gt 0 ]; then
    ok "成功経路の -d 検査を落とした複製を未検査として検出する（検出力の実測）"
  else
    bad "-d 検査を落としても検出できない（この検査は空振りする）"
  fi
fi
rm -rf "$_mkchk_fx"

# suite-cases-end: parallel.sh
