#!/usr/bin/env bash

# stdin は **上限付きで**読み切ってから ASDD ゲートへ入る（契約 (c)。正本は
# hooks/asdd-hook-gate.sh）。ゲートの早期終了は exit 0 なので、ゲートを先に置くと
# 「読まずに exit 0」する経路ができ、書き手（ホスト）が EPIPE / SIGPIPE を受ける
# （パイプバッファ 65536 バイト超で実測）。SessionStart の実ペイロードは今は小さいが、
# 免除は denylist であり後から足す hook を無審査で通すので、読み切る側で揃える。
#
# 上限を付けるのは、**閉じない stdin（対話端末・パイプを開いたまま書かないホスト）で
# 無限に待たないため**。無上限の `read -d ''` は EOF が来るまで戻らない。上限は本 hook の
# 登録 timeout（hooks.json: 5 秒）より十分小さい値に置く — 上限が timeout を超えると
# ホストの kill が先に来て、その kill が drain の防いでいる EPIPE を渡す。
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
# レビュアー名簿の追随検査を実体に対して回す配線（SessionStart）。
#
# `hooks/guard-review-in-flight.sh` は、レビュー凍結レーンを取る subagent_type を**列挙**で
# 持つ（`FF_REVIEW_SUBAGENT_LOCK_TYPES` の既定値）。列挙先の実体は別プラグインのレビュアー群
# なので、そちらにレビュアーが増えても列挙は自動では追随しない。突き合わせ自体は
# `scripts/check-review-roster-drift.sh` が行う（そちらが判定ロジックの正本）。本 hook は
# **その検査をホストの実体に対して自動で回す経路**だけを担う。
#
# 経路の選択: `SessionStart` hook（同じくホスト依存の drift 検査である
# `hooks/check-skill-drift.sh` と同じ形）。`tests/run-all.sh` の suite にしないのは、
# 公開同期の定期実行点ゲートが環境 skip を許容しないため、当該プラグイン未導入の環境で
# 同期が止まるから。`check-skill-drift.sh` へ相乗りしないのは、あちらが
# 「リポジトリ側 `plugins/<plugin>/skills/` がある dogfood セッション専用」の検査で、
# 配布先の利用者セッションでは skills/ 不在で早期 exit するため、相乗りすると
# **利用者環境では一度も発火しない**から（opt-out 変数も相乗りで共有されてしまう）。
#
# ## 無音で抜けてよいのは「未導入」だけ
#
# **無音の exit 0 は「レビュアー実体が 1 つも見つからない（当該プラグインが未導入）」に
# 限定する。** それ以外で判定が成立しない経路 — 中間ディレクトリを列挙できない・
# プラグイン実体はあるのに `agents/` が無い / 読めない・名簿を抽出できない・突き合わせ
# スクリプトや hook を読めない — はすべて「判定不能」として通知する。ここを無音へ倒すと、
# 「一致」と見分けがつかない緑が出続け、この配線は名簿がどれだけ腐っても静かなままになる。
#
# とくに**中間ディレクトリが読めない回**（例: `plugins/cache` が traverse だけ許す権限）は、
# glob が 1 件も展開されないので「未導入」と同じ形（候補 0 件）で現れる。`[ -d ]` は真だが
# `[ -r ]` / `[ -x ]` が偽になることで両者を区別できるので、走査の前に明示的に見分ける。
#
#   | 状況                                   | 挙動                         |
#   | -------------------------------------- | ---------------------------- |
#   | レビュアー実体が 1 つも見つからない     | 無音で exit 0                |
#   | 名簿と実体が一致（rc=0）                | 無音で exit 0                |
#   | drift（rc=1）                           | 通知（MISSING / EXTRA と実体）|
#   | 突き合わせが成立しない（rc=2・走査不能） | 「判定不能」として通知        |
#
# drift と判定不能が**同時に**起きる回（片方の実体は食い違い、もう片方は読めない等）は、
# 1 通の通知へ**併記**する。先に見つかった方で早期 return すると、もう片方が届かない。
#
# ## 併存する写しの畳み方（「消せない通知」を作らないため）
#
# cache は同じプラグインの版違いの写しを併存させる（`plugins/cache/<marketplace>/<plugin>/
# <版>/`）。**写しを 1 つずつ独立に突き合わせてはいけない。** 上流がレビュアーを 1 本増やし、
# 名簿を正しく直したあとも、古い写しが「名簿にあるが実体に無い」（EXTRA）を出し続け、
# どの名簿値でも消せない通知になるためである。鳴り続ける通知は無視されるようになるので、
# 配線した意味が消える。
#
# そこで `<marketplace>/<plugin>` の単位で 1 つの判定へ畳む。
#
#   1. 写しの版を解釈できるなら、**最新版の `agents/` だけ**を突き合わせる。版は
#      `check-skill-drift.sh` と同じく `<写し>/.claude-plugin/plugin.json` の `version` を
#      SemVer として読み、無ければ cache の版ディレクトリ名（`cache/<mp>/<plugin>/<版>/` の
#      規約）を SemVer として読む。
#   2. どの写しからも SemVer を読めないときは、写し全体の**和集合**を 1 つの実体として
#      突き合わせる（`check-skill-drift.sh` がスキル集合の差分で採っているのと同じ畳み方）。
#      実測: 本リポジトリの開発ホストに在る `pr-review-toolkit` は `plugin.json` に `version`
#      を持たず、cache の版ディレクトリ名も内容ハッシュ（`022b3c274938` 等）なので、
#      1. の経路は成立しない。ここを「順序づけられないから判定不能」へ倒すと毎セッション
#      鳴り続け、「写しを全部独立に見る」へ倒すと上流が 1 本変えた瞬間に消せない通知になる。
#      和集合はどちらも避ける — 増えた側は即座に MISSING として出て、消えた側は写しが
#      掃除されてから EXTRA として出る（遅れるが、鳴り続けることはない）。
#
# marketplace checkout（`plugins/marketplaces/<mp>/plugins/<plugin>/`）は版の次元を持たない
# ので、そのまま 1 実体として扱う。最後にレビュアー集合が同じ実体どうしを 1 つへ畳む
# （同一集合の cache + marketplace checkout は通常構成なので、同じ答えを二度出さない）。
#
# 設計原則（check-skill-drift.sh と同じ）:
#   - fail-open: ユーザーの全セッション起動に割り込む。自分の不具合でセッションを
#     壊さない。stdout は通知 JSON 以外に何も出さず、stderr も汚さない。
#   - 破壊的操作をしない: 読むだけで、名簿も実体も書き換えない。
#   - 互換性: bash 3.2（stock macOS）互換。jq / timeout(1) / sort -V に依存しない。
#   - 出力の安全: 実体側のファイル名に由来する名前は
#     ^[A-Za-z0-9][A-Za-z0-9_:.-]*$ を通ったものだけを JSON へ埋め込む。
#     path と REASON は json_escape のみ（whitelist しない）。
#
# 既知の限界: 突き合わせ側は **hook ファイルの既定値**だけを名簿として読む。利用者が
# 環境変数 `FF_REVIEW_SUBAGENT_LOCK_TYPES` で名簿を上書きして実行時のレーン漏れを直しても、
# この検査の判定は変わらない。通知文はその非対称を明示し、環境変数で直した利用者には
# `FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK=1` を併せて案内する。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK=1  検査を無効化する（ユーザー向け）
#   以下はテストシーム（tests/guard-review-in-flight/verify.sh が実 ~/.claude に
#   触れずに本スクリプトを駆動するための注入口。通常運用で設定する必要はない）:
#   FF_DEV_TOOLKIT_ROSTER_DRIFT_CLAUDE_HOME   Claude 設定ディレクトリの上書き
#                                             （既定は CLAUDE_CONFIG_DIR または ~/.claude）
#   FF_DEV_TOOLKIT_ROSTER_DRIFT_HOOK          突き合わせ対象の hook パスの上書き

