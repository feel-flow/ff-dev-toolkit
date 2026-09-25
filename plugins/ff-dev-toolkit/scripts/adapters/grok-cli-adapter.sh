#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# grok-cli-adapter.sh — Multi-CLI Agent: Grok CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./grok-cli-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --staged                  Review only staged changes (mutually exclusive with --base)
#   --timeout <seconds>       Timeout in seconds (default: 900; the orchestrator always passes this explicitly)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
#   --staging-dir <dir>       Absolute, existing, writable dir the agent writes generated
#                             files into (implement only; the orchestrator always passes it)
#   --inline-output           implement without a staging dir: the CLI reports file contents
#                             inline instead of writing them. An implement run with neither
#                             this nor --staging-dir is rejected (a dropped path must not
#                             silently degrade into inline mode)
#
# Plan-time probe (no perspective / output file):
#   ./grok-cli-adapter.sh --probe-sandbox [task-type]
#     Reports whether this environment can apply the sandbox profile this adapter
#     would request for <task-type> (default: review). Exit 3 = the sandbox this
#     adapter asks for will not be in effect here; exit 0 = nothing was determined.
#     The probe does NOT take --inline-output: it measures the profile for the
#     task-type the orchestrator passes, which is what the plan is about (for
#     implement, `workspace`). --inline-output would make the real run ask for
#     `read-only` instead; the probe does not model that, and no option is added
#     for it — the plan does not know that flag either. See run_sandbox_probe.
#
# Requires: grok (npm i -g @xai-official/grok)
# Cost tier: Flat-rate (subscription)
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"

readonly CLI_NAME="Grok CLI"
readonly CLI_COMMAND="grok"

# ── Preflight ──

if ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed." >&2
  echo "Install: npm install -g @xai-official/grok" >&2
  exit 1
fi

# ── Parse Arguments ──

# --probe-sandbox はタスクを走らせない別入口なので、観点ファイルも出力先も取らない。
# parse_adapter_args は両方を必須にしている（無ければ usage で rc=1）ため、この分岐は
# パーサーより前に置く。プロンプト構築も行わない — probe が見るのは
# 「この環境でサンドボックスを適用できるか」だけで、diff も観点も要らない。
PROBE_SANDBOX="false"
if [[ "${1:-}" == "--probe-sandbox" ]]; then
  PROBE_SANDBOX="true"
  TASK_TYPE="${2:-review}"
  INLINE_OUTPUT="false"
else
  parse_adapter_args "$@"

  # perspective_name は build_prompt 失敗時の fail_orchestrator_error にも要る。
  # build_prompt を mktemp ガードより前に素で呼ぶと set -e が bare exit し、
  # INCOMPLETE 成果物が残らない（プロンプト構築の失敗を無言の欠落にしないための順序）。
  perspective_name="$(basename "$PERSPECTIVE_FILE" .md)"

  # ── Build Prompt ──

  if ! prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"; then
    fail_orchestrator_error "$perspective_name" \
      "cannot build the ${TASK_TYPE:-review} prompt (perspective missing, empty diff, or load failure)."
  fi
fi

