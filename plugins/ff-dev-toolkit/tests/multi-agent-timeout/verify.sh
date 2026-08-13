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
# 実 CLI は 1 つも起動しない。全 CLI のコマンド名を stub で覆い、課金や
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

# ---- 実行環境からの分離（Issue #378） --------------------------------------------
# MULTI_AGENT_CODEX_PROFILE が export された環境では、codex アダプタの profile 実在
# 検査（Issue #239 系の仕様どおり fail-closed）がホストの $CODEX_HOME / ~/.codex に
# 向かい（本 suite は HOME を差し替えない）、設定が解決できない環境では timeout/crash
# 等のシナリオが「プロファイル不在エラー」にすり替わって前提が崩れる。解決できる
# 環境でも stub の argv に -p が混入して被検体の挙動が env 依存になるため、いずれに
# せよ分離が要る。orchestrator は MULTI_AGENT_CONFIG / MULTI_AGENT_REVIEW_MAIN 等も
# 読むため、抽出対象は multi-agent.sh とアダプタ実装の両方に広げる。センチネルは
# orchestrator 専用変数とアダプタ変数の 2 本 — 片方のソースだけ引数から落ちる形を
# 単一センチネルでは検出できない。方式の詳細は lib 側ヘッダー参照。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE FF_TIMEOUT_KILL_GRACE" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

# ホスト由来の値を **suite の先頭で 1 回だけ** 落とす。probe() は `( source ...; 関数 )`
# の形でプロセス内から run_with_timeout を呼ぶため env -u が構造的に届かず、そこだけ
# ホストの FF_TIMEOUT_* が生き残っていた（実測: FF_TIMEOUT_KILL_GRACE=1 でこのケース
# だけが赤くなる）。
#
# **probe() の内側で unset してはいけない。** 内側から見るとホスト由来の値と
# `FF_TIMEOUT_KILL_GRACE=2 probe ...` というケース固有の前置代入は区別できず、後者まで
# 消える。そうなるとシームが既定値へ戻り、シーム自体が壊れても検査が通る（= 検出力を
# 失う）うえ SIGKILL 昇格ケースが grace 10 秒ぶん余計に待つ。先頭で 1 回落としておけば、
# 前置代入は代入として subshell へ届く（実測: ホスト 99 は消え、ケース固有 2 は届く）。
# run_isolated と同じ意味論 — ホストの値は除き、ケース固有の上書きは通す。
unset_isolated_vars

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

for adapter in claude-code codex-cli copilot-cli gemini-cli grok-cli; do
  hdr="$PLUGIN_ROOT/scripts/adapters/${adapter}-adapter.sh"
  if grep -qE "^#   --timeout <seconds>.*default: ${CANON}([^0-9]|$)" "$hdr"; then
    ok "${adapter}-adapter.sh のヘッダー既定が一致 (${CANON})"
  else
    bad "${adapter}-adapter.sh のヘッダー既定が SSOT (${CANON}) と一致しない"
    grep -nE '^#   --timeout' "$hdr" >&2 || true
  fi
done

# CLI 別の timeout 上限は存在しない（唯一持っていた cursor-cli は issue #240 で削除）。
# 上限を再導入するなら orchestrator 側（報告・助言の正本）に置くこと。アダプタだけで
# 黙って clamp すると、ログに出る秒数や提示コマンドが実際に適用された値とずれる。
#
# 検出するのは**定数名ではなく挙動**。削除前の実装（cursor-cli-adapter.sh）はこうだった:
#     readonly DEFAULT_CURSOR_TIMEOUT="${FF_CURSOR_TIMEOUT_CAP:-120}"
#     if [[ "$TIMEOUT" -gt "$DEFAULT_CURSOR_TIMEOUT" ]]; then
#       TIMEOUT="$DEFAULT_CURSOR_TIMEOUT"
# 定数名は `DEFAULT_CURSOR_TIMEOUT` で `_TIMEOUT_CAP` では終わらない。名前で探す検査は
# この実装を素通りする（初版がまさにそれで、再混入させても緑のままだった）。clamp の
# 本体は「TIMEOUT への再代入」なので、そこを禁じる。インラインのリテラル比較で
# clamp する変種も、代入が要る以上ここで捕まる。
#
# TIMEOUT を代入してよいのは adapter-common.sh だけ（既定値と --timeout の解釈）。
#
# grep の rc を 0 / 1 / それ以外で分岐する。`|| true` で丸めると rc=2（対象ファイルが
# 無い・読めない・glob が展開されなかった）が rc=1（不一致）と同じ「検出なし」に見え、
# 検査が走っていないのに緑になる（Issue #152 と同じ形）。本 Part は一時ディレクトリを
# 使わない静的検査なので、stderr はファイルに落とさず rc だけで判定する。
CLAMP_HITS=""
CLAMP_RC=0
CLAMP_HITS="$(grep -rnE '^[[:space:]]*TIMEOUT=' "$PLUGIN_ROOT"/scripts/adapters/*-adapter.sh 2>/dev/null)" || CLAMP_RC=$?
if [[ "$CLAMP_RC" -eq 0 ]]; then
  bad "アダプタが TIMEOUT を再代入している（orchestrator が報告する秒数と食い違う）:"
  printf '%s\n' "$CLAMP_HITS" | sed 's/^/      /' >&2
