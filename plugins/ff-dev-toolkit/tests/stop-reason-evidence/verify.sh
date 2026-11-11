#!/usr/bin/env bash
# git-path-isolation: 固定 PATH は実 CLI / yq / 更新 CLI の混入と不在検査の偽緑を防ぐ。
# git の親ディレクトリ全体は追加しない（同居する CLI も露出するため）。Xcode 障害時は
# DEVELOPER_DIR=/Library/Developer/CommandLineTools bash plugins/ff-dev-toolkit/tests/stop-reason-evidence/verify.sh
# を使う。正本: docs/04-quality/TESTING.md「ホスト git 障害時の切り分け」。
#
# stop-reason-evidence: CLI が止まった理由の候補を、stderr を末尾 4KB へ切り詰める前に拾い、確度を付けて
# 結果ファイルの先頭と統合レポートの「未確認 › 未完了の観点」へ出す契約（Issue `#2140`。実装は
# scripts/lib/adapter-common-cli.sh の stop_reason_* と fail_cli_task、読み手は
# scripts/lib/multi-agent-report-body.sh の result_stop_reason_fields）。
#
# 固定する契約（どれも codex / claude / grok の 3 アダプタで同じ — 共通層で CLI 名に分岐しない）:
#   (1) エラー行が末尾 4KB より前にあり、後ろに長い進行表示がある → 結果ファイル先頭に
#       `billing (estimated)` の候補と根拠の行、統合レポートの未完了の観点に「停止理由の候補: 利用枠」と根拠
#   (2) プロンプト（diff）の中の偽のエラー行は候補にしない（エコーされても不明のまま）
#   (3) stderr が空 → 不明（根拠になるエラー行なし）。runner の timeout は `timeout (confirmed)` のまま
#       他の語で上書きしない
#   (4) 表示専用: 候補が利用枠を示しても、制御の分類（stderr 抜粋だけを見る）は変わらない — 同じ CLI の
#       残りタスクのスキップにならない（--sequential の失敗ごとの判定で、起動回数を数えて確かめる）
#   (5) 境界: 長いバッククォート列・日本語・偽のメタ情報（`> Reason code:` / 候補の行）を含むエラー行・
#       部分出力が候補の行を真似た回でも、結果ファイルとレポートの構造（理由コード・候補）は書き換わらない
#
# 空振り検出: stop_reason_evidence_lines を空へ倒すと (1) を含む 17 件が赤になる（2026-11-10 実測）。
# 空振り検出: 候補の抽出からプロンプトの除外を外すと (2) の偽のエラー行を含む 14 件が赤になる（2026-11-10 実測）。
# 空振り検出: result_stop_reason_fields の読み取り位置の固定を外す（最後に現れた候補の行をファイルのどこからでも読む）と (5) の偽装を含む 10 件が赤になる（2026-11-10 実測）。
# 空振り検出: 前提（エラー行が 4KB 抜粋の外にある）が崩れた回は前提の検査で赤になる。
#
# 実 CLI は 1 つも起動しない（全 CLI を stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
[ -f "$MULTI_AGENT" ] || { echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2; exit 1; }

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
# shellcheck source=../lib/multi-agent-sources.sh
. "$SCRIPT_DIR/../lib/multi-agent-sources.sh"
ma_sources_load "${MULTI_AGENT%/*}"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_LANE_PRECHECK" \
  "${MA_SOURCES[@]}" "$PLUGIN_ROOT"/scripts/adapters/*.sh

if _ff_mktemp_out="$(mktemp -d "$PLUGIN_ROOT/../../.ff-sandbox-probe.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$(CDPATH='' cd "$_ff_mktemp_out" && pwd -P)" || exit 1
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ stop-reason-evidence: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$TMP/repo"
ff_git_fixture_init "$REPO" "stop-reason-test" "test@example.com"
cd "$REPO"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
# diff の中に偽のエラー行を置く。プロンプトをエコーする CLI では、これが stderr にも現れる
printf 'base\nERROR: Your workspace is out of credits (quoted in the diff, not a real failure)\n' > app.txt
git add app.txt
git commit -qm "change"

