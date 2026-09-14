#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: 検出器（AI CLI を直接起動していないか）の fixture 検査・lexical model の境界・シム本体の静的契約（委譲先の参照・ヘルプの観点列挙）。
# 依存: 親の ${WORK} / ${SHIM} / ${DIRECT_CLI_DETECTOR} / ok / bad のみ（stub オーケストレータは使わない）。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

# ── 検出器: AI CLI を直接起動していないか ────────────────────────────────────────
#
# 走査対象は shell lexical model が command word と判定した語。コメント・通常の引数・
# 文字列リテラル・heredoc 本文の言及は実行されないため除外する。一方、quote された
# command word、eval の静的 surface、command substitution は実行文脈なので残す。
#
# **パス修飾された起動も検出する。** 初版は直前文字クラスから `/` `.` `-` を除いて
# いたため `/opt/homebrew/bin/codex exec` が原理的に不可視だった — グローバル規約が
# その絶対パス表記で codex を指しているので、最も踏みやすい形を見逃していた。
# コマンド位置（行頭・`;`・`&`・`|`・`(`・空白の直後）で、任意のディレクトリ接頭辞を
# 許して照合する。
#
# 検出するのは 5 CLI すべて。codex だけを見ていると、同じ形の別 CLI ラッパーを
# 足したときに素通りする。
#
# 限界: 変数だけを経由する動的起動（`CLI=codex; "$CLI" exec`）は静的には解決しない。
# ただし `eval "$cmd codex exec"` のように静的 CLI 語が残る eval と、`$(codex exec)` は
# 実行文脈として検出する。lexer が未閉 quote / heredoc に遭遇した場合は clean とせず rc=2。
detects_direct_cli() {
  local file="$1" rc=0
  awk -f "$DIRECT_CLI_DETECTOR" "$file" || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) echo "DETECTOR-ERROR: 走査できません: ${file} (rc=${rc})" >&2; return 2 ;;
  esac
}

expect_detector_clean() {
  local file="$1" success_message="$2" false_positive_message="$3" rc=0
  detects_direct_cli "$file" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    1) ok "$success_message" ;;
    0) bad "$false_positive_message" ;;
    *) bad "検出器: clean fixture の解析が成立しない: ${file} (rc=${rc})" ;;
  esac
}

echo "-- 検出器の自己検証（fixture） --"

mkdir -p "$WORK/fx"
if [ -f "$DIRECT_CLI_DETECTOR" ]; then
  ok "検出器: shell lexical model が同梱されている"
else
  bad "検出器: shell lexical model が見つからない: $DIRECT_CLI_DETECTOR"
fi
cat > "$WORK/fx/direct-codex.sh" <<'SH'
#!/usr/bin/env bash
# 悪い例: codex を直接叩く（stdin を閉じていないとハングする）
prompt="review this"
codex exec "$prompt" --sandbox read-only
SH
cat > "$WORK/fx/abs-path-codex.sh" <<'SH'
#!/usr/bin/env bash
/opt/homebrew/bin/codex exec "$prompt" --sandbox read-only
SH
cat > "$WORK/fx/delegating.sh" <<'SH'
#!/usr/bin/env bash
# 良い例: オーケストレータへ委譲する。codex exec という語はコメントにだけ現れる
exec bash "$ORCH/multi-agent.sh" --task review --cli codex-cli "$@"
SH

if detects_direct_cli "$WORK/fx/direct-codex.sh" >/dev/null; then
  ok "検出器: 直接 codex exec を叩く fixture を検出する"
else
  bad "検出器: 直接 codex exec を叩く fixture を見逃した（検出器が効いていないので、以降の緑は無意味）"
fi

# パス修飾形。グローバル規約は /opt/homebrew/bin/codex という表記で codex を指すので、
# これを見逃す検出器は「最も踏みやすい形だけ通す」ことになる。
if detects_direct_cli "$WORK/fx/abs-path-codex.sh" >/dev/null; then
  ok "検出器: 絶対パスでの起動も検出する"
