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
#   FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD=1 で判定を省く（PreToolUse ガードと同じ変数）
ff_commit_identity_check() {
  local repo="${1:-.}" name email
  [ "${FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD:-}" = "1" ] && return 0
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
    echo "  2) 意図的に合成 identity で進める場合だけ FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD=1 を付けて再実行する"
  } >&2
  return 1
}