# ── Task-type specific sandbox ──
#
# grok's --sandbox takes a built-in profile name and is enforced by the kernel
# (Seatbelt on macOS, Landlock on Linux), so it holds for the agent's own file
# tools, anything it spawns through the shell, and MCP servers alike.
#
# Measured on grok 0.2.118, with the agent explicitly told to write and to fall
# back to the shell if its tools failed:
#   --sandbox read-only    → Write tool and printf/echo/touch/cp/dd/python/perl
#                            all returned "Operation not permitted". No file
#                            created, no file modified.
#   --permission-mode plan → the file WAS created and a.txt WAS appended to.
#                            Plan mode is not a write guard; do not use it here.
#   --tools <allowlist>    → blocks the built-in tools only. `--help` says
#                            "Built-in tools to allow", and the agent was
#                            observed reaching for an MCP server instead.
#
# Caveat when re-verifying: the read-only profile permits writes to /tmp,
# /var/tmp and ~/.grok by design. Running the check inside a temp directory
# reports a false negative — the first attempt here did exactly that.
#
# Provenance is stale and cannot be refreshed for free. The table above was
# measured on grok 0.2.118; a 1.0.5 install was observed on another machine
# (2026-08-26). Unlike codex — which ships `codex sandbox`, a subcommand that runs
# an arbitrary command under the same sandbox without invoking a model — grok has
# no way to exercise the WRITE rows offline: proving that a write is blocked needs
# an agent that attempts one, and that is a billed run. So the WRITE rows above are
# NOT re-measured beyond 0.2.118, and this comment does not claim they are.
#
# What IS available offline is narrower and is used by run_sandbox_probe below:
# whether the profile can be **applied at all** in this environment. That question
# is decided at startup, before any model call, so a non-agent subcommand answers
# it for free. Do not read the probe as reviving the write rows — it says nothing
# about what the applied profile then blocks.
#
# Network boundary (Issue #897, measured 2026-09-01 on grok 0.2.118, macOS
# seatbelt, billed runs — commands and results in
# tests/adapter-sandbox-contract/README.md):
#   --sandbox workspace  → ProfileApplied restrict_network:false, and an
#                          outbound HTTPS fetch to an external host SUCCEEDED.
#   --sandbox read-only  → ProfileApplied records restrict_network:true,
#                          enforced:true — and the same outbound HTTPS fetch
#                          STILL SUCCEEDED. The declaration and the effective
#                          boundary diverge on macOS; do not treat a
#                          restrict_network:true record as proof of isolation.
#   Fabrication was ruled out by having the sandboxed agent return the HTTP
#   Date response header, which landed between wall-clock timestamps taken
#   immediately before and after the read-only run.
# grok has no VERIFIED way to close the network: there is no codex-style
# `-c sandbox_workspace_write.network_access=false` equivalent, and while
# ~/.grok/sandbox.toml can define custom profiles, the read-only measurement
# above shows that a profile *recording* restrict_network:true still passes
# outbound HTTPS on macOS — so a custom profile pinning the same knob cannot
# be expected to hold either (custom-profile blocking itself is unmeasured).
# The asymmetry with codex implement (network pinned off) is therefore a
# measured, currently unfixable fact. The adapter therefore TELLS the user before every
# dispatch (see the notice below get_sandbox_profile) instead of silently
# running open — that notice is the "do not run open silently" half of the AC.
# This cannot become a standing gate: measuring requires a billed agent run,
# so it stays a recorded measurement, like the write rows above.
#
# Write-boundary narrowing (Issue #896): codex confines implement writes to the
# staging dir alone via `codex exec -C <staging>`. The equivalent for grok is
# UNMEASURED, not impossible. grok 1.0.5 does expose `--cwd <CWD>` ("Working
# directory"), so the mechanism plausibly exists — but whether the `workspace`
# profile's write root follows `--cwd` cannot be established without a billed
# run, for the reason above. Until someone measures it, the asymmetry stands and
# is intentional:
#
#   codex implement … writes confined to staging by the sandbox
#   grok  implement … writes confined to the repository by the sandbox;
#                     staging-only remains a prompt contract
#
# Do not narrow this adapter on the strength of the codex measurement. The two
# CLIs implement their sandboxes independently, and a `--cwd` that only relocated
# the CWD without moving the sandbox root would silently change nothing while the
# comment claimed otherwise.
# ── read-only スロットのプロファイル差し替え（docker.sock symlink 対応） ──
#
# 潰す事故: **review / explore レーンが、この機械では一度も走らない**。grok の
# `read-only` / `strict`（= `restrict_network:true` を持つ組み込み）は、コンテナ
# ランタイムのソケット（/var/run/docker.sock 等）への deny を張ってから起動する。
# その deny path を実体解決する際に **symlink を拒否する**ため、Docker Desktop の
# macOS 既定配置（/var/run/docker.sock → ~/.docker/run/docker.sock）では
# 「runtime-socket deny resolution failed: ... endpoint is a symlink」で起動拒否
# になる。`workspace` は restrict_network:false なので同じ機械で起動する。
#
# 実測（grok 1.0.30 / macOS seatbelt、2026-09-14、`grok --sandbox <p> inspect`）:
#   read-only / strict                          → rc=1 起動拒否（上の理由）
#   workspace                                   → rc=0
#   custom: extends=read-only                   → rc=1（deny を継承する）
#   custom: extends=read-only, restrict_network=false
#                                               → rc=0。ProfileApplied の
#                                                  read_write_paths は組み込み
#                                                  read-only と同一（CWD を含まない）
#   custom: extends=workspace, restrict_network=true
#                                               → rc=1（deny は restrict_network に
#                                                  連動しており、base には依らない）
# つまり deny を外せるのは `restrict_network=false` だけで、これは macOS では
# もともと no-op（ベンダー文書 18-sandbox.md「On macOS network blocking is a
# no-op」、および tests/adapter-sandbox-contract/README.md のネットワーク境界の実測: read-only でも外部 HTTPS が通る）。書き込み
# 境界は失わない — 同版の課金走行で、CWD への shell 書き込み・Write ツールとも
# "Operation not permitted" で失敗し FsViolation が記録された
# （tests/adapter-sandbox-contract/README.md）。
#
# 採らない回避: read-only → workspace への切り替え。レーンは動くが、動いているのは
# CWD 書き込みを許した別の保証の実行になる（multi-review SKILL.md が依拠する
# 「read-only サンドボックスで書き込みを失敗させる」が黙って外れる）。
#
# したがってアダプタは既定を `read-only` のまま変えず、利用者が ~/.grok/sandbox.toml
# （または <project>/.grok/sandbox.toml）に定義したカスタムプロファイル名を
# MULTI_AGENT_GROK_READONLY_PROFILE で受け取ったときだけ、**read-only スロット**
# （review / explore / implement --inline-output）をその名前へ差し替える。implement
# の `workspace` には触れない。fail-closed の 3 点:
#   1. 未設定なら `read-only`。workspace へ黙って降格する経路は無い
#   2. 書き込みを許す組み込み名（workspace / devbox）と無効化（off / none）は
#      名前の時点で拒否する（レーンを動かすためにそれを指すのが最短の誤用のため）
#   3. 名前だけでは custom の中身を保証できないので、実行後の ProfileApplied ゲートが
#      `read_write_paths` に作業ツリー（その祖先・配下を含む）が**含まれない**ことを要求する
#      （下の「Confirm the sandbox actually took effect」）。含まれていれば結果を
#      採用しない。ここが「read-only ではない」を機械的に検出する本体
readonly READONLY_PROFILE_ENV="MULTI_AGENT_GROK_READONLY_PROFILE"
readonly READONLY_PROFILE_DEFAULT="read-only"

# 成功時は stdout にプロファイル名を 1 つ書き rc=0。拒否時は stderr に理由、rc=2。
resolve_readonly_profile() {
  local value="${MULTI_AGENT_GROK_READONLY_PROFILE:-}"
  if [[ -z "$value" ]]; then
    echo "$READONLY_PROFILE_DEFAULT"
    return 0
  fi
  # grok のプロファイル名は sandbox.toml の table キー。argv に載せるので、フラグに
  # 化ける先頭 `-` や空白・引用符は名前として受け付けない。
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: ${READONLY_PROFILE_ENV}='${value}' is not a sandbox profile name (letters, digits, '.', '_', '-' only; must start with a letter or digit)." >&2
    return 2
  fi
  # strict も CWD への書き込みを許す（18-sandbox.md: "write CWD + ~/.grok/sessions +
  # temp dirs"）ので read-only の代替にはならない。
  case "$value" in
    workspace|devbox|strict|off|none)
      echo "ERROR: ${READONLY_PROFILE_ENV}='${value}' names a profile that permits writes to the working tree (or disables the sandbox)." >&2
      echo "       The read-only slot (review / explore) cannot be pointed at it. Define a custom profile" >&2
      echo "       in ~/.grok/sandbox.toml that extends \"read-only\" (see docs-template/05-operations/deployment/grok-cli-reviewer.md) and name that instead." >&2
      return 2
      ;;
  esac
  echo "$value"
}

