#!/usr/bin/env bash
#
# multi-agent-load-gate: レーン起動前の負荷判定と --perspective のカンマ区切り（Issue `#1810` / `#1833`）。
#
# (A) 契約: 正本 docs-template/05-operations/deployment/multi-cli-review-orchestration.md の
#     「レーン起動前の負荷判定」節（アンカー lane-load-gate）が、閾値の形（論理コア数 × 係数）・
#     既定係数 10・根拠の実測 3 件・係数の環境変数・閾値以下で何も出さないことを述べ、
#     git-workflow.md ステップ6 がその節を参照していること。既定係数は実装の定数とも照合する。
# (B) 挙動: 一時 git リポジトリ + stub codex で orchestrator を実走し、load average を
#     FF_MULTI_AGENT_LOAD_SAMPLE（内部の注入口）で擬似注入して、閾値超 → 1 行出して逐次、
#     閾値以下 → 何も出さず並列、境界（= 閾値は並列 / +0.01 は逐次）、係数 0 → 判定しない、
#     係数不正 → プラン構築前に rc=2（前回結果を消さない。dry-run / --sequential / 1 タスクでも）、
#     1 タスク → 判定しない、を確かめる。注入なしの実測経路（sysctl が PATH に無い形を含む）も走らせる。
# (C) --perspective a,b の分割（`#1833` の A 案）: 分割結果・繰り返し指定との併用・分割後の
#     各語が is_safe_token を通ることを dry-run で確かめる。
# (D) 検出力: orchestrator の一時コピーから負荷判定の呼び出し行 / カンマ分割を外す変異で、
#     (B) / (C) の針が赤になることを同じ実行内で実測する。
#
# 空振り検出: 正本の lane-load-gate アンカーを消す（節の抽出が 0 行）と (A) の節抽出 + 規定行 12 本の計 13 件が赤、stub の実行プランを 1 タスクにすると (B) の前提検査・閾値超・境界・実測経路・係数 0 / 08・注入値不正の計 11 件が赤になる（2026-09-27 実測）。
#
# 実 CLI・ネットワーク・課金は伴わない。一時領域を作れない環境では skip。
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（multi-agent-serialization と同じ扱い）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
DOC="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-review-orchestration.md"
GIT_WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"

for f in "$MULTI_AGENT" "$DOC" "$GIT_WORKFLOW"; do
  [ -f "$f" ] || { echo "✗ 対象ファイルが見つかりません: $f" >&2; exit 1; }
done

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "FF_MULTI_AGENT_LOAD_PER_CORE MULTI_AGENT_CODEX_PROFILE" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== (A) 契約: 正本の規定行 =="

SECTION="$(awk '
  /^<a id="lane-load-gate"><\/a>$/ { f = 1; next }
  f && (/^<a id="/ || /^## /) { exit }
  f { print }
' "$DOC")"
if [ -n "$SECTION" ]; then
  ok "lane-load-gate 節を抽出できる"
else
  bad "lane-load-gate 節が見つからない（アンカーの改名・削除）"
fi
for needle in \
  '### レーン起動前の負荷判定' \
  '論理コア数 × 係数' \
  '係数の既定は **10**' \
  'load average 295' \
  'load 150' \
  '1 コアあたり 10 を超えると stall する' \
  '並行セッションのゲートだけが負荷源の回' \
  'FF_MULTI_AGENT_LOAD_PER_CORE' \
  '`0` で判定を無効化する' \
  '閾値以下なら**何も出さずに**従来どおり並列' \
  '`--sequential` と同じ逐次実行へ倒す' \
  'Agent / Task ツール'; do
  case "$SECTION" in
    *"$needle"*) ok "規定行: ${needle}" ;;
    *) bad "規定行が無い: ${needle}" ;;
  esac
done
if /usr/bin/grep -qF 'multi-cli-review-orchestration.md#lane-load-gate' "$GIT_WORKFLOW"; then
  ok "git-workflow.md ステップ6 が lane-load-gate 節を参照する"
else
  bad "git-workflow.md から lane-load-gate 節への参照が無い"
fi
IMPL_DEFAULT="$(awk -F= '/^LOAD_GATE_DEFAULT_PER_CORE=/ { print $2; exit }' "$MULTI_AGENT")"
if [ "$IMPL_DEFAULT" = "10" ]; then
  ok "実装の既定係数（LOAD_GATE_DEFAULT_PER_CORE=10）が正本と一致"
