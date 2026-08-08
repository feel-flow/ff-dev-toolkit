#!/usr/bin/env bash
# ============================================================================
# Multi-CLI Agent セットアップスクリプト
# ============================================================================
#
# 概要:
#   Multi-CLI Agent Orchestrator の依存ツールを確認・インストールし、
#   動作確認まで行うセットアップスクリプト。
#   Review / Explore / Implement の全タスクタイプに対応。
#
# 対応環境:
#   - macOS (Homebrew)
#   - Linux (apt / yum / pacman)
#
# 使い方:
#   bash scripts/setup-multi-agent.sh [オプション]
#
# オプション:
#   --skip-install    依存ツールの自動インストールをスキップ
#   --help            ヘルプを表示
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Options
SKIP_INSTALL=false
TOTAL_STEPS=6

# ============================================================================
# Functions
# ============================================================================

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "============================================================"
    echo "  Multi-CLI Agent セットアップ"
    echo "  (Review / Explore / Implement)"
    echo "============================================================"
    echo -e "${NC}"
}

print_step() {
    local step=$1
    local message=$2
    echo ""
    echo -e "${BLUE}[${step}/${TOTAL_STEPS}] ${message}${NC}"
}

print_success() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}  ✗ $1${NC}"
}

print_info() {
    echo -e "  $1"
}

show_help() {
    cat << 'EOF'
使い方: bash scripts/setup-multi-agent.sh [オプション]

Multi-CLI Agent Orchestrator の依存ツールを確認・インストールし、
動作確認まで行います。Review / Explore / Implement の全タスクタイプに対応。

オプション:
  --skip-install    依存ツールの自動インストールをスキップ（確認のみ）
  --help            このヘルプを表示

前提条件:
  - Git リポジトリ内で実行すること
  - Homebrew がある環境（macOS / Linuxbrew）: brew で yq を導入可能
  - Homebrew が無い Linux / macOS: curl または wget が必要（GitHub release 取得用）

セットアップされるもの:
  - yq (Mike Farah yq v4) — agent-config.yaml の読み込みに必要
    Homebrew がある場合: brew install yq
    それ以外: GitHub release の公式バイナリ（curl/wget で取得）
    （distro の apt/yum パッケージ yq は別実装のことがあり非対応）
  - AI CLI の検出と動作確認
  - multi-agent.sh の動作確認 (--dry-run) — 全タスクタイプ

対応するAI CLI:
  - Claude Code (claude)      — Premium tier
  - Codex CLI (codex)         — Standard tier
  - Copilot CLI (copilot)     — Metered（従量課金。review 既定ラインナップ外）
  - Gemini CLI (gemini)       — Free tier
  - Grok CLI (grok)           — Flat-rate tier

詳細: docs-template/05-operations/deployment/multi-cli-review-orchestration.md
EOF
}

# ── Step 1: Prerequisites ──

check_prerequisites() {
    print_step 1 "前提条件を確認中..."

    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "Git リポジトリ内で実行してください"
        exit 1
    fi
    print_success "Git リポジトリ: OK"

    if [[ -f "$SCRIPT_DIR/multi-agent.sh" ]]; then
        print_success "multi-agent.sh: OK"
    else
        print_error "scripts/multi-agent.sh が見つかりません"
        exit 1
    fi

    # Backward compat wrapper
    if [[ -f "$SCRIPT_DIR/multi-review.sh" ]]; then
        print_success "multi-review.sh (wrapper): OK"
    fi

    if [[ -f "$SCRIPT_DIR/agent-config.yaml" ]]; then
        print_success "agent-config.yaml: OK"
    else
        print_warning "agent-config.yaml が見つかりません（デフォルト設定で動作）"
    fi

    # Perspectives check
    local perspective_count=0
    for task_dir in review explore implement; do
        if [[ -d "$SCRIPT_DIR/perspectives/${task_dir}" ]]; then
            local count
            count=$(ls "$SCRIPT_DIR/perspectives/${task_dir}/"*.md 2>/dev/null | wc -l | tr -d ' ')
            perspective_count=$((perspective_count + count))
            print_success "perspectives/${task_dir}/: ${count} files"
        else
            print_warning "perspectives/${task_dir}/ が見つかりません"
        fi
    done
    print_success "Perspective ファイル合計: ${perspective_count}"

    # Execution permission
    if [[ -x "$SCRIPT_DIR/multi-agent.sh" ]]; then
        print_success "実行権限: OK"
    else
        chmod +x "$SCRIPT_DIR/multi-agent.sh" 2>/dev/null || true
        chmod +x "$SCRIPT_DIR/multi-review.sh" 2>/dev/null || true
        chmod +x "$SCRIPT_DIR/adapters/"*.sh 2>/dev/null || true
        print_success "実行権限: 付与しました"
    fi
}

