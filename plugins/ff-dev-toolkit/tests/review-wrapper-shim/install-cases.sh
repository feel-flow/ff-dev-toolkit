#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: 本番経路（FF_DEV_TOOLKIT_ROOT 未設定）での setup による配置: main 経由の配置・冪等・揮発パス警告・CRLF 正規化・失敗の rc 伝播・偽オーケストレータの拒否。
# 依存: run_isolated_shim / ${SETUP}。${FAKE} / ${PLACED} / ${SIDECAR} をここで定義し、**後続の 2 ファイルが参照する**。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

echo "-- 本番経路（FF_DEV_TOOLKIT_ROOT を設定しない） --"

# ここまでの検査は（toolkit 未解決を測る RUN_SHIM_NO_ROOT の 2 件を除き）FF_DEV_TOOLKIT_ROOT を
# 設定していた。それだけだと
# 「配置されたシムが自力でオーケストレータへ到達できるか」を一度も通らない。
FAKE="$WORK/fake-toolkit"
mkdir -p "$FAKE/scripts/templates" "$FAKE/.claude-plugin" "$WORK/consumer2"
cp "$SETUP" "$FAKE/scripts/setup-multi-agent.sh"
cp "$SHIM" "$FAKE/scripts/templates/codex-review.sh"
cat > "$FAKE/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "ff-dev-toolkit",
  "version": "0.38.0"
}
JSON
cat > "$FAKE/scripts/agent-config.yaml" <<'YAML'
version: "2.0"
toolkit_version: "0.38.0"
YAML
cat > "$FAKE/scripts/multi-agent.sh" <<'SH'
#!/usr/bin/env bash
# stub orchestrator: --task review|explore|implement と --perspective を受け付ける体裁
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
  run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$WORK/no-codex-home" \
    CLAUDE_CONFIG_DIR="$WORK/no-claude-home" ARGV_LOG="$WORK/argv.log" \
    bash "$PLACED" --base develop >"$WORK/prod.log" 2>&1 || PROD_RC=$?
  if [ "$PROD_RC" -eq 0 ]; then
    ok "本番経路: 環境変数なしでシムが完走する"
  else
    bad "本番経路: 環境変数なしで非 0 終了した (rc=$PROD_RC)"
    sed 's/^/    | /' "$WORK/prod.log" >&2
  fi

  # シムが同一でも sidecar は毎回現在の toolkit へ更新する。旧版を指す sidecar が
  # 残ると、setup が「シムは最新」と早期 return して旧版を使い続ける。
  printf '%s\n' "$WORK/stale-toolkit/scripts" > "$SIDECAR"
  run_install_via_main "$WORK/consumer2"
  _sidecar_got="$(cat "$SIDECAR")"
  if [ "$_sidecar_got" = "$_sidecar_want" ] \
     && [ ! -e "$WORK/consumer2/scripts/codex-review.sh.bak" ]; then
    ok "本番経路: シムが同一でも sidecar だけを現在版へ更新する"
  else
    bad "本番経路: 同一シムで古い sidecar が更新されない、または不要な .bak を作った"
  fi
  if argv_has_seq "--base" "develop" && argv_has_seq "--cli" "codex-cli"; then
    ok "本番経路: サイドカー経由でオーケストレータへ引数が届く"
  else
    bad "本番経路: サイドカー経由で引数が届いていない"
    sed 's/^/    | /' "$WORK/argv.log" >&2
  fi

  # 環境変数はサイドカーに勝つこと。負けると、toolkit を移動・更新して
  # サイドカーが古くなったとき env で上書きできなくなる。
  ALT="$WORK/alt-toolkit"
  mkdir -p "$ALT/scripts/templates" "$ALT/.claude-plugin"
  cp "$FAKE/scripts/multi-agent.sh" "$ALT/scripts/multi-agent.sh"
  cp "$SHIM" "$ALT/scripts/templates/codex-review.sh"
  cp "$FAKE/scripts/agent-config.yaml" "$ALT/scripts/agent-config.yaml"
  cp "$FAKE/.claude-plugin/plugin.json" "$ALT/.claude-plugin/plugin.json"
  : > "$WORK/argv-alt.log"
  run_isolated_shim FF_DEV_TOOLKIT_ROOT="$ALT" ARGV_LOG="$WORK/argv-alt.log" \
    bash "$PLACED" --base develop >/dev/null 2>&1 || true
  if [ -s "$WORK/argv-alt.log" ]; then
    ok "env と サイドカーが両方あるとき env が勝つ"
  else
    bad "env が指す先が使われていない（サイドカーが勝っている）"
  fi

  # ── パスの形の対称性と、env によるサイドカーの覆い隠し（`Issue #603`） ──────────
  #
  # env とサイドカーは慣習上の正規形が違う（前者=プラグインルート / 後者=scripts/）が、
  # 解決はどちらも canonical_toolkit_root を通るので**両形を受け付ける**。ここを
  # 検査しないと、片側だけの補完へ戻す変異が緑のまま通り、診断が案内する形と
  # 実装が食い違う。サイドカーへプラグインルートを書く形は既存の検査が 1 件も
  # 触れていなかった（サイドカー=scripts/ と env=プラグインルートしか通っていない）。
  : > "$WORK/argv.log"
  printf '%s\n' "$FAKE" > "$SIDECAR"
  run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$WORK/no-codex-home" \
    CLAUDE_CONFIG_DIR="$WORK/no-claude-home" ARGV_LOG="$WORK/argv.log" \
    bash "$PLACED" --base develop >"$WORK/shape.log" 2>&1 || true
  if argv_has_seq "--cli" "codex-cli"; then
    ok "サイドカーにプラグインルートを書いても解決できる（env と対称）"
  else
    bad "サイドカーがプラグインルート形を受け付けない（案内する形と実装が食い違う）"
    sed 's/^/    | /' "$WORK/shape.log" >&2
  fi

  # env が使えないサイドカーを覆い隠す事故。実測（`Issue #603`）: 同じシェルで
  # FF_DEV_TOOLKIT_ROOT を export したまま成功したため「サイドカーは正しい」と
  # 誤って結論し、env の無い次のシェル（= 実際の運用）で失敗した。
  # 告知であって上書きではないので **rc は 0 のまま**であること。
  : > "$WORK/argv.log"
  printf '%s\n' "$WORK/nonexistent-toolkit" > "$SIDECAR"
  MASK_RC=0
  run_isolated_shim FF_DEV_TOOLKIT_ROOT="$ALT" ARGV_LOG="$WORK/argv.log" \
    bash "$PLACED" --base develop >"$WORK/mask.log" 2>&1 || MASK_RC=$?
  if [ "$MASK_RC" -eq 0 ] && [ -s "$WORK/argv.log" ] \
     && grep -qF "$MASK_NEEDLE" "$WORK/mask.log"; then
    ok "env が使えないサイドカーを覆い隠すとき告知する（レビューは止めない）"
  else
    bad "壊れたサイドカーが env に覆い隠されたまま黙って通った (rc=$MASK_RC)"
    sed 's/^/    | /' "$WORK/mask.log" >&2
  fi

  # 逆に「別の toolkit を指しているだけ」では鳴らさないこと。env がサイドカーに
  # 勝つのは正規の上書き手段で、開発 clone と cache を併用する構成では食い違うのが
  # 普通。そこで鳴らすと毎回出て、上の本物の告知ごと読み飛ばされる。
  printf '%s\n' "$_sidecar_want" > "$SIDECAR"
  : > "$WORK/argv.log"
  NOMASK_RC=0
  run_isolated_shim FF_DEV_TOOLKIT_ROOT="$ALT" ARGV_LOG="$WORK/argv.log" \
    bash "$PLACED" --base develop >"$WORK/nomask.log" 2>&1 || NOMASK_RC=$?
  # 「警告が出ない」だけを見ると、起動そのものが失敗した回（ログが空・別の理由で非 0）も
  # ✓ になる。実際このケースは、13 件が rc=4 で赤くなったクラウドの回でも ✓ を出していた。
  # 委譲まで届いたこと（rc=0 と argv の記録）を先に確かめる。
  if [ "$NOMASK_RC" -eq 0 ] && [ -s "$WORK/argv.log" ] && ! grep -qF "$MASK_NEEDLE" "$WORK/nomask.log"; then
    ok "使えるサイドカーが env と食い違うだけでは警告しない"
  else
    bad "使えるサイドカーにまで警告が出る、または委譲まで届いていない (rc=$NOMASK_RC)"
    sed 's/^/    | /' "$WORK/nomask.log" >&2
  fi

  # 末尾に改行が無い**使える**サイドカーでも鳴らさないこと（`Issue #807`）。read は
  # 値を代入したうえで EOF により非 0 を返すため、その非 0 で空へ上書きすると、
  # resolve 側（`|| true` 済み）では解決できる同じファイルが告知判定でだけ
  # 「使えない」に化け、手書きサイドカーの正規構成で毎回誤警告が出る。
  printf '%s' "$_sidecar_want" > "$SIDECAR"
  : > "$WORK/argv.log"
  MASK_NONL_RC=0
  run_isolated_shim FF_DEV_TOOLKIT_ROOT="$ALT" ARGV_LOG="$WORK/argv.log" \
    bash "$PLACED" --base develop >"$WORK/nomask-nonl.log" 2>&1 || MASK_NONL_RC=$?
  if [ "$MASK_NONL_RC" -eq 0 ] && [ -s "$WORK/argv.log" ] \
     && ! grep -qF "$MASK_NEEDLE" "$WORK/nomask-nonl.log"; then
    ok "末尾改行の無い使えるサイドカーは env 併用でも誤警告しない（read の EOF 非 0 で値を捨てない）"
  else
    bad "末尾改行の無い使えるサイドカーが覆い隠し警告を誤発報した (rc=$MASK_NONL_RC)"
    sed 's/^/    | /' "$WORK/nomask-nonl.log" >&2
  fi

  # cache が勝つ場合の告知抑止は、fixture 生成器（make_cache_toolkit）が定義される
  # toolkit-root-resolution-cases.sh（「cache 解決順・版整合」）で検査する。

  # 解決に失敗したときの診断は、期待するパスの形と記録値の両方を出すこと。
  # 「指す先に multi-agent.sh がありません」だけだと、利用者は scripts/ を足すのか
  # 外すのかが判らず設定ミスの解消に何往復もかかる（`Issue #603` の実測）。
  printf '%s\n' "$WORK/nonexistent-toolkit" > "$SIDECAR"
  : > "$WORK/argv-shape.log"
  SHAPE_RC=0
  run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$WORK/no-codex-home" \
    CLAUDE_CONFIG_DIR="$WORK/no-claude-home" ARGV_LOG="$WORK/argv-shape.log" \
    bash "$PLACED" --base develop >"$WORK/nohint.log" 2>&1 || SHAPE_RC=$?
  if [ "$SHAPE_RC" -ne 0 ] && [ ! -s "$WORK/argv-shape.log" ] \
     && grep -q '期待するパスの形' "$WORK/nohint.log" \
     && grep -q 'FF_DEV_TOOLKIT_ROOT: プラグインルート' "$WORK/nohint.log" \
     && grep -qF "$(basename "$SIDECAR"): toolkit の scripts/ ディレクトリ" "$WORK/nohint.log" \
     && grep -qF "記録値: ${WORK}/nonexistent-toolkit" "$WORK/nohint.log"; then
    ok "解決失敗の診断が期待するパスの形と記録値を示す"
  else
    bad "解決失敗の診断に期待するパスの形または記録値が無い (rc=$SHAPE_RC)"
    sed 's/^/    | /' "$WORK/nohint.log" >&2
  fi

  # 空のサイドカーは記録値を「(empty)」と明示すること（診断が黙って欠ける形にしない）。
  : > "$SIDECAR"
  : > "$WORK/argv-empty.log"
  EMPTY_REC_RC=0
  run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$WORK/no-codex-home" \
    CLAUDE_CONFIG_DIR="$WORK/no-claude-home" ARGV_LOG="$WORK/argv-empty.log" \
    bash "$PLACED" --base develop >"$WORK/emptyrec.log" 2>&1 || EMPTY_REC_RC=$?
  if [ "$EMPTY_REC_RC" -ne 0 ] && [ ! -s "$WORK/argv-empty.log" ] \
     && grep -qF '記録値: (empty)' "$WORK/emptyrec.log"; then
    ok "空のサイドカーは記録値を (empty) と明示する"
  else
    bad "空のサイドカーで記録値の明示が無い、または委譲してしまった (rc=$EMPTY_REC_RC)"
    sed 's/^/    | /' "$WORK/emptyrec.log" >&2
  fi

  # 末尾に改行が無いサイドカーでも解決すること。`read` は値を代入したうえで EOF で非 0 を
  # 返すため、その非 0 を「読めなかった」と同一視して空へ倒すと、非空のファイルを
  # 「記録値: (empty)」と報告しながら解決にも失敗する（手設定こそこの形になりやすい）。
  : > "$WORK/argv-nonl.log"
  printf '%s' "$_sidecar_want" > "$SIDECAR"
  NONL_RC=0
  run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$WORK/no-codex-home" \
    CLAUDE_CONFIG_DIR="$WORK/no-claude-home" ARGV_LOG="$WORK/argv-nonl.log" \
    bash "$PLACED" --base develop >"$WORK/nonl.log" 2>&1 || NONL_RC=$?
  if [ "$NONL_RC" -eq 0 ] && [ -s "$WORK/argv-nonl.log" ] \
     && grep -q 'source=sidecar' "$WORK/nonl.log"; then
    ok "末尾に改行が無いサイドカーでも解決する（read の EOF 非 0 で値を捨てない）"
  else
    bad "末尾改行の無いサイドカーが解決できない (rc=$NONL_RC)"
    sed 's/^/    | /' "$WORK/nonl.log" >&2
  fi

  # 後続の検査は本番経路のサイドカーが生きている前提なので戻す。
  printf '%s\n' "$_sidecar_want" > "$SIDECAR"