else
  bad "実装の既定係数が '${IMPL_DEFAULT}'（正本は 10）"
fi

if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ multi-agent-load-gate: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

REPO="$TMP/repo"
ff_git_fixture_init "$REPO" "multi-agent-load-gate-test" "test@example.com"
cd "$REPO"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > app.txt
git add app.txt
git commit -qm "change"

STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
echo "## Findings"
echo "- Suggestion: stub review"
echo "  - verdict: severity=suggestion failure_scenario=no confidence=50"
SH
chmod +x "$STUB/codex"

GATE_LINE='負荷判定: load average'

# run_gate <label> <multi-agent path> <追加の env 代入...> -- <追加の引数...>
# ログは repo の外（${TMP}）へ書く — 作業ツリーへ置くとリビジョンガードが結果を破棄する。
run_gate() {
  local label="$1" script="$2"; shift 2
  local envs=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  args=("$@")
  rm -rf "$REPO/.review-results"
  # PRESEED=1 のときは前回結果を模した 1 ファイルを置く（設定誤りで止まる回に前回結果が
  # 消されないことを確かめる）。
  if [ "${PRESEED:-0}" = 1 ]; then
    mkdir -p "$REPO/.review-results/codex-cli"
    printf '%s\n' '<!-- Multi-CLI Review Result -->' 'preseed' > "$REPO/.review-results/codex-cli/code-review.md"
  fi
  set +e
  # run_isolated は全 suite のために FF_MULTI_AGENT_LOAD_PER_CORE=0（判定停止）を置くので、
  # ここだけ env -u で外して既定係数の挙動を見る（ケース固有の代入はその後に効く）。
  run_isolated PATH="$STUB:/usr/bin:/bin" FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE=1 \
    /usr/bin/env -u FF_MULTI_AGENT_LOAD_PER_CORE ${envs[@]+"${envs[@]}"} \
    bash "$script" --task review --cli codex-cli --base develop --timeout 60 ${args[@]+"${args[@]}"} \
    >"$TMP/${label}.out" 2>"$TMP/${label}.err"
  echo $? > "$TMP/${label}.rc"
  set -e
}
rc_of() { cat "$TMP/$1.rc"; }
has() { /usr/bin/grep -qF -- "$2" "$TMP/$1.err"; }
count_of() { local n; n="$(/usr/bin/grep -cF -- "$2" "$TMP/$1.err")" || n=0; printf '%s\n' "$n"; }

echo "== (B) 挙動: 負荷判定 =="

CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || CORES=""
case "$CORES" in
  ''|*[!0-9]*|0) bad "前提: getconf _NPROCESSORS_ONLN でコア数を取れない（'${CORES}'）"; CORES=1 ;;
esac

TWO="--perspective code-review --perspective test-analysis"
# shellcheck disable=SC2086 # TWO は意図的に語分割する
run_gate high "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE=99999 -- $TWO
if [ "$(rc_of high)" -eq 0 ]; then ok "閾値超: rc=0 で完走"; else bad "閾値超: rc=$(rc_of high)"; tail -5 "$TMP/high.err" | sed 's/^/    | /' >&2; fi
# 前提: stub プランが 2 タスクであること（1 タスクだと判定自体が走らず空振りする）
if [ "$(count_of high '▶ codex-cli → ')" -eq 2 ]; then
  ok "前提: 2 タスクが起動した"
else
  bad "前提が崩れた: 起動タスク数が $(count_of high '▶ codex-cli → ')（期待 2。観点名の変更を確認すること）"
fi
if [ "$(count_of high "$GATE_LINE")" -eq 1 ] \
  && has high "load average 99999 > 閾値 $((CORES * 10))（${CORES} コア × 10）" \
  && has high '逐次で実行します'; then
  ok "閾値超: 実測値・閾値（コア数 × 既定 10）・判定の 1 行が出る"
else
  bad "閾値超: 判定行が期待どおりでない"
  /usr/bin/grep -F '負荷判定' "$TMP/high.err" | sed 's/^/    | /' >&2 || true
fi
if ! has high 'parallel review tasks'; then
  ok "閾値超: 並列の待機行が出ない（逐次へ倒れた）"
else
  bad "閾値超なのに並列で起動した"
fi

