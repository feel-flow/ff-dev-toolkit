#!/usr/bin/env bash
#
# 決定木 v0 の hook（UserPromptSubmit / Stop の 2 イベントを 1 本で受ける）。
#
# UserPromptSubmit … ルータ（scripts/decision-tree/route.sh --git）を cwd で走らせ、根の答え
#                    （fast / full / none）をセッション別の記録へ置く。**stdout には何も出さない**
#                    — FF_JEV_MODE=off（既定）では既存の発火（SKILL.md の description / hook の
#                    matcher）に対して何も足さないのが契約で、ルータは経路を測るだけで発火を変えない。
# Stop             … そのセッションで到達した葉を Issue 番号付きで記録へ追記する。到達の根拠は
#                    (1) UserPromptSubmit が置いた根の答え、(2) transcript に残る Skill ツールの
#                    起動（`"skill":"ff-dev-toolkit:<名>"`）、(3) この hook 自身。hook の葉は
#                    それぞれの hook が自分の発火を書かないと分からないので v0 では記録しない
#                    （読み手 effort-report.sh は hook の葉を 0 ではなく (unmeasured) と出す）。
#
# 記録の置き場（Wave 0 の wall-clock / 読み込みバイト記録と同じディレクトリ。追記専用）:
#   ${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/leaves.tsv
#     1 行 1 レコード（タブ区切り・ヘッダ無し）:
#       <ISO 時刻 UTC> <epoch 秒> <Issue 番号 or -> <session_id> <kind> <名> <via> <repo>
#       kind = route | skill | hook、via = root（根の答え）/ transcript（Skill 起動）/ self（この hook）
#       repo = cwd の `git rev-parse --path-format=absolute --git-common-dir`（wall-clock 記録と同じ列）
#     同じセッションで同じ葉は 1 行だけ（sessions/<session_id>.seen で重複を落とす）。.seen の
#     read → check → write は同一セッションの Stop が並行しない前提で原子性を持たない。万一の重複行は
#     読み手が集合として畳む（記録は fail-soft を優先し、ロックは持たない）
#   同 metrics/sessions/<session_id>.route … UserPromptSubmit が置く最新の根の答え（上書き）
#   同 metrics/sessions/<session_id>.seen  … 記録済みの葉（追記）
#   Issue 番号は cwd のブランチ名（`<type>/#<番号>-<slug>`）から取る。取れなければ `-`。
#
# fail-soft（Issue の AC）: 記録が書けない・読めない・ルータが判定できないときはワークフローを
# 止めない（exit 0・stdout 無出力）。ただし黙って 0 にせず、stderr へ `(unmeasured)` を含む
# 1 行を残して区別できるようにする（UserPromptSubmit / Stop の exit 0 では stderr はモデルへ
# 入らないので、観測点は hook ログだけになる）。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_DECISION_TREE=1  この hook を無効化する（ルータも記録も走らない）
#   FF_DEV_TOOLKIT_STATE_DIR             記録の置き場の親（既定 $HOME/.config/ff-dev-toolkit）
#   FF_JEV_MODE / FF_JEV_POINTS          ルータへそのまま渡る（scripts/decision-tree/route.sh のヘッダ）
#
# 設計原則: fail-open（set -e / set -u は使わない）。bash 3.2 互換。依存は jq（入力 JSON の解釈。
# 不在なら (unmeasured) を残して素通し）・git・awk・grep。

# stdin は bash 組み込みの read で読み切る（`cat` だと PATH 破損で未読のまま exit 0 になり、
# 書き手が EPIPE / SIGPIPE を受ける）。opt-out も読み切ってから抜ける。
# UserPromptSubmit / Stop は応答ごと・プロンプトごとに乗るので、retrospective-stop.sh と同じく
# 上限付きで読む（hooks.json の timeout 5 秒を 2 秒の入力段 + 2 秒の捨て読み段へ割る。stdin を
# 開いたまま書かないホストでも hook が自分の予算内で終わる）。上限で切れた回は node があれば
# EOF まで捨て読みして書き手の EPIPE を防ぐ（asdd-hook-gate.sh の stdin contract (c)）。
INPUT_TIMEOUT_SECONDS=2
DRAIN_TIMEOUT_SECONDS=2
input=""
DRAIN_STARTED=$SECONDS
IFS= read -r -t "$INPUT_TIMEOUT_SECONDS" -d '' input
READ_RC=$?
if [ "$READ_RC" -ne 0 ] && [ "$((SECONDS - DRAIN_STARTED))" -ge "$INPUT_TIMEOUT_SECONDS" ] \
  && command -v node >/dev/null 2>&1; then
  node -e '