# ── Step 2: Install Dependencies ──
#
# yq は Mike Farah 実装の v4 が必須。Ubuntu 等の distro パッケージ `yq` は別実装
# （または非互換）であることがあり、`apt install yq` / `yum install yq` では
# agent-config-mirror の capability gate や multi-agent の `yq -r` 式と合わない。
# Linux では GitHub release の公式バイナリを明示取得し、導入直後に version と
# capability probe で fail-loud 検証する（ACE-66-1 / Issue #271）。

# テストや air-gapped 向け: ダウンロード元と配置先を上書き可能
YQ_GITHUB_BASE_URL="${YQ_GITHUB_BASE_URL:-https://github.com/mikefarah/yq/releases/latest/download}"
# 空なら ~/.local/bin → /usr/local/bin の順で書き込み可能な場所を選ぶ
YQ_INSTALL_DIR="${YQ_INSTALL_DIR:-}"

detect_package_manager() {
    if command -v brew &>/dev/null; then
        echo "brew"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# Mike Farah yq v4 の version 文字列か（agent-config-mirror と同じ契約）
yq_version_is_mikefarah_v4() {
    local version="${1:-}"
    case "$version" in
        *github.com/mikefarah/yq*'version v4.'*) return 0 ;;
        *) return 1 ;;
    esac
}

# multi-agent.sh / setup が使う式が動くか。version 文字列の偽装だけを通さない。
yq_capability_probe() {
    local sample out
    sample=$'version: "2.0"\nmode: distributed\ntasks:\n  review: {}\nagents:\n  a: 1\n'

    if ! out="$(printf '%s' "$sample" | yq -r '.version // "unknown"' 2>&1)"; then
        return 1
    fi
    [[ "$out" == "2.0" ]] || return 1

    if ! out="$(printf '%s' "$sample" | yq -r '.mode // ""' 2>&1)"; then
        return 1
    fi
    [[ "$out" == "distributed" ]] || return 1

    if ! out="$(printf '%s' "$sample" | yq -r '.tasks | keys | .[]' 2>&1)"; then
        return 1
    fi
    [[ "$out" == "review" ]] || return 1

    if ! out="$(printf '%s' "$sample" | yq -r '.agents | keys | length' 2>&1)"; then
        return 1
    fi
    [[ "$out" == "1" ]] || return 1

    # パース可否チェック（multi-agent.sh load_config と同じ形）
    if ! printf '%s' "$sample" | yq '.' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# PATH 上の yq が使える Mike Farah v4 なら 0。検出結果は REPLY に入れる。
yq_is_compatible() {
    REPLY=""
    if ! command -v yq &>/dev/null; then
        REPLY="yq が PATH 上にありません"
        return 1
    fi

    local version path
    path="$(command -v yq)"
    if ! version="$(yq --version 2>&1)"; then
        REPLY="yq --version の実行に失敗しました（path=${path}）: ${version}"
        return 1
    fi
    version="$(printf '%s\n' "$version" | head -1)"

    if ! yq_version_is_mikefarah_v4 "$version"; then
        REPLY="Mike Farah yq v4 ではありません（path=${path} / version=${version}）"
        return 1
    fi

    if ! yq_capability_probe; then
        REPLY="yq v4 の capability probe に失敗しました（path=${path} / version=${version}）。必要な式（-r / // / keys / length）が使えません"
        return 1
    fi

    REPLY="${version} [${path}]"
    return 0
}

yq_manual_install_hint() {
    print_info "手動インストール（Mike Farah yq v4）:"
    print_info "  macOS:  brew install yq"
    print_info "  Linux:  公式バイナリを PATH へ配置"
    print_info "    curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o ~/.local/bin/yq && chmod +x ~/.local/bin/yq"
    print_info "    # arm64 の場合は yq_linux_arm64 を使う"
    print_info "  詳細: https://github.com/mikefarah/yq#install"
    print_info "  注意: Ubuntu 等の distro パッケージ（apt/yum の yq）は別実装のことがあり非対応"
}

yq_binary_asset_name() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        i386|i686) arch="386" ;;
        *)
            print_error "未対応の CPU アーキテクチャです: $(uname -m)"
            return 1
            ;;
    esac
    case "$os" in
        linux|darwin) echo "yq_${os}_${arch}" ;;
        *)
            print_error "未対応の OS です: ${os}（Mike Farah yq の公式バイナリ導入は linux/darwin のみ）"
            return 1
            ;;
    esac
}

