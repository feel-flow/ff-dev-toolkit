#!/usr/bin/env bash
#
# multi-agent-serialization: 同一 CLI への観点集中の制御（Issue #251）。
#
# minimize_cost は premium（claude-code）の担当観点を最安 tier へ振り替えるため、
# レート制限のある free-tier CLI に複数観点が集中する。本ツールは実行時 fallback を
# 意図的に持たないので、throttle されたタスクは別 CLI で再実行されず**その観点の
# カバレッジがゼロ**になる。対策は 2 層:
#   (1) 実行層 — 同一 CLI のタスクは 1 本のワーカーで逐次実行（CLI 間は並列のまま）
#   (2) プラン層 — free-tier CLI に複数観点が乗る形をプラン表示で名指しで警告
# 本 suite は (1) を stub CLI の start/end ログの非交差で、(2) を dry-run 出力で固定する。
# standard tier の並列維持は期限付きバリアと逐次化変異で固定する（詳細は README.md）。
#
# 実 CLI は 1 つも起動しない（全 CLI を stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
CODEX_BARRIER_TIMEOUT_SECONDS=10
CODEX_BARRIER_PARTIES=2

[ -f "$MULTI_AGENT" ] || {
  echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2
  exit 1
}

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ multi-agent-serialization: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- レビュー対象の差分を持つ一時リポジトリ ---
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "multi-agent-serialization-test"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > app.txt
git add app.txt
git commit -qm "change"

# --- stub CLI 群 ---
# gemini は start/end を PID つきで記録し（時刻は取らない。判定は順序だけで足りる）、
# 意図的に 0.6 秒滞留する — 旧実装
# （全タスク一斉 background）では同一 CLI の 2 タスクがこの滞留窓で必ず交差する。
# 他 CLI は即答（並列のままでよい側なので、ここでは順序を主張しない）。
STUB="$TMP/bin"
mkdir -p "$STUB"
GEMINI_LOG="$TMP/gemini-events.log"
# $TMP/gemini-fail-nth があるときは、その回数目の起動だけ失敗する（途中失敗後の
# 継続の検査に使う。カウンタは逐次実行前提 — 本 suite が固定する性質そのもの）。
cat > "$STUB/gemini" <<SH
#!/usr/bin/env bash
n=\$( (cat "$TMP/gemini-count" 2>/dev/null || echo 0) )
n=\$((n + 1))
echo "\$n" > "$TMP/gemini-count"
echo "start \$\$" >> "$GEMINI_LOG"
sleep 0.6
echo "end \$\$" >> "$GEMINI_LOG"
if [ -f "$TMP/gemini-fail-nth" ] && [ "\$n" -eq "\$(cat "$TMP/gemini-fail-nth")" ]; then
  echo "stub: simulated rate-limit failure" >&2
  exit 1
