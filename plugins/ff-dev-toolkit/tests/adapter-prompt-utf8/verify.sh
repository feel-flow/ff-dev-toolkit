#!/usr/bin/env bash
#
# adapter-prompt-utf8: CLI へ渡すプロンプトが呼び出し側のロケールに依存せず
# valid UTF-8 であることの回帰検査。
#
# 背景（導入先からの実測報告）: Windows / Git Bash のコンソール codepage 932 で
# レビューを走らせると codex-cli の全観点が
#   Failed to read prompt from stdin: input is not valid UTF-8 (invalid byte at offset N)
# で incomplete になった。`chcp 65001` + `LC_ALL=C.UTF-8` を設定すると完走する。
# つまり壊れているのはレビュー対象ではなく、プロンプトを組み立てる側のバイト列。
#
# 原因側の機械検証（Windows 実機は無いので、ロケールを C に固定して同じ条件を作る）:
#
#   1. **プロンプトはロケールに依存せず valid UTF-8 で CLI へ届く。** 非 UTF-8
#      ロケールで日本語 --description を渡しても、stub CLI が受け取る stdin が
#      valid UTF-8 で、日本語がそのまま載っていること。
#   2. **不正なバイトを含むプロンプトは送らない（fail-loud）。** 呼び出し元が
#      不正な UTF-8 を --description で渡したら、CLI を起動する前に止まり、原因と
#      回避策を出すこと。黙って送ると CLI がプロンプト全体を拒否し、全観点が
#      「レビュー結果なし」で終わる。
#   3. **再実行案内の引用がロケール非依存であること。** orchestrator は貼り付け用
#      コマンドを組み立てる。`printf '%q'` は現在のロケールで文字境界を解釈するため、
#      非 UTF-8 ロケールでは日本語が生バイトと $'\NNN' の混在になる（macOS の
#      bash 3.2 / LC_ALL=C で、出力全体が不正な UTF-8 になることを実測）。この文字列は
#      レポートへ載り、次回実行の --description（prior review evidence）として
#      戻ってくる。単引用エスケープ（shell_quote）はバイト透過なので日本語が
#      そのまま残る — そこを針にする。
#
# 実 CLI・ネットワーク・課金は伴わない。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
ADAPTER_COMMON="$ADAPTERS_DIR/adapter-common.sh"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

ORCHESTRATOR="$PLUGIN_ROOT/scripts/multi-agent.sh"

for f in "$ADAPTER_COMMON" "$ORCHESTRATOR"; do
  [ -f "$f" ] || { echo "✗ 対象ファイルが見つかりません: $f" >&2; exit 1; }
done

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_MODEL_CLAUDE_CODE" \
  "$ORCHESTRATOR" "$ADAPTERS_DIR"/*.sh

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正なパス・
# quota 超過など）まで同じ skip 文言に潰れ、壊れた TMPDIR が suite を exit 0 で
# 無効化し続ける。rc=0 でも -d を検査する（2>&1 の合流で警告文が混入しうる）。
_ff_mktemp_rc=0
_ff_mktemp_out="$(mktemp -d 2>&1)" || _ff_mktemp_rc=$?
if [ "$_ff_mktemp_rc" -eq 0 ] && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

# 検査器が無ければ何も主張できない。無言で緑にせず理由付きで skip する。
if ! command -v iconv >/dev/null 2>&1; then
  echo "○ skip: iconv が無い環境のためスキップ（UTF-8 妥当性を判定できない）"
  rm -rf "$TMP"
  exit 0
fi

# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は 0 になるため、
# 「rc=0 なのに最後まで到達していない」を中断として扱う。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ adapter-prompt-utf8: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  if [ "$_ff_rc" -ne 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ adapter-prompt-utf8: サマリー前に中断しました (rc=${_ff_rc})" >&2
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

is_utf8() { # $1: ファイル / rc0 = valid UTF-8
  # 変換結果の捨て先を /dev/null にしない。macOS 26 の BSD iconv は stdout が
  # /dev/null だと、多バイト文字が出力の 1024 バイト境界をまたぐ入力で valid な
  # UTF-8 でも rc=1（"Inappropriate ioctl for device"）を返す（2026-09 実測。
  # 発生はバイト位置依存で、同じ内容でも絶対パスの長さで緑・赤が入れ替わる）。
  # 通常ファイルへ向けると判定も診断も本来のものになる。
  LC_ALL=C iconv -f UTF-8 -t UTF-8 <"$1" >"$TMP/iconv-sink.bin" 2>&1
}