# dest に公式バイナリを落とす。YQ_GITHUB_BASE_URL で差し替え可。
# - 通常: https://github.com/mikefarah/yq/releases/latest/download
# - テスト/air-gapped: ローカルディレクトリを指定するとネットワーク無しで cp する
download_yq_binary_to() {
    local dest="$1"
    local asset url src
    asset="$(yq_binary_asset_name)" || return 1

    # ローカルディレクトリ指定（offline fixture / air-gapped mirror）
    if [[ -d "$YQ_GITHUB_BASE_URL" ]]; then
        src="${YQ_GITHUB_BASE_URL%/}/${asset}"
        if [[ ! -f "$src" ]]; then
            print_error "ローカル yq アセットが見つかりません: $src"
            return 1
        fi
        if ! cp "$src" "$dest"; then
            print_error "ローカル yq アセットのコピーに失敗しました: $src"
            return 1
        fi
        chmod +x "$dest" || return 1
        return 0
    fi

    url="${YQ_GITHUB_BASE_URL%/}/${asset}"

    if command -v curl &>/dev/null; then
        if ! curl -fsSL "$url" -o "$dest"; then
            print_error "yq バイナリの取得に失敗しました: $url"
            return 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -qO "$dest" "$url"; then
            print_error "yq バイナリの取得に失敗しました: $url"
            return 1
        fi
    else
        print_error "curl または wget が必要です（yq バイナリのダウンロード用）"
        return 1
    fi

    chmod +x "$dest" || return 1
    return 0
}

# 書き込み可能な配置先を決める。YQ_INSTALL_DIR があればそれを優先。
resolve_yq_install_dir() {
    local candidate
    if [[ -n "$YQ_INSTALL_DIR" ]]; then
        echo "$YQ_INSTALL_DIR"
        return 0
    fi
    for candidate in "${HOME}/.local/bin" "/usr/local/bin"; do
        if [[ -d "$candidate" && -w "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
        # 親が書ければ mkdir して使う（~/.local/bin が未作成の典型ケース）
        if [[ ! -e "$candidate" ]]; then
            if mkdir -p "$candidate" 2>/dev/null && [[ -w "$candidate" ]]; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    # sudo で /usr/local/bin へ置く前提の候補を返す（実書き込みは install 側）
    echo "/usr/local/bin"
    return 0
}

install_yq_from_github() {
    local dir dest tmp
    dir="$(resolve_yq_install_dir)" || return 1
    dest="${dir}/yq"

    if ! tmp="$(mktemp "${TMPDIR:-/tmp}/yq-install.XXXXXX" 2>/dev/null)"; then
        print_error "一時ファイルを作成できません（yq バイナリのダウンロード先）"
        return 1
    fi

    print_info "Mike Farah yq v4 を GitHub release から取得します..."
    if ! download_yq_binary_to "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    # 先にディレクトリを用意し、書けなければ sudo へ倒す
    if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
        if ! mv -f "$tmp" "$dest"; then
            print_error "yq を配置できません: $dest"
            rm -f "$tmp"
            return 1
        fi
        chmod +x "$dest" || true
    elif command -v sudo &>/dev/null; then
        if ! sudo mkdir -p "$dir"; then
            print_error "sudo でもインストール先を作成できません: $dir"
            rm -f "$tmp"
            return 1
        fi
        if ! sudo mv -f "$tmp" "$dest"; then
            print_error "sudo でも yq を配置できません: $dest"
            rm -f "$tmp"
            return 1
        fi
        sudo chmod +x "$dest" || true
    else
        print_error "書き込み可能なインストール先がありません（試行: ${dest}）"
        print_info "YQ_INSTALL_DIR に書けるディレクトリを指定するか、手動で配置してください"
        rm -f "$tmp"
        return 1
    fi

    # 常に配置先を PATH 先頭へ置く。既に PATH 後方にあるだけでは、前方の
    # distro/python yq が勝ち続けて post-install 検証が永久に失敗する（Issue #271）。
    export PATH="${dir}:${PATH}"
    # bash の command hash が旧 yq を掴んだままだと PATH 更新が効かない
    hash -r 2>/dev/null || true
    print_info "PATH 先頭に ${dir} を置きました（このシェルセッション内）"
    print_info "永続利用には shell の PATH に ${dir} を追加してください（未設定の場合）"

    print_info "配置: $dest"
    return 0
}

install_yq() {
    local pkg_mgr
    pkg_mgr="$(detect_package_manager)"

    case "$pkg_mgr" in
        brew)
            # Homebrew の yq formula は Mike Farah 実装（macOS / Linuxbrew 共通）。
            brew install yq
            # brew 後も command hash と前方の stale yq を避ける
            hash -r 2>/dev/null || true
            ;;
        *)
            # apt/yum/pacman の yq パッケージは distro によって別実装になる。
            # パッケージ名に依存せず、公式 GitHub release バイナリを明示取得する。
            install_yq_from_github
            ;;
    esac
}

