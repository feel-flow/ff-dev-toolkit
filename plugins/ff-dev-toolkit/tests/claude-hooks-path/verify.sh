#!/usr/bin/env bash
#
# claude-hooks-path: .claude/settings.json の hook 起動コマンドのパス解決（Issue #273）。
#
# 背景: 旧コマンドは `bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/...` で、env が
# 未設定・空の環境ではルート直下の `/.claude/hooks/...` を叩き
# `No such file or directory` になっていた。修正後のコマンドは
#   env → git rev-parse --show-toplevel の順で「hook ファイルが実在する」候補を選び、
#   どちらも解決できなければ additionalContext JSON（stdout）+ stderr の診断を出して
#   fail-open（exit 0）する。exit 0 + stderr だけでは Claude Code の hook 出力仕様上
#   ユーザーに届かないため、可視化は stdout の JSON が担う（hook 本体の notify() /
#   ACE-72-2 と同じ規律）。
#   設計意図: env は権威ではなく**候補**（hook ファイルの実在ゲートで降格する）。
#   env が hook を持たない別ルートを指していても、cwd 側の repo で hook が見つかれば
#   そちらを実行する — settings.json は JSON コメントを持てないため、この意図は
#   本 suite のヘッダが規範として保持し、挙動はケース 3b が固定する。
# 本 suite は settings.json から**実物のコマンド文字列**を抽出してそのまま実行し、
# env あり / git fallback / 解決不能 / 空白入りパス の各経路を固定する。
#
# 対象は SSOT リポジトリの .claude/settings.json（公開配布物ではない）。settings.json
# が無い・対象 hook 定義が無いチェックアウト（公開リポジトリ等）では ○ skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
SETTINGS="${REPO_ROOT:+$REPO_ROOT/.claude/settings.json}"

if [ -z "$REPO_ROOT" ] || [ ! -f "$SETTINGS" ]; then
  echo "○ skip: .claude/settings.json が無いチェックアウトのためスキップ（本 suite は SSOT リポジトリ専用の検査です）"
  FF_REACHED_END=1
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（.claude/settings.json の hook 起動コマンドは未検査のままです）"
  FF_REACHED_END=1
  exit 0
fi

HOOK_NAMES="post-merge-dev-toolkit-sync.sh session-start-sync-drift.sh"

# settings.json が valid JSON であること自体を独立に固定する — 壊れていると
# Claude Code は hook を全停止するため、これは沈黙の全無効化ゲートでもある。
if command -v jq >/dev/null 2>&1 && ! jq empty "$SETTINGS" 2>/dev/null; then
  echo "✗ .claude/settings.json が valid JSON ではありません（壊れていると Claude Code は hook を全停止します）" >&2
  exit 1
fi

# 対象 hook はイベント種別ごとの正確な JSON パスから数える。**両方とも 0 件**なら
# このチェックアウトは対象外（公開リポジトリ等）として skip。片方だけ消えている・
# 複数あるのは SSOT 側の設定事故なので fail-closed で名指しする（ファイル名の
# 全文 grep だと、対象 hook の削除が「対象外」として静かに成功してしまう）。
PM_COUNT="$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command // empty | select(contains("post-merge-dev-toolkit-sync.sh"))] | length' "$SETTINGS")"
SS_COUNT="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(contains("session-start-sync-drift.sh"))] | length' "$SETTINGS")"
if [ "$PM_COUNT" = 0 ] && [ "$SS_COUNT" = 0 ]; then
  echo "○ skip: 対象 hook の定義が settings.json に無いためスキップ（SSOT リポジトリ以外の構成）"
  FF_REACHED_END=1
  exit 0
fi
if [ "$PM_COUNT" != 1 ] || [ "$SS_COUNT" != 1 ]; then
  echo "✗ 対象 hook の定義数が想定と違う（post-merge=${PM_COUNT} / session-start=${SS_COUNT}。片方だけの削除・重複は設定事故）" >&2
  exit 1
fi
# 抽出も正確な JSON パスで行う（改行を含むコマンドでも全文が 1 要素として取れる —
# 変数を grep/head に流す形は、コマンドが将来複数行に整形されたとき**断片**を
# 実行する事故と、下流早期終了の SIGPIPE 事故を同居させる）。
PM_CMD="$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command // empty | select(contains("post-merge-dev-toolkit-sync.sh"))][0]' "$SETTINGS")"
SS_CMD="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(contains("session-start-sync-drift.sh"))][0]' "$SETTINGS")"

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ claude-hooks-path: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# fixture ルートを作る: .claude/hooks/<name> は実行されたら "$0.ran" を作り、
# stdin を "$0.stdin" へ保全する stub — resolver という間接層が stdin を消費する
# 退行（hook 本体は stdin の hook JSON を読む契約）をここで検出する。
make_root() { # $1: ルートパス
  mkdir -p "$1/.claude/hooks"
  local n
  for n in $HOOK_NAMES; do
    printf '%s\n' '#!/usr/bin/env bash' 'cat > "$0.stdin"' ': > "$0.ran"' > "$1/.claude/hooks/$n"
    chmod +x "$1/.claude/hooks/$n"
  done
}