else
  bad "検出器: 絶対パス起動を見逃した（/opt/homebrew/bin/codex exec が不可視）"
fi

# 5 CLI すべてを主張しているので 5 つとも確かめる。1 つで代表させると、
# 正規表現を codex 専用へ狭める変異が素通りする。
for _cli in codex claude gemini copilot grok; do
  case "$_cli" in
    codex) _inv="${_cli} exec \"\$p\"" ;;
    *)     _inv="${_cli} -p \"\$p\"" ;;
  esac
  printf '#!/usr/bin/env bash\n%s\n' "$_inv" > "$WORK/fx/cli-${_cli}.sh"
  if detects_direct_cli "$WORK/fx/cli-${_cli}.sh" >/dev/null; then
    ok "検出器: ${_cli} の直接起動を検出する"
  else
    bad "検出器: ${_cli} の直接起動を見逃した"
  fi
done

# フラグが先に来る形。ヘッダーのコメント自身が `codex exec -s read-only` と
# 書いているので、逆順も同じくらい自然に書かれる。
printf '#!/usr/bin/env bash\ncodex -s read-only exec "$p"\n' > "$WORK/fx/flags-first.sh"
if detects_direct_cli "$WORK/fx/flags-first.sh" >/dev/null; then
  ok "検出器: CLI 名とサブコマンドの間にオプションが挟まる形も検出する"
else
  bad '検出器: codex -s read-only exec を見逃した（フラグ順を変えるだけで回避できる）'
fi

# コメント除去がクォート内・パラメータ展開の # を切ると、**同じ行の実行部分が消えて
# 違反を見逃す**。旧実装（sed 's/#.*$//'）はこの 2 形をどちらも素通しした（実測）。
printf '%s\n' '#!/usr/bin/env bash' \
  'base="${1#--base=}"; codex exec -s read-only "review $base"' \
  > "$WORK/fx/param-expansion.sh"
if detects_direct_cli "$WORK/fx/param-expansion.sh" >/dev/null; then
  ok "検出器: パラメータ展開の # と同じ行にある直接起動を検出する"
else
  bad '検出器: ${var#pat} の後ろの直接起動を見逃した（コメント除去が実行部分まで切っている）'
fi
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "see PR 406"; claude -p "review"' \
  > "$WORK/fx/hash-in-string.sh"
if detects_direct_cli "$WORK/fx/hash-in-string.sh" >/dev/null; then
  ok "検出器: 文字列リテラル内の # と同じ行にある直接起動を検出する"
else
  bad '検出器: 文字列内の # の後ろの直接起動を見逃した'
fi

# ANSI-C クォート $'...' の中でも bash は \ エスケープを解釈する。素の '...' と同じに
# 扱うと \' で閉じたと誤認し、以降がずれて**同じ行の直接起動が消える**（実測で見逃した）。
printf '%s\n' '#!/usr/bin/env bash' \
  "x=\$'a\\'b # c'; codex exec \"\$p\"" \
  > "$WORK/fx/ansi-c-quote.sh"
if detects_direct_cli "$WORK/fx/ansi-c-quote.sh" >/dev/null; then
  ok "検出器: ANSI-C クォート内のエスケープに惑わされず直接起動を検出する"
else
  bad "検出器: \$'...' のエスケープを誤読して直接起動を見逃した"
fi

# ── lexical model: positive / negative / boundary ───────────────────────────
# 普通の引数・文字列・heredoc 本文は command word ではない。ヘルプや診断に利用例を
# 書けることを固定する一方、その直後にある本物の起動は separator 後の command word
# として検出する（文字列を行ごと捨てるだけの実装を弾く）。
cat > "$WORK/fx/non-executing-mentions.sh" <<'SH'
#!/usr/bin/env bash
echo "codex exec を直接叩かないこと"
printf '%s\n' 'claude -p は使用例の文字列'
echo codex exec is documentation text
cat <<'USAGE'
例: codex exec -s read-only "..."
例: claude -p "..."
USAGE
cat <<-TABBED
	gemini -p "..."
