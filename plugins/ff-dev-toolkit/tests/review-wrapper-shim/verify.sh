#!/usr/bin/env bash
#
# 同梱レビューラッパー（シム）の契約検査（Issue #406）。
#
# 潰している事故は 2 つある。
#
# (1) **`codex exec` を同期で直接叩くラッパー**。codex は stdin が TTY でないと
#     「追加入力」として読みに行き、EOF が来るまでブロックする。stdout には何も
#     出ないので、外からはハングと区別がつかない。実測（codex-cli 0.144.5）:
#       codex exec -s read-only "..." </dev/null  → rc=0 / 9 秒で完走
#       同上・stdin を開いたまま同期実行          → 60 秒でタイムアウト。
#                                                  stderr は "Reading additional
#                                                  input from stdin..." のみ
#     実際にこれを踏み、長時間かけて「Codex 未応答」と誤診した経緯がある。
#     消費プロジェクトが自前で持っていた旧ラッパーには、今もこの形のものがある。
#
#     同梱するシムは `multi-agent.sh` へ委譲するので、CLI の起動は
#     `run_with_timeout` 経由になる。あちらは `"$@" >"$out_file" &` と**非同期**で
#     子を起動し、POSIX により非対話シェルの非同期リストの stdin は /dev/null に
#     割り当てられる（実測: 同期 15 秒ブロック / 非同期 0 秒）。つまり委譲している
#     限り罠は構造的に起きない。**だから「直接叩いていないこと」を固定する**。
#
# (2) **黙って無視されるオプション・環境変数**。シムは薄いので、既存コピーが持って
#     いた機能の大半を持たない。渡されたものを黙って捨てると、利用者は指定したつもり
#     のまま既定設定でレビューが走り、成果物からもログからも判別できない
#     （ACE-70-2 が記録した実害と同じ形）。受け取れないものは非 0 で拒否し、
#     対応する `multi-agent.sh` の経路を案内する。
#
# 検出器は静的走査（実 CLI 不要）。効くことは fixture で先に確かめる —
# 「直接叩く」形を検出できない検出器は、本体を通しても何も保証しない。
# 振る舞い（オプションの写し・拒否・skip）は stub の multi-agent.sh で実測する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
SHIM="$PLUGIN_ROOT/scripts/templates/codex-review.sh"
SETUP="$PLUGIN_ROOT/scripts/setup-multi-agent.sh"
SUITE_NAME="review-wrapper-shim"

echo "== 同梱レビューラッパー（シム）の契約 =="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-review-shim.XXXXXX" 2>/dev/null)" || WORK=""
if [ -z "$WORK" ]; then
  echo "○ skip: 一時ディレクトリを作成できません（本 suite の検査は1件も実行されていません）"
  exit 0
fi

# 途中死を rc=0 で終わらせない（ACE-404-2）。trap 最終コマンドの成功ステータスが
# suite の終了ステータスを上書きし、set -u の死では突入時点の $? が既に 0 になる。
FF_REACHED_END=0
ff_cleanup() {
  ff_rc=$?
  rm -rf "$WORK"
  if [ "$FF_REACHED_END" != "1" ] && [ "$ff_rc" -eq 0 ]; then
    echo "✗ ${SUITE_NAME} verify: 末尾に到達せず終了した（set -e / set -u による途中死。残りのアサーションは 1 件も実行されていない）" >&2
    ff_rc=1
  fi
  exit "$ff_rc"
}
trap ff_cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ── 検出器: AI CLI を直接起動していないか ────────────────────────────────────────
#
# 走査対象は「コメントを除いた実行行」。コメントで `codex exec` に言及するのは
# 正当（このファイル自身がそうしている）。
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
# 限界（承知のうえ・**実測で確認した現在の穴**）:
#   - 変数越しの起動（`CLI=codex; "$CLI" exec`）とバックスラッシュ行継続は静的走査では追えない
#   - **改行をまたぐ文字列**（`x="1 行目<改行>2 行目"`）は追えない。クォート状態を行ごとに
#     初期化しているため。持ち越す実装にすると、ファイル内に不均衡なクォートが 1 つあった
#     だけで**そこから先が全部クォート内扱いになり検出器が丸ごと盲目になる**ので、
#     より広い fail-open を避けてこちらを選んでいる
#   - **heredoc 本文**はモデル化していない。本文中の `#` はコメントではないが、そう扱う
#   - 文字列リテラルの中身は走査対象のまま。実行しない言及も違反として拾う（別 Issue）
# `${var#pat}` と文字列内の `#` は**追えるようになった**（下の除去器を参照）。
# シムは短く直接的に書く前提で、上記は「レビューで見る」に委ねる。
detects_direct_cli() {
  local file="$1" stripped
  # 読めないファイルを「一致なし」と同じ答えにしない。sed|grep の rc は右端の
  # grep が支配するので、上流が失敗しても「clean」に見える（実測で読めない
  # ファイルが clean と報告された）。中間結果を受けてから判定する。
  # コメント除去はクォート状態を追う。`sed 's/#.*$//'` だと、クォートの中の # や
  # ${var#pat} の # まで切ってしまい、**同じ行の実行部分が走査対象から消える**。
  # 実測（旧実装）:
  #   base="${1#--base=}"; codex exec ...   → 残るのは `base="${1` だけ → 見逃し
  #   echo "see PR #406"; claude -p ...      → 行ごと消える           → 見逃し
  # 検出器が「読んだつもりで読んでいない」形なので、実際の違反を隠す方向に外れる。
  if ! stripped="$(awk '{
    line = $0; out = ""; inq = ""; ansi_c = 0; n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (inq == "") {
        # $'\'' は ANSI-C クォート。bash はこの中でも \ エスケープを解釈するので、
        # 素の '\'' と区別しないと \'\'' で閉じたと誤認し、以降がずれる（実測で見逃した）。
        if (c == "'"'"'") { inq = c; ansi_c = (i > 1 && substr(line, i - 1, 1) == "$"); out = out c; continue }
        if (c == "\"") { inq = c; ansi_c = 0; out = out c; continue }
        if (c == "\\") { out = out c; i++; if (i <= n) out = out substr(line, i, 1); continue }
        if (c == "#") {
          # コメントは行頭・空白の直後・制御演算子の直後に始まる。`true;# c` は bash では
          # コメントだが、空白だけを見ていると本文として残り誤検出する（実測）。
          # 一方 ${var#pat} や a#b はコメントではないので残す。
          if (i == 1) break
          prev = substr(line, i - 1, 1)
          if (prev == " " || prev == "\t") break
          if (prev == ";" || prev == "&" || prev == "|" || prev == "(") break
          out = out c; continue
        }
        out = out c
      } else {
        if ((inq == "\"" || ansi_c) && c == "\\") { out = out c; i++; if (i <= n) out = out substr(line, i, 1); continue }
        if (c == inq) { inq = ""; ansi_c = 0 }
        out = out c
      }
    }
    print out
  }' "$file" 2>/dev/null)"; then
    echo "DETECTOR-ERROR: 走査できません: ${file}" >&2
    return 2
  fi
  # CLI 名のあとにオプションが挟まる形も拾う。`codex -s read-only exec ...` は
  # 実在する書き方で、初版は exec/-p が直後に来る形しか見ていなかった（実測で素通り）。
  # 規則は「CLI 名が**コマンド位置に完全な語として**現れないこと」。exec/-p が直後に
  # 来る形だけを見ると、`codex -s read-only exec` のようにオプションを挟むだけで
  # 回避できた（実測）。オプションとその値を数え上げる正規表現は複雑で脆いので、
  # 語の出現そのものを禁じる方に倒す。委譲行の `--cli codex-cli` は語が codex-cli
  # なので一致せず、`MULTI_AGENT_MODEL_CODEX_CLI` も大文字なので一致しない。
  printf '%s\n' "$stripped" \
    | grep -nE '(^|[;&|(]|[[:space:]])([^[:space:];&|()]*/)?(codex|claude|gemini|copilot|grok)([[:space:]]|$)' \
    || return 1
}

