#!/usr/bin/env bash
# ============================================================================
# codex-review.sh — Codex cross-model レビューの薄いシム
# ============================================================================
#
# 本体は何もしない。`multi-agent.sh --task review --cli codex-cli` へ委譲する。
#
# ## なぜシムなのか
#
# 以前このファイルは各プロジェクトが自前で持つ 80〜390 行のラッパーで、
# `review-common.sh` / `review-prompts.sh` と合わせて 3 本 1 組だった。同じ仕事を
# オーケストレータと二重に持っていたため、7 リポジトリで 13 通りに分岐し、
# 依存欠落で起動できないコピーや、下記の stdin の罠を踏むコピーが生まれた
# （Issue #406）。実装をオーケストレータ 1 本へ寄せ、この入口は名前と
# コマンドラインの互換だけを担う。
#
# ## 直接 `codex exec` を叩かない理由（重要）
#
# codex は stdin が TTY でないと「追加入力」として読みに行き、EOF が来るまで
# ブロックする。stdout には何も出ないので、外からはハングと区別がつかない。
# 実測（codex-cli 0.144.5）:
#
#   codex exec -s read-only "..." </dev/null  → rc=0 で完走
#   同上・stdin を開いたまま同期実行          → EOF が来るまで戻らない
#
# 見分け方に注意: "Reading additional input from stdin..." は**成功時にも出る**ので、
# その行の有無では判別できない。ハングを示すのは **stdout が 0 バイトのまま**という
# 事実の方。所要時間はモデル側の待ち時間で変動するので基準にしない。
#
# multi-agent.sh は `run_with_timeout` 経由で CLI を起動し、そこは
# `"$@" >"$out_file" &` と**非同期**なので、POSIX により非対話シェルの非同期
# リストの stdin は /dev/null に割り当てられる。委譲している限りこの罠は
# 構造的に起きない。`tests/review-wrapper-shim/` がこのファイルに
# 「AI CLI を直接起動しないこと」を機械的に課している。
#
# ## 受け付けないものは黙って捨てない
#
# シムは薄いので、旧ラッパーが持っていた機能の大半を持たない。渡されたものを
# 黙って無視すると、利用者は指定したつもりのまま既定設定でレビューが走り、
# 成果物からもログからも判別できない（ACE-70-2 が記録した実害と同じ形）。
# 未対応のオプション・環境変数は非 0 で拒否し、正規の経路を案内する。
#
# ## 使い方
#
#   bash scripts/codex-review.sh [--base <branch>] [--reviewers a,b,c]
#                                [--timeout <秒>] [--dry-run]
#
#   SKIP_CODEX_REVIEW=1  レビューを実行せず成功終了する（pre-commit の逃がし弁）
#
#   モデル / reasoning effort の指定は toolkit の正規経路を使う:
#     MULTI_AGENT_MODEL_CODEX_CLI=<model>     モデルを明示する
#     MULTI_AGENT_CODEX_PROFILE=<profile>     ~/.codex/<name>.config.toml を層に重ねる
#   （両者は同時指定できない。詳細は skills/multi-review/SKILL.md の「モデル選択」）
# ============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# ── オーケストレータの解決 ──────────────────────────────────────────────────────
#
# 探索順は FF_DEV_TOOLKIT_ROOT（環境変数）→ 同じディレクトリのサイドカー
# `.ff-dev-toolkit-root`（setup が書く）。どちらも解決できなければ推測で走らずに
# 落とす — 「オーケストレータが無い」を「レビュー結果が空」に化けさせない。
#
# **このファイルへパスを焼き込まない**理由が 3 つある:
#   1. 焼き込むと配置後のファイルがマシン固有になる。配置先の scripts/ は通常
#      git 管理下なので、開発者ごとに違う行がコミットされ、他人の環境や CI で壊れる。
#   2. 焼き込み値は toolkit のバージョン付きインストール先を含むため、更新のたびに
#      内容が変わる。冪等配置の比較が毎回不一致になり、利用者の .bak が上書きされ続ける。
#   3. 置換で生成するのはシェルコードなので、パスに含まれる & や $ や " が
#      構文を壊す（実測で `/a&b/` が代入行を破壊した）。
# サイドカーは**素のデータ 1 行**なので、どれも起こらない。読み取りも read -r だけで
# eval を通さない。
#
# 固定パスの当て推量もしない。実インストール先は
# ~/.claude/plugins/cache/<marketplace>/ff-dev-toolkit/<version>/scripts/ の形で
# **複数バージョンが同居する**（実測で 0.9.0 / 0.14.0 / 0.19.0 が並存）。glob で
# 拾うと古い版を静かに選びうる。
FF_ROOT_SIDECAR_NAME=".ff-dev-toolkit-root"