TABBED
bash "$ORCH" --task review
SH
expect_detector_clean "$WORK/fx/non-executing-mentions.sh" \
  "検出器: 引数・文字列・heredoc 本文の CLI 言及は誤検出しない" \
  "検出器: 引数・文字列・heredoc 本文の CLI 言及を直接起動と誤検出した"

cat > "$WORK/fx/heredoc-then-direct.sh" <<'SH'
#!/usr/bin/env bash
cat <<FIRST <<'SECOND'
codex exec は 1 個目の heredoc 本文
FIRST
claude -p は 2 個目の heredoc 本文
SECOND
gemini -p "$prompt"
SH
if detects_direct_cli "$WORK/fx/heredoc-then-direct.sh" >/dev/null; then
  ok "検出器: 複数 heredoc の本文を除外し、終端後の直接起動を検出する"
else
  bad "検出器: 複数 heredoc の境界を越えて後続の直接起動まで除外した"
fi

cat > "$WORK/fx/string-then-direct.sh" <<'SH'
#!/usr/bin/env bash
echo "codex exec は説明文字列"; codex exec "$prompt"
SH
if detects_direct_cli "$WORK/fx/string-then-direct.sh" >/dev/null; then
  ok "検出器: 文字列直後の本物の直接起動を引き続き検出する"
else
  bad "検出器: 文字列を除外した結果、その直後の直接起動まで見逃した"
fi

# quote は「常に文字列」ではない。command word 自身を quote した起動は実行される。
printf '%s\n' '#!/usr/bin/env bash' '"codex" exec "$prompt"' > "$WORK/fx/quoted-command.sh"
if detects_direct_cli "$WORK/fx/quoted-command.sh" >/dev/null; then
  ok "検出器: quote された command word の直接起動を検出する"
else
  bad "検出器: quote を一律除外して実行される command word を見逃した"
fi
printf '%s\n' '#!/usr/bin/env bash' "\$'codex' exec \"\$prompt\"" > "$WORK/fx/ansi-quoted-command.sh"
if detects_direct_cli "$WORK/fx/ansi-quoted-command.sh" >/dev/null; then
  ok "検出器: ANSI-C quote された command word の直接起動を検出する"
else
  bad "検出器: ANSI-C quote を動的文字列扱いして command word を見逃した"
fi

# prefix command の options / option values を command word と誤読して探索を止めない。
cat > "$WORK/fx/prefix-options-direct.sh" <<'SH'
#!/usr/bin/env bash
env -i codex exec "$prompt"
sudo -u root claude -p "$prompt"
time -p gemini -p "$prompt"
SH
if detects_direct_cli "$WORK/fx/prefix-options-direct.sh" >/dev/null; then
  ok "検出器: prefix command の option 後にある直接起動を検出する"
else
  bad "検出器: env/sudo/time の option を実 command と誤読して後続 CLI を見逃した"
fi

# prefix の実 command が別なら、その argv に現れる CLI 語は直接起動ではない。
cat > "$WORK/fx/prefix-safe-arguments.sh" <<'SH'
#!/usr/bin/env bash
env -i printf '%s\n' codex
sudo -u root printf '%s\n' claude
command -v gemini
SH
expect_detector_clean "$WORK/fx/prefix-safe-arguments.sh" \
  "検出器: prefix command の実 command 以降にある CLI 引数は誤検出しない" \
  "検出器: prefix command の通常引数を直接起動と誤検出した"

# eval / command substitution は quote 内でも shell code を実行する境界。静的に CLI 語が
# 見える場合は、通常の説明文字列と区別して検出する。
printf '%s\n' '#!/usr/bin/env bash' 'eval "$prefix codex exec \"$prompt\""' > "$WORK/fx/eval-direct.sh"
if detects_direct_cli "$WORK/fx/eval-direct.sh" >/dev/null; then
  ok "検出器: eval の静的 surface にある直接起動を検出する"