echo "-- 検出器の自己検証（fixture） --"

mkdir -p "$WORK/fx"
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
  'echo "see PR #406"; claude -p "review"' \
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

# 制御演算子の直後から始まるコメント。空白の直後だけを見ていると本文として残り、
# 中の CLI 名を誤検出して**正常なラッパーを違反として止める**（実測）。
printf '%s\n' '#!/usr/bin/env bash' \
  'bash "$ORCH" --task review;# ここで codex exec を直接叩かない' \
  > "$WORK/fx/semicolon-comment.sh"
if detects_direct_cli "$WORK/fx/semicolon-comment.sh" >/dev/null 2>&1; then
  bad "検出器: 制御演算子直後のコメントを誤検出した（正常なラッパーを止める）"
else
  ok "検出器: 制御演算子直後のコメントは誤検出しない"
fi

# 逆方向: 本物のコメントは従来どおり誤検出しないこと（除去をやめただけの実装を弾く）。
printf '%s\n' '#!/usr/bin/env bash' \
  '# ここでは codex exec を直接叩かない（委譲する）' \
  'bash "$ORCH" --task review' \
  > "$WORK/fx/comment-mention.sh"
if detects_direct_cli "$WORK/fx/comment-mention.sh" >/dev/null 2>&1; then
  bad "検出器: コメント中の言及を誤検出した（コメント除去が効いていない）"
else
  ok "検出器: コメント中の言及は誤検出しない"
fi

# 走査できないファイルを「clean」と同じ答えにしない（fail-closed）。
printf '#!/usr/bin/env bash\ncodex exec "$p"\n' > "$WORK/fx/unreadable.sh"
chmod 000 "$WORK/fx/unreadable.sh"
_det_rc=0
detects_direct_cli "$WORK/fx/unreadable.sh" >/dev/null 2>&1 || _det_rc=$?
chmod 644 "$WORK/fx/unreadable.sh"
if [ "$_det_rc" -eq 2 ]; then
  ok "検出器: 読めないファイルを clean と報告せず走査失敗として区別する"
else
  bad "検出器: 読めないファイルの扱いが「一致なし」と同じ (rc=${_det_rc}) — 走査ゼロで緑になる"
fi

if detects_direct_cli "$WORK/fx/delegating.sh" >/dev/null; then
  bad "検出器: 委譲する fixture を誤検出した（コメント中の言及を拾っている）"
else
  ok "検出器: 委譲する fixture は誤検出しない"
fi

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

echo "-- 振る舞い（stub オーケストレータで実測） --"

# stub の multi-agent.sh: 受け取った argv を 1 引数 1 行で記録する。
PROJ="$WORK/proj"
mkdir -p "$PROJ/scripts" "$PROJ/orch"
cp "$SHIM" "$PROJ/scripts/codex-review.sh"
chmod +x "$PROJ/scripts/codex-review.sh"
# stub にもオーケストレータの印（--task / implement）を持たせる。シムは候補が
# 本当に multi-agent.sh かを検査するので、印の無い stub は正しく拒否される。
cat > "$PROJ/orch/multi-agent.sh" <<'SH'
#!/usr/bin/env bash
# stub orchestrator: --task review|explore|implement を受け付ける体裁
: > "$ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_LOG"; done
# env の写像を検査するため、委譲先から見えた値を記録する。argv だけを見ていると
# 「写したつもりで export していない」実装を素通しする（シムが exec で置き換わる
# 以上、env は argv と同じく委譲の一部）。
: > "$ENV_LOG"
for v in MULTI_AGENT_MODEL_CODEX_CLI MULTI_AGENT_CODEX_PROFILE CODEX_MODEL; do
  eval "_val=\${$v:-}"
  [ -n "$_val" ] && printf '%s=%s\n' "$v" "$_val" >> "$ENV_LOG"
done
echo "stub orchestrator ran"
SH
chmod +x "$PROJ/orch/multi-agent.sh"

RUN_RC=0
# run_shim [VAR=VALUE ...] [-- <シムへの引数> ...]
# 先頭の VAR=VALUE 群は env 代入として扱い、残りをシムの引数として渡す。
# 両者を混ぜて env へ丸投げすると `--base` が env 代入として解釈され rc=127 になる。
run_shim() {
  : > "$WORK/argv.log"
  RUN_RC=0
  local -a envs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Z_]*=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  : > "$WORK/env.log"
  # stdout と stderr を**分けて**記録する。合流させてから grep すると、通知が
  # stdout へ移っても検査が通ってしまう（pre-commit 等で stdout だけ捨てる構成では
  # 通知が消える）。既存の検査のために合流版も残す。
  env FF_DEV_TOOLKIT_ROOT="$PROJ/orch" ARGV_LOG="$WORK/argv.log" ENV_LOG="$WORK/env.log" \
    ${envs[@]+"${envs[@]}"} \
    bash "$PROJ/scripts/codex-review.sh" "$@" \
    >"$WORK/stdout.log" 2>"$WORK/err.log" </dev/null || RUN_RC=$?
  cat "$WORK/stdout.log" "$WORK/err.log" > "$WORK/out.log"
}
env_log_has() {
  grep -qxF "$1" "$WORK/env.log"
}
argv_has() {
  grep -qxF -- "$1" "$WORK/argv.log"
}
argv_has_seq() {
  # 連続する 2 行（フラグと値）が argv に現れるか
  awk -v a="$1" -v b="$2" 'prev == a && $0 == b { found = 1 } { prev = $0 } END { exit(found ? 0 : 1) }' \
    "$WORK/argv.log"
}

# 既定の documented 用法が素通しで届くこと
run_shim --base develop
if [ "$RUN_RC" -ne 0 ]; then
  bad "既定用法 (--base develop) が非 0 で終了した (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
else
  ok "既定用法 (--base develop) が成功する"
fi
if argv_has_seq "--task" "review" && argv_has_seq "--cli" "codex-cli"; then
  ok "task=review / cli=codex-cli が委譲先へ届く"
else
  bad "task=review / cli=codex-cli が委譲先へ届いていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
if argv_has_seq "--base" "develop"; then
  ok "--base の値が委譲先へ届く"
else
  bad "--base の値が委譲先へ届いていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# --reviewers は multi-agent.sh の --perspective へ写す（複数値は個別フラグへ展開）
run_shim --reviewers code-review,security-analysis
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "security-analysis"; then
  ok "--reviewers のカンマ区切りが --perspective へ 1 件ずつ展開される"
else
  bad "--reviewers が --perspective へ展開されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# --reviewers を**他のオプションと併用**する。単体で渡すケースしか見ていないと、
