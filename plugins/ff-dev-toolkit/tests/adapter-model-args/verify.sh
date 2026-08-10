#!/usr/bin/env bash
#
# アダプタが CLI へ実際に渡す argv の検証（Issue #239）。
#
# tests/no-hardcoded-model/ は「モデル slug が書かれていないこと」を静的に見るが、
# 静的検査では次のような「機能が丸ごと届かない」変化を捕まえられない:
#   - env 変数名の打ち間違い（MULTI_AGENT_MODEL_GEMINI_CLI → ..._GEMENI_CLI）
#   - フラグ名の取り違え（codex の -m を --model に変える）
#   - 組み立てた MODEL_ARGS を起動行で展開し忘れる
#   - 値の語分割（"gpt 5x" のような空白入りの値が 2 引数に割れる）
# これらはすべて「設定したのに効かない」形の沈黙した後退で、成果物からは判別
# できない。argv を実測して契約を固定する（ACE-36-1 の
# 「argv 記録スタブでないと語分割の退化を検出できない」を踏襲）。
#
# 実 CLI は起動しない。PATH の先頭に argv を記録するだけの stub を置く。
# 課金もネットワークアクセスも発生しない。
#
# 検査ケースの env 変数名はこのファイル内にリテラルで書く。これが
# skills/multi-review/SKILL.md の表と実装の間の突き合わせになり、実装側だけ
# 変数名を変えると red になる（例外は実行環境からの分離リストのみ — そちらは
# 実装からの動的抽出で、突き合わせではなく網羅が目的。下の分離ブロック参照）。
#
# 一時ディレクトリと git リポジトリを要求するので、いずれかが使えない環境では
# 行頭 `○ skip` を出して exit 0 する（部分 skip はしない — 検査は全件走るか
# 1 件も走らないかのどちらか）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
PERSPECTIVE="$PLUGIN_ROOT/scripts/perspectives/review/code-review.md"

echo "== アダプタが渡す argv の検証 =="

if [ ! -f "$PERSPECTIVE" ]; then
  echo "○ skip: perspective ファイルが見つかりません（本 suite の検査は1件も実行されていません）: $PERSPECTIVE"
  exit 0
fi

if ! git -C "$PLUGIN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "○ skip: git リポジトリ外のため実行できません（本 suite の検査は1件も実行されていません）"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-adapter-argv.XXXXXX" 2>/dev/null)" || WORK=""
if [ -z "$WORK" ]; then
  echo "○ skip: 一時ディレクトリを作成できません（本 suite の検査は1件も実行されていません）"
  exit 0
fi
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- stub CLI 群 ---------------------------------------------------------------
# argv を <arg> 区切りで記録する。単純な空白連結だと "gpt 5x" が 2 引数へ割れても
# 記録が同じに見えてしまい、語分割の退化を検出できない（ACE-36-1）。
mkdir -p "$WORK/bin"
for cli in claude codex gemini copilot grok; do
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do printf "<%s>" "$a" >> "$ARGV_LOG"; done'
    echo 'printf "\n" >> "$ARGV_LOG"'
    echo 'echo "stub review output"'
  } > "$WORK/bin/$cli"
  chmod +x "$WORK/bin/$cli"
done

# ---- 実行環境からの分離（Issue #374 で導入、#378 で lib へ共通化） ----------------
# MULTI_AGENT_MODEL_* / MULTI_AGENT_CODEX_PROFILE は利用者が設定する正規の設定つまみ
# なので、export 済みの環境で走らせると「env 未設定」ケースの前提が崩れて恒常赤になる。
# アダプタ起動時に env -u で明示的に取り除き、前提を仮定するのではなく作る。
# 抽出・fail-closed の設計は lib 側ヘッダー参照（本 suite が初出、PR #379）。
# センチネルの変数名リテラルは env 上書きケース側と重複するが、それ自体が実装との
# 突き合わせになる — ファイル冒頭コメントの方針と同じ。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env MULTI_AGENT_MODEL_CLAUDE_CODE "$ADAPTERS_DIR"/*.sh

