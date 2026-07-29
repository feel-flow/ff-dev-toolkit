#!/usr/bin/env bash
#
# multi-agent の timeout / 実行時失敗の回帰テスト（Issue #152）。
#
# 潰している事故は 3 つ。表に出た形はそれぞれ違う:
#
#   A. 早く終わっても timeout 全尺待つ（症状: レビューが常に上限秒数かかる）—
#      旧 run_with_timeout は watchdog の `sleep` に呼び出し側の `$(...)` キャプチャ
#      パイプを継がせていた。watchdog を kill しても `sleep` は孤児として生き残り
#      パイプを掴み続けるため、2 秒で答えた CLI でも制限秒数ぶん待たされた
#      （`timeout(1)` を持つホストでは発生しない。stock macOS が該当）。この状態で
#      既定値を上げると全レビューが必ずその分遅くなるので、timeout 既定値の
#      引き上げは本修正と不可分だった。
#   B. timeout と異常終了が区別できない（症状: 誤った次の一手を案内する）— 旧実装は
#      kill 経路で素の 1 を返していた。「時間切れで途中まで進んだ」と「起動時に
#      落ちた」が同じに見えるので、時間を延ばすべきかどうかを出し分けられなかった。
#   C. 捕まえた partial 出力を捨てていた（症状: レビューを 1 本まるごと失い、レポートに
#      理由が出ない）— adapter の失敗経路は `result` を握ったまま exit しており、
#      300 秒ぶんの Codex の作業がまるごと消え、結果ファイルは 1 つもできなかった。
#      Issue #152 の「空振り」の直接原因はこれ。
#
# さらに「実行時 fallback は行わない」という方針そのものを検査する。設定の
# `fallback:` は**未インストール時のプラン構築専用**で、インストール済み CLI の
# 実行時失敗を別モデルへ振り替えることはしない（理由は multi-agent.sh のヘッダー）。
# 黙って振り替わっていないことをテストで固定しないと、方針は文書だけの約束になる。
#
# 実 CLI は 1 つも起動しない。5 つの CLI コマンド名すべてを stub で覆い、課金や
# ネットワークを伴わずに orchestrator の分岐だけを動かす。
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
AGENT_CONFIG="$PLUGIN_ROOT/scripts/agent-config.yaml"
COMMAND_DOC="$PLUGIN_ROOT/skills/multi-review/SKILL.md"
DOC_REVIEW="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-review-orchestration.md"
DOC_AGENT="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-agent-orchestration.md"

for f in "$MULTI_AGENT" "$ADAPTER_COMMON" "$AGENT_CONFIG" "$COMMAND_DOC" "$DOC_REVIEW" "$DOC_AGENT"; do
  [ -f "$f" ] || { echo "✗ 対象ファイルが見つかりません: $f" >&2; exit 1; }
done

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ════════════════════════════════════════════════════════════════════════════
# Part C: 既定 timeout の三者一致（SSOT / config / 利用者向け文書）
# 一時ディレクトリを要らないので先に走らせる（read-only 環境でも必ず通る検査）。
# ════════════════════════════════════════════════════════════════════════════

echo "== 既定 timeout の一致 =="

# DEFAULT_TIMEOUT_REVIEW を書き換えたら、置き換えた**前**の値をここに移すこと。
# 「新しい値が載っている」だけの検査だと、古い値が別行に残っても緑になる。
PREVIOUS_DEFAULT_REVIEW_TIMEOUT=300

read_default() { # $1: review|explore|implement
  local key
  key="$(echo "$1" | awk '{print toupper($0)}')"
  grep -E "^readonly DEFAULT_TIMEOUT_${key}=" "$MULTI_AGENT" \
    | sed -E 's/^readonly [A-Z_]+=([0-9]+).*/\1/'
}

CANON="$(read_default review)"
if [[ "$CANON" =~ ^[0-9]+$ ]] && [[ "$CANON" -gt 0 ]]; then
  ok "SSOT を読めた: DEFAULT_TIMEOUT_REVIEW=${CANON}"
else
  bad "multi-agent.sh から DEFAULT_TIMEOUT_REVIEW を読めない（抽出結果: '${CANON}'）"
  echo "✗ 以降の一致検査を行えません" >&2
  exit 1
fi

# agent-config.yaml の tasks.<task>.timeout（yq に依存しないよう awk で読む）
read_config_timeout() {
  awk -v want="  $1:" '
    $0 == want { f = 1; next }
    f && /^    timeout:/ { print $2; exit }
    f && /^  [a-z]/ { exit }
  ' "$AGENT_CONFIG"
}

# review だけでなく explore / implement も照合する。SSOT のコメントは「defaults」と
# 複数形で宣言しているので、1 つしか見ていないと宣言だけが正しい状態になる。
for task in review explore implement; do
  ssot="$(read_default "$task")"
  cfg="$(read_config_timeout "$task")"
  if [[ -n "$ssot" && "$cfg" == "$ssot" ]]; then
    ok "agent-config.yaml tasks.${task}.timeout が一致 (${cfg})"
  else
    bad "agent-config.yaml tasks.${task}.timeout が不一致: config=${cfg} SSOT=${ssot}"
  fi
done

