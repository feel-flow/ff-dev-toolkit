#!/usr/bin/env bash

# stdin は **上限付きで**読み切ってから ASDD ゲートへ入る（契約 (c)。正本は
# hooks/asdd-hook-gate.sh）。ゲートの早期終了は exit 0 なので、ゲートを先に置くと
# 「読まずに exit 0」する経路ができ、書き手（ホスト）が EPIPE / SIGPIPE を受ける
# （パイプバッファ 65536 バイト超で実測）。SessionStart の実ペイロードは今は小さいが、
# 免除は denylist であり後から足す hook を無審査で通すので、読み切る側で揃える。
#
# 上限を付けるのは、**閉じない stdin（対話端末・パイプを開いたまま書かないホスト）で
# 無限に待たないため**。無上限の `read -d ''` は EOF が来るまで戻らず、実測では
# 3 本とも 6 秒経っても戻らなかった（上限付きなら 0.1 秒台で抜ける）。上限は本 hook の
# 登録 timeout（hooks.json: 5 秒）より十分小さい値に置く。本 hook は自分の処理だけで
# 実測 3.9 秒（登録 timeout の 79%）を使っていたため、上限は 1 秒に置いている — 上限が timeout を
# 超えるとホストの kill が先に来て、その kill が drain の防いでいる EPIPE を渡す（判定を組み込みへ
# 移した後は、プロセス起動の遅い Windows でも処理は 1 秒前後。Issue `#2020`）。
#
# `cat` を使わないのは、PATH が空・壊れた環境で command not found となり
# stdin 未読のまま exit 0 する経路がそこから開くため。
FF_STDIN_BOUND_SECONDS=1
input=""
IFS= read -r -t "$FF_STDIN_BOUND_SECONDS" -d '' input || true

# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0
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

# 判定と値の抜き出しは bash の組み込みだけで行い、外部コマンドもサブシェルも起動しない。プロセス起動が
# 遅い Windows（Git Bash）では、plugin.json 172 件・スキル 186 件の 1 件ごとに grep / sed / basename を
# 起動していたため 56 秒かかり、登録 timeout（5 秒）を超えていた（Issue `#2020`）。文字クラスは範囲ではなく
# 列挙で書く（ロケールによっては範囲が非 ASCII を含み、JSON へ埋め込む名前の whitelist が緩むため）。
ASCII_DIGITS='0123456789'
ASCII_LOWER='abcdefghijklmnopqrstuvwxyz'
ASCII_UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
NL='
'

is_semver() {
  local v="${1:-}"
  case "$v" in
    '' | .* | *. | *..* | *[!"$ASCII_DIGITS".]*) return 1 ;;
  esac
  [ "${v//[$ASCII_DIGITS]/}" = ".." ]
}

is_skill_name() {
  case "${1:-}" in
    '' | [!"$ASCII_DIGITS$ASCII_UPPER$ASCII_LOWER"]* | *[!"$ASCII_DIGITS$ASCII_UPPER$ASCII_LOWER"_-]*) return 1 ;;
  esac
  return 0
}

is_plugin_name() {
  case "${1:-}" in
    '' | [!"$ASCII_DIGITS$ASCII_LOWER"]* | *[!"$ASCII_DIGITS$ASCII_LOWER"-]*) return 1 ;;
  esac
  return 0
}

read_json_string() {
  # $1=file $2=key。整形済み 1 行 1 キーの plugin.json を前提とする（check-update.sh と同じ）。最初に
  # `"key": "値"` の形で当たった行の値を JSON_VALUE に入れる（$(...) で受けるとサブシェルを fork する）。
  local line rest
  JSON_VALUE=""
  [ -r "${1:-}" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *"\"$2\""*) ;; *) continue ;; esac
    rest="${line#*\"$2\"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$rest" in :*) rest="${rest#:}" ;; *) continue ;; esac
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$rest" in \"*\"*) ;; *) continue ;; esac
    rest="${rest#\"}"
    JSON_VALUE="${rest%%\"*}"
    return 0
  done < "$1"
  return 0
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