elif [[ "$CLAMP_RC" -eq 1 ]]; then
  ok "アダプタが TIMEOUT を再代入していない（clamp はオーケストレータの責務）"
else
  bad "TIMEOUT 再代入の検査自体が失敗した（grep rc=${CLAMP_RC}。対象 glob が展開されていない可能性）"
fi

# 空出力パス（rc=0 + stdout 空）の保全パターンは 5 アダプタへ手で写されている
# （feel-flow/ff-dev-toolkit#6 の残件対応）。behavioral ケース（Part B の empty）は
# codex-cli しか通らないため、残り 4 本は片側だけ旧実装へ戻っても緑のまま退行する
# — 実際に gemini だけ戻す mutation が全件 pass を維持した。写し崩れの本体は
# (a) record_timeout_reason empty-output の消失と (b) stderr_log の破棄（最後の
# rm -f）が空出力チェックより前へ動くことの 2 点なので、行順で静的にピン留めする。
# grep が失敗した場合（対象ファイル欠落・読取不能を含む）は変数が空になり bad へ
# 落ちるため、rc の丸めが偽緑を作ることはない。
for adapter in claude-code codex-cli copilot-cli gemini-cli grok-cli; do
  f="$PLUGIN_ROOT/scripts/adapters/${adapter}-adapter.sh"
  reason_line=""
  reason_line="$(grep -n 'record_timeout_reason empty-output' "$f" 2>/dev/null | head -1 | cut -d: -f1)" || true
  rm_line=""
  rm_line="$(grep -n 'rm -f "\$stderr_log"' "$f" 2>/dev/null | tail -1 | cut -d: -f1)" || true
  if [[ -n "$reason_line" && -n "$rm_line" && "$reason_line" -lt "$rm_line" ]]; then
    ok "${adapter}: 空出力パスが stderr_log を保全してから破棄する"
  else
    bad "${adapter}: empty-output 保全パターンが崩れている (reason=${reason_line:-なし} rm=${rm_line:-なし})"
  fi
done

# --help の表示（利用者が最初に見る値）
HELP_OUT="$(run_isolated bash "$MULTI_AGENT" --help 2>/dev/null || true)"
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
# **すべての**文書で成立していないと意味がない。実際、複数の CLI 別ページに同じ
# 曖昧な言い回し（「利用不可の場合…フォールバックします」）が双子で存在し、
# レビュアーが指した 1 ファイルだけ直すと残りが黙って矛盾したままになった。
# だから対象はファイル名直書きではなく glob で拾う（CLI の増減で検査対象が
# 抜け落ちないため）。
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

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
# **mktemp の成功は「TMPDIR が使える」を意味しない。** BSD mktemp はテンプレート無しだと
# TMPDIR が書き込み不可でも実 temp（/var/folders）へ黙って fallback する（実測）。
# 一方この suite が検査するアダプタは reason ファイルを `${TMPDIR:-/tmp}/` に置くため、
# TMPDIR が書けないと理由が記録されず、timeout/crash の区別を見る 5 件だけが赤くなる
# — ゲートは通ったのに検査対象は動かない、という食い違いになる（Issue #382）。
# ゲートが見るものを、suite が実際に必要とするもの（TMPDIR へ書けるか）に合わせる。
# 環境都合の skip は「ここから先を実行しない」だけであって、**既に検出した失敗を
# 取り消す権限は無い**。Part C の静的検査 30 件はこのゲートより手前で走り終えており、
# bad() は FAIL を増やすだけで止めないため、素の `exit 0` は本物の退行（SSOT と
# agent-config.yaml の timeout 乖離など）を「環境都合の skip」へ洗浄してしまう。
# しかも run-all はそれを failed ではなく skipped に数えるので、他 suite が緑なら
# 全体も緑になる（実測: 同一の変異が TMPDIR 書込可では rc=1 / 書込不可では rc=0）。
# #405 で潰した「途中死が rc=0 で pass と報告される」と同じ形が、suite の内側で
# 再発している状態。skip 行を出したまま非 0 で終えてよい — run-all は非 0 を
# 無条件に failed へ数える（skip マーカーの有無を見るのは rc=0 の場合だけ）。
_ff_skip_guard() {
  [ "$FAIL" -eq 0 ] && return 0
  echo "✗ multi-agent-timeout: 環境都合でスキップしますが、既に ${FAIL} 件の失敗を検出済みです（skip では消しません）" >&2
  exit 1
}