# 引数の並べ直しで後続を壊す実装を素通しする（実測: 初版は IFS=',' + 位置パラメータの
# set -- で後続を連結し、`--timeout 420` を 1 引数へ潰していた。単体テストは緑のまま、
# 実 CLI 実行で「対応しているはずの --timeout が拒否される」形で露見した）。
run_shim --base develop --reviewers code-review,test-analysis --timeout 420
if [ "$RUN_RC" -ne 0 ]; then
  bad "--reviewers を他オプションと併用すると非 0 で終了する (rc=$RUN_RC) — 引数の並べ直しで後続を壊している"
  sed 's/^/    | /' "$WORK/out.log" >&2
else
  ok "--reviewers を他オプションと併用できる"
fi
if argv_has_seq "--timeout" "420" && argv_has_seq "--base" "develop" \
   && argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "test-analysis"; then
  ok "併用時も --base / --timeout / 複数 --perspective がすべて委譲先へ届く"
else
  bad "併用時に一部のオプションが委譲先へ届いていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 受け取れないオプションは黙って捨てない
run_shim --no-such-option foo
if [ "$RUN_RC" -ne 0 ]; then
  ok "未対応オプションを非 0 で拒否する"
else
  bad "未対応オプションが素通りした（指定したつもりのまま既定設定でレビューが走る）"
fi
if grep -q -- "--no-such-option" "$WORK/out.log"; then
  ok "拒否メッセージが該当オプションを名指しする"
else
  bad "拒否メッセージが該当オプションを名指ししていない"
fi

# 旧ラッパーのモデル指定 env は、黙殺でも拒否でもなく**写像 + 通知**にする。
# 黙殺は「指定したつもりの設定が効かないまま走る」ACE-70-2 の形。拒否は安全だが、
# 移行対象の消費リポジトリがいずれもこれを設定していたため、拒否＝移行不能になる
# （件数はこのリポジトリからは検証できないので書かない）。
run_shim CODEX_MODEL=some-model
if [ "$RUN_RC" -eq 0 ]; then
  ok "CODEX_MODEL が設定されていても成功する（拒否ではなく写像する）"
else
  bad "CODEX_MODEL が設定されていると非 0 で落ちる (rc=$RUN_RC) — 移行できない"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if env_log_has "MULTI_AGENT_MODEL_CODEX_CLI=some-model"; then
  ok "CODEX_MODEL の値が MULTI_AGENT_MODEL_CODEX_CLI として委譲先へ届く"
else
  bad "CODEX_MODEL が委譲先へ届いていない（写したつもりで export していない）"
  sed 's/^/    | /' "$WORK/env.log" >&2
fi
if grep -q "MULTI_AGENT_MODEL_CODEX_CLI" "$WORK/out.log"; then
  ok "写像した旨が通知される（黙って読み替えない）"
else
  bad "写像が無言で行われた（利用者の指定と実際の設定が食い違っても気づけない）"
fi

# 新旧が同時指定された場合、黙って旧が勝つと移行途中の環境で古い設定が生き残る。
run_shim CODEX_MODEL=old-model MULTI_AGENT_MODEL_CODEX_CLI=new-model
if env_log_has "MULTI_AGENT_MODEL_CODEX_CLI=new-model"; then
  ok "新旧の同時指定では新（MULTI_AGENT_*）が優先される"
else
  bad "新旧の同時指定で旧が勝った（移行途中の環境で古い設定が生き残る）"
  sed 's/^/    | /' "$WORK/env.log" >&2
fi
if grep -q "CODEX_MODEL" "$WORK/out.log"; then
  ok "旧を無視した旨が通知される"
else
  bad "旧を無視したことが通知されない"
fi

# reasoning effort だけは写像先が 1:1 でない（プロファイルへ束ねる必要がある）ので、
# 推測で写さず拒否を維持する。機械変換できないものを写すと「指定したつもり」が
# 別の意味で通ってしまい、写像の趣旨に反する。
run_shim CODEX_REASONING_EFFORT=high
if [ "$RUN_RC" -ne 0 ]; then
  ok "CODEX_REASONING_EFFORT は写像先が 1:1 でないため拒否を維持する"
else
  bad "CODEX_REASONING_EFFORT が黙って通った（プロファイルへ束ねる必要がある）"
fi
if grep -q "MULTI_AGENT_CODEX_PROFILE" "$WORK/out.log"; then
  ok "拒否メッセージがプロファイルへの移行を案内する"
else
  bad "拒否メッセージが移行先を案内していない"
fi

# 旧ラッパーの既定観点 env。観点名の写像も併せて適用されること。
run_shim CODEX_DEFAULT_REVIEWERS=code-reviewer,comment-analyzer
if [ "$RUN_RC" -eq 0 ]; then
  ok "CODEX_DEFAULT_REVIEWERS が設定されていても成功する"
else
  bad "CODEX_DEFAULT_REVIEWERS で非 0 になった (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "comment-analysis"; then
  ok "CODEX_DEFAULT_REVIEWERS が観点名の写像つきで --perspective へ展開される"
else
  bad "CODEX_DEFAULT_REVIEWERS が --perspective へ展開されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 明示指定は env の既定より強い。逆だと「--reviewers を渡したのに env が勝つ」形になる。
run_shim CODEX_DEFAULT_REVIEWERS=code-reviewer --reviewers test-analysis
if argv_has_seq "--perspective" "test-analysis" \
   && ! argv_has_seq "--perspective" "code-review"; then
  ok "--reviewers の明示指定が CODEX_DEFAULT_REVIEWERS より優先される"
else
  bad "明示した --reviewers より env の既定が勝った"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# SKIP_CODEX_REVIEW=1 は既存の pre-commit 構成が使う実在の逃がし弁。
# 黙って無視すると「skip したはずのレビューが走る」ので、明示的に尊重する。
run_shim SKIP_CODEX_REVIEW=1
if [ "$RUN_RC" -eq 0 ]; then
  ok "SKIP_CODEX_REVIEW=1 は成功終了する"
else
  bad "SKIP_CODEX_REVIEW=1 が非 0 で終了した (rc=$RUN_RC)"
fi
if [ -s "$WORK/argv.log" ]; then
  bad "SKIP_CODEX_REVIEW=1 なのに委譲先が起動された"
  sed 's/^/    | /' "$WORK/argv.log" >&2
else
  ok "SKIP_CODEX_REVIEW=1 なら委譲先を起動しない"
fi

echo "-- setup による配置（冪等性） --"

if [ ! -f "$SETUP" ]; then
  bad "setup-multi-agent.sh が見つからない: $SETUP"
elif ! grep -q "install_review_wrappers" "$SETUP"; then
  bad "setup-multi-agent.sh に配置関数が無い（同梱しても消費プロジェクトへ届かない）"