# yq の存在確認 → 必要なら導入 → 必ず post-install で flavor/version/capability を検証。
# 成功時 0、利用不可なら 1（成功表示はしない）。
ensure_yq() {
    if yq_is_compatible; then
        print_success "yq: $REPLY"
        return 0
    fi

    local prior_reason="$REPLY"

    if command -v yq &>/dev/null; then
        print_error "PATH 上の yq は利用できません: ${prior_reason}"
        if [[ "$SKIP_INSTALL" == "true" ]]; then
            print_warning "--skip-install のため自動導入を行いません"
            yq_manual_install_hint
            return 1
        fi
        print_warning "互換な Mike Farah yq v4 の導入を試みます..."
    else
        if [[ "$SKIP_INSTALL" == "true" ]]; then
            print_warning "yq が未インストール（--skip-install のためスキップ）"
            yq_manual_install_hint
            return 1
        fi
        print_warning "yq が未インストール — Mike Farah yq v4 のインストールを開始します..."
    fi

    if ! install_yq; then
        print_error "yq のインストールに失敗しました"
        yq_manual_install_hint
        return 1
    fi

    # install の exit 0 を信用しない（ACE-66-1）。実体・flavor・capability を再検証。
    if yq_is_compatible; then
        print_success "yq: インストール完了（${REPLY}）"
        return 0
    fi

    print_error "yq を導入したあとでも利用できません: ${REPLY:-unknown}"
    print_info "別実装の yq が PATH 前方に残っている可能性があります（command -v yq → $(command -v yq 2>/dev/null || echo 'なし')）"
    yq_manual_install_hint
    return 1
}

check_and_install_dependencies() {
    print_step 2 "依存ツールを確認中..."

    local yq_ok=true
    if ! ensure_yq; then
        yq_ok=false
    fi

    if command -v gh &>/dev/null; then
        print_success "gh (GitHub CLI): $(gh --version 2>/dev/null | head -1)"
    else
        print_warning "gh (GitHub CLI) が未インストール（オプション）"
        print_info "PR連携に必要: brew install gh (macOS) / 公式: https://cli.github.com/"
    fi

    if [[ "$yq_ok" != "true" ]]; then
        return 1
    fi
    return 0
}

# ── Step 3: Detect AI CLIs ──

detect_ai_clis() {
    print_step 3 "AI CLI を検出中..."

    local found=0
    local total=5

    local clis="claude-code:claude:Premium
codex-cli:codex:Standard
copilot-cli:copilot:Metered
gemini-cli:gemini:Free-tier
grok-cli:grok:Flat-rate"

    while IFS=: read -r name cmd tier; do
        if command -v "$cmd" &>/dev/null; then
            local path
            path="$(which "$cmd")"
            print_success "$name ($cmd) — $tier [$path]"
            found=$((found + 1))
        else
            print_warning "$name ($cmd) — 未インストール"
        fi
    done <<< "$clis"

    echo ""
    if [[ $found -eq 0 ]]; then
        print_error "AI CLI が1つもインストールされていません"
        echo ""
        print_info "以下のいずれかをインストールしてください:"
        print_info "  Claude Code:  npm install -g @anthropic-ai/claude-code"
        print_info "  Codex CLI:    npm install -g @openai/codex"
        print_info "  Copilot CLI:  gh extension install github/gh-copilot"
        print_info "  Gemini CLI:   npm install -g @google/gemini-cli"
        print_info "  Grok CLI:     npm install -g @xai-official/grok"
        exit 1
    else
        print_success "${found}/${total} の AI CLI が利用可能です"
        if [[ $found -lt $total ]]; then
            echo ""
            print_info "未インストールの CLI はフォールバック設定で他の CLI に再分配されます"
        fi
    fi
}