fi

echo "-- setup: sidecar 修復の検証・揮発パス警告・行末正規化（Issue 658） --"

# (1) 記録前の usable 検証。存在（-f）だけを見ると、0 バイトの multi-agent.sh でも
# サイドカーへ記録され、解決不能はシム実行時（usable_orchestrator の拒否）に初めて
# 露見する。setup は記録前に同じ語彙で検証し、使えない値で既存サイドカーを
# 上書きしないこと。
BADKIT="$WORK/bad-toolkit"
mkdir -p "$BADKIT/scripts/templates"
cp "$SETUP" "$BADKIT/scripts/setup-multi-agent.sh"
cp "$SHIM" "$BADKIT/scripts/templates/codex-review.sh"
: > "$BADKIT/scripts/multi-agent.sh"   # 0 バイト = シムの usable_orchestrator が拒否する形
BAD_TGT="$WORK/consumer-bad"
mkdir -p "$BAD_TGT/scripts"
printf '%s\n' "$WORK/stale-toolkit/scripts" > "$BAD_TGT/scripts/.ff-dev-toolkit-root"
BAD_RC=0
( set +e
  # shellcheck disable=SC1090
  . "$BADKIT/scripts/setup-multi-agent.sh" >/dev/null 2>&1
  INSTALL_WRAPPERS_TARGET="$BAD_TGT" install_review_wrappers
) >"$WORK/install-bad.log" 2>&1 || BAD_RC=$?
if [ "$BAD_RC" -ne 0 ] \
   && [ "$(cat "$BAD_TGT/scripts/.ff-dev-toolkit-root")" = "$WORK/stale-toolkit/scripts" ]; then
  ok "setup: 使えない multi-agent.sh（0 バイト）を sidecar へ記録せず非 0 で落ちる"
