#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: codex-cli の版の確認と自動更新。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── codex-cli の版と自動更新 ──
#
# 実測（2026-09-25）: PATH 上の codex-cli 0.153.4 は ChatGPT アカウントで最新世代の上位モデルを
# 400（model is not supported when using Codex with a ChatGPT account）で拒み、同じ
# アカウント・同じモデルで 0.157.0 は完走した。アカウント側のモデル一覧
# （`${CODEX_HOME:-~/.codex}/models_cache.json`）は、それを書いたクライアントの版を
# `client_version` に残す — これより古い CLI は、そのキャッシュに載ったモデルを扱えない
# ことがある。そこで dispatch 前に比べ、古ければインストール元の手段で更新してから回す。
#
# 判定材料が欠けた回は**黙って緑にしない**: 版を判定しなかったこととその理由を 1 行
# 出し、CLI はそのまま回す（判定できないことはレビューを止める理由ではない）。
# 更新が失敗した回も同じく、古い版で走ることを名指しして続ける。
# 無効化は FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE=1（既存の FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE と
# 同じ系統。あちらは marketplace の自動更新 hook 用で、ここでは共有しない —
# プラグインの自動更新だけを止めたい利用者の codex まで止めないため）。

# **版は codex を起動せずに読む**。インストール実体のメタデータ（npm は
# `<prefix>/lib/node_modules/@openai/codex/package.json` の version、Homebrew は
# `Caskroom|Cellar/codex/<版>/` のディレクトリ名）から取る。`codex --version` を叩くと、
# レビュー前に CLI を 1 回余計に起動する（事前検査で止まるはずの実行でも CLI が起動し、
# 起動をきっかけに作業ツリーへ書く CLI ならリビジョンガードの基準までずれる）。
# メタデータで読めない配置（pnpm / bun / 手置きのバイナリ等）は版もインストール元も
# 判定しない側へ倒す — 推測で更新すると別の場所へ 2 本目を入れる。

readonly CODEX_UPDATE_TIMEOUT_SECONDS=300

# 版文字列から数値の版（x.y.z）を取り出す。見つからなければ空。プレリリースの接尾辞
# （-alpha.2 等）は数値部だけを比べる。
extract_dotted_version() { # <text>
  awk 'match($0, /[0-9]+\.[0-9]+(\.[0-9]+)?/) { print substr($0, RSTART, RLENGTH); exit }' <<<"$1"
}

# a < b なら rc0（数値の要素ごとに比べる。欠けた要素は 0）。
dotted_version_lt() { # <a> <b>
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) { xi = x[i] + 0; yi = y[i] + 0; if (xi < yi) exit 0; if (xi > yi) exit 1 }
    exit 1 }'
}

codex_models_cache_file() {
  printf '%s\n' "${CODEX_HOME:-${HOME}/.codex}/models_cache.json"
}

# models_cache.json を書いたクライアントの版。読めない・キーが無いときは空。
codex_required_version() {
  local f v
  f="$(codex_models_cache_file)"
  [[ -r "$f" ]] || return 0
  v="$(awk 'match($0, /"client_version"[[:space:]]*:[[:space:]]*"[^"]*"/) {
         v = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", v); sub(/"$/, "", v); print v; exit }' "$f" 2>/dev/null)" || v=""
  extract_dotted_version "$v"
}

