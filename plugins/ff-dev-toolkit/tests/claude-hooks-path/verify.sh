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
# あわせて起動チェーンの下流も固定する（Issue #474）: hook 本体が参照するルート、
# linked worktree での解決、gh の実行 cwd（GitHub 側の照会先）、hook から起動される
# scripts/check-dev-toolkit-sync-drift.sh 自身のルート解決、および解決不能時に
# スキップが可視化されること。
#
# 対象は SSOT リポジトリの .claude/settings.json（公開配布物ではない）。skip の判定軸は
# settings.json の存在と対象 hook の定義数のみ（公開リポジトリ等では ○ skip）。定義が
# あるのに hook 実体や drift checker が無いのは SSOT 側の事故なので fail-closed で名指しする。

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

HOOK_NAMES="post-merge-dev-toolkit-sync.sh session-start-sync-drift.sh session-start-dependabot-health.sh"

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
DH_COUNT="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(contains("session-start-dependabot-health.sh"))] | length' "$SETTINGS")"
if [ "$PM_COUNT" = 0 ] && [ "$SS_COUNT" = 0 ] && [ "$DH_COUNT" = 0 ]; then
  echo "○ skip: 対象 hook の定義が settings.json に無いためスキップ（SSOT リポジトリ以外の構成）"
  FF_REACHED_END=1
  exit 0
fi
if [ "$PM_COUNT" != 1 ] || [ "$SS_COUNT" != 1 ] || [ "$DH_COUNT" != 1 ]; then
  echo "✗ 対象 hook の定義数が想定と違う（post-merge=${PM_COUNT} / session-start=${SS_COUNT} / dependabot-health=${DH_COUNT}。片方だけの削除・重複は設定事故）" >&2
  exit 1
fi
# 抽出も正確な JSON パスで行う（改行を含むコマンドでも全文が 1 要素として取れる —
# 変数を grep/head に流す形は、コマンドが将来複数行に整形されたとき**断片**を
# 実行する事故と、下流早期終了の SIGPIPE 事故を同居させる）。
PM_CMD="$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command // empty | select(contains("post-merge-dev-toolkit-sync.sh"))][0]' "$SETTINGS")"
SS_CMD="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(contains("session-start-sync-drift.sh"))][0]' "$SETTINGS")"
DH_CMD="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(contains("session-start-dependabot-health.sh"))][0]' "$SETTINGS")"

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
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
    post-merge-dev-toolkit-sync.sh)     printf '%s\n' "$PM_CMD" ;;
    session-start-sync-drift.sh)        printf '%s\n' "$SS_CMD" ;;
    session-start-dependabot-health.sh) printf '%s\n' "$DH_CMD" ;;
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

# ---- hook 本体が参照するルート（Issue #474） ----
# 上のループは hook を stub へ差し替えるため、**hook 本体**がどのルートを見るかは
# 本 suite では未検査だった（3 hook のうち session-start-dependabot-health.sh のみ
# public-dependabot-health suite のケース 12 が別途固定している）。ラッパーが解決したルート `$d` を hook 本体が受け取らず、自分で
# cwd 基準の rev-parse をやり直す退行がここを素通りする（cwd が非 git なら無音
# 終了し検査が黙って無効化、cwd が別リポジトリならそちら側のスクリプトを実行）。
# ここでは**実物の hook** を fixture ルートへ複製し、そこから呼ばれる checker /
# 同期スクリプトを marker 付き stub にして、どちら側が実行されたかを観測する。

REAL_HOOK_DIR="$REPO_ROOT/.claude/hooks"

# hook 本体から呼ばれるスクリプトの stub。実行されたら "$0.ran" を作り、
# KEY=値 プロトコルの最小応答を返す（本文は別ファイルに置き、stub 生成時に
# シェル解釈を挟まない）。
make_stub() { # $1: スクリプトパス / $2: stdout に出す本文
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1.payload"
  printf '%s\n' '#!/usr/bin/env bash' ': > "$0.ran"' 'cat "$0.payload"' > "$1"
  chmod +x "$1"
}