# stdout にプロファイル名。read-only スロットで環境変数が不正なら rc=2（stderr に理由）。
# 呼び出し側は必ず失敗を受ける — set -e 下で素の command substitution に置くと
# bare exit で成果物が残らない。
get_sandbox_profile() {
  if [[ "${TASK_TYPE:-review}" == "implement" && "${INLINE_OUTPUT:-false}" == "true" ]]; then
    resolve_readonly_profile
    return
  fi
  case "${TASK_TYPE:-review}" in
    review)    resolve_readonly_profile ;;
    explore)   resolve_readonly_profile ;;
    # implement has to write its staging output, so it gets the profile that
    # allows CWD writes rather than no sandbox at all.
    #
    # `workspace` permits writes anywhere under the CWD. multi-agent.sh fixes that
    # CWD to REPO_ROOT and rejects output dirs outside it before launch; confining
    # writes from the whole repository to staging alone remains a prompt contract
    # here (see the note above on why the codex-style narrowing is not copied over).
    # MULTI_AGENT_GROK_READONLY_PROFILE はここに効かない（read-only スロット専用）。
    implement) echo "workspace" ;;
    *)         resolve_readonly_profile ;;
  esac
}

# 「read-only / workspace 以外の名前が入っている」= 名前では書き込み境界を保証できない
# 実行。ProfileApplied ゲートが read_write_paths の検査を追加で要求する。組み込みの
# strict / devbox / off / none もここでは custom 扱いになるが、read-only スロットへは
# resolve_readonly_profile が名前の時点で通さないので到達しない。
is_custom_readonly_profile() { # $1: profile
  case "$1" in
    read-only|workspace) return 1 ;;
    *) return 0 ;;
  esac
}

# ── Sandbox applicability probe（--probe-sandbox） ──
#
# 潰す事故: **プランには載るのに一度も走らない CLI**。サンドボックスを適用できない
# 環境では grok はモデルを呼ぶ前に起動を拒否する（status 1、stdout 空）。実行時の
# 検出は既にあるが、それが分かるのはタスクを 1 つ丸ごと失ったあとで、dry-run は
# 毎回「載る」としか言わない。起動前に決まっている失敗は起動前に言う。
#
# 課金しない probe が成立する理由（本実装の要点）。サンドボックスの適用は起動時に
# 済み、失敗すればそこで拒否される — つまり**エージェントを走らせないサブコマンド**
# でも同じ適用経路を踏む。実測（grok 0.2.118 / macOS seatbelt、2026-09-06。同じ
# 4 行を grok 1.0.30 で 2026-09-14 に再測: workspace は rc=0 で一致、read-only は
# この機械では rc=1 側へ落ちる（docker.sock symlink）、拒否時の stderr は warning 行に加えて
# "error: could not apply ..." 行が付く形へ変わった。probe の目印は行頭の warning /
# error の両方を見ているので判定は変わらない）:
#   grok --sandbox read-only inspect  → rc=0。sandbox-events.jsonl へ
#                                       ProfileApplied / enforced:true が 1 行増える。
#                                       モデル呼び出し・ネットワーク往復は無し
#                                       （1.0.30 では docker.sock が symlink の機械で
#                                       rc=1 側へ落ちる — 上の差し替えの節）
#   grok --sandbox workspace inspect  → rc=0（同上）
#   grok --sandbox <適用できない値> inspect
#                                     → rc=1、stderr に
#                                       "warning: sandbox could not be applied: ..." と
#                                       "error: could not apply the '<p>' sandbox
#                                       profile; ... Refusing to start with its
#                                       protections missing." — 観測台帳が記録した
#                                       実環境の失敗（runtime-socket の deny path が
#                                       symlink）と同じ形
# `inspect` を選ぶのは、設定探索を表示するだけでローカル完結だから。`models` は
# 同じくサンドボックスを適用するが認証済みアカウントへ問い合わせるので使わない。
# **`inspect` の現存は grok 0.2.118 と 1.0.30 で実測したもの**（`grok inspect --help`
# rc=0、`grok --help` の Commands 一覧に "inspect  Show the configuration Grok
# discovers for this directory"）で、ベンダーの互換保証ではない。
# 将来のバージョンで消える・改名されると probe は「目印が出ない」経路へ落ちて
# fail-open で黙る（= 警告が消えるだけで、赤くはならない）。probe が常に無言に
# なったらまずこのサブコマンドの現存を疑うこと。
#
# **副作用**: probe も本物の起動なので、適用に成功したときは
# ${GROK_HOME:-~/.grok}/sessions/sandbox-events.jsonl（1.0.30。0.2.118 は
# ${GROK_HOME:-~/.grok}/sandbox-events.jsonl）へ ProfileApplied を 1 行足す。
# GROK_HOME を一時領域へ逃がして避けることはしない — 逃がすと ~/.grok/sandbox.toml
# の探索先まで変わり、**本番とは別の条件**を測ることになるため。この追記が下の
# ProfileApplied ゲートに与える影響は、そのゲート側のコメント（残る限界）に書く。
#
# 判定は**片側だけ**。拒否を確定できたときにだけ非 0 を返し、それ以外は 0 を返す
# （= 呼び出し側は黙る）。「適用できる」と断定はしない — probe が rc=0 で返っても、
# 本番の実行が別の理由で拒否される可能性は消えないし、実際にサンドボックスが効いた
# かどうかの肯定確認は下の ProfileApplied ゲートが実行のたびに取り直す。誤った断定
# （「この環境では動く」）は、動かなかったときに読み手を無関係な原因へ送る。
#
# 認証・残高は probe の対象外。オーケストレータ側が dispatch 前の preflight probe を
# 採らなかった判断（classify_cli_failure_cause のヘッダー）は生きている — あちらの
# 理由は「残高・認証は課金される API 呼び出しをしないと分からない」で、ここで見るのは
# 環境固有・決定的・起動前に確定する別種の性質なので、その判断とは衝突しない。
readonly SANDBOX_PROBE_REFUSED_STATUS=3
# probe はローカル完結なので長い猶予は要らない。刺さったまま dry-run を止めない
# ための上限で、公開つまみにはしない（延ばして直る種類の失敗ではない）。
readonly SANDBOX_PROBE_TIMEOUT=30