# ---- 実行ヘルパー ---------------------------------------------------------------
# run_adapter <adapter ファイル名> [VAR=VALUE ...]
# 記録した argv を RUN_ARGV に、終了コードを RUN_RC に入れる。
# 継承環境の MULTI_AGENT_* は ISOLATE_ENV で除去する。env は -u の除去を先に、
# NAME=VALUE の代入を後に適用するため、ケース固有の上書き（"$@"）はそのまま効く。
# GROK_HOME も同じクラスの実行環境つまみ（未設定だと grok アダプタが $HOME 配下へ
# fallback し、ホストの実イベントログを読む）なので、常にスクラッチへ向ける。
mkdir -p "$WORK/grok-home-empty"
RUN_ARGV=""
RUN_RC=0
run_adapter() {
  local adapter="$1"; shift
  : > "$WORK/argv.log"
  # implement は staging の実パス（または --inline-output）が要る（Issue #392）。
  # 渡さない implement は build_prompt が fail-loud で拒否するため、CLI が
  # 起動せず argv が空になる。ここは実行経路に近い方 = staging を渡す形にする。
  local task_args=()
  if [ "${RUN_TASK_TYPE:-review}" = "implement" ]; then
    mkdir -p "$WORK/staging"
    task_args=(--staging-dir "$WORK/staging")
  fi
  if run_isolated \
       PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" CODEX_HOME="$WORK/codex" \
       GROK_HOME="${RUN_GROK_HOME:-$WORK/grok-home-empty}" "$@" \
       bash "$ADAPTERS_DIR/$adapter" "$PERSPECTIVE" "$WORK/out.md" \
       --base HEAD --timeout 30 --task-type "${RUN_TASK_TYPE:-review}" \
       ${task_args[@]+"${task_args[@]}"} \
       --description "stub task" >"$WORK/stdout.log" 2>"$WORK/stderr.log"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
  RUN_ARGV="$(cat "$WORK/argv.log")"
}

# expect_argv_has <説明> <期待する部分文字列>
expect_argv_has() {
  if [ "$(printf '%s\n' "$RUN_ARGV" | grep -c -F -- "$2")" -gt 0 ]; then
    ok "$1"
  else
    bad "$1 — argv に '$2' が無い"
    printf '%s\n' "$RUN_ARGV" | sed 's/^/    | /' >&2
  fi
}

# expect_argv_lacks <説明> <現れてはいけない部分文字列>
expect_argv_lacks() {
  if [ "$(printf '%s\n' "$RUN_ARGV" | grep -c -F -- "$2")" -gt 0 ]; then
    bad "$1 — argv に '$2' がある"
    printf '%s\n' "$RUN_ARGV" | sed 's/^/    | /' >&2
  else
    ok "$1"
  fi
}

# expect_launched <説明>
# lacks 系しか見ないケースは、env の起動自体が失敗して argv が空のままでも「無い」
# 判定で真空 PASS する（stub は起動されれば必ず argv を記録するので、空 = CLI 未起動）。
# 起動の成立を明示的に固定して、個別行が「検証した」と嘘をつく穴を塞ぐ。
# 注意: 全ケース一律には掛けない — 「プロファイル不在なら CLI を起動しない」のように
# 空 argv が正であるケースが存在する。
expect_launched() {
  if [ -n "$RUN_ARGV" ]; then
    ok "$1"
  else
    bad "$1 — argv 記録が空（CLI が起動していない。rc=${RUN_RC}）"
  fi
}

# ---- 既定（env 未設定）: 変更前と同じ argv であること ----------------------------
# 各 CLI で expect_launched を先に置く。grok だけは直後の --sandbox 肯定検査が
# 起動の成立を兼ねるため不要。
run_adapter claude-code-adapter.sh
expect_launched "claude-code: 既定ケースで CLI が起動している"
expect_argv_lacks "claude-code: env 未設定ならモデルフラグを渡さない" "<--model>"

run_adapter codex-cli-adapter.sh
expect_launched "codex-cli: 既定ケースで CLI が起動している"
expect_argv_lacks "codex-cli: env 未設定ならモデルフラグを渡さない" "<-m>"
expect_argv_lacks "codex-cli: env 未設定ならプロファイルフラグを渡さない" "<-p>"

run_adapter gemini-cli-adapter.sh
expect_launched "gemini-cli: 既定ケースで CLI が起動している"
expect_argv_lacks "gemini-cli: env 未設定ならモデルフラグを渡さない" "<-m>"

run_adapter copilot-cli-adapter.sh
expect_launched "copilot-cli: 既定ケースで CLI が起動している"
expect_argv_lacks "copilot-cli: env 未設定ならモデルフラグを渡さない" "<--model>"

