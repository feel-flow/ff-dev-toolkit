# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# case 15・12・11・44・35: 再混入ガードと hook の stdin drain
#
# verify.sh から source される（ok / bad / expect_* / run_runner / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2696`）。

echo ""
echo "== case 15: mktemp skip ゲートが失敗理由を捨てる形の再混入ガード =="

# `mktemp -d ... 2>/dev/null` は、read-only 以外の失敗（TMPDIR が不正なパス・quota 超過など）まで
# 「書き込み可能な環境で再実行してください」に誤帰属する。恒常的に壊れた TMPDIR は suite 群を
# exit 0 で無効化し続け、skip の連鎖は run-all のサマリーでは正常に見える（`#385`）。
_swallow=""
_scanned_mk=0
# cases/ は verify.sh から分けた検査本体（Issue `#2692`）。
for _f in "$TESTS_DIR"/*/verify.sh "$TESTS_DIR"/*/cases/*.sh; do
  [ -f "$_f" ] || continue
  _scanned_mk=$((_scanned_mk + 1))
  # **コメント行を拾わない**。この検査を説明する散文が同じ文字列を含むため、素朴な grep は
  # 自分自身（run-all/verify.sh）を違反として挙げる（実測）。
  if grep -qE '^[[:space:]]*[^#[:space:]].*mktemp -d[^|]*2>/dev/null' "$_f"; then
    _swallow="${_swallow} ${_f#"$TESTS_DIR"/}"
  fi
done
if [ "$_scanned_mk" -lt 20 ]; then
  bad "suite を ${_scanned_mk} 本しか走査できなかった（この検査は成立していない）"
elif [ -z "$_swallow" ]; then
  ok "mktemp の失敗理由を捨てる skip ゲートが無い（${_scanned_mk} 本走査）"
else
  bad "mktemp の stderr を捨てる skip ゲートが再混入した:${_swallow}"
fi

# BSD mktemp のテンプレート無し呼び出しは、使えない TMPDIR からシステムの一時領域へフォール
# バックし得る。冒頭の probe が同じ TMPDIR を明示していないと環境都合が本物の失敗へ化ける。
# コメント中の説明ではなく、実行行に指定があることを固定する。
for _probe_spec in \
  'setup-multi-agent-yq|ff-setup-yq.XXXXXX' 'markdownlint-selftest|markdownlint-selftest.XXXXXX' \
  'mcp-state-selftest|mcp-state-selftest.XXXXXX' 'ace-refine|ace-refine-preflight.XXXXXX' \
  'run-all|run-all-preflight.XXXXXX'; do
  _probe_suite="${_probe_spec%%|*}"
  _probe_template="${_probe_spec#*|}"
  _probe_src="$TESTS_DIR/${_probe_suite}/verify.sh"
  if awk -v needle="\${TMPDIR:-/tmp}/${_probe_template}" '
    /^[[:space:]]*#/ { next }
    index($0, needle) { found=1 }
    END { exit !found }
  ' "$_probe_src"; then
    ok "${_probe_suite} の一時領域 probe が TMPDIR を明示している"
  else
    bad "${_probe_suite} の mktemp が TMPDIR を固定していない（環境都合を後段の失敗へ化かす）"
  fi
done

echo ""
echo "== case 12: 途中死した suite が rc=0 で pass と報告される形の再混入ガード =="

# `trap 'rm -rf "$X"' EXIT` は、suite が途中で死んでも**トラップ最終コマンドの成功**が終了ステータスを
# 上書きし、rc=0 で終わる。run-all はそれを passed に数えるので、アサーションが 1 件も走らないまま
# 「全部通った」と報告される（実測で 23 本中 20 本）。終了ステータスの保存だけでは直らない —
# `set -u` による死ではトラップ突入時の $? が **0** になるため。
#
# 振る舞いで測ると 23 suite を走らせることになるので、ここは構造で固定する。走査は ${TESTS_DIR}
# （tests/ 直下）。${SCRIPT_DIR} は tests/run-all/ を指すので、そちらを使うと**対象 0 件のまま
# 「問題なし」と報告する**（初版がそうなっており、変異が素通りした）。走査できた件数も主張に含める。
_unguarded=""
_scanned=0
for _f in "$TESTS_DIR"/*/verify.sh; do
  [ -f "$_f" ] || continue
  # **コメント行を拾わない**。`trap ... EXIT` の話をしている説明文が先に現れると、そちらを実装として
  # 読んで誤検出する（初版が 2 本を誤って挙げた）。
  _trap="$(grep -hE '^[[:space:]]*trap .*EXIT' "$_f" 2>/dev/null | head -1 || true)"
  [ -n "$_trap" ] || continue
  _scanned=$((_scanned + 1))
  case "$_trap" in
    *"trap 'rm -rf"*) _unguarded="${_unguarded} $(basename "$(dirname "$_f")")" ;;
  esac