# アダプタ単独実行時の既定（orchestrator は常に --timeout を明示で渡すため、この値は
# 直叩き専用）。ここが 300 のまま残ると、ヘッダーが案内している使い方だけが
# Issue #152 の原因値で動き続ける。
ADAPTER_DEFAULT="$(grep -E '^[[:space:]]*TIMEOUT="\$\{REVIEW_TIMEOUT:-[0-9]+\}"' "$ADAPTER_COMMON" \
  | sed -E 's/.*REVIEW_TIMEOUT:-([0-9]+).*/\1/')"
if [[ "$ADAPTER_DEFAULT" == "$CANON" ]]; then
  ok "adapter-common.sh の REVIEW_TIMEOUT 既定が一致 (${ADAPTER_DEFAULT})"
else
  bad "adapter-common.sh の REVIEW_TIMEOUT 既定が不一致: adapter=${ADAPTER_DEFAULT} SSOT=${CANON}"
fi

for adapter in claude-code codex-cli copilot-cli gemini-cli; do
  hdr="$PLUGIN_ROOT/scripts/adapters/${adapter}-adapter.sh"
  if grep -qE "^#   --timeout <seconds>.*default: ${CANON}([^0-9]|$)" "$hdr"; then
    ok "${adapter}-adapter.sh のヘッダー既定が一致 (${CANON})"
  else
    bad "${adapter}-adapter.sh のヘッダー既定が SSOT (${CANON}) と一致しない"
    grep -nE '^#   --timeout' "$hdr" >&2 || true
  fi
done

# cursor-cli の上限は orchestrator（報告・助言の正本）とアダプタ（直叩き用）の
# 2 箇所にある。食い違うと、ログに出る秒数や提示コマンドが実際に適用された値と
# ずれる（まさに本 PR が直した種類の嘘）。
CAP_ORCH="$(grep -E '^readonly CURSOR_TIMEOUT_CAP=' "$MULTI_AGENT" \
  | sed -E 's/.*:-([0-9]+)\}.*/\1/')"
CAP_ADAPTER="$(grep -E '^readonly DEFAULT_CURSOR_TIMEOUT=' "$PLUGIN_ROOT/scripts/adapters/cursor-cli-adapter.sh" \
  | sed -E 's/.*:-([0-9]+)\}.*/\1/')"
if [[ -n "$CAP_ORCH" && "$CAP_ORCH" == "$CAP_ADAPTER" ]]; then
  ok "cursor-cli の timeout 上限が orchestrator とアダプタで一致 (${CAP_ORCH})"
else
  bad "cursor-cli の timeout 上限が不一致: orchestrator=${CAP_ORCH} adapter=${CAP_ADAPTER}"
fi

# --help の表示（利用者が最初に見る値）
HELP_OUT="$(bash "$MULTI_AGENT" --help 2>/dev/null || true)"
if [[ "$HELP_OUT" == *"review ${CANON}"* ]]; then
  ok "--help が review ${CANON} を表示"
else
  bad "--help に 'review ${CANON}' が出ていない"
fi

# 利用者向け文書に新しい値が載っていること。
# timeout 文脈の行に限って照合する。ファイル全体を対象にすると、無関係な箇所の
# 900 でも通るうえ、下の「旧既定値が残っていない」検査と前提がずれる。
for doc in "$COMMAND_DOC" "$DOC_REVIEW" "$DOC_AGENT"; do
  ctx="$(grep -icE 'timeout|タイムアウト' "$doc" || true)"
  hit="$(grep -iE 'timeout|タイムアウト' "$doc" | grep -c "$CANON" || true)"
  if [[ "$ctx" -gt 0 && "$hit" -gt 0 ]]; then
    ok "$(basename "$doc") の timeout 文脈に ${CANON} が載っている"
  else
    # ctx=0 は「timeout に触れる行が 1 行も無い」状態。旧値検査も空前提で通って
    # しまうので、ここで落とす（文書の作り替えで検査が無効化されるのを防ぐ）
    bad "$(basename "$doc") の timeout 文脈に ${CANON} が無い（timeout 文脈の行数=${ctx}）"
  fi
done

# 置き換えた前の既定値が timeout 文脈に残っていないこと（部分更新の検出）
for doc in "$COMMAND_DOC" "$DOC_REVIEW" "$DOC_AGENT" "$AGENT_CONFIG"; do
  # `-n` を付けないこと。行番号を前置すると「300 行目」のような行番号自体が旧既定値に
  # マッチして偽陽性になる（この検査で実際に踏んだ）。診断表示だけ -n 付きで出す。
  stale="$(grep -iE 'timeout|タイムアウト' "$doc" | grep -c "${PREVIOUS_DEFAULT_REVIEW_TIMEOUT}" || true)"
  if [[ "$stale" -eq 0 ]]; then
    ok "$(basename "$doc") の timeout 文脈に旧既定値 ${PREVIOUS_DEFAULT_REVIEW_TIMEOUT} が残っていない"
  else
    bad "$(basename "$doc") の timeout 文脈に旧既定値 ${PREVIOUS_DEFAULT_REVIEW_TIMEOUT} が ${stale} 行残っている"
    grep -inE 'timeout|タイムアウト' "$doc" | grep "${PREVIOUS_DEFAULT_REVIEW_TIMEOUT}" >&2 || true
  fi
done

echo ""