get_command() { # $1: hook 名 / stdout: settings.json の実コマンド文字列
  case "$1" in
    post-merge-dev-toolkit-sync.sh) printf '%s\n' "$PM_CMD" ;;
    session-start-sync-drift.sh)    printf '%s\n' "$SS_CMD" ;;
  esac
}

# run_cmd <コマンド> <cwd> <env指定: unset|パス>
# GIT_DIR / GIT_WORK_TREE の環境 leak は cwd 基準の rev-parse を狂わせるため常に除去。
# GIT_CEILING_DIRECTORIES で $TMP より上への遡上も禁止する — TMPDIR が何かの
# リポジトリ配下にある環境で、非 git のはずの fixture が外側の実リポジトリへ
# 解決して**実 hook を起動する**事故を防ぐ。
# 実行は sh -c — hook コマンドの実行契約に合わせる（resolver は POSIX sh の範囲で
# 書かれており、bash 拡張に依存しないことの検査を兼ねる）。stdin には既知の
# hook JSON を流し、hook 本体への素通し（stdin 契約）を検査可能にする。
HOOK_STDIN='{"tool_input":{"command":"claude-hooks-path fixture"}}'
run_cmd() {
  local cmd="$1" dir="$2" envmode="$3"
  if [ "$envmode" = "unset" ]; then
    (cd "$dir" && printf '%s' "$HOOK_STDIN" | env -u CLAUDE_PROJECT_DIR -u GIT_DIR -u GIT_WORK_TREE GIT_CEILING_DIRECTORIES="$TMP" sh -c "$cmd") >"$TMP/out.log" 2>"$TMP/err.log"
  else
    (cd "$dir" && printf '%s' "$HOOK_STDIN" | env -u GIT_DIR -u GIT_WORK_TREE GIT_CEILING_DIRECTORIES="$TMP" CLAUDE_PROJECT_DIR="$envmode" sh -c "$cmd") >"$TMP/out.log" 2>"$TMP/err.log"
  fi
}

NONGIT="$TMP/nongit"
mkdir -p "$NONGIT"

echo "== hook 起動コマンドのパス解決（Issue #273） =="