# fail-open のため set -e / set -u は使わない。参照は ${VAR:-default} 形で行う。

if [ "${FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK:-0}" = "1" ]; then
  exit 0
fi

json_escape() {
  # 改行・制御文字は落とす。残るのは path / REASON / レビュアー名だけ。
  printf '%s' "${1:-}" | tr -d '\n\r\t' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

emit_json() { # <systemMessage> <additionalContext>
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")"
}

# 通知末尾の共通案内。修理先を 1 か所に持つ（文面を 2 か所へ書き分けない）。
HOWTO="恒久的な修理は開発元での hooks/guard-review-in-flight.sh の REVIEW_LOCK_TYPES 既定値の更新（共有ツリーを編集する前提のレビュアーは意図的な除外なので scripts/check-review-roster-drift.sh の EXCLUDED_AGENTS へ理由付きで足す）。本検査が名簿として読むのは**同梱の既定値だけ**で、環境変数 FF_REVIEW_SUBAGENT_LOCK_TYPES による上書きは見ない — 実行時のレーン漏れを環境変数で直した場合、この通知は止まらないので FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK=1 を併せて設定すること。差分は bash scripts/check-review-roster-drift.sh --agents-dir <実体のパス> で再現できる。"

# 判定不能を 1 件だけ報告して終わる経路（走査そのものが始められない回）。
emit_undetermined_and_exit() { # <理由>
  emit_json \
    "⚠️ レビュー凍結レーンの名簿が実体に追随しているかを判定できませんでした（${1}）。「一致」は未確認です。" \
    "ff-dev-toolkit の SessionStart 検査が、hooks/guard-review-in-flight.sh の名簿と別プラグインのレビュアー実体の突き合わせを開始できなかった。理由: ${1}。これは「一致」ではなく「判定不能」であり、名簿が実体から遅れている可能性は排除できない。${HOWTO}この通知を止めたい場合は FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK=1 を設定する。"
  exit 0
}

is_semver() {
  printf '%s' "${1:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

# $1 > $2 なら真。数値比較なので 0.9.9 < 0.10.0 を正しく扱う（check-update.sh と同形）。
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit 1
  }'
}