else
  # 文字列の存在ではなく**実挙動**で見る。setup は末尾で BASH_SOURCE ガードを
  # 掛けているので、source しても main は走らない（依存導入も対話も起きない）。
  # grep で「上書き」「スキップ」という語を探すだけの検査は、語が別文脈で
  # 登場するだけで緑になる — 実際、この suite の初版はそれで真空 PASS した。
  TGT="$WORK/consumer"
  mkdir -p "$TGT"
  run_install() {
    ( set +e
      # shellcheck disable=SC1090
      . "$SETUP" >/dev/null 2>&1
      INSTALL_WRAPPERS_TARGET="$TGT" install_review_wrappers
    ) >"$WORK/install.log" 2>&1
  }

  # 1 回目: 新規配置
  if run_install && [ -f "$TGT/scripts/codex-review.sh" ]; then
    ok "setup: 新規プロジェクトへシムを配置する"
  else
    bad "setup: 新規配置に失敗した"
    sed 's/^/    | /' "$WORK/install.log" >&2
  fi
  if [ -x "$TGT/scripts/codex-review.sh" ]; then
    ok "setup: 配置したシムに実行ビットが立つ"
  else
    bad "setup: 配置したシムに実行ビットが無い"
  fi

  # 2 回目: 同一内容なら何もしない（冪等）
  if run_install && grep -q "スキップ" "$WORK/install.log"; then
    ok "setup: 同一内容の再実行はスキップと報告する"
  else
    bad "setup: 同一内容の再実行がスキップと報告されない"
    sed 's/^/    | /' "$WORK/install.log" >&2
  fi
  if [ ! -e "$TGT/scripts/codex-review.sh.bak" ]; then
    ok "setup: 同一内容なら退避ファイルを作らない"
  else
    bad "setup: 同一内容なのに退避ファイルを作った（毎回 .bak が増える）"
  fi

  # 3 回目: 利用者が手を入れた状態 → 黙って消さず退避してから置き換える
  printf '%s\n' '# ローカル改変' >> "$TGT/scripts/codex-review.sh"
  if run_install && [ -f "$TGT/scripts/codex-review.sh.bak" ] \
     && grep -q "ローカル改変" "$TGT/scripts/codex-review.sh.bak"; then
    ok "setup: 改変された既存ファイルを .bak へ退避してから置き換える"
  else
    bad "setup: 改変された既存ファイルを黙って消した（利用者の編集が失われる）"
    sed 's/^/    | /' "$WORK/install.log" >&2
  fi
  if grep -qE "退避|上書き" "$WORK/install.log"; then
    ok "setup: 上書きしたことを出力に残す"
  else
    bad "setup: 上書きが出力に現れない（静かな破壊）"
  fi
fi

echo "-- 本番経路（FF_DEV_TOOLKIT_ROOT を設定しない） --"

# ここまでの検査はすべて FF_DEV_TOOLKIT_ROOT を設定していた。それだけだと
# 「配置されたシムが自力でオーケストレータへ到達できるか」を一度も通らない。
FAKE="$WORK/fake-toolkit"
mkdir -p "$FAKE/scripts/templates" "$WORK/consumer2"
cp "$SETUP" "$FAKE/scripts/setup-multi-agent.sh"
cp "$SHIM" "$FAKE/scripts/templates/codex-review.sh"
cat > "$FAKE/scripts/multi-agent.sh" <<'SH'
#!/usr/bin/env bash
# stub orchestrator: --task review|explore|implement を受け付ける体裁
: > "$ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_LOG"; done
echo "fake orchestrator ran"
SH
chmod +x "$FAKE/scripts/multi-agent.sh"

# 配置は **main 経由**で確かめる。関数を直接呼ぶだけだと、production の呼び出し行を
# 削除しても緑のままになる（実測で生存した変異）。main は依存導入や実 CLI 検出を
# 走らせるので、その段だけ no-op に差し替えてから通す。
run_install_via_main() {
  local target="$1"
  ( set +e
    # shellcheck disable=SC1090
    . "$FAKE/scripts/setup-multi-agent.sh" >/dev/null 2>&1
    check_prerequisites() { :; }
    check_and_install_dependencies() { :; }
    detect_ai_clis() { :; }
    show_install_guides() { :; }
    run_verification() { :; }
    check_config() { :; }
    print_summary() { :; }
    print_header() { :; }
    INSTALL_WRAPPERS_TARGET="$target" main
  ) >"$WORK/install2.log" 2>&1
}
run_install_via_main "$WORK/consumer2"

PLACED="$WORK/consumer2/scripts/codex-review.sh"
SIDECAR="$WORK/consumer2/scripts/.ff-dev-toolkit-root"
if [ -f "$PLACED" ]; then
  ok "本番経路: main がシムを配置する（配線されている）"
else
  bad "本番経路: main を通してもシムが配置されない（呼び出しが配線されていない）"
  sed 's/^/    | /' "$WORK/install2.log" >&2
fi

# 比較は物理パスで行う。TMPDIR が末尾 / を持つと $WORK に // が混ざり、
# setup 側は cd+pwd で正規化した値を書くため、文字列比較だけだと食い違う。
_sidecar_want="$(cd "$FAKE/scripts" && pwd)"
_sidecar_got="$( [ -f "$SIDECAR" ] && cat "$SIDECAR" || true )"
if [ -n "$_sidecar_got" ] && [ "$(cd "$_sidecar_got" 2>/dev/null && pwd)" = "$_sidecar_want" ]; then
  ok "本番経路: サイドカーに toolkit の実パスが記録される"
else
  bad "本番経路: サイドカーが無い、または内容が不正（got=${_sidecar_got} want=${_sidecar_want}）"
fi

# シム本体は**どのマシンでも同一**であること。マシン固有の値が混ざると、git 管理下の
# scripts/ に入ったとき他人の環境や CI で壊れ、更新のたび .bak が増える。
if [ -f "$PLACED" ] && cmp -s "$SHIM" "$PLACED"; then
  ok "本番経路: 配置されたシムはテンプレートと同一（マシン固有の値を含まない）"
else
  bad "本番経路: 配置されたシムがテンプレートと異なる（マシン固有の値が焼き込まれている）"
fi

if [ -f "$PLACED" ]; then
  : > "$WORK/argv.log"
  PROD_RC=0
  env -u FF_DEV_TOOLKIT_ROOT ARGV_LOG="$WORK/argv.log" \
    bash "$PLACED" --base develop >"$WORK/prod.log" 2>&1 || PROD_RC=$?
  if [ "$PROD_RC" -eq 0 ]; then
    ok "本番経路: 環境変数なしでシムが完走する"
  else
    bad "本番経路: 環境変数なしで非 0 終了した (rc=$PROD_RC)"
    sed 's/^/    | /' "$WORK/prod.log" >&2
  fi
  if argv_has_seq "--base" "develop" && argv_has_seq "--cli" "codex-cli"; then
    ok "本番経路: サイドカー経由でオーケストレータへ引数が届く"
  else
    bad "本番経路: サイドカー経由で引数が届いていない"
    sed 's/^/    | /' "$WORK/argv.log" >&2
  fi

  # 環境変数はサイドカーに勝つこと。負けると、toolkit を移動・更新して
  # サイドカーが古くなったとき env で上書きできなくなる。
  mkdir -p "$WORK/alt-orch"
  cp "$FAKE/scripts/multi-agent.sh" "$WORK/alt-orch/multi-agent.sh"
  : > "$WORK/argv-alt.log"
  env FF_DEV_TOOLKIT_ROOT="$WORK/alt-orch" ARGV_LOG="$WORK/argv-alt.log" \
    bash "$PLACED" --base develop >/dev/null 2>&1 || true
  if [ -s "$WORK/argv-alt.log" ]; then
    ok "env と サイドカーが両方あるとき env が勝つ"
  else
    bad "env が指す先が使われていない（サイドカーが勝っている）"
  fi
fi

# skill 群が使う正規形（プラグインルート指定）で解決できること。
: > "$WORK/argv.log"
env FF_DEV_TOOLKIT_ROOT="$FAKE" ARGV_LOG="$WORK/argv.log" \
  bash "$PLACED" --base develop >/dev/null 2>&1 || true
if argv_has_seq "--cli" "codex-cli"; then
  ok "FF_DEV_TOOLKIT_ROOT にプラグインルートを渡す正規形で解決できる"
else
  bad "プラグインルート指定（skill 群が使う形）で解決できていない"
fi