# 日本語の fixture 値。**空白を含めない**こと: bash の printf %q は空白を含む文字列を
# `$'...'` で丸ごと包む形へ倒れるため、空白入りの値では退行（%q への差し戻し）を
# 取り逃がす配置がありうる。針は「生の UTF-8 がそのまま残るか」で見る。
JP_DESC='前回レビュー:未解決の指摘はなし'

# --- diff を持つ一時リポジトリ（review の build_prompt は diff 必須） ---
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$TMP/repo"
ff_git_fixture_init "$REPO" "adapter-prompt-utf8-test" "test@example.com"
cd "$REPO"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > app.txt
git add app.txt
git commit -qm "change"

PERSPECTIVE="$TMP/perspective.md"
printf '%s\n' '# Fixture Perspective' 'PERSPECTIVE-CONTENT-MARKER' > "$PERSPECTIVE"

# stub codex は argv を 1 引数 1 行で、stdin を丸ごと記録する。
# implement 経路の能力確認（exec --help）には記録せずに応答する。
CODEX_HELP_ARM='case " $* " in *" exec --help "*) printf "  -C, --cd <DIR>\n"; exit 0 ;; esac'
STUB="$TMP/bin"
mkdir -p "$STUB"
write_codex_stub() { # $1: 終了コード
  cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
${CODEX_HELP_ARM}
for a in "\$@"; do printf '%s\n' "\$a" >> "$TMP/argv.log"; done
cat >> "$TMP/stdin.log"
echo "- Suggestion: stub review output"
exit $1
SH
  chmod +x "$STUB/codex"
}
write_codex_stub 0

echo "== 非 UTF-8 ロケールでも CLI が受け取るプロンプトは valid UTF-8 =="

: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
run_isolated LC_ALL=C LANG=C PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$ADAPTERS_DIR/codex-cli-adapter.sh" "$PERSPECTIVE" "$TMP/out.md" \
  --base develop --timeout 30 --task-type review --description "$JP_DESC" \
  >"$TMP/adapter.log" 2>&1
ADAPTER_RC=$?
set -e

if [ "$ADAPTER_RC" -ne 0 ]; then
  bad "LC_ALL=C 下で codex アダプタが非 0 終了した (rc=$ADAPTER_RC)"
  tail -20 "$TMP/adapter.log" | sed 's/^/    | /' >&2
elif [ ! -s "$TMP/argv.log" ]; then
  bad "codex の argv が記録されていない（stub 未経由の疑い）"
else
  ok "LC_ALL=C 下で codex アダプタが完走する"
  if is_utf8 "$TMP/stdin.log"; then
    ok "CLI が受け取ったプロンプト（stdin）が valid UTF-8"
  else
    bad "CLI が受け取ったプロンプトが不正な UTF-8（codex-cli はこれを丸ごと拒否する）"
    # 捨てる先を /dev/null にすると BSD iconv は errno を上書きし
    # "Inappropriate ioctl for device" を出す。通常ファイルへ向けて本来の理由を残す。
    printf '    | %s\n' "$(LC_ALL=C iconv -f UTF-8 -t UTF-8 <"$TMP/stdin.log" 2>&1 >"$TMP/iconv-sink.bin" || true)" >&2
  fi
  if grep -qF "$JP_DESC" "$TMP/stdin.log"; then
    ok "日本語 --description がプロンプトへ生の UTF-8 のまま載る"
  else
    bad "日本語 --description がプロンプトに見つからない（バイト列が変質した疑い）"
  fi
fi

echo "== 不正な UTF-8 を含むプロンプトは CLI へ送らない（fail-loud） =="

# 呼び出し元が壊れたバイトを渡してくる形（原因は呼び出し側のロケール）。
# 0x81 は単体では不正な UTF-8。argv では NUL 以外の任意バイトを渡せる。
BAD_DESC="$(printf 'prior review evidence: \201 broken')"

: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
run_isolated LC_ALL=C LANG=C PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$ADAPTERS_DIR/codex-cli-adapter.sh" "$PERSPECTIVE" "$TMP/out-bad.md" \
  --base develop --timeout 30 --task-type review --description "$BAD_DESC" \
  >"$TMP/adapter-bad.log" 2>&1
BAD_RC=$?
set -e

if [ "$BAD_RC" -eq 0 ]; then
  bad "不正な UTF-8 を含むプロンプトで正常終了した（黙って壊れた入力を送っている）"
else
  ok "不正な UTF-8 を含むプロンプトで非 0 終了する (rc=$BAD_RC)"