# 実 hook を持つ fixture リポジトリ。`git init` は必須 — hook 本体は自身の配置
# から rev-parse するため、非 git のルートに置くと修正後も解決できず「marker が
# 無い」だけの、バグと区別できない赤になる。
make_real_root() { # $1: ルートパス
  local root="$1" n
  mkdir -p "$root/.claude/hooks"
  for n in $HOOK_NAMES; do
    cp "$REAL_HOOK_DIR/$n" "$root/.claude/hooks/$n"
    chmod +x "$root/.claude/hooks/$n"
  done
  make_stub "$root/scripts/check-dev-toolkit-sync-drift.sh" "DRIFT_COUNT=0"
  make_stub "$root/scripts/check-public-dependabot-health.sh" "GRAPH_MANIFESTS=1
OPEN_ALERTS=0
GHOST_ALERTS=0"
  make_stub "$root/scripts/sync-dev-toolkit-to-public.sh" "plugins/ff-dev-toolkit"
  git init -q "$root"
}

# 実 `gh` へ出さないための stub。PATH 差し込みが効かないと hook は gh 失敗経路
# へ落ちて marker が立たず、ルート解決の失敗と区別できなくなるため、stub 自身の
# 実行も marker で固定する。
# 実行時の cwd も記録する: gh は `git -C` 相当を持たず **cwd の git remote** から
# 対象リポジトリを決めるため、ローカルのスクリプト解決だけ直しても GitHub 側の
# 照会先が cwd 側リポジトリに残る。どのディレクトリで呼ばれたかが唯一の観測点。
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'FF_GH_STUB'
#!/usr/bin/env bash
: > "$0.ran"
pwd -P >> "$0.pwd"
case "$*" in
  *"pr view"*) printf '%s' '{"state":"MERGED","number":999}' ;;
  *"pr diff"*) printf '%s\n' 'plugins/ff-dev-toolkit/skills/example/SKILL.md' ;;
  *) exit 1 ;;
esac
FF_GH_STUB
chmod +x "$STUB_BIN/gh"

# hook 名 → その hook が実行されたときに marker が立つスクリプトの相対パス群。
# post-merge は解決済みルートを**消費する箇所**を 2 つ持つ（公開対象パターンの
# 構築と drift 検査）。片方だけ cwd 側へ漏れる部分故障を見逃さないよう両方を
# 固定する（解決そのものは修正後 1 箇所に寄せてある）。
markers_for() { # $1: hook 名
  case "$1" in
    session-start-sync-drift.sh)
      printf '%s\n' 'scripts/check-dev-toolkit-sync-drift.sh' ;;
    session-start-dependabot-health.sh)
      printf '%s\n' 'scripts/check-public-dependabot-health.sh' ;;
    post-merge-dev-toolkit-sync.sh)
      printf '%s\n' 'scripts/sync-dev-toolkit-to-public.sh' 'scripts/check-dev-toolkit-sync-drift.sh' ;;
  esac
}

# 未実行の marker を空白区切りで返す（空 = 全て実行された）
missing_markers() { # $1: ルート / $2: hook 名
  local m out=""
  for m in $(markers_for "$2"); do
    [ -f "$1/$m.ran" ] || out="${out} $m"
  done
  printf '%s' "$out"
}

# marker が 1 つでも実行されていれば 0。「一部だけ誤実行された」を見逃さないため、
# 参照してはいけない側の判定は missing の有無ではなくこちらで行う（解決箇所を
# 複数持つ hook では、片方だけ cwd 側へ漏れる部分故障がありうる）。
ran_any() { # $1: ルート / $2: hook 名
  local m
  for m in $(markers_for "$2"); do
    if [ -f "$1/$m.ran" ]; then return 0; fi
  done
  return 1
}