for name in $HOOK_NAMES; do
  CMD="$(get_command "$name")"
  if [ -z "$CMD" ] || [ "$CMD" = "null" ]; then
    bad "${name}: settings.json にコマンド定義が無い"
    continue
  fi

  # 静的契約 2 件: git fallback を持つこと / 旧形（bare 直付け。env 未設定で
  # /.claude を叩く形）が残っていないこと — 存在検査だけだと新旧連結で緑になる。
  case "$CMD" in
    *'rev-parse --show-toplevel'*) ok "${name}: git fallback を持つ" ;;
    *) bad "${name}: git fallback（rev-parse --show-toplevel）が無い" ;;
  esac
  case "$CMD" in
    *'"$CLAUDE_PROJECT_DIR"/.claude'*) bad "${name}: 旧形（bare \$CLAUDE_PROJECT_DIR 直付け）が残っている" ;;
    *) ok "${name}: 旧形の直付け参照が残っていない" ;;
  esac

  # 1. env が有効なルートを指す → そのルートの hook が実行される
  ROOT_A="$TMP/rootA-$name"
  make_root "$ROOT_A"
  rc=0; run_cmd "$CMD" "$NONGIT" "$ROOT_A" || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$ROOT_A/.claude/hooks/$name.ran" ]; then
    ok "${name}: CLAUDE_PROJECT_DIR 指定ルートの hook を実行する"
  else
    bad "${name}: env 指定ルートの hook が実行されない (rc=$rc)"
    cat "$TMP/err.log" | sed 's/^/    | /' >&2
  fi
  # stdin 契約: resolver 層が hook JSON を消費せず hook 本体へ素通しすること
  if [ "$(cat "$ROOT_A/.claude/hooks/$name.stdin" 2>/dev/null)" = "$HOOK_STDIN" ]; then
    ok "${name}: stdin の hook JSON が本体へ素通しされる"
  else
    bad "${name}: stdin が hook 本体に届いていない（resolver 層が消費している疑い）"
  fi

  # 2. env 未設定 + git リポジトリ内の cwd → git fallback で実行される
  ROOT_B="$TMP/rootB-$name"
  make_root "$ROOT_B"
  git init -q "$ROOT_B"
  mkdir -p "$ROOT_B/sub/dir"
  rc=0; run_cmd "$CMD" "$ROOT_B/sub/dir" unset || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$ROOT_B/.claude/hooks/$name.ran" ]; then
    ok "${name}: env 未設定でも git toplevel から hook を解決する"
  else
    bad "${name}: git fallback で hook が実行されない (rc=$rc)"
    cat "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 3. env 未設定 + 非 git cwd → ブロックせず（exit 0）、原因を**ユーザーに届く形**で
  #    診断して、旧症状（/.claude への No such file）を出さない。
  #    exit 0 + stderr は Claude Code の hook 出力仕様では通常 UI に出ないため、
  #    診断は additionalContext JSON として stdout に無ければならない（hook 本体の
  #    notify() / ACE-72-2 と同じ規律）。stderr 版は --debug 用の補助。
  rc=0; run_cmd "$CMD" "$NONGIT" unset || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "${name}: 解決不能時にメイン処理をブロックした (rc=$rc)"
  elif [ "$(/usr/bin/grep -c '\[ff-hook\] skip' "$TMP/out.log")" != 1 ] || ! /usr/bin/grep -q 'additionalContext' "$TMP/out.log"; then
    bad "${name}: 解決不能の診断が stdout の additionalContext にちょうど 1 回出ていない（exit 0 + stderr は UI に届かない）"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  elif /usr/bin/grep -q 'No such file' "$TMP/err.log"; then
    bad "${name}: 旧症状（No such file）が再現している"
  elif ! /usr/bin/grep -q 'root unresolved' "$TMP/out.log"; then
    bad "${name}: 解決不能の診断がルート未解決を名指ししていない"
  else
    ok "${name}: 解決不能時は fail-open + ユーザーに届く診断が起動ごとに 1 回（No such file なし）"
  fi

  # 3b. ルートは解決できるが hook ファイルが無い → 「root unresolved」と誤診せず
  #     hook 不在を名指しする（対処の案内が嘘にならない）
  ROOT_M="$TMP/rootM-$name"
  mkdir -p "$ROOT_M"
  rc=0; run_cmd "$CMD" "$NONGIT" "$ROOT_M" || rc=$?
  if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'hook file missing' "$TMP/out.log"; then
    ok "${name}: hook 不在はルート未解決と区別して名指しされる"
  else
    bad "${name}: hook 不在の診断が区別されない (rc=$rc)"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 4. 空白・シェルメタ文字（$ ; *）を含むプロジェクトパス → 分割・再解釈せず
  #    正しい hook を実行する
  ROOT_S="$TMP/root with \$meta;and star-$name"
  make_root "$ROOT_S"
  rc=0; run_cmd "$CMD" "$NONGIT" "$ROOT_S" || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$ROOT_S/.claude/hooks/$name.ran" ]; then
    ok "${name}: 空白・メタ文字入りパスでも正しい hook を実行する"
  else
    bad "${name}: 空白・メタ文字入りパスで hook が実行されない (rc=$rc)"
    cat "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 5. env と git の両候補が有効 → env が優先される（git 側は実行されない）
  ROOT_E="$TMP/rootE-$name"
  make_root "$ROOT_E"
  ROOT_G="$TMP/rootG-$name"
  make_root "$ROOT_G"
  git init -q "$ROOT_G"
  rc=0; run_cmd "$CMD" "$ROOT_G" "$ROOT_E" || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$ROOT_E/.claude/hooks/$name.ran" ] && [ ! -f "$ROOT_G/.claude/hooks/$name.ran" ]; then
    ok "${name}: 両候補が有効なら env を優先する（git 側は実行されない）"
  else
    bad "${name}: 候補の優先順位が期待と違う (rc=$rc env-ran=$([ -f "$ROOT_E/.claude/hooks/$name.ran" ] && echo y || echo n) git-ran=$([ -f "$ROOT_G/.claude/hooks/$name.ran" ] && echo y || echo n))"
  fi

  # 6. env が hook を持たないルートを指す + cwd の repo は hook を持つ →
  #    git 候補へ**継続**して実行される（env で打ち切る退行の検出）
  ROOT_N="$TMP/rootN-$name"
  mkdir -p "$ROOT_N"
  ROOT_G2="$TMP/rootG2-$name"
  make_root "$ROOT_G2"
  git init -q "$ROOT_G2"
  rc=0; run_cmd "$CMD" "$ROOT_G2" "$ROOT_N" || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$ROOT_G2/.claude/hooks/$name.ran" ]; then
    ok "${name}: env 候補に hook が無ければ git 候補へ継続する"
  else
    bad "${name}: env 候補で打ち切られ git 候補へ継続しない (rc=$rc)"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi
done

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ claude-hooks-path verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ claude-hooks-path verify: 全 $PASS 件 pass"
FF_REACHED_END=1