else
  bad "setup: 0 バイトの multi-agent.sh が sidecar へ記録された、または成功扱いになった (rc=$BAD_RC)"
  sed 's/^/    | /' "$WORK/install-bad.log" >&2
fi

# (2) 揮発パス（Temp 配下）の判定と警告。Temp 上の作業コピーから setup を実行すると、
# 配置直後は動くが Temp 清掃でサイドカーの参照先だけが消えて後日静かに壊れる
# （実測インシデント）。記録は行ってよいが、予告なしにしないこと。
# 判定関数そのものを両側（揮発 / 非揮発）から見る。$WORK は mktemp 由来なので
# どの OS でも Temp 配下 = 揮発側の入力になる。
if ( # shellcheck disable=SC1090
     . "$SETUP" >/dev/null 2>&1
     toolkit_path_is_volatile "$WORK/somewhere/scripts" ); then
  ok "setup: Temp 配下のパスを揮発と判定する"
else
  bad "setup: Temp 配下のパスを揮発と判定できない"
fi
if ( # shellcheck disable=SC1090
     . "$SETUP" >/dev/null 2>&1
     toolkit_path_is_volatile "/opt/ff-dev-toolkit/scripts" ); then
  bad "setup: 恒久パスまで揮発と誤判定する（毎回鳴る警告は読み飛ばされる）"