# 配置先の既定（INSTALL_WRAPPERS_TARGET 未設定）は git のトップレベル。
# ここを検査しないと、既定値を別の場所へ変える変異が素通りする。
DEFAULT_REPO="$WORK/default-repo/sub"
mkdir -p "$DEFAULT_REPO"
git -C "$WORK/default-repo" init -q 2>/dev/null || true
( cd "$DEFAULT_REPO" && env -u INSTALL_WRAPPERS_TARGET bash -c '
    . "'"$FAKE"'/scripts/setup-multi-agent.sh" >/dev/null 2>&1
    install_review_wrappers' ) >"$WORK/install3.log" 2>&1 || true
if [ -f "$WORK/default-repo/scripts/codex-review.sh" ]; then
  ok "配置先の既定はリポジトリのトップレベル（サブディレクトリからでも正しい場所）"
else
  bad "配置先の既定がトップレベルでない（サブディレクトリ実行で迷子になる）"
  sed 's/^/    | /' "$WORK/install3.log" >&2
fi

echo "-- 旧観点名の互換 --"

run_shim --reviewers code-reviewer,silent-failure-hunter,type-design-analyzer
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "error-handler-hunt" \
   && argv_has_seq "--perspective" "type-design-analysis"; then
  ok "旧観点名が現行の perspective 名へ写される"
else
  bad "旧観点名が写されていない（対応表を示しながら実際には拒否される形になる）"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
if grep -q "旧観点名" "$WORK/out.log"; then
  ok "読み替えたことを通知する（黙って別の観点で走らない）"
else
  bad "読み替えを黙って行っている"
fi

# 写像表の 6 件を**1 件ずつ**検査する。まとめて 3 件だけ渡す上の検査は、写像表から
# 残り 3 件を削っても緑のまま通る（実測: comment-analyzer / pr-test-analyzer /
# code-simplifier はテストが 1 件も触れていなかった）。6 観点を使う消費リポジトリの
# 移行はこの 3 件に依存するので、削除・打ち間違いが即赤くなる形にする。
ALIAS_ITERATIONS=0
while IFS='|' read -r _old _new; do
  [ -n "$_old" ] || continue
  run_shim --reviewers "$_old"
  if [ "$RUN_RC" -ne 0 ]; then
    bad "旧観点名 '${_old}' で非 0 になった (rc=$RUN_RC)"
    sed 's/^/    | /' "$WORK/out.log" >&2
  elif argv_has_seq "--perspective" "$_new"; then
    ok "旧観点名 '${_old}' → '${_new}' が写される"
  else
    bad "旧観点名 '${_old}' が '${_new}' へ写されていない"
    sed 's/^/    | /' "$WORK/argv.log" >&2
  fi
  ALIAS_ITERATIONS=$((ALIAS_ITERATIONS + 1))
done <<'ALIASES'
code-reviewer|code-review
silent-failure-hunter|error-handler-hunt
type-design-analyzer|type-design-analysis
comment-analyzer|comment-analysis
pr-test-analyzer|test-analysis
code-simplifier|code-simplification
ALIASES

# ループが途中で終わっても PASS が減るだけで FAIL は 0 のまま — 「全 N 件 pass」と
# 緑で表示される（このスイートが塞いでいる fail-open を、検査側で再現してしまう形）。
# 現実的な中断経路は stdin の食い合いで、まさにこのスイートが存在する理由。
# run_shim 側で </dev/null を閉じたうえで、回った件数そのものを固定する。
if [ "$ALIAS_ITERATIONS" -eq 6 ]; then
  ok "写像表の 6 件すべてを回した（件数ガード）"
else
  bad "写像の検査が ${ALIAS_ITERATIONS} 件しか回っていない（6 件のはず）"
fi

# 現行の perspective 名はそのまま通ること（写像表が現行名まで書き換えないこと）
run_shim --reviewers comment-analysis,test-analysis,code-simplification
if argv_has_seq "--perspective" "comment-analysis" \
   && argv_has_seq "--perspective" "test-analysis" \
   && argv_has_seq "--perspective" "code-simplification"; then
  ok "現行の perspective 名はそのまま委譲される"
else
  bad "現行の perspective 名が書き換えられている"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 通知は stderr へ出すこと。pre-commit や npm script で stdout だけ捨てる構成でも
# 「読み替えが起きた」ことが残る必要がある。
run_shim CODEX_MODEL=some-model
if grep -q "MULTI_AGENT_MODEL_CODEX_CLI" "$WORK/err.log"; then
  ok "写像の通知が stderr へ出る"
else
  bad "写像の通知が stderr に無い（stdout を捨てる構成で通知が消える）"
  sed 's/^/    | /' "$WORK/stdout.log" >&2
fi

# 委譲先が実際に読む env 名は、レジストリ（get_cli_model_env_vars）が宣言している。
# シムはその名前を**文字列として持つ 4 つ目のコピー**なので、レジストリ側で改名すると
# シムだけが古い名前を export し、全レビューが黙って既定モデルで走る（ACE-70-2 の形）。
# 名前が食い違ったら赤くする。
# 抽出は関数本体へ限定する。`codex-cli)   echo "..."` は multi-agent.sh に 8 行あり、
# ファイル全体を舐めると別の case（CLI 名や adapter パス）を拾う。実際、初版は
# `echo "codex"` を拾い、シムに "codex" が含まれるので**素通しで緑**になっていた
# ——この検査自身が fail-open だった。
REGISTERED="$(awk '/^get_cli_model_env_vars\(\)/ { inf = 1 }
                   inf && /codex-cli\)/ { sub(/.*echo "/, ""); sub(/".*/, ""); print; exit }' \
  "$PLUGIN_ROOT/scripts/multi-agent.sh")"
# 抽出が壊れたことを「一致した」と読まないよう、形も確かめる。
case "$REGISTERED" in
  *MULTI_AGENT_*) ;;
  *) REGISTERED="" ;;
esac
if [ -z "$REGISTERED" ]; then
  bad "レジストリから codex-cli のモデル env 名を取得できなかった（この検査が成立していない）"
else
  _missing=""
  for _v in $REGISTERED; do
    grep -q "$_v" "$SHIM" || _missing="${_missing} ${_v}"
  done
  if [ -z "$_missing" ]; then
    ok "シムが参照する env 名がレジストリの宣言（${REGISTERED}）と一致する"
  else
    bad "レジストリが宣言する env 名をシムが参照していない:${_missing}"
  fi
fi

# 拒否経路では委譲先を一度も起動しないこと。終了コードと案内文だけを見ていると、
# 「委譲してから非 0 を返す」実装へ退行したときに課金を伴う実行を見逃す。
run_shim CODEX_REASONING_EFFORT=high
if [ ! -s "$WORK/argv.log" ]; then
  ok "CODEX_REASONING_EFFORT 拒否時に委譲先を起動しない"
else
  bad "拒否したのに委譲先が起動された（課金を伴う実行を見逃す）"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# モデルとプロファイルはアダプタ側で排他。プロファイルへ移行済みの環境に旧
# CODEX_MODEL が残っていると、シムがモデルを写した結果アダプタが非 0 で落ちる。
# **最も正しく移行した人だけが壊れる**形なので、プロファイルも「新しい設定」として扱う。
run_shim CODEX_MODEL=old-model MULTI_AGENT_CODEX_PROFILE=review
if env_log_has "MULTI_AGENT_MODEL_CODEX_CLI=old-model"; then
  bad "プロファイル設定済みなのに CODEX_MODEL を写した（アダプタの排他検査で落ちる）"
  sed 's/^/    | /' "$WORK/env.log" >&2
