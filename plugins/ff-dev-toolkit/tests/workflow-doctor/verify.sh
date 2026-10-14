#!/usr/bin/env bash
# workflow-doctor（導入先の入口規範とスキルの判定順の矛盾検査）の回帰テスト。
#
# 2 層で固定する（assess-impact の形に倣う）:
#   (A) 生成器規則のドリフト — SKILL.md の検査表に 11 項目が在り、--fix を持たない契約が書かれていること
#   (B) fixture — 「issue化必須」を含む CLAUDE.md で FAIL 1 が該当行を名指しし rc=1、直した fixture で rc=0。
#       節の欠落は WARN、必須語の欠落は FAIL、Stop hook の旧 reminder は FAIL、grep 失敗は FAIL。
#       --offline で gh を使わない（ネットワークに出ない）。
#
# 空振り検出: 強制起票の言い換えや別名のスコープ外節を入力し、検出しない旧実装では fixture 2d / 3b が赤。別のスコープ外節だけに必須語がある負対照も固定する。
# 空振り検出（Issue `#2089`）: 契約表の行が当たらない入力でも緑に倒さない — Draft / 特定 CLI の常時必須の旧文言は FAIL 8 / 9 を名指しで要求し（検査が無い旧実装では fixture 7 / 8 が赤）、否定・条件付きの文は OK を要求する。提案の根拠が 0 件の入力では「提案なし」の 1 行を要求し（空の提案節は 10c が赤）、gh が失敗した Draft 一覧は SKIP 11 を要求する（0 件の OK に畳む実装は 11 が赤）。
# 空振り検出（Issue `#2111`）: 検査 9 の除外は 1 つずつ効きを固定する — 8b は 1 行が新しい除外 1 つだけに当たり、除外を 1 つ外した変異（exempt の在れば / 有れば、strip の `@` 必須）はそれぞれ対応する行だけが FAIL 9 になって 8b が赤（実測）。逆に除外を広げた変異（素の「のみ」/ `@` 単体を exempt へ / `@` 注記を strip ではなく exempt へ）は 8c が赤（実測）。
# 空振り検出（Issue `#2101`）: strip のリダイレクト注記（`</dev/null` が必須）を外した変異は 8d の 1 本目が FAIL 9 になって赤、先頭文字の制限を外して英字始まりの code span まで消す変異（「`codex` 必須」を消す）は 8c と 8d の 2 本目が赤、助詞の `(が|は|を)?` を素の `が?` へ戻す変異は 8d の 1 本目の助詞の無い行と「は必須」の行が LC_ALL=C で strip されず赤、span の空白禁止を外す変異（`[^`[:space:]]*` を `[^`]*` へ）は 8d の 2 本目 3 行目（「`< /dev/null codex exec review` 必須」）が赤、半角スペースだけの禁止へ狭める変異（`[^` ]*`）は 8d のタブ区切りの行が赤（実測）。
#
# 変異検出（2026-10-02）: 追加語族の除去で 2d / 4c が赤。見出しを旧名限定へ戻すと 3b が赤、次のスコープ外節を連結すると 3c が赤。
#
# 変異検出（2026-09-16 実測。赤転しなかった変異は無し）:
#   OLD_PATTERN から `|口にした時点で.*起票` を落とす → fixture 2b（第 3 選択肢だけの旧文言）が赤
#   hook 検査の `! grep -q 'YAGNI'` を外す → fixture 4b（即起票の語を残しつつ YAGNI を持つ reminder）が誤って FAIL になり赤
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/scripts/workflow-doctor.sh"
SKILL="$PLUGIN_ROOT/skills/workflow-doctor/SKILL.md"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

[ -f "$TARGET" ] || { echo "✗ workflow-doctor.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$SKILL" ] || { echo "✗ SKILL.md が見つかりません: $SKILL" >&2; exit 1; }

if _t="$(mktemp -d "${TMPDIR:-/tmp}/ff-workflow-doctor.XXXXXX" 2>&1)" && [ -d "$_t" ]; then
  TEST_TMP="$_t"
else
  echo "✗ 一時ディレクトリを作成できません: $_t" >&2; exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ workflow-doctor: 最後まで到達しませんでした" >&2; rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

# ---- (A) SKILL.md の生成器規則 ---------------------------------------------------
for needle in "| 1 | 判定順の矛盾" "| 2 | 節の必須語" "| 3 | hook の文言" "| 4 | 起票の受け皿" "| 5 | ラベルの実在" "| 6 | 親無し Issue" "| 7 | 環境変数" "| 8 | Draft PR" "| 9 | レビュー担当" "| 10 | 入口のパリティ" "| 11 | Draft の実態"; do
  if grep -qF "$needle" "$SKILL"; then ok "SKILL.md の検査表に「${needle#| }」がある"; else bad "SKILL.md の検査表に「${needle#| }」が無い"; fi
done
# shellcheck disable=SC2016  # バッククォートを含む固定文字列（展開しないのが正）
if grep -qF -- '`--fix` は**意図的に持たない**' "$SKILL"; then ok "SKILL.md が --fix を持たない契約を書いている"; else bad "SKILL.md に --fix を持たない契約が無い"; fi
if grep -qF 'scripts/workflow-doctor.sh' "$SKILL"; then ok "SKILL.md が同梱スクリプトを名指ししている"; else bad "SKILL.md が同梱スクリプトを名指ししていない"; fi

# ---- (B) fixture ------------------------------------------------------------------
GOOD_CLAUDE='# CLAUDE.md

## Git Workflow

1. 着手前