run_adapter grok-cli-adapter.sh
expect_argv_lacks "grok-cli: env 未設定ならモデルフラグを渡さない" "<-m>"
# read-only 保証はプロファイル名まで含めて固定する。`--sandbox` を渡していても
# プロファイルが workspace なら CWD へ書けるので、フラグの有無だけでは足りない。
expect_argv_has "grok-cli: review では --sandbox read-only を渡す" "<--sandbox><read-only>"

# ---- 分離の自己検証 ---------------------------------------------------------------
# run_adapter から ISOLATE_ENV の適用が落ちる退行を検出する。ホスト環境の汚染を
# 意図的に再現し、除去されることを固定する（Issue #374 の再発は「設定済み環境で
# だけ恒常赤」という形で現れ、クリーンな CI では見えない — だから汚染をここで作る）。
# 関数呼び出しへの前置代入は呼び出しの間だけ子プロセスへ export され、終了後は
# 復元されるため後続ケースを汚染しない。
MULTI_AGENT_MODEL_CLAUDE_CODE=polluted-from-host run_adapter claude-code-adapter.sh
expect_launched "isolation: 自己汚染ケースで CLI が起動している"
expect_argv_lacks "isolation: 継承環境の MULTI_AGENT_* が除去される" "<--model>"

# ---- env による上書き ------------------------------------------------------------
run_adapter claude-code-adapter.sh MULTI_AGENT_MODEL_CLAUDE_CODE=opus
expect_argv_has "claude-code: MULTI_AGENT_MODEL_CLAUDE_CODE が --model に届く" "<--model><opus>"

run_adapter codex-cli-adapter.sh MULTI_AGENT_MODEL_CODEX_CLI=some-model
expect_argv_has "codex-cli: MULTI_AGENT_MODEL_CODEX_CLI が -m に届く" "<-m><some-model>"

run_adapter gemini-cli-adapter.sh MULTI_AGENT_MODEL_GEMINI_CLI=some-model
expect_argv_has "gemini-cli: MULTI_AGENT_MODEL_GEMINI_CLI が -m に届く" "<-m><some-model>"

run_adapter copilot-cli-adapter.sh MULTI_AGENT_MODEL_COPILOT_CLI=auto
expect_argv_has "copilot-cli: MULTI_AGENT_MODEL_COPILOT_CLI が --model に届く" "<--model><auto>"

run_adapter grok-cli-adapter.sh MULTI_AGENT_MODEL_GROK_CLI=some-model
expect_argv_has "grok-cli: MULTI_AGENT_MODEL_GROK_CLI が -m に届く" "<-m><some-model>"

# 空白入りの値が 1 引数に保たれること。文字列連結 + 非クォート展開への退化は
# ここでしか検出できない（静的検査は形が同じなので通る）。
run_adapter gemini-cli-adapter.sh "MULTI_AGENT_MODEL_GEMINI_CLI=model with spaces"
expect_argv_has "gemini-cli: 空白を含むモデル名が 1 引数に保たれる" "<-m><model with spaces>"

# ---- codex のプロファイル経路 -----------------------------------------------------
mkdir -p "$WORK/codex"
: > "$WORK/codex/review.config.toml"

run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_PROFILE=review
expect_argv_has "codex-cli: 実在するプロファイルが -p に届く" "<-p><review>"

# codex は存在しないプロファイル名を黙って無視し base config で完走する。
# ラッパー側で落とさないと「専用プロファイルで走らせたつもり」が成立してしまう。
run_adapter codex-cli-adapter.sh MULTI_AGENT_CODEX_PROFILE=no_such_profile
if [ "$RUN_RC" -ne 0 ]; then
  ok "codex-cli: プロファイルのファイルが無ければ非 0 で落ちる（黙って base config で走らない）"
else
  bad "codex-cli: プロファイル不在なのに成功した（rc=0）"
fi
expect_argv_lacks "codex-cli: プロファイル不在なら CLI を起動しない" "<exec>"

# -m と -p の併用は、-m のモデルがプロファイルのモデルに勝ち effort だけ
# プロファイル由来という不整合を生むので落とす。
run_adapter codex-cli-adapter.sh MULTI_AGENT_MODEL_CODEX_CLI=some-model MULTI_AGENT_CODEX_PROFILE=review
if [ "$RUN_RC" -ne 0 ]; then
  ok "codex-cli: モデルとプロファイルの同時指定を非 0 で拒否する"