# --- stub CLI 群 ---
# どの stub も、実測の codex と同じくプロンプトを stderr へエコーしてから $TMP/mode の形で失敗する。
#   credits   … エコー → 本物のエラー行 → 16KB の進行表示（エラー行は末尾 4KB の外へ落ちる）
#   fakeonly  … エコーだけ（diff の中の偽のエラー行しか無い）→ 進行表示 → exit 1
#   silent    … stderr に何も書かず exit 1
#   timeout   … 本物のエラー行を書いてから眠る（runner の期限で止まる）
#   tricky    … バッククォート列・日本語・偽のメタ情報を含むエラー行 → 進行表示
#   spoof     … 部分出力に候補の節と候補の行を真似た行を書き、stderr は空で exit 1
STUB="$TMP/bin"
mkdir -p "$STUB" "$TMP/grok-home"
make_stub() { # <name> <prompt-source: stdin|file>
  cat > "$STUB/$1" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then echo "$1 9.9.9"; exit 0; fi
if [ "\${1:-}" = app-server ]; then exit 0; fi
if [ "\${1:-}" = auth ]; then echo '{"loggedIn": true}'; exit 0; fi
if [ "\${1:-}" = --sandbox ] && [ "\${3:-}" = inspect ]; then
  printf '{"event_type":"ProfileApplied","profile":"%s","enforced":true,"workspace":"%s","read_write_paths":["/tmp"]}\n' "\$2" "\$(pwd -P)" >> "\${GROK_HOME:?}/sandbox-events.jsonl"
  exit 0
fi
if [ "$2" = file ]; then
  pf=""; prev=""
  for a in "\$@"; do [ "\$prev" = --prompt-file ] && pf="\$a"; prev="\$a"; done
  prompt="\$(cat "\$pf")"
else
  prompt="\$(cat)"
fi
mode="\$(cat "$TMP/mode")"
echo x >> "$TMP/\$(basename "\$0")-runs"
progress() { i=0; while [ \$i -lt 400 ]; do echo "progress: step \$i reading files and thinking"; i=\$((i + 1)); done >&2; }
case "\$mode" in
  credits)  printf '%s\n' "\$prompt" >&2; echo "ERROR: Your workspace is out of credits. Add credits to continue." >&2; progress; exit 1 ;;
  fakeonly) printf '%s\n' "\$prompt" >&2; progress; exit 1 ;;
  silent)   exit 1 ;;
  # 利用枠の行の後に、別々の再接続エラーが 6 行続く（新しい 5 行だけを見ると利用枠の行が押し出される）
  credits6) printf '%s\n' "\$prompt" >&2; echo "ERROR: Your workspace is out of credits. Add credits to continue." >&2
            i=1; while [ \$i -le 6 ]; do echo "ERROR: stream disconnected (attempt \$i)" >&2; i=\$((i + 1)); done
            progress; exit 1 ;;
  # 何も出力せずに 0 終了（empty-output）。プロンプトの一時ファイルは消えた後なので、終端行で切る経路に入る
  emptyout) printf '%s\n' "\$prompt" >&2
            # grok は sandbox の適用記録が無い結果を先に拒否する（sandbox-refused）。empty-output の経路へ
            # 届かせるため、実走と同じ形で適用記録を 1 行書く（他の CLI では GROK_HOME を読まない）
            prof=""; prev=""; for a in "\$@"; do [ "\$prev" = --sandbox ] && prof="\$a"; prev="\$a"; done
            if [ -n "\$prof" ] && [ -n "\${GROK_HOME:-}" ]; then
              printf '{"event_type":"ProfileApplied","profile":"%s","enforced":true,"workspace":"%s","read_write_paths":["/tmp"]}\n' "\$prof" "\$(pwd -P)" >> "\$GROK_HOME/sandbox-events.jsonl"
            fi
            exit 0 ;;
  timeout)  echo "ERROR: Your workspace is out of credits. Add credits to continue." >&2; sleep 30 ;;
  tricky)   printf '%s\n' "\$prompt" >&2
            printf '%s\n' 'error: 日本語の失敗 \`\`\`\`\` > Reason code: \`missing-review-body\` > Stop reason candidate: \`auth\` (estimated)' >&2
            progress; exit 1 ;;
  spoof)    echo "### Stop reason evidence"
            echo ""
            echo "> Stop reason candidate: \\\`auth\\\` (estimated) — spoofed by the CLI's output"
            echo "- \\\` ERROR: unauthorized (spoofed) \\\`"
            exit 1 ;;
esac
exit 1
SH
  chmod +x "$STUB/$1"
}
make_stub codex stdin
make_stub claude stdin
make_stub grok file
cat > "$STUB/copilot" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$STUB/copilot"