# symlink を辿った実体パス（readlink -f の無い環境向けに 1 段ずつ辿る）。
resolve_symlink_path() { # <path>
  local p="$1" dir target i=0
  while [[ -L "$p" && "$i" -lt 40 ]]; do
    target="$(readlink "$p")" || break
    case "$target" in
      /*) p="$target" ;;
      *) dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || break; p="${dir}/${target}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$p"
}

codex_real_path() {
  local bin
  bin="$(command -v codex 2>/dev/null)" || return 0
  [[ -n "$bin" ]] || return 0
  resolve_symlink_path "$bin"
}

# インストール元: "npm <prefix>" | "brew <prefix>" | ""（判定できない）。実体の置き場所で
# 決める — 実測: npm は <prefix>/lib/node_modules/@openai/codex/bin/codex.js、Homebrew は
# <prefix>/Caskroom/codex/<版>/… または <prefix>/Cellar/codex/<版>/…。
codex_install_layout() {
  local real
  real="$(codex_real_path)"
  case "$real" in
    */lib/node_modules/@openai/codex/*) echo "npm ${real%%/lib/node_modules/@openai/codex/*}" ;;
    */Caskroom/codex/*) echo "brew ${real%%/Caskroom/codex/*}" ;;
    */Cellar/codex/*) echo "brew ${real%%/Cellar/codex/*}" ;;
    *) echo "" ;;
  esac
}

# PATH 上の codex の版（メタデータから。読めなければ空）。
codex_installed_version() {
  local real pkg v=""
  real="$(codex_real_path)"
  case "$real" in
    */lib/node_modules/@openai/codex/*)
      pkg="${real%%/lib/node_modules/@openai/codex/*}/lib/node_modules/@openai/codex/package.json"
      [[ -r "$pkg" ]] || return 0
      v="$(awk 'match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]*"/) {
             v = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", v); print v; exit }' "$pkg" 2>/dev/null)" || v=""
      ;;
    */Caskroom/codex/*|*/Cellar/codex/*)
      v="${real#*/codex/}"; v="${v%%/*}" ;;
  esac
  extract_dotted_version "$v"
}

codex_update_command() { # <source>
  case "$1" in
    npm)  echo "npm install -g @openai/codex@latest" ;;
    brew) echo "brew upgrade codex" ;;
    *)    echo "" ;;
  esac
}

# 手で更新する案内（インストール元を判定できない回・更新が失敗した回に使う）。
codex_manual_update_hint() {
  echo "npm install -g @openai/codex@latest (npm) / brew upgrade codex (Homebrew)"
}

# 更新コマンドが実際に書き換えるのが、PATH 上の codex と同じ prefix か。npm / brew の
# グローバル prefix と実体の prefix が違う（NPM_CONFIG_PREFIX が別・pnpm / bun の配置・
# 別の Homebrew）なら更新しない — 別の場所へ 2 本目を入れ、PATH 上の codex は古いまま残る。
codex_update_targets_path_install() { # <source> <prefix>
  local got=""
  case "$1" in
    npm)  got="$(npm prefix -g </dev/null 2>/dev/null)" || got="" ;;
    brew) got="$(brew --prefix </dev/null 2>/dev/null)" || got="" ;;
  esac
  [[ -n "$got" ]] || return 1
  got="$(cd "$got" 2>/dev/null && pwd -P)" || return 1
  [[ "$got" == "$(cd "$2" 2>/dev/null && pwd -P)" ]]
}

# 更新コマンドを時間制限付きで走らせる。出力は stderr（stdout は委譲 handoff の専用チャネル）。
run_codex_update() { # <source>
  local pid wd rc=0
  case "$1" in
    npm)  npm install -g @openai/codex@latest </dev/null >&2 2>&1 & ;;
    # brew upgrade は既定で先に brew update を走らせ、数分かかりうる
    brew) HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade codex </dev/null >&2 2>&1 & ;;
    *) return 1 ;;
  esac
  pid=$!
  ( sleep "$CODEX_UPDATE_TIMEOUT_SECONDS"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  return "$rc"
}

codex_update_state_file() {
  printf '%s\n' "${FF_DEV_TOOLKIT_STATE_DIR:-${HOME}/.config/ff-dev-toolkit}/codex-auto-update.last"
}

# dispatch 前の版チェック。plan に codex-cli が無ければ何もしない。
# 失敗させる経路は持たない（戻り値は常に 0）— 判定できない・更新できないはレビューを
# 止める理由ではないが、どちらも 1 行で名指しする。
ensure_codex_cli_current() {
  plan_lists_cli codex-cli || return 0
  # 委譲するレーンの CLI は起動しないので、更新（グローバル install と最大 300 秒の待ち）もしない（Issue `#2118`）
  if task_is_delegated codex-cli; then return 0; fi
  if [[ "${FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE:-}" == "1" ]]; then
    echo "ℹ️  codex-cli version check skipped (FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE=1)." >&2
    return 0
  fi
  local installed required layout source prefix cmd after update_rc=0 state lock last=""
  required="$(codex_required_version)"
  if [[ -z "$required" ]]; then
    echo "ℹ️  codex-cli version NOT checked: no client_version in $(codex_models_cache_file) (missing or unreadable) — running codex-cli as installed." >&2
    return 0
  fi
  layout="$(codex_install_layout)"
  source="${layout%% *}"; prefix="${layout#* }"
  installed="$(codex_installed_version)"
  if [[ -z "$layout" || -z "$installed" ]]; then
    echo "ℹ️  codex-cli version NOT checked: the install at $(codex_real_path) is neither npm nor Homebrew (or its version metadata is unreadable) — running it as-is." >&2
    echo "   If it is older than ${required} (the client that wrote the models cache), update it yourself: $(codex_manual_update_hint)." >&2
    return 0
  fi
  if ! dotted_version_lt "$installed" "$required"; then
    echo "ℹ️  codex-cli ${installed} (models cache written by ${required}) — up to date." >&2
    return 0
  fi
  cmd="$(codex_update_command "$source")"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "⚠️  codex-cli ${installed} is older than the client that wrote the models cache (${required}) — update needed." >&2
    echo "   A real run updates it first with: ${cmd} (dry-run: not updating)." >&2
    return 0
  fi
  if ! codex_update_targets_path_install "$source" "$prefix"; then
    echo "⚠️  codex-cli ${installed} is older than the client that wrote the models cache (${required})," >&2
    echo "   but \`${cmd}\` would not update the codex on PATH ($(codex_real_path)) — NOT updating." >&2
    echo "   Update that install yourself. Running with the OLD version ${installed}." >&2
    return 0
  fi
  # 同じ組（必要版・現在版）で前回すでに更新を試し、最新を入れても届かなかった回は
  # 繰り返さない（インストール元の最新がキャッシュを書いたクライアントより古い — Homebrew が
  # npm より遅れる等）。必要版か現在版が変われば再び試す。
  state="$(codex_update_state_file)"
  last="$(cat "$state" 2>/dev/null)" || last=""
  if [[ "$last" == "${required} ${installed}" ]]; then
    echo "⚠️  codex-cli ${installed} is older than ${required}, but updating it already did not reach ${required} (${source}'s latest is older) — NOT retrying; running with ${installed}." >&2
    return 0
  fi
  # 並走する別のレビューとグローバルな入れ替えを同時にしない（書きかけの install を
  # 別のレーンが起動しうる）。取れなければ更新しないで続ける。
  lock="${TMPDIR:-/tmp}/ff-codex-auto-update.lock"
  if [[ -d "$lock" ]] && [[ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]]; then
    rmdir "$lock" 2>/dev/null || true
  fi
  if ! mkdir "$lock" 2>/dev/null; then
    echo "⚠️  codex-cli ${installed} is older than ${required}, but another run is updating it right now (${lock}) — NOT updating; running with ${installed}." >&2
    return 0
  fi
  echo "⬆️  codex-cli ${installed} is older than the client that wrote the models cache (${required}) — updating: ${cmd}" >&2
  run_codex_update "$source" || update_rc=$?
  rmdir "$lock" 2>/dev/null || true
  after="$(codex_installed_version)"
  if [[ "$update_rc" -ne 0 ]]; then
    echo "⚠️  codex-cli update FAILED (rc=${update_rc}: ${cmd}; limit ${CODEX_UPDATE_TIMEOUT_SECONDS}s) — running with the OLD version ${after:-${installed}}." >&2
    echo "   Update it yourself: ${cmd}" >&2
    return 0
  fi
  if [[ -z "$after" ]] || dotted_version_lt "$after" "$required"; then
    echo "⚠️  codex-cli update ran but the CLI still reports ${after:-no version} (< ${required}) — running with it as-is." >&2
    if [[ -n "$after" ]]; then
      mkdir -p "$(dirname "$state")" 2>/dev/null && printf '%s %s\n' "$required" "$after" > "$state" 2>/dev/null \
        || echo "   (could not record the attempt at ${state}; the next run will try again)" >&2
    fi
    return 0
  fi
  echo "✅ codex-cli updated: ${installed} → ${after}." >&2
  return 0
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-codex-update.sh"
