#!/usr/bin/env bash
#
# 公開 CHANGELOG の契約検査（Issue #800 で changelog-version と統合）。
#
# 2 つの関心事を 1 本で見る。どちらも**同じ CHANGELOG を同じ手順で解決し、外部依存を
# 持たず read-only 環境で完走する**ため、可用性条件が一致する（統合の前提。可用性条件が
# 違う suite を混ぜると、片方の skip がもう片方の検査を道連れにする — ACE-927-3）。
#
#   1. 版の一致: plugin.json の version が CHANGELOG の最新の日付つき版見出しと
#      agent-config.yaml の toolkit_version の両方と一致する（[Unreleased] は除く）
#   2. 参照の境界: 公開 CHANGELOG に、公開側から辿れない SSOT の Issue / PR 番号が
#      残っていない
#
# **2 つの検査は互いに独立に走らせ、両方を実行してから終了コードを決める。**
# 統合前は run-all が別 suite として起動していたため、前段の前提不足（jq 不在など）が
# 後段を道連れにすることは無かった。1 本に畳んだ時点でプロセス境界が消えるので、
# 前段の early exit をそのまま残すと**後段が到達不能になる経路**が生まれる
# （レビュー指摘。統合の前提「可用性条件の一致」はプロセス境界の消失まで含めて見る）。
#
# 検査 1 は旧 `changelog-version` suite（統合前は独立していた）。名前でこの suite を
# 探していた文書・ADR・アーカイブ済み Playbook は当時の名前のまま残す（歴史引用は
# 改変しない。ACE-124-1）。
#
# Layout resolution:
#   SSOT monorepo:  oss/ff-dev-toolkit/CHANGELOG.md
#   Public checkout: CHANGELOG.md at repo root
#
# テスト用 env（通常は未設定のまま使う。設定時は ⚠ を stderr に出す）:
#   FF_CHANGELOG_PUBLIC_REFERENCES_FILE  参照境界の検査対象を差し替える
#                                        （tests/changelog-contract-selftest/ が
#                                        fixture で検出力を実測する）。**版の一致
#                                        （検査 1）は差し替えの影響を受けない** —
#                                        差し替えは fixture を検査対象にするための
#                                        シームであって、実 CHANGELOG の版検査を
#                                        止める口ではない
#
# 一時ファイル・here-doc を使わない（read-only 環境で動かすため）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
AGENT_CONFIG="$PLUGIN_ROOT/scripts/agent-config.yaml"

CONTRACT_FAIL=0
contract_fail() { echo "✗ $*" >&2; CONTRACT_FAIL=1; }