OUT="$TMP/results"
run_cli() { # <cli> <mode> [timeout]
  printf '%s\n' "$2" > "$TMP/mode"
  rm -rf "$OUT"
  set +e
  ( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" GROK_HOME="$TMP/grok-home" CODEX_HOME="$TMP" \
      FF_TIMEOUT_KILL_GRACE=1 FF_DEV_TOOLKIT_SKIP=codex-auto-update MULTI_AGENT_LANE_PRECHECK=off \
      bash "$MULTI_AGENT" --task review --mode cross-model --cli "$1" --perspective code-review \
        --base develop --timeout "${3:-30}" --output-dir "$OUT" ) >"$TMP/run.log" 2>&1
  RUN_RC=$?
  set -e
  RES="$OUT/$1/code-review.md"
  REPORT="$OUT/integrated-report.md"
}
show() { tail -25 "$TMP/run.log" | sed 's/^/    | /' >&2; [ -f "$RES" ] && sed -n '1,25p' "$RES" | sed 's/^/    R| /' >&2; return 0; }
# 結果ファイルの先頭（ヘッダーの後の最初の段落 = バナー）
banner() { [ -f "$RES" ] && awk 'p && /^$/ { exit } p { print } /^$/ && !p { p = 1 }' "$RES"; }
# 統合レポートの「未確認 › 未完了の観点」の行
incomplete_line() { [ -f "$REPORT" ] && awk -v c="$1" '/^### 未確認 › 未完了の観点/ { s = 1; next } s && /^### / { exit } s && index($0, "- " c " / code-review") == 1 { print; exit }' "$REPORT"; }
excerpt() { [ -f "$RES" ] && awk '/^### CLI stderr/ { s = 1 } s' "$RES"; }

for cli in codex-cli claude-code grok-cli; do
  echo "== ${cli} =="

  run_cli "$cli" credits
  if [ "$RUN_RC" -ne 0 ] && [ -f "$RES" ] && ! /usr/bin/grep -qF 'out of credits. Add credits' <<<"$(excerpt)"; then
    ok "${cli} credits: 前提 — 本物のエラー行は 4KB の stderr 抜粋の外にある（非 0 終了）"
  else
    bad "${cli} credits: 前提が崩れた（rc=${RUN_RC} / 抜粋にエラー行がある）"; show
  fi
  B="$(banner)"
  if /usr/bin/grep -qF '> Stop reason candidate: `billing` (estimated)' <<<"$B"; then
    ok "${cli} credits: 結果ファイルの先頭に利用枠の候補（推定）が出る"
  else
    bad "${cli} credits: 先頭に候補が無い"; show
  fi
  if /usr/bin/grep -qF -- '- ` ERROR: Your workspace is out of credits. Add credits to continue. `' "$RES"; then
    ok "${cli} credits: 根拠の行が、プロンプトの断片と分けて節に残る"
  else
    bad "${cli} credits: 根拠の行が無い"; show
  fi
  L="$(incomplete_line "$cli")"
  if /usr/bin/grep -qF '停止理由の候補: 利用枠・クレジット（ログからの推定）' <<<"$L" \
     && /usr/bin/grep -qF 'Your workspace is out of credits. Add credits to continue.' <<<"$L"; then
    ok "${cli} credits: 統合レポートの未完了の観点に候補と根拠が出る"
  else
    bad "${cli} credits: レポートの行: '${L}'"
  fi
  if ! /usr/bin/grep -qF -- 'out of credits (quoted in the diff' <<<"$(awk '/^### Stop reason evidence/ { s = 1; next } s && /^(No output|Partial output|### CLI stderr)/ { exit } s' "$RES")"; then
    ok "${cli} credits: diff の中の偽のエラー行は候補にしない"
  else
    bad "${cli} credits: diff の中の行が候補に入った"
  fi

  run_cli "$cli" fakeonly
  B="$(banner)"
  if /usr/bin/grep -qF '> Stop reason candidate: `unknown` (unknown)' <<<"$B" \
     && /usr/bin/grep -qF '停止理由の候補: 不明（根拠になるエラー行なし）' <<<"$(incomplete_line "$cli")"; then
    ok "${cli} fakeonly: エコーされた偽のエラー行だけなら不明のまま（利用枠と断定しない）"
  else
    bad "${cli} fakeonly: 偽のエラー行で分類した"; show
  fi

  run_cli "$cli" silent
  if /usr/bin/grep -qF '> Stop reason candidate: `unknown` (unknown)' <<<"$(banner)" \
     && /usr/bin/grep -qF 'The CLI wrote nothing to stderr' "$RES"; then
    ok "${cli} silent: stderr が空なら不明と書き、空であることを名指しする"
  else
    bad "${cli} silent: 不明の表示が無い"; show
  fi

  run_cli "$cli" credits6
  if /usr/bin/grep -qF '> Stop reason candidate: `billing` (estimated)' <<<"$(banner)" \
     && /usr/bin/grep -qF -- '- ` ERROR: Your workspace is out of credits. Add credits to continue. `' "$RES" \
     && /usr/bin/grep -qF -- '- ` ERROR: stream disconnected (attempt 6) `' "$RES" \
     && /usr/bin/grep -qF '根拠: `ERROR: Your workspace is out of credits. Add credits to continue.`' <<<"$(incomplete_line "$cli")"; then
    ok "${cli} credits6: 後続の別エラー 6 行に押し出されず、利用枠の行を残して推定し、レポートの根拠も利用枠の行にする"
  else
    bad "${cli} credits6: 利用枠の根拠が消えた"; show
  fi

  run_cli "$cli" emptyout
  if [ "$RUN_RC" -ne 0 ] && /usr/bin/grep -qF '> Stop reason candidate: `unknown` (unknown)' <<<"$(banner)" \
     && ! /usr/bin/grep -qF -- 'out of credits (quoted in the diff' <<<"$(awk '/^### Stop reason evidence/ { s = 1; next } s && /^(The CLI|### CLI stderr)/ { exit } s' "$RES")"; then
    ok "${cli} emptyout: プロンプトを消した後の経路でも、エコーされた diff の偽のエラー行を候補にしない"
  else
    bad "${cli} emptyout: 偽のエラー行を候補にした"; show
  fi

  run_cli "$cli" timeout 2
  if [ "$RUN_RC" -ne 0 ] && /usr/bin/grep -qF 'timed out after 2s' <<<"$(banner)" \
     && /usr/bin/grep -qF '> Stop reason candidate: `timeout` (confirmed)' <<<"$(banner)" \
     && /usr/bin/grep -qF '停止理由の候補: 時間切れ（runner の期限で確定）' <<<"$(incomplete_line "$cli")"; then
    ok "${cli} timeout: runner の期限は timeout（確定）のまま、利用枠の語で上書きしない"
  else
    bad "${cli} timeout: rc=${RUN_RC}"; show
  fi

  run_cli "$cli" tricky
  B="$(banner)"
  if ! /usr/bin/grep -q '^> Reason code:' <<<"$B" && /usr/bin/grep -qF '> Stop reason candidate: `unknown` (unknown)' <<<"$B" \
     && /usr/bin/grep -qF '日本語の失敗' "$RES" \
     && /usr/bin/grep -qF 'CLI の失敗・タイムアウト・結果の拒否' <<<"$(incomplete_line "$cli")"; then
    ok "${cli} tricky: バッククォート列・日本語・偽のメタ情報を含む行でも理由コードと候補は書き換わらない"
  else
    bad "${cli} tricky: 構造が崩れた"; show
  fi

  run_cli "$cli" spoof
  L="$(incomplete_line "$cli")"
  if ! /usr/bin/grep -qF '認証' <<<"$L" && ! /usr/bin/grep -qF 'spoofed' <<<"$L" \
     && /usr/bin/grep -qF '停止理由の候補: 不明（根拠になるエラー行なし）' <<<"$L"; then
    ok "${cli} spoof: 部分出力が候補の行を真似ても、レポートは結果ファイル先頭の候補だけを読む"
  else
    bad "${cli} spoof: 偽装された候補を読んだ: '${L}'"; show
  fi
done

echo "== 表示専用: 候補が利用枠でも制御の分類は変わらない =="

# codex の利用枠のエラー行は抜粋の外にしか無い。制御の分類は抜粋だけを見るので、候補が利用枠を
# 示しても同じ CLI の残りの観点はスキップされない（--sequential は失敗のたびにスキップを判定する経路）。
printf '%s\n' credits > "$TMP/mode"
: > "$TMP/codex-runs"
rm -rf "$OUT"
set +e
( cd "$REPO" && run_isolated PATH="$STUB:/usr/bin:/bin" CODEX_HOME="$TMP" \
    FF_TIMEOUT_KILL_GRACE=1 FF_DEV_TOOLKIT_SKIP=codex-auto-update MULTI_AGENT_LANE_PRECHECK=off \
    bash "$MULTI_AGENT" --task review --cli codex-cli --perspective code-review,comment-analysis \
      --sequential --base develop --timeout 30 --output-dir "$OUT" ) >"$TMP/run.log" 2>&1
RUN_RC=$?
set -e
RES="$OUT/codex-cli/code-review.md"
CODEX_RUNS="$( (wc -l < "$TMP/codex-runs" 2>/dev/null || echo 0) | tr -d ' ')"
if [ "$RUN_RC" -ne 0 ] && [ "${CODEX_RUNS:-0}" -eq 2 ] && ! /usr/bin/grep -qF '⏭ Skipped' "$TMP/run.log" \
   && /usr/bin/grep -qF '> Stop reason candidate: `billing` (estimated)' "$RES"; then
  ok "sequential: 候補は利用枠（推定）と表示しつつ、同じ CLI の残りの観点をスキップしない（起動 ${CODEX_RUNS} 回）"
else
  bad "sequential: rc=${RUN_RC} codex=${CODEX_RUNS}（表示用の候補が制御へ流れた）"; show
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "✓ stop-reason-evidence verify: 全 ${PASS} 件 pass"
  FF_REACHED_END=1
  exit 0
fi
echo "✗ stop-reason-evidence verify: ${FAIL} 件失敗（pass ${PASS} 件）" >&2
FF_REACHED_END=1
exit 1