_ff_tmpdir="${TMPDIR:-/tmp}"
# 固定名 + `: >` で試さないこと。予測可能な名前を共有ディレクトリ（TMPDIR 既定は
# /tmp）へ作るため、先回りで同名のシンボリックリンクを置かれるとリンク先を切り詰める
# （実測: 用意した canary ファイルが空になる）。**テンプレート付き** mktemp は
# 排他生成なのでこの経路が無く、しかもテンプレートを与えた場合は上で述べた fallback を
# **しない** — 書けない TMPDIR では失敗する。つまり「安全に作る」と「TMPDIR の書き込み
# 可否を測る」が同じ 1 呼び出しで両立する。失敗理由は 2>&1 で同じ変数に受ける
# （捨てると read-only 以外の失敗まで「書き込み不可」へ誤帰属する）。
if _ff_probe="$(mktemp "${_ff_tmpdir%/}/.ff-timeout-writable.XXXXXX" 2>&1)"; then
  rm -f "$_ff_probe"
else
  # 文言は「ここから先が成立しない」までに留める。直前の静的検査（Part C）は既に
  # 走っているので、「1 件も実行していない」と書くと診断が事実と食い違う。skip
  # マーカーを出す以上ランナー上は suite 全体が skip として数えられる（部分 skip の
  # 扱いは下の mktemp 分岐と同じ判断）が、出力そのものが嘘をつく必要はない。
  echo "○ skip: TMPDIR へ書き込めない環境のためスキップ（一時ディレクトリを要する実行検査は 1 件も実行されていません）"
  printf '  TMPDIR: %s（アダプタはここへ reason ファイルを置くため、書けないと timeout/crash の区別が成立しない）\n' "$_ff_tmpdir"
  printf '  mktemp: %s\n' "$_ff_probe"
  FF_REACHED_END=1
  _ff_skip_guard
  exit 0
fi

if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  # 部分 skip でこのマーカーを出すと suite 全体が skip 扱いになり、上の Part C が
  # 走ったことが報告から消える。ここは検証本体が丸ごと成立しないケースなので出す。
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  _ff_skip_guard
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
    echo "✗ multi-agent-timeout: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

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
  # ここは同じプロセス内で source して関数を直接呼ぶ経路なので env -u が届かない。
  # ホスト由来の値は suite 先頭の unset_isolated_vars で既に落としてある（ここで
  # unset するとケース固有の前置代入まで消える。理由は先頭の注記を参照）。
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
# 全 CLI のコマンド名を覆い、実 CLI が起動しないことを構造で保証する。
# codex 以外は呼ばれたら invoked-<name> を残すので、意図しない fallback を検出できる。
#
# stub 名を手で持つと CLI を足したときに漏れ、その CLI だけ実物が課金付きで起動する
# ——「実 CLI は 1 つも起動しない」という本 suite の前提が静かに壊れる形。ALL_CLIS を
# 正本から読んで突き合わせる。
STUB="$TMP/stub-bin"
mkdir -p "$STUB"

REGISTRY_CLIS="$(awk -F'"' '/^ALL_CLIS=/ { print $2; exit }' "$MULTI_AGENT")"
REGISTRY_COMMANDS="$(
  awk '/^get_cli_command\(\)/ { inside = 1; next }
       inside && /^}/ { exit }
       inside && match($0, /echo "[a-z0-9-]+"/) {
         cmd = substr($0, RSTART + 6, RLENGTH - 7)
         if (cmd != "") print cmd
       }' "$MULTI_AGENT" | sort -u | tr '\n' ' '
)"
STUB_NAMES="claude codex copilot gemini grok"
if [ "$(printf '%s\n' $REGISTRY_COMMANDS | sort -u | tr -d ' \n')" \
   = "$(printf '%s\n' $STUB_NAMES | sort -u | tr -d ' \n')" ]; then
  ok "stub の CLI コマンド名が get_cli_command の全 arm を覆っている (${STUB_NAMES})"
