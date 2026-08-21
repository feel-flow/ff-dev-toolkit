#!/usr/bin/env bash
#
# multi-agent-critical-marker: 統合レポートの CRITICAL_BLOCK 判定の構造検査（Issue #272）。
#
# 背景: 旧判定式 `^\s*-\s*\[.*:.*\]` は重大度に関係なく [file:line] 形式の箇条書き
# すべてに発火し、Important のみのレビューでも「Critical issues detected」を宣言して
# いた（PR #270 で実際に発生）。CRITICAL_BLOCK は pre-push ゲート（docs-gates-runtime
# 参照）が push をブロックする根拠なので、誤出力は「Critical が無いのに push が
# 止まる」実害になる。逆に Critical の実所見でマーカーが出ない退行は、ゲートの
# 素通りという逆向きの実害になる。両方向を stub CLI の実走で固定する。
#
# 実 CLI は起動しない。codex コマンドを stub で覆い、レビュー本文だけを差し替えて
# orchestrator → generate_review_report の実経路を通す（判定式を単体で切り出して
# 検査すると、呼び出し側の変化で検査が別物になる）。
#
# 書き込み不可の環境では skip して成功扱いにする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$MULTI_AGENT" ] || {
  echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2
  exit 1
}

# 実行環境の MULTI_AGENT_* から分離する（Issue #374 / #378 の共通機構）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

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
    echo "✗ multi-agent-critical-marker: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- レビュー対象の差分を持つ一時リポジトリ ---
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "multi-agent-critical-marker-test"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange for review\n' > app.txt
git add app.txt
git commit -qm "change"

# --- stub CLI（codex のみ。レビュー本文は $TMP/body.md をそのまま出す） ---
STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
cat "$TMP/body.md"
SH
chmod +x "$STUB/codex"

REPORT="$REPO/.review-results/integrated-report.md"
MARKER='<!-- CRITICAL_BLOCK -->'
NONBLOCK_MARKER='<!-- CRITICAL_NONBLOCK -->'