else
  ok "setup: 恒久パス（/opt 配下）は揮発と判定しない"
fi

# end-to-end: Temp 配下の toolkit（$FAKE は $WORK 配下）から配置すると、警告を
# 出しつつ記録は行う。
WARN_TGT="$WORK/consumer-warn"
mkdir -p "$WARN_TGT"
WARN_RC=0
( set +e
  # shellcheck disable=SC1090
  . "$FAKE/scripts/setup-multi-agent.sh" >/dev/null 2>&1
  INSTALL_WRAPPERS_TARGET="$WARN_TGT" install_review_wrappers
) >"$WORK/install-warn.log" 2>&1 || WARN_RC=$?
if [ "$WARN_RC" -eq 0 ] && grep -q "一時領域" "$WORK/install-warn.log" \
   && [ "$(cat "$WARN_TGT/scripts/.ff-dev-toolkit-root" 2>/dev/null)" = "$_sidecar_want" ]; then
  ok "setup: Temp 配下からの実行は警告を出しつつ記録は行う"
else
  bad "setup: Temp 配下からの実行で警告が出ない、または記録されない (rc=$WARN_RC)"
  sed 's/^/    | /' "$WORK/install-warn.log" >&2
fi

# (3) CRLF テンプレートと LF 配置済みシム。Windows の plugin cache はテンプレートを
# CRLF で持つことがあり、byte 比較だと同一内容のシムが毎回「変更あり」になる —
# tracked ファイルが CRLF で上書きされて全行 diff になり、.bak が実行のたびに増える。
CRLF_KIT="$WORK/crlf-toolkit"
mkdir -p "$CRLF_KIT/scripts/templates" "$CRLF_KIT/.claude-plugin"
cp "$SETUP" "$CRLF_KIT/scripts/setup-multi-agent.sh"
cp "$FAKE/scripts/multi-agent.sh" "$CRLF_KIT/scripts/multi-agent.sh"
cp "$FAKE/scripts/agent-config.yaml" "$CRLF_KIT/scripts/agent-config.yaml"
cp "$FAKE/.claude-plugin/plugin.json" "$CRLF_KIT/.claude-plugin/plugin.json"
awk '{ printf "%s\r\n", $0 }' "$SHIM" > "$CRLF_KIT/scripts/templates/codex-review.sh"
run_crlf_install() {
  ( set +e
    # shellcheck disable=SC1090
    . "$CRLF_KIT/scripts/setup-multi-agent.sh" >/dev/null 2>&1
    INSTALL_WRAPPERS_TARGET="$WORK/consumer-crlf" install_review_wrappers
  ) >"$WORK/install-crlf.log" 2>&1
}
CRLF_PLACED="$WORK/consumer-crlf/scripts/codex-review.sh"
mkdir -p "$WORK/consumer-crlf"