# ---- 検査 1: 版の一致（旧 changelog-version）--------------------------------
# 実 CHANGELOG を解決する。参照境界の差し替えシームはここへ効かせない
# （fixture を渡した実行でも、版の一致は実リポジトリに対して測る）。
check_version_alignment() {
  local real_changelog="" plugin_ver agent_ver changelog_ver
  if [[ -f "$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" ]]; then
    real_changelog="$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
  elif [[ -f "$REPO_ROOT/CHANGELOG.md" ]]; then
    real_changelog="$REPO_ROOT/CHANGELOG.md"
  else
    contract_fail "CHANGELOG.md not found (looked under oss/ff-dev-toolkit/ and repo root)"
    return 0
  fi
  [[ -f "$PLUGIN_JSON" ]]   || { contract_fail "plugin.json not found: $PLUGIN_JSON"; return 0; }
  [[ -f "$AGENT_CONFIG" ]]  || { contract_fail "agent-config.yaml not found: $AGENT_CONFIG"; return 0; }
  command -v jq >/dev/null 2>&1 || { contract_fail "jq is required for the version check"; return 0; }

  plugin_ver="$(jq -er '.version | strings | select(length > 0)' "$PLUGIN_JSON" 2>/dev/null)" \
    || { contract_fail "plugin.json の version を読み取れません: $PLUGIN_JSON"; return 0; }
  if [[ ! "$plugin_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
    contract_fail "plugin.json version is not SemVer-like: $plugin_ver"
    return 0
  fi
  agent_ver="$(sed -nE 's/^toolkit_version:[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$AGENT_CONFIG")"
  if [[ "$agent_ver" != "$plugin_ver" ]]; then
    contract_fail "version mismatch: plugin.json=$plugin_ver agent-config.yaml=${agent_ver:-missing}"
    echo "  plugin.json:       $PLUGIN_JSON" >&2
    echo "  agent-config.yaml: $AGENT_CONFIG" >&2
    return 0
  fi

  # 最初の**日付つき**版見出し: `## [x.y.z] - YYYY-MM-DD`。`grep | head` は使わない —
  # head の早期終了で上流の grep が SIGPIPE で死に、pipefail のもとでパイプライン全体が
  # 失敗扱いになる（この壊れ方は本リポジトリの他 suite でも実測されている）。
  changelog_ver="$(LC_ALL=C awk '
    match($0, /^## \[[0-9]+\.[0-9]+\.[0-9]+[^]]*\][[:space:]]*-[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
      line = $0
      sub(/^## \[/, "", line)
      sub(/\].*$/, "", line)
      print line
      exit
    }' "$real_changelog")"
  if [[ -z "$changelog_ver" ]]; then
    contract_fail "no dated release heading found in $real_changelog"
    return 0
  fi
  if [[ "$plugin_ver" != "$changelog_ver" ]]; then
    contract_fail "version mismatch: plugin.json=$plugin_ver CHANGELOG newest=$changelog_ver"
    echo "  plugin.json: $PLUGIN_JSON" >&2
    echo "  CHANGELOG:   $real_changelog" >&2
    return 0
  fi
  echo "✓ plugin.json version ($plugin_ver) matches CHANGELOG newest release heading"
  echo "✓ plugin.json version ($plugin_ver) matches agent-config.yaml toolkit_version"
}
check_version_alignment

# ---- 検査 2: 参照の境界（旧 changelog-public-references）---------------------
check_public_references() {
  local CHANGELOG=""
  if [[ -n "${FF_CHANGELOG_PUBLIC_REFERENCES_FILE:-}" ]]; then
  # テストシーム（selftest 専用。通常は未設定）。fixture を検査対象として渡す。
  # 差し替えは必ず可視化する（実 CHANGELOG を見ていない実行を緑と読み違えない）。
    CHANGELOG="$FF_CHANGELOG_PUBLIC_REFERENCES_FILE"
    echo "⚠ FF_CHANGELOG_PUBLIC_REFERENCES_FILE で検査対象を差し替えています: $CHANGELOG" >&2
    # 存在しないパスは「参照なし」ではなく失敗として扱う（fail-closed）。
    if [[ ! -f "$CHANGELOG" ]]; then
      contract_fail "FF_CHANGELOG_PUBLIC_REFERENCES_FILE が指すファイルがありません: $CHANGELOG"
      return 0
    fi
  elif [[ -f "$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" ]]; then
    CHANGELOG="$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
  elif [[ -f "$REPO_ROOT/CHANGELOG.md" ]]; then
    CHANGELOG="$REPO_ROOT/CHANGELOG.md"
  else
    contract_fail "CHANGELOG.md not found (looked under oss/ff-dev-toolkit/ and repo root)"
    return 0
  fi

# 禁止形式:
#   - Issue / PR に続く番号（# の有無を問わない）
#   - # に続く番号（前に何が付いていても検出する）
# 2 つ目は前置の制限を持たない。以前は `#` の直前に非英数字を要求していたため、
# `example-org/example-repo#12` のような owner/repo#N 完全修飾参照が
# 「直前が英数字」で素通りしていた（`#` 自体が識別子文字ではないので、この制限は
# 短縮参照の検出には何も足していない）。既知のトレードオフとして、数字だけの
# URL フラグメント（`.../CHANGELOG.md#0440` 等）も検出対象に入る — 公開
# CHANGELOG に該当記載は無く、必要になった時点で除外を設計する。
# 1 つ目は `#` を伴わない `Issue 12` / `PR 12` の形のために残している。
# バージョン番号・公開タグ・compare URL は対象外。grep 自体の異常を「一致なし」と
# 読まないよう、rc=1 だけを参照なしとして扱う。
  local MATCHES GREP_RC
  set +e
  MATCHES="$(grep -En '(^|[^[:alnum:]_])(Issue|PR)[[:space:]]*#?[0-9]+|#[0-9]+' "$CHANGELOG")"
  GREP_RC=$?
  set -e

  if [[ "$GREP_RC" -eq 0 ]]; then
    contract_fail "公開 CHANGELOG に SSOT の Issue / PR 番号参照があります:"
    printf '%s\n' "$MATCHES" >&2
    return 0
  fi
  if [[ "$GREP_RC" -ne 1 ]]; then
    contract_fail "公開 CHANGELOG の参照検査に失敗しました（grep rc=${GREP_RC}）: $CHANGELOG"
    return 0
  fi

  echo "✓ 公開 CHANGELOG に SSOT の Issue / PR 番号参照はありません"
  echo "  CHANGELOG: $CHANGELOG"
}
check_public_references

# 両方を実行してから終了コードを決める（片方の前提不足でもう片方を道連れにしない）。
exit "$CONTRACT_FAIL"