extract_json_string() {
  # $1=file $2=key。整形済み 1 行 1 キーの plugin.json を前提とする（check-skill-drift.sh と同じ）。
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n 1
}

hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || hook_dir=""
[ -n "$hook_dir" ] || emit_undetermined_and_exit "本 hook の設置場所を解決できません（突き合わせスクリプトの所在が決まらない）"
guard_hook="${FF_DEV_TOOLKIT_ROSTER_DRIFT_HOOK:-$hook_dir/guard-review-in-flight.sh}"
check_script="$hook_dir/../scripts/check-review-roster-drift.sh"
[ -r "$guard_hook" ] \
  || emit_undetermined_and_exit "名簿を持つ hook を読めません: ${guard_hook}"
[ -r "$check_script" ] \
  || emit_undetermined_and_exit "突き合わせスクリプトを読めません: ${check_script}"

# ---- レビュアー実体の所在を決める接頭辞を名簿から導く --------------------------
# プラグイン名をここへ書き写すと、名簿を別プラグインへ向け替えたときにこの配線だけが
# 古い所在を見続ける。名簿の既定値から導出する（突き合わせ側と同じ抽出式）。
roster_line="$(sed -n 's/^REVIEW_LOCK_TYPES="\${FF_REVIEW_SUBAGENT_LOCK_TYPES:-\(.*\)}"$/\1/p' "$guard_hook" 2>/dev/null | head -n 1)"
[ -n "$roster_line" ] \
  || emit_undetermined_and_exit "hook から名簿の既定値を抽出できません（REVIEW_LOCK_TYPES の書き方が変わった可能性）: ${guard_hook}"

# 名簿は glob を書ける契約なので、cwd のファイル名を名簿へ混ぜないよう展開を止める。
reviewer_plugin=""
set -f
for _t in $roster_line; do
  case "$_t" in
    *:*) _p="${_t%%:*}" ;;
    *) _p="" ;;
  esac
  # 接頭辞が一意でない名簿は、突き合わせ側の `--prefix`（単一値）では表現できない。
  # 片側の接頭辞だけで回すと、もう片側が丸ごと EXTRA として鳴り続ける。
  if [ -z "$_p" ] || { [ -n "$reviewer_plugin" ] && [ "$_p" != "$reviewer_plugin" ]; }; then
    reviewer_plugin=""
    break
  fi
  reviewer_plugin="$_p"
done
set +f
printf '%s' "$reviewer_plugin" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
  || emit_undetermined_and_exit "名簿からレビュアー実体の所在（プラグイン名の接頭辞）を一意に決められません: ${roster_line}"

# ---- インストール実体（レビュアー群のディレクトリ）の列挙 -----------------------
claude_home="${FF_DEV_TOOLKIT_ROSTER_DRIFT_CLAUDE_HOME:-}"
if [ -z "$claude_home" ]; then
  claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
fi

UNDET_DIRS=""
UNDET_REASON=""
add_undet() { # <対象パス> <理由>
  UNDET_DIRS="${UNDET_DIRS}${UNDET_DIRS:+; }${1}"
  [ -n "$UNDET_REASON" ] || UNDET_REASON="$2"
}

PROBE_ENTRIES=""
SEEN_SIGS=""
add_probe() { # <突き合わせるディレクトリ> <報告に出す表示名>
  local d="$1" label="$2" sig="" f
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    sig="${sig}${f##*/}|"
  done
  # レビュアー集合が同じ実体は同じ判定になる。同じ答えを二度出さない。
  case "$SEEN_SIGS" in
    *"<${sig}>"*) return 0 ;;
  esac
  SEEN_SIGS="${SEEN_SIGS}<${sig}>"
  PROBE_ENTRIES="${PROBE_ENTRIES}${d}	${label}