else
  bad "検出器: 文字列除外で eval 内の直接起動を見逃した"
fi
printf '%s\n' '#!/usr/bin/env bash' 'output="$(codex exec "$prompt")"' > "$WORK/fx/command-substitution.sh"
if detects_direct_cli "$WORK/fx/command-substitution.sh" >/dev/null; then
  ok "検出器: command substitution 内の直接起動を検出する"
else
  bad "検出器: quote 内の command substitution を説明文字列として捨てた"
fi

printf '%s\n' '#!/usr/bin/env bash' 'output=`codex exec "$prompt"`' \
  > "$WORK/fx/legacy-backtick-direct.sh"
if detects_direct_cli "$WORK/fx/legacy-backtick-direct.sh" >/dev/null; then
  ok "検出器: legacy backtick 内の直接起動を検出する"
else
  bad "検出器: legacy backtick の実行 surface を通常引数として見逃した"
fi

cat > "$WORK/fx/shell-command-surface-direct.sh" <<'SH'
#!/usr/bin/env bash
bash --noprofile -lc 'claude -p "$prompt"'
env -i /bin/sh -c 'gemini -p "$prompt"'
SH
if detects_direct_cli "$WORK/fx/shell-command-surface-direct.sh" >/dev/null; then
  ok "検出器: shell -c 内の直接起動を検出する"
else
  bad "検出器: shell -c の実行 surface を通常引数として見逃した"
fi

cat > "$WORK/fx/redirection-substitution.sh" <<'SH'
#!/usr/bin/env bash
cat >"$(codex exec "$prompt")"
cat <<< "$(claude -p "$prompt")"
SH
if detects_direct_cli "$WORK/fx/redirection-substitution.sh" >/dev/null; then
  ok "検出器: redirection target 内の command substitution 直接起動を検出する"
else
  bad "検出器: redirection target を除外して内側の command substitution まで見逃した"
fi

cat > "$WORK/fx/safe-execution-surfaces.sh" <<'SH'
#!/usr/bin/env bash
out="$(printf '%s' 'codex exec')"
eval "printf %s codex"
out=`printf '%s' 'claude -p'`
bash -c 'printf "%s\\n" gemini'
printf '%s\n' bash -c 'codex exec'
SH
expect_detector_clean "$WORK/fx/safe-execution-surfaces.sh" \
  "検出器: execution surface 内でも通常引数の CLI 言及は誤検出しない" \
  "検出器: execution surface を語の存在だけで判定して誤検出した"

# here-string は heredoc ではない。<<< の引数だけを読み飛ばし、次の行の検出を継続する。
cat > "$WORK/fx/here-string-boundary.sh" <<'SH'
#!/usr/bin/env bash
cat <<< "codex exec は入力データ"
claude -p "$prompt"
SH
if detects_direct_cli "$WORK/fx/here-string-boundary.sh" >/dev/null; then
  ok "検出器: here-string を未閉 heredoc と誤読せず後続の直接起動を検出する"
else
  bad "検出器: here-string 後を heredoc 本文扱いして直接起動を見逃した"
fi

cat > "$WORK/fx/declaration-boundaries.sh" <<'SH'
#!/usr/bin/env bash
case "$tool" in
  codex) echo selected ;;
  claude|gemini) echo another ;;
esac
codex() {
  echo mock
}
SH
expect_detector_clean "$WORK/fx/declaration-boundaries.sh" \
  "検出器: case pattern と function 宣言の CLI 名は誤検出しない" \
  "検出器: case pattern / function 宣言を直接起動と誤検出した"

# 未閉構文は「言及なし」と同じ rc=1 にしない。lexer が成立しない入力は rc=2。
printf '%s\n' '#!/usr/bin/env bash' 'echo "unterminated' > "$WORK/fx/unclosed-quote.sh"
_det_rc=0
detects_direct_cli "$WORK/fx/unclosed-quote.sh" >/dev/null 2>&1 || _det_rc=$?
if [ "$_det_rc" -eq 2 ]; then
  ok "検出器: 未閉 quote を clean とせず解析不成立で止める"