# 新規配置: CRLF テンプレートからでも LF へ正規化して置く（tracked ファイルを
# CRLF で汚さない）。LF の $SHIM と byte 一致することが正規化の証拠。
if run_crlf_install && cmp -s "$SHIM" "$CRLF_PLACED"; then
  ok "setup: CRLF テンプレートからの新規配置が LF へ正規化される"
else
  bad "setup: CRLF テンプレートからの配置が LF に正規化されない"
  sed 's/^/    | /' "$WORK/install-crlf.log" >&2
fi

# 再実行: 行末だけ違うテンプレートと配置済みシムを「同一」と判定し、再配置も
# .bak 増殖も起きない。
if run_crlf_install && grep -q "スキップ" "$WORK/install-crlf.log" \
   && [ ! -e "${CRLF_PLACED}.bak" ] && cmp -s "$SHIM" "$CRLF_PLACED"; then
  ok "setup: CRLF テンプレート vs LF 配置済みの再実行はスキップし .bak を作らない"
else
  bad "setup: 行末差だけで再配置された、または .bak が増えた"
  sed 's/^/    | /' "$WORK/install-crlf.log" >&2
  ls "$WORK/consumer-crlf/scripts" | sed 's/^/    | /' >&2
fi

# シム側の版一致検査も行末を正規化すること。setup が LF で配置する以上、CRLF cache と
# LF 配置済みシムは**正規の構成**であり、byte 比較のままだと「版が一致しません」
# （rc=2）でレビューが 1 件も走らない。
: > "$WORK/argv-crlf.log"
CRLF_ID_RC=0
run_isolated_shim FF_DEV_TOOLKIT_ROOT="$CRLF_KIT" ARGV_LOG="$WORK/argv-crlf.log" \
  bash "$CRLF_PLACED" --base develop >"$WORK/crlf-id.log" 2>&1 || CRLF_ID_RC=$?
if [ "$CRLF_ID_RC" -eq 0 ] && [ -s "$WORK/argv-crlf.log" ]; then
  ok "シム: CRLF テンプレートと LF 配置済みシムを別版と誤判定しない（行末正規化）"