# run_case <ラベル> <expect: present|absent> <センチネル> <本文ヒアドキュメントを stdin から>
# センチネルは本文中の一意な行で、「本文がレポートに到達したこと」を先に確かめる。
# これが無いと、stub や adapter 経路の故障で本文が判定器に届かないまま absent ケースが
# 空振り合格する（マーカーが出ない理由が「Critical なし」ではなく「本文なし」でも ✓）。
#
# 観点別段階化（Issue #645）のケースは、既存ケースの呼び出しを変えないため
# グローバル opt-in で条件を渡す。run_case が冒頭で local へ取り込んだ直後に
# リセットするので、早期 return 経路でも次ケースへ漏れない:
#   CASE_PERSPECTIVE      実行する観点（既定 code-review。空文字の明示指定 =
#                         --perspective を渡さず、--cli の registry 所有観点を全部走らせる）
#   CASE_EXPECT_NONBLOCK  <!-- CRITICAL_NONBLOCK --> 注記の期待（present|absent、既定 absent）
#   CASE_NONBLOCK_ENV     設定すると MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES として渡す
#                         （空文字も「明示指定」として渡す = 全観点ブロックの意思表示）
#   CASE_CONFIG_NONBLOCK  設定すると $REPO/.claude/agent-config.yaml の
#                         review.critical_nonblock_perspectives として書き込む
#                         （config 層の実挙動検査）
#   CASE_CONFIG_RAW       設定すると agent-config.yaml へ**そのまま**書き込む
#                         （YAML リスト誤設定など、整形済みの 1 文字列で表せない形用）
run_case() {
  local label="$1" expect="$2" sentinel="$3" rc=0
  local perspective="${CASE_PERSPECTIVE-code-review}"
  local expect_nonblock="${CASE_EXPECT_NONBLOCK:-absent}"
  local env_set=0 env_val="" cfg_set=0 cfg_val="" cfgraw_set=0 cfgraw_val=""
  if [[ "${CASE_NONBLOCK_ENV+set}" == "set" ]]; then
    env_set=1
    env_val="$CASE_NONBLOCK_ENV"
  fi
  if [[ "${CASE_CONFIG_NONBLOCK+set}" == "set" ]]; then
    cfg_set=1
    cfg_val="$CASE_CONFIG_NONBLOCK"
  fi
  if [[ "${CASE_CONFIG_RAW+set}" == "set" ]]; then
    cfgraw_set=1
    cfgraw_val="$CASE_CONFIG_RAW"
  fi
  unset CASE_PERSPECTIVE CASE_EXPECT_NONBLOCK CASE_NONBLOCK_ENV CASE_CONFIG_NONBLOCK CASE_CONFIG_RAW
  cat > "$TMP/body.md"
  if ! grep -qF "$sentinel" "$TMP/body.md"; then
    bad "${label}: fixture がセンチネル '${sentinel}' を含んでいない（self-test のバグ）"
    return
  fi
  rm -rf "$REPO/.review-results"
  # config はケース単位で用意し、使わないケースには残さない（前ケースの config が
  # 既定層の検査を黙って config 層の検査に変える汚染を防ぐ）
  rm -rf "$REPO/.claude"
  if [[ "$cfg_set" == "1" ]]; then
    mkdir -p "$REPO/.claude"
    printf 'review:\n  critical_nonblock_perspectives: "%s"\n' "$cfg_val" \
      > "$REPO/.claude/agent-config.yaml"
  elif [[ "$cfgraw_set" == "1" ]]; then
    mkdir -p "$REPO/.claude"
    printf '%s\n' "$cfgraw_val" > "$REPO/.claude/agent-config.yaml"
  fi
  # bash 3.2 + set -u は空配列の "${a[@]}" 展開で落ちるため、可変引数は分岐で渡す
  set +e
  if [[ "$env_set" == "1" && -n "$perspective" ]]; then
    run_isolated PATH="$STUB:$PATH" \
      MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES="$env_val" bash "$MULTI_AGENT" \
      --task review --cli codex-cli --perspective "$perspective" \
      --base develop --timeout 60 >"$TMP/run.log" 2>&1
  elif [[ "$env_set" == "1" ]]; then
    run_isolated PATH="$STUB:$PATH" \
      MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES="$env_val" bash "$MULTI_AGENT" \
      --task review --cli codex-cli \
      --base develop --timeout 60 >"$TMP/run.log" 2>&1
  elif [[ -n "$perspective" ]]; then
    run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
      --task review --cli codex-cli --perspective "$perspective" \
      --base develop --timeout 60 >"$TMP/run.log" 2>&1
  else
    run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
      --task review --cli codex-cli \
      --base develop --timeout 60 >"$TMP/run.log" 2>&1
  fi
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    bad "${label}: orchestrator が非 0 終了した (rc=$rc)"
    tail -5 "$TMP/run.log" | sed 's/^/    | /' >&2
    return
  fi
  if [[ ! -f "$REPORT" ]]; then
    bad "${label}: 統合レポートが生成されていない"
    return
  fi
  if ! grep -qF "$sentinel" "$REPORT"; then
    bad "${label}: 本文がレポートに到達していない（判定は空振り）"
    return
  fi
  if grep -qF "$MARKER" "$REPORT"; then
    if [[ "$expect" == "present" ]]; then
      ok "${label}: マーカーが出る"
    else
      bad "${label}: Critical が無い（またはブロック対象外）のにマーカーが出た（push ゲートの誤ブロック）"
      grep -n -B2 -A1 -F "$MARKER" "$REPORT" | sed 's/^/    | /' >&2
    fi
  else
    if [[ "$expect" == "absent" ]]; then
      ok "${label}: マーカーが出ない"
    else
      bad "${label}: Critical の実所見があるのにマーカーが出ない（push ゲートの素通り）"
    fi
  fi
  if grep -qF "$NONBLOCK_MARKER" "$REPORT"; then
    if [[ "$expect_nonblock" == "present" ]]; then
      ok "${label}: 非ブロック注記が出る"
    else
      bad "${label}: 非ブロック観点の Critical が無いのに注記が出た"
      grep -n -B2 -A2 -F "$NONBLOCK_MARKER" "$REPORT" | sed 's/^/    | /' >&2
    fi
  else
    if [[ "$expect_nonblock" == "absent" ]]; then
      : # 既定期待。ケースごとの ✓ は増やさない（既存ケースの出力を変えない）
    else
      bad "${label}: 非ブロック観点の Critical があるのに注記が出ない（重要度の情報が落ちた）"
    fi
  fi
}