done
if [ "$_scanned" -lt 20 ]; then
  bad "trap EXIT を持つ suite を ${_scanned} 本しか走査できなかった（この検査は成立していない）"
elif [ -z "$_unguarded" ]; then
  ok "trap EXIT を持つ ${_scanned} 本すべてに素の rm -rf トラップが無い（途中死が rc=0 にならない）"
else
  bad "途中死を握り潰すトラップが再混入した:${_unguarded}"
fi

# 検出器そのものが効くことを fixture で確かめる（構造検査が空振りしていないこと）。trap が途中死の
# 終了コードを上書きするかは Bash の版で異なるため fixture は実行せず、本体と同じ静的条件で見る。
_fixture_trap="$(grep -hE '^[[:space:]]*trap .*EXIT' "$SCRIPT_DIR/fixtures/exit-guard/bare-trap.sh" 2>/dev/null | head -1 || true)"
case "$_fixture_trap" in
  *"trap 'rm -rf"*)
    ok "fixture: 素の rm -rf トラップを本体と同じ静的条件で検出する" ;;
  *)
    bad "fixture: 素の rm -rf トラップを検出できない — 構造検査が空振りしている" ;;
esac

echo "== case 11: \$VAR 直付けマルチバイト展開の再混入ガード =="

# bash 3.2（macOS 標準 /bin/bash）は $VAR 直後のマルチバイト文字の先頭バイトを変数名へ取り込み、
# set -u 下では失敗を報告しようとした瞬間だけ unbound variable で落ちる。発火が bash の版数と
# ロケールに依存するため振る舞いテストは回帰ガードにならない（ACE-307-2）— 違反の形そのものへの
# 静的検査で縛る（Issue `#278`）。実装の正本は tests/lib/mbcs-guard.sh。fail-closed 経路の自動回帰は
# tests/mbcs-guard-failclosed/verify.sh。SKILL.md 内 bash ブロックは tests/skill-bash-blocks/verify.sh。

# shellcheck source=../lib/mbcs-guard.sh
. "$SCRIPT_DIR/../lib/mbcs-guard.sh"

# 検出器の自己検証（空振りの fail-closed）。違反 probe は 2 分割で組み立てる — 1 行に直書きすると、
# 本検査がこのファイル自体を違反として検出する（ACE-307-3）。
MBCS_PROBE_BAD='echo "失敗しました: $name'
MBCS_PROBE_BAD="${MBCS_PROBE_BAD}（原因不明）\""
MBCS_PROBE_GOOD='echo "失敗しました: ${name}（原因不明）"'
MBCS_PROBE_CONT='echo "失敗しました: $name\'
MBCS_PROBE_CONT="${MBCS_PROBE_CONT}
（原因不明）\""
MBCS_SELFTEST_OK=1
mbcs_expect() { # $1: probe / $2: hit|nohit / $3: 成立時の名 / $4: 不成立時の名
  # `_mb_out=$(...)` を素で書くと、mbcs_scan（= awk）の非 0 が pipefail 経由でこの代入文の終了
  # コードに乗り、set -e が suite を即終了させる（FF_MBCS_AWK が壊れている等）。後続ケース・
  # 最終集計・cleanup へ到達できなくなるため if 形式で受ける。
  if _mb_out="$(printf '%s\n' "$1" | mbcs_scan)"; then
    if { [ "$2" = "hit" ] && [ -n "$_mb_out" ]; } || { [ "$2" = "nohit" ] && [ -z "$_mb_out" ]; }; then
      ok "$3"
    else
      bad "$4"
      MBCS_SELFTEST_OK=0
    fi
  else
    bad "mbcs_scan を実行できません（$4）"
    MBCS_SELFTEST_OK=0
  fi
}
mbcs_expect "$MBCS_PROBE_BAD" hit "MBCS 検出器が違反を検出できる（self-test）" \
  "MBCS 検出器が違反を検出できない — 横断検査は空振りするため実行しない"
