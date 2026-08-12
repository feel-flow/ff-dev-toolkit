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
#
# 実 CLI は 1 つも起動しない（全 CLI を stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

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
# codex（standard tier）にも start/end ログを持たせる — 「逐次化は free-tier
# **限定**で、standard はタスク並列のまま」という設計判断を固定するため。
# 一律逐次化への退行が入ると、codex の 2 タスクが交差しなくなりここが赤くなる。
CODEX_LOG="$TMP/codex-events.log"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
echo "start \$\$" >> "$CODEX_LOG"
sleep 0.6
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
PLAN_OUT="$(run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --mode distributed --strategy minimize_cost --base develop --dry-run 2>&1)"
PLAN_RC=$?
set -e
if [[ $PLAN_RC -ne 0 ]]; then
  bad "dry-run が非 0 終了した (rc=$PLAN_RC)"
  printf '%s\n' "$PLAN_OUT" | tail -10 | sed 's/^/    | /' >&2
fi

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
rm -rf "$REPO/.review-results"
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
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

# tier 限定の対称検査: codex（standard）の 2 タスクは並列のまま = 交差が**ある**こと。
# 0.6 秒の滞留窓に対して spawn スキューはミリ秒オーダーなので、並列なら交差する。
#
# この前提は外部負荷に弱い。spawn スキューが滞留窓（0.6 秒）を超えると、並列に
# 起動していても交差が記録されず「並列が維持されていない」と**偽陽性**で赤くなる
# （実装は正しいのにこの検査だけが鳴る）。
# 実測: CPU を全コアの 2 倍に過負荷にしても再現しなかった（11 件 pass）。別の
# エージェントや AI CLI を多数同時に走らせている環境で本 suite が赤くなった実績が
# あるが、11 件のどれが落ちたかは記録が残っていない（Issue #411）。
# **この検査が赤くなったら、まず実行環境の負荷を疑うこと** — オーケストレータの
# 逐次化ロジックを触る前に、単独実行で再現するかを確かめる。
# 滞留窓を広げれば頑健になる。**止めている理由は実行時間ではない** — 2 つの stub を
# 0.6 → 0.9 秒にして実測したが、スイート全体の所要は変わらなかった（0.9 秒版
# 27.2 / 27.3 秒、0.6 秒版 27.5 秒。ただし 0.6 秒版が 40.1 秒かかった回もあり、実行ごとの
# ばらつきのほうが効果より大きい）。理由は**検出力**のほうで、窓を広げると本物の
# 逐次化退行もその中で交差して見えるようになる。決定的な作りへの変更は #415。
CODEX_STARTS="$(/usr/bin/grep -c '^start ' "$CODEX_LOG")" || CODEX_STARTS=0
if [[ "$CODEX_STARTS" -ge 2 ]]; then
  ok "前提: codex（standard）に ${CODEX_STARTS} タスク（並列維持の検査対象）"
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
else
  bad "前提が崩れた: codex のタスク数が ${CODEX_STARTS}（プラン形の変更を確認して本 suite を追随させること）"
fi

echo "== 途中失敗後の継続と失敗の名指し =="

# 2 回目の gemini タスクだけ失敗させる。逐次ワーカーはタスク失敗で止まらず
# 残りを実行し、失敗は 1 件として名指しされ、全体 rc は非 0 になること。
: > "$GEMINI_LOG"
rm -f "$TMP/gemini-count"
echo 2 > "$TMP/gemini-fail-nth"
rm -rf "$REPO/.review-results"
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
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
FAILED_LINES="$(/usr/bin/grep -c '❌' "$TMP/run2.log")" || FAILED_LINES=0
if [[ "$FAILED_LINES" -eq 1 ]] && /usr/bin/grep -q '❌.*gemini-cli/' "$TMP/run2.log"; then
  ok "失敗が 1 件だけ・gemini のタスク名で名指しされる"
else
  bad "失敗の名指しが期待と違う（❌ 行 ${FAILED_LINES} 件）"
  /usr/bin/grep '❌' "$TMP/run2.log" | sed 's/^/    | /' >&2
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-serialization verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ multi-agent-serialization verify: 全 $PASS 件 pass"
FF_REACHED_END=1