fi
echo "## Findings"
echo "- Suggestion: stub gemini review"
SH
chmod +x "$STUB/gemini"
# grok は置かない（未インストール扱いにしてプラン fallback へ委ねる）— grok アダプタは
# サンドボックス適用イベントの実在を fail-closed で要求するため、素朴な stub では
# 完走できない（adapter-model-args suite 参照）。本 suite の主題は gemini の逐次化で、
# grok の起動経路は検査対象外。
#
# ただし「置かない = 未インストール」が成り立つのは、**起動 PATH に実行環境の PATH を
# 混ぜない**場合だけ。混ぜるとホストに grok が入っているかどうかで結果が変わる
# （Issue #435。実測でどちらに転んでも期待の 1 件が成立しなかった）。
# そこでホストを模した grok を用意し、**この suite 自身の PATH には載せる**。
# 起動側が PATH を絞れていれば一度も呼ばれない。`$STUB:$PATH` へ戻す退行が入ると
# ここが呼ばれて起動ログが残り、ホストに grok が無い環境でも赤くなる。
HOSTMOCK="$TMP/host-bin"
mkdir -p "$HOSTMOCK"
HOSTMOCK_LOG="$TMP/hostmock-invocations.log"
: > "$HOSTMOCK_LOG"
cat > "$HOSTMOCK/grok" <<SH
#!/usr/bin/env bash
echo "invoked \$\$" >> "$HOSTMOCK_LOG"
echo "## Findings"
echo "- Suggestion: host-mock grok (should never run)"
SH
chmod +x "$HOSTMOCK/grok"
export PATH="$HOSTMOCK:$PATH"
# codex（standard tier）は 2-party の期限付きバリアで互いの開始を待つ。
# 並列なら両者が通過し、standard まで逐次化すると先行タスクが期限切れになる。
# 時間窓内の start/end 交差ではなく、相手の開始という事象を期限内で待つため、短い
# 滞留窓より大きな spawn スキューを許容する。期限は壊れた実装で suite を hang させない
# 安全弁である（Issue #415）。
CODEX_LOG="$TMP/codex-events.log"
CODEX_BARRIER="$TMP/codex-barrier"
CODEX_BARRIER_TIMEOUT_LOG="$TMP/codex-barrier-timeouts.log"
reset_codex_barrier() {
  rm -rf "$CODEX_BARRIER"
  mkdir -p "$CODEX_BARRIER"
  : > "$CODEX_LOG"
  : > "$CODEX_BARRIER_TIMEOUT_LOG"
}
count_codex_barrier_timeouts() {
  local count grep_rc
  count="$(/usr/bin/grep -c '^timeout ' "$CODEX_BARRIER_TIMEOUT_LOG")" && grep_rc=0 || grep_rc=$?
  case "$grep_rc" in
    0) printf '%s\n' "$count" ;;
    1) printf '0\n' ;;
    *) return "$grep_rc" ;;
  esac
}
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
echo "start \$\$" >> "$CODEX_LOG"
: > "$CODEX_BARRIER/ready.\$\$" || {
  echo "stub: codex barrier marker could not be created" >&2
  exit 1
}
deadline=\$((SECONDS + $CODEX_BARRIER_TIMEOUT_SECONDS))
while :; do
  ready=\$(find "$CODEX_BARRIER" -maxdepth 1 -type f -name 'ready.*' | wc -l | tr -d ' ')
  if [ "\$ready" -ge "$CODEX_BARRIER_PARTIES" ]; then
    break
  fi
  if [ "\$SECONDS" -ge "\$deadline" ]; then
    echo "timeout \$\$" >> "$CODEX_BARRIER_TIMEOUT_LOG"
    echo "stub: codex barrier timed out after ${CODEX_BARRIER_TIMEOUT_SECONDS}s (ready=\${ready}/${CODEX_BARRIER_PARTIES})" >&2
    exit 1
  fi
  sleep 0.1
done
echo "end \$\$" >> "$CODEX_LOG"
echo "## Findings"
echo "- Suggestion: stub review"
SH
chmod +x "$STUB/codex"
for name in claude copilot; do
  cat > "$STUB/$name" <<'SH'
#!/usr/bin/env bash
echo "## Findings"
echo "- Suggestion: stub review"
SH
  chmod +x "$STUB/$name"
done

echo "== プラン層: free-tier 集中の警告（Issue #251） =="

set +e
PLAN_OUT="$(run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --mode distributed --strategy minimize_cost --base develop --dry-run 2>&1)"
PLAN_RC=$?
set -e
if [[ $PLAN_RC -ne 0 ]]; then
  bad "dry-run が非 0 終了した (rc=$PLAN_RC)"
  printf '%s\n' "$PLAN_OUT" | tail -10 | sed 's/^/    | /' >&2
fi

# プラン層でも grok が未インストール扱いになっていること。**実行層の検査だけでは
# ここは守れない** — dry-run は CLI を起動しないのでホスト模擬 grok のログが残らず、
# 下の観点数の検査も `>= 2` なので集中数が 5 → 4 に変わっても通る。つまり dry-run の
# PATH だけを実行環境まかせに戻す部分退行は、他の全検査を素通りする（実測で 13 件
# すべて緑のまま通過した）。プラン層にも実行層と同じ強度の前提検査を置く。
case "$PLAN_OUT" in
  *"grok-cli (grok) — not installed"*)
    ok "プラン層でも grok が未インストール扱い（dry-run 側の PATH 制限が効いている）" ;;
  *)
    bad "プラン層で grok が未インストール扱いになっていない（dry-run 側の PATH に実行環境の PATH が混ざっている）"
    printf '%s\n' "$PLAN_OUT" | /usr/bin/grep -E 'grok' | head -3 | sed 's/^/    | /' >&2 ;;
esac

# 前提の確認: minimize_cost で gemini-cli に 2 観点以上が乗っていること。
# プラン形が変わって集中自体が消えたら、警告の検査は空振りになるので名指しで止める。
GEMINI_TASKS="$(printf '%s\n' "$PLAN_OUT" | awk '/^   gemini-cli \[/{f=1;next} /^   [a-z]/{f=0} f && /^     - /{n++} END{print n+0}')"
if [[ "$GEMINI_TASKS" -ge 2 ]]; then
  ok "前提: minimize_cost で gemini-cli に ${GEMINI_TASKS} 観点が集中する"