## スコープ外の発見

1. YAGNI: 追跡しない
2. 同 PR インライン
3. 既存 bundle へ追記
4. 新規は bundle 単位のみ

## 次の節

無関係な本文'

make_root() { # $1 name, $2 CLAUDE.md body, $3 (optional) AGENTS.md body
  local dir="$TEST_TMP/$1"
  mkdir -p "$dir/.claude"
  printf '%s\n' "$2" > "$dir/CLAUDE.md"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$dir/AGENTS.md"
  printf '{}\n' > "$dir/.claude/settings.json"
  echo "$dir"
}
NOGLOBAL="$TEST_TMP/no-global-CLAUDE.md"   # 存在しないパスを渡し、実機のグローバル CLAUDE.md を読まない

# handoff env（FF_DEV_TOOLKIT_ROOT 等）は中和して呼ぶ。継承したままだと、消えた root を指す handoff で
# script 側 root ガードが先に exit 2 を返し、引数解決の rc=2 検査がガード経由で「成立」する（レビューで実測）。
DOCTOR=(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE bash "$TARGET")
run_doctor() { # $1 root, rest: extra args
  local root="$1"; shift
  "${DOCTOR[@]}" --root "$root" --global-claude "$NOGLOBAL" --settings "$root/.claude/settings.json" --offline "$@" 2>&1
}

# 1. 良い状態 → rc=0、SUMMARY fail=0
d="$(make_root good "$GOOD_CLAUDE")"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^SUMMARY fail=0 ' <<<"$out"; then ok "良い状態 → rc=0 / fail=0"; else bad "良い状態で rc=${rc}: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi

# 2. 旧文言（issue化必須）→ rc=1 で FAIL 1 が該当行（path:line）を名指し、FIXTEXT が出る
d="$(make_root old "$GOOD_CLAUDE
- スコープ外の発見はissue化必須")"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t1\t.*CLAUDE\\.md:[0-9]+:.*issue化必須' <<<"$out"; then ok "旧文言 → rc=1 / FAIL 1 が行を名指し"; else bad "旧文言を検知できない（rc=${rc}）"; fi
if grep -q $'^FIXTEXT\t1\t' <<<"$out"; then ok "旧文言の FIXTEXT（置換案）が出る"; else bad "FIXTEXT が出ない"; fi

# 2b. 第 3 選択肢（口にした時点で…起票）だけに当たる旧文言（AGENTS.md 側）→ FAIL 1
d="$(make_root third "$GOOD_CLAUDE" '# AGENTS.md
別 Issue 化を口にした時点で、同じ turn 内で起票し、番号を残す。')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t1\t.*AGENTS\\.md:[0-9]+:' <<<"$out"; then ok "第 3 選択肢だけの旧文言（AGENTS.md）→ FAIL 1"; else bad "第 3 選択肢の旧文言を検知できない（rc=${rc}）"; fi

# 2c. グローバル CLAUDE.md 側の旧文言（デフォルトは即 Issue 起票）→ FAIL 1
d="$(make_root global "$GOOD_CLAUDE")"
printf '%s\n' '# global' '- **スコープ外**: デフォルトは即 Issue 起票' > "$TEST_TMP/global-old.md"
out="$("${DOCTOR[@]}" --root "$d" --global-claude "$TEST_TMP/global-old.md" --settings "$d/.claude/settings.json" --offline 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t1\t.*global-old\\.md:[0-9]+:' <<<"$out"; then ok "グローバル CLAUDE.md の旧文言 → FAIL 1"; else bad "グローバル側の旧文言を検知できない（rc=${rc}）"; fi

# 2d. 実測した旧ルールの言い換えは、対象ファイルと一致行を必ず FAIL 1 へ出す。
for rule in \
  'スコープ外の問題を見つけた場合は、即座に GitHub Issue を作成する。' \
  'スコープ外は即座にGitHub Issueを作成する。' \
  'スコープ外の発見はIssue化して即続行' \
  'スコープ外の発見は Issue 化して即続行' \
  'スコープ外の発見はissue化して即続行' \
  '即座に Issue を作成する' \
  '即座にIssueを作成する' \
  '即座に GitHub Issue を起票する' \
  '即座にGitHub Issueを起票する' \
  '即座に Issue を起票する' \
  '即座にIssueを起票する' \
  '即座にGitHub issueを作成する' \
  '「別Issue」と言ったら即座に `/out-of-scope-issue` で起票する' \
  '別Issue化を口にした/書いた時点で起票する'; do
  d="$(make_root variants "$GOOD_CLAUDE" "$rule")"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t1\t.*AGENTS\\.md:1:' <<<"$out"; then
    ok "旧ルールの言い換え → FAIL 1: $rule"
  else
    bad "旧ルールの言い換えを検知できない（rc=${rc}）: $rule"
  fi
done

# 2e. 正規4段ルールと、その意味を変えないスキル呼出し文は誤検出しない。
d="$(make_root positive "$GOOD_CLAUDE" 'YAGNI → 同 PR インライン → 既存 bundle へ追記 → bundle 単位で新規起票。
判定は /out-of-scope-issue を通し、必要と判断した場合だけ GitHub Issue を作成する。
即座に起票せず、YAGNI → インライン → bundle 追記 → bundle 単位で Issue を起票。
Critical は即座に修正し、前提を覆す指摘は別 Issue を作成して切り出す。')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q $'^OK\t1\t' <<<"$out"; then ok "正規4段と条件付き起票 → OK 1"; else bad "正規4段を旧ルールとして誤検出（rc=${rc}）"; fi