const stop = () => process.exit(0);
const timer = setTimeout(stop, Number(process.argv[1]) * 1000 || 2000);
process.stdin.on("data", () => {});
process.stdin.on("error", stop);
process.stdin.on("end", () => { clearTimeout(timer); stop(); });
' "$DRAIN_TIMEOUT_SECONDS" >/dev/null 2>&1 || true
fi

# ASDD ゲートは drain より後（ゲートの早期終了は exit 0 で、先に置くと未読のまま抜ける経路ができる）。
# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0

[ "${FF_DEV_TOOLKIT_SKIP_DECISION_TREE:-0}" = "1" ] && exit 0
[ -n "$input" ] || exit 0

unmeasured() { echo "decision-tree: (unmeasured) $1" >&2; exit 0; }

command -v jq >/dev/null 2>&1 || unmeasured "jq が無いため hook 入力を解釈できません"

nl='
'
meta="$(printf '%s' "$input" | jq -r '
  (.hook_event_name // ""),
  (.session_id // ""),
  (.cwd // ""),
  (.transcript_path // "")' 2>/dev/null)" || unmeasured "hook 入力が JSON として読めません"
meta_rest="$meta"
FIELD=""
pop_field() {
  case "$meta_rest" in
    *"$nl"*) FIELD="${meta_rest%%"$nl"*}"; meta_rest="${meta_rest#*"$nl"}" ;;
    *) FIELD="$meta_rest"; meta_rest="" ;;
  esac
}
pop_field; event="$FIELD"
pop_field; session_id="$FIELD"
pop_field; cwd="$FIELD"
pop_field; transcript="$FIELD"

case "$event" in
  UserPromptSubmit|Stop) ;;
  *) exit 0 ;;