else
  bad "stub の CLI コマンド名がレジストリと不一致 — 覆えていない CLI は実物が起動する"
  echo "      レジストリ: ${REGISTRY_COMMANDS}" >&2
  echo "      stub:       ${STUB_NAMES}" >&2
fi
[ -n "$REGISTRY_CLIS" ] || bad "ALL_CLIS を読めない（stub 網の検査が空振りしている）"

for name in claude copilot gemini grok; do
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
printf '%s\n' "\$@" > "$TMP/codex-argv"
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
  empty)
    # exit 0 かつ stdout 空。原因（レート制限・認証切れ等）は stderr にしか出ない
    # — feel-flow/ff-dev-toolkit#6 の残件が踏む形そのもの。
    echo "stub: rate limited - no review produced" >&2
    ;;
  empty-silent)
    # exit 0・stdout も stderr も完全に空。成果物のバナーが「存在しない stderr
    # 抜粋」を案内しないことを見る（案内文が虚空を指すと、最も診断が要る成果物が
    # 読み手を実在しないセクションへ送る）。
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
  run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout "$to" >"$TMP/run.log" 2>&1
  rc=$?
  set -e
  end="$(date +%s)"
  echo "$rc $((end - start))"
}

no_other_cli_invoked() {
  local n
  for n in claude copilot gemini grok; do
    [ -e "$TMP/invoked-$n" ] && return 1
  done
  return 0
}

# ブランチ差分が空で作業ツリーだけに変更がある pre-commit 経路。実行ガードと
# prompt builder のどちらか一方だけが BASE...HEAD に戻る変異を、起動 rc と実際に
# stub CLI へ渡ったプロンプトの両方で検出する。
WORKTREE_ONLY_REPO="$TMP/worktree-only-repo"
git init -q "$WORKTREE_ONLY_REPO"
git -C "$WORKTREE_ONLY_REPO" config user.email "test@example.com"
git -C "$WORKTREE_ONLY_REPO" config user.name "multi-agent-timeout-test"
git -C "$WORKTREE_ONLY_REPO" config commit.gpgsign false
git -C "$WORKTREE_ONLY_REPO" switch -q -c develop
echo base > "$WORKTREE_ONLY_REPO/app.txt"
echo base > "$WORKTREE_ONLY_REPO/unstaged.txt"
git -C "$WORKTREE_ONLY_REPO" add app.txt unstaged.txt
git -C "$WORKTREE_ONLY_REPO" commit -qm "init"
git -C "$WORKTREE_ONLY_REPO" switch -q -c feature/worktree-only
echo worktree-only-review-marker >> "$WORKTREE_ONLY_REPO/app.txt"
git -C "$WORKTREE_ONLY_REPO" add app.txt
echo unstaged-only-review-marker >> "$WORKTREE_ONLY_REPO/unstaged.txt"
echo ok > "$TMP/codex-mode"
rm -f "$TMP/invoked-codex" "$TMP/codex-argv"
WORKTREE_ONLY_RC=0
( cd "$WORKTREE_ONLY_REPO" && run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout 10 >"$TMP/worktree-only.log" 2>&1 ) || WORKTREE_ONLY_RC=$?
if [ "$WORKTREE_ONLY_RC" -eq 0 ] && [ -e "$TMP/invoked-codex" ]; then
  ok "作業ツリーだけに変更がある review も空振りせず CLI を起動する"
else
  bad "作業ツリーだけの変更で review が起動しない (rc=${WORKTREE_ONLY_RC})"
  sed 's/^/    | /' "$TMP/worktree-only.log" >&2
fi
if grep -q "worktree-only-review-marker" "$TMP/codex-argv" \
   && grep -q "unstaged-only-review-marker" "$TMP/codex-argv"; then
  ok "staged / unstaged の両 diff が実際のレビュープロンプトへ入る"
else
  bad "ガードは通ったが staged / unstaged の片方がレビュープロンプトに無い（空 diff の silent success）"
  sed 's/^/    | /' "$TMP/codex-argv" >&2
fi