# 3. 節が無い → WARN 2（rc=0）/ 節はあるが YAGNI が無い → FAIL 2（rc=1）
d="$(make_root nosection '# CLAUDE.md

## 別の節

YAGNI bundle')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q $'^WARN\t2\t.*節が無い' <<<"$out"; then ok "節が無い → WARN 2（rc=0）"; else bad "節の欠落が WARN にならない（rc=${rc}）"; fi
d="$(make_root noyagni "$(printf '%s\n' "$GOOD_CLAUDE" | sed 's/YAGNI: 追跡しない/追跡しない/')")"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t2\t.*YAGNI が無い' <<<"$out"; then ok "節から YAGNI が消えた → FAIL 2"; else bad "YAGNI の欠落を検知できない（rc=${rc}）"; fi

# 3b. 別見出しでも必須語を検査し、後続節の語では欠落を埋めない。
for heading in '## スコープ外問題の取り扱い' '## スコープ外の発見と対応'; do
  d="$(make_root aliases "$heading
必須語のない旧節
## 後続節
YAGNI bundle")"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t2\t.*YAGNI が無い' <<<"$out" && grep -q $'^FAIL\t2\t.*bundle が無い' <<<"$out"; then
    ok "別見出しの欠落 → FAIL 2: $heading"
  else
    bad "別見出しを未導入と誤判定、または後続節で補完（rc=${rc}）: $heading"
  fi
  d="$(make_root aliases-good "${GOOD_CLAUDE/## スコープ外の発見/$heading}")"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q $'^OK\t2\t.*bundle あり' <<<"$out"; then ok "別見出しの正規4段 → OK 2: $heading"; else bad "別見出しの正規4段を検査できない（rc=${rc}）"; fi
done

# 3c. 次の節もスコープ外見出しでも、先行節の欠落をその語で埋めない。
d="$(make_root two-sections '## スコープ外の発見
必須語なし
## スコープ外問題の取り扱い
YAGNI bundle')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t2\t.*YAGNI が無い' <<<"$out" && grep -q $'^FAIL\t2\t.*bundle が無い' <<<"$out"; then ok "次のスコープ外節で先行欠落を埋めない → FAIL 2"; else bad "スコープ外の2節を連結して欠落を補完（rc=${rc}）"; fi

# 4. Stop hook の reminder が旧形（即起票だけで YAGNI 無し）→ FAIL 3 / YAGNI を持つ reminder → OK 3
d="$(make_root hook "$GOOD_CLAUDE")"
mkdir -p "$d/hooks"
printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP3 それ以外 → gh issue create で即起票"' > "$d/hooks/guard.py"
# JSON は jq -n で作る（printf の書式内 `\"` は bash 3.2 で `"` に落ちて JSON が壊れ、「解釈できない」の FAIL 3 で
# テストが空回りする — レビューで実測）。fixture が有効 JSON であることも jq -e で確かめる
hook_settings() { # $1 command string, $2 dest
  jq -n --arg c "$1" '{hooks:{Stop:[{hooks:[{type:"command",command:$c}]}]}}' > "$2" && jq -e . "$2" > /dev/null
}
if command -v jq >/dev/null 2>&1; then
  hook_settings "python3 \"$d/hooks/guard.py\"" "$d/.claude/settings.json" || bad "fixture の settings.json が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*'"$d/hooks/guard.py" <<<"$out"; then ok "Stop hook の旧 reminder → FAIL 3（解決済みパスを名指し）"; else bad "hook の旧 reminder を検知できない（rc=${rc} / $(printf '%s' "$out" | grep -E $'\t3\t' | head -1)）"; fi
  # 「即起票」の語を STEP4 に残しつつ YAGNI を持つ reminder（4 段の reminder は STEP4 で bundle 単位の即起票を言う）。
  # `! grep -q 'YAGNI'` を外す変異はこの fixture を FAIL 3 に倒す（語の共存で否定条件の有無を固定する）。
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP1 YAGNI → 対応も Issue も作らない / STEP3 既存 bundle へ追記 / STEP4 bundle 単位で即起票"' > "$d/hooks/guard.py"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q $'^OK\t3\t' <<<"$out"; then ok "YAGNI を持つ reminder（即起票の語つき）→ OK 3"; else bad "新しい reminder が誤って FAIL になる（rc=${rc}）"; fi
else
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 x.py"}]}]}}' > "$d/.claude/settings.json"
  out="$(run_doctor "$d")"; rc=$?
  if grep -q $'^SKIP\t3\t' <<<"$out"; then ok "jq 不在では hook 検査が SKIP（緑にしない）"; else bad "jq 不在で hook 検査が SKIP にならない"; fi
  ok "（jq 不在のため hook の正例は未検証 — 件数合わせ）"
fi

# 4c. 追加した語族は Stop hook の inline / script のどちらにも届く。
if command -v jq >/dev/null 2>&1; then
  d="$(make_root hook-variants "$GOOD_CLAUDE")"
  mkdir -p "$d/hooks"
  for rule in '即座に GitHub Issue を作成する' 'スコープ外の発見はIssue化して即続行'; do
    hook_settings "echo $rule" "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
    out="$(run_doctor "$d")"; rc=$?
    if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*command 文字列' <<<"$out"; then ok "追加語族の inline hook → FAIL 3: $rule"; else bad "追加語族が inline hook に届かない（rc=${rc}）"; fi
    printf '%s\n' '#!/usr/bin/env bash' "# $rule" > "$d/hooks/guard.sh"
    hook_settings "bash $d/hooks/guard.sh" "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
    out="$(run_doctor "$d")"; rc=$?
    if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*'"$d/hooks/guard.sh" <<<"$out"; then ok "追加語族の script hook → FAIL 3: $rule"; else bad "追加語族が script hook に届かない（rc=${rc}）"; fi
  done
else
  printf '%s\n' '  ○ jq 不在のため追加語族の hook 検査は未検証'
fi

# 5. --offline の 4〜6・11 は SKIP として数える（緑にしない）。jq 不在の環境では検査 3 も SKIP になるので期待値を 1 足す
d="$(make_root offline "$GOOD_CLAUDE")"
out="$(run_doctor "$d")"
if command -v jq >/dev/null 2>&1; then want_skip=4; else want_skip=5; fi
if grep -q "^SUMMARY fail=0 warn=0 skip=${want_skip}\$" <<<"$out"; then ok "--offline で 4〜6・11 が SKIP ${want_skip} 件として数えられる"; else bad "--offline の SKIP 計上が違う: $(printf '%s' "$out" | tail -1)"; fi

# 5b. settings.json が壊れている（末尾カンマ）→ FAIL 3（jq の失敗を「設定は無い」に畳まない）
if command -v jq >/dev/null 2>&1; then
  d="$(make_root badjson "$GOOD_CLAUDE")"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 x.py"},]}]}}' > "$d/.claude/settings.json"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*解釈できない' <<<"$out"; then ok "壊れた settings.json → FAIL 3（fail-closed）"; else bad "壊れた settings.json が FAIL にならない（rc=${rc}）"; fi
else
  ok "（jq 不在のため settings.json 破損の検査は未検証 — 件数合わせ）"
fi

# 5c. settings.local.json（既定対象）にだけ旧 reminder の hook がある → FAIL 3。既定対象を使うため --settings を渡さず、
#     グローバル側は CLAUDE_CONFIG_DIR を空の一時ディレクトリへ向けて読まない
if command -v jq >/dev/null 2>&1; then
  d="$(make_root localjson "$GOOD_CLAUDE")"
  mkdir -p "$d/hooks" "$TEST_TMP/cfg"
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP3 それ以外 → gh issue create で即起票"' > "$d/hooks/guard.py"
  hook_settings 'python3 "$CLAUDE_PROJECT_DIR/hooks/guard.py"' "$d/.claude/settings.local.json" || bad "fixture の settings.local.json が有効 JSON にならない"
  out="$(CLAUDE_CONFIG_DIR="$TEST_TMP/cfg" "${DOCTOR[@]}" --root "$d" --global-claude "$NOGLOBAL" --offline 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*'"$d/hooks/guard.py" <<<"$out"; then ok "settings.local.json の旧 reminder（\$CLAUDE_PROJECT_DIR を root へ展開）→ FAIL 3"; else bad "settings.local.json を既定で見ていない / 展開が違う（rc=${rc} / $(printf '%s' "$out" | grep -E $'\t3\t' | head -1 | cut -c1-120)）"; fi
  # 5d. inline の command 文字列に旧文言 → FAIL 3 / YAGNI を持つ inline は OK（スクリプト側と同じ連言）
  d="$(make_root inlinecmd "$GOOD_CLAUDE")"
  hook_settings 'echo 別 Issue 化を口にした時点で必ず起票する' "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*command 文字列' <<<"$out"; then ok "inline command の旧文言 → FAIL 3"; else bad "inline command の旧文言を検知できない（rc=${rc}）"; fi
  hook_settings 'echo STEP1 YAGNI なら起票しない / STEP4 bundle 単位で即起票' "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q $'^FAIL\t3\t' <<<"$out"; then ok "YAGNI を持つ inline command → FAIL にしない"; else bad "YAGNI を持つ inline command が誤って FAIL になる（rc=${rc}）"; fi
  # 5f. YAGNI は持つが STEP3 が「gh issue create で即起票」のままで bundle が無い → FAIL 3（スクリプト本文 / inline の両方で同じ判定）
  d="$(make_root elifpath "$GOOD_CLAUDE")"
  mkdir -p "$d/hooks"
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP1 YAGNI 違反 → 黙る / STEP3 それ以外 → gh issue create で即起票"' > "$d/hooks/guard.py"
  hook_settings "python3 \"$d/hooks/guard.py\"" "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*bundle への追記が無い' <<<"$out"; then ok "YAGNI ありでも STEP3 が即起票のまま（bundle 無し）→ FAIL 3（スクリプト）"; else bad "elif 経路（bundle 無し）を検知できない（rc=${rc}）"; fi
  hook_settings 'echo STEP1 YAGNI 違反 → 黙る / STEP3 それ以外 → gh issue create で即起票' "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*bundle への追記が無い' <<<"$out"; then ok "同じ reminder を inline に置いても FAIL 3（配置で判定が変わらない）"; else bad "inline の elif 経路を検知できない（rc=${rc}）"; fi
  # 5g. スクリプト本文に検査 1 と同じ語族（issue化必須）→ FAIL 3（ファイル側の検査語を狭めない）
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "スコープ外の発見はissue化必須"' > "$d/hooks/guard.py"
  hook_settings "python3 \"$d/hooks/guard.py\"" "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*旧文言' <<<"$out"; then ok "スクリプト本文の issue化必須 → FAIL 3（検査 1 と同じ語族）"; else bad "スクリプト側の検査語が狭い（rc=${rc}）"; fi
  # 5e. command に 2 本のスクリプトがあり、2 本目だけ旧 reminder → FAIL 3（先頭 1 本だけを見ない）
  d="$(make_root twopaths "$GOOD_CLAUDE")"
  mkdir -p "$d/hooks"
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP1 YAGNI / STEP4 bundle"' > "$d/hooks/a.py"
  printf '%s\n' '#!/usr/bin/env python3' 'reason = "STEP3 それ以外 → gh issue create で即起票"' > "$d/hooks/b.py"
  hook_settings "python3 \"$d/hooks/a.py\" && python3 \"$d/hooks/b.py\"" "$d/.claude/settings.json" || bad "fixture が有効 JSON にならない"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t3\t.*'"$d/hooks/b.py" <<<"$out"; then ok "command 内の 2 本目のスクリプトの旧 reminder → FAIL 3"; else bad "2 本目のスクリプトを見ていない（rc=${rc}）"; fi
else
  ok "（jq 不在のため settings.local.json の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため inline command の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため YAGNI つき inline の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため 2 本目のスクリプトの検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため elif 経路 2 件の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため elif 経路 2 件の検査は未検証 — 件数合わせ）"
  ok "（jq 不在のため issue化必須 の検査は未検証 — 件数合わせ）"
fi

# 7. 検査 8（Draft PR の旧文言）: 作る指示は FAIL 8 + FIXTEXT、否定・廃止を述べる行は OK 8
for rule in \
  'PR は Draft PR で作成し、レビュー後に Ready にする' \
  'PR はドラフトPRで作る' \
  'gh pr create --draft --base develop' \
  'gh pr create -d --fill' \
  'gh pr ready 12 --undo' \
  'Push and open it as a draft PR.' \
  'PR はドラフト PR として出す'; do
  d="$(make_root draft "$GOOD_CLAUDE" "$rule")"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t8\t.*AGENTS\\.md:1:' <<<"$out" && grep -q $'^FIXTEXT\t8\t.*gh pr ready' <<<"$out"; then
    ok "Draft の旧文言 → FAIL 8 + FIXTEXT: $rule"
  else
    bad "Draft の旧文言を検知できない（rc=${rc}）: $rule"
  fi
done
d="$(make_root draft-ok "$GOOD_CLAUDE" 'PR は通常 PR として作る（Draft にしない。gh pr create に --draft を付けない）。
DraftPR をやめて通常 PR にした。')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q $'^OK\t8\t' <<<"$out"; then ok "Draft の否定・廃止の文 → OK 8（誤検出しない）"; else bad "Draft の否定文を旧文言として誤検出（rc=${rc}）"; fi

# 8. 検査 9（レビュー担当）: 特定 CLI の常時必須は FAIL 9、条件付きは OK 9
d="$(make_root review-cli "$GOOD_CLAUDE")"
printf '%s\n' '# global' '4. **Self-Review with PR Review Toolkit + Codex CLI (MANDATORY before PR)**' > "$TEST_TMP/global-review.md"
out="$("${DOCTOR[@]}" --root "$d" --global-claude "$TEST_TMP/global-review.md" --settings "$d/.claude/settings.json" --offline 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t9\t.*global-review\\.md:2:' <<<"$out" && grep -q $'^FIXTEXT\t9\t.*self-review\\.md' <<<"$out"; then ok "特定 CLI のレビューを常時必須 → FAIL 9 + FIXTEXT"; else bad "特定 CLI の常時必須を検知できない（rc=${rc}）"; fi
d="$(make_root review-cond "$GOOD_CLAUDE" 'セルフレビューは主担当が行い、Codex が使えるときだけクロスレビューを足す（必須にしない）。
Codex は必須ではない（optional）。
Codex CLI のインストールは必須（/opt/homebrew/bin/codex）。')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q $'^OK\t9\t旧文言' <<<"$out"; then ok "条件付きのクロスレビュー・レビュー以外の必須 → OK 9（誤検出しない）"; else bad "条件付きのクロスレビューかレビュー以外の必須を誤検出（rc=${rc}）"; fi
# 8b. 現行契約どおりの文言（グローバル CLAUDE.md で実測した形）: 漢字表記の「在れば / 有れば」（exempt）と、
#     `@` 記号への「必須」の注記（strip で注記だけを消す）は、特定 CLI の常時必須ではない → OK 9。
#     1 行が新しい除外の 1 つだけに当たるように書く（除外を 1 つ外すと、その行だけが FAIL 9 になる）
d="$(make_root review-current "$GOOD_CLAUDE" '- **ALWAYS** 主担当がセルフレビューし、別モデル CLI（Codex 等）が在れば 1 本加える
- Grok が有れば必ずクロスレビューを 1 本足す
- 課金を許容する場合 / Codex が未応答の場合に、`gh pr edit {PR} --add-reviewer @copilot` で依頼する（`@` 必須）
gh pr edit {PR} --add-reviewer @copilot   # @ 必須。なしは解決に失敗')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q $'^OK\t9\t旧文言' <<<"$out"; then ok "在れば・有れば・@ への必須の注記 → OK 9（誤検出しない）"; else bad "現行契約どおりの文言を誤検出（rc=${rc}）: $(grep -E $'^FAIL\t9\t' <<<"$out" | head -4 | tr '\n' ' ')"; fi
# 8c. 除外を広げても本物の常時必須は落とさない: 素の「のみ」、@ の後に CLI 名が続く「@codex 必須」、
#     `@` 注記と同じ行に並ぶ本物の常時必須（注記を行ごと除外すると隠れる形）は FAIL 9 のまま
d="$(make_root review-near "$GOOD_CLAUDE" 'PR 作成前のみ Codex レビュー必須
レビューは `@codex` 必須
Copilot レビューは必須。`gh pr edit {PR} --add-reviewer @copilot` で依頼する（`@` 必須）')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t9\t.*AGENTS\\.md:1:' <<<"$out" && grep -qE $'^FAIL\t9\t.*AGENTS\\.md:2:' <<<"$out" && grep -qE $'^FAIL\t9\t.*AGENTS\\.md:3:' <<<"$out"; then ok "前のみ・@codex 必須・@ 注記と同じ行の本物 → FAIL 9 のまま（除外が本物を飲み込まない）"; else bad "近い形の常時必須を見逃す（rc=${rc}）: $(grep -E $'\t9\t' <<<"$out" | head -4 | tr '\n' ' ')"; fi
# 8d. シェルのリダイレクトへの「必須」の注記（導入先の CLAUDE.md で実測した形）: CLI 名・レビューの語・「必須」が
#     同じ行に在るが、「必須」は `</dev/null`（stdin の扱い）にかかる → strip で注記だけを消して OK 9。
#     2 行目は助詞の無い形（「`</dev/null` 必須」）— 検査は LC_ALL=C で走るので、素の `が?` だと多バイトの
#     最後の 1 バイトだけが省略可能になり strip が効かない（`(が)?` と括る実装だけが通る）。
#     同じ注記と並ぶ本物の常時必須（「Codex レビューは必須（stdin は `</dev/null` が必須）」）、英字で始まる code span、
#     リダイレクトで始まるが空白（スペース / タブ）を含む（コマンド全体の）code span への必須は FAIL 9 のまま
d="$(make_root review-redirect "$GOOD_CLAUDE" '> **素の `codex exec` を自分で組み立てないこと。** 同期・フォアグラウンドで呼ぶと、stdin が TTY でない場合に codex が追加入力を待ち、ハングと区別がつかなくなる（その場合は `</dev/null` が必須）。`codex-parallel-review.sh` は各呼び出しを `&` でバックグラウンド起動する
codex のレビュー結果を同期で読むときは stdin に `</dev/null` 必須
codex-review.sh を同期で呼ぶなら stdin には `</dev/null` は必須')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q $'^OK\t9\t旧文言' <<<"$out"; then ok "リダイレクトへの必須の注記（codex exec の stdin） → OK 9（誤検出しない）"; else bad "リダイレクトへの必須の注記を誤検出（rc=${rc}）: $(grep -E $'^FAIL\t9\t' <<<"$out" | head -2 | tr '\n' ' ')"; fi
d="$(make_root review-redirect-real "$GOOD_CLAUDE" 'Codex レビューは必須（stdin は `</dev/null` が必須）
レビューは `codex` 必須
レビューは `< /dev/null codex exec review` 必須')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t9\t.*AGENTS\\.md:1:' <<<"$out" && grep -qE $'^FAIL\t9\t.*AGENTS\\.md:2:' <<<"$out" && grep -qE $'^FAIL\t9\t.*AGENTS\\.md:3:' <<<"$out"; then ok "リダイレクト注記と同じ行の本物・英字で始まる code span・空白を含むコマンド全体の必須 → FAIL 9 のまま"; else bad "リダイレクト注記の除外が本物を飲み込む（rc=${rc}）: $(grep -E $'\t9\t' <<<"$out" | head -4 | tr '\n' ' ')"; fi
# 同じコマンド全体の必須指定で、区切りがタブの形（半角スペースだけを禁止する実装はすり抜ける。クロスレビュー指摘）
printf 'レビューは `<\t/dev/null\tcodex\texec\treview` 必須\n' > "$d/AGENTS.md"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t9\t.*AGENTS\\.md:1:' <<<"$out"; then ok "タブ区切りのコマンド全体の必須 → FAIL 9 のまま（空白禁止はタブも含む）"; else bad "タブ区切りのコマンド全体の必須指定を strip が飲み込む（rc=${rc}）: $(grep -E $'\t9\t' <<<"$out" | head -2 | tr '\n' ' ')"; fi

# 9. 検査 9 (b) と提案: レビュー用 npm script が package.json に無い → FAIL 9 + そのリポジトリの入口を挙げた SUGGEST 9
d="$(make_root npm-missing "$GOOD_CLAUDE" '- クロスレビューは npm run code-review:codex -- --base develop で起動する
- 判定ロジックは npm run code-review:test で検証する')"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE $'^FAIL\t9\t.*npm run code-review:codex .*package\\.json が無い' <<<"$out"; then ok "package.json が無い → FAIL 9（npm run code-review:codex）/ rc=1"; else bad "存在しない npm script を検知できない（rc=${rc}）"; fi
if grep -qE $'^SUGGEST\t9\t.*/multi-review.*\t根拠: .*npm run code-review:codex.*multi-agent\\.sh が在る' <<<"$out"; then ok "SUGGEST 9 が /multi-review を根拠付きで挙げる"; else bad "SUGGEST 9 が出ない / 根拠が無い: $(grep '^SUGGEST' <<<"$out" | head -2)"; fi
if ! grep -qE $'^SUGGEST\t9\t.*code-review:test' <<<"$out"; then ok "検査用 script（code-review:test）には代わりの起動口を提案しない"; else bad "検査用 script に起動口を提案している"; fi
mkdir -p "$d/scripts"; printf '#!/usr/bin/env bash\n' > "$d/scripts/codex-review.sh"
out="$(run_doctor "$d")"
if grep -qE $'^SUGGEST\t9\t.*bash scripts/codex-review\\.sh' <<<"$out"; then ok "リポジトリに scripts/codex-review.sh が在る → そちらを提案する"; else bad "リポジトリ固有の入口を提案しない: $(grep '^SUGGEST' <<<"$out" | head -1)"; fi
d="$(make_root npm-cond "$GOOD_CLAUDE" '- package.json に code-review:codex があるリポジトリは npm run code-review:codex、無ければ /multi-review')"
out="$(run_doctor "$d")"
if grep -q $'^INFO\t9\t条件付き.* 1 行は数えない' <<<"$out" && ! grep -q $'^WARN\t9\t' <<<"$out" && ! grep -q $'^SUGGEST\t9\t' <<<"$out"; then ok "同じ行に条件を書いた参照 → INFO 9（WARN・提案にしない）"; else bad "条件付きの参照を WARN にしている: $(grep -E $'\t9\t' <<<"$out" | tr '\n' ' ')"; fi
d="$(make_root npm-present "$GOOD_CLAUDE" 'クロスレビューは npm run code-review:codex で起動する')"
printf '%s\n' '{"scripts":{"code-review:codex":"bash scripts/codex-review.sh"}}' > "$d/package.json"
out="$(run_doctor "$d")"
if grep -q $'^OK\t9\tnpm run code-review:codex は package.json に在る' <<<"$out" && ! grep -q $'^SUGGEST\t9\t' <<<"$out"; then ok "package.json に在る script → OK 9 / 提案なし"; else bad "実在する script を誤って FAIL / 提案（$(grep -E $'\t9\t' <<<"$out" | head -2 | tr '\n' ' ')）"; fi
printf '%s\n' '{"scripts":{"build":"tsc"}}' > "$d/package.json"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t9\t.*scripts に code-review:codex が無い' <<<"$out"; then ok "package.json はあるが script が無い → FAIL 9（scripts に無い）"; else bad "scripts に無い script を検知できない（rc=${rc}）: $(grep -E $'\t9\t' <<<"$out" | tr '\n' ' ')"; fi
if command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"scripts":{"code-review:codex":"x"},}' > "$d/package.json"
  out="$(run_doctor "$d")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q $'^FAIL\t9\t.*解析できない' <<<"$out" && ! grep -q 'が無い' <<<"$(grep -E $'\t9\t' <<<"$out")" && ! grep -q $'^SUGGEST\t9\t' <<<"$out"; then ok "壊れた package.json → FAIL 9（解析できない。「script が無い」と提案にしない）"; else bad "壊れた package.json を「script が無い」に畳んでいる（rc=${rc}）: $(grep -E $'\t9\t' <<<"$out" | tr '\n' ' ')"; fi