read_json_string "$own_json" name
plugin_name="$JSON_VALUE"
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
  read_json_string "$repo_json" version
  repo_version="$JSON_VALUE"
fi
is_semver "$repo_version" || repo_version="unknown"

# ---- スキル名の一覧 --------------------------------------------------------------
# 一覧は「名前 + 改行」を並べた文字列で持ち、集合演算も組み込みで行う。一時ファイル・パイプ・
# sort / comm を使うと、インストール実体 1 件ごとに fork が数回走り、Windows ではそれだけで
# 数秒かかる。並べ替えはリポジトリ側の一覧に 1 回だけ行う（差分の出力順を決めるのはこの一覧）。
skills_of() {
  # $1=plugin root。SKILLS に「名前\n」の並びを入れる
  local d base
  SKILLS=""
  [ -d "$1/skills" ] || return 0
  for d in "$1/skills"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}SKILL.md" ] || continue
    base="${d%/}"
    base="${base##*/}"
    is_skill_name "$base" || continue
    SKILLS="$SKILLS$base$NL"
  done
}

has_line() {
  # $1=「値\n」の並び  $2=値
  case "$NL$1" in
    *"$NL$2$NL"*) return 0 ;;
  esac
  return 1
}

skills_of "$repo_plugin"
repo_skills=""
if [ -n "$SKILLS" ]; then
  repo_skills="$(printf '%s' "$SKILLS" | LC_ALL=C sort -u)$NL" || exit 0
fi

# ---- インストール実体の列挙 ----------------------------------------------------
claude_home="${FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME:-}"
if [ -z "$claude_home" ]; then
  claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
fi

installs=""      # 「version<TAB>正規化したパス\n」を見つけた順に並べる
install_count=0
union_skills=""  # 全インストール実体のスキル名の和集合（「名前\n」の並び）
seen_list=""
orig_pwd="$PWD"

add_install() {
  # $1=plugin root（未正規化）。他プラグインの大半は、組み込みの判定と名前の比較だけで抜ける
  local root json ver canon rest s
  root="${1:-}"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  json="$root/.claude-plugin/plugin.json"
  [ -f "$json" ] || return 0
  read_json_string "$json" name
  [ "$JSON_VALUE" = "$plugin_name" ] || return 0
  # 実体の正規化は、名前が一致した実体だけで組み込みの cd -P で行う（サブシェルを起こさない）
  cd -P -- "$root" 2>/dev/null || return 0
  canon="$PWD"
  cd -- "$orig_pwd" 2>/dev/null || exit 0
  has_line "$seen_list" "$canon" && return 0
  seen_list="$seen_list$canon$NL"
  read_json_string "$json" version
  ver="$JSON_VALUE"
  is_semver "$ver" || ver="unknown"
  # 1 行 1 件。path にタブは来ない前提（cd -P）。version と path を TAB 区切り。
  installs="$installs$ver	$canon$NL"
  install_count=$((install_count + 1))
  skills_of "$canon"
  rest="$SKILLS"
  while [ -n "$rest" ]; do
    s="${rest%%"$NL"*}"
    rest="${rest#*"$NL"}"
    has_line "$union_skills" "$s" || union_skills="$union_skills$s$NL"
  done
}

# cache: ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
for plugin_json in "$claude_home"/plugins/cache/*/*/*/.claude-plugin/plugin.json; do
  [ -f "$plugin_json" ] || continue
  add_install "${plugin_json%/.claude-plugin/plugin.json}"
done

# marketplace checkout: ~/.claude/plugins/marketplaces/<mp>/plugins/<plugin>/
for plugin_json in "$claude_home"/plugins/marketplaces/*/plugins/*/.claude-plugin/plugin.json; do
  [ -f "$plugin_json" ] || continue
  add_install "${plugin_json%/.claude-plugin/plugin.json}"
done

