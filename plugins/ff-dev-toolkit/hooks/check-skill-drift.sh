#!/usr/bin/env bash
#
# ff-dev-toolkit スキル実体ドリフト検査（SessionStart、Issue #656）。
#
# リポジトリの plugins/<plugin>/skills/ と、Claude Code のインストール実体
# （~/.claude/plugins/cache と marketplaces、および CLAUDE_PLUGIN_ROOT）を照合し、
# 次のどれかがあれば SessionStart 通知 JSON を 1 行出す。正常なら完全に無出力。
#
#   1. リポジトリにあるスキル名が、どのインストール実体にも無い
#   2. 同一プラグインのインストール実体が複数 version で併存している
#      （1 つだけを見て「最新」と判定しない。全パスと version を列挙する。
#      同一 version の cache + marketplace checkout は通常構成なので無音）
#   3. インストール実体を 1 つも発見できない → 「検出不能」と報告して exit 0
#
# リポジトリ側の skills/ が見つからない環境（配布先の利用者プロジェクトなど）は
# 照合対象外として無音で抜ける。dogfood セッション専用の検査である。
#
# 設計原則:
#   - fail-open: ユーザーの全セッション起動に割り込む。自分の不具合でセッションを
#     壊さない。あらゆる異常は黙って exit 0。stdout は通知 JSON 以外に何も出さず、
#     stderr も汚さない。
#   - 破壊的操作をしない: 古い cache の削除は通知と手順提示に留める。
#   - 互換性: bash 3.2（stock macOS）互換。jq / timeout(1) に依存しない。
#   - 出力の安全: スキル名は ^[A-Za-z0-9][A-Za-z0-9_-]*$ を通ったものだけを
#     JSON へ埋め込む。version は SemVer 3 要素以外を unknown に置換してから
#     埋め込む。path は json_escape のみ（whitelist しない）。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1  検査を無効化する（ユーザー向け）
#   以下はテストシーム（tests/skill-drift-check/verify.sh が実 ~/.claude に
#   触れずに本スクリプトを駆動するための注入口。通常運用で設定する必要はない）:
#   FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT     リポジトリルートの上書き
#   FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME   Claude 設定ディレクトリの上書き
#                                            （既定は CLAUDE_CONFIG_DIR または ~/.claude）

# fail-open のため set -e / set -u は使わない。参照は ${VAR:-default} 形で行う。

if [ "${FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK:-0}" = "1" ]; then
  exit 0
fi

