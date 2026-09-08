#!/usr/bin/env bash
#
# fixture 用 Git リポジトリの隔離初期化（Issue #1348 / #1368）。
#
# suite が `git init` した fixture へ `git -C "$dir" config user.*` で合成 identity
# を書く形は identity の値に依らず、次の経路で**呼び出し元リポジトリの .git/config**
# へ漏れる（Issue #1348 で実測。tests/git-fixture-isolation は経路 1 を
# git 版依存の info 表示、経路 2 を init を no-op にする stub で模擬し、ヘルパーの fail-closed を固定する。
# 既定 identity は fixture <fixture@example.invalid>。NAME / EMAIL 引数で差し替えられる）:
#   1. GIT_DIR が export された環境（git hook の内側や、それを継承したサブプロセス）では
#      `git init <dir>` が GIT_DIR の既存リポジトリを再初期化するだけで <dir>/.git を作らず、
#      続く `git -C <dir> config` は GIT_DIR/config = 外側の設定へ書く
#   2. <dir> が外側の作業ツリー内にあって自前の .git を持たない場合、`git -C <dir> config` は
#      上位ディレクトリの .git を発見して外側へ書く
#   3. 旧来の GIT_CONFIG が export されていると、`git config` の書き先がその file になる（git dir の
#      解決は fixture 自身のままなので照合では検出できない）
# 漏れた identity はそのリポジトリの以後の全コミットに載る（develop の knowledge 直 push
# 41 件が fixture 名義になった）。
#
# 公開関数:
#   ff_git_fixture_init DIR [NAME] [EMAIL]
#     DIR を mkdir -p → `git -C DIR init -q` → DIR/.git が DIR 自身の git dir として
#     解決されることを `rev-parse --absolute-git-dir` で確認してから、identity（既定
#     fixture / fixture@example.invalid）を DIR のローカル設定へ書く。解決先が DIR/.git
#     でなければ**何も書かずに非 0**（fail-closed）。
#   ff_git_fixture_unset_env
#     GIT_DIR 系の環境変数を**現在のシェル**で unset する。source 時に 1 回自動で呼ぶ。
#
# 保証の境界（ここに書いていない保護は無い）:
#   - source 時に GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_COMMON_DIR /
#     GIT_OBJECT_DIRECTORY / GIT_ALTERNATE_OBJECT_DIRECTORIES / GIT_CONFIG /
#     GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT（と GIT_CONFIG_KEY_* / GIT_CONFIG_VALUE_*）を unset する。
#     identity の書き込みは `config --local` で、GIT_CONFIG が残っていても外側へは書けない
#     （`only one config file at a time` で非 0）
#     suite の後続 `git -C DIR add / commit` も外側へ向かなくなる
#   - GIT_CONFIG_GLOBAL / GIT_CONFIG_NOSYSTEM は触らない（suite が意図して隔離に使う）
#   - unset は source 時に加えて ff_git_fixture_init の冒頭（git init の前）でも行う。source 後に
#     suite が GIT_DIR 等を再 export しても、init が外側を再初期化する前に中和される
#   - identity 以外の設定（core.hooksPath 等）はここでは書かない
#   - `git -c user.name=… commit` の per-command 形は設定を残さないため対象外だが、
#     経路 1 では `git -C DIR init` が外側を再初期化し続く commit も外側へ入るので、
#     init は必ず本ヘルパーを通す

ff_git_fixture_unset_env() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  local _v
  for _v in $(compgen -v GIT_CONFIG_ 2>/dev/null || true); do
    case "$_v" in
      GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$_v" ;;
    esac
  done
}

ff_git_fixture_init() {
  local dir="${1:?ff_git_fixture_init: DIR が必要}"
  local name="${2:-fixture}" email="${3:-fixture@example.invalid}"
  local abs got got_p
  # source 時任せにせず、外側へ副作用が出る git init の前に必ず中和する
  ff_git_fixture_unset_env
  mkdir -p "$dir" || return 1
  abs="$(cd "$dir" && pwd -P)" || return 1
  if ! git -C "$abs" init -q; then
    echo "✗ git-fixture: git init に失敗（identity は書かない）: $abs" >&2
    return 1
  fi
  got="$(git -C "$abs" rev-parse --absolute-git-dir 2>/dev/null)" || got=""
  got_p=""
  [ -n "$got" ] && [ -d "$got" ] && got_p="$(cd "$got" && pwd -P)"
  if [ "$got_p" != "$abs/.git" ]; then
    echo "✗ git-fixture: fixture の git dir が自分自身へ解決されない（identity は書かない）: $abs → ${got:-<解決不能>}" >&2
    return 1
  fi
  git -C "$abs" config --local user.name "$name" && git -C "$abs" config --local user.email "$email"
}

ff_git_fixture_unset_env