# このセッションが実際に読むルート（cache と別実体を指しうる）
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  add_install "$CLAUDE_PLUGIN_ROOT"
fi

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
    "ff-dev-toolkit の SessionStart 検査がインストール実体を 1 つも見つけられませんでした。照合はスキップし、セッションは止めません。再インストールする場合は次の手順を案内すること: (1) claude plugin marketplace update （引数なし。marketplace 名はユーザーの登録名に依存するため） (2) claude plugin list で登録 ID を確認する。ID は プラグイン名@marketplace名 の形式で、素の名前を渡すと Plugin not found で失敗する (3) claude plugin update に (2) で確認した ID を渡す (4) 適用には Claude Code の再起動が必要。この通知を止めたい場合は FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1 を設定する。"
  exit 0
fi

join_missing() {
  # $1=リポジトリ側の一覧（並べ替え済み）  $2=照合先の一覧。$1 にあって $2 に無い名前を、$1 の順で
  # 「, 」区切りにして JOINED に入れる
  local rest s
  JOINED=""
  rest="$1"
  while [ -n "$rest" ]; do
    s="${rest%%"$NL"*}"
    rest="${rest#*"$NL"}"
    has_line "$2" "$s" && continue
    JOINED="${JOINED:+$JOINED, }$s"
  done
}

# ---- スキル集合差分（mutation target: missing_joined を空にすると検出が落ちる） --
missing_joined=""
if [ -n "$repo_skills" ]; then
  join_missing "$repo_skills" "$union_skills"
  missing_joined="$JOINED"
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
if [ -n "$repo_skills" ] && [ -n "${own_root:-}" ] && [ -d "$own_root/skills" ]; then
  skills_of "$own_root"
  join_missing "$repo_skills" "$SKILLS"
  loaded_missing_joined="$JOINED"
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
seen_versions=""
rest="$installs"
while [ -n "$rest" ]; do
  line="${rest%%"$NL"*}"
  rest="${rest#*"$NL"}"
  has_line "$seen_versions" "${line%%	*}" && continue
  seen_versions="$seen_versions${line%%	*}$NL"
  uniq_versions=$((uniq_versions + 1))
done
drift_coexist=0
if [ "$uniq_versions" -gt 1 ]; then
  drift_coexist=1
fi

# 正常: スキル集合一致かつ version が 1 種類（path が複数でも同じ version なら無音。
# version 不一致の 1 実体は check-update.sh の管轄）
if [ "$drift_skill_set" -eq 0 ] && [ "$drift_loaded_set" -eq 0 ] && [ "$drift_coexist" -eq 0 ]; then
  exit 0
fi

# 列挙は全件コピーしてから読む。先頭の 1 件だけへ退行させる変異がここを潰す。
installs_report="$installs"

install_lines=""
rest="$installs_report"
while [ -n "$rest" ]; do
  line="${rest%%"$NL"*}"
  rest="${rest#*"$NL"}"
  ver="${line%%	*}"
  path="${line#*	}"
  [ -n "$path" ] || continue
  if [ -n "$install_lines" ]; then
    install_lines="${install_lines}; ${path} (v${ver})"
  else
    install_lines="${path} (v${ver})"
  fi
done

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

ctx="${ctx} 古いキャッシュは自動削除しない。掃除手順（削除は必ず再起動の後 — 稼働中セッションの hook は発火のたびに起動時スナップショットのディスク実体を読むため、先に削除するとそのセッションの SessionStart / Stop hook が残りの間ずっと壊れる）: (1) claude plugin marketplace update （引数なし。marketplace 名はユーザーの登録名に依存するため） (2) claude plugin list で登録 ID を確認する。ID は プラグイン名@marketplace名 の形式で、素の名前を渡すと Plugin not found で失敗する (3) claude plugin update に (2) で確認した ID を渡す (4) 適用には Claude Code の再起動が必要 (5) 再起動後に、通知のパスのうちリポジトリ version より古い ~/.claude/plugins/cache/<marketplace>/ff-dev-toolkit/<version>/ を手動で削除する。ただし稼働中の別セッションが残っている場合、そのセッションがロードしているバージョンは削除しない。この通知を止めたい場合は FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1 を設定する。"

emit_json "$sys" "$ctx"
exit 0