# 目印は **stderr の行頭**にアンカーして見る。stdout を混ぜた部分一致で拾うと、
# `inspect` が設定ダンプとして同じ語を素通しで出しただけ・別のエラーが文中で
# 引用しただけで「拒否」と読み、存在しない環境問題を毎回警告することになる。
#
# 区別する形は 2 つ:
#   REFUSED — 起動を拒否する側。warning 行と error 行が対で出て、rc も非 0 になる
#             （実測 rc=1）。rc≠0 と目印の両方が揃ったときだけ拒否と読む
#   UNSANDBOXED — サンドボックス**無しで続行する**側。こちらは rc=0 で走りうるので
#             rc は条件にしない。走ってもレビュー結果は下の ProfileApplied ゲートが
#             refuse するので、プラン時点で言うべきことは同じ（ただし理由が違う）
readonly SANDBOX_MARKER_REFUSED_WARNING='^warning: sandbox could not be applied'
readonly SANDBOX_MARKER_REFUSED_ERROR='^error: could not apply the .* sandbox profile'
readonly SANDBOX_MARKER_UNSANDBOXED='^Sandbox could not be applied, continuing without sandbox'

# 出力契約: 拒否を確定できたときだけ stdout に 2 行を書き、
# SANDBOX_PROBE_REFUSED_STATUS を返す。
#   1 行目 = 種別（refused-to-start / unsandboxed-start）— 呼び出し側の帰結文の出し分け用
#   2 行目 = CLI 自身が出した理由の行（そのまま）
# それ以外（rc=0 / timeout / 想定外の rc / 目印なし）は無出力で rc=0（fail-open）。
run_sandbox_probe() { # $1: profile
  local profile="$1" stderr_file="" probe_stdout="" probe_rc=0 marker=""
  if ! stderr_file="$(mktemp)"; then
    # probe の足回りすら用意できない環境では何も確定できない。fail-open。
    return 0
  fi
  # 起動形は他のアダプタ呼び出しと同じ「コマンド置換で受ける」形に揃える
  # （run_with_timeout はこの形を前提に stdin の EOF を保証している）。判定に
  # 使うのは stderr だけなので、stdout はファイルへ分けずに置換で捨てる。
  probe_stdout="$(run_with_timeout "$SANDBOX_PROBE_TIMEOUT" \
    "$CLI_COMMAND" --sandbox "$profile" inspect 2>"$stderr_file")" || probe_rc=$?
  : "${probe_stdout:-}"

  # timeout は「拒否」ではない。刺さった probe を環境の欠陥として警告すると、
  # 一時的な負荷が恒久的な環境問題として表示され続ける。
  if [[ "$probe_rc" -eq "$TIMEOUT_EXIT_CODE" ]]; then
    rm -f "$stderr_file"
    return 0
  fi

  marker="$(grep -m1 -E "$SANDBOX_MARKER_UNSANDBOXED" "$stderr_file" || true)"
  if [[ -n "$marker" ]]; then
    printf 'unsandboxed-start\n%s\n' "$marker"
    rm -f "$stderr_file"
    return "$SANDBOX_PROBE_REFUSED_STATUS"
  fi

  if [[ "$probe_rc" -ne 0 ]]; then
    marker="$(grep -m1 -E "$SANDBOX_MARKER_REFUSED_WARNING" "$stderr_file" || true)"
    if [[ -z "$marker" ]]; then
      marker="$(grep -m1 -E "$SANDBOX_MARKER_REFUSED_ERROR" "$stderr_file" || true)"
    fi
    if [[ -n "$marker" ]]; then
      printf 'refused-to-start\n%s\n' "$marker"
      rm -f "$stderr_file"
      return "$SANDBOX_PROBE_REFUSED_STATUS"
    fi
  fi

  # 想定外の rc（未ログイン・サブコマンド消失・CLI 不在）は拒否と読まない。
  rm -f "$stderr_file"
  return 0
}

if [[ "$PROBE_SANDBOX" == "true" ]]; then
  probe_rc=0
  # 環境変数が指すプロファイル名が不正なら、CLI は起動しない（アダプタが argv を
  # 組む前に拒否する）。probe の出力契約に乗せて「起動を拒否する側」として報告する
  # — プランに載っていても未実行になる、という帰結はサンドボックス拒否と同じ。
  # stdout（成功時の名前）と stderr（拒否時の理由）は排他なので 1 本に併合して受ける。
  # 一時ファイルを挟まない — 予測可能な /tmp パスへの redirect は避けるべき形で、
  # 作れない環境では「理由の無い拒否」を報告することになる。
  probe_out=""
  if ! probe_out="$(get_sandbox_profile 2>&1)"; then
    printf 'refused-to-start\n%s\n' "$(printf '%s\n' "$probe_out" | sed -n '1p')"
    exit "$SANDBOX_PROBE_REFUSED_STATUS"
  fi
  run_sandbox_probe "$probe_out" || probe_rc=$?
  exit "$probe_rc"
fi

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: ${perspective_name}" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

# 拒否理由は成果物にも残す（stderr だけだと INCOMPLETE 成果物を読む人に値も理由も
# 届かない）。stdout / stderr は排他なので 1 本で受け、失敗時は理由として使う。
sandbox_profile=""
if ! sandbox_profile="$(get_sandbox_profile 2>&1)"; then
  printf '%s\n' "$sandbox_profile" >&2
  fail_orchestrator_error "$perspective_name" \
    "${READONLY_PROFILE_ENV} does not name a usable read-only sandbox profile: $(printf '%s\n' "$sandbox_profile" | sed -n '1p')"