# shellcheck disable=SC2086
run_gate low "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE=0.5 -- $TWO
if [ "$(rc_of low)" -eq 0 ] && ! has low '負荷判定' && has low 'Waiting for 2 parallel review tasks'; then
  ok "閾値以下: 何も出さずに並列で起動する"
else
  bad "閾値以下の挙動が違う (rc=$(rc_of low))"
  /usr/bin/grep -E '負荷判定|Waiting' "$TMP/low.err" | sed 's/^/    | /' >&2 || true
fi

# 境界: 閾値は「超えたら」逐次。係数 1 で閾値 = コア数にし、等しい値は並列・わずかに超える値は逐次。
# shellcheck disable=SC2086
run_gate edge_eq "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE="$CORES" FF_MULTI_AGENT_LOAD_PER_CORE=1 -- $TWO
if [ "$(rc_of edge_eq)" -eq 0 ] && ! has edge_eq '負荷判定' && has edge_eq 'Waiting for 2 parallel review tasks'; then
  ok "境界: load = 閾値（${CORES}）は並列・無出力"
else
  bad "境界: load = 閾値で並列・無出力にならない (rc=$(rc_of edge_eq))"
fi
# shellcheck disable=SC2086
run_gate edge_over "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE="${CORES}.01" FF_MULTI_AGENT_LOAD_PER_CORE=1 -- $TWO
if [ "$(rc_of edge_over)" -eq 0 ] && has edge_over "load average ${CORES}.01 > 閾値 ${CORES}（${CORES} コア × 1）" && ! has edge_over 'parallel review tasks'; then
  ok "境界: load = 閾値 + 0.01 は逐次"
else
  bad "境界: load = 閾値 + 0.01 で逐次にならない (rc=$(rc_of edge_over))"
fi

# 実測経路（注入なし）: PATH は /usr/sbin まで（macOS の sysctl の位置）。係数を大きくして
# 閾値を超えないようにし、「実測できない」注記も判定行も出ないことを要求する — 解析が
# 壊れると注記が出るので赤になる。
# shellcheck disable=SC2086
run_gate real "$MULTI_AGENT" PATH="$STUB:/usr/bin:/bin:/usr/sbin" FF_MULTI_AGENT_LOAD_PER_CORE=999999 -- $TWO
if [ "$(rc_of real)" -eq 0 ] && ! has real '負荷判定' && has real 'Waiting for 2 parallel review tasks'; then
  ok "実測経路: 注入なしで load average とコア数を読める（注記・判定行なし）"
else
  bad "実測経路: 注入なしで実測できない、または判定行が出た (rc=$(rc_of real))"
  /usr/bin/grep -F '負荷判定' "$TMP/real.err" | sed 's/^/    | /' >&2 || true
fi
# 同じ実測経路で PATH から sysctl を外しても（macOS の /usr/sbin/sysctl へのフォールバック）読める。
# shellcheck disable=SC2086
run_gate real_nosbin "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_PER_CORE=999999 -- $TWO
if [ "$(rc_of real_nosbin)" -eq 0 ] && ! has real_nosbin '負荷判定'; then
  ok "実測経路: PATH に sysctl が無くても読める"
else
  bad "実測経路: PATH に sysctl が無いと実測できない (rc=$(rc_of real_nosbin))"
fi

# shellcheck disable=SC2086
run_gate off "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE=99999 FF_MULTI_AGENT_LOAD_PER_CORE=0 -- $TWO
if [ "$(rc_of off)" -eq 0 ] && ! has off '負荷判定' && has off 'Waiting for 2 parallel review tasks'; then
  ok "係数 0: 判定しない（並列のまま・判定行なし）"
else
  bad "係数 0 で判定が止まっていない (rc=$(rc_of off))"
fi

# 係数不正: プランを組む前に rc=2 で止まる。前回結果を消さない・dry-run / --sequential /
# 1 タスクでも同じく止まる（並列起動の直前まで検査を遅らせない）。
PRESEED=1
# shellcheck disable=SC2086
run_gate badcoef "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE=0.5 FF_MULTI_AGENT_LOAD_PER_CORE=ten -- $TWO
PRESEED=0
if [ "$(rc_of badcoef)" -eq 2 ] && has badcoef 'FF_MULTI_AGENT_LOAD_PER_CORE は 6 桁までの非負整数' && ! has badcoef 'Running Codex CLI review'; then
  ok "係数不正: タスクを起動せず rc=2 で止まり、変数名を名指しする（既定へ黙って倒さない）"