else
  ok "MULTI_AGENT_CODEX_PROFILE 設定時は CODEX_MODEL を写さない"
fi
if grep -q "MULTI_AGENT_CODEX_PROFILE" "$WORK/err.log"; then
  ok "無視した理由（プロファイルが優先）を通知する"
else
  bad "プロファイル優先で無視したことが通知されない"
fi

# env 経由の不正なリスト。コマンドライン側 (--reviewers) だけ検証して env を素通しすると、
# 既定の観点セットが黙って走って課金される。
for _bad in "" "code-review," ",code-review" "code-review,,test-analysis"; do
  run_shim "CODEX_DEFAULT_REVIEWERS=${_bad}"
  if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
    ok "CODEX_DEFAULT_REVIEWERS='${_bad}' を拒否し、委譲しない"
  else
    bad "CODEX_DEFAULT_REVIEWERS='${_bad}' が rc=$RUN_RC で通った（既定の観点が黙って走る）"
    sed 's/^/    | /' "$WORK/out.log" >&2
  fi
done
if grep -q "CODEX_DEFAULT_REVIEWERS" "$WORK/err.log"; then
  ok "拒否メッセージが env 名を名指しする（どちらの入口が不正か分かる）"
else
  bad "拒否メッセージが env 名を名指ししていない"
fi

# `a, b, c` 形式。除去しないと 2 件目以降が写像表を通らず、**通知も出ないまま**
# 存在しない観点として委譲され、オーケストレータ側で全滅する。
run_shim "CODEX_DEFAULT_REVIEWERS=code-reviewer, comment-analyzer"
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "comment-analysis"; then
  ok "空白入りのリストでも全要素が写像される"
else
  bad "空白入りのリストで一部の要素が写像されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
run_shim --reviewers "code-reviewer, pr-test-analyzer"
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "test-analysis"; then
  ok "--reviewers 側でも空白入りのリストが写像される"
else
  bad "--reviewers の空白入りリストで一部の要素が写像されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# pnpm は版によって `pnpm run x -- --opt` の `--` をスクリプトへ**透過する**
# （実測: pnpm 9.15.9 で argv[1] が '--'。npm は除去する）。各リポジトリの手順書は
# `pnpm code-review:codex -- --base develop` の形なので、先頭 `--` を拒否すると
# **文書どおりのコマンドが動かない**。`--` は利用者が渡した引数ではなくパッケージ
# マネージャが挟むものなので、拒否の対象として不適切。
run_shim -- --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--base" "develop"; then
  ok "先頭の '--' を読み飛ばして後続を解釈する（pnpm の透過に対応）"
else
  bad "先頭の '--' で失敗した (rc=$RUN_RC) — pnpm 経由の文書化コマンドが動かない"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# `--` の位置は pnpm の版や呼び出し方で変わりうる。途中でも読み飛ばす。
run_shim --base develop -- --dry-run
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--base" "develop"; then
  ok "途中の '--' も読み飛ばす"
else
  bad "途中の '--' で失敗した (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# GNU 慣用の `--opt=value` 形式。旧ラッパーが受けていたので手順書やスクリプトに残りうる。
run_shim --base=develop --dry-run
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--base" "develop"; then
  ok "--base=develop 形式が空白区切りと同じ結果になる"
else
  bad "--base=develop 形式が拒否された (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
run_shim --reviewers=code-reviewer,comment-analyzer --dry-run
if argv_has_seq "--perspective" "code-review" \
   && argv_has_seq "--perspective" "comment-analysis"; then
  ok "--reviewers=a,b 形式が写像つきで展開される"
else
  bad "--reviewers=a,b 形式が展開されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
run_shim --timeout=300 --dry-run
if argv_has_seq "--timeout" "300"; then
  ok "--timeout=300 形式が委譲される"
else
  bad "--timeout=300 形式が委譲されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 値が空の `--opt=` は、黙って既定へ落とさず拒否する（空白区切り側と同じ扱い）。
for _empty in "--base=" "--timeout="; do
  run_shim "$_empty" --dry-run
  if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
    ok "'${_empty}'（値が空）を拒否し、委譲しない"
  else
    bad "'${_empty}' が rc=$RUN_RC で通った（黙って既定へ落ちる）"
    sed 's/^/    | /' "$WORK/out.log" >&2
  fi
done

# usage() の heredoc は ${SCRIPT_NAME} を展開するため**非クォート**（<<USAGE）。
# そこへバッククォートを書くとコマンド置換として実行され、`--help` が
# `command not found` を吐きながら該当語をヘルプ本文から落とす（実測で踏んだ）。
# 静かに壊れるので、出力そのものを検査する。
run_shim --help
if [ "$RUN_RC" -eq 0 ]; then
  ok "--help が成功する"
else
  bad "--help が非 0 で終了した (rc=$RUN_RC)"
fi
if grep -q "command not found" "$WORK/out.log"; then
  bad "--help がコマンド置換を実行している（usage の heredoc が非クォート）"
  grep "command not found" "$WORK/out.log" | sed 's/^/    | /' >&2
else
  ok "--help がコマンド置換を実行しない"
fi
# ヘルプに書いた語が実際に出ていること（置換で消えると空白だけが残る）
for _word in "--base" "--reviewers" "--timeout" "--dry-run" "opt=value"; do
  if grep -q -- "$_word" "$WORK/out.log"; then
    ok "--help に '${_word}' が出る"
  else
    bad "--help から '${_word}' が消えている"
  fi
done

# 配置は原子的であること。cp で dest を直接上書きすると、書き込み途中で失敗したときに
# 壊れたラッパーが残る。同一ディレクトリの一時ファイルへ書いてから mv すれば、
# rename(2) が原子的なので dest は「前の内容」か「新しい内容」しか取らない。
#
# 部分書き込み（ディスク満杯・中断）を再現するのは現実的でないため、ここは**構造で
# 固定する**: dest を直接 cp する形へ戻す変更を赤にする。振る舞いで測れていない旨を
# 明示しておく（測っていない検出力を主張しない）。
_setup_src="$PLUGIN_ROOT/scripts/setup-multi-agent.sh"

# 走査は install_review_wrappers の関数本体へ限定する。ファイル全体を舐めると、
# (1) 既に原子的な別経路（yq は呼び出し元が一時パスを渡している）の cp を拾って誤検出し、
# (2) **コメントの散文が needle に一致して素通しになる**（実測: 原子化を丸ごと戻しても
#     「以前は mv "$tmp" "$dest" だったが…」というコメントを残すだけで緑になった）。
_install_body="$(awk '/^install_review_wrappers\(\)/ { inf = 1 }
                      inf { print }
                      inf && /^}$/ { exit }' "$_setup_src")"
# 抽出が**途中で切れた**ことを「本体を読んだ」と誤認しない。awk は行頭 } で打ち切るので、
# 関数内に heredoc 等で行頭 } があると数行で終わる（実測: 4 行で打ち切られ、変異が素通りした）。
# 空でないことに加えて、関数の末尾まで到達した証拠（最後の成功メッセージ）を要求する。
case "$_install_body" in
  *'codex-review.sh を配置しました'*) _body_ok=1 ;;
  *) _body_ok=0 ;;
esac
if [ -z "$_install_body" ] || [ "$_body_ok" -ne 1 ]; then
  bad "install_review_wrappers の本体を最後まで抽出できなかった（この検査が成立していない）"
  _install_body=""