# staged は pre-commit 用の第一級 diff source。作業ツリーの unstaged 変更やブランチ差分を
# 混ぜると「コミットしようとしている内容」以外をレビューするため、prompt 実体で分離する。
rm -f "$TMP/invoked-codex" "$TMP/codex-argv"
STAGED_RC=0
( cd "$WORKTREE_ONLY_REPO" && run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --staged --timeout 10 >"$TMP/staged.log" 2>&1 ) || STAGED_RC=$?
if [ "$STAGED_RC" -eq 0 ] && [ -e "$TMP/invoked-codex" ]; then
  ok "--staged で staged 変更に対する review が起動する"
else
  bad "--staged review が起動しない (rc=${STAGED_RC})"
  sed 's/^/    | /' "$TMP/staged.log" >&2
fi
if grep -q "worktree-only-review-marker" "$TMP/codex-argv" \
   && ! grep -q "unstaged-only-review-marker" "$TMP/codex-argv"; then
  ok "--staged の prompt は index 差分だけを含み unstaged を混ぜない"
else
  bad "--staged の prompt が staged / unstaged の境界を守っていない"
  sed 's/^/    | /' "$TMP/codex-argv" >&2
fi

rm -f "$TMP/invoked-codex" "$TMP/codex-argv"
STAGED_BASE_RC=0
( cd "$WORKTREE_ONLY_REPO" && run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --staged --base develop --timeout 10 >"$TMP/staged-base.log" 2>&1 ) || STAGED_BASE_RC=$?
if [ "$STAGED_BASE_RC" -ne 0 ] && [ ! -e "$TMP/invoked-codex" ]; then
  ok "--staged と --base の同時指定を CLI 起動前に拒否する"
else
  bad "--staged と --base の同時指定が素通りした (rc=${STAGED_BASE_RC})"
fi

git -C "$WORKTREE_ONLY_REPO" restore --staged app.txt
rm -f "$TMP/invoked-codex" "$TMP/codex-argv"
EMPTY_STAGED_RC=0
( cd "$WORKTREE_ONLY_REPO" && run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --staged --timeout 10 >"$TMP/staged-empty.log" 2>&1 ) || EMPTY_STAGED_RC=$?
if [ "$EMPTY_STAGED_RC" -eq 0 ] && [ ! -e "$TMP/invoked-codex" ] \
   && grep -q "No staged changes" "$TMP/staged-empty.log"; then
  ok "staged 変更が無いときは明示 skip + rc=0 で CLI を起動しない"
else
  bad "空 staged の skip 契約が崩れた (rc=${EMPTY_STAGED_RC})"
  sed 's/^/    | /' "$TMP/staged-empty.log" >&2
fi

# 和集合の反対側も固定する。上の BASE...HEAD=空ケースだけでは、実装を git diff HEAD
# のみにしても緑になる。コミット済み・staged・unstaged の3層を同居させ、どれかを
# 落とす変異をプロンプト実体で検出する。
UNION_REPO="$TMP/union-repo"
git init -q "$UNION_REPO"
git -C "$UNION_REPO" config user.email "test@example.com"
git -C "$UNION_REPO" config user.name "multi-agent-timeout-test"
git -C "$UNION_REPO" config commit.gpgsign false
git -C "$UNION_REPO" switch -q -c develop
echo base > "$UNION_REPO/base.txt"
echo base > "$UNION_REPO/unstaged.txt"
git -C "$UNION_REPO" add base.txt unstaged.txt
git -C "$UNION_REPO" commit -qm "init"
git -C "$UNION_REPO" switch -q -c feature/union
echo committed-review-marker > "$UNION_REPO/committed.txt"
git -C "$UNION_REPO" add committed.txt
git -C "$UNION_REPO" commit -qm "committed change"
echo staged-review-marker > "$UNION_REPO/staged.txt"
git -C "$UNION_REPO" add staged.txt
echo unstaged-review-marker >> "$UNION_REPO/unstaged.txt"
rm -f "$TMP/invoked-codex" "$TMP/codex-argv"
UNION_RC=0
( cd "$UNION_REPO" && run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout 10 >"$TMP/union.log" 2>&1 ) || UNION_RC=$?
if [ "$UNION_RC" -eq 0 ] \
   && grep -q "committed-review-marker" "$TMP/codex-argv" \
   && grep -q "staged-review-marker" "$TMP/codex-argv" \
   && grep -q "unstaged-review-marker" "$TMP/codex-argv"; then
  ok "コミット済み・staged・unstaged の和集合がレビュープロンプトへ入る"
else
  bad "レビュー範囲の3層和集合から差分が欠落した (rc=${UNION_RC})"
  sed 's/^/    | /' "$TMP/union.log" >&2
  sed 's/^/    | /' "$TMP/codex-argv" >&2