else
  bad "前提が崩れた: gemini-cli の観点数が ${GEMINI_TASKS}（プラン形の変更を確認して本 suite を追随させること）"
fi

case "$PLAN_OUT" in
  *"rate limit"*)
    ok "プラン表示が free-tier のレート制限リスクを警告する" ;;
  *)
    bad "プラン表示にレート制限の警告が無い"
    printf '%s\n' "$PLAN_OUT" | /usr/bin/grep -A3 'gemini-cli \[' | sed 's/^/    | /' >&2 ;;
esac
case "$PLAN_OUT" in
  *"zero coverage"*)
    ok "警告が「fallback 無し = カバレッジゼロ」の帰結まで述べる" ;;
  *)
    bad "警告が throttle の帰結（カバレッジゼロ）を述べていない" ;;
esac

echo "== 実行層: 同一 CLI 内の逐次化 =="

: > "$GEMINI_LOG"
reset_codex_barrier
rm -rf "$REPO/.review-results"
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --mode distributed --strategy minimize_cost --base develop --timeout 60 \
  >"$TMP/run.log" 2>&1
RUN_RC=$?
set -e
if [[ $RUN_RC -eq 0 ]]; then
  ok "orchestrator が全 stub タスクを完走 (rc=0)"
else
  bad "orchestrator が非 0 終了した (rc=$RUN_RC)"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi

GEMINI_STARTS="$(/usr/bin/grep -c '^start ' "$GEMINI_LOG")" || GEMINI_STARTS=0
if [[ "$GEMINI_STARTS" -ge 2 ]]; then
  ok "前提: gemini stub が ${GEMINI_STARTS} 回起動した（集中の実行形）"
else
  bad "前提が崩れた: gemini stub の起動が ${GEMINI_STARTS} 回（逐次化の検査が空振りする）"
fi

# 非交差の検査: ログが start/end の厳密な交互列であること。旧実装（一斉 background）
# では 0.6 秒の滞留窓で start start ... の交差が必ず記録される。
# 注意: awk の本文中の exit は END ブロックを**経由してから**終了するため、違反は
# フラグに記録して END で合成する（本文 exit 1 は END の exit に上書きされる）。
if awk '
  /^start / { if (open) { bad = 1 }; open = 1; next }
  /^end /   { if (!open) { bad = 1 }; open = 0; next }
  END { exit (bad || open) ? 1 : 0 }
' "$GEMINI_LOG"; then
  ok "同一 CLI のタスクが交差なく逐次実行されている（start/end が厳密な交互列）"
else
  bad "同一 CLI のタスクが並列に走っている（start/end が交差。レート制限 burst の再発）"
  sed 's/^/    | /' "$GEMINI_LOG" >&2
fi

# tier 限定の対称検査: codex（standard）の 2 タスクは並列のまま = 両方が期限付き
# バリアを通過し、start/start/end/end の交差が記録されること。
CODEX_STARTS="$(/usr/bin/grep -c '^start ' "$CODEX_LOG")" || CODEX_STARTS=0
if [[ "$CODEX_STARTS" -eq "$CODEX_BARRIER_PARTIES" ]]; then
  ok "前提: codex（standard）に ${CODEX_STARTS} タスク（${CODEX_BARRIER_PARTIES}-party バリアの検査対象）"
  if CODEX_TIMEOUTS="$(count_codex_barrier_timeouts)"; then
    if [[ "$CODEX_TIMEOUTS" -eq 0 ]]; then
      ok "standard tier の全タスクが期限付きバリアを通過（${CODEX_BARRIER_TIMEOUT_SECONDS} 秒までの spawn スキューを許容）"
    else
      bad "standard tier のバリアが ${CODEX_TIMEOUTS} 件期限切れ"
      sed 's/^/    | /' "$CODEX_BARRIER_TIMEOUT_LOG" >&2
    fi
    if [[ "$CODEX_TIMEOUTS" -eq 0 ]]; then
      if awk '
        /^start / { if (open) { bad = 1 }; open = 1; next }
        /^end /   { if (!open) { bad = 1 }; open = 0; next }
        END { exit (bad || open) ? 1 : 0 }
      ' "$CODEX_LOG"; then
        bad "standard tier まで逐次化されている（codex の start/end が交差しない — 一律逐次化への退行。既定 pair モードの実行時間が観点数倍になる）"
        sed 's/^/    | /' "$CODEX_LOG" >&2
      else
        ok "standard tier はタスク並列のまま（codex の start/end が交差 = tier 限定が効いている）"
      fi
    fi
  else
    bad "codex バリア期限切れログを読み取れない"
  fi