fi

if [ -n "$_install_body" ]; then
  case "$_install_body" in
    *'mv "$tmp" "$dest"'*)
      ok "配置が一時ファイル + mv（原子的）になっている" ;;
    *)
      bad "配置が原子的でない — dest を直接上書きすると、失敗時に壊れたラッパーが残る" ;;
  esac
fi
# 照合は case で行う。`printf | grep -q` は grep が先に閉じるので pipefail 下で
# SIGPIPE により rc が反転しうる（このリポジトリの run-all case 10 が禁止している形）。
if [ -n "$_install_body" ]; then
  case "$_install_body" in
    *'cp "$src" "$dest"'*)
      bad "install_review_wrappers が dest を直接 cp している" ;;
    *)
      ok "install_review_wrappers に dest を直接 cp する経路が無い" ;;
  esac
fi
# 失敗時に「既存ファイルは無傷」と伝えること。伝えないと、利用者は退避先を探すか
# 再実行するかを判断できない。
#
# 件数はリテラルで固定しない。`-ge 3` のような直書きは (1) 失敗経路を 1 本増やしても
# 気づかず（実測: 通知の無い 4 本目を足しても緑）、(2) grep -c がコメントまで数えるため
# 実装から通知を消してコメントに同じ文言を書くだけで通った（実測: chmod を `|| true` へ
# 変えても緑）。**tmp 導入後の失敗経路（return 1）の数から導出**して照合する。
if [ -n "$_install_body" ]; then
  # 要求は「全経路が『変更していません』と言うこと」ではない。mv の後に失敗する経路では
  # ラッパーは既に置かれているので、その文言は**嘘になる**（実際そう書きかけて赤くなった）。
  # 正しい要求は「どの失敗経路も、終わった時点の状態を利用者へ伝えること」。
  # return 1 の直前 3 行以内に print_info があるかで判定する。
  _bare="$(printf '%s\n' "$_install_body" | awk '
    /local tmp=/ { started = 1 }
    started {
      if ($0 ~ /^ *return 1$/) {
        if (p1 !~ /print_info/ && p2 !~ /print_info/ && p3 !~ /print_info/) bare++
        total++
      }
      p3 = p2; p2 = p1; p1 = $0
    }
    END { printf "%d %d", total, bare }')"
  _total="${_bare%% *}"
  _bare_n="${_bare##* }"
  if [ "${_total:-0}" -lt 3 ]; then
    bad "tmp 導入後の失敗経路を ${_total} 本しか見つけられなかった（この検査が成立していない）"
  elif [ "${_bare_n:-1}" -eq 0 ]; then
    ok "配置の失敗経路すべて（${_total} 本）が終了時の状態を利用者へ伝える"
  else
    bad "失敗経路 ${_total} 本のうち ${_bare_n} 本が状態を伝えずに return している"
  fi
fi

# --- 観点の一覧と除外（消費側ラッパーが持っていた入口） ---

run_shim --list-reviewers
if [ "$RUN_RC" -eq 0 ]; then
  ok "--list-reviewers が成功する"
else
  bad "--list-reviewers が非 0 で終了した (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if argv_has "--list-perspectives"; then
  ok "--list-reviewers が委譲先の --list-perspectives へ写される"
else
  bad "--list-reviewers が委譲されていない（シムが独自に一覧を持つとレジストリと乖離する）"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

run_shim --exclude-reviewers code-reviewer,comment-analyzer --dry-run
if argv_has_seq "--exclude-perspective" "code-review" \
   && argv_has_seq "--exclude-perspective" "comment-analysis"; then
  ok "--exclude-reviewers が観点名の写像つきで --exclude-perspective へ展開される"
else
  bad "--exclude-reviewers が展開されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
run_shim --exclude-reviewers "" --dry-run
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "--exclude-reviewers の空値を拒否し、委譲しない"
else
  bad "--exclude-reviewers の空値が rc=$RUN_RC で通った"
fi

# --- diff サイズ閾値（消費側の課金の歯止め） ---

# 既定は無効。既定で有効にすると、これまで走っていたレビューが**黙ってスキップされる**
# 側へ倒れる。歯止めは明示的に入れてもらう。
run_shim --base develop --dry-run
if argv_has "--task"; then
  ok "閾値未設定なら従来どおり委譲する（既定で無効）"
else
  bad "閾値未設定なのに委譲されなかった"
fi

# 十分大きい閾値を設定すると、委譲せずスキップし、理由を 1 行出す。
run_shim CODEX_REVIEW_MIN_LINES=999999 --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "diff が閾値未満ならスキップし、委譲しない"
else
  bad "小 diff スキップが働いていない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if grep -q "CODEX_REVIEW_MIN_LINES" "$WORK/err.log"; then
  ok "スキップの理由と閾値を伝える（黙ってスキップしない）"
else
  bad "スキップした事実が伝わらない — 走ったのか飛ばされたのか区別できない"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi

# 非数値を黙って既定へ落とすと、歯止めを設定したつもりで全件走る。
run_shim CODEX_REVIEW_MIN_LINES=abc --base develop --dry-run
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "閾値が非数値なら非 0 で拒否し、委譲しない"
else
  bad "非数値の閾値が rc=$RUN_RC で通った（設定したつもりで全件走る）"
fi
run_shim CODEX_REVIEW_MAX_DIFF_BYTES=abc --base develop --dry-run
if [ "$RUN_RC" -eq 2 ]; then
  ok "上限側の閾値も非数値を拒否する"
else
  bad "CODEX_REVIEW_MAX_DIFF_BYTES の非数値が通った (rc=$RUN_RC)"