fi
if [ -s "$TMP/argv.log" ]; then
  bad "不正な UTF-8 のまま CLI を起動した（起動前に止まっていない）"
else
  ok "CLI を起動する前に止まる（無駄な課金・全観点の incomplete を避ける）"
fi
if grep -qF 'not valid UTF-8' "$TMP/adapter-bad.log"; then
  ok "エラーが原因（不正な UTF-8）を名指しする"
else
  bad "エラーが不正な UTF-8 を名指ししない（原因がロケールだと読み取れない）"
  tail -20 "$TMP/adapter-bad.log" | sed 's/^/    | /' >&2
fi
if grep -qF 'LC_ALL=C.UTF-8' "$TMP/adapter-bad.log" && grep -qF 'chcp 65001' "$TMP/adapter-bad.log"; then
  ok "エラーが回避策（chcp 65001 / LC_ALL=C.UTF-8）を示す"
else
  bad "エラーに回避策が無い（読んだ人が次の一手を取れない）"
  tail -20 "$TMP/adapter-bad.log" | sed 's/^/    | /' >&2
fi
if [ -f "$TMP/out-bad.md" ]; then
  ok "失敗しても INCOMPLETE 成果物は残る（沈黙しない）"
else
  bad "成果物が書かれていない（失敗が下流から見えない）"
fi

echo "== 再実行案内の引用がロケールに依存しない =="

# 失敗した実行の再実行案内には --description が載る。ここが `printf '%q'` だと、
# 非 UTF-8 ロケールでは日本語が $'\NNN' の並びへ落ちる（そのテキストが次回実行の
# prior review evidence として戻ると、プロンプト全体が壊れる）。
write_codex_stub 1
: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
( cd "$REPO" && run_isolated LC_ALL=C LANG=C PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$ORCHESTRATOR" \
  --task review --cli codex-cli --perspective code-review \
  --description "$JP_DESC" --base develop --timeout 30 \
  --output-dir "$REPO/.review-results" \
  ) >"$TMP/orch.log" 2>&1
ORCH_RC=$?
set -e

if [ "$ORCH_RC" -eq 0 ]; then
  bad "stub CLI が失敗したのに orchestrator が 0 で終了した（失敗が伝播していない）"
else
  ok "失敗した実行として扱われる (rc=$ORCH_RC)"
fi
if is_utf8 "$TMP/orch.log"; then
  ok "orchestrator の出力全体が valid UTF-8"
else
  bad "orchestrator の出力が不正な UTF-8（レポート経由で次回のプロンプトを壊す）"
fi
# 案内行だけを見る。show_plan は description を素で 1 回出すため、全体検索では
# 引用側の退行を取り逃がす。
ADVICE_LINE="$(grep -F -- '--description' "$TMP/orch.log" || true)"
if [ -z "$ADVICE_LINE" ]; then
  bad "再実行案内に --description の行が無い（案内が出ていない）"
  tail -25 "$TMP/orch.log" | sed 's/^/    | /' >&2
else
  case "$ADVICE_LINE" in
    *"$JP_DESC"*) ok "再実行案内の --description に日本語が生の UTF-8 のまま載る" ;;
    *)
      bad "再実行案内の --description が生の日本語でない（ロケール依存の引用に戻った疑い）"
      printf '    | %s\n' "$ADVICE_LINE" >&2
      ;;
  esac
fi

# 構造側の固定。上の針は「%q が壊れるロケール」でしか赤くならない（bash 5 の
# LC_ALL=C は $'...' で全体を包むため、その組み合わせでは生の日本語も escape も
# 区別が付く一方、環境によっては %q が偶然通る）。ロケール依存の引用そのものを
# 使わないことを、環境非依存に固定しておく。
# コメント行（この退行を説明している行そのもの）は除く。行番号を付けたまま
# 先頭の空白を落として `#` 判定する — `grep -v ':#'` 型の除外は、コロンを含む
# コード行を巻き込んで検出を静かに殺す。
LOCALE_QUOTE_HITS="$(awk '
  index($0, "printf \x27%q\x27") {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (substr(line, 1, 1) != "#") printf "%d:%s\n", NR, $0
  }' "$ORCHESTRATOR")"
if [ -n "$LOCALE_QUOTE_HITS" ]; then
  bad "orchestrator が printf '%q' を使っている（引用がロケール依存に戻っている）"
  printf '%s\n' "$LOCALE_QUOTE_HITS" | sed 's/^/    | /' >&2