esac
# session_id は記録ファイル名になる。パス区切りや空を通さない（`..` も弾く）。
case "$session_id" in
  ''|*/*|*..*|.*) unmeasured "session_id が記録のキーに使えません" ;;
  *[!A-Za-z0-9._-]*) unmeasured "session_id に想定外の文字が含まれています" ;;
esac

PLUGIN_ROOT="${BASH_SOURCE[0]%/*}/.."
ROUTER="$PLUGIN_ROOT/scripts/decision-tree/route.sh"
[ -f "$ROUTER" ] || unmeasured "ルータがありません: ${ROUTER}"
STATE_DIR="${FF_DEV_TOOLKIT_STATE_DIR:-${HOME:-}/.config/ff-dev-toolkit}/metrics"
SESS_DIR="$STATE_DIR/sessions"
LEAVES="$STATE_DIR/leaves.tsv"

if ! mkdir -p "$SESS_DIR" 2>/dev/null || [ ! -w "$SESS_DIR" ]; then
  unmeasured "記録の置き場を作れません / 書けません: ${SESS_DIR}"
fi

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || now_iso="-"
now_epoch="$(date -u +%s 2>/dev/null)" || now_epoch="0"

# ---- UserPromptSubmit: 根の答えをセッション記録へ ----------------------------------------
if [ "$event" = "UserPromptSubmit" ]; then
  [ -n "$cwd" ] && [ -d "$cwd" ] || unmeasured "cwd が無いためルータを走らせられません"
  out="$(cd "$cwd" 2>/dev/null && bash "$ROUTER" --git 2>/dev/null)"
  rc=$?
  route="$(printf '%s\n' "$out" | awk -F= '/^DT_ROUTE=/ { print $2; exit }')"
  reason="$(printf '%s\n' "$out" | awk -F= '/^DT_REASON=/ { sub(/^DT_REASON=/, ""); print; exit }')"
  case "$route" in
    fast|full|none) ;;
    *) unmeasured "ルータが経路を返しませんでした（rc=${rc}）" ;;
  esac
  # ルータの exit 2（判定不能）も none として記録する — 理由は DT_REASON=error:… が運ぶ
  printf '%s\t%s\t%s\t%s\n' "$now_iso" "$now_epoch" "$route" "$reason" > "$SESS_DIR/${session_id}.route" 2>/dev/null \
    || unmeasured "根の答えを書けません: ${SESS_DIR}/${session_id}.route"
  exit 0
fi

# ---- Stop: 到達した葉を leaves.tsv へ ------------------------------------------------------
# repo 列（8 列目）は wall-clock 記録と同じ `git rev-parse --path-format=absolute --git-common-dir`
# （linked worktree 間で共通）。記録置き場はリポジトリ横断で共有されるので、読み手はこの列で
# 別リポジトリの到達を分ける。repo を引けないときは記録しない（同じ規約）。
issue="-"
repo_key=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  repo_key="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || repo_key=""
  branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch=""
  case "$branch" in
    *'#'[0-9]*)
      num="${branch#*#}"
      num="${num%%[!0-9]*}"
      [ -n "$num" ] && issue="$num"
      ;;
  esac
fi
[ -n "$repo_key" ] || unmeasured "cwd の repo（git-common-dir）を引けないため葉を記録しません"

seen_file="$SESS_DIR/${session_id}.seen"
seen=""
[ -f "$seen_file" ] && seen="$(cat "$seen_file" 2>/dev/null)"
seen="${nl}${seen}${nl}"

candidates=""
route_file="$SESS_DIR/${session_id}.route"
if [ -f "$route_file" ]; then
  route="$(awk -F'\t' 'NR == 1 { print $3 }' "$route_file" 2>/dev/null)"
  case "$route" in
    fast|full|none) candidates="route	${route}	root" ;;
  esac
fi
candidates="${candidates}${nl}hook	decision-tree	self"

# transcript の Skill 起動。採るのは次の 2 形だけ（本文やレビュー対象コードに `"skill":"…"` の
# 文字列があるだけでは採らない — 構造を見ずに全文 grep すると偽の到達を記録する）:
#   (1) Skill ツールの tool_use: 同じ行に `"name":"Skill","input":{"skill":"<名>"` が隣接する
#       （Claude Code の transcript は tool_use ブロックをこの順で 1 行に書く。実測 2026-09-23）
#   (2) スラッシュコマンド: `<command-name>/ff-dev-toolkit:<名></command-name>`（接頭辞は省略可）
# どちらの痕跡も無い transcript は「Skill 起動 0」ではなく (unmeasured) として skill の葉を
# 記録しない。木の skill の葉と一致する名前だけを採る（他プラグインのスキルは葉ではない）。
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  skill_leaves="$(bash "$ROUTER" --leaves 2>/dev/null | awk -F'\t' '$1 == "skill" { print $2 }')"
  invoked=""
  if [ -n "$skill_leaves" ]; then
    invoked="$( {
      grep -o '"name":"Skill","input":{"skill":"\(ff-dev-toolkit:\)\{0,1\}[a-z][a-z0-9-]*"' "$transcript" 2>/dev/null \
        | sed 's/^.*"skill":"//; s/^ff-dev-toolkit://; s/"$//'
      grep -o '<command-name>/\(ff-dev-toolkit:\)\{0,1\}[a-z][a-z0-9-]*</command-name>' "$transcript" 2>/dev/null \
        | sed 's/^<command-name>\///; s/^ff-dev-toolkit://; s/<\/command-name>$//'
    } | LC_ALL=C sort -u)"
  fi
  if [ -z "$invoked" ]; then
    echo "decision-tree: (unmeasured) transcript に Skill 起動の痕跡（tool_use / スラッシュコマンド）が無いため skill の葉は記録しません" >&2
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "${nl}${skill_leaves}${nl}" in
      *"${nl}${name}${nl}"*) candidates="${candidates}${nl}skill	${name}	transcript" ;;
    esac
  done <<EOF
$invoked
EOF
else
  echo "decision-tree: (unmeasured) transcript を読めないため Skill 起動の葉は記録しません" >&2
fi

appended=0
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  kind="${cand%%	*}"; rest="${cand#*	}"; name="${rest%%	*}"; via="${rest#*	}"
  key="${kind}:${name}"
  case "$seen" in
    *"${nl}${key}${nl}"*) continue ;;
  esac
  if printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now_iso" "$now_epoch" "$issue" "$session_id" "$kind" "$name" "$via" "$repo_key" >> "$LEAVES" 2>/dev/null \
    && printf '%s\n' "$key" >> "$seen_file" 2>/dev/null; then
    seen="${seen}${key}${nl}"
    appended=$((appended + 1))
  else
    unmeasured "葉の記録を書けません: ${LEAVES}"
  fi
done <<EOF
$candidates
EOF

exit 0