else
  bad "シム: 行末差だけで版不一致として拒否した (rc=$CRLF_ID_RC)"
  sed 's/^/    | /' "$WORK/crlf-id.log" >&2
fi

# (4) CRLF で**配置済み**の既存シム + LF テンプレート。CRLF シムは
# `set: pipefail: invalid option name`（rc=1）で壊れているのに、正規化比較だけだと
# 「最新です」で恒久放置される（レビュー実測）。内容は同一なので .bak を作らずに
# LF へ書き直す（自己修復）こと。
REPAIR_TGT="$WORK/consumer-repair"
mkdir -p "$REPAIR_TGT/scripts"
awk '{ printf "%s\r\n", $0 }' "$SHIM" > "$REPAIR_TGT/scripts/codex-review.sh"
chmod +x "$REPAIR_TGT/scripts/codex-review.sh"
REPAIR_RC=0
( set +e
  # shellcheck disable=SC1090
  . "$FAKE/scripts/setup-multi-agent.sh" >/dev/null 2>&1
  INSTALL_WRAPPERS_TARGET="$REPAIR_TGT" install_review_wrappers
) >"$WORK/install-repair.log" 2>&1 || REPAIR_RC=$?
if [ "$REPAIR_RC" -eq 0 ] && cmp -s "$SHIM" "$REPAIR_TGT/scripts/codex-review.sh" \
   && [ ! -e "$REPAIR_TGT/scripts/codex-review.sh.bak" ] \
   && grep -q "正規化" "$WORK/install-repair.log"; then
  ok "setup: CRLF で配置済みの既存シムを LF へ書き直す（.bak は作らない）"
else
  bad "setup: CRLF 配置済みシムが修復されない・.bak が出た・または告知が無い (rc=$REPAIR_RC)"
  sed 's/^/    | /' "$WORK/install-repair.log" >&2
fi

# (5) main 経由でも配置失敗が最終 rc へ伝播すること。warning へ変換して rc=0
# 「セットアップ完了」で終えると、unusable 検出の fail-closed が正規経路で無効化される。
BADMAIN_RC=0
( set +e
  # shellcheck disable=SC1090
  . "$BADKIT/scripts/setup-multi-agent.sh" >/dev/null 2>&1
  check_prerequisites() { :; }
  check_and_install_dependencies() { :; }
  detect_ai_clis() { :; }
  show_install_guides() { :; }
  run_verification() { :; }
  check_config() { :; }
  print_summary() { :; }
  print_header() { :; }
  INSTALL_WRAPPERS_TARGET="$WORK/consumer-badmain" main
) >"$WORK/install-badmain.log" 2>&1 || BADMAIN_RC=$?
if [ "$BADMAIN_RC" -ne 0 ]; then
  ok "setup: main 経由でも配置失敗が非 0 で終了する（warning へ変換して握り潰さない）"
else
  bad "setup: 配置失敗なのに main が rc=0 で「完了」した"
  sed 's/^/    | /' "$WORK/install-badmain.log" >&2
fi

# (6) 非空の偽オーケストレータ: --task と implement を**コメントに**含むだけの
# exit 0 スクリプト。2 語の grep だけだと usable と誤認して記録する（レビュー実測）。
FAKEORCH_KIT="$WORK/fakeorch-toolkit"
mkdir -p "$FAKEORCH_KIT/scripts/templates"
cp "$SETUP" "$FAKEORCH_KIT/scripts/setup-multi-agent.sh"
cp "$SHIM" "$FAKEORCH_KIT/scripts/templates/codex-review.sh"
cat > "$FAKEORCH_KIT/scripts/multi-agent.sh" <<'SH'
#!/usr/bin/env bash
# 無関係なスクリプト。--task を implement する予定、とコメントに書いてあるだけ。
exit 0
SH
FAKEORCH_TGT="$WORK/consumer-fakeorch"
mkdir -p "$FAKEORCH_TGT"
FAKEORCH_RC=0
( set +e
  # shellcheck disable=SC1090
  . "$FAKEORCH_KIT/scripts/setup-multi-agent.sh" >/dev/null 2>&1
  INSTALL_WRAPPERS_TARGET="$FAKEORCH_TGT" install_review_wrappers
) >"$WORK/install-fakeorch.log" 2>&1 || FAKEORCH_RC=$?
if [ "$FAKEORCH_RC" -ne 0 ] && [ ! -e "$FAKEORCH_TGT/scripts/.ff-dev-toolkit-root" ]; then
  ok "setup: コメントに --task/implement を含むだけの偽オーケストレータを記録しない"