# run_real <コマンド> <cwd> <env指定: unset|パス>
# 実 hook を起動する版。PATH に stub bin を前置して実ネットワークへ出さない。
# stdin は post-merge の入口条件（`gh pr merge` を含む Bash コマンド）を満たす形。
REAL_STDIN='{"tool_input":{"command":"gh pr merge 999 --squash"}}'
run_real() {
  local cmd="$1" dir="$2" envmode="$3"
  rm -f "$STUB_BIN/gh.ran" "$STUB_BIN/gh.pwd"
  if [ "$envmode" = "unset" ]; then
    (cd "$dir" && printf '%s' "$REAL_STDIN" | env -u CLAUDE_PROJECT_DIR -u GIT_DIR -u GIT_WORK_TREE GIT_CEILING_DIRECTORIES="$TMP" PATH="$STUB_BIN:$PATH" sh -c "$cmd") >"$TMP/out.log" 2>"$TMP/err.log"
  else
    (cd "$dir" && printf '%s' "$REAL_STDIN" | env -u GIT_DIR -u GIT_WORK_TREE GIT_CEILING_DIRECTORIES="$TMP" CLAUDE_PROJECT_DIR="$envmode" PATH="$STUB_BIN:$PATH" sh -c "$cmd") >"$TMP/out.log" 2>"$TMP/err.log"
  fi
}

echo
echo "== hook 本体が参照するルート（Issue #474） =="