else
  bad "前提が崩れた: codex のタスク数が ${CODEX_STARTS}（期待 ${CODEX_BARRIER_PARTIES}。プラン形の変更を確認して本 suite を追随させること）"
fi

echo
echo "== standard tier 逐次化変異の検出力 =="

# 実 orchestrator を一時コピーし、free-tier 専用 worker の条件へ standard を加える。
# 先行 codex stub は相手を起動できず期限切れになるため、時間窓を調整しても生き残らない。
MUTATED_PLUGIN="$TMP/mutated-plugin"
mkdir -p "$MUTATED_PLUGIN"
cp -R "$PLUGIN_ROOT/scripts" "$MUTATED_PLUGIN/scripts"
MUTATED_MULTI_AGENT="$MUTATED_PLUGIN/scripts/multi-agent.sh"
# shellcheck disable=SC2016 # copied script で評価させる literal なのでこの shell では展開しない
MUTATION_MATCH='      if [[ "$(get_cli_cost_tier "$group_cli")" == "free-tier" ]]; then'
# shellcheck disable=SC2016 # 同上
MUTATION_REPLACEMENT='      if [[ "$(get_cli_cost_tier "$group_cli")" == "free-tier" || "$(get_cli_cost_tier "$group_cli")" == "standard" ]]; then'
MUTATION_MATCHES="$(awk -v target="$MUTATION_MATCH" '$0 == target { count++ } END { print count + 0 }' "$MUTATED_MULTI_AGENT")"
MUTATION_APPLIED=0
if [[ "$MUTATION_MATCHES" -eq 1 ]]; then
  awk -v target="$MUTATION_MATCH" -v replacement="$MUTATION_REPLACEMENT" \
    '{ if ($0 == target) $0 = replacement; print }' "$MUTATED_MULTI_AGENT" \
    > "$MUTATED_MULTI_AGENT.tmp"
  mv "$MUTATED_MULTI_AGENT.tmp" "$MUTATED_MULTI_AGENT"
  chmod +x "$MUTATED_MULTI_AGENT"
  MUTATION_APPLIED=1
  ok "逐次化変異が tier 条件へ 1 回だけ適用された"
else
  bad "逐次化変異の対象行が ${MUTATION_MATCHES} 件（期待 1 件。orchestrator の tier 条件へ追随すること）"
fi

if [[ "$MUTATION_APPLIED" -eq 1 ]]; then
  reset_codex_barrier
  rm -rf "$REPO/.review-results"
  set +e
  run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MUTATED_MULTI_AGENT" \
    --task review --mode distributed --strategy minimize_cost --base develop --timeout 60 \
    >"$TMP/mutated-run.log" 2>&1
  MUTATED_RUN_RC=$?
  set -e
  if [[ "$MUTATED_RUN_RC" -ne 0 ]]; then
    ok "standard tier 逐次化変異が非 0 終了"
  else
    bad "standard tier 逐次化変異が生き残った（rc=0）"
    tail -15 "$TMP/mutated-run.log" | sed 's/^/    | /' >&2
  fi
  if MUTATED_TIMEOUTS="$(count_codex_barrier_timeouts)"; then
    if [[ "$MUTATED_TIMEOUTS" -ge 1 ]]; then
      ok "逐次化変異を codex バリアの期限切れで検出"
    else
      bad "逐次化変異で codex バリア期限切れが記録されていない"
      tail -15 "$TMP/mutated-run.log" | sed 's/^/    | /' >&2
    fi
  else
    bad "逐次化変異の codex バリア期限切れログを読み取れない"
  fi
fi

echo "== 途中失敗後の継続と失敗の名指し =="

# 2 回目の gemini タスクだけ失敗させる。逐次ワーカーはタスク失敗で止まらず
# 残りを実行し、失敗は 1 件として名指しされ、全体 rc は非 0 になること。
: > "$GEMINI_LOG"
reset_codex_barrier
rm -f "$TMP/gemini-count"
echo 2 > "$TMP/gemini-fail-nth"
rm -rf "$REPO/.review-results"
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --mode distributed --strategy minimize_cost --base develop --timeout 60 \
  >"$TMP/run2.log" 2>&1
RUN2_RC=$?
set -e
rm -f "$TMP/gemini-fail-nth"
if [[ $RUN2_RC -ne 0 ]]; then
  ok "タスク失敗があると全体 rc が非 0"
else
  bad "タスク失敗があるのに全体 rc=0（失敗の沈黙）"