else
  bad "codex-cli: モデルとプロファイルの同時指定が素通りした（rc=0）"
fi

# ---- grok: タスク種別ごとの sandbox プロファイル -----------------------------------
# `--sandbox` が付いているかだけを見ても保証にならない。read-only と workspace は
# CWD へ書けるかどうかが違うので、**プロファイル名まで**固定する。逆に implement は
# 成果物を書けないと機能しないため、read-only へ寄せる退行も落とす必要がある。
RUN_TASK_TYPE=explore run_adapter grok-cli-adapter.sh
expect_argv_has "grok-cli: explore でも --sandbox read-only" "<--sandbox><read-only>"

RUN_TASK_TYPE=implement run_adapter grok-cli-adapter.sh
expect_argv_has "grok-cli: implement では --sandbox workspace（成果物の書き込みに必要）" "<--sandbox><workspace>"
expect_argv_lacks "grok-cli: implement で read-only へ寄せない" "<--sandbox><read-only>"

# ---- grok: サンドボックス適用の肯定確認 -------------------------------------------
# このアダプタを作業ツリーに向けて走らせてよい根拠はサンドボックスだけなので、
# 「警告が出ていないこと」ではなく「適用イベントが出ていること」で判定する。
#
# stub に渡す文字列は **grok バイナリから抽出した実物**であって、こちらで考えた
# 文言ではない（`strings ~/.grok/bin/grok | grep -i sandbox` で確認できる）。
# 初版はアダプタが想定した文言を stub にも書いたため、ガードとテストが同じ誤解で
# 合意して常に緑だった（ACE-249-1 と同型）。
#   実物1: "warning: sandbox could not be applied:"  → CLI が exit 1 で起動を拒否
#   実物2: "Sandbox could not be applied, continuing without sandbox"
#                                                    → サンドボックス無しで続行
# 危険なのは 2 の方で、初版のガードはこれに一致しなかった。
GROK_EVENTS_HOME="$WORK/grok-home"
mkdir -p "$GROK_EVENTS_HOME"

# grok stub を差し替える。$1 = CLI 起動時に追加で行う副作用
make_grok_stub() {
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do printf "<%s>" "$a" >> "$ARGV_LOG"; done'
    echo 'printf "\n" >> "$ARGV_LOG"'
    echo "$1"
    echo 'echo "stub review output"'
  } > "$WORK/bin/grok"
  chmod +x "$WORK/bin/grok"
}

# 実際に grok が書く形（timestamp が先頭、enforced は末尾寄り）。フィールド順に
# 依存する判定を書くと、この形で正常系が落ちる（初版がそうだった）。
emit_applied='mkdir -p "$GROK_HOME"; printf "%s\n" "{\"timestamp\":\"2026-08-02T00:00:00Z\",\"event_type\":\"ProfileApplied\",\"profile\":\"read-only\",\"workspace\":\"$(pwd -P)\",\"platform\":\"macos/seatbelt\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"'

grok_case() { # <説明> <stub の副作用> <期待 rc: ok|fail>
  make_grok_stub "$2"
  RUN_GROK_HOME="$GROK_EVENTS_HOME" run_adapter grok-cli-adapter.sh
  if [ "$3" = "ok" ]; then
    if [ "$RUN_RC" -eq 0 ] && grep -qF "<!-- Status: complete -->" "$WORK/out.md" 2>/dev/null; then
      ok "$1"
    else
      bad "$1（rc=${RUN_RC}）"
    fi
  else
    if [ "$RUN_RC" -ne 0 ] && grep -qF "<!-- Status: incomplete -->" "$WORK/out.md" 2>/dev/null; then
      ok "$1"
    else
      bad "$1（rc=${RUN_RC}。サンドボックス未確認の結果を complete として受け取った）"
    fi
  fi
}

grok_case "grok-cli: ProfileApplied があれば complete として通す" "$emit_applied" ok
grok_case "grok-cli: 適用イベントが無ければ結果を受け取らない（未適用と区別できない）" 'true' fail
grok_case "grok-cli: 実物の「warn して続行」文字列を検出する" \
  'echo "Sandbox could not be applied, continuing without sandbox" >&2' fail
grok_case "grok-cli: ApplyFailed が混ざっていれば受け取らない" \
  "$emit_applied"'; printf "%s\n" "{\"event_type\":\"ApplyFailed\",\"profile\":\"read-only\"}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# fail-open の 3 経路。どれも「サンドボックスが効いた」と誤判定する向きなので、