# ── Step 4: Show Install Guides ──

show_install_guides() {
    print_step 4 "未インストール CLI のインストールガイド..."

    local all_installed=true

    if ! command -v claude &>/dev/null; then
        all_installed=false
        echo ""
        echo -e "  ${BOLD}Claude Code (Premium tier — 高度な分析に最適)${NC}"
        print_info "  npm install -g @anthropic-ai/claude-code"
        print_info "  https://claude.ai/code"
    fi

    if ! command -v codex &>/dev/null; then
        all_installed=false
        echo ""
        echo -e "  ${BOLD}Codex CLI (Standard tier — クロスモデルレビューに最適)${NC}"
        print_info "  npm install -g @openai/codex"
        print_info "  https://github.com/openai/codex"
    fi

    if ! command -v copilot &>/dev/null; then
        all_installed=false
        echo ""
        echo -e "  ${BOLD}Copilot CLI (Metered — 従量課金。review 既定ラインナップ外・オプトイン)${NC}"
        print_info "  gh extension install github/gh-copilot"
        print_info "  https://docs.github.com/en/copilot/github-copilot-in-the-cli"
    fi

    if ! command -v gemini &>/dev/null; then
        all_installed=false
        echo ""
        echo -e "  ${BOLD}Gemini CLI (Free tier — 無料枠でセキュリティスキャンに最適)${NC}"
        print_info "  npm install -g @google/gemini-cli"
        print_info "  https://github.com/google-gemini/gemini-cli"
    fi

    if ! command -v grok &>/dev/null; then
        all_installed=false
        echo ""
        echo -e "  ${BOLD}Grok CLI (Flat-rate — サブスクリプション。--sandbox read-only で読み取り専用レビュー)${NC}"
        print_info "  npm install -g @xai-official/grok"
    fi

    if [[ "$all_installed" == "true" ]]; then
        print_success "全5つの AI CLI がインストール済みです！"
    fi
}

# ── Step 5: Verification ──

run_verification() {
    print_step 5 "動作確認 (--dry-run) — 全タスクタイプ..."

    local all_passed=true

    # Review
    echo ""
    echo -e "  ${BOLD}🔍 Review タスク:${NC}"
    if bash "$SCRIPT_DIR/multi-agent.sh" --task review --dry-run 2>&1; then
        print_success "Review: OK"
    else
        print_error "Review: 失敗"
        all_passed=false
    fi

    # Explore
    echo ""
    echo -e "  ${BOLD}🔭 Explore タスク:${NC}"
    if bash "$SCRIPT_DIR/multi-agent.sh" --task explore --description "セットアップ検証" --dry-run 2>&1; then
        print_success "Explore: OK"
    else
        print_error "Explore: 失敗"
        all_passed=false
    fi

    # Implement
    echo ""
    echo -e "  ${BOLD}🛠️  Implement タスク:${NC}"
    if bash "$SCRIPT_DIR/multi-agent.sh" --task implement --description "セットアップ検証" --dry-run 2>&1; then
        print_success "Implement: OK"
    else
        print_error "Implement: 失敗"
        all_passed=false
    fi

    # Backward compat
    echo ""
    echo -e "  ${BOLD}↪ 後方互換 (multi-review.sh):${NC}"
    if [[ -f "$SCRIPT_DIR/multi-review.sh" ]]; then
        if bash "$SCRIPT_DIR/multi-review.sh" --dry-run 2>&1; then
            print_success "multi-review.sh (wrapper): OK"
        else
            print_warning "multi-review.sh (wrapper): 失敗（後方互換の問題）"
            all_passed=false
        fi
    else
        print_warning "multi-review.sh 未同梱 — スキップ"
    fi

    echo ""
    if [[ "$all_passed" == "true" ]]; then
        print_success "全タスクタイプの動作確認完了！"
    else
        print_error "一部の動作確認に失敗しました"
        print_info "エラーを確認し、依存ツールが正しくインストールされているか確認してください"
        exit 1
    fi
}