"
}

readable_dir() { # <パス> — 列挙できるディレクトリか
  [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ]
}

scan_plugin_root() { # <プラグイン実体のルート>
  local root="$1" agents="$1/agents"
  if [ ! -d "$agents" ]; then
    add_undet "$root" "プラグイン実体はありますがレビュアー実体のディレクトリがありません: ${agents}"
    return 0
  fi
  if ! readable_dir "$agents"; then
    add_undet "$agents" "レビュアー実体のディレクトリを列挙できません（読み取り権限がありません）: ${agents}"
    return 0
  fi
  add_probe "$agents" "$agents"
}

WORK=""
UNION_SEQ=0
ensure_work() {
  [ -n "$WORK" ] && return 0
  WORK="$(mktemp -d 2>/dev/null)" || WORK=""
  [ -n "$WORK" ] && [ -d "$WORK" ] || { WORK=""; return 1; }
  trap 'rm -rf "$WORK"' EXIT
  return 0
}

scan_group_union() { # <グループのディレクトリ> <写しのパス（改行区切り）>
  local gdir="$1" copies="$2" root agents f udir contributed=0 unreadable=0
  ensure_work \
    || { add_undet "$gdir" "一時領域を作成できず、併存する写しの和集合を作れません: ${gdir}"; return 0; }
  udir="$WORK/union.$UNION_SEQ"
  UNION_SEQ=$((UNION_SEQ + 1))
  mkdir -p "$udir" 2>/dev/null \
    || { add_undet "$gdir" "併存する写しの和集合を作れません: ${gdir}"; return 0; }
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    agents="$root/agents"
    [ -d "$agents" ] || continue
    if ! readable_dir "$agents"; then
      unreadable=1
      continue
    fi
    # 突き合わせ側が見るのはファイル名だけなので、名前だけを空ファイルとして写す。
    for f in "$agents"/*.md; do
      [ -f "$f" ] || continue
      : > "$udir/${f##*/}" 2>/dev/null || continue
      contributed=1
    done
  done <<EOF
$copies
EOF
  if [ "$contributed" -eq 0 ]; then
    if [ "$unreadable" -eq 1 ]; then
      add_undet "$gdir" "併存する写しのレビュアー実体を 1 つも列挙できません（読み取り権限がありません）: ${gdir}"
    else
      add_undet "$gdir" "プラグイン実体はありますがレビュアー実体を 1 件も見つけられません: ${gdir}"
    fi
    return 0
  fi
  add_probe "$udir" "${gdir}/*（併存する写しの和集合）"
}

# 中間ディレクトリが「あるのに列挙できない」回は、glob が空振りして「未導入」と同じ形で
# 現れる。走査の前に見分けて判定不能へ倒す（無音にすると「一致」と区別できない）。
for _base in "$claude_home/plugins" "$claude_home/plugins/cache" "$claude_home/plugins/marketplaces" \
  "$claude_home"/plugins/cache/* "$claude_home"/plugins/marketplaces/* \
  "$claude_home"/plugins/marketplaces/*/plugins; do
  [ -d "$_base" ] || continue
  readable_dir "$_base" && continue
  add_undet "$_base" "ディレクトリを列挙できません（読み取り権限がありません）: ${_base}"
done

# cache: `plugins/cache/<marketplace>/<plugin>/<版>/agents`。版の写しはグループ単位で畳む。
for _gdir in "$claude_home"/plugins/cache/*/"$reviewer_plugin"; do
  [ -d "$_gdir" ] || continue
  if ! readable_dir "$_gdir"; then
    add_undet "$_gdir" "プラグイン実体のディレクトリを列挙できません（読み取り権限がありません）: ${_gdir}"
    continue
  fi
  _best_root=""
  _best_ver=""
  _copies=""
  for _root in "$_gdir"/*; do
    [ -d "$_root" ] || continue
    _copies="${_copies}${_root}
"
    _ver="$(extract_json_string "$_root/.claude-plugin/plugin.json" version)"
    is_semver "$_ver" || _ver="${_root##*/}"
    is_semver "$_ver" || _ver=""
    [ -n "$_ver" ] || continue
    if [ -z "$_best_ver" ] || version_gt "$_ver" "$_best_ver"; then
      _best_ver="$_ver"
      _best_root="$_root"
    fi
  done
  if [ -z "$_copies" ]; then
    add_undet "$_gdir" "プラグイン実体のディレクトリに版の写しが 1 つもありません: ${_gdir}"
    continue
  fi
  if [ -n "$_best_root" ]; then
    scan_plugin_root "$_best_root"
  else
    scan_group_union "$_gdir" "$_copies"
  fi