else
  bad "検出器: 未閉 quote を clean と報告した (rc=${_det_rc})"
fi

# mutation: command-position 分岐を壊すと安全な引数が赤になり、直接起動の report を消すと
# positive fixture が clean へ反転することを確認する。fixture 件数だけ増えて検出器が空洞化
# する形を防ぐ。
cp "$DIRECT_CLI_DETECTOR" "$WORK/fx/detector-command-position-broken.awk"
perl -0pi -e 's/if \(word_at_command\) \{/if (1) {/' "$WORK/fx/detector-command-position-broken.awk"
_mutation_rc=0
awk -f "$WORK/fx/detector-command-position-broken.awk" "$WORK/fx/non-executing-mentions.sh" >/dev/null 2>&1 \
  || _mutation_rc=$?
if [ "$_mutation_rc" -eq 0 ]; then
  ok "検出器 mutation: command-position 判定を壊すと非実行の CLI 言及を誤検出する"
else
  bad "検出器 mutation: command-position 判定の破壊を negative fixture が検出できない"
fi

cp "$DIRECT_CLI_DETECTOR" "$WORK/fx/detector-positive-broken.awk"
perl -0pi -e 's/if \(!word_dynamic && is_cli\(word\)\) report_hit\(\)/if (0) report_hit()/g' \
  "$WORK/fx/detector-positive-broken.awk"
_mutation_rc=0
awk -f "$WORK/fx/detector-positive-broken.awk" "$WORK/fx/direct-codex.sh" >/dev/null 2>&1 \
  || _mutation_rc=$?
if [ "$_mutation_rc" -eq 1 ]; then
  ok "検出器 mutation: direct-command report を消すと positive fixture が clean へ反転する"
else
  bad "検出器 mutation: direct-command report の空洞化を positive fixture で識別できない (rc=${_mutation_rc})"
fi

# 制御演算子の直後から始まるコメント。空白の直後だけを見ていると本文として残り、
# 中の CLI 名を誤検出して**正常なラッパーを違反として止める**（実測）。
printf '%s\n' '#!/usr/bin/env bash' \
  'bash "$ORCH" --task review;# ここで codex exec を直接叩かない' \
  > "$WORK/fx/semicolon-comment.sh"
expect_detector_clean "$WORK/fx/semicolon-comment.sh" \
  "検出器: 制御演算子直後のコメントは誤検出しない" \
  "検出器: 制御演算子直後のコメントを誤検出した（正常なラッパーを止める）"

# 逆方向: 本物のコメントは従来どおり誤検出しないこと（除去をやめただけの実装を弾く）。
printf '%s\n' '#!/usr/bin/env bash' \
  '# ここでは codex exec を直接叩かない（委譲する）' \
  'bash "$ORCH" --task review' \
  > "$WORK/fx/comment-mention.sh"
expect_detector_clean "$WORK/fx/comment-mention.sh" \
  "検出器: コメント中の言及は誤検出しない" \
  "検出器: コメント中の言及を誤検出した（コメント除去が効いていない）"

# 走査できないファイルを「clean」と同じ答えにしない（fail-closed）。
printf '#!/usr/bin/env bash\ncodex exec "$p"\n' > "$WORK/fx/unreadable.sh"
chmod 000 "$WORK/fx/unreadable.sh"
if [ -r "$WORK/fx/unreadable.sh" ]; then
  # root 実行（Claude Code cloud など）では chmod 000 でも読めるため fixture が成立しない。
  # install-cases.sh の (7)（読み取り不能な multi-agent.sh）と同じ扱いで部分 skip（root 実行では読み取り不能 fixture が成立しない。suite 全体の skip ではない）
  echo "  ○ skip: chmod 000 でも読める実行環境（root）のため、検出器の読み取り不能検査をスキップ"
  chmod 644 "$WORK/fx/unreadable.sh"