# 見逃すと無サンドボックスのレビューが complete として通る。いずれも実測で再現済み。
#
# (a) 前回実行が残したイベントで確認が成立する経路。baseline を取れないときに 0 で
#     代用すると `tail -n +1` がファイル全体を「この実行の追記分」として返す。
printf '%s\n' '{"timestamp":"old","event_type":"ProfileApplied","profile":"read-only","enforced":true}' \
  > "$GROK_EVENTS_HOME/sandbox-events.jsonl"
grok_case "grok-cli: 前回実行が残したイベントでは確認としない" 'true' fail

# (b) 3 条件が別々の行で成立する経路。条件ごとに grep を分けると、無関係な行の
#     組み合わせで「該当プロファイルが enforced で適用された」と読めてしまう。
grok_case "grok-cli: 条件が別々の行に散っていれば確認としない" \
  'mkdir -p "$GROK_HOME"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"workspace\",\"enforced\":false}" "{\"event_type\":\"Heartbeat\",\"profile\":\"read-only\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# (c) 別プロファイルが適用された場合。read-only を要求したのに workspace が
#     適用されていたら、要求した保証は成立していない。
grok_case "grok-cli: 別プロファイルの適用イベントでは確認としない" \
  'mkdir -p "$GROK_HOME"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"workspace\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# (d) フィールド順が変わっても正常系は通ること。順序依存の判定にすると、ベンダーが
#     JSON の並びを変えただけで全レビューが落ちる（fail-closed だが実質使えなくなる）。
# (e) 同じイベントログを共有する別プロセスの成功イベントを、自分の証明として
#     受け取らないこと。行数の差分だけでは並行実行を切り分けられない。
grok_case "grok-cli: 別 workspace の適用イベントでは確認としない（並行実行の混線）" \
  'mkdir -p "$GROK_HOME"; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"read-only\",\"workspace\":\"/some/other/repo\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# (f) 自分の適用イベントが**ある上で**、同じ窓に別プロファイルの適用も並ぶ場合。
#     肯定条件だけを見ると通ってしまう（実ログでは 107ms の間に 3 プロファイルの
#     適用が並ぶことがある）。要求より広いプロファイルが同時に効いていたなら、
#     要求した保証は成立していない。失格条件は肯定の裏返しで対称に置く。
grok_case "grok-cli: 自分の適用があっても別プロファイルが同じ窓にあれば失格" \
  "$emit_applied"'; printf "%s\n" "{\"event_type\":\"ProfileApplied\",\"profile\":\"workspace\",\"workspace\":\"$(pwd -P)\",\"enforced\":true}" >> "$GROK_HOME/sandbox-events.jsonl"' fail

# (g) サンドボックスが実際に操作を止めた記録（FsViolation）は**失格にしない**。
#     これは機能している証拠であって失敗ではない。ここを失格にすると、書き込みを
#     試みた差分をレビューするたびに結果が捨てられる。
grok_case "grok-cli: FsViolation は失格にしない（サンドボックスが働いた証拠）" \
  "$emit_applied"'; printf "%s\n" "{\"event_type\":\"FsViolation\",\"operation\":\"write\",\"target\":\"/x\"}" >> "$GROK_HOME/sandbox-events.jsonl"' ok

grok_case "grok-cli: イベントのフィールド順が変わっても確認できる" \
  'mkdir -p "$GROK_HOME"; printf "%s\n" "{\"enforced\":true,\"workspace\":\"$(pwd -P)\",\"profile\":\"read-only\",\"event_type\":\"ProfileApplied\"}" >> "$GROK_HOME/sandbox-events.jsonl"' ok


# 拒否時の報告内容。CLI は 0 で終了し結論にも到達しているので、
# 「CLI が status 1 で落ちた」と書くと読み手は存在しないクラッシュを追う。
#
# 直前の実行結果に依存させない。ケースを足す順番が変わっただけで検査対象が
# 別の成果物にすり替わり、実際に一度壊れた。拒否ケースをここで明示的に一度走らせる。
make_grok_stub 'true'
RUN_GROK_HOME="$GROK_EVENTS_HOME" run_adapter grok-cli-adapter.sh
if grep -qF "sandbox" "$WORK/out.md" 2>/dev/null && ! grep -qF "exited with status 1" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: サンドボックス未確認を CLI のクラッシュとして報告しない"
else
  bad "grok-cli: サンドボックス未確認が CLI のクラッシュとして報告されている（原因の指し先が誤り）"