else
  ok "（jq 不在のため壊れた package.json の検査は未検証 — 件数合わせ）"
fi

# 10. 検査 10（入口のパリティ）: AGENTS.md にだけ契約語が無い → WARN 10
d="$(make_root parity "$GOOD_CLAUDE" '# AGENTS.md
スコープ外は bundle へ追記する。')"
out="$(run_doctor "$d")"
if grep -q $'^WARN\t10\tYAGNI が CLAUDE.md にだけ在る' <<<"$out" && grep -q $'^OK\t10\t.*bundle の有無が揃っている' <<<"$out"; then ok "YAGNI が CLAUDE.md にだけ在る → WARN 10（bundle は OK 10）"; else bad "入口のパリティずれを検知できない: $(grep -E $'\t10\t' <<<"$out" | tr '\n' ' ')"; fi

# 10b. AGENTS.md が無く、PATH に codex が在る → SUGGEST 10（PATH 上の実在パスを根拠に出す）
mkdir -p "$TEST_TMP/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/fakebin/codex"; chmod +x "$TEST_TMP/fakebin/codex"
d="$(make_root no-agents "$GOOD_CLAUDE")"
out="$(PATH="$TEST_TMP/fakebin:$PATH" run_doctor "$d")"
s10="$(grep -E $'^SUGGEST\t10\tAGENTS\\.md を置き' <<<"$out")"
if grep -qF "根拠: PATH に codex(${TEST_TMP}/fakebin/codex)" <<<"$s10"; then ok "AGENTS.md が無く codex が在る → SUGGEST 10（PATH の実在を根拠に）"; else bad "AGENTS.md の追加を提案しない: $(grep '^SUGGEST' <<<"$out" | head -1)"; fi