mbcs_expect "$MBCS_PROBE_GOOD" nohit "MBCS 検出器が \${VAR} 形式を誤検出しない（self-test）" \
  "MBCS 検出器が \${VAR} 形式を誤検出する"
mbcs_expect "$MBCS_PROBE_CONT" hit "MBCS 検出器がバックスラッシュ行継続をまたぐ隣接も検出できる（self-test）" \
  "MBCS 検出器が行継続をまたぐ隣接を取りこぼす"

if [ "$MBCS_SELFTEST_OK" -eq 1 ]; then
  MBCS_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || MBCS_REPO_ROOT=""
  if [ -z "$MBCS_REPO_ROOT" ]; then
    bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
  else
    # stdout=サマリー1行 / stderr=詳細。成功時は詳細不要、失敗時だけ再実行して詳細を出す。
    set +e
    MBCS_SUMMARY="$(mbcs_check_tracked "$MBCS_REPO_ROOT" 2>/dev/null)"
    MBCS_RC=$?
    set -e
    case "$MBCS_SUMMARY" in
      MBCS_RESULT=ok\ *)
        MBCS_SCANNED="$(printf '%s\n' "$MBCS_SUMMARY" | sed -E 's/.*SCANNED=([0-9]+).*/\1/')"
        ok "tracked shell スクリプトに \$VAR 直付けのマルチバイト展開が無い（${MBCS_SCANNED} ファイル走査）"
        ;;
      MBCS_RESULT=hits\ *)
        bad "\$VAR 直付けのマルチバイト展開が再混入した（\${VAR} 形式にすること）"
        mbcs_check_tracked "$MBCS_REPO_ROOT" >/dev/null || true
        ;;
      MBCS_RESULT=error_repo\ *)
        bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
        ;;
      MBCS_RESULT=error_list\ *)
        bad "検査対象の tracked ファイル一覧を取得できない（git ls-files 失敗/空）— 0 件の主張はできない"
        ;;
      MBCS_RESULT=error_scan\ *)
        bad "走査に失敗した *.sh がある — そのファイルの 0 件は主張できない"
        mbcs_check_tracked "$MBCS_REPO_ROOT" >/dev/null || true
        ;;
      *)
        bad "MBCS 横断検査の結果を解釈できない (rc=${MBCS_RC}): ${MBCS_SUMMARY:-empty}"
        mbcs_check_tracked "$MBCS_REPO_ROOT" >/dev/null || true
        ;;
    esac
  fi
fi

echo ""
echo "== case 44: hooks.json 登録 hook の stdin drain 契約 =="

HOOKDRAIN_PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# 契約の正本は hooks/asdd-hook-gate.sh の "stdin contract" 節。読まない hook を免除しないのは、
# 免除が denylist になり後から足した hook を無審査で通すため。判定対象は hooks.json の登録
# コマンドから導出し、検査側に hook 名を書かない（名簿で守らない = AC の要求）。
# 実装の正本は tests/lib/hook-stdin-drain.sh。
# shellcheck source=../lib/hook-stdin-drain.sh
. "$SCRIPT_DIR/../lib/hook-stdin-drain.sh"

# 検出器の自己検証。契約に反する形を 1 つずつ足した写しで**赤になること**を先に測る。
# 変異の一覧はレビューで実測した偽陰性（検出器が緑にしてしまう形）をそのまま並べたもので、
# どれか 1 つでも緑へ戻ると、その形の契約違反が無審査で通る。
HOOKDRAIN_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/ff-hook-drain.XXXXXX" 2>&1)" || HOOKDRAIN_FIXTURE=""
if [ -z "$HOOKDRAIN_FIXTURE" ] || [ ! -d "$HOOKDRAIN_FIXTURE" ]; then
  bad "case 44: 一時領域を作成できず、drain 契約の検出力を実測できません: $HOOKDRAIN_FIXTURE"