is_semver() {
  printf '%s' "${1:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

is_skill_name() {
  printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$'
}

is_plugin_name() {
  printf '%s' "${1:-}" | grep -Eq '^[a-z0-9][a-z0-9-]*$'
}

extract_json_string() {
  # $1=file $2=key。整形済み 1 行 1 キーの plugin.json を前提とする（check-update.sh と同じ）。
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n 1
}

json_escape() {
  # 改行・制御文字は落とす。残るのは path / version / skill 名だけ。
  printf '%s' "${1:-}" | tr -d '\n\r\t' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ---- 自プラグイン（名前の決定） ------------------------------------------------
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  own_root="$CLAUDE_PLUGIN_ROOT"
else
  own_root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || exit 0
fi

own_json="$own_root/.claude-plugin/plugin.json"
[ -f "$own_json" ] || exit 0

plugin_name="$(extract_json_string "$own_json" name)"
is_plugin_name "$plugin_name" || plugin_name="ff-dev-toolkit"
is_plugin_name "$plugin_name" || exit 0

# ---- リポジトリ側 skills/ ------------------------------------------------------
repo_root="${FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT:-}"
if [ -z "$repo_root" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
fi
[ -n "$repo_root" ] || exit 0

repo_plugin="$repo_root/plugins/$plugin_name"
[ -d "$repo_plugin/skills" ] || exit 0

repo_json="$repo_plugin/.claude-plugin/plugin.json"
repo_version=""
if [ -f "$repo_json" ]; then
  repo_version="$(extract_json_string "$repo_json" version)"
fi
is_semver "$repo_version" || repo_version="unknown"

# ---- 作業領域（comm 用）。作れなければ fail-open --------------------------------
work="$(mktemp -d 2>/dev/null)" || exit 0
trap 'rm -rf "$work"' EXIT

list_skills_into() {
  # $1=plugin root  $2=outfile
  : > "$2"
  [ -d "$1/skills" ] || return 0
  for d in "$1/skills"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}SKILL.md" ] || continue
    base="$(basename "$d")"
    is_skill_name "$base" || continue
    printf '%s\n' "$base"
  done | LC_ALL=C sort -u > "$2"
}

list_skills_into "$repo_plugin" "$work/repo_skills"

# ---- インストール実体の列挙 ----------------------------------------------------
claude_home="${FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME:-}"
if [ -z "$claude_home" ]; then
  claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
fi

: > "$work/installs"
: > "$work/seen"
: > "$work/union_skills"

add_install() {
  # $1=plugin root（未正規化）
  local root json name ver canon
  root="${1:-}"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  json="$root/.claude-plugin/plugin.json"
  [ -f "$json" ] || return 0
  name="$(extract_json_string "$json" name)"
  [ "$name" = "$plugin_name" ] || return 0
  canon="$(cd "$root" 2>/dev/null && pwd -P)" || return 0
  if grep -Fxq "$canon" "$work/seen" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$canon" >> "$work/seen"
  ver="$(extract_json_string "$json" version)"
  is_semver "$ver" || ver="unknown"
  # 1 行 1 件。path にタブは来ない前提（pwd -P）。version と path を TAB 区切り。
  printf '%s\t%s\n' "$ver" "$canon" >> "$work/installs"
  list_skills_into "$canon" "$work/one_skills"
  if [ -s "$work/one_skills" ]; then
    cat "$work/union_skills" "$work/one_skills" 2>/dev/null | LC_ALL=C sort -u > "$work/union_skills.next" 2>/dev/null
    mv -f "$work/union_skills.next" "$work/union_skills" 2>/dev/null
  fi
}

# cache: ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
for plugin_json in "$claude_home"/plugins/cache/*/*/*/.claude-plugin/plugin.json; do
  [ -f "$plugin_json" ] || continue
  add_install "$(cd "$(dirname "$plugin_json")/.." 2>/dev/null && pwd)"
done

# marketplace checkout: ~/.claude/plugins/marketplaces/<mp>/plugins/<plugin>/
for plugin_json in "$claude_home"/plugins/marketplaces/*/plugins/*/.claude-plugin/plugin.json; do
  [ -f "$plugin_json" ] || continue
  add_install "$(cd "$(dirname "$plugin_json")/.." 2>/dev/null && pwd)"
done

# このセッションが実際に読むルート（cache と別実体を指しうる）
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  add_install "$CLAUDE_PLUGIN_ROOT"
fi

install_count=0
if [ -s "$work/installs" ]; then
  install_count="$(wc -l < "$work/installs" | tr -d ' ')"
fi
case "$install_count" in
  '' | *[!0-9]*) install_count=0 ;;
esac

emit_json() {
  # $1=systemMessage  $2=additionalContext
  local sys ctx
  sys="$(json_escape "$1")"
  ctx="$(json_escape "$2")"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$sys" "$ctx"
}

# ---- 検出不能（インストール 0 件）。セッションは止めない -------------------------
if [ "$install_count" -eq 0 ]; then
  emit_json \
    "⚠️ ff-dev-toolkit のインストール実体を検出不能でした。スキル集合の照合をスキップします（セッションは継続します）。" \
    "ff-dev-toolkit の SessionStart 検査がインストール実体を 1 つも見つけられませんでした。照合はスキップし、セッションは止めません。再インストールする場合は claude plugin marketplace update （引数なし）のあと claude plugin update ff-dev-toolkit を案内し、Claude Code の再起動が必要な旨を伝える。この通知を止めたい場合は FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1 を設定する。"
  exit 0
fi

# ---- スキル集合差分（mutation target: missing_joined を空にすると検出が落ちる） --
missing_joined=""
if [ -s "$work/repo_skills" ]; then
  comm -23 "$work/repo_skills" "$work/union_skills" > "$work/missing" 2>/dev/null || : > "$work/missing"
  if [ -s "$work/missing" ]; then
    missing_joined="$(tr '\n' ',' < "$work/missing" | sed 's/,$//; s/,/, /g')"
  fi
fi

# --- skill-set-diff (mutation target) ---
drift_skill_set=0
if [ -n "$missing_joined" ]; then
  drift_skill_set=1
fi

# ---- ロード中のコピーに無いスキル（Issue #881）---------------------------------
# 上の差分は **union**（全インストール実体の和集合）を見るので、「どこかのコピーに
# 在れば無音」になる。ところがセッションが呼べるのは **いま読み込まれているコピー**の
# スキルだけで、そこに無ければ `Unknown skill` で落ちる。
#
# 実測（Issue #881）: ロード済みが v0.14.0（3 スキル）、キャッシュに v0.61.0（21 スキル）が
# 併存する状態で、ワークフローがチェーン末尾に必須と定める `/retrospective` が
# `Unknown skill: ff-dev-toolkit:retrospective` になった。union には在るので上の検査は無音
# だった。呼べる集合を見ていないことが原因なので、own_root を別に差分する。
#
# 名簿は持たない — 比較対象はリポジトリの skills/ の実体で、ワークフロー文書が名指しする
# スキル名を書き写さない（二重管理を作らない。#881 の DoD）。
#
# 既知の限界: この検査はロード中のコピーの hook として走るので、**この検査を含まない
# 古い版がロードされている回は自分自身を報告できない**。その回は下の併存検出（複数
# version の列挙）が受け皿になる。
#
# ロード中のコピーに `skills/` ディレクトリ自体が無い場合は差分を取らない。「ディレクトリ
# が無い」と「スキルが 0 件」を出力から区別できず、本 hook は fail-open 設計（自分の不具合で
# セッションを壊さない）だからである。現実のロード実体は必ず skills/ を持つ（#881 の
# v0.14.0 も 3 件持っていた）。この経路が抜けても、どのインストール実体にも無い場合は上の
# union 差分が受け止める。
loaded_missing_joined=""
if [ -s "$work/repo_skills" ] && [ -n "${own_root:-}" ] && [ -d "$own_root/skills" ]; then
  list_skills_into "$own_root" "$work/loaded_skills"
  comm -23 "$work/repo_skills" "$work/loaded_skills" > "$work/loaded_missing" 2>/dev/null \
    || : > "$work/loaded_missing"
  if [ -s "$work/loaded_missing" ]; then
    loaded_missing_joined="$(tr '\n' ',' < "$work/loaded_missing" | sed 's/,$//; s/,/, /g')"
  fi
fi

# --- loaded-set-diff (mutation target: loaded_missing_joined を空にすると検出が落ちる) ---
drift_loaded_set=0
if [ -n "$loaded_missing_joined" ]; then
  drift_loaded_set=1
fi

# --- coexistence-list (mutation target: do not collapse to 1 via head -n 1) ---
# 併存はユニーク version が 2 以上のときだけ。同一 version の cache と
# marketplace checkout は Claude Code の通常構成なので無音にする。
uniq_versions=0
if [ -s "$work/installs" ]; then
  uniq_versions="$(cut -f1 "$work/installs" 2>/dev/null | LC_ALL=C sort -u | wc -l | tr -d ' ')"
fi
case "$uniq_versions" in
  '' | *[!0-9]*) uniq_versions=0 ;;