else
  bad "係数不正の扱いが違う (rc=$(rc_of badcoef))"
fi
if /usr/bin/grep -qx 'preseed' "$REPO/.review-results/codex-cli/code-review.md" 2>/dev/null; then
  ok "係数不正: 前回結果を消さない（検査は破壊操作より前）"
else
  bad "係数不正: 止まる前に前回結果が消された・退避された"
fi
for variant in "dry:--dry-run" "seq:--sequential" "one:"; do
  vname="${variant%%:*}"; vflag="${variant#*:}"
  if [ "$vname" = one ]; then
    run_gate "badcoef_${vname}" "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_PER_CORE=ten -- --perspective code-review
  else
    # shellcheck disable=SC2086
    run_gate "badcoef_${vname}" "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_PER_CORE=ten -- $TWO "$vflag"
  fi
  if [ "$(rc_of "badcoef_${vname}")" -eq 2 ] && has "badcoef_${vname}" 'FF_MULTI_AGENT_LOAD_PER_CORE'; then
    ok "係数不正（${vname}）: 並列起動の経路でなくても rc=2 で止まる"
  else
    bad "係数不正（${vname}）: 黙って通った (rc=$(rc_of "badcoef_${vname}"))"
  fi
done
run_gate badcoef_big "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_PER_CORE=99999999999999999999 -- --perspective code-review --dry-run
if [ "$(rc_of badcoef_big)" -eq 2 ]; then
  ok "係数不正（7 桁以上）: 算術の桁あふれ前に rc=2 で止まる"
else
  bad "係数 20 桁が通った (rc=$(rc_of badcoef_big))"
fi
# ゼロ埋め（08）は 10 進として読む（8 進解釈だと算術展開がエラーになる）。
# shellcheck disable=SC2086
run_gate leading0 "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE=0.5 FF_MULTI_AGENT_LOAD_PER_CORE=08 -- $TWO
if [ "$(rc_of leading0)" -eq 0 ] && ! has leading0 '負荷判定' && has leading0 'Waiting for 2 parallel review tasks'; then
  ok "係数 08: 10 進として読み、並列・無出力"
else
  bad "係数 08 の扱いが違う (rc=$(rc_of leading0))"
fi

run_gate single "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE=99999 -- --perspective code-review
if [ "$(rc_of single)" -eq 0 ] && ! has single '負荷判定'; then
  ok "1 タスク: 並列にする対象が無いので判定しない"
else
  bad "1 タスクで判定行が出た (rc=$(rc_of single))"
fi

# shellcheck disable=SC2086
run_gate unmeasured "$MULTI_AGENT" FF_MULTI_AGENT_LOAD_SAMPLE=not-a-number -- $TWO
if [ "$(rc_of unmeasured)" -eq 0 ] && has unmeasured "FF_MULTI_AGENT_LOAD_SAMPLE が数値ではないため（'not-a-number'）" && has unmeasured 'Waiting for 2 parallel review tasks'; then
  ok "注入値が数値でない: 原因を名指しする注記 1 行を出して並列のまま起動する"
else
  bad "実測不能の扱いが違う (rc=$(rc_of unmeasured))"
fi

echo "== (C) --perspective のカンマ区切り =="

plan_perspectives() {
  awk '/^   codex-cli \[/ { f = 1; next } /^   [a-z]/ { f = 0 } f && /^     - / { sub(/^     - /, ""); print }' "$TMP/$1.err" | LC_ALL=C sort | tr '\n' ' '
}
run_gate comma "$MULTI_AGENT" -- --perspective code-review,test-analysis --dry-run
if [ "$(rc_of comma)" -eq 0 ] && [ "$(plan_perspectives comma)" = "code-review test-analysis " ]; then
  ok "--perspective a,b が 2 観点へ分割される"
else
  bad "カンマ区切りの分割結果が違う (rc=$(rc_of comma)): '$(plan_perspectives comma)'"
  tail -3 "$TMP/comma.err" | sed 's/^/    | /' >&2
fi
run_gate mixed "$MULTI_AGENT" -- --perspective code-review,test-analysis --perspective acceptance-criteria --dry-run
if [ "$(rc_of mixed)" -eq 0 ] && [ "$(plan_perspectives mixed)" = "acceptance-criteria code-review test-analysis " ]; then
  ok "カンマ区切りと繰り返し指定を併用できる"