# 10b'. CLAUDE.md が無く AGENTS.md だけ、PATH に claude が在る → SUGGEST 10（CLAUDE.md の追加）
printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/fakebin/claude"; chmod +x "$TEST_TMP/fakebin/claude"
d="$TEST_TMP/agents-only"; mkdir -p "$d/.claude"; printf '{}\n' > "$d/.claude/settings.json"; printf '%s\n' "$GOOD_CLAUDE" > "$d/AGENTS.md"
out="$(PATH="$TEST_TMP/fakebin:$PATH" run_doctor "$d")"
s10="$(grep -E $'^SUGGEST\t10\tCLAUDE\\.md を置き' <<<"$out")"
if grep -q $'^INFO\t10\tCLAUDE\\.md が無い' <<<"$out" && grep -qF "根拠: PATH に claude(${TEST_TMP}/fakebin/claude)" <<<"$s10"; then ok "AGENTS.md だけで claude が在る → INFO 10 + SUGGEST 10（CLAUDE.md の追加）"; else bad "CLAUDE.md の追加を提案しない: $(grep -E $'\t10\t' <<<"$out" | tr '\n' ' ')"; fi

# 10c. 根拠となる実測が無い → 「提案なし」を明示する（空の提案節で緑に見せない）。CLAUDE.md / AGENTS.md を揃えて検査 10 の提案を出さない
d="$(make_root nosuggest "$GOOD_CLAUDE" "$GOOD_CLAUDE")"
out="$(run_doctor "$d")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q $'^SUGGEST\t-\t提案なし（根拠となる実測なし）$' <<<"$out" && [ "$(grep -c '^SUGGEST' <<<"$out")" -eq 1 ]; then ok "提案の根拠が無い → 「提案なし」を 1 行だけ明示"; else bad "提案なしを明示しない / 余分な提案（rc=${rc}）: $(grep '^SUGGEST' <<<"$out" | tr '\n' ' ')"; fi
if [ "$(tail -1 <<<"$out" | cut -c1-8)" = "SUMMARY " ]; then ok "SUGGEST は SUMMARY の前に出る（SUMMARY が最終行）"; else bad "SUMMARY が最終行でない"; fi