fi
GEMINI_STARTS2="$(/usr/bin/grep -c '^start ' "$GEMINI_LOG")" || GEMINI_STARTS2=0
if [[ "$GEMINI_STARTS2" -ge 3 ]]; then
  ok "失敗タスクの後続も実行される（gemini 起動 ${GEMINI_STARTS2} 回 — ワーカーは失敗で止まらない）"
else
  bad "失敗タスクの後続が実行されていない（gemini 起動 ${GEMINI_STARTS2} 回）"
fi
# `❌` はタスク失敗とプラン構築時の通知の両方に使われる。素のまま数えると
# 「CLI が未インストール」通知が混ざり、しかもそれが出るかはホストにその CLI が
# 入っているかで変わるため、検査が実機依存になる（実測: grok 導入済みなら
# `❌ Failed: grok-cli/...`、未導入なら `❌ grok-cli (grok) — not installed` が出て
# **どちらでも 2 件**になり、期待の 1 件が成立しない）。上の PATH 制限で未インストール
# 側に固定したうえで、計数からその 1 行だけを除く。
#
# **許可リスト（`❌ Failed:` だけ数える）にはしない。** orchestrator はタスク失敗を
# 5 通りの文言で報告する — Failed / Timed out after / No output file /
# Worker died before recording a status / Corrupt-empty status file。1 形だけを数えると
# 残り 4 形が無検査になり、gemini 以外のタスクが timeout しても本数 1 のまま通る。
# 除外側を「プラン時の通知」1 種に限る形なら、将来 orchestrator が新しい失敗文言を
# 足しても自動的に数えられる（増えた分は本数超過として赤くなる = fail-closed）。
FAILED_LINES="$(/usr/bin/grep '❌' "$TMP/run2.log" | /usr/bin/grep -vc -- '— not installed')" || FAILED_LINES=0
if [[ "$FAILED_LINES" -eq 1 ]] && /usr/bin/grep -q '❌.*gemini-cli/' "$TMP/run2.log"; then
  ok "失敗が 1 件だけ・gemini のタスク名で名指しされる"
else
  bad "失敗の名指しが期待と違う（未インストール通知を除く ❌ 行 ${FAILED_LINES} 件）"
  /usr/bin/grep '❌' "$TMP/run2.log" | sed 's/^/    | /' >&2
fi

# orchestrator 自身が数えた件数でも裏を取る。上の ❌ 計数は行の**書式**に依存する
# （除外パターンが文言変更で外れると計数が狂う）が、集約行は orchestrator の
# 内部カウンタという単一の情報源なので、書式の変更と件数の変化を切り分けられる。
if /usr/bin/grep -qE '^⚠️ +1 review task\(s\) failed\.' "$TMP/run2.log"; then
  ok "orchestrator の集約も失敗 1 件と報告する（❌ 計数の裏取り）"
else
  bad "orchestrator の集約が失敗 1 件と報告していない"
  /usr/bin/grep -E 'task\(s\) failed' "$TMP/run2.log" | head -2 | sed 's/^/    | /' >&2
fi

echo
echo "== 実行環境の PATH からの独立 =="
# 上の全実行が PATH を絞れていれば、ホスト模擬 grok は一度も呼ばれない。
# `$STUB:$PATH` へ戻す退行が入るとここに起動記録が残る — ホストに grok が無い
# 環境でも赤くなるので、この検査は実機の導入状況に依存しない。
HOSTMOCK_CALLS="$(/usr/bin/grep -c '^invoked ' "$HOSTMOCK_LOG")" || HOSTMOCK_CALLS=0
if [[ "$HOSTMOCK_CALLS" -eq 0 ]]; then
  ok "ホスト模擬 grok が一度も起動されない（起動 PATH に実行環境の PATH が混ざっていない）"
else
  bad "ホスト模擬 grok が ${HOSTMOCK_CALLS} 回起動された — 起動 PATH に実行環境の PATH が混ざっている（\$STUB:\$PATH への退行）"
fi
# 未インストール扱いが実際に成立していることも確かめる。上の検査だけだと、grok が
# そもそもプランに現れない形（観点の割り当てが変わる等）でも緑になるため。
if /usr/bin/grep -q 'grok-cli (grok) — not installed' "$TMP/run2.log"; then
  ok "grok が未インストールとして扱われている（前提が実際に作られている）"
else
  bad "grok の未インストール通知が無い — 前提が成立していない可能性がある"
  /usr/bin/grep -E 'grok' "$TMP/run2.log" | head -3 | sed 's/^/    | /' >&2
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-serialization verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ multi-agent-serialization verify: 全 $PASS 件 pass"
FF_REACHED_END=1