fi
cd "$REPO"

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
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
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
ALT_OUT="$REPO/alt-results"
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
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

# --- ケース2e: CLI が exit 0 のまま何も出力しない（stderr にのみ原因） ---
# feel-flow/ff-dev-toolkit#6 の残件。この経路で stderr_log を先に rm すると、原因を
# 語る唯一のチャネルが消え、成果物も残らない。「CLI は正常終了したのに何も言わな
# かった」は最も診断が要る状況であり、他の失敗経路と同じ保全（INCOMPLETE 成果物 +
# stderr 抜粋）を受けるべき。
echo empty > "$TMP/codex-mode"
read -r RC EL <<<"$(run_orchestrator 60)"

if [[ "$RC" -ne 0 ]]; then
  ok "empty: orchestrator が非 0 終了 (rc=$RC)"
else
  bad "empty: 空出力なのに 0 終了した"
fi

if [[ -f "$RESULT_FILE" ]] && grep -q '^<!-- Status: incomplete -->$' "$RESULT_FILE"; then
  ok "empty: 結果ファイルが Status: incomplete で生成される（空振りしない）"
else
  bad "empty: 結果ファイルが生成されない（診断情報ゼロの silent failure が再発）"
fi

if [[ -f "$RESULT_FILE" ]] && grep -q 'exited successfully but produced no output' "$RESULT_FILE"; then
  ok "empty: 理由が empty-output として記録される"
else
  bad "empty: 空出力の理由が成果物に残らない"
fi

# 原因は stderr にしか出ていない。ここが読めることが本ケースの主眼。
if [[ -f "$RESULT_FILE" ]] && grep -q 'stub: rate limited' "$RESULT_FILE"; then
  ok "empty: CLI の stderr が成果物に保全される（原因が後から読める）"
else
  bad "empty: stderr が破棄され、なぜ空だったかが読めない"
fi

if [[ -f "$RESULT_FILE" ]] && ! grep -q 'timed out' "$RESULT_FILE"; then
  ok "empty: timeout と誤表示されない"
else
  bad "empty: 空出力が timeout として誤表示された"
fi

# ケース 2f の「抜粋を案内しない」否定検査の正アンカー。文言が変わって否定検査が
# 空回りする退行をここで検出する。
if [[ -f "$RESULT_FILE" ]] && grep -q 'stderr excerpt below' "$RESULT_FILE"; then
  ok "empty: stderr があるときはバナーが抜粋の存在を案内する"
else
  bad "empty: stderr があるのにバナーが抜粋を案内しない（or 文言が変わった）"
fi

# 人間が実際に読む面（統合レポート）まで未完了バナーが届くこと。成果物側だけ見て
# いると、レポートが「クラッシュ」文言のままでも緑になる。
if [[ -f "$REPORT_FILE" ]] && grep -q 'finding here means unchecked, not clean' "$REPORT_FILE"; then
  ok "empty: 統合レポートが未完了であることを明示する"
else
  bad "empty: 統合レポート側の未完了バナーが出ていない"
fi

# 時間を足しても直らない失敗に「時間を足せ」と案内しないこと（crash と同じ性質）。
# 否定形単独だと案内ブロックごと消えた退行でも緑になるため、肯定とペアで照合する。
if grep -q 'failed for a reason more time will not fix' "$TMP/run.log" \
  && ! grep -q -- '--timeout 120' "$TMP/run.log"; then
  ok "empty: 時間延長ではなく原因確認を案内する"
else
  bad "empty: 時間を足しても直らない空出力に時間延長を案内している（or 案内自体が消えた）"
fi

if target_cli_invoked && no_other_cli_invoked; then
  ok "empty: 対象 CLI は起動し、実行時 fallback は起きていない（他 CLI は未起動）"
else
  bad "empty: 対象 CLI 未起動 or 設定 fallback が黙って実行された"
fi

# --- ケース2f: exit 0・stdout も stderr も空 ---
# empty-output バナーの「the reason is in the stderr excerpt below」は、stderr が
# 空だと抜粋セクション自体が付かず、読み手を実在しないセクションへ送る。stderr の
# 有無でバナーを出し分けることを固定する。
echo empty-silent > "$TMP/codex-mode"
read -r RC EL <<<"$(run_orchestrator 60)"

if [[ "$RC" -ne 0 ]]; then
  ok "empty-silent: orchestrator が非 0 終了 (rc=$RC)"