fi
# 上限を極小にすると、大きすぎる diff としてスキップする。
# 上限超過は**非 0**。0 で返すと呼び出し側から「レビュー成功」と区別できず、
# 最もレビューが要る大きな差分ほどゲートを素通りする。
run_shim CODEX_REVIEW_MAX_DIFF_BYTES=1 --base HEAD~1 --dry-run
if [ "$RUN_RC" -eq 3 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "diff が上限を超えたら非 0（3）で終了し、委譲しない"
else
  bad "上限超過が rc=$RUN_RC で終わった（意図的なスキップと区別できない）"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if grep -q "CODEX_MAX\|CODEX_REVIEW_MAX_DIFF_BYTES=0" "$WORK/err.log"; then
  ok "上限超過の出力が回避方法を案内する"
else
  bad "上限超過の出力に回避方法が無い"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi
# 小 diff スキップ（0）と終了コードで区別できること。
run_shim CODEX_REVIEW_MIN_LINES=999999 --base develop --dry-run
if [ "$RUN_RC" -eq 0 ]; then
  ok "小 diff スキップは 0 のまま（上限超過の 3 と区別できる）"
else
  bad "小 diff スキップが 0 で終わらない (rc=$RUN_RC)"
fi

# 旧 env の timeout は新しい入口へ写す。
run_shim CODEX_REVIEW_TIMEOUT_S=321 --base develop --dry-run
if argv_has_seq "--timeout" "321"; then
  ok "CODEX_REVIEW_TIMEOUT_S が --timeout へ写される"
else
  bad "CODEX_REVIEW_TIMEOUT_S が写されていない"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 明示した --timeout が env に負けると、指定した意味が消える。委譲先は last-wins なので
# 後から足すと env が勝つ（実測: --timeout 999 を渡して 321 秒で走った）。
run_shim CODEX_REVIEW_TIMEOUT_S=321 --base develop --timeout 999 --dry-run
if argv_has_seq "--timeout" "999" && ! argv_has_seq "--timeout" "321"; then
  ok "明示した --timeout が CODEX_REVIEW_TIMEOUT_S より優先される"
else
  bad "env の timeout が明示指定を上書きした"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 「設定済みだが空」を未設定と同一視すると、歯止めが黙って無効になる。
for _v in CODEX_REVIEW_MIN_LINES CODEX_REVIEW_MAX_DIFF_BYTES; do
  run_shim "${_v}=" --base develop --dry-run
  if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
    ok "${_v} の空値を拒否する（設定したのに効かない、を作らない）"
  else
    bad "${_v} の空値が rc=$RUN_RC で通った（歯止めが黙って無効になる）"
  fi
done

# 一覧は後段（skip / 旧 env / diff 閾値）を通さない。通すと「一覧を見たいだけ」なのに
# --base が無くて落ちたり、閾値次第で一覧が出ないまま成功終了したりする。
run_shim CODEX_REVIEW_MIN_LINES=10 --list-reviewers
if [ "$RUN_RC" -eq 0 ] && argv_has "--list-perspectives"; then
  ok "--list-reviewers は閾値が設定されていても一覧を出す"
else
  bad "--list-reviewers が閾値の経路に巻き込まれた (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
if argv_has "--dry-run" || argv_has_seq "--base" "develop"; then
  bad "--list-reviewers が一覧以外の引数まで委譲した"
  sed 's/^/    | /' "$WORK/argv.log" >&2
else
  ok "--list-reviewers は一覧のためだけの引数で委譲する"
fi

# 数字だけでも桁があふれると shell の整数比較が壊れる。`[ 30 -lt 999…9 ]` は
# 「integer expression expected」で rc=2 を返し、if の条件としては偽 — つまり歯止めが
# 黙って効かなくなり、レビューが全件走る（実測）。
run_shim CODEX_REVIEW_MIN_LINES=99999999999999999999 --base develop --dry-run
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "桁があふれる閾値を拒否する（整数比較が壊れて歯止めが無効になるのを防ぐ）"
else
  bad "桁あふれの閾値が rc=$RUN_RC で通った（歯止めが黙って効かない）"
fi

# "00" を文字列比較で "0" と区別すると、実効値 0 の歯止めが有効化され全件スキップする。
run_shim CODEX_REVIEW_MAX_DIFF_BYTES=00 --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && [ -s "$WORK/argv.log" ]; then
  ok "先頭ゼロの 0 は「無効」として正規化される（全件スキップにならない）"
else
  bad "CODEX_REVIEW_MAX_DIFF_BYTES=00 で委譲されなかった (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# timeout env も「設定済みだが空」を未設定と同一視しない（同じファイル内で扱いを揃える）。
run_shim CODEX_REVIEW_TIMEOUT_S= --base develop --dry-run
if [ "$RUN_RC" -eq 2 ]; then
  ok "CODEX_REVIEW_TIMEOUT_S の空値を拒否する"
else
  bad "CODEX_REVIEW_TIMEOUT_S の空値が rc=$RUN_RC で通った（設定したのに効かない）"
fi

# 測る範囲は委譲先がレビューする範囲と同じであること。BASE...HEAD だけを測ると
# pre-commit（staged 未コミット）で「0 行」と判定してスキップし、レビューされるはずの
# 変更が静かに飛ぶ。振る舞いで作り分けるのが難しいので構造で固定する。
if grep -qF 'git diff --numstat HEAD' "$SHIM"; then
  ok "diff の測定が作業ツリーの変更も含む（委譲先のレビュー範囲と一致）"
else
  bad "diff の測定が BASE...HEAD だけ — pre-commit の staged 変更が 0 行と判定される"
fi
# バイナリは numstat が `-` を出し、加算では 0 に化ける。測れないものを「小さい」と
# 読んでスキップしない。
if grep -qF '_unmeasurable' "$SHIM"; then
  ok "行数で測れない diff（バイナリ）をスキップ判定から除外する"
else
  bad "バイナリ変更が 0 行として扱われ、無言でスキップされる"
fi

# 先頭ゼロの正規化は 10 進で行う。`printf '%d'` は bash が 8 進として解釈するため、
# `010` が 8 になり `008` は invalid number で落ちる（実測）。閾値が 8 進で解釈されると、
# 設定した値と実際に効く値が食い違ったまま気づけない。
# 008 は 8 進として解釈できない値。printf '%d' だと invalid number で落ちる。
run_shim CODEX_REVIEW_MIN_LINES=008 --base HEAD~1 --dry-run
if [ "$RUN_RC" -eq 0 ]; then
  ok "先頭ゼロ付きの 008 が数値として扱われる（8 進解釈でエラーにならない）"
else
  bad "008 で非 0 になった (rc=$RUN_RC) — printf '%d' の 8 進解釈"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
# 正規化の結果は**スキップの通知に出る数値**で確かめる。rc だけを見ると、8 進で
# 解釈されても「落ちなかった」で通ってしまう（初版がそうだった）。
# 十分大きい値にして必ずスキップさせ、通知の数値を照合する。
# 10 進なら 10000000、8 進なら 2097152 になる。
run_shim CODEX_REVIEW_MIN_LINES=010000000 --base HEAD~1 --dry-run
if grep -q "CODEX_REVIEW_MIN_LINES=10000000" "$WORK/err.log"; then
  ok "先頭ゼロ付きの値が 10 進として正規化される"
else
  bad "先頭ゼロが 8 進として解釈された（通知の数値が 10 進でない）"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi

# 一覧はレビューを走らせる操作ではないので、逃がし弁や旧 env の判定より前に返す。
run_shim SKIP_CODEX_REVIEW=1 --list-reviewers
if [ "$RUN_RC" -eq 0 ] && argv_has "--list-perspectives"; then
  ok "SKIP_CODEX_REVIEW=1 でも --list-reviewers は一覧を出す"
else
  bad "SKIP_CODEX_REVIEW が --list-reviewers を止めた (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi
run_shim CODEX_DEFAULT_REVIEWERS= --list-reviewers
if [ "$RUN_RC" -eq 0 ] && argv_has "--list-perspectives"; then
  ok "旧 env が空でも --list-reviewers は一覧を出す"
else
  bad "旧 env の検証が --list-reviewers を止めた (rc=$RUN_RC)"
fi

# --workdir は委譲先に対応する概念が無い。黙って無視せず拒否する。
run_shim --workdir /tmp --base develop --dry-run
# この rc=2 の主張は、汎用の「未対応オプション」経路でも満たされる（実測: 専用 case を
# 消しても緑のまま）。専用 case が守っているのは**代替手段の案内**のほうなので、
# ラベルを実際に守っている範囲へ狭める。
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "--workdir で委譲しない（汎用の未対応オプション経路でも満たされる）"
else
  bad "--workdir が rc=$RUN_RC で通った"
fi
if grep -q "cd" "$WORK/err.log"; then
  ok "--workdir の拒否メッセージが代替手段を案内する"
else
  bad "--workdir の拒否メッセージに代替手段が無い"
fi

echo
echo "  PASS=${PASS} FAIL=${FAIL}"
FF_REACHED_END=1
if [ "$FAIL" -eq 0 ]; then
  echo "✓ ${SUITE_NAME} verify: 全 ${PASS} 件 pass"
else
  echo "✗ ${SUITE_NAME} verify: ${FAIL} 件失敗" >&2
  exit 1
fi