# ════════════════════════════════════════════════════════════════════════════
# Part C2: fallback の意味が文書間でぶれていないこと
#
# 「未インストール時のプラン構築限定」という区別は、multi-CLI の fallback を語る
# **すべての**文書で成立していないと意味がない。実際 cursor / gemini の CLI 別ページに
# 同じ曖昧な言い回し（「利用不可の場合…フォールバックします」）が双子で存在し、
# レビュアーが指した 1 ファイルだけ直すと残りが黙って矛盾したままになった。
#
# 判定は「fallback に触れているなら、区別語（未インストール）も書いてあること」。
# 特定の言い回しを禁止する形にすると表現替えで簡単に迂回されるので、必要な語の
# 存在を要求する側に倒す。
# ════════════════════════════════════════════════════════════════════════════

echo "== fallback の意味の一貫性 =="

DEPLOY_DIR="$PLUGIN_ROOT/docs-template/05-operations/deployment"
for doc in "$DEPLOY_DIR"/multi-cli-*.md "$DEPLOY_DIR"/*-cli-reviewer.md \
           "$PLUGIN_ROOT/docs-template/06-reference/REVIEW_AGENT_CREATION_GUIDE.md" \
           "$COMMAND_DOC"; do
  [[ -f "$doc" ]] || continue
  mentions="$(grep -c 'フォールバック\|fallback' "$doc" || true)"
  [[ "$mentions" -gt 0 ]] || continue
  if grep -q '未インストール' "$doc"; then
    ok "$(basename "$doc") が fallback をプラン構築時（未インストール）と明示している"
  else
    bad "$(basename "$doc") は fallback に触れているが未インストール限定であることを書いていない（実行時失敗にも効くと読める）"
  fi
done

echo ""

# ════════════════════════════════════════════════════════════════════════════
# ここから先は一時ディレクトリが必要
# ════════════════════════════════════════════════════════════════════════════

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  # 部分 skip でこのマーカーを出すと suite 全体が skip 扱いになり、上の Part C が
  # 走ったことが報告から消える。ここは検証本体が丸ごと成立しないケースなので出す。
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# Part A: run_with_timeout の単体挙動
# ════════════════════════════════════════════════════════════════════════════

echo "== run_with_timeout =="

# 実測を 1 ケース走らせて rc / 経過秒 / stdout を返すヘルパー。
# stdout はファイル経由で受け、パイプ越しの待ち合わせを持ち込まない。
probe() { # $1: 制限秒 / $2..: コマンド。出力: "rc elapsed" を stdout、本文を $TMP/probe.out
  local to="$1"; shift
  local start end rc=0
  start="$(date +%s)"
  set +e
  ( source "$ADAPTER_COMMON"; run_with_timeout "$to" "$@" ) >"$TMP/probe.out" 2>/dev/null
  rc=$?
  set -e
  end="$(date +%s)"
  echo "$rc $((end - start))"
}

read -r RC EL <<<"$(probe 20 bash -c 'echo HELLO; sleep 1; echo BYE')"
BODY="$(cat "$TMP/probe.out")"
# 上限 8 秒は「制限秒数（20）を待っていない」ことだけを見る幅。旧実装はここで必ず 20 秒。
if [[ "$RC" -eq 0 && "$EL" -lt 8 && "$BODY" == "HELLO
BYE" ]]; then
  ok "早く終われば早く返る（${EL}s < 制限 20s）／stdout 完全"
else
  bad "早期完了が制限秒数まで待たされた or 出力が欠けた (rc=$RC elapsed=${EL}s body=[${BODY//$'\n'/|}])"
fi

# grace を 2 秒に縮めて上限を締める。既定 10 秒のままだと正当な最長経路が
# 3 + 10 = 13 秒になり、20 秒上限では負荷時の余裕が薄い。
read -r RC EL <<<"$(FF_TIMEOUT_KILL_GRACE=2 probe 3 bash -c 'echo PARTIAL; sleep 30 >/dev/null 2>&1; echo NEVER')"
BODY="$(cat "$TMP/probe.out")"
if [[ "$RC" -eq 124 && "$EL" -lt 12 && "$BODY" == "PARTIAL" ]]; then
  ok "制限で打ち切り rc=124・partial を保全（${EL}s）"
else
  bad "timeout の rc/経過秒/partial が期待どおりでない (rc=$RC elapsed=${EL}s body=[${BODY//$'\n'/|}])"
fi

# 期限が来た「あとに」コマンドが自力で成功した場合を timeout に化けさせないこと。
# marker は「期限が経過した」を意味するだけなので、rc≠0 の条件を外すと正常終了が
# 124 に書き換わる。SIGTERM を無視して grace 内に完走する子で再現する。
read -r RC EL <<<"$(probe 1 bash -c 'trap "" TERM; sleep 3; echo DONE')"
BODY="$(cat "$TMP/probe.out")"
if [[ "$RC" -eq 0 && "$BODY" == "DONE" ]]; then
  ok "期限経過後に自力で成功した実行を timeout に化けさせない（rc=0 を維持）"
else
  bad "期限経過後の正常終了が timeout として扱われた (rc=$RC body=[${BODY//$'\n'/|}])"
fi

read -r RC EL <<<"$(probe 20 bash -c 'echo OUT; exit 3')"
if [[ "$RC" -eq 3 ]]; then
  ok "コマンド自身の終了コードを素通し (rc=3)"
else
  bad "終了コードが素通しされない (rc=$RC)"
fi

# 期限が来ていないのに外部から SIGKILL された場合を timeout と混同しないこと。
# 混同すると「時間を延ばせ」と案内して OOM 等の真因を埋める。marker は signal の
# 前に書かれるので、期限発火なら必ず 124 になる = 素の 137 は外部 kill を意味する。
read -r RC EL <<<"$(probe 30 bash -c 'echo BEFORE_KILL; kill -KILL $$')"
if [[ "$RC" -eq 137 ]]; then
  ok "期限前の外部 SIGKILL は 137 のまま（timeout に化けない）"
else
  bad "外部 SIGKILL の終了コードが 137 でない (rc=$RC)"
fi

# 孫プロセスまで止まること。直接の子だけに TERM を送ると、CLI が起動したワーカーが
# 期限後も走り続ける（従量課金 CLI では課金も続く）。プロセスグループへ送っている
# ことをここで固定する。
GC_LOG="$TMP/grandchild.log"
: > "$GC_LOG"
read -r RC EL <<<"$(probe 3 bash -c "bash -c 'while :; do echo tick >> \"$GC_LOG\"; sleep 1; done' >/dev/null 2>&1 & echo SPAWNED; wait")"
GC_AT_KILL="$(wc -l < "$GC_LOG" | tr -d ' ')"
sleep 3
GC_LATER="$(wc -l < "$GC_LOG" | tr -d ' ')"
if [[ "$RC" -eq 124 && "$GC_LATER" -eq "$GC_AT_KILL" ]]; then
  ok "孫プロセスもグループごと停止する（打ち切り後 ${GC_AT_KILL} 行から増えない）"
else
  bad "孫プロセスが期限後も生き残っている (rc=$RC 打ち切り時=${GC_AT_KILL} 3秒後=${GC_LATER})"
  # 生き残りを残したままにしない
  pkill -f "$GC_LOG" 2>/dev/null || true
fi

# SIGTERM を**無視する**孫が grace 後に SIGKILL されること。直接の子は TERM で死ぬので
# 親は即 wait から復帰し、watchdog の昇格をキャンセルする。この経路で昇格を親側が
# 引き取っていないと、TERM を無視するワーカーは期限後も無期限に生き残る。
# grace はテストシームで 2 秒に縮める（既定 10 秒だと suite が伸びるだけ）。
TRAP_LOG="$TMP/trapper.log"
: > "$TRAP_LOG"
read -r RC EL <<<"$(FF_TIMEOUT_KILL_GRACE=2 probe 2 bash -c "bash -c 'trap \"\" TERM; while :; do echo tick >> \"$TRAP_LOG\"; sleep 1; done' >/dev/null 2>&1 & echo SPAWNED; wait")"
TRAP_AT_RETURN="$(wc -l < "$TRAP_LOG" | tr -d ' ')"
sleep 3
TRAP_LATER="$(wc -l < "$TRAP_LOG" | tr -d ' ')"
if [[ "$RC" -eq 124 && "$TRAP_LATER" -eq "$TRAP_AT_RETURN" ]]; then
  ok "SIGTERM を無視する孫も grace 後に SIGKILL される（復帰後 ${TRAP_AT_RETURN} 行から増えない）"
else
  bad "SIGTERM を無視する孫が期限後も生き残っている (rc=$RC 復帰時=${TRAP_AT_RETURN} 3秒後=${TRAP_LATER})"
  pkill -f "$TRAP_LOG" 2>/dev/null || true
fi

# 終了コードの説明が用途ごとに分かれていること。124 だけが「時間を足す」案内の対象。
DESC_124="$( (source "$ADAPTER_COMMON"; describe_cli_failure 124 900) 2>/dev/null )"
DESC_137="$( (source "$ADAPTER_COMMON"; describe_cli_failure 137 900) 2>/dev/null )"
DESC_125="$( (source "$ADAPTER_COMMON"; describe_cli_failure 125 900) 2>/dev/null )"
DESC_1="$(   (source "$ADAPTER_COMMON"; describe_cli_failure 1 900)   2>/dev/null )"
if [[ "$DESC_124" == *"timed out after 900s"* ]] \
  && [[ "$DESC_137" != *"timed out"* ]] && [[ "$DESC_137" == *"SIGKILL"* ]] \
  && [[ "$DESC_125" == *"orchestrator"* ]] && [[ "$DESC_125" != *"timed out"* ]] \
  && [[ "$DESC_1" == *"exited with status 1"* ]]; then
  ok "終了コードの説明: 124=timeout / 137=SIGKILL / 125=orchestrator 起因 / 他=status"
else
  bad "終了コードの説明が期待どおりでない (124='${DESC_124}' 137='${DESC_137}' 125='${DESC_125}' 1='${DESC_1}')"
fi

# timeout(1) への分岐は持たない（= ホスト差で未検査になる経路が無い）。理由は
# adapter-common.sh の run_with_timeout ヘッダー参照: timeout(1) の終了コードでは
# 「期限で SIGKILL 昇格」と「外部からの SIGKILL」が区別できない（GNU coreutils 9.7
# 実測: 前者は 137 を返す）。分岐が残っていないことをここで固定する。
# コメント行は除外する（timeout(1) を使わない理由の説明そのものが `timeout -k` を
# 含むため）。判定は入力を読み切る `grep -c` で行い、`grep -q` の早期終了が上流を
# SIGPIPE で殺して pipefail のもとで結果を反転させる事故を避ける（ACE-149）。
# `-k` 付きに限らず `timeout <秒> cmd` 形式の委譲も捕まえる。
DELEGATES="$(grep -vE '^[[:space:]]*#' "$ADAPTER_COMMON" \
  | grep -cE '(^|[^A-Za-z_-])(timeout|gtimeout)[[:space:]]+(-k[[:space:]]|-[[:alnum:]]|"?\$|[0-9])' || true)"
if [[ "$DELEGATES" -eq 0 ]]; then
  ok "supervisor は単一実装（ホストにより未検査になる経路が無い）"
else
  bad "adapter-common.sh が timeout(1) へ委譲する分岐を持っている（終了コードで期限発火と外部 kill を判別できない）"
  grep -vE '^[[:space:]]*#' "$ADAPTER_COMMON" | grep -nE '(^|[^A-Za-z_-])(timeout|gtimeout)[[:space:]]' >&2 || true
fi

# marker は signal より前に書かれること。後ろだと、親が子を回収して watchdog を
# 停止するのが書き込みより先になり得て、timeout が crash として誤報告される。
# この順序は競合の窓が極端に狭く、160 回の mutation 実行でも再現しなかったため
# 行動テストでは固定できない（実測に基づく試行回数を出せない）。静的に固定する。
MARKER_ORDER="$(awk '
  /^[[:space:]]*sleep "\$timeout_seconds"/ { inwd = 1; next }
  inwd && /printf .timeout. >"\$marker"/   { print "marker"; exit }
  inwd && /kill -TERM/                      { print "kill"; exit }
' "$ADAPTER_COMMON")"
if [[ "$MARKER_ORDER" == "marker" ]]; then
  ok "watchdog は marker を signal より前に書く（timeout の crash 誤報告を防ぐ順序）"
else
  bad "watchdog の marker 書き込みが signal より後ろにある（timeout が crash として誤報告されうる）"
fi

echo ""

# ════════════════════════════════════════════════════════════════════════════
# Part B: orchestrator の実行時失敗の扱い（stub CLI）
# ════════════════════════════════════════════════════════════════════════════

echo "== orchestrator の実行時失敗 =="

# --- レビュー対象の差分を持つ一時リポジトリ ---
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "multi-agent-timeout-test"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange for review\n' > app.txt
git add app.txt
git commit -qm "change"

# --- stub CLI ---
# 5 つの CLI コマンド名すべてを覆い、実 CLI が起動しないことを構造で保証する。
# codex 以外は呼ばれたら invoked-<name> を残すので、意図しない fallback を検出できる。
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
for name in claude copilot gemini cursor-agent; do
  cat > "$STUB/$name" <<SH
#!/usr/bin/env bash
touch "$TMP/invoked-$name"
echo "stub $name should not have run"
SH
  chmod +x "$STUB/$name"
done

# codex stub の振る舞いは $TMP/codex-mode で切り替える
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
touch "$TMP/invoked-codex"
mode="\$(cat "$TMP/codex-mode")"
case "\$mode" in
  hang)
    echo "PARTIAL FINDING: started analysing"
    sleep 30 >/dev/null 2>&1
    echo "never reached"
    ;;
  crash)
    echo "boom: stub failure" >&2
    exit 1
    ;;
  ok)
    echo "## Findings"
    echo "- Suggestion: stub review completed"
    ;;
  quote-marker)
    # 完了レビューが本文でマーカー行を引用するケース（本ツールが自身のスクリプトを
    # レビューすると実際に起こる）。未完了として扱われてはいけない。
    # 行頭・行末が一致する形で出す: 前置きを付けると行アンカー付きの照合に当たらず、
    # 「判定範囲を本文まで広げる」退行を検出できない（テストが空回りする）。
    echo "レポートの未完了判定はこの行と一致するかを見る:"
    echo "<!-- Status: incomplete -->"
    echo "- Suggestion: stub review completed"
    ;;
  exit124)
    # 124 は慣習的に timeout 用だが、CLI が自分で返すことは禁じられていない
    echo "CLI chose to exit 124 itself"
    exit 124
    ;;
esac
SH
chmod +x "$STUB/codex"

# mktemp stub。$TMP/mktemp-mode が fail のときだけ失敗し、それ以外は実体へ委譲する。
# 実体の絶対パスは stub 生成時に焼き込む（PATH 経由で引くと自分自身を呼んで再帰する）。
REAL_MKTEMP="$(command -v mktemp)"
echo pass > "$TMP/mktemp-mode"
cat > "$STUB/mktemp" <<SH
#!/usr/bin/env bash
if [[ "\$(cat "$TMP/mktemp-mode" 2>/dev/null)" == "fail" ]]; then
  echo "mktemp: stubbed failure" >&2
  exit 1
fi
exec "$REAL_MKTEMP" "\$@"
SH
chmod +x "$STUB/mktemp"

RESULT_FILE="$REPO/.review-results/codex-cli/code-review.md"
REPORT_FILE="$REPO/.review-results/integrated-report.md"

run_orchestrator() { # $1: timeout 秒 / 出力: "rc elapsed"
  local to="$1" start end rc=0
  rm -f "$TMP/invoked-"*
  start="$(date +%s)"
  set +e
  PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout "$to" >"$TMP/run.log" 2>&1
  rc=$?
  set -e
  end="$(date +%s)"
  echo "$rc $((end - start))"
}

no_other_cli_invoked() {
  local n
  for n in claude copilot gemini cursor-agent; do
    [ -e "$TMP/invoked-$n" ] && return 1
  done
  return 0
}

# 対象 CLI が本当に起動したことも確認する。これが無いと「stub が一度も呼ばれて
# いないのに他 CLI も呼ばれていないので緑」という空回りが成立する。
target_cli_invoked() { [ -e "$TMP/invoked-codex" ]; }

# --- ケース1: CLI が制限時間内に終わらない ---
echo hang > "$TMP/codex-mode"
read -r RC EL <<<"$(run_orchestrator 3)"

if [[ "$RC" -ne 0 ]]; then
  ok "timeout: orchestrator が非 0 終了 (rc=$RC)"
else
  bad "timeout: 失敗したのに 0 終了した"
fi

# 上限 45 秒は「stub の 30 秒 sleep を待っていない」ことを見る幅
if [[ "$EL" -lt 45 ]]; then
  ok "timeout: 制限が実際に効いている（${EL}s、stub は 30s 走る）"
else
  bad "timeout: 制限が効かず stub の完走を待った (${EL}s)"
fi

if [[ -f "$RESULT_FILE" ]]; then
  ok "timeout: 結果ファイルが生成される（空振りしない）"
  if grep -q '^<!-- Status: incomplete -->$' "$RESULT_FILE"; then
    ok "timeout: ヘッダーに Status: incomplete が入る"
  else
    bad "timeout: Status: incomplete が入っていない"
  fi
  if grep -q 'INCOMPLETE' "$RESULT_FILE" && grep -q 'timed out after 3s' "$RESULT_FILE"; then
    ok "timeout: 本文に INCOMPLETE と理由（timed out after 3s）が入る"
  else
    bad "timeout: 本文の INCOMPLETE バナー／理由が欠けている"
  fi
  if grep -q 'PARTIAL FINDING' "$RESULT_FILE"; then
    ok "timeout: 打ち切り前の partial 出力が保全される"
  else
    bad "timeout: partial 出力が捨てられている"
  fi
else
  bad "timeout: 結果ファイルが生成されない（空振りが再発）"
fi

# レポート側バナー固有の文言で照合する。単に 'INCOMPLETE' を探すと、レポートは
# 結果ファイルを丸ごと cat するため結果ファイル側のバナーにマッチしてしまい、
# レポート側のバナーを削除しても緑のまま（自分の fixture にマッチする空回り）。
if [[ -f "$REPORT_FILE" ]] && grep -q 'finding here means unchecked, not clean' "$REPORT_FILE"; then
  ok "timeout: 統合レポートが未完了であることを明示する（レポート側バナー固有の文言で照合）"
else
  bad "timeout: 統合レポート側の未完了バナーが出ていない"
fi

if grep -q 'Timed out after 3s' "$TMP/run.log"; then
  ok "timeout: ログが timeout と異常終了を区別して表示する"
else
  bad "timeout: ログで timeout が異常終了と区別されていない"
fi

if grep -q 'No runtime fallback was attempted' "$TMP/run.log" \
  && grep -q -- '--cli claude-code' "$TMP/run.log"; then
  ok "timeout: fallback を行わない旨と、代替 CLI の明示実行コマンドを提示する"
else
  bad "timeout: 失敗時の次の一手（時間延長／代替 CLI 明示実行）が提示されない"
fi

# 提示コマンドがそのまま貼って動くこと。basename だけを出すと、プラグイン内の
# スクリプトを対象プロジェクトから実行している通常構成では即座に失敗する。
if grep -qF "$MULTI_AGENT" "$TMP/run.log"; then
  ok "timeout: 提示コマンドが実在する絶対パスを含む"
else
  bad "timeout: 提示コマンドのスクリプトパスが絶対パスでない（貼っても動かない）"
fi
if grep -qE '^ +bash multi-agent\.sh ' "$TMP/run.log"; then
  bad "timeout: 提示コマンドが basename だけ（対象プロジェクト側に同名ファイルは無い）"
else
  ok "timeout: 提示コマンドが basename 止まりになっていない"
fi
# --base を落とすと「失敗した実行の再試行」ではなく別の差分を見る実行になる
if grep -q -- '--base develop' "$TMP/run.log"; then
  ok "timeout: 提示コマンドが --base を引き継ぐ"
else
  bad "timeout: 提示コマンドが --base を落としている（別の差分を見る実行になる）"
fi

if target_cli_invoked && no_other_cli_invoked; then
  ok "timeout: 対象 CLI は起動し、実行時 fallback は起きていない（他 CLI は未起動）"
else
  bad "timeout: 対象 CLI 未起動 or 設定 fallback が黙って実行された"
fi

# --- ケース2: CLI が即座に異常終了 ---
echo crash > "$TMP/codex-mode"
read -r RC EL <<<"$(run_orchestrator 60)"

if [[ "$RC" -ne 0 ]]; then
  ok "crash: orchestrator が非 0 終了 (rc=$RC)"
else
  bad "crash: 失敗したのに 0 終了した"
fi

# 失敗経路にも経過秒の上限を置く。Issue #152 が実際に踏んだのはこの経路で、
# 「即座に落ちたのに制限秒数ぶん待たされる」退行がここだけ無検査だった。
if [[ "$EL" -lt 30 ]]; then
  ok "crash: 即座の失敗が制限秒数を待たない（${EL}s < 制限 60s）"
else
  bad "crash: 即座に失敗したのに制限秒数まで待たされた (${EL}s)"
fi

if [[ -f "$RESULT_FILE" ]] && grep -q 'exited with status 1' "$RESULT_FILE"; then
  ok "crash: 結果ファイルに異常終了として記録される（timeout と別表現）"
else
  bad "crash: 異常終了の理由が結果に残らない"
fi

if [[ -f "$RESULT_FILE" ]] && ! grep -q 'timed out' "$RESULT_FILE"; then
  ok "crash: timeout と誤表示されない"
else
  bad "crash: timeout として誤表示された"
fi

# 異常終了の原因は stdout ではなく stderr にしか出ないことが多い（認証切れなど）。
# 並列実行では orchestrator の出力は複数アダプタが混ざった非永続ストリームなので、
# stderr を成果物に残さないと後から原因が読めない。
if [[ -f "$RESULT_FILE" ]] && grep -q 'boom: stub failure' "$RESULT_FILE"; then
  ok "crash: CLI の stderr が成果物に保全される（原因が後から読める）"
else
  bad "crash: stderr が成果物に残らず、原因が非永続ストリームにしか出ていない"
fi

# 時間を足しても直らない失敗に「時間を足せ」と案内しないこと。
if grep -q 'failed for a reason more time will not fix' "$TMP/run.log" \
  && ! grep -q -- '--timeout 120' "$TMP/run.log"; then
  ok "crash: 時間延長ではなく原因確認を案内する"
else
  bad "crash: 時間を足しても直らない失敗に時間延長を案内している"
fi

if no_other_cli_invoked; then
  ok "crash: 実行時 fallback が起きていない（他 CLI は未起動）"
else
  bad "crash: 設定 fallback が黙って実行された"
fi

# --- ケース2b: CLI 自身が 124 / 125 を返した場合 ---
# 124 / 125 は「慣習的に空いている」だけで、CLI が自分で返すことは禁じられていない。
# 終了コードだけで判定すると、CLI の 124 が「期限が来た」に化けて「時間を足せ」と
# 誤誘導する。理由は out-of-band で運ぶので、ここは CLI 自身の終了として扱われるべき。
echo exit124 > "$TMP/codex-mode"
read -r RC EL <<<"$(run_orchestrator 60)"

if [[ "$RC" -ne 0 ]]; then
  ok "self-124: orchestrator が非 0 終了 (rc=$RC)"
else
  bad "self-124: 失敗したのに 0 終了した"
fi

if [[ -f "$RESULT_FILE" ]] \
  && grep -q "the CLI's own status, not a timeout" "$RESULT_FILE" \
  && ! grep -q 'timed out' "$RESULT_FILE"; then
  ok "self-124: CLI 自身の 124 を timeout と誤認しない"
else
  bad "self-124: CLI 自身の 124 が timeout として記録された"
fi

if ! grep -q 'Timed out after' "$TMP/run.log" && ! grep -q -- '--timeout 120' "$TMP/run.log"; then
  ok "self-124: 時間延長を案内しない（プロセス境界で終了コードを正規化）"
else
  bad "self-124: timeout 扱いのログ／時間延長の案内が出ている"
fi

# --- ケース2c: 一時ファイルが作れない環境 ---
# アダプタは run_with_timeout より先に stderr 用の mktemp を行う。ここが素の 1 で
# 死ぬと、orchestrator 起因の失敗が「CLI が status 1 で終了」として記録され、
# 成果物も残らない（125 の処理に到達できない）。
#
# 不正な TMPDIR では再現しない: macOS の BSD mktemp は TMPDIR が使えないと実 temp へ
# 落ちるだけで失敗しない。ホスト差に依らせないため mktemp 自体を stub で失敗させる
# （orchestrator は mktemp を呼ばないので、落ちるのはアダプタ側だけ）。
echo ok > "$TMP/codex-mode"
echo fail > "$TMP/mktemp-mode"
rm -f "$TMP/invoked-"*
set +e
PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --perspective code-review \
  --base develop --timeout 60 >"$TMP/run.log" 2>&1
RC=$?
set -e
echo pass > "$TMP/mktemp-mode"
if [[ "$RC" -ne 0 ]]; then
  ok "tmpdir: orchestrator が非 0 終了 (rc=$RC)"
else
  bad "tmpdir: 一時ファイルが作れないのに 0 終了した"
fi
if [[ -f "$RESULT_FILE" ]] && grep -q 'orchestrator' "$RESULT_FILE"; then
  ok "tmpdir: orchestrator 起因として成果物に記録される（CLI の失敗に化けない）"
else
  bad "tmpdir: orchestrator 起因の失敗が成果物に残らない or CLI の失敗として記録された"
fi

# --- ケース2d: 再実行コマンドが「何を見るか」を決めるフラグを引き継ぐ ---
# --output-dir / --include-diff が落ちると、提示コマンドは失敗した実行の再試行では
# なく別のタスクになる（--base と同じ種類の欠落）。
echo hang > "$TMP/codex-mode"
ALT_OUT="$TMP/alt-results"
set +e
PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task implement --description "stub task" --include-diff \
  --cli codex-cli --perspective refactoring \
  --base develop --output-dir "$ALT_OUT" --timeout 3 >"$TMP/run-impl.log" 2>&1
set -e
if grep -q -- '--include-diff' "$TMP/run-impl.log" && grep -qF -- "--output-dir" "$TMP/run-impl.log"; then
  ok "advice: --include-diff と --output-dir を再実行コマンドへ引き継ぐ"
else
  bad "advice: --include-diff / --output-dir が再実行コマンドから落ちている"
  grep -A3 'more time on the same CLI' "$TMP/run-impl.log" >&2 || true
fi

# --- ケース3: 正常完了（Bug A の回帰: 制限秒数を待たされない） ---
echo ok > "$TMP/codex-mode"
read -r RC EL <<<"$(run_orchestrator 60)"

if [[ "$RC" -eq 0 ]]; then
  ok "success: orchestrator が 0 終了"
else
  bad "success: 正常完了なのに非 0 終了 (rc=$RC)。ログ末尾: $(tail -5 "$TMP/run.log" | tr '\n' ' ')"
fi

# 上限 30 秒は「制限秒数（60）を待っていない」ことを見る幅。旧実装はここで必ず 60 秒。
if [[ "$EL" -lt 30 ]]; then
  ok "success: 制限秒数を待たずに完了する（${EL}s < 制限 60s）"
else
  bad "success: 早期完了なのに制限秒数まで待たされた (${EL}s)"
fi

if [[ -f "$RESULT_FILE" ]] \
  && grep -q '^<!-- Status: complete -->$' "$RESULT_FILE" \
  && grep -q 'stub review completed' "$RESULT_FILE"; then
  ok "success: 結果ファイルが complete として保存される"
else
  bad "success: 正常結果の保存 or Status: complete が期待どおりでない"
fi

if [[ -f "$RESULT_FILE" ]] && ! grep -q 'INCOMPLETE' "$RESULT_FILE"; then
  ok "success: 正常結果に INCOMPLETE バナーが付かない"
else
  bad "success: 正常結果が未完了として表示された"
fi

# --- ケース4: 完了レビューが本文でマーカー行を引用している ---
echo quote-marker > "$TMP/codex-mode"
read -r RC EL <<<"$(run_orchestrator 60)"

if [[ "$RC" -eq 0 ]]; then
  ok "quote-marker: マーカーを引用した完了レビューでも 0 終了"
else
  bad "quote-marker: 完了レビューなのに非 0 終了 (rc=$RC)"
fi
if [[ -f "$REPORT_FILE" ]] && ! grep -q 'finding here means unchecked, not clean' "$REPORT_FILE"; then
  ok "quote-marker: 本文の引用を未完了と誤判定しない（判定はヘッダー範囲に限定）"
else
  bad "quote-marker: 完了レビューが未完了として表示された（判定範囲が本文まで及んでいる）"
fi

# --- ケース5: --sequential 経路 ---
# 既定は parallel なので、逐次経路は別に踏まないと未検査のまま残る（実際に
# 「逐次経路へ実行時 fallback を差し込む」mutation が緑のままだった）。
echo hang > "$TMP/codex-mode"
rm -f "$TMP/invoked-"*
set +e
PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --sequential --cli codex-cli --perspective code-review \
  --base develop --timeout 3 >"$TMP/run-seq.log" 2>&1
RC=$?
set -e
if [[ "$RC" -ne 0 ]] && grep -q 'Timed out after 3s' "$TMP/run-seq.log"; then
  ok "sequential: timeout を並列経路と同じ表現で報告する"
else
  bad "sequential: 非 0 終了 or timeout 表現が並列経路と揃っていない (rc=$RC)"
fi
if target_cli_invoked && no_other_cli_invoked; then
  ok "sequential: 実行時 fallback が起きていない（他 CLI は未起動）"
else
  bad "sequential: 対象 CLI 未起動 or 設定 fallback が黙って実行された"
fi

# --- ケース6: cursor-cli の上限が実際に適用され、助言も上限を踏まえること ---
# 上限は 2 秒へ縮めて実行する（実寸 120 秒を待たずに適用経路を踏むため）。
# 上限の「値の一致」だけを検査していると、上限を無視する退行や「延ばせない CLI に
# --timeout を倍にせよ」と案内する退行が丸ごと検出できない。
cat > "$STUB/cursor-agent" <<SH
#!/usr/bin/env bash
touch "$TMP/invoked-cursor-agent"
echo "CURSOR PARTIAL"
sleep 30 >/dev/null 2>&1
SH
chmod +x "$STUB/cursor-agent"
rm -f "$TMP/invoked-"*
set +e
FF_CURSOR_TIMEOUT_CAP=2 PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli cursor-cli --perspective code-simplification \
  --base develop --timeout 60 >"$TMP/run-cursor.log" 2>&1
RC=$?
set -e
if [[ "$RC" -ne 0 ]] && grep -q 'Timed out after 2s' "$TMP/run-cursor.log"; then
  ok "cap: 実効値（上限 2s）で打ち切り、実効値で報告する"
else
  bad "cap: 上限が適用されない or 実行全体の --timeout 60 を報告している (rc=$RC)"
  grep -E '❌|Timed out' "$TMP/run-cursor.log" >&2 || true
fi
if grep -q 'cannot extend it' "$TMP/run-cursor.log" && ! grep -q -- '--timeout 120' "$TMP/run-cursor.log"; then
  ok "cap: 上限付き CLI に --timeout での延長を案内しない"
else
  bad "cap: 従っても効かない --timeout 延長を案内している"
  grep -A3 'cursor-cli/code-simplification' "$TMP/run-cursor.log" >&2 || true
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-timeout verify: $FAIL 件失敗（詳細: 直近の実行ログ抜粋）" >&2
  tail -40 "$TMP/run.log" >&2
  exit 1
fi
echo "✓ multi-agent-timeout verify: 全 $PASS 件 pass"
