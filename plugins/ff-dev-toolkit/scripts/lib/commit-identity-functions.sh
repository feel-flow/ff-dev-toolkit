#!/usr/bin/env bash
# shellcheck shell=bash
# 検査用の合成 git identity（user.name=fixture / user.email=*@example.invalid）のまま
# 定型コミット（knowledge / release）を作らないための共通判定。
#
# 背景: テスト fixture の identity が作業 checkout の .git/config へ漏れ、knowledge の
# 直 push が fixture 名義で統合ブランチへ入り続けた。Claude Code の PreToolUse ガードは
# コマンド文字列に現れる `git commit` しか見えないので、script の内側で打つ commit と、
# PreToolUse ガードが動かないホスト（Codex / grok）の経路には届かない。定型コミットを
# 作る script は commit の直前にこの関数を呼び、同じ条件で止まる。
#
# ff_commit_identity_check <repo>
#   0  通してよい（合成 identity ではない / identity が未設定で git 自身が止める / 判定省略）
#   1  合成 identity（stderr に復旧手順）
#   FF_DEV_TOOLKIT_SKIP=commit-identity で判定を省く（PreToolUse ガードと同じ鍵。鍵の名簿は
#   l4-declarations.tsv、判定は同じ置き場の l4-declarations.sh。ADR-087）
#
# 判定の lib は、呼び出し側が既に読んでいれば読み直さない。読めない配置（この lib だけを写した
# fixture など）では止めない側（判定は効いたまま）に倒し、stderr も汚さない。読む前に [ -r ] で
# 確かめる — macOS の bash 3.2 は set -e の下で `.` が対象を見つけられないと、`||` の中でもシェルを
# 止める（呼び出し側が set -e でも落ちないように）。
declare -F ff_l4_skipped >/dev/null 2>&1 \
  || { [ -r "${BASH_SOURCE[0]%/*}/l4-declarations.sh" ] && . "${BASH_SOURCE[0]%/*}/l4-declarations.sh"; } 2>/dev/null \
  || ff_l4_skipped() { return 1; }
ff_commit_identity_check() {
  local repo="${1:-.}" name email ff_ci_skip=1
  if ff_l4_skipped 'commit-identity'; then ff_ci_skip=0; fi
  # 旧名を見つけた回に共通関数が置く注記は、hook の停止文（scripts/lib/stop-block.sh）のためのもの。この lib を
  # 読む scripts（リリース・knowledge-commit）は同じシェルで長く動き、注記を使わない（ADR-087 決定 4）ので、
  # 残すと別の段の停止文の 次の一手 に関係の無い注記が付く。呼んだ直後に空へ戻す
  ff_l4_retired_note=""
  [ "$ff_ci_skip" -ne 0 ] || return 0
  name="$(git -C "$repo" config --get user.name 2>/dev/null || true)"
  email="$(git -C "$repo" config --get user.email 2>/dev/null || true)"
  case "$email" in
    *@example.invalid) ;;
    *) [ "$name" = "fixture" ] || return 0 ;;
  esac
  {
    echo "✗ 実効の git identity が検査用の合成 identity です（user.name=${name:-（空）} / user.email=${email:-（空）}、対象: ${repo}）。"
    echo "  このままコミットすると履歴に fixture 名義が残ります。次のいずれかで再実行してください:"
    echo "  1) 漏れた値を消す: git -C '${repo}' config --local --unset user.name; git -C '${repo}' config --local --unset user.email"
    echo "  2) 意図的に合成 identity で進める場合だけ FF_DEV_TOOLKIT_SKIP=commit-identity を付けて再実行する"
  } >&2
  return 1
}