esac
drift_coexist=0
if [ "$uniq_versions" -gt 1 ]; then
  drift_coexist=1
fi

# 正常: スキル集合一致かつ version が 1 種類（path が複数でも同じ version なら無音。
# version 不一致の 1 実体は check-update.sh の管轄）
if [ "$drift_skill_set" -eq 0 ] && [ "$drift_loaded_set" -eq 0 ] && [ "$drift_coexist" -eq 0 ]; then
  exit 0
fi

# 列挙は全件コピーしてから読む。head -n 1 へ退行させる変異がここを潰す。
copy_install_list_for_report() {
  cat "$work/installs" > "$work/installs.report" 2>/dev/null
}
copy_install_list_for_report

install_lines=""
while IFS="$(printf '\t')" read -r ver path; do
  [ -n "$path" ] || continue
  if [ -n "$install_lines" ]; then
    install_lines="${install_lines}; ${path} (v${ver})"
  else
    install_lines="${path} (v${ver})"
  fi
done < "$work/installs.report"

sys=""
ctx=""
if [ "$drift_skill_set" -eq 1 ]; then
  sys="⚠️ ff-dev-toolkit のスキル実体がリポジトリより古いまたは欠けています。リポジトリに在るがインストール実体に無いスキル: ${missing_joined}（リポジトリ v${repo_version} / インストール実体: ${install_lines}）"
  ctx="ff-dev-toolkit のリポジトリ skills/（v${repo_version}）に在るがインストール実体に無いスキル: ${missing_joined}。インストール実体: ${install_lines}。"
fi
if [ "$drift_loaded_set" -eq 1 ]; then
  # union に在っても、いま読み込まれているコピーに無ければ呼べない。呼び出しは
  # `Unknown skill` で落ちるので、欠落したスキル名とロード元のパスを名指しする。
  loaded_msg="⚠️ いま読み込まれている ff-dev-toolkit（${own_root}）に無いスキルがあります: ${loaded_missing_joined}。これらの呼び出しは Unknown skill で失敗します（リポジトリ v${repo_version}）"
  if [ -n "$sys" ]; then
    sys="${sys} ${loaded_msg}"
  else
    sys="$loaded_msg"
  fi
  ctx="${ctx}いま読み込まれている ff-dev-toolkit のコピー（${own_root}）に無いスキル: ${loaded_missing_joined}。別のインストール実体に在っても、セッションが呼べるのはこのコピーのスキルだけなので、これらは Unknown skill になる。リポジトリ内の正本 plugins/ff-dev-toolkit/skills/<name>/SKILL.md を直接読んで手順を代替実行できる。"
fi
if [ "$drift_coexist" -eq 1 ]; then
  if [ -n "$sys" ]; then
    sys="${sys} インストール実体が複数バージョン併存しています: ${install_lines}"
  else
    sys="⚠️ ff-dev-toolkit のインストール実体が複数バージョン併存しています: ${install_lines}（リポジトリ v${repo_version}）"
  fi
  ctx="${ctx}併存しているインストール実体（1 つだけを最新と見なさない）: ${install_lines}。リポジトリ version は v${repo_version}。"
fi

ctx="${ctx} 古いキャッシュは自動削除しない。掃除手順: (1) 通知のパスのうちリポジトリ version より古い ~/.claude/plugins/cache/<marketplace>/ff-dev-toolkit/<version>/ を手動で削除する (2) claude plugin marketplace update （引数なし。marketplace 名はユーザーの登録名に依存するため） (3) claude plugin update ff-dev-toolkit (4) 適用には Claude Code の再起動が必要。この通知を止めたい場合は FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1 を設定する。"

emit_json "$sys" "$ctx"
exit 0