fi
if is_custom_readonly_profile "$sandbox_profile"; then
  echo "   ℹ️ sandbox: read-only スロットを ${READONLY_PROFILE_ENV}='${sandbox_profile}' で差し替えています（実行後に read_write_paths が作業ツリーを含まないことを確認します）" >&2
  # 差し替えで外れるのは restrict_network の deny = コンテナランタイムのソケット
  # （docker.sock 等）への deny。実測（grok 1.0.30 / macOS、2026-09-14、課金走行）:
  # extends=read-only + restrict_network=false では /var/run/docker.sock とその実体
  # ~/.docker/run/docker.sock の両方に `curl --unix-socket` で到達できた。custom の
  # `deny` に両パスを足しても、symlink 側は塞がるが実体側への connect は通る
  # （deny は file-read/write の規則で、unix socket の connect を止めない）。つまり
  # この差し替えは「書き込み境界を保ったまま、ランタイムソケットの遮断を失う」。
  # 同じ機械の implement（workspace、restrict_network:false）は既にこの状態で走って
  # いるので保証の新規後退ではないが、review が受ける diff は信頼できない入力なので、
  # 黙って走らせずネットワーク通知と同じく毎回提示する（fail-closed にしないのは、
  # それがこの機械で grok review を走らせる唯一の道であり、代替が「走らない」だから）。
  echo "   ⚠️ runtime-socket: '${sandbox_profile}' は restrict_network を外しているため、コンテナランタイムのソケット（/var/run/docker.sock 等）への接続を遮断しません（macOS 実測 2026-09-14 / 1.0.30。custom の deny でも実体パスへの connect は塞げない）" >&2
fi

# grok のサンドボックスは outbound network を遮断しない（Issue #897 の実測
# 2026-09-01 / grok 0.2.118 / macOS: workspace は宣言どおり開放、read-only は
# restrict_network:true を記録しながら外部 HTTPS が通る）。閉じる設定手段が無い
# ため、黙って開放のまま走らせず毎回提示する（codex implement は network を
# 明示ピンで遮断しており、非対称）。Linux（Landlock）は未測定だが、保守側 =
# 開放前提に倒して同じ通知を出す（意図的な過剰警告。測定したら文言を分岐する）。
echo "   ⚠️ network: grok の '${sandbox_profile}' sandbox は外部ネットワークを遮断しません（macOS 実測 2026-09-01 / 0.2.118、Linux は未測定・開放前提。codex と非対称）" >&2