# 候補が「本当に multi-agent.sh か」まで見る。存在だけを見ると、0 バイトのファイルや
# 無関係なスクリプトを掴んで **rc=0・出力ゼロ** で終わる — 元のバグと同じ signature に
# なる（実測: 0 バイトの multi-agent.sh を指すと、シムは何も出さず成功した）。
usable_orchestrator() {
  local f="$1"
  [ -f "$f" ] && [ -r "$f" ] && [ -s "$f" ] || return 1
  # オーケストレータであることの印。--task の 3 値は multi-agent.sh の中核契約で、
  # 別スクリプトに偶然含まれることは考えにくい。
  grep -q -- "--task" "$f" && grep -q -- "implement" "$f"
}

resolve_orchestrator() {
  local candidate sidecar sidecar_value
  local -a env_candidates=() candidates=()
  if [ -n "${FF_DEV_TOOLKIT_ROOT:-}" ]; then
    # skill 群は FF_DEV_TOOLKIT_ROOT を**プラグインルート**として定義し
    # ${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh を叩く。scripts/ を直接指す
    # 使い方も許すため両方を候補にする（前者が正規形）。
    env_candidates=("${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh"
                    "${FF_DEV_TOOLKIT_ROOT}/multi-agent.sh")
    candidates+=("${env_candidates[@]}")
  fi
  sidecar="$(dirname "$0")/${FF_ROOT_SIDECAR_NAME}"
  if [ -f "$sidecar" ]; then
    IFS= read -r sidecar_value < "$sidecar" || sidecar_value=""
    if [ -n "$sidecar_value" ]; then
      candidates+=("${sidecar_value}/multi-agent.sh")
    fi
  fi

  # 明示指定が使えないときに黙ってサイドカーへ落ちない。利用者が
  # FF_DEV_TOOLKIT_ROOT でローカルの改造版を指したのにパスを間違えた場合、
  # 落ちた先は**インストール済みの toolkit** で、出力は正常に見える。指定が
  # 効かなかったことに気づけないまま「改造が効かない」と結論することになる。
  if [ "${#env_candidates[@]}" -gt 0 ]; then
    local env_ok=false
    for candidate in "${env_candidates[@]}"; do
      if usable_orchestrator "$candidate"; then env_ok=true; break; fi
    done
    if [ "$env_ok" != "true" ]; then
      echo "ERROR: FF_DEV_TOOLKIT_ROOT が設定されていますが、使える multi-agent.sh がありません。" >&2
      for candidate in "${env_candidates[@]}"; do
        echo "       試したパス: ${candidate}" >&2
      done
      echo "       明示指定を黙って無視して別の toolkit で走ることはしません。" >&2
      return 2
    fi
  fi

  # bash 3.2 は set -u 下で空配列を "${a[@]}" と展開すると unbound variable で落ちる
  for candidate in ${candidates[@]+"${candidates[@]}"}; do
    if usable_orchestrator "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

usage() {
  cat >&2 <<USAGE
${SCRIPT_NAME} — Codex cross-model レビュー（multi-agent.sh への薄いシム）

  --base <branch>       差分の基準ブランチ
  --reviewers a,b,c     観点をカンマ区切りで指定（--perspective へ展開される）

    ⚠ 観点名は toolkit の perspective 名であり、旧ラッパーが使っていた
      Claude エージェント名とは**別体系**。存在しない名前は multi-agent.sh が
      非 0 で拒否する（黙って既定へ落ちることはない）。
        旧 code-reviewer          → code-review
        旧 silent-failure-hunter  → error-handler-hunt
        旧 type-design-analyzer   → type-design-analysis
        旧 comment-analyzer       → comment-analysis
        旧 pr-test-analyzer       → test-analysis
        旧 code-simplifier        → code-simplification
      実在する review 観点: code-review / code-simplification / comment-analysis /
      comprehensive-review / error-handler-hunt / security-analysis /
      test-analysis / type-design-analysis

  --timeout <秒>        CLI ごとの制限時間
  --dry-run             実行せずプランだけ表示する
  --help                このヘルプ

  SKIP_CODEX_REVIEW=1   レビューを実行せず成功終了する

モデル指定は MULTI_AGENT_MODEL_CODEX_CLI / MULTI_AGENT_CODEX_PROFILE を使う。
ここに無いオプションは、直接 multi-agent.sh を呼んで指定する:
  bash <toolkit>/scripts/multi-agent.sh --task review --cli codex-cli ...
USAGE
}

# ── 引数の解釈 ──────────────────────────────────────────────────────────────────
ORCH_ARGS=(--task review --cli codex-cli)

while [ $# -gt 0 ]; do
  case "$1" in
    --base|--timeout)
      if [ $# -lt 2 ]; then
        echo "ERROR: ${1} には値が必要です。" >&2
        usage
        exit 2
      fi
      ORCH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --dry-run)
      ORCH_ARGS+=(--dry-run)
      shift
      ;;
    --reviewers)
      if [ $# -lt 2 ]; then
        echo "ERROR: --reviewers には値が必要です（例: --reviewers code-reviewer,silent-failure-hunter）。" >&2
        exit 2
      fi
      # カンマ区切りを 1 件ずつ --perspective へ展開する。multi-agent.sh 側は
      # --perspective の繰り返しで観点を絞る仕様なので、カンマのまま渡すと
      # 「そんな観点は無い」ではなく**観点名として 1 件**に見えてしまう。
      #
      # 分解は**パラメータ展開だけ**で行い、位置パラメータには触らない。初版は
      # IFS=',' にして `set -- $2 "${@:3}"` で並べ直していたが、これは後続の引数を
      # 連結してしまい（実測: `--reviewers a --timeout 420` が `--timeout 420` という
      # 1 引数になった）、対応しているはずの --timeout が「受け付けません」と
      # 拒否された。実 CLI 実行で初めて露見した — 単体で --reviewers を渡す
      # テストしか無かったため、他オプションと併用する形が検査されていなかった。
      # 空値・空要素を読み飛ばすと --perspective が 1 件も付かず、**既定の観点セットが
      # 黙って走る**。指定したつもりの利用者は、意図しない観点に課金される
      # （このファイルの冒頭が「黙って捨てない」と宣言している当のクラス）。
      case "$2" in
        ""|*,,*|,*|*,)
          echo "ERROR: --reviewers の値が空、または空の要素を含んでいます: '${2}'" >&2
          echo "       観点を 1 つ以上、カンマ区切りで指定してください（例: --reviewers code-review）。" >&2
          exit 2 ;;
      esac
      _list="$2"
      while [ -n "$_list" ]; do
        _item="${_list%%,*}"
        if [ "$_item" = "$_list" ]; then _list=""; else _list="${_list#*,}"; fi
        [ -n "$_item" ] || continue
        # 旧ラッパーが使っていた Claude エージェント名を、toolkit の perspective 名へ
        # 写す。ヘルプに対応表を載せただけでは足りない — 既存の運用手順やコピペされた
        # コマンドはそのまま旧名を渡してくるので、変換しないと「対応表は示すのに
        # 実際には拒否される」形になる。**黙って読み替えず 1 行通知する**（利用者の
        # 指定と実際に走った観点が食い違ったまま気づけない状態にしない）。
        # toolkit が文書化している改称は 6 件。3 件だけ写すと、文書どおりの
        # 6 件指定コマンドが未対応の 1 件目で拒否され**レビューが 1 件も走らない**
        # （実測: `perspective 'comment-analyzer' does not exist` で rc=1）。
        # 対応表は COPILOT_AGENTS.md / REVIEW_AGENT_CREATION_GUIDE.md と同じ 6 件。
        case "$_item" in
          code-reviewer)         _mapped="code-review" ;;
          silent-failure-hunter) _mapped="error-handler-hunt" ;;
          type-design-analyzer)  _mapped="type-design-analysis" ;;
          comment-analyzer)      _mapped="comment-analysis" ;;
          pr-test-analyzer)      _mapped="test-analysis" ;;
          code-simplifier)       _mapped="code-simplification" ;;
          *)                     _mapped="$_item" ;;
        esac
        if [ "$_mapped" != "$_item" ]; then
          echo "ℹ️  旧観点名 '${_item}' を '${_mapped}' として解釈しました（perspective 名へ改称済み）。" >&2
        fi
        ORCH_ARGS+=(--perspective "$_mapped")
      done
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: ${SCRIPT_NAME} は '${1}' を受け付けません。" >&2
      echo "       このシムが担うのは --base / --reviewers / --timeout / --dry-run だけです。" >&2
      echo "       それ以外は multi-agent.sh を直接呼んで指定してください:" >&2
      echo "         bash <toolkit>/scripts/multi-agent.sh --task review --cli codex-cli ${1} ..." >&2
      exit 2
      ;;
  esac