echo "== CRITICAL_BLOCK 判定の構造検査 =="

# 1. Important のみ（[file:line] 箇条書きあり・Critical 0 件）→ 出ない
run_case "Important のみの [file:line] 箇条書き" absent "sentinel-case-1" <<'BODY'
<!-- sentinel-case-1 -->
## Code Review Results

### Critical Issues (信頼度 91-100)

なし。

### Important Issues (信頼度 80-90)
- [app.txt:2] 変更行の説明が不足している
  - 信頼度: 85
- [app.txt:1] 既存行との一貫性
  - 信頼度: 82

### Summary
- 検出された問題数: 2
- Critical: 0
- Important: 2
BODY

# 2. Critical セクションに実所見 → 出る
run_case "Critical セクションの実所見" present "sentinel-case-2" <<'BODY'
<!-- sentinel-case-2 -->
## Code Review Results

### Critical Issues (信頼度 91-100)
- [app.txt:2] 認証チェックの欠落
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 3. 箇条書きは無いが Summary の集計が Critical >= 1 → 出る
run_case "Summary 集計のみの Critical" present "sentinel-case-3" <<'BODY'
<!-- sentinel-case-3 -->
## Review

重大な問題を本文で説明する（箇条書きは使わない）。

### Summary
- Critical: 2
- Important: 0
BODY

# 4. 完了レビューがフェンス内と散文で Critical 判定文字列を引用 → 出ない
#    （本ツールが自身のスクリプトや perspective 文書をレビューすると実際に起こる形）
run_case "フェンス引用と散文言及のみ" absent "sentinel-case-4" <<'BODY'
<!-- sentinel-case-4 -->
## Code Review Results

判定式のレビュー。この検査は `- Critical: 1` のような Summary 行と、
行頭の CRITICAL: マーカーを探す（散文の中の言及はこの行のように無害）。
テンプレートの引用:

```markdown
### Critical Issues (信頼度 91-100)
- [ファイル名:行番号] 問題の説明

### Summary
- Critical: 1
```

### Summary
- 検出された問題数: 0
- Critical: 0
BODY

# 5. 行頭の大文字マーカー → 出る
run_case "行頭 CRITICAL: マーカー" present "sentinel-case-5" <<'BODY'
<!-- sentinel-case-5 -->
## Review

CRITICAL: authentication bypass in app.txt

### Summary
- Critical: 1
BODY

# 6. error-handler-hunt テンプレートの全大文字形 → 出る（同梱 perspective の実契約。
#    大文字小文字の吸収が落ちると同 perspective の Critical が丸ごと素通りする）
run_case "全大文字テンプレート（CRITICAL Issues / - CRITICAL: N）" present "sentinel-case-6" <<'BODY'
<!-- sentinel-case-6 -->
## Error Handler Hunt Results

### CRITICAL Issues
- [app.txt:2] エラーが握りつぶされている
  - 信頼度: 95

### Summary
- CRITICAL: 2
BODY

# 7. 未閉フェンスの後ろに実 Critical → 出る（フェンス不整合は判定不能として安全側 =
#    マーカーありへ倒す。旧トグル実装は以降を全部読み飛ばして素通りしていた）
run_case "未閉フェンスの後ろの実 Critical" present "sentinel-case-7" <<'BODY'
<!-- sentinel-case-7 -->
## Review

途中経過の引用:

```text
（この引用は閉じられないまま本文が続いてしまった）

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 8. Critical 見出し配下の「- なし」箇条書き → 出ない（空所見の箇条書き表記。
#    ケース 1 の散文「なし。」と対で、最も紛らわしい変種を固定する）
run_case "Critical 見出し配下の - なし 箇条書き" absent "sentinel-case-8" <<'BODY'
<!-- sentinel-case-8 -->
## Code Review Results

### Critical Issues (信頼度 91-100)
- なし

### Important Issues (信頼度 80-90)
- [app.txt:2] 軽微な指摘

### Summary
- Critical: 0
BODY

# 9. 見出しなし・語彙違いの集計行のみ（test-analysis 形）→ 出る
run_case "集計行の語彙違い（- Critical Gaps: N）" present "sentinel-case-9" <<'BODY'
<!-- sentinel-case-9 -->
## Test Analysis

本文で重大なギャップを説明する（Critical 見出しは使わない）。

### Summary
- Critical Gaps: 2
BODY

# ── 観点別段階化（Issue #645）──

# 10. 非ブロック観点（既定名簿の comment-analysis）の Critical → CRITICAL_BLOCK は
#     出ず、CRITICAL_NONBLOCK 注記が出る（格下げの本体。修正必須の情報は落とさない）
CASE_PERSPECTIVE=comment-analysis CASE_EXPECT_NONBLOCK=present \
run_case "非ブロック観点（comment-analysis）の Critical" absent "sentinel-case-10" <<'BODY'
<!-- sentinel-case-10 -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 10b. 消費側ゲートは囲みなしの部分一致 `grep -q "CRITICAL_BLOCK"` で判定する契約。
#      非ブロック注記のマーカー名・本文がその文字列を含むと、ブロックしないはずの
#      注記がブロックとして誤検知される。ケース 10 のレポート全体で消費側と同じ式が
#      不一致であることを固定する（本文 fixture 側にも当該文字列を書かないこと）。
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-10" "$REPORT"; then
  if grep -q "CRITICAL_BLOCK" "$REPORT"; then
    bad "非ブロック注記が消費側ゲートの部分一致 grep に誤検知される（CRITICAL_BLOCK を含む行がある）"
    grep -n "CRITICAL_BLOCK" "$REPORT" | sed 's/^/    | /' >&2
  else
    ok "非ブロック注記は消費側ゲートの部分一致 grep に掛からない"
  fi
else
  bad "ケース 10 のレポートが残っていない（10b は空振り）"
fi

# 11. 非ブロック観点でも Critical が無ければ注記も出ない（注記の誤出力は
#     「修正必須の指摘がある」という偽のシグナルになる）
CASE_PERSPECTIVE=comment-analysis \
run_case "非ブロック観点の Important のみ" absent "sentinel-case-11" <<'BODY'
<!-- sentinel-case-11 -->
## Comment Analysis Results

### Critical Issues
- なし

### Important Issues
- [app.txt:2] コメントの言い回しが冗長
  - 信頼度: 82

### Summary
- Critical: 0
BODY

# 12. 既定名簿に載っていない観点（comprehensive-review）の Critical → 従来どおり
#     ブロック（denylist 方式の fail closed。名簿は「格下げする観点」の列挙であり、
#     未知・未列挙の観点が黙って非ブロックへ落ちる退行を許さない）
CASE_PERSPECTIVE=comprehensive-review \
run_case "名簿外の観点（comprehensive-review）の Critical" present "sentinel-case-12" <<'BODY'
<!-- sentinel-case-12 -->
## Comprehensive Review Results

### Critical Issues
- [app.txt:2] 認可チェックの欠落
  - 信頼度: 96

### Summary
- Critical: 1
BODY

# 13. env に空文字を明示指定 → 全観点ブロック（旧挙動への復帰手段。
#     空文字が「未設定」と同一視されて既定名簿へ埋め戻される退行を固定する）
CASE_PERSPECTIVE=comment-analysis CASE_NONBLOCK_ENV="" \
run_case "env 空文字の明示指定で全観点ブロック" present "sentinel-case-13" <<'BODY'
<!-- sentinel-case-13 -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 14. env で code-review を格下げ名簿へ（カンマ区切りの受理も兼ねる）→ 既定で
#     ブロックする観点も設定で非ブロックへ上書きできる
CASE_PERSPECTIVE=code-review CASE_EXPECT_NONBLOCK=present \
  CASE_NONBLOCK_ENV="code-review,comment-analysis" \
run_case "env 上書きで code-review を非ブロック化" absent "sentinel-case-14" <<'BODY'
<!-- sentinel-case-14 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 15. 既定名簿の残り 3 観点も全件、非ブロックであることを固定する（ケース 10 の
#     comment-analysis と合わせて名簿 4 観点が揃う。どれか 1 つが既定から欠ける
#     変異でも該当ケースが赤くなる）
for _persp in test-analysis type-design-analysis code-simplification; do
  CASE_PERSPECTIVE="$_persp" CASE_EXPECT_NONBLOCK=present \
  run_case "既定名簿の非ブロック観点（${_persp}）の Critical" absent "sentinel-case-15" <<'BODY'
<!-- sentinel-case-15 -->
## Review Results

### Critical Issues
- [app.txt:2] 重大な指摘
  - 信頼度: 95

### Summary
- Critical: 1
BODY
done

# 16. 判定不能（未閉フェンス）× 非ブロック観点 → ブロックへ格上げせず、注記側で
#     「実所見」と区別された文言になる（本 PR が旧挙動から意図的に変えた唯一の
#     安全側分岐。「安全側だから」とブロックへ戻す将来のリファクタを赤にする）
CASE_PERSPECTIVE=comment-analysis CASE_EXPECT_NONBLOCK=present \
run_case "未閉フェンス × 非ブロック観点" absent "sentinel-case-16" <<'BODY'
<!-- sentinel-case-16 -->
## Comment Analysis Results

途中経過の引用:

```text
（この引用は閉じられないまま本文が続いてしまった）

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている

### Summary
- Critical: 1
BODY
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-16" "$REPORT"; then
  if grep -qF "Unparseable result treated as critical, in non-blocking perspectives (comment-analysis)" "$REPORT"; then
    ok "判定不能は注記内で実所見と区別された文言になる"
  else
    bad "判定不能の注記文言が見当たらない（実所見と区別できず、空振りを所見と読ませる）"
  fi
  if grep -qF "Critical findings in non-blocking perspectives" "$REPORT"; then
    bad "判定不能しかないのに実所見の文言が出ている"
  else
    ok "判定不能のみのとき実所見の文言は出ない"
  fi
else
  bad "ケース 16 のレポートが残っていない（文言検査は空振り）"
fi

# ── config 層（.claude/agent-config.yaml 経由）の実挙動 ──
# yq の有無で config 契約が丸ごと未検証にならないよう、この suite が書く最小
# config（printf の 2 行）だけを決定的に解釈する yq stub を用意して**常時**実行する。
# stub は実 yq の再実装ではない — 解釈対象の YAML はこの suite 自身が形を固定して
# 書いているので、sed 1 本で忠実に読める。実 yq が居る環境では代表 1 ケース +
# YAML リスト分岐を実 yq でも走らせ、stub と実物の乖離を検出する。
HAVE_YQ=0
command -v yq >/dev/null 2>&1 && HAVE_YQ=1
cat > "$STUB/yq" <<'SH'
#!/usr/bin/env bash
query="" file=""
for a in "$@"; do
  case "$a" in
    -r) ;;
    *) if [ -z "$query" ]; then query="$a"; else file="$a"; fi ;;
  esac
done
case "$query" in
  *critical_nonblock_perspectives*)
    sed -n 's/^  critical_nonblock_perspectives: "\(.*\)"$/\1/p' "$file" ;;
  .) cat "$file" ;;
  *) echo "" ;;
esac
SH
chmod +x "$STUB/yq"

# 17. config だけで code-review を格下げできる（env 未設定）
CASE_PERSPECTIVE=code-review CASE_EXPECT_NONBLOCK=present \
  CASE_CONFIG_NONBLOCK="code-review" \
run_case "config で code-review を非ブロック化 (stub yq)" absent "sentinel-case-17" <<'BODY'
<!-- sentinel-case-17 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 17b. config は既定名簿への**追加ではなく置換** — config が code-review だけを
#      挙げたら、既定名簿の comment-analysis はブロックへ戻る
CASE_PERSPECTIVE=comment-analysis CASE_CONFIG_NONBLOCK="code-review" \
run_case "config は既定名簿を置換する（comment-analysis はブロックへ戻る）(stub yq)" present "sentinel-case-17b" <<'BODY'
<!-- sentinel-case-17b -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている

### Summary
- Critical: 1
BODY