done

# marketplace checkout: `plugins/marketplaces/<mp>/plugins/<plugin>/agents`（版の次元なし）。
for _mroot in "$claude_home"/plugins/marketplaces/*/plugins/"$reviewer_plugin"; do
  [ -d "$_mroot" ] || continue
  scan_plugin_root "$_mroot"
done

# 実体も判定不能も 1 件も無い = 当該プラグインが導入されていない。ここだけが無音の出口。
if [ -z "$PROBE_ENTRIES" ] && [ -z "$UNDET_DIRS" ]; then
  exit 0
fi

# ---- 突き合わせ ---------------------------------------------------------------
# 名前は実体側のファイル名に由来する。JSON へ出すのは whitelist を通ったものだけ。
sanitize_names() { # <空白区切りの名前列>
  local out="" n
  for n in ${1:-}; do
    printf '%s' "$n" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_:.-]*$' || continue
    out="${out}${n} "
  done
  printf '%s' "$out"
}

drift_missing=""
drift_extra=""
drift_dirs=""

while IFS="$(printf '\t')" read -r dir label; do
  [ -n "$dir" ] || continue
  out="$(bash "$check_script" --agents-dir "$dir" --hook "$guard_hook" --prefix "${reviewer_plugin}:" 2>&1)" \
    && rc=0 || rc=$?
  case "$rc" in
    0) continue ;;
    1)
      drift_dirs="${drift_dirs}${drift_dirs:+; }${label}"
      _m="$(printf '%s\n' "$out" | sed -n 's/^MISSING=//p')"
      _e="$(printf '%s\n' "$out" | sed -n 's/^EXTRA=//p')"
      drift_missing="${drift_missing}$(sanitize_names "$_m")"
      drift_extra="${drift_extra}$(sanitize_names "$_e")"
      ;;
    *)
      # rc=2（判定不能）と想定外の rc の両方をここへ倒す。「一致」へは倒さない。
      add_undet "$label" "$(printf '%s\n' "$out" | sed -n 's/^REASON=//p' | head -n 1)"
      ;;
  esac
done <<EOF
$PROBE_ENTRIES
EOF

# 重複を畳んでから出す（集合の違う実体が併存すると同じ名前が並ぶ）。
drift_missing="$(printf '%s' "$drift_missing" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' ')"
drift_extra="$(printf '%s' "$drift_extra" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' ')"
drift_missing="${drift_missing% }"
drift_extra="${drift_extra% }"

# drift と判定不能は**併記**する。片方で早期に返すと、もう片方が利用者へ届かない。
sys=""
ctx=""
if [ -n "$drift_dirs" ]; then
  sys="⚠️ レビュー凍結レーンの名簿が ${reviewer_plugin} の実体に追随していません。名簿に足す候補: ${drift_missing:-（なし）}／実体から消えた名前: ${drift_extra:-（なし）}（実体: ${drift_dirs}）"
  ctx="ff-dev-toolkit の SessionStart 検査が、hooks/guard-review-in-flight.sh の名簿（FF_REVIEW_SUBAGENT_LOCK_TYPES の既定値）と ${reviewer_plugin} のレビュアー実体の食い違いを検出した。MISSING（名簿に足す候補）: ${drift_missing:-なし}。EXTRA（名簿にあるが実体に無い）: ${drift_extra:-なし}。突き合わせた実体: ${drift_dirs}。名簿から落ちたレビュアーはレビュー走行中のレーンを取らないため、そのレビュアーが動いている間は編集の凍結が効かない。"
fi
if [ -n "$UNDET_DIRS" ]; then
  sys="${sys}${sys:+ }⚠️ 突き合わせが成立しなかった実体があります（${UNDET_REASON:-理由不明}）。その分の「一致」は未確認です（実体: ${UNDET_DIRS}）。"
  ctx="${ctx}${ctx:+ }突き合わせが成立しなかった実体: ${UNDET_DIRS}。理由: ${UNDET_REASON:-不明}。これは「一致」ではなく「判定不能」であり、名簿が実体から遅れている可能性は排除できない。"
fi
if [ -n "$sys" ]; then
  emit_json "$sys" "${ctx}${HOWTO}この通知を止めたい場合は FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK=1 を設定する。"
fi

exit 0