else
  ok "orchestrator はロケール依存の printf '%q' で引用しない"
fi

echo ""
echo "== UTF-8 検査の捨て先が /dev/null でない（macOS 26 の BSD iconv の境界不具合） =="

# macOS 26 の BSD iconv は stdout が /dev/null だと、多バイト文字が出力の 1024 バイト
# 境界をまたぐ valid な入力で rc=1 を返す（"Inappropriate ioctl for device"）。
# is_utf8 自身がその形へ戻っていないことを、境界を踏む合成入力で直接固定する
# （ASCII 1019 バイト + 多バイト文字 = 実測で再現した最小形）。
head -c 1019 /dev/zero | tr '\0' 'x' > "$TMP/boundary.txt"
printf '日本\n' >> "$TMP/boundary.txt"
if is_utf8 "$TMP/boundary.txt"; then
  ok "1024 バイト境界を多バイト文字がまたぐ valid な入力を valid と判定する"
else
  bad "1024 バイト境界を多バイト文字がまたぐ valid な入力が invalid 扱いになる（捨て先が /dev/null に戻った疑い）"
fi
printf '\xff\n' >> "$TMP/boundary.txt"
if is_utf8 "$TMP/boundary.txt"; then
  bad "不正バイトを含む入力が valid 扱いになる（判定が壊れている）"
else
  ok "不正バイトを含む入力は引き続き invalid と判定する"
fi

# 静的な再混入ガード: プラグイン配下の tracked shell で、iconv の UTF-8 再解釈を
# 同じ行で /dev/null へ捨てている箇所が無いこと（コメント行は除く）。
# git grep はリポジトリ内で走るので cwd に依存しない（ls-files | xargs grep は
# cwd が plugin root でないと相対 path を開けず、空振りして緑になる）。
# 見るのは iconv 自身の stdout（`>` / `1>` / `&>` / `>&`、引用付き "/dev/null" も含む）。
# `2>/dev/null`（stderr）は対象外。パイプ消費側の `>(cat 1>/dev/null)` はこの
# idiom だけを行から取り除いてから照合する（iconv 自身の `1>/dev/null` は拾う）。
DEVNULL_RE="[^0-9&](1?>|&>|>&)[[:space:]]*\"?/dev"
DEVNULL_RE="${DEVNULL_RE}/null"
DEVNULL_CONSUMER='>(cat 1>/dev/null)'
# 走査できないことを「指摘 0 件」と同一視しない（git 管理外の plugin root では
# 理由付き skip、走査できても対象が 0 件なら 0 件の主張はできないので赤、
# git grep の rc=1 だけを「一致なし」と読み、それ以外の非 0 は赤）。
if ! git -C "$PLUGIN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "  ○ skip: plugin root が git 管理外のため /dev/null 宛て再混入の静的検査をスキップ"
else
  if DEVNULL_TARGETS="$(git -C "$PLUGIN_ROOT" grep -nE 'iconv -f UTF-8 -t UTF-8' -- '*.sh' 2>"$TMP/gitgrep.err")"; then
    DEVNULL_GREP_RC=0
  else
    DEVNULL_GREP_RC=$?
  fi
  if [ "$DEVNULL_GREP_RC" -ne 0 ]; then
    bad "静的検査の走査に失敗（git grep rc=${DEVNULL_GREP_RC}）— 0 件の主張はできない"
    sed 's/^/    | /' "$TMP/gitgrep.err" >&2
  elif [ -z "$DEVNULL_TARGETS" ]; then
    bad "静的検査の対象（iconv の UTF-8 再解釈を持つ tracked shell）が 0 件 — 0 件の主張はできない"
  else
    DEVNULL_HITS="$(printf '%s\n' "$DEVNULL_TARGETS" \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      | sed "s|$DEVNULL_CONSUMER||g" \
      | grep -E "$DEVNULL_RE" || true)"
    if [ -z "$DEVNULL_HITS" ]; then
      ok "tracked shell に iconv の UTF-8 再解釈を /dev/null へ捨てる行が無い（対象 $(printf '%s\n' "$DEVNULL_TARGETS" | wc -l | tr -d ' ') 行）"
    else
      bad "iconv の UTF-8 再解釈を /dev/null へ捨てる行が残っている（sink ファイルかパイプへ向けること）"
      printf '    | %s\n' "$DEVNULL_HITS" >&2
    fi
  fi
fi

echo "  PASS: $PASS / FAIL: $FAIL"
FF_REACHED_END=1
[ "$FAIL" -eq 0 ]