else
  bad "empty-silent: 空出力なのに 0 終了した"
fi

if [[ -f "$RESULT_FILE" ]] && grep -q '^<!-- Status: incomplete -->$' "$RESULT_FILE"; then
  ok "empty-silent: stderr も空でも成果物は残る"
else
  bad "empty-silent: stderr が空だと成果物が残らない"
fi

if [[ -f "$RESULT_FILE" ]] && grep -q 'wrote nothing to stdout or stderr' "$RESULT_FILE"; then
  ok "empty-silent: 原因を捕捉できなかったことを明示する"
else
  bad "empty-silent: 原因未捕捉の明示がない"
fi

if [[ -f "$RESULT_FILE" ]] && ! grep -q 'stderr excerpt below' "$RESULT_FILE"; then
  ok "empty-silent: 存在しない stderr 抜粋を案内しない"
else
  bad "empty-silent: バナーが実在しない stderr 抜粋セクションを指している"
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
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
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

# --- ケース5b: 分離の自己検証（Issue #378） ---
# ホスト汚染を意図的に再現し、run_isolated のラップが起動経路から落ちる退行を
# クリーンな環境でも検出する（落ちているとこのケースだけ汚染が漏れて赤くなる）。
# 存在しないプロファイル名はアダプタの fail-closed 実在検査に、存在しない config
# パスは orchestrator の設定読込にそれぞれ引っかかるため、adapter 側・orchestrator
# 側どちらのラップ欠落も成功ケースの失敗として現れる。adapter-model-args の
# 自己汚染ケースと同じ前置代入イディオム（関数実行中だけ環境へ export される）。
echo ok > "$TMP/codex-mode"
read -r RC EL <<<"$(MULTI_AGENT_CODEX_PROFILE=isolation-selftest-no-such-profile \
  MULTI_AGENT_CONFIG="$TMP/no-such-config.yaml" run_orchestrator 60)"
if [[ "$RC" -eq 0 ]] && target_cli_invoked; then
  ok "isolation: 汚染を前置しても正常完了ケースが影響を受けない（除去が効いている）"
else
  bad "isolation: 汚染が漏れている — run_isolated のラップが起動経路から落ちていないか (rc=$RC)"
  tail -5 "$TMP/run.log" | sed 's/^/    | /' >&2 || true
fi

# ケース6（cursor-cli の上限が実際に適用されること）は issue #240 で削除した。
# 上限を持つ CLI がもう無いので、上限の適用経路そのものが存在しない。
# 「報告される秒数が実際に適用された秒数と一致する」という本来の性質は、上の
# --timeout 3 のケース群（並列・逐次とも 'Timed out after 3s' を照合）が押さえて
# いる。上限を再導入するときは、値の一致だけでなく適用の挙動をここで固定すること
# — 値だけ見る検査では「上限を無視する退行」も「延ばせない CLI に --timeout を
# 倍にせよと案内する退行」も丸ごと素通りする。

# ════════════════════════════════════════════════════════════════════════════
# Part D: timeout-reason ライフサイクル + build_prompt 失敗の保全（Issue #266 / #267）
# ════════════════════════════════════════════════════════════════════════════

echo "== timeout-reason lifecycle / build_prompt fail-closed =="

# --- D1: record_timeout_reason の書き込み失敗が警告を出す（#266） ---
# 親ディレクトリが無いパスへ書いて失敗させる（TMPDIR 全体を壊す必要はない）。
export FF_TIMEOUT_REASON_FILE="$TMP/no-such-parent/reason-marker"
# サブシェルで source し、本 suite の EXIT trap を上書きしない。
# stderr を stdout に合流させてから捕捉する（`) 2>&1` は $() の外側で、
# 警告が親の stderr に漏れて捕捉ゼロになる）。
# shellcheck disable=SC1090
set +e
WARN_OUT="$(
  exec 2>&1
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  record_timeout_reason empty-output
  true
)"
set -e
unset FF_TIMEOUT_REASON_FILE
# パイプ + grep -q は case 10 の禁止形（SIGPIPE 反転）。シェル内マッチを使う。
if [[ $'\n'"$WARN_OUT"$'\n' == *$'\n'"WARNING: could not record timeout reason"* ]] \
  || [[ "$WARN_OUT" == *"WARNING: could not record timeout reason"* ]]; then
  ok "timeout-reason: 書き込み失敗時に stderr へ WARNING が 1 行出る"