# サンドボックス適用の肯定確認は、この実行で**追記された**イベントだけを見る。
# 実行前の行数を控えておく。
#
# 行数を取れなかったときに 0 で代用してはいけない。0 だと実行後の `tail -n +1` が
# ファイル全体を「この実行の追記分」として返し、**前回の実行が残した ProfileApplied**
# で確認が成立する（実測で再現）。baseline を確立できないなら確認もできないので、
# 空にして後段で fail-closed に倒す。
# grok home の解決順は GROK_HOME → HOME（CLI 側も同じ順で、無ければ
# "no user grok home (set $GROK_HOME or $HOME)" で落ちる）。ここで素に $HOME を
# 参照すると、両方未設定の環境（CI コンテナ / systemd / cron）で set -u が
# bare exit 1 を投げ、成果物を 1 つも残さずに終わる — 3 行下の mktemp ガードが
# まさに防いでいる形の失敗を、そのガードの手前で作ることになる。
sandbox_home="${GROK_HOME:-${HOME:-}}"
if [[ -z "$sandbox_home" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "GROK_HOME も HOME も設定されていないため、${CLI_NAME} のサンドボックス適用を確認できません。"
fi
if [[ -n "${GROK_HOME:-}" ]]; then
  grok_home_dir="${GROK_HOME}"
else
  grok_home_dir="${sandbox_home}/.grok"
fi
# イベントログの置き場は版で動いた（実測）: 0.2.118 は <grok home>/sandbox-events.jsonl、
# 1.0.30 は <grok home>/sessions/sandbox-events.jsonl（実測で `inspect` と本実行の
# ProfileApplied がそこへ追記され、ベンダー文書 18-sandbox.md も「~/.grok/sessions」
# へ変わっている。binary の文字列にはファイル名しか無く、ディレクトリは実行時に組まれる）。
# 片方だけを見ると、もう片方の版では**適用できていても**「確認できない」で全結果を
# 捨てる（1.0.30 を旧パスのまま読んで review レーンが常に sandbox-refused になった）。
# 両方を候補にし、baseline もそれぞれ取る。**存在するのに行数を取れない**ファイルが
# 1 つでもあれば確認不能（fail-closed）— その窓に ApplyFailed / BypassGranted が
# 書かれていても見えないため。
sandbox_events_file="${grok_home_dir}/sessions/sandbox-events.jsonl"
sandbox_events_file_legacy="${grok_home_dir}/sandbox-events.jsonl"
events_baseline() { # $1: file → stdout に行数（未作成なら 0、取れなければ空）
  local f="$1" n=""
  if [[ -f "$f" ]]; then
    n="$(wc -l < "$f" 2>/dev/null | tr -d ' ' || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=""
  else
    # ファイル未作成なら、この実行が作る分がまるごと追記分になる。
    n=0
  fi
  printf '%s' "$n"
}
sandbox_events_before="$(events_baseline "$sandbox_events_file")"
sandbox_events_before_legacy="$(events_baseline "$sandbox_events_file_legacy")"
sandbox_events_unreadable="false"
[[ -f "$sandbox_events_file" && -z "$sandbox_events_before" ]] && sandbox_events_unreadable="true"
[[ -f "$sandbox_events_file_legacy" && -z "$sandbox_events_before_legacy" ]] && sandbox_events_unreadable="true"
# Guard this mktemp explicitly: under `set -e` a failure here would kill the
# adapter with a bare 1 before run_with_timeout is ever reached, filing a broken
# TMPDIR as "the CLI exited 1" and writing no artifact at all.
stderr_log="$(mktemp 2>/dev/null)" || stderr_log=""
if [[ -z "$stderr_log" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for ${CLI_NAME} stderr (check TMPDIR)."
fi

# モデルは既定では指定せず Grok CLI 側の設定に委譲する（ACE-70-2）。
# MULTI_AGENT_MODEL_GROK_CLI が設定されたときだけ -m を渡す。
# 引数不正は呼び出し側（このファイル）のバグ。素の呼び出しだと set -e が bare exit 2 で
# 落とすため、INCOMPLETE 成果物が残らず「CLI が 2 で落ちた」と誤読される。
reset_model_args
add_model_arg -m MULTI_AGENT_MODEL_GROK_CLI \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
echo_model_args

# プロンプトは argv ではなく一時ファイルで渡す（Issue #712: argv 渡しは Windows の
# CreateProcess 上限 ~32KB で exit 126 になる）。grok は stdin をプロンプトとして
# 読まない（0.2.118 で実測: stdin のマーカーが届かない）ため、専用の
# `--prompt-file <PATH>`（Single-turn prompt from a file）を使う（同バージョンで
# 実測済み）。stdin は run_with_timeout の既定どおり /dev/null に閉じる。
prompt_file="$(materialize_prompt_file "$prompt")" || prompt_file=""
if [[ -z "$prompt_file" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot hand the prompt to the CLI (temp-file write failed, or the prompt is not valid UTF-8 — see the error above)."
fi
_FF_PROMPT_FILE="$prompt_file"

# MODEL_ARGS は空になりうる。bash 3.2 では set -u 下で空配列を "${a[@]}" と
# 展開すると unbound variable で落ちるため ${a[@]+"${a[@]}"} を使う。
result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" --prompt-file "$prompt_file" \
    --sandbox "$sandbox_profile" \
    --output-format plain \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  2>"$stderr_log") || {
    # Capture the status first: any command inside this block would overwrite $?.
    rc=$?
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }
rm -f "$prompt_file"
_FF_PROMPT_FILE=""

# ── Confirm the sandbox actually took effect ──
#
# The sandbox is the whole reason this adapter is safe to point at a working tree,
# so it is verified positively rather than by the absence of a warning.
#
# Measured on grok 0.2.118 (do not re-derive these from the flag names):
#   - A successful sandboxed run writes **nothing** to stderr. There is no
#     confirmation line to grep for.
#   - The confirmation is structured, in ${GROK_HOME:-~/.grok}/sandbox-events.jsonl:
#       {"event_type":"ProfileApplied","profile":"read-only","enforced":true,...}
#     The binary also carries an "ApplyFailed" event type.
#     grok 1.0.30 (measured 2026-09-14) writes the same events to
#     ${GROK_HOME:-~/.grok}/sessions/sandbox-events.jsonl instead, and the line
#     additionally carries "read_write_paths":[...] (the applied write grants,
#     symlinks resolved) — the field the custom-profile check below relies on.
#   - The binary contains TWO different failure strings, and they behave
#     differently:
#       "warning: sandbox could not be applied:"            → CLI refuses to start
#                                                             (exit 1, empty stdout)
#       "Sandbox could not be applied, continuing without sandbox"
#                                                           → runs UNSANDBOXED
#     An earlier version of this guard grepped only for the first — the one the
#     exit-code path already covers — and therefore missed the only case it was
#     written to defend against. Matching a string this adapter invented, and then
#     stubbing that same invented string in the test, made the check agree with
#     the bug (ACE-249-1).
#
# So: require the positive event, and treat "cannot tell" as failure. A review
# that silently ran unsandboxed is worse than one that loudly did not run.
new_sandbox_events=""
if [[ -n "$sandbox_events_before" && -f "$sandbox_events_file" ]]; then
  new_sandbox_events="$(tail -n "+$((sandbox_events_before + 1))" "$sandbox_events_file" 2>/dev/null || true)"
fi
if [[ -n "$sandbox_events_before_legacy" && -f "$sandbox_events_file_legacy" ]]; then
  new_sandbox_events="${new_sandbox_events}${new_sandbox_events:+
}$(tail -n "+$((sandbox_events_before_legacy + 1))" "$sandbox_events_file_legacy" 2>/dev/null || true)"
fi

# 3 条件を別々に grep すると**別々の行**で成立してしまう。実測: 「workspace が
# enforced:false で適用された」行と「read-only を含む無関係な行」が並んでいるだけで
# 「read-only が enforced で適用された」と判定された。1 行が 3 条件すべてを満たす
# ことを要求する。
#
# 行数の差分だけでは、同じイベントログを共有する**別プロセス**の成功イベントを
# 自分の証明として受け取りうる（同時に走る 2 つの grok が同じ baseline を取る）。
# イベント行の workspace で相関させて絞る。実測でこの値は `pwd -P` と一致する
# （シンボリックリンクは解決済みで記録される）。
#
# 残る限界: 同一ディレクトリ・同一プロファイルでの並行実行は相関しきれない。
# オーケストレータはタスクごとに grok を 1 つしか計画しないので露出は小さいが、
# ゼロではない。完全な相関には実行 ID かログ単位の排他が要る（未実装）。
#
# **この限界には dry-run の sandbox probe も乗る。** probe（run_sandbox_probe）も
# 本物の起動なので、成功時は同じ sandbox-events.jsonl へ ProfileApplied を 1 行足す。
# 同一 worktree で dry-run と実行が並行すると、probe が書いた行がこちらの窓に入り、
# プロファイルが違えば other_profile として**偽陰性**（実際には効いていたのに
# 「確認できない」）になりうる。probe を GROK_HOME ごと一時領域へ逃がす回避は
# 採らない — 逃がすと ~/.grok/sandbox.toml の探索先まで変わり、probe が本番とは
# 別の条件を測ることになるため。解消も上と同じ実行 ID / ログ排他が要る。
#
# 判定は awk で「1 行が全条件を含む」を見る。正規表現で `.*` を挟んで繋ぐと JSON の
# フィールド順に依存し、並びが変わっただけで確認が取れなくなる（実測: 実際の行は
# timestamp が先頭で、`{"event_type"` を先頭に置いた初版パターンは正常系まで落とした）。
# index() なら順序非依存で、部分文字列の意味も変わらない。
sandbox_workspace="$(pwd -P 2>/dev/null || pwd)"

# 判定は awk で「1 行が全条件を含む」を見る。正規表現で `.*` を挟んで繋ぐと JSON の
# フィールド順に依存し、並びが変わっただけで確認が取れなくなる（実測: 実際の行は
# timestamp が先頭で、`{"event_type"` を先頭に置いた初版パターンは正常系まで落とした）。
# index() なら順序非依存で、部分文字列の意味も変わらない。
#
# workspace で相関させるのは、同じイベントログを共有する**別プロセス**の成功イベントを
# 自分の証明として受け取らないため（行数の差分だけでは並行実行を切り分けられない）。
# 実測でこの値は `pwd -P` と一致する。残る限界は同一ディレクトリ・同一プロファイルでの
# 並行実行で、完全な相関には実行 ID かログ単位の排他が要る。
#
# 失格条件は「肯定の裏返し」で対称に置く。肯定だけを条件にすると、要求より広い
# プロファイルが同じ窓で適用されていても通ってしまう（実ログでは 107ms の間に
# workspace / read-only / strict の 3 プロファイルが並ぶことがある）。
#   ApplyFailed    — 適用そのものの失敗
#   BypassGranted  — 個別操作が deny を迂回できた記録（operation / target / command /
#                    tool_call_id を伴う操作系イベント）。意味論はベンダー文書で確認
#                    できていないが、名前と随伴フィールドから離脱と読むのが保守側。
#                    実測ではレビュー実行中に一度も出ていない
#   FsViolation / NetViolation は**失格にしない**。これはサンドボックスが実際に
#   操作を止めた記録で、機能している証拠だから（実測: 書き込みを試させたときに 1 件出た）
#
# カスタムプロファイル（docker.sock symlink 対応）の追加条件: 名前は利用者が付けたもので、中身が
# read-only 相当である保証は名前に無い。同じ ProfileApplied 行の `read_write_paths`
# （実測 1.0.30: 適用された書き込み許可の実パス配列。組み込み read-only では ~/.grok と
# temp 系だけ、workspace ではそこに CWD が加わる）を見て、作業ツリー自身・その祖先・
# その配下・`/` のいずれかが含まれていれば **read-only ではない**として結果を採用
# しない（配下も落とすのは、`read_write = ["src"]` のような部分 grant でもソース改変が
# 通るため）。配列そのものが無い行・引用文字列として読めない要素は「確認できない」=
# 不採用（fail-closed）。組み込み `read-only` を要求した実行にはこの追加条件を掛けない
# — 名前が組み込みの保証で、判定を配列の有無に依存させないため（0.2.118 の行にも配列は
# 在ったが、stub で走る既存 suite の行には無い）。
#
# 配列は `"…"` の引用トークン単位で読む。`,` や `]` で切ると、パスにその文字を含む
# grant が要素として壊れて一致せず、fail-open になる。awk の -v は `\` を解釈するので
# 作業ツリーのパスは ENVIRON で素のまま渡す。
sandbox_custom="false"
is_custom_readonly_profile "$sandbox_profile" && sandbox_custom="true"
sandbox_verdict=""
if [[ "$sandbox_events_unreadable" == "true" ]]; then
  sandbox_verdict="events-unreadable"
elif [[ -n "$new_sandbox_events" ]]; then
  # awk 自身の失敗（方言差・不在）は bare exit にせず「判定不能」へ倒す — set -e で
  # ここが落ちると INCOMPLETE 成果物が残らない。
  sandbox_verdict="$(printf '%s\n' "$new_sandbox_events" \
     | FF_SANDBOX_WSDIR="$sandbox_workspace" awk -v prof="\"profile\":\"${sandbox_profile}\"" \
           -v ws="\"workspace\":\"${sandbox_workspace}\"" -v custom="${sandbox_custom}" '
         BEGIN { wsdir = ENVIRON["FF_SANDBOX_WSDIR"]; sub(/\/+$/, "", wsdir) }
         function grant_covers_tree(p) {
           if (p == "/") return 1
           sub(/\/+$/, "", p)
           if (p == "") return 1                       # "/" の末尾正規化後
           if (p == wsdir) return 1                    # 作業ツリー自身
           if (index(wsdir, p "/") == 1) return 1      # 祖先
           if (index(p, wsdir "/") == 1) return 1      # 配下
           return 0
         }
         index($0, "\"event_type\":\"ProfileApplied\"") && index($0, ws) {
           if (index($0, prof) && index($0, "\"enforced\":true")) {
             applied = 1
             if (custom == "true") {
               key = "\"read_write_paths\":["
               i = index($0, key)
               if (i == 0) { grants_unknown = 1 }
               else {
                 rest = substr($0, i + length(key))
                 closed = 0
                 while (!closed) {
                   sub(/^[ \t]*/, "", rest)
                   c = substr(rest, 1, 1)
                   if (c == "]") { closed = 1; break }
                   if (c != "\"") { grants_unknown = 1; break }
                   # 引用文字列の終端: `\` でエスケープされていない次の `"`
                   rest = substr(rest, 2); p = ""; ended = 0
                   while (length(rest) > 0) {
                     c = substr(rest, 1, 1)
                     if (c == "\\") { p = p substr(rest, 2, 1); rest = substr(rest, 3); continue }
                     if (c == "\"") { rest = substr(rest, 2); ended = 1; break }
                     p = p c; rest = substr(rest, 2)
                   }
                   if (!ended) { grants_unknown = 1; break }
                   if (grant_covers_tree(p)) write_granted = 1
                   sub(/^[ \t]*,?/, "", rest)
                 }
                 if (!closed && !grants_unknown) grants_unknown = 1
               }
             }
           }
           else other_profile = 1          # 要求と違うプロファイルが同じ窓で適用された
         }
         index($0, "\"event_type\":\"ApplyFailed\"")   { failed = 1 }
         index($0, "\"event_type\":\"BypassGranted\"") { failed = 1 }
         END {
           if (!(applied && !other_profile && !failed)) { print "unconfirmed"; exit }
           if (write_granted)  { print "write-granted";  exit }
           if (grants_unknown) { print "grants-unknown"; exit }
           print "confirmed"
         }
       ')" || sandbox_verdict="awk-failed"
fi
sandbox_confirmed=false
[[ "$sandbox_verdict" == "confirmed" ]] && sandbox_confirmed=true


# backstop として stderr の警告文字列も見ていたが、撤去した。真理値表を取ると、
# その grep が結果を変えるのは「肯定確認が取れている」行だけで、コメントが謳って
# いた「イベントログが使えないときの保険」では sandbox_confirmed が既に false な
# ため出番が無い。つまり唯一の効き目は**確認が取れた実行を捨てること**で、実際
# stderr がその文言を引用しただけの実行を落とした（無アンカーの grep は、CLI 自身の
# 警告と CLI が中継した文字列を区別できない）。肯定確認だけに寄せる。
if [[ "$sandbox_confirmed" != "true" ]]; then
  # 理由は stderr と CLI の stderr ログの両方へ書く。後者は INCOMPLETE 成果物へ抜粋
  # されるので、成果物だけを読む人にも「未確認」と「書き込みが許されていた」の区別が届く。
  {
  case "$sandbox_verdict" in
    write-granted)
      # 名前は通ったが中身が read-only ではない。降格を黙って通さないための本体。
      echo "ERROR: ${CLI_NAME} applied the '${sandbox_profile}' sandbox, but its read_write_paths grant writes to the working tree (${sandbox_workspace}) or a directory above/inside it."
      echo "       ${READONLY_PROFILE_ENV}='${sandbox_profile}' is therefore NOT a read-only profile (it extends workspace/devbox/strict, or adds the tree via read_write)."
      echo "       Refusing the result: the review ran with write access it must not have. Fix the profile in ~/.grok/sandbox.toml (extends = \"read-only\") or unset ${READONLY_PROFILE_ENV}."
      ;;
    grants-unknown)
      echo "ERROR: ${CLI_NAME} applied the '${sandbox_profile}' sandbox, but the ProfileApplied event carries no read_write_paths array (or one this adapter cannot parse), so the write boundary of this custom profile cannot be verified."
      echo "       Refusing the result: a custom read-only profile is accepted only when the event proves the working tree is not writable."
      ;;
    events-unreadable)
      echo "ERROR: ${CLI_NAME} sandbox event log exists but its line count could not be read before the run (${sandbox_events_file} / ${sandbox_events_file_legacy}), so this run's events cannot be isolated."
      echo "       Refusing the result: without a baseline, an ApplyFailed/BypassGranted written by this run could go unseen."
      ;;
    awk-failed)
      echo "ERROR: ${CLI_NAME} sandbox verdict could not be computed (awk failed while reading the ProfileApplied events)."
      echo "       Refusing the result: the sandbox may have taken effect, but this adapter could not verify it."
      ;;
    *)
      echo "ERROR: ${CLI_NAME} did not confirm the '${sandbox_profile}' sandbox took effect."
      echo "       Expected a ProfileApplied/enforced event in ${sandbox_events_file} (grok 1.0.30 measured) or ${sandbox_events_file_legacy} (grok 0.2.118 measured)."
      echo "       Refusing the result: this ${TASK_TYPE:-review} may have run with wider"
      echo "       filesystem access than intended, so its findings are unverified."
      ;;
  esac
  } | tee -a "$stderr_log" >&2
  # Not a CLI crash — it may well have exited 0 and reached a conclusion. Record
  # the real reason so the report names the sandbox rather than sending the
  # reader after a crash that never happened.
  record_timeout_reason sandbox-refused
  fail_cli_task 1 "$stderr_log" "$perspective_name" "$result"
