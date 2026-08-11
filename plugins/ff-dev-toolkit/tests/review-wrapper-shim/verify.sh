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
# 限界（承知のうえ）: 変数越しの起動（`CLI=codex; "$CLI" exec`）とバックスラッシュ
# 行継続はこの静的走査では追えない。シムは短く直接的に書く前提で、そこは
# 「レビューで見る」に委ねる。コメント除去は素朴な `#` 以降の切り落としなので、
# 同じ行に `${var#pat}` があるとそこから先が消える点も同様。
detects_direct_cli() {
  local file="$1" stripped
  # 読めないファイルを「一致なし」と同じ答えにしない。sed|grep の rc は右端の
  # grep が支配するので、上流が失敗しても「clean」に見える（実測で読めない
  # ファイルが clean と報告された）。中間結果を受けてから判定する。
  if ! stripped="$(sed 's/[[:space:]]*#.*$//' "$file" 2>/dev/null)"; then
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
  env FF_DEV_TOOLKIT_ROOT="$PROJ/orch" ARGV_LOG="$WORK/argv.log" \
    ${envs[@]+"${envs[@]}"} \
    bash "$PROJ/scripts/codex-review.sh" "$@" >"$WORK/out.log" 2>&1 || RUN_RC=$?
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
run_shim --exclude-reviewers foo
if [ "$RUN_RC" -ne 0 ]; then
  ok "未対応オプションを非 0 で拒否する"
else
  bad "未対応オプションが素通りした（指定したつもりのまま既定設定でレビューが走る）"
fi
if grep -q -- "--exclude-reviewers" "$WORK/out.log"; then
  ok "拒否メッセージが該当オプションを名指しする"
else
  bad "拒否メッセージが該当オプションを名指ししていない"
fi

# モデル指定の env は toolkit の正規経路（MULTI_AGENT_*）へ寄せる。
# 黙って無視すると「指定したつもりの古いモデルで走る」ACE-70-2 の形になる。
run_shim CODEX_MODEL=some-model
if [ "$RUN_RC" -ne 0 ]; then
  ok "CODEX_MODEL が設定されていたら非 0 で拒否する"
else
  bad "CODEX_MODEL が黙って無視された（モデル指定が効かないまま走る）"
fi
if grep -q "MULTI_AGENT_MODEL_CODEX_CLI" "$WORK/out.log"; then
  ok "拒否メッセージが正規の env 名を案内する"
else
  bad "拒否メッセージが正規の env 名を案内していない"
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

echo
echo "  PASS=${PASS} FAIL=${FAIL}"
FF_REACHED_END=1
if [ "$FAIL" -eq 0 ]; then
  echo "✓ ${SUITE_NAME} verify: 全 ${PASS} 件 pass"
else
  echo "✗ ${SUITE_NAME} verify: ${FAIL} 件失敗" >&2
  exit 1
fi