else
  bad "setup: 偽オーケストレータ（コメントのみ・exit 0）が usable 扱いされた (rc=$FAKEORCH_RC)"
  sed 's/^/    | /' "$WORK/install-fakeorch.log" >&2
fi

# (7) 読み取り不能な multi-agent.sh も記録しない（root 実行では chmod 000 でも
# 読めるため、その場合だけ部分 skip）。
UNREAD_KIT="$WORK/unread-toolkit"
mkdir -p "$UNREAD_KIT/scripts/templates"
cp "$SETUP" "$UNREAD_KIT/scripts/setup-multi-agent.sh"
cp "$SHIM" "$UNREAD_KIT/scripts/templates/codex-review.sh"
cp "$FAKE/scripts/multi-agent.sh" "$UNREAD_KIT/scripts/multi-agent.sh"
chmod 000 "$UNREAD_KIT/scripts/multi-agent.sh"
if [ -r "$UNREAD_KIT/scripts/multi-agent.sh" ]; then
  echo "  ○ skip: chmod 000 でも読める実行環境（root）のため、読み取り不能の検査をスキップ"
else
  UNREAD_TGT="$WORK/consumer-unread"
  mkdir -p "$UNREAD_TGT"
  UNREAD_RC=0
  ( set +e
    # shellcheck disable=SC1090
    . "$UNREAD_KIT/scripts/setup-multi-agent.sh" >/dev/null 2>&1
    INSTALL_WRAPPERS_TARGET="$UNREAD_TGT" install_review_wrappers
  ) >"$WORK/install-unread.log" 2>&1 || UNREAD_RC=$?
  if [ "$UNREAD_RC" -ne 0 ] && [ ! -e "$UNREAD_TGT/scripts/.ff-dev-toolkit-root" ]; then
    ok "setup: 読み取り不能な multi-agent.sh を記録しない"
  else
    bad "setup: 読み取り不能な multi-agent.sh が usable 扱いされた (rc=$UNREAD_RC)"
    sed 's/^/    | /' "$WORK/install-unread.log" >&2
  fi
fi
chmod 644 "$UNREAD_KIT/scripts/multi-agent.sh"

# (8) 正規化・比較の前提が壊れているとき「最新です」に倒れないこと。読めない
# テンプレート vs 配置済みシムは、procsub のままだと「両側空 = 一致」で成功扱いに
# なる（レビュー実測: cmp -s が rc=0 を返した）。
GATE_KIT="$WORK/gate-toolkit"
mkdir -p "$GATE_KIT/scripts/templates"
cp "$SETUP" "$GATE_KIT/scripts/setup-multi-agent.sh"
cp "$FAKE/scripts/multi-agent.sh" "$GATE_KIT/scripts/multi-agent.sh"
cp "$SHIM" "$GATE_KIT/scripts/templates/codex-review.sh"
chmod 000 "$GATE_KIT/scripts/templates/codex-review.sh"
if [ -r "$GATE_KIT/scripts/templates/codex-review.sh" ]; then
  echo "  ○ skip: chmod 000 でも読める実行環境（root）のため、読めないテンプレートの検査をスキップ"
else
  GATE_TGT="$WORK/consumer-gate"
  mkdir -p "$GATE_TGT/scripts"
  # dest は 0 バイトにする。レビュー実測の形はこれ — 読めない src と空 dest は
  # procsub 比較だと「両側空 = 一致」で「最新です」rc=0 に化ける。
  : > "$GATE_TGT/scripts/codex-review.sh"
  GATE_RC=0
  ( set +e
    # shellcheck disable=SC1090
    . "$GATE_KIT/scripts/setup-multi-agent.sh" >/dev/null 2>&1
    INSTALL_WRAPPERS_TARGET="$GATE_TGT" install_review_wrappers
  ) >"$WORK/install-gate.log" 2>&1 || GATE_RC=$?
  if [ "$GATE_RC" -ne 0 ] && ! grep -q "最新です" "$WORK/install-gate.log"; then
    ok "setup: 読めないテンプレートで「最新です」に倒れず非 0 で落ちる"
  else
    bad "setup: 読めないテンプレートが成功・最新扱いになった (rc=$GATE_RC)"
    sed 's/^/    | /' "$WORK/install-gate.log" >&2
  fi
fi
chmod 644 "$GATE_KIT/scripts/templates/codex-review.sh"