fi

# exit 0 + 空出力。ここで stderr を先に捨てると「なぜ空だったか」を言う唯一の
# チャネルが消え、成果物も残らない（実測: レート制限の一文が stderr にだけ出て、
# 成果物もログも残らなかった — feel-flow/ff-dev-toolkit#6 の残件）。fail_cli_task
# へ通して、INCOMPLETE 成果物（stderr があれば抜粋つき）を残す。
if [[ -z "$result" ]]; then
  echo "ERROR: ${CLI_NAME} produced no output. The ${TASK_TYPE:-review} may have failed silently." >&2
  # クラッシュではない（0 で終了し、止められてもいない）。既定の reason のままだと
  # 「CLI が status 1 で落ちた／途中で止められた」と報告され、読み手は存在しない
  # クラッシュを追う。実際に見るべきは成果物に残る stderr 抜粋。
  record_timeout_reason empty-output
  fail_cli_task 1 "$stderr_log" "$perspective_name" ""
fi
# exit 0 + 非空でも、有効な型付き判定行を 1 行も含まない捕捉結果は complete に
# しない（Issue #893。観測は claude-code だが、捕捉経路は「CLI の最終出力を command
# substitution で受ける」の 4 アダプタ共通形なので同じゲートを掛ける）。**受理条件の
# 正は adapter-common.sh の review_body_present ヘッダ** — ここに列挙を複製しない。
if [[ "${TASK_TYPE:-review}" == "review" ]] && ! review_body_present "$result" "${CLI_NAME}/${perspective_name}"; then
  echo "ERROR: ${CLI_NAME} output ($(printf '%s' "$result" | wc -c | tr -d '[:space:]') bytes) $(review_body_refusal_clause) — refusing it as a review result. The review body may have been emitted in an earlier, uncaptured turn, or written without the typed verdict lines the prompt requires." >&2
  record_timeout_reason missing-review-body
  fail_cli_task 1 "$stderr_log" "$perspective_name" "$result"
fi
rm -f "$stderr_log"

# ── Write Output ──

# 書き込み失敗は rc に載る（adapter-common.sh の write_output）。ここで受け止めないと
# `set -e` が素の 1 で落とし、CLI 側のクラッシュと同じ番号に混ざる。
write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" "$result" \
  || fail_output_write "$perspective_name" "$OUTPUT_FILE"