else
  mkdir -p "$HOOKDRAIN_FIXTURE/hooks"
  cp "$HOOKDRAIN_PLUGIN_ROOT/hooks/hooks.json" "$HOOKDRAIN_FIXTURE/hooks/hooks.json.orig"
  for _hd_src in "$HOOKDRAIN_PLUGIN_ROOT"/hooks/*.sh; do cp "$_hd_src" "$HOOKDRAIN_FIXTURE/hooks/"; done

  # 登録を 1 件足す（$1 = command 文字列）
  hookdrain_register() {
    cp "$HOOKDRAIN_FIXTURE/hooks/hooks.json.orig" "$HOOKDRAIN_FIXTURE/hooks/hooks.json"
    FF_HD_CMD="$1" python3 - "$HOOKDRAIN_FIXTURE/hooks/hooks.json" <<'HOOKJSON'
import io, json, os, sys
p = sys.argv[1]
d = json.load(io.open(p, encoding="utf-8"))
d.setdefault("hooks", {}).setdefault("SessionStart", []).append(
    {"hooks": [{"type": "command", "command": os.environ["FF_HD_CMD"]}]})
io.open(p, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=2))
HOOKJSON
  }
  # 変異 1 件を測る（$1 = ラベル / $2 = 期待 rc / $3 = 期待診断の部分文字列）
  hookdrain_expect() {
    local label="$1" want_rc="$2" needle="$3" out got
    out="$(ff_hook_stdin_drain_scan "$HOOKDRAIN_FIXTURE" 2>&1)" && got=0 || got=$?
    case "$got:$out" in
      "$want_rc":*"$needle"*) ok "case 44: $label" ;;
      *) bad "case 44: ${label}（rc=${got} 期待 ${want_rc}）: $out" ;;
    esac
  }

  cp "$HOOKDRAIN_FIXTURE/hooks/hooks.json.orig" "$HOOKDRAIN_FIXTURE/hooks/hooks.json"
  hookdrain_expect "未変異の対照は緑（変異の赤を対照と区別できる）" 0 "INSPECTED"

  # 走査件数は固定床ではなく hooks.json の実体と突き合わせる。固定床（-ge N）は、
  # 「走査から漏れた 1 本 + 契約違反 1 本」を同時に吸収して緑にする（レビューで実測）。
  HOOKDRAIN_EXPECTED="$(jq -r '.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty' \
    "$HOOKDRAIN_FIXTURE/hooks/hooks.json" | awk '{ n=split($(0),w,/[[:space:]]+/); for(i=1;i<=n;i++){ gsub(/["\047]/,"",w[i]); if (w[i] ~ /\.sh$/) { sub(/.*\//,"",w[i]); print w[i] } } }' | sort -u | wc -l | tr -d ' ')"
  HOOKDRAIN_OUT="$(ff_hook_stdin_drain_scan "$HOOKDRAIN_FIXTURE" 2>&1)" && HOOKDRAIN_RC=0 || HOOKDRAIN_RC=$?
  HOOKDRAIN_COUNT="$(printf '%s\n' "$HOOKDRAIN_OUT" | awk -F'\t' '/^INSPECTED/ { print $2 }')"
  if [ "$HOOKDRAIN_RC" -eq 0 ] && [ -n "$HOOKDRAIN_COUNT" ] && [ "$HOOKDRAIN_COUNT" -eq "$HOOKDRAIN_EXPECTED" ]; then
    ok "case 44: 走査本数が hooks.json の登録実体と一致する（${HOOKDRAIN_COUNT} 本・固定床で吸収しない）"
  else
    bad "case 44: 走査本数が実体と不一致（走査 ${HOOKDRAIN_COUNT:-0} / 実体 ${HOOKDRAIN_EXPECTED} / rc=${HOOKDRAIN_RC}）: $HOOKDRAIN_OUT"
  fi

  printf '%s\n' '#!/usr/bin/env bash' \
    'source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh" || exit 0' \
    > "$HOOKDRAIN_FIXTURE/hooks/ff-probe.sh"
  hookdrain_register 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/ff-probe.sh"'
  hookdrain_expect "drain の無い hook を 1 本足すと赤（名簿ではなく列挙で守られている）" 1 "drain がありません"

  hookdrain_register 'bash ${CLAUDE_PLUGIN_ROOT}/hooks/ff-probe.sh --flag'
  hookdrain_expect "無引用 + 引数付きの登録も検査対象になる（黙って除外しない）" 1 "drain がありません"

  hookdrain_register 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/ff-probe-missing.sh"'
  hookdrain_expect "実在しないファイルの登録は走査不成立（rc=2）" 2 "実在しません"

  hookdrain_register 'node --eval "process.exit(0)"'
  hookdrain_expect "hook ファイルを解決できない登録形は走査不成立（rc=2）" 2 "解決できません"

  hookdrain_register 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/ff-probe.sh"'
  {
    printf '%s\n' '#!/usr/bin/env bash' 'input=""'
    printf '%s\n' "IFS= read -r -d x input || true"
    printf '%s\n' 'source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh" || exit 0'
  } > "$HOOKDRAIN_FIXTURE/hooks/ff-probe.sh"
  hookdrain_expect "区切りが非空の read（read -d x）は drain と認めない" 1 "drain がありません"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'while IFS= read -r -d "" f; do :; done < <(find . -maxdepth 0 -print0)'
    printf '%s\n' 'source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh" || exit 0'
  } > "$HOOKDRAIN_FIXTURE/hooks/ff-probe.sh"
  hookdrain_expect "リダイレクト付きの read（stdin を読んでいない）は drain と認めない" 1 "drain がありません"

  {
    printf '%s\n' '#!/usr/bin/env bash' "cat <<'DOC'"
    printf '%s\n' "IFS= read -r -d '' input || true"
    printf '%s\n' 'DOC' 'source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh" || exit 0'
  } > "$HOOKDRAIN_FIXTURE/hooks/ff-probe.sh"
  hookdrain_expect "heredoc 本文の read（実行されない）は drain と認めない" 1 "drain がありません"

  {
    printf '%s\n' '#!/usr/bin/env bash' 'GATE="${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"'
    printf '%s\n' 'source "$GATE" || exit 0' 'input=""'
    printf '%s\n' "IFS= read -r -d '' input || true"
  } > "$HOOKDRAIN_FIXTURE/hooks/ff-probe.sh"
  hookdrain_expect "変数経由で source してもゲート位置を見失わない" 1 "より後にあります"

  {
    printf '%s\n' '#!/usr/bin/env bash' 'input="$(cat)"'
    printf '%s\n' 'source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh" || exit 0'
  } > "$HOOKDRAIN_FIXTURE/hooks/ff-probe.sh"
  hookdrain_expect "cat による drain は契約 (a) 違反として名指しする" 1 "cat を使っています"

  {
    printf '%s\n' '#!/usr/bin/env bash' 'input=""'
    printf '%s\n' "IFS= read -r -d '' input || true"
  } > "$HOOKDRAIN_FIXTURE/hooks/ff-probe.sh"
  hookdrain_expect "ゲート言及の無い hook は緑にしない" 1 "ゲートへの言及がありません"

  # 正当な旗順・結合旗を誤って赤にしない（偽陽性側）
  {
    printf '%s\n' '#!/usr/bin/env bash' 'input=""'
    printf '%s\n' "IFS= read -rd '' input || true"
    printf '%s\n' 'source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh" || exit 0'
  } > "$HOOKDRAIN_FIXTURE/hooks/ff-probe.sh"
  hookdrain_expect "結合旗（read -rd ''）は正当な drain として通す" 0 "INSPECTED"

  rm -f "$HOOKDRAIN_FIXTURE/hooks/hooks.json"
  hookdrain_expect "hooks.json が読めない回は走査不成立（rc=2）で止まる" 2 "SCAN-ERROR"
  rm -rf "$HOOKDRAIN_FIXTURE"
fi

# 契約 (c): 上限付き drain は「閉じない stdin でも必ず終わる」ことを買っている。
# 無上限（-t 無し）の read は EOF まで戻らないので、対話端末やパイプを開いたまま書かない
# ホストで hook が固まり、ホストの timeout kill まで持ち時間を使い切る（実測 6.1s / 上限付きは
# 0.1s 台）。実 hook を起動すると副作用（ネットワーク照会・キャッシュ書き込み）を踏むので、
# drain の形だけを写した fixture で終了保証を測り、実 hook 側は上限の宣言を静的に確かめる。
HOOKBOUND_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ff-hook-bound.XXXXXX" 2>&1)" || HOOKBOUND_DIR=""
if [ -z "$HOOKBOUND_DIR" ] || [ ! -d "$HOOKBOUND_DIR" ]; then
  bad "case 44: 一時領域を作成できず、上限付き drain の終了保証を実測できません: $HOOKBOUND_DIR"
else
  {
    printf '%s\n' '#!/usr/bin/env bash' 'FF_STDIN_BOUND_SECONDS=1' 'input=""'
    printf '%s\n' "IFS= read -r -t \"\$FF_STDIN_BOUND_SECONDS\" -d '' input || true"
    printf '%s\n' 'exit 0'
  } > "$HOOKBOUND_DIR/bounded.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'input=""'
    printf '%s\n' "IFS= read -r -d '' input || true"
    printf '%s\n' 'exit 0'
  } > "$HOOKBOUND_DIR/unbounded.sh"

  # 閉じない stdin を与え、上限の 3 倍の猶予で戻るかを見る（戻らなければ kill して赤）。
  hookbound_probe() { # <script> -> 戻れば 0 / 固まれば 1
    bash "$1" < <(sleep 9) >/dev/null 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 3 ]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; fi
    wait "$pid" 2>/dev/null
    return 0
  }
  if hookbound_probe "$HOOKBOUND_DIR/bounded.sh"; then
    ok "case 44: 上限付き drain は閉じない stdin でも上限内に終わる（契約 (c) の終了保証）"
  else
    bad "case 44: 上限付き drain が閉じない stdin で戻りません（上限が効いていない）"
  fi
  if hookbound_probe "$HOOKBOUND_DIR/unbounded.sh"; then
    bad "case 44: 無上限 drain が閉じない stdin で戻りました（対照が成立せず、上の検査は終了保証を測れていません）"
  else
    ok "case 44: 無上限 drain は閉じない stdin で戻らない（上限の有無が実際に効いている対照）"
  fi
  rm -rf "$HOOKBOUND_DIR"
fi

# 実 hook 側: SessionStart に登録された hook が上限を宣言していること（無上限へ戻す変更を
# 止める）。値そのものは登録 timeout との突き合わせを行わないので契約文では規範扱い
# （asdd-hook-gate.sh）。**対象は hooks.json から導出する** — ここへ名前を書き並べると、
# 後から足した SessionStart hook が無審査で通る（drain の走査側が名簿を持たないのと同じ理由）。
HOOKBOUND_RESOLVED_RAW="$(jq -r '(.hooks.SessionStart // [])[] | .hooks[]? | .command // empty' \
  "$HOOKDRAIN_PLUGIN_ROOT/hooks/hooks.json" \
  | awk '{ n=split($(0),w,/[[:space:]]+/); for(i=1;i<=n;i++){ gsub(/["\047]/,"",w[i]); if (w[i] ~ /\.sh$/) { sub(/.*\//,"",w[i]); print w[i] } } }')"
HOOKBOUND_TARGETS="$(printf '%s\n' "$HOOKBOUND_RESOLVED_RAW" | grep -v '^$' | sort -u || true)"
HOOKBOUND_COUNT="$(printf '%s\n' "$HOOKBOUND_TARGETS" | grep -c . || true)"
# 「0 件なら赤」だけでは足りない。hooks.json の書き方が変わって**一部だけ**導出できなく
# なった回（`.sh` で終わらない command・wrapper 化）は、対象が黙って縮んだまま緑になる。
# 直下の live 検査は登録 hook の**総数**しか見ないので、SessionStart 部分集合の縮みは拾えない。
# 登録エントリ 1 件につき 1 本解決できたことを突き合わせて、縮んだ回を赤にする
# （重複登録があっても数が合うよう、比較は sort -u の前の解決数で行う）。
HOOKBOUND_RESOLVED="$(printf '%s\n' "$HOOKBOUND_RESOLVED_RAW" | grep -c . || true)"
HOOKBOUND_REGISTERED="$(jq -r '[(.hooks.SessionStart // [])[].hooks[]?] | length' \
  "$HOOKDRAIN_PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null || true)"
HOOKBOUND_MISSING=""
if [ -z "$HOOKBOUND_TARGETS" ] || [ "$HOOKBOUND_COUNT" -eq 0 ]; then
  bad "case 44: hooks.json から SessionStart hook を 1 本も導出できません（走査不成立を緑にしない）"
elif [[ ! "$HOOKBOUND_REGISTERED" =~ ^[0-9]+$ ]] \
  || [ "$HOOKBOUND_RESOLVED" -ne "$HOOKBOUND_REGISTERED" ]; then
  bad "case 44: SessionStart の登録エントリから解決できた hook 数が一致しません（解決 ${HOOKBOUND_RESOLVED} / 登録 ${HOOKBOUND_REGISTERED:-取得失敗}）— 一部だけ解釈できない形を緑にしない"
else
  for _hb in $HOOKBOUND_TARGETS; do
    if [ ! -f "$HOOKDRAIN_PLUGIN_ROOT/hooks/${_hb}" ] \
      || ! awk '/^[[:space:]]*#/ { next } /read[[:space:]]+-r[[:space:]]+-t[[:space:]]/ { found = 1 } END { exit !found }' \
        "$HOOKDRAIN_PLUGIN_ROOT/hooks/${_hb}"; then
      HOOKBOUND_MISSING="${HOOKBOUND_MISSING}${_hb} "
    fi
  done
  if [ -z "$HOOKBOUND_MISSING" ]; then
    ok "case 44: SessionStart の ${HOOKBOUND_COUNT} 本は上限付きで読む（無上限へ戻すと赤）"
  else
    bad "case 44: 上限の宣言が無い hook があります: ${HOOKBOUND_MISSING}"
  fi
fi

# live: 実体の hooks.json に登録された全 hook が契約を満たす
HOOKDRAIN_LIVE="$(ff_hook_stdin_drain_scan "$HOOKDRAIN_PLUGIN_ROOT" 2>&1)" && HOOKDRAIN_LIVE_RC=0 || HOOKDRAIN_LIVE_RC=$?
HOOKDRAIN_LIVE_EXPECTED="$(jq -r '.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty' \
  "$HOOKDRAIN_PLUGIN_ROOT/hooks/hooks.json" | awk '{ n=split($(0),w,/[[:space:]]+/); for(i=1;i<=n;i++){ gsub(/["\047]/,"",w[i]); if (w[i] ~ /\.sh$/) { sub(/.*\//,"",w[i]); print w[i] } } }' | sort -u | wc -l | tr -d ' ')"
HOOKDRAIN_LIVE_COUNT="$(printf '%s\n' "$HOOKDRAIN_LIVE" | awk -F'\t' '/^INSPECTED/ { print $2 }')"
if [ "$HOOKDRAIN_LIVE_RC" -eq 0 ] && [ -n "$HOOKDRAIN_LIVE_COUNT" ] && [ "$HOOKDRAIN_LIVE_COUNT" -eq "$HOOKDRAIN_LIVE_EXPECTED" ]; then
  ok "case 44: 登録 hook ${HOOKDRAIN_LIVE_COUNT} 本すべてが stdin を読み切る契約を満たす（live）"
else
  bad "case 44: live の drain 契約が不正（rc=${HOOKDRAIN_LIVE_RC} / 走査 ${HOOKDRAIN_LIVE_COUNT:-0} / 実体 ${HOOKDRAIN_LIVE_EXPECTED}）: $HOOKDRAIN_LIVE"
fi

# case 35: パイプ終端の終了コード誤読の再混入ガード。別の契約（終了コード検出器）を検査する
# 塊なので cases ファイルへ置く（ADR-057 決定 2。Issue `#1805`）。
EXITCODE_CONSUMER_CASES=0
suite_cases_source "$SCRIPT_DIR/cases" exit-code-guard.sh
if [ "${EXITCODE_CONSUMER_CASES:-0}" -gt 0 ]; then
  ok "consumer gate のケース集合は空でない"
else
  bad "consumer gate のケース集合が空 / cases ファイルの中身が消失"
fi

echo ""
EXITCODE_CONTEXT_CASES=0
EXITCODE_CONTEXT_FILE="$SCRIPT_DIR/cases/consumer-gate-context.sh"
if [ ! -f "$EXITCODE_CONTEXT_FILE" ] || [ ! -r "$EXITCODE_CONTEXT_FILE" ] || [ ! -s "$EXITCODE_CONTEXT_FILE" ]; then
  bad "consumer context casesが無い/読めない/空"
else
  suite_cases_source "$SCRIPT_DIR/cases" consumer-gate-context.sh
  if [ "$EXITCODE_CONTEXT_CASES" -gt 0 ]; then ok "consumer contextのケース集合は空でない"; else bad "consumer contextのケース集合が空"; fi
fi

# suite-cases-end: reintroduction-guards.sh