# (9) 本文中（行末以外）の CR はデータとして扱う。`tr -d '\r'` は本文中の CR も
# 消すため、CR の有無だけ違う別内容を「同一（スキップ）」と誤判定する（レビュー
# 実測）。行末のみの正規化なら差分として検出され、.bak 退避つきで置き換わる。
MIDCR_TGT="$WORK/consumer-midcr"
mkdir -p "$MIDCR_TGT/scripts"
awk 'NR==2 { printf "\r%s\n", $0; next } { print }' "$SHIM" > "$MIDCR_TGT/scripts/codex-review.sh"
MIDCR_RC=0
( set +e
  # shellcheck disable=SC1090
  . "$FAKE/scripts/setup-multi-agent.sh" >/dev/null 2>&1
  INSTALL_WRAPPERS_TARGET="$MIDCR_TGT" install_review_wrappers
) >"$WORK/install-midcr.log" 2>&1 || MIDCR_RC=$?
if [ "$MIDCR_RC" -eq 0 ] && cmp -s "$SHIM" "$MIDCR_TGT/scripts/codex-review.sh" \
   && [ -e "$MIDCR_TGT/scripts/codex-review.sh.bak" ]; then
  ok "setup: 本文中の CR だけ違う既存シムを「同一」と誤判定せず .bak 退避つきで置き換える"
else
  bad "setup: 本文中 CR の差分が行末正規化で消されて誤スキップされた (rc=$MIDCR_RC)"
  sed 's/^/    | /' "$WORK/install-midcr.log" >&2
fi

# (9b) シム側の版一致検査も本文中 CR をデータとして扱うこと。行末のみの正規化なら
# 「mid-line CR の有無だけ違う template」は別内容 = 版不一致（rc=2）として拒否される。
# tr 正規化だと同一版と誤認して委譲してしまう。
MIDCR_KIT="$WORK/midcr-toolkit"
mkdir -p "$MIDCR_KIT/scripts/templates" "$MIDCR_KIT/.claude-plugin"
cp "$FAKE/scripts/multi-agent.sh" "$MIDCR_KIT/scripts/multi-agent.sh"
cp "$FAKE/scripts/agent-config.yaml" "$MIDCR_KIT/scripts/agent-config.yaml"
cp "$FAKE/.claude-plugin/plugin.json" "$MIDCR_KIT/.claude-plugin/plugin.json"
awk 'NR==2 { printf "\r%s\n", $0; next } { print }' "$SHIM" > "$MIDCR_KIT/scripts/templates/codex-review.sh"
: > "$WORK/argv-midcr.log"
MIDCR_ID_RC=0
run_isolated_shim FF_DEV_TOOLKIT_ROOT="$MIDCR_KIT" ARGV_LOG="$WORK/argv-midcr.log" \
  bash "$CRLF_PLACED" --base develop >"$WORK/midcr-id.log" 2>&1 || MIDCR_ID_RC=$?
if [ "$MIDCR_ID_RC" -eq 2 ] && [ ! -s "$WORK/argv-midcr.log" ] \
   && grep -q '配置済み shim の版が一致しません' "$WORK/midcr-id.log"; then
  ok "シム: 本文中 CR だけ違う template を同一版と誤認せず拒否する"
else
  bad "シム: 本文中 CR の差分が正規化で消えて委譲された (rc=$MIDCR_ID_RC)"
  sed 's/^/    | /' "$WORK/midcr-id.log" >&2
fi

# (10) 揮発判定の境界値。TMPDIR=/ や末尾スラッシュのみの値で候補が空へ退化すると、
# case パターンが "/*" になってあらゆる絶対パスを揮発と誤判定する（レビュー実測:
# TMPDIR=/ で /opt が VOLATILE）。
if ( # shellcheck disable=SC1090
     . "$SETUP" >/dev/null 2>&1
     TMPDIR=/ toolkit_path_is_volatile "/opt/ff-dev-toolkit/scripts" ); then
  bad "setup: TMPDIR=/ で恒久パスまで揮発と誤判定する"
else
  ok "setup: TMPDIR=/ でも恒久パスを揮発と誤判定しない"
fi
if ( # shellcheck disable=SC1090
     . "$SETUP" >/dev/null 2>&1
     TMPDIR="" toolkit_path_is_volatile "/opt/ff-dev-toolkit/scripts" ); then
  bad "setup: TMPDIR 空で恒久パスまで揮発と誤判定する"
else
  ok "setup: TMPDIR 空でも恒久パスを揮発と誤判定しない"
fi