else
  bad "timeout-reason: 書き込み失敗が無警告のまま（#266）"
  printf '%s\n' "$WARN_OUT" | sed 's/^/    | /' >&2
fi

# --- D2: 成功パスで reason ファイルが残留しない（#266 / EXIT trap） ---
SUCCESS_REASON="$TMP/reason-on-success"
rm -f "$SUCCESS_REASON"
(
  export FF_TIMEOUT_REASON_FILE="$SUCCESS_REASON"
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  record_timeout_reason command
  [[ -f "$SUCCESS_REASON" ]] || { echo "marker missing before exit" >&2; exit 2; }
  # 正常終了 → EXIT trap が clear_timeout_reason する
  FF_REACHED_END=1
  exit 0
)
if [[ ! -f "$SUCCESS_REASON" ]]; then
  ok "timeout-reason: 成功パス終了後に reason ファイルが残留しない"
else
  bad "timeout-reason: 成功パスで reason ファイルが残留している（#266）"
fi

# --- D3: build_prompt 失敗時に INCOMPLETE + orchestrator 起因（#267） ---
# 5 アダプタすべてを欠落 perspective で直接起動する。CLI は stub で preflight を通す。
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
# bash 3.2 互換のため連想配列は使わない
ADAPTER_KEYS="claude-code codex-cli copilot-cli gemini-cli grok-cli"
build_prompt_ok=0
build_prompt_fail=0
for key in $ADAPTER_KEYS; do
  case "$key" in
    claude-code) stub_cmd=claude ;;
    codex-cli)   stub_cmd=codex ;;
    copilot-cli) stub_cmd=copilot ;;
    gemini-cli)  stub_cmd=gemini ;;
    grok-cli)    stub_cmd=grok ;;
  esac
  adapter_sh="$ADAPTERS_DIR/${key}-adapter.sh"
  out_file="$TMP/build-prompt-${key}.md"
  rm -f "$out_file"
  # 欠落 perspective。build_prompt → load_perspective が return 1。
  set +e
  run_isolated PATH="$STUB:$PATH" GROK_HOME="$TMP/grok-home-empty" bash "$adapter_sh" \
    "$TMP/no-such-perspective-file.md" "$out_file" \
    --timeout 30 --base develop >"$TMP/bp-${key}.log" 2>&1
  bp_rc=$?
  set -e
  if [[ "$bp_rc" -ne 0 ]] \
    && [[ -f "$out_file" ]] \
    && grep -q 'orchestrator' "$out_file" \
    && grep -qE 'INCOMPLETE|Status: incomplete' "$out_file"; then
    build_prompt_ok=$((build_prompt_ok + 1))
  else
    build_prompt_fail=$((build_prompt_fail + 1))
    bad "build_prompt: ${key} が INCOMPLETE/orchestrator 成果物を残さない (rc=${bp_rc})"
    sed 's/^/    | /' "$TMP/bp-${key}.log" | tail -20 >&2 || true
    [[ -f "$out_file" ]] && sed 's/^/    | /' "$out_file" | head -20 >&2 || true
  fi
done
if [[ "$build_prompt_fail" -eq 0 && "$build_prompt_ok" -eq 5 ]]; then
  ok "build_prompt: 5 アダプタすべてが欠落 perspective で INCOMPLETE + orchestrator を残す"
fi

# 静的: 5 アダプタが if ! prompt="$(build_prompt ...)" 形を保っていること
# （素の prompt="$(build_prompt ...)" へ戻す退行を検出）
static_bp_ok=1
for key in $ADAPTER_KEYS; do
  adapter_sh="$ADAPTERS_DIR/${key}-adapter.sh"
  if ! grep -q 'if ! prompt="$(build_prompt' "$adapter_sh"; then
    bad "build_prompt: ${key} が fail_orchestrator_error 経路の wrap を失っている"
    static_bp_ok=0
  fi
  if grep -E '^\s*prompt="\$\(build_prompt' "$adapter_sh"; then
    bad "build_prompt: ${key} に bare の prompt=\"\$(build_prompt ...)\" が残っている"
    static_bp_ok=0
  fi
done
if [[ "$static_bp_ok" -eq 1 ]]; then
  ok "build_prompt: 5 アダプタすべてが if ! prompt= 形で wrap している"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-timeout verify: $FAIL 件失敗（詳細: 直近の実行ログ抜粋）" >&2
  tail -40 "$TMP/run.log" >&2
  exit 1
fi
echo "✓ multi-agent-timeout verify: 全 $PASS 件 pass"
FF_REACHED_END=1