# 18. 非空 env は config より優先される（env に code-review が無い → ブロック）
CASE_PERSPECTIVE=code-review CASE_NONBLOCK_ENV="comment-analysis" \
  CASE_CONFIG_NONBLOCK="code-review" \
run_case "非空 env が config より優先 (stub yq)" present "sentinel-case-18" <<'BODY'
<!-- sentinel-case-18 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 19. 空文字 env は config より優先される（全観点ブロックへの復帰は config が
#     あっても埋め戻されない）
CASE_PERSPECTIVE=comment-analysis CASE_NONBLOCK_ENV="" \
  CASE_CONFIG_NONBLOCK="comment-analysis" \
run_case "空文字 env が config より優先（埋め戻さない）(stub yq)" present "sentinel-case-19" <<'BODY'
<!-- sentinel-case-19 -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている

### Summary
- Critical: 1
BODY

rm -f "$STUB/yq"

if [[ "$HAVE_YQ" -eq 1 ]]; then
  # 17R. 代表ケースを実 yq でも走らせ、stub と実物の乖離（クォート解釈の差など）を検出
  CASE_PERSPECTIVE=code-review CASE_EXPECT_NONBLOCK=present \
    CASE_CONFIG_NONBLOCK="code-review" \
  run_case "config で code-review を非ブロック化 (real yq)" absent "sentinel-case-17R" <<'BODY'
<!-- sentinel-case-17R -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

  # L1/L2. YAML リストで書かれた config は警告して既定名簿へ落とす（リスト出力の
  #        形は yq 実装依存のため実 yq でのみ検査する）。fallback 先は「全観点
  #        ブロック」ではなく**既定名簿** — code-review はブロックへ、
  #        comment-analysis は非ブロックへ、がそれぞれ生きていること
  CASE_PERSPECTIVE=code-review \
    CASE_CONFIG_RAW=$'review:\n  critical_nonblock_perspectives:\n    - code-review' \
  run_case "YAML リスト config は既定へ fallback（code-review はブロック）" present "sentinel-case-L1" <<'BODY'
<!-- sentinel-case-L1 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY
  if grep -qF "YAML リストではなく 1 文字列" "$TMP/run.log"; then
    ok "YAML リスト config に警告が出る"
  else
    bad "YAML リスト config の警告が出ていない（黙った fallback）"
  fi
  CASE_PERSPECTIVE=comment-analysis CASE_EXPECT_NONBLOCK=present \
    CASE_CONFIG_RAW=$'review:\n  critical_nonblock_perspectives:\n    - code-review' \
  run_case "YAML リスト config の fallback 先は既定名簿（comment-analysis は非ブロック）" absent "sentinel-case-L2" <<'BODY'
<!-- sentinel-case-L2 -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている

### Summary
- Critical: 1
BODY
else
  echo "  ○ skip: 実 yq が無いため代表照合（17R）と YAML リスト分岐（L1/L2）をスキップ（config 契約自体は stub yq で検査済み）"
fi

# ── 判定器（awk）自体の実行失敗（rc>2）の fail-closed ──
# Critical 判定器のプログラム文字列（in_crit を含む）だけを選択的に失敗させる
# awk stub。他の awk 呼び出し（Status: incomplete 検査など）は実物へ委譲する。
REAL_AWK="$(command -v awk)"
cat > "$STUB/awk" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *in_crit*) exit 3 ;; esac
done
exec "$REAL_AWK" "\$@"
SH
chmod +x "$STUB/awk"

# 21. awk 失敗 × ブロック観点 → fail closed でマーカーが出る。本文は Critical なし
#     （Important のみ）にして、マーカーが所見ではなく判定不能から来ることを固定する
CASE_PERSPECTIVE=code-review \
run_case "awk 失敗 × ブロック観点は fail closed" present "sentinel-case-21" <<'BODY'
<!-- sentinel-case-21 -->
## Code Review Results

### Important Issues
- [app.txt:2] 軽微な指摘

### Summary
- Critical: 0
BODY
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-21" "$REPORT"; then
  if grep -qF "Unparseable result treated as critical (code-review)" "$REPORT"; then
    ok "awk 失敗はブロック側でも判定不能の文言になる"
  else
    bad "awk 失敗の判定不能文言が出ていない（実所見と区別できない）"
  fi