else
  bad "併用の結果が違う (rc=$(rc_of mixed)): '$(plan_perspectives mixed)'"
fi
run_gate emptylist "$MULTI_AGENT" -- --perspective ',' --dry-run
if [ "$(rc_of emptylist)" -eq 2 ] && has emptylist '--perspective に観点名がありません'; then
  ok "区切りだけの値（','）は観点名なしとして名指しで止まる"
else
  bad "区切りだけの値の扱いが違う (rc=$(rc_of emptylist))"
fi
run_gate unsafe "$MULTI_AGENT" -- --perspective 'code-review,../x' --dry-run
if [ "$(rc_of unsafe)" -ne 0 ] && has unsafe "unsafe perspective name: '../x'"; then
  ok "分割後の各語が is_safe_token を通る（'../x' だけを名指しで拒否）"
else
  bad "分割後の安全検査が効いていない (rc=$(rc_of unsafe))"
fi

echo "== (D) 検出力: 変異で赤になる =="

MUT="$TMP/mutated-plugin"
mkdir -p "$MUT"
cp -R "$PLUGIN_ROOT/scripts" "$MUT/scripts"
MUT_MA="$MUT/scripts/multi-agent.sh"

apply_mutation() {
  # $1: 対象行（完全一致） $2: 置換行（空なら削除）
  local n
  n="$(awk -v t="$1" '$0 == t { c++ } END { print c + 0 }' "$MULTI_AGENT")"
  [ "$n" -eq 1 ] || { bad "変異の対象行が ${n} 件（期待 1）: $1"; return 1; }
  awk -v t="$1" -v r="$2" '$0 == t { if (r != "") print r; next } { print }' "$MULTI_AGENT" > "$MUT_MA"
}

# shellcheck disable=SC2016 # コピー先で評価させる literal
if apply_mutation '  apply_load_gate || return 2' ''; then
  # shellcheck disable=SC2086
  run_gate mut_gate "$MUT_MA" FF_MULTI_AGENT_LOAD_SAMPLE=99999 -- $TWO
  if ! has mut_gate '負荷判定' && has mut_gate 'parallel review tasks'; then
    ok "負荷判定の呼び出しを外す変異: 閾値超でも並列になり、(B) の針が赤になる"
  else
    bad "負荷判定の呼び出しを外しても挙動が変わらない（針が変異を検出できない）"
  fi
fi
# shellcheck disable=SC2016
if apply_mutation '        PERSPECTIVE_FILTER="${PERSPECTIVE_FILTER:+$PERSPECTIVE_FILTER }${2//,/ }"; shift 2 ;;' \
  '        PERSPECTIVE_FILTER="${PERSPECTIVE_FILTER:+$PERSPECTIVE_FILTER }$2"; shift 2 ;;'; then
  run_gate mut_comma "$MUT_MA" -- --perspective code-review,test-analysis --dry-run
  if [ "$(rc_of mut_comma)" -ne 0 ] && has mut_comma "unsafe perspective name: 'code-review,test-analysis'"; then
    ok "カンマ分割を外す変異: (C) の分割針が赤になる（旧挙動の unsafe 拒否へ戻る）"
  else
    bad "カンマ分割を外しても挙動が変わらない (rc=$(rc_of mut_comma))"
  fi
fi

# shellcheck disable=SC2016
if apply_mutation "  if awk -v l=\"\$load\" -v t=\"\$threshold\" 'BEGIN { exit !(l > t) }'; then" \
  "  if awk -v l=\"\$load\" -v t=\"\$threshold\" 'BEGIN { exit !(l >= t) }'; then"; then
  # shellcheck disable=SC2086
  run_gate mut_ge "$MUT_MA" FF_MULTI_AGENT_LOAD_SAMPLE="$CORES" FF_MULTI_AGENT_LOAD_PER_CORE=1 -- $TWO
  if has mut_ge '負荷判定'; then
    ok "比較を >= にする変異: 境界（load = 閾値）で逐次へ倒れ、境界の針が赤になる"
  else
    bad "比較を >= にしても境界の挙動が変わらない（境界の針が変異を検出できない）"
  fi
fi

echo
echo "multi-agent-load-gate: pass=${PASS} fail=${FAIL}"
FF_REACHED_END=1
[ "$FAIL" -eq 0 ]