for name in $HOOK_NAMES; do
  CMD="$(get_command "$name")"
  if [ -z "$CMD" ] || [ "$CMD" = "null" ]; then
    bad "${name}: settings.json にコマンド定義が無い"
    continue
  fi
  # settings.json に登録があるのに実体が無いのは SSOT 側の事故。skip にしない
  if [ ! -f "$REAL_HOOK_DIR/$name" ]; then
    bad "${name}: hook 実体が ${REAL_HOOK_DIR} に無い（settings.json には登録済み）"
    continue
  fi
  # marker 未登録のまま進むと以降のケースが空ループで真空 pass する。suite 全体は
  # 別ケースで赤くなるが、原因が「cwd 側を参照している」と誤って報告される
  if [ -z "$(markers_for "$name")" ]; then
    bad "${name}: markers_for に marker が登録されていない（HOOK_NAMES へ足したら登録も要る）"
    continue
  fi

  # 7. env が正しいリポジトリを指し cwd が非 git → env 側のスクリプトが動く。
  #    修正前の壊れ方は hook ごとに違った（SessionStart 側は無音終了、post-merge は
  #    「公開対象パターンの構築に失敗」という誤った理由の通知）が、いずれも
  #    指定ルート側の検査は実行されなかった。判定は機構ではなく marker で行う
  RA="$TMP/realA-$name"
  make_real_root "$RA"
  rc=0; run_real "$CMD" "$NONGIT" "$RA" || rc=$?
  miss="$(missing_markers "$RA" "$name")"
  if [ "$rc" -eq 0 ] && [ -z "$miss" ]; then
    ok "${name}: cwd が非 git でも CLAUDE_PROJECT_DIR 側のスクリプトを実行する"
  else
    bad "${name}: cwd が非 git のとき指定ルート側のスクリプトが実行されない（未実行:${miss:- なし} rc=${rc}）"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 8. env がリポジトリ A・cwd がリポジトリ B → 参照されるのは A 側だけ
  #    （B 側の marker が立つ = cwd 基準で解決している退行の陽性検出）
  RB="$TMP/realB-$name"
  make_real_root "$RB"
  rm -f "$RA/scripts"/*.ran   # ケース 7 の marker を持ち越すと本ケースが常に緑になる
  rc=0; run_real "$CMD" "$RB" "$RA" || rc=$?
  miss="$(missing_markers "$RA" "$name")"
  # cwd 側は 1 つも動いてはいけない。「未実行が 1 つでもあれば合格」にすると、
  # 解決箇所が複数ある hook で片方だけ cwd 側へ漏れる部分故障を見逃す
  if [ "$rc" -eq 0 ] && [ -z "$miss" ] && ! ran_any "$RB" "$name"; then
    ok "${name}: cwd が別リポジトリでも env 側のスクリプトだけを実行する"
  else
    bad "${name}: cwd 側リポジトリのスクリプトを参照している（env 側未実行:${miss:- なし} / cwd 側実行:$(ran_any "$RB" "$name" && echo あり || echo なし) rc=${rc}）"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 8b. gh はローカルのファイル解決とは別に、**cwd の git remote** から対象
  #     リポジトリを決める。ケース 8 と同じ配置で、gh が env 側ルートで
  #     呼ばれていることを実行時 cwd の記録から固定する（cwd 側で呼ばれると
  #     別リポジトリの PR の変更ファイルを同期判定の根拠にしてしまう）。
  if [ "$name" = "post-merge-dev-toolkit-sync.sh" ]; then
    # gh は pr view と pr diff で 2 回呼ばれる。1 回目だけを見ると、片方の
    # 呼び出しだけ cwd 側へ漏れる部分退行が緑のまま通る（ran_any と同じ理由）。
    # 記録**全体**が env 側ルート 1 種類に揃っていることを要求し、あわせて
    # 呼び出し回数の下限も置く — 回数を見ないと、将来 call site が減ったときに
    # 検査が静かに縮小する。
    gh_calls="$(/usr/bin/grep -c . "$STUB_BIN/gh.pwd" 2>/dev/null)" || gh_calls=0
    gh_dirs="$(sort -u "$STUB_BIN/gh.pwd" 2>/dev/null)" || gh_dirs=""
    want_pwd="$(cd "$RA" && pwd -P)"
    if [ "$gh_calls" -ge 2 ] && [ "$gh_dirs" = "$want_pwd" ]; then
      ok "${name}: gh の全呼び出しを env 側ルートで実行する（GitHub 側の照会先も cwd に残らない）"
    elif [ "$gh_calls" -lt 2 ]; then
      bad "${name}: gh の呼び出しが ${gh_calls} 回しか記録されていない（pr view と pr diff の双方を検査できていない）"
    else
      bad "${name}: gh の実行 cwd が env 側ルートに揃っていない（記録=$(printf '%s' "$gh_dirs" | tr '\n' ' ')/ 期待=${want_pwd}）"
    fi
  fi

  # 8c. env 候補が hook を持たない（ラッパーはケース 6 で cwd 候補へ降格する）→
  #     起動された hook は cwd 側リポジトリを見る。ここを env 優先にすると、
  #     「env は権威ではなく候補」というラッパーの判断を本体が覆すことになり、
  #     降格経路で #474 と同じ食い違いが復活する。解決に CLAUDE_PROJECT_DIR を
  #     混ぜる形（例: git -C "${CLAUDE_PROJECT_DIR:-$script_dir}"）は他の全ケースを
  #     通過するため、この配置だけが検出できる。
  RE="$TMP/envnohook-$name"
  mkdir -p "$RE"
  make_stub "$RE/scripts/check-dev-toolkit-sync-drift.sh" "DRIFT_COUNT=0"
  make_stub "$RE/scripts/check-public-dependabot-health.sh" "GRAPH_MANIFESTS=1
OPEN_ALERTS=0
GHOST_ALERTS=0"
  make_stub "$RE/scripts/sync-dev-toolkit-to-public.sh" "plugins/ff-dev-toolkit"
  git init -q "$RE"
  RG="$TMP/gitside-$name"
  make_real_root "$RG"
  rc=0; run_real "$CMD" "$RG" "$RE" || rc=$?
  miss="$(missing_markers "$RG" "$name")"
  if [ "$rc" -eq 0 ] && [ -z "$miss" ] && ! ran_any "$RE" "$name"; then
    ok "${name}: 降格された env 候補ではなく起動元リポジトリのスクリプトを使う"
  else
    bad "${name}: 降格された env 候補のスクリプトを参照している（起動元未実行:${miss:- なし} rc=${rc}）"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 9. env 未設定 + cwd がリポジトリ内 → 従来どおり cwd のリポジトリを使う（回帰なし）
  RC="$TMP/realC-$name"
  make_real_root "$RC"
  mkdir -p "$RC/sub/dir"
  rc=0; run_real "$CMD" "$RC/sub/dir" unset || rc=$?
  miss="$(missing_markers "$RC" "$name")"
  if [ "$rc" -eq 0 ] && [ -z "$miss" ]; then
    ok "${name}: env 未設定なら従来どおり cwd のリポジトリを使う"
  else
    bad "${name}: env 未設定時に cwd のリポジトリを解決できない（未実行:${miss:- なし} rc=${rc}）"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 10. linked worktree: hook 自身の配置から解決するなら、参照先は親 checkout では
  #     なく worktree 自身になる。`--git-common-dir` や親 checkout 基準への退行は
  #     通常の git init だけの fixture では観測できないため、専用のケースを持つ。
  RW="$TMP/wtmain-$name"
  make_real_root "$RW"
  git -C "$RW" add -A
  git -C "$RW" -c user.name=ff -c user.email=ff@example.invalid commit -q -m init
  WT="$TMP/wtlinked-$name"
  git -C "$RW" worktree add -q --detach "$WT" HEAD
  rm -f "$RW/scripts"/*.ran   # 親 checkout 側の marker を持ち越さない
  rc=0; run_real "$CMD" "$NONGIT" "$WT" || rc=$?
  miss="$(missing_markers "$WT" "$name")"
  if [ "$rc" -eq 0 ] && [ -z "$miss" ] && ! ran_any "$RW" "$name"; then
    ok "${name}: linked worktree では worktree 自身のスクリプトを実行する"
  else
    bad "${name}: linked worktree で親 checkout 側を参照している（worktree 側未実行:${miss:- なし} rc=${rc}）"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # post-merge のみ: 直前のケース 10 が gh stub 経由で走っていたことを固定する
  # （run_real は毎回 marker を消すため、これが見ているのは最後の 1 回だけ）。
  # PATH 差し込みが効かないと gh 失敗経路へ落ち、marker 不在がルート解決の
  # 失敗と見分けられなくなる。実 gh がネットワークへ出る事故の検出も兼ねる。
  if [ "$name" = "post-merge-dev-toolkit-sync.sh" ]; then
    if [ -f "$STUB_BIN/gh.ran" ]; then
      ok "${name}: 直前のケースで gh は stub 経由で呼ばれている（実ネットワークへ出ていない）"
    else
      bad "${name}: gh stub が呼ばれていない（PATH 差し込みが効いていない疑い）"
    fi
  fi

  # 11. hook 自身がリポジトリ外に置かれた → 無音で落ちず、ユーザーに届く形で
  #     スキップを可視化する（ACE-72-2）。判定対象が cwd から hook 自身の配置へ
  #     変わったことで、この分岐に落ちる理由も変わった: ラッパーは既にこの
  #     ファイルの実在を確認して起動しているので、残るのは git が PATH に無い・
  #     safe.directory の所有権拒否（rev-parse は exit 128）といった**恒久的な**
  #     環境異常だけ。無音にすると検査が永久に無効化されたまま誰も気づけない。
  RN="$TMP/nogit-$name"
  mkdir -p "$RN/.claude/hooks"
  cp "$REAL_HOOK_DIR/$name" "$RN/.claude/hooks/$name"
  chmod +x "$RN/.claude/hooks/$name"
  rc=0; run_real "$CMD" "$NONGIT" "$RN" || rc=$?
  if [ "$rc" -eq 0 ] \
    && /usr/bin/grep -q 'additionalContext' "$TMP/out.log" \
    && /usr/bin/grep -q 'リポジトリルートを解決できなかった' "$TMP/out.log"; then
    ok "${name}: hook がリポジトリ外にあるときはスキップを可視化する（無音にしない）"
  else
    bad "${name}: リポジトリ外配置のスキップが可視化されない (rc=${rc})"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi
done

# ---- hook から起動される checker のルート解決（Issue #474） ----
# hook が正しいルートの checker「ファイル」を起動しても、checker 自身が cwd 基準で
# rev-parse していれば同じ食い違いが 1 階層下で再発する。しかも症状は無音終了より
# 悪い: checker は解決したルートへ cd してから全ての git 操作を行うため、cwd 側
# リポジトリの drift 件数を、依頼したリポジトリの答えとして返してしまう。

# drift checker の fixture リポジトリ。HEAD を develop に向けるのは必須 —
# git init の既定ブランチは develop ではないため、明示しないと checker は
# 「develop が見つからない」で skip し、修正前後で同じ結果になってルート解決を
# 検査したことにならない。コミットは global の git identity に依存させない。
make_drift_root() { # $1: ルートパス
  local root="$1"
  mkdir -p "$root"
  git init -q "$root"
  git -C "$root" symbolic-ref HEAD refs/heads/develop
  make_stub "$root/scripts/sync-dev-toolkit-to-public.sh" "plugins/ff-dev-toolkit"
  cp "$DRIFT_CHECKER" "$root/scripts/"
  git -C "$root" -c user.name=ff -c user.email=ff@example.invalid commit -q --allow-empty -m init
}

# run_drift <cwd> <checker を置いたルート>
# remote 未設定なので checker 内の fetch は即失敗する（STALE_TIP=1 で継続）。
# PATH に stub bin を前置するのは、実ネットワークを SYNC_DRIFT_BASE_OVERRIDE
# 一枚に依存させないため（override の扱いが変われば実 gh api へ出てしまう）。
run_drift() {
  (cd "$1" && env -u CLAUDE_PROJECT_DIR -u GIT_DIR -u GIT_WORK_TREE GIT_CEILING_DIRECTORIES="$TMP" \
    PATH="$STUB_BIN:$PATH" SYNC_DRIFT_BASE_OVERRIDE="$(git -C "$2" rev-parse HEAD)" \
    bash "$2/scripts/check-dev-toolkit-sync-drift.sh") >"$TMP/out.log" 2>"$TMP/err.log"
}

DRIFT_CHECKER="$REPO_ROOT/scripts/check-dev-toolkit-sync-drift.sh"
if [ ! -x "$DRIFT_CHECKER" ]; then
  bad "check-dev-toolkit-sync-drift.sh が無いか実行権限がない（hook から起動される契約）"
else
  RD="$TMP/driftroot"
  make_drift_root "$RD"

  # 12. cwd が非 git → 自身の配置から解決して判定を返す（旧: SKIP_REASON で無効化）
  rc=0; run_drift "$NONGIT" "$RD" || rc=$?
  if [ "$rc" -eq 0 ] && /usr/bin/grep -q '^DRIFT_COUNT=' "$TMP/out.log"; then
    ok "check-dev-toolkit-sync-drift.sh: cwd が非 git でも自身の配置から解決する"
  else
    bad "check-dev-toolkit-sync-drift.sh: cwd が非 git だと判定できない (rc=$rc)"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 13. cwd が別リポジトリ → cwd 側ではなく自身のリポジトリの公開対象一覧を使う。
  #     marker が cwd 側に立つ = 別リポジトリの答えを返している（無音より悪い誤答）。
  #     この fixture は cwd 側にも sync スクリプトと到達可能な基点コミットを
  #     用意している — 誤答経路が成立するのはその条件下だけで、無関係な
  #     リポジトリを cwd にすると sync スクリプト不在で可視 SKIP に落ちるため、
  #     そちらでは退行を観測できない。
  RD2="$TMP/driftroot-cwd"
  make_drift_root "$RD2"
  rm -f "$RD/scripts"/*.ran "$RD2/scripts"/*.ran
  rc=0; run_drift "$RD2" "$RD" || rc=$?
  if [ "$rc" -eq 0 ] \
    && [ -f "$RD/scripts/sync-dev-toolkit-to-public.sh.ran" ] \
    && [ ! -f "$RD2/scripts/sync-dev-toolkit-to-public.sh.ran" ]; then
    ok "check-dev-toolkit-sync-drift.sh: cwd が別リポジトリでも自身のリポジトリを判定する"
  else
    bad "check-dev-toolkit-sync-drift.sh: cwd 側リポジトリの答えを返している (rc=$rc)"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 14. checker が linked worktree にある → 親 checkout ではなく worktree 自身を
  #     見る。checker は解決したルートへ cd してから全 git 操作を行うため、ここが
  #     親を向くと **marker は正しく見えたまま件数だけが親の答え**になりうる。
  #     公開対象一覧を親と worktree で食い違わせ、DRIFT_COUNT の値まで固定する
  #     （ref は worktree 間で共有されるので、差を作れるのは一覧の側）。
  RD4="$TMP/driftroot-wt"
  mkdir -p "$RD4"
  git init -q "$RD4"
  git -C "$RD4" symbolic-ref HEAD refs/heads/develop
  make_stub "$RD4/scripts/sync-dev-toolkit-to-public.sh" "plugins/ff-dev-toolkit"
  cp "$DRIFT_CHECKER" "$RD4/scripts/"
  git -C "$RD4" add -A
  git -C "$RD4" -c user.name=ff -c user.email=ff@example.invalid commit -q -m init
  BASE_WT="$(git -C "$RD4" rev-parse HEAD)"
  mkdir -p "$RD4/plugins/ff-dev-toolkit"
  printf '%s\n' 'x' > "$RD4/plugins/ff-dev-toolkit/x.md"
  git -C "$RD4" add -A
  git -C "$RD4" -c user.name=ff -c user.email=ff@example.invalid commit -q -m 'touch public target'
  WTD="$TMP/driftroot-wtlinked"
  git -C "$RD4" worktree add -q --detach "$WTD" HEAD
  # 親側の一覧からだけ当該パスを外す → 親を見れば 0 件、worktree を見れば 1 件
  printf '%s\n' 'oss/ff-dev-toolkit' > "$RD4/scripts/sync-dev-toolkit-to-public.sh.payload"
  rm -f "$RD4/scripts"/*.ran "$WTD/scripts"/*.ran
  rc=0
  (cd "$NONGIT" && env -u CLAUDE_PROJECT_DIR -u GIT_DIR -u GIT_WORK_TREE \
    GIT_CEILING_DIRECTORIES="$TMP" PATH="$STUB_BIN:$PATH" SYNC_DRIFT_BASE_OVERRIDE="$BASE_WT" \
    bash "$WTD/scripts/check-dev-toolkit-sync-drift.sh") >"$TMP/out.log" 2>"$TMP/err.log" || rc=$?
  if [ "$rc" -eq 0 ] \
    && /usr/bin/grep -q '^DRIFT_COUNT=1$' "$TMP/out.log" \
    && [ -f "$WTD/scripts/sync-dev-toolkit-to-public.sh.ran" ] \
    && [ ! -f "$RD4/scripts/sync-dev-toolkit-to-public.sh.ran" ]; then
    ok "check-dev-toolkit-sync-drift.sh: linked worktree では worktree 自身の一覧で数える"
  else
    bad "check-dev-toolkit-sync-drift.sh: linked worktree で親 checkout の答えを返している (rc=$rc)"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi

  # 15. checker 自身がリポジトリ外 → 非 0 + SKIP_REASON で可視化する。呼び出し元
  #     hook はこの出力を診断へ埋め込むため、無音になると原因が消える
  RD3="$TMP/driftroot-nogit"
  mkdir -p "$RD3/scripts"
  cp "$DRIFT_CHECKER" "$RD3/scripts/"
  rc=0
  (cd "$NONGIT" && env -u CLAUDE_PROJECT_DIR -u GIT_DIR -u GIT_WORK_TREE \
    GIT_CEILING_DIRECTORIES="$TMP" bash "$RD3/scripts/check-dev-toolkit-sync-drift.sh") \
    >"$TMP/out.log" 2>"$TMP/err.log" || rc=$?
  if [ "$rc" -ne 0 ] && /usr/bin/grep -q '^SKIP_REASON=' "$TMP/out.log"; then
    ok "check-dev-toolkit-sync-drift.sh: リポジトリ外配置は SKIP_REASON と非 0 で可視化する"
  else
    bad "check-dev-toolkit-sync-drift.sh: リポジトリ外配置の失敗が可視化されない (rc=$rc)"
    cat "$TMP/out.log" "$TMP/err.log" | sed 's/^/    | /' >&2
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ claude-hooks-path verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ claude-hooks-path verify: 全 $PASS 件 pass"
FF_REACHED_END=1