else
  bad "ケース 21 のレポートが残っていない（文言検査は空振り）"
fi

# 21b. awk 失敗 × 非ブロック観点 → 注記へ分類される（ブロックへ格上げしない）
CASE_PERSPECTIVE=comment-analysis CASE_EXPECT_NONBLOCK=present \
run_case "awk 失敗 × 非ブロック観点は注記へ" absent "sentinel-case-21b" <<'BODY'
<!-- sentinel-case-21b -->
## Comment Analysis Results

### Important Issues
- [app.txt:2] 軽微な指摘

### Summary
- Critical: 0
BODY
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-21b" "$REPORT"; then
  if grep -qF "Unparseable result treated as critical, in non-blocking perspectives (comment-analysis)" "$REPORT"; then
    ok "awk 失敗は非ブロック側でも判定不能の文言になる"
  else
    bad "awk 失敗（非ブロック側）の判定不能文言が出ていない"
  fi
else
  bad "ケース 21b のレポートが残っていない（文言検査は空振り）"
fi

rm -f "$STUB/awk"

# 22. タブ区切りの env 名簿も受理される（正規化が落ちるとタブ区切りの観点が
#     黙ってブロック側へ倒れ、利用者の指定が静かに無視される）
CASE_PERSPECTIVE=code-review CASE_EXPECT_NONBLOCK=present \
  CASE_NONBLOCK_ENV=$'code-review\tcomment-analysis' \
run_case "タブ区切りの env 名簿" absent "sentinel-case-22" <<'BODY'
<!-- sentinel-case-22 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 20. ブロック観点と非ブロック観点の Critical が同一レポートに混在する
#     （--perspective を渡さず codex-cli の registry 所有 = code-review +
#     test-analysis の 2 観点を実走。stub は同じ本文を返すので両観点が Critical）
#     → 両マーカーが共存し、各行の観点名の帰属が正しい
CASE_PERSPECTIVE="" CASE_EXPECT_NONBLOCK=present \
run_case "ブロック + 非ブロックの混在" present "sentinel-case-20" <<'BODY'
<!-- sentinel-case-20 -->
## Review Results

### Critical Issues
- [app.txt:2] 重大な指摘
  - 信頼度: 95

### Summary
- Critical: 1
BODY
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-20" "$REPORT"; then
  if grep -qF "Critical issues detected (code-review)" "$REPORT"; then
    ok "ブロック行の観点名が code-review に帰属する"
  else
    bad "ブロック行の観点名の帰属が崩れている"
    grep -n "Critical issues detected" "$REPORT" | sed 's/^/    | /' >&2
  fi
  if grep -qF "Critical findings in non-blocking perspectives (test-analysis)" "$REPORT"; then
    ok "非ブロック行の観点名が test-analysis に帰属する"
  else
    bad "非ブロック行の観点名の帰属が崩れている"
    grep -n "Critical findings in non-blocking" "$REPORT" | sed 's/^/    | /' >&2
  fi
else
  bad "ケース 20 のレポートが残っていない（帰属検査は空振り）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-critical-marker verify: $FAIL 件失敗" >&2
  exit 1
fi
# 検査総数アサート（Issue #540 と同じ侵食対策）: run_case の注記検査ブロックや
# インライン検査が黙って削られても FAIL=0 のまま通ってしまうため、✓ の総数まで
# 固定する。ケースを増減させたらここも同時に更新すること。
# 実 yq が居る環境では代表照合 17R（2）+ YAML リスト L1（2）+ L2（2）の 6 検査が加わる
EXPECTED_PASS=43
[ "$HAVE_YQ" -eq 1 ] && EXPECTED_PASS=49
if [ "$PASS" -ne "$EXPECTED_PASS" ]; then
  echo "✗ multi-agent-critical-marker verify: 検査数が想定と違います（実測 ${PASS} / 想定 ${EXPECTED_PASS}）。検査が黙って消えたか、追加分の想定更新漏れです" >&2
  exit 1
fi
echo "✓ multi-agent-critical-marker verify: 全 $PASS 件 pass"
FF_REACHED_END=1