else
  _det_rc=0
  detects_direct_cli "$WORK/fx/unreadable.sh" >/dev/null 2>&1 || _det_rc=$?
  chmod 644 "$WORK/fx/unreadable.sh"
  if [ "$_det_rc" -eq 2 ]; then
    ok "検出器: 読めないファイルを clean と報告せず走査失敗として区別する"
  else
    bad "検出器: 読めないファイルの扱いが「一致なし」と同じ (rc=${_det_rc}) — 走査ゼロで緑になる"
  fi
fi

expect_detector_clean "$WORK/fx/delegating.sh" \
  "検出器: 委譲する fixture は誤検出しない" \
  "検出器: 委譲する fixture を誤検出した（コメント中の言及を拾っている）"

echo "-- 同梱シムの静的契約 --"

if [ -f "$SHIM" ]; then
  ok "シムが同梱されている: scripts/templates/codex-review.sh"
else
  bad "シムが同梱されていない: $SHIM"
  # 以降の検査はすべて対象不在で真空になるため、ここで打ち切る
  echo
  echo "  PASS=${PASS} FAIL=${FAIL}"
  FF_REACHED_END=1
  echo "✗ ${SUITE_NAME} verify: ${FAIL} 件失敗" >&2
  exit 1
fi

if [ -x "$SHIM" ]; then
  ok "シムに実行ビットが立っている"
else
  bad "シムに実行ビットが無い（配置後に chmod を要求する形は、配置漏れと区別がつかない）"
fi

_shim_det_rc=0
hits="$(detects_direct_cli "$SHIM")" || _shim_det_rc=$?
if [ "$_shim_det_rc" -eq 2 ]; then
  bad "シムを走査できませんでした（検出器が動いていないので、この検査は成立していない）"
elif [ "$_shim_det_rc" -eq 0 ]; then
  bad "シムが AI CLI を直接起動している — stdin を閉じ忘れると無言ハングする経路が復活する"
  printf '%s\n' "$hits" | sed 's/^/    | /' >&2
else
  ok "シムは AI CLI を直接起動しない（multi-agent.sh へ委譲している）"
fi

if grep -qE 'multi-agent\.sh' "$SHIM"; then
  ok "シムが multi-agent.sh へ委譲している"
else
  bad "シムが multi-agent.sh を参照していない（何に委譲しているのか不明）"
fi

# ヘルプの「実在する review 観点」列挙が perspectives/review の実体と集合一致すること。
# この列挙は利用者が --reviewers へ渡せる名前の一次案内で、固定する針が無いと新観点の
# 追加時に黙って古くなる（`Issue #1054` のレビューで acceptance-criteria の追加漏れを実測）。
# 列挙はラベル行から空行（またはヘルプの次項目）までを読み、`/` 区切りで観点名に割る。
_shim_help_persp="$(awk '/実在する review 観点:/ { f = 1 }
    f && /^[[:space:]]*$/ { exit }
    f { print }' "$SHIM" \
  | sed 's/実在する review 観点://' | tr '/' '\n' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | sort)"
_disk_review_persp="$(for _f in "$PLUGIN_ROOT"/scripts/perspectives/review/*.md; do
    [ -f "$_f" ] && basename "$_f" .md
  done | sort)"
if [ -z "$_shim_help_persp" ]; then
  bad "シムのヘルプに「実在する review 観点」の列挙が見つからない"
elif [ -z "$_disk_review_persp" ]; then
  bad "perspectives/review の実体が 1 件も見つからない（比較が空振り）"
elif [ "$_shim_help_persp" = "$_disk_review_persp" ]; then
  ok "シムのヘルプの review 観点列挙が perspectives/review の実体と一致"
else
  bad "シムのヘルプの review 観点列挙が perspectives/review の実体と不一致"
  diff <(printf '%s\n' "$_disk_review_persp") <(printf '%s\n' "$_shim_help_persp") | sed 's/^/    | /' >&2 || true
fi