# ── Step 6: Config Check ──

check_config() {
    print_step 6 "設定ファイルを確認中..."

    # Mirror multi-agent.sh's 3-layer resolution (env > project override > plugin default)
    local project_root effective_config config_src
    project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [[ -n "${MULTI_AGENT_CONFIG:-}" ]]; then
        effective_config="$MULTI_AGENT_CONFIG"; config_src="MULTI_AGENT_CONFIG env"
    elif [[ -f "$project_root/.claude/agent-config.yaml" ]]; then
        effective_config="$project_root/.claude/agent-config.yaml"; config_src="project override"
    else
        effective_config="$SCRIPT_DIR/agent-config.yaml"; config_src="plugin default"
    fi
    echo "  Effective config: ${effective_config} (${config_src})"

    if command -v yq &>/dev/null && [[ -f "$effective_config" ]]; then
        local version
        version=$(yq -r '.version // "unknown"' "$effective_config" 2>/dev/null || echo "unknown")
        print_success "Config version: ${version}"

        local task_types
        task_types=$(yq -r '.tasks | keys | .[]' "$effective_config" 2>/dev/null || echo "")
        if [[ -n "$task_types" ]]; then
            print_success "タスクタイプ: $(echo "$task_types" | tr '\n' ', ' | sed 's/,$//')"
        fi

        local agent_count
        agent_count=$(yq -r '.agents | keys | length' "$effective_config" 2>/dev/null || echo "0")
        print_success "エージェント定義: ${agent_count}"
    else
        print_warning "設定ファイルの詳細確認をスキップ（yq未インストールまたはファイル未存在）"
    fi
}

# ── Summary ──

print_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "============================================================"
    echo "  セットアップ完了"
    echo "============================================================"
    echo -e "${NC}"
    echo "使い方:"
    echo ""
    echo "  # Claude Code から（スラッシュコマンド）"
    echo "  /multi-review                    # コードレビュー"
    echo "  /multi-explore 認証フローの調査    # コードベース探索"
    echo "  /multi-implement バリデーション追加  # 並列実装"
    echo ""
    echo "  # ターミナルから直接"
    echo "  bash \"$SCRIPT_DIR/multi-agent.sh\" --task review --dry-run"
    echo "  bash \"$SCRIPT_DIR/multi-agent.sh\" --task explore --description '調査内容' --dry-run"
    echo "  bash \"$SCRIPT_DIR/multi-agent.sh\" --task implement --description '実装内容' --dry-run"
    echo ""
    echo "  # 後方互換（review のみ）"
    echo "  bash \"$SCRIPT_DIR/multi-review.sh\" --dry-run"
    echo ""
    echo "  # レビュワー（主 + 副）の設定 — 主に全観点、副に総合レビュー1本"
    echo "  bash \"$SCRIPT_DIR/multi-agent.sh\" --task review --print-reviewers"
    echo "  bash \"$SCRIPT_DIR/multi-agent.sh\" --task review --set-reviewers main=<cli>,sub=<cli>"
    echo "    主 = メインで使う CLI / 副 = もう1つの CLI（省略可）"
    echo "    保存するのは CLI 名だけ。モデルは各 CLI 自身の設定に委ねます"
    echo ""
    echo "  # 設定カスタマイズ（プロジェクト側 override が同梱デフォルトより優先）"
    echo "  cp \"$SCRIPT_DIR/agent-config.yaml\" .claude/agent-config.yaml && vim .claude/agent-config.yaml"
    echo ""
    echo "詳細: プラグイン同梱 docs-template/05-operations/deployment/multi-cli-review-orchestration.md"
    echo ""
}

# ============================================================================
# Main
# ============================================================================

main() {
    for arg in "$@"; do
        case "$arg" in
            --skip-install) SKIP_INSTALL=true ;;
            --help|-h)      show_help; exit 0 ;;
            *)
                echo "Unknown option: $arg" >&2
                echo "Run with --help for usage" >&2
                exit 1
                ;;
        esac
    done

    print_header
    check_prerequisites
    if ! check_and_install_dependencies; then
        print_error "必須依存（Mike Farah yq v4）が揃っていません。セットアップを中断します"
        exit 1
    fi
    detect_ai_clis
    show_install_guides
    run_verification
    check_config
    print_summary
}

# 直接実行時だけ main を走らせる（テストから関数を source できるようにする）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