fi

# exit 0 + 空出力でも stderr を捨てない。捨てると「なぜ空か」を言う唯一のチャネルが消える。
make_grok_stub "$emit_applied"'; echo "error: rate limit exceeded" >&2'
# 出力を空にする stub（上の echo を打ち消すため専用に組む）
{
  echo '#!/usr/bin/env bash'
  echo 'for a in "$@"; do printf "<%s>" "$a" >> "$ARGV_LOG"; done'
  echo 'printf "\n" >> "$ARGV_LOG"'
  echo "$emit_applied"
  echo 'echo "error: rate limit exceeded" >&2'
} > "$WORK/bin/grok"
chmod +x "$WORK/bin/grok"
RUN_GROK_HOME="$GROK_EVENTS_HOME" run_adapter grok-cli-adapter.sh
if [ "$RUN_RC" -ne 0 ] && grep -qF "rate limit exceeded" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: 空出力でも CLI の stderr を成果物に残す（原因が失われない）"
else
  bad "grok-cli: 空出力時に stderr を捨てている（なぜ空かを言うチャネルが消える）"
fi
# stderr 抜粋が残っても、見出しが「CLI が status 1 で落ちた／止められた」のままだと
# 読み手は存在しないクラッシュを追う。CLI は 0 で終了し、止められてもいない。
if grep -qF "exited successfully but produced no output" "$WORK/out.md" 2>/dev/null \
  && ! grep -qF "exited with status 1" "$WORK/out.md" 2>/dev/null \
  && ! grep -qF "before the CLI was stopped" "$WORK/out.md" 2>/dev/null; then
  ok "grok-cli: 空出力をクラッシュ／中断として報告しない"
else
  bad "grok-cli: 空出力が「CLI が落ちた／止められた」と報告されている（原因の指し先が誤り）"
fi

# 通常の stub に戻す（後続のヘルパー検査へ影響させない）
make_grok_stub "$emit_applied"

# ---- ヘルパーの第 3 引数（ベンダー中立な既定値） -----------------------------------
# この経路を使うアダプタは無い。唯一の利用者だった cursor-cli の `auto` は issue #240
# で消えたが、API は残っている。アダプタ経由で検査できなくなった以上ヘルパー単体で
# 挙動を固定しておかないと、次に既定値を持つ CLI を足す人が誰も検証していない土台の
# 上に書くことになる（検査を消すのではなく層を下げる）。
#
# 第 3 引数に書いてよいのは `auto` のようなベンダー中立語だけ。具体的なモデル slug を
# 書くことは tests/no-hardcoded-model/verify.sh 側が静的に禁じている。
helper_model_args() {
  ( set -euo pipefail
    # shellcheck disable=SC1090
    . "$ADAPTERS_DIR/adapter-common.sh"
    reset_model_args
    add_model_arg "$@"
    for a in ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}; do printf "<%s>" "$a"; done )
}

expect_helper() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$desc"
  else
    bad "$desc — expected '$expected' / actual '$actual'"
  fi
}

expect_helper "add_model_arg: env 未設定なら第 3 引数の既定値を渡す" \
  "<--model><auto>" \
  "$(helper_model_args --model FF_TEST_MODEL_UNSET auto)"

expect_helper "add_model_arg: env 指定が第 3 引数の既定値を上書きする" \
  "<--model><some-model>" \
  "$(FF_TEST_MODEL_SET=some-model helper_model_args --model FF_TEST_MODEL_SET auto)"

expect_helper "add_model_arg: 第 3 引数が無く env も未設定ならフラグ自体を渡さない" \
  "" \
  "$(helper_model_args --model FF_TEST_MODEL_UNSET)"

# ---- ヘルパーの入力検証 -----------------------------------------------------------
# env 変数名でない第 2 引数（呼び出し側のバグ）は沈黙せず非 0 を返す。
if ( set -euo pipefail
     # shellcheck disable=SC1090
     . "$ADAPTERS_DIR/adapter-common.sh"
     reset_model_args
     add_model_arg --model "BAD-NAME" ) >/dev/null 2>&1; then
  bad "add_model_arg: 不正な env 変数名を黙って受け入れた"
else
  ok "add_model_arg: 不正な env 変数名を非 0 で拒否する"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ adapter-model-args verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ adapter-model-args verify: 全 $PASS 件 pass"