# 11. 検査 11（Draft PR の実態）: gh のスタブで Draft 一覧を返す。knowledge: の ACE PR は数えない
mkdir -p "$TEST_TMP/ghbin"
cat > "$TEST_TMP/ghbin/gh" <<'STUB'
#!/bin/sh
# --jq を解釈しないスタブ: doctor の各呼び出しへ jq 適用後の出力を直接返す
case "$*" in
  *"pr list"*"--draft"*) [ -n "${GH_STUB_FAIL:-}" ] && exit 1; [ -n "${GH_STUB_NO_DRAFT:-}" ] && exit 0; printf '12\tfeat: x\n13\tknowledge: ACE-1\n' ;;
  *"label list"*) printf 'bundle\nepic\nfollow-up\npriority:high\n' ;;
  *"issue list"*"bundle"*) printf '0\n' ;;
  *"api --paginate"*) printf '5\n7\n' ;;
  *"api graphql"*) printf '5\n7\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TEST_TMP/ghbin/gh"
d="$(make_root drafts "$GOOD_CLAUDE" "$GOOD_CLAUDE")"
out="$(PATH="$TEST_TMP/ghbin:$PATH" "${DOCTOR[@]}" --root "$d" --global-claude "$NOGLOBAL" --settings "$d/.claude/settings.json" --repo o/r 2>&1)"
if grep -q $'^WARN\t11\t.*[#]12（' <<<"$out" && ! grep -q $'^WARN\t11\t.*[#]13' <<<"$out" && grep -q $'^INFO\t11\t.*1 件は除外' <<<"$out"; then ok "Draft PR 12 → WARN 11（knowledge: の 13 は除外して INFO）"; else bad "Draft の実態を検知できない: $(grep -E $'\t11\t' <<<"$out" | tr '\n' ' ')"; fi
if grep -qE $'^SUGGEST\t11\t.*gh pr ready.*[#]12.*\t根拠: gh pr list --draft' <<<"$out"; then ok "SUGGEST 11 が gh pr ready を根拠付きで挙げる"; else bad "SUGGEST 11 が出ない: $(grep '^SUGGEST' <<<"$out" | tr '\n' ' ')"; fi
if grep -q $'^WARN\t4\t.*bundle が 0 件' <<<"$out" && grep -qE $'^SUGGEST\t6\t.*link-sub-issues\\.sh.*\t根拠: open な bundle が 0 件 / 親無しの open Issue が 2 件' <<<"$out"; then ok "bundle 0 件 + 親無し 2 件 → SUGGEST 6（link-sub-issues.sh を根拠付きで）"; else bad "検査 4・6 の組み合わせの提案が出ない: $(grep -E $'\t(4|6)\t' <<<"$out" | tr '\n' ' ')"; fi
out="$(GH_STUB_FAIL=1 PATH="$TEST_TMP/ghbin:$PATH" "${DOCTOR[@]}" --root "$d" --global-claude "$NOGLOBAL" --settings "$d/.claude/settings.json" --repo o/r 2>&1)"
if grep -q $'^SKIP\t11\t.*取得できない' <<<"$out"; then ok "gh の失敗 → SKIP 11（Draft 0 件と断定しない）"; else bad "gh の失敗を 0 件に畳んでいる: $(grep -E $'\t11\t' <<<"$out" | tr '\n' ' ')"; fi

# 6. --root が無い → rc=2（検査不成立）。handoff env は中和済みなので、root ガードではなく引数解決で 2 が出る
out="$("${DOCTOR[@]}" --root "$TEST_TMP/does-not-exist" --offline 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q '解決できません' <<<"$out"; then ok "対象を解決できない → rc=2（引数解決の経路）"; else bad "対象が無いのに rc=${rc}（out: $(printf '%s' "$out" | tail -1 | cut -c1-100)）"; fi

# 6b. 値なしオプションが最終引数 → rc=2 で止まる（無限ループしない）。上限は perl の alarm で張る
#     （coreutils の timeout は macOS に無い。alarm 到達時は SIGALRM で rc=142）
out="$(perl -e 'alarm 5; exec @ARGV' "${DOCTOR[@]}" --root 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q '値が要ります' <<<"$out"; then ok "値なしの --root → rc=2（ハングしない）"; else bad "値なしの --root が rc=${rc}（142 なら無限ループ）"; fi

echo ""
echo "workflow-doctor: ${PASS} 件成功 / ${FAIL} 件失敗"
REACHED_END=1
[ "$FAIL" -eq 0 ]