done

# ── 逃がし弁 ────────────────────────────────────────────────────────────────────
# pre-commit 構成が使う実在のつまみ。尊重しないと「skip したはずのレビューが走る」。
if [ "${SKIP_CODEX_REVIEW:-}" = "1" ]; then
  echo "ℹ️  SKIP_CODEX_REVIEW=1 のため Codex レビューをスキップします。" >&2
  exit 0
fi

# ── 効かない設定を黙って通さない ────────────────────────────────────────────────
# 旧ラッパーは CODEX_MODEL / CODEX_REASONING_EFFORT を解釈していた。シムはこれらを
# 使わないので、設定されたまま走ると「指定したつもりの設定が効いていない」状態に
# なる。それはユーザー設定を黙って上書きしていた ACE-70-2 と同じ形の実害なので、
# 気づける形で落とす。
for _legacy in CODEX_MODEL CODEX_REASONING_EFFORT CODEX_DEFAULT_REVIEWERS; do
  eval "_legacy_value=\${${_legacy}:-}"
  if [ -n "$_legacy_value" ]; then
    echo "ERROR: ${_legacy} は ${SCRIPT_NAME} では効きません（黙って無視すると、指定したつもりのまま既定設定でレビューが走ります）。" >&2
    case "$_legacy" in
      CODEX_MODEL)
        echo "       モデルの明示指定には MULTI_AGENT_MODEL_CODEX_CLI を使ってください。" >&2 ;;
      CODEX_REASONING_EFFORT)
        echo "       reasoning effort はプロファイルで束ねてください: MULTI_AGENT_CODEX_PROFILE=<name>" >&2
        echo "       （~/.codex/<name>.config.toml にモデルと effort を 1 ファイルで書く）" >&2 ;;
      CODEX_DEFAULT_REVIEWERS)
        echo "       観点の既定は --reviewers で渡すか、agent-config.yaml で設定してください。" >&2 ;;
    esac
    exit 2
  fi
done

# ── 委譲 ────────────────────────────────────────────────────────────────────────
if ! ORCHESTRATOR="$(resolve_orchestrator)"; then
  echo "ERROR: multi-agent.sh が見つかりません。" >&2
  echo "       探索順: FF_DEV_TOOLKIT_ROOT → $(dirname "$0")/${FF_ROOT_SIDECAR_NAME}" >&2
  if [ -f "$(dirname "$0")/${FF_ROOT_SIDECAR_NAME}" ]; then
    echo "       サイドカーは在りますが、指す先に multi-agent.sh がありません" >&2
    echo "       （toolkit を更新・移動した場合は setup-multi-agent.sh を再実行してください）。" >&2
  else
    echo "       サイドカーがありません。setup-multi-agent.sh を実行して配置し直すか、" >&2
    echo "       FF_DEV_TOOLKIT_ROOT を toolkit のプラグインルートへ向けてください。" >&2
  fi
  exit 1
fi

exec bash "$ORCHESTRATOR" "${ORCH_ARGS[@]}"
