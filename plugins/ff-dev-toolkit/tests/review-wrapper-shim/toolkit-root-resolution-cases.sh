#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: cache 解決順・版整合・--print-toolkit-root の契約・プラグインルート指定の正規形・配置先の既定。
# 依存: install-cases.sh が定義した ${FAKE} / ${PLACED} / ${SIDECAR} と、recovery-mode-cases.sh が作る ${WORK}/review-context.txt。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

echo "-- cache 解決順・版整合 --"

make_cache_toolkit() { # <root> <version>
  local root="$1" version="$2"
  mkdir -p "$root/scripts/templates" "$root/.claude-plugin"
  cp "$FAKE/scripts/multi-agent.sh" "$root/scripts/multi-agent.sh"
  cp "$SHIM" "$root/scripts/templates/codex-review.sh"
  cat > "$root/.claude-plugin/plugin.json" <<JSON
{
  "name": "ff-dev-toolkit",
  "version": "$version"
}
JSON
  cat > "$root/scripts/agent-config.yaml" <<YAML
version: "2.0"
toolkit_version: "$version"
YAML
}

CODEX_CACHE_HOME="$WORK/codex-cache-home"
CLAUDE_CACHE_HOME="$WORK/claude-cache-home"
make_cache_toolkit "$CODEX_CACHE_HOME/plugins/cache/market/ff-dev-toolkit/0.9.0" "0.9.0"
make_cache_toolkit "$CODEX_CACHE_HOME/plugins/cache/market/ff-dev-toolkit/0.10.0" "0.10.0"
make_cache_toolkit "$CLAUDE_CACHE_HOME/plugins/cache/market/ff-dev-toolkit/9.0.0" "9.0.0"
: > "$WORK/argv-cache.log"
CACHE_RC=0
run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$CODEX_CACHE_HOME" \
  CLAUDE_CONFIG_DIR="$CLAUDE_CACHE_HOME" ARGV_LOG="$WORK/argv-cache.log" \
  bash "$PLACED" --base develop >"$WORK/cache.log" 2>&1 || CACHE_RC=$?
if [ "$CACHE_RC" -eq 0 ] \
   && grep -q 'version=9.0.0 source=claude-cache' "$WORK/cache.log"; then
  ok "cache: 両 cache を横断して最大 semantic version を選ぶ"
else
  bad "cache: 優先順位または semantic version 選択が不正 (rc=$CACHE_RC)"
  sed 's/^/    | /' "$WORK/cache.log" >&2
fi

make_cache_toolkit "$CODEX_CACHE_HOME/plugins/cache/market/ff-dev-toolkit/9.0.0" "9.0.0"
: > "$WORK/argv-cache.log"
CACHE_RC=0
run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$CODEX_CACHE_HOME" \
  CLAUDE_CONFIG_DIR="$CLAUDE_CACHE_HOME" ARGV_LOG="$WORK/argv-cache.log" \
  bash "$PLACED" --base develop >"$WORK/cache.log" 2>&1 || CACHE_RC=$?
if [ "$CACHE_RC" -eq 0 ] \
   && grep -q 'version=9.0.0 source=codex-cache' "$WORK/cache.log"; then
  ok "cache: 最大版が同じときだけ Codex cache を優先する"
else
  bad "cache: 同版の Codex 優先が不正 (rc=$CACHE_RC)"
fi

: > "$WORK/argv-cache.log"
CACHE_RC=0
run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$WORK/empty-codex-home" \
  CLAUDE_CONFIG_DIR="$CLAUDE_CACHE_HOME" ARGV_LOG="$WORK/argv-cache.log" \
  bash "$PLACED" --base develop >"$WORK/cache.log" 2>&1 || CACHE_RC=$?
if [ "$CACHE_RC" -eq 0 ] \
   && grep -q 'version=9.0.0 source=claude-cache' "$WORK/cache.log"; then
  ok "cache: Codex 候補が無いとき Claude cache から完走する"
else
  bad "cache: Claude cache フォールバックが不正 (rc=$CACHE_RC)"
fi

cp "$CODEX_CACHE_HOME/plugins/cache/market/ff-dev-toolkit/9.0.0/scripts/templates/codex-review.sh" "$WORK/cache-template.good"
printf '\n# mismatch\n' >> "$CODEX_CACHE_HOME/plugins/cache/market/ff-dev-toolkit/9.0.0/scripts/templates/codex-review.sh"
printf '%s\n' "$FAKE/scripts" > "$SIDECAR"
: > "$WORK/argv-cache.log"
CACHE_RC=0
run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$CODEX_CACHE_HOME" \
  CLAUDE_CONFIG_DIR="$WORK/empty-claude-home" ARGV_LOG="$WORK/argv-cache.log" \
  bash "$PLACED" --base develop >"$WORK/cache.log" 2>&1 || CACHE_RC=$?
mv "$WORK/cache-template.good" "$CODEX_CACHE_HOME/plugins/cache/market/ff-dev-toolkit/9.0.0/scripts/templates/codex-review.sh"
if [ "$CACHE_RC" -eq 2 ] && [ ! -s "$WORK/argv-cache.log" ] \
   && grep -q '配置済み shim の版が一致しません' "$WORK/cache.log" \
   && ! grep -q 'source=sidecar' "$WORK/cache.log"; then
  ok "cache: 最大候補の版不整合は sidecar へ落とさず fail closed"
else
  bad "cache: 版不整合が sidecar へフォールバックした (rc=$CACHE_RC)"
fi

# cache が勝った実行では、使えないサイドカーがあっても告知しないこと（`Issue #603`）。
# env はシェルスコープなので「ここでは在るが次のシェルでは無い」が成立するが、plugin cache は
# マシンに永続していて次のシェルでも CI でも同じように解決する。cache 下で「この経路が
# 無い環境では失敗します」と言うのは端的に嘘になる。しかも cache はサイドカーより先に
# 引かれるので、plugin の版が上がって旧 cache ディレクトリが消えた消費リポジトリでは
# **毎回**鳴る（実測）。常時鳴る警告は、同じブロックが運んでいる本物のパス案内ごと
# 読み飛ばされるようにするだけで、埋めたはずの診断の穴より悪い。
CACHE_QUIET_HOME="$WORK/cache-quiet-home"
make_cache_toolkit "$CACHE_QUIET_HOME/plugins/cache/market/ff-dev-toolkit/0.38.0" "0.38.0"
printf '%s\n' "$WORK/nonexistent-toolkit" > "$SIDECAR"
CACHE_QUIET_RC=0
run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$CACHE_QUIET_HOME" \
  CLAUDE_CONFIG_DIR="$WORK/no-claude-home" ARGV_LOG="$WORK/argv-cache.log" \
  bash "$PLACED" --base develop >"$WORK/cachequiet.log" 2>&1 || CACHE_QUIET_RC=$?
printf '%s\n' "$FAKE/scripts" > "$SIDECAR"
if [ "$CACHE_QUIET_RC" -eq 0 ] && grep -q 'source=codex-cache' "$WORK/cachequiet.log" \
   && ! grep -qF "$MASK_NEEDLE" "$WORK/cachequiet.log"; then
  ok "cache が勝った実行では壊れたサイドカーを告知しない（毎回鳴る警告にしない）"
else
  bad "cache 経路で警告が鳴った、または cache で解決していない (rc=$CACHE_QUIET_RC)"
  sed 's/^/    | /' "$WORK/cachequiet.log" >&2
fi

echo "-- --print-toolkit-root: 解決結果だけを出す契約 --"

# 消費側の hook / ゲートが sidecar を直接読むと、plugin 更新で sidecar が消えた版を
# 指したまま「ゲートは緑・記録だけが黙って止まる」（導入先で 2 回観測）。この契約は
# レビュー時と同じ resolve_toolkit を通し、解決したプラグインルートを stdout 1 行で返す。
# 下の 3 経路（cache 最大版 / 明示指定が不正 / どこにも無い）が Issue の AC そのもの。
#
# stdout と stderr は**分けて**取る。合流させると ℹ️ の診断行が stdout に混ざっても
# 「1 行だけ」の検査が通らない形で気づけるが、逆に stdout が空でも診断行で埋まって
# 「何か出た」に見える。契約は stdout だけなので、stdout を単独で検査する。
run_print_root() { # [env 代入...] -- <シム引数...>   （stdout→print.out / stderr→print.err）
  local -a envs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      *) envs+=("$1"); shift ;;
    esac
  done
  : > "$WORK/argv-print.log"
  PRINT_RC=0
  # codex の実体は**不在**に固定する。解決結果を出すだけの経路が「codex が無いから exit 4」で
  # 止まると、codex を持たない hook ホスト（CI・クラウド）で契約が成立しない。
  run_isolated_shim -u FF_DEV_TOOLKIT_ROOT ARGV_LOG="$WORK/argv-print.log" \
    ${envs[@]+"${envs[@]}"} CODEX_REVIEW_CODEX_BIN=/nonexistent/ff-codex-absent \
    bash "$PLACED" "$@" >"$WORK/print.out" 2>"$WORK/print.err" </dev/null || PRINT_RC=$?
}

# AC 1: cache に最新版があり sidecar が消えた版を指す → cache の最大版を 1 行・exit 0
# 比較は物理パスで行う。cache 経路の root は glob で列挙した生のパスで、TMPDIR が末尾 /
# を持つと `//` が混ざる（install-cases.sh の物理パス比較と同じ理由）。消費側にとって
# `//` は無害だが、文字列比較だと環境依存で赤になる。cd できること自体も契約の一部
# （存在しないディレクトリを 1 行返しても hook は動かない）なので、出力を cd して測る。
_print_want="$(cd "$CACHE_QUIET_HOME/plugins/cache/market/ff-dev-toolkit/0.38.0" && pwd -P)"
print_root_physical() { # $1: 出力された root（1 行）→ 物理パス。cd できなければ空
  ( cd "$1" 2>/dev/null && pwd -P ) || true
}
printf '%s\n' "$WORK/nonexistent-toolkit" > "$SIDECAR"
run_print_root CODEX_HOME="$CACHE_QUIET_HOME" CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 0 ] && [ "$(wc -l < "$WORK/print.out" | tr -d ' ')" -eq 1 ] \
   && [ "$(print_root_physical "$(cat "$WORK/print.out")")" = "$_print_want" ] \
   && [ ! -s "$WORK/argv-print.log" ]; then
  ok "--print-toolkit-root: stale sidecar より cache の最大版を選び、プラグインルートを stdout 1 行で返す（exit 0・委譲しない）"
else
  bad "--print-toolkit-root: stale sidecar + cache で期待の root を返さない (rc=$PRINT_RC)"
  sed 's/^/    | out: /' "$WORK/print.out" >&2
  sed 's/^/    | err: /' "$WORK/print.err" >&2
fi
if grep -q 'source=codex-cache' "$WORK/print.err" && ! grep -q 'source=' "$WORK/print.out"; then
  ok "--print-toolkit-root: 診断（ℹ️ version/source 行）は stderr に留まり stdout を汚さない"
else
  bad "--print-toolkit-root: 診断行が stdout に混ざる、または解決経路が cache でない"
fi

# 同じ状態で =kv は root / version / source の 3 行（消費側が版も要るときの 1 形式）
run_print_root CODEX_HOME="$CACHE_QUIET_HOME" CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root=kv
if [ "$PRINT_RC" -eq 0 ] && [ "$(wc -l < "$WORK/print.out" | tr -d ' ')" -eq 3 ] \
   && [ "$(print_root_physical "$(sed -n 's/^root=//p' "$WORK/print.out")")" = "$_print_want" ] \
   && grep -qxF "version=0.38.0" "$WORK/print.out" \
   && grep -qxF "source=codex-cache" "$WORK/print.out"; then
  ok "--print-toolkit-root=kv: root= / version= / source= の 3 行を返す"
else
  bad "--print-toolkit-root=kv の出力形式が契約と違う (rc=$PRINT_RC)"
  sed 's/^/    | out: /' "$WORK/print.out" >&2
fi

# 未知の形式は既定へ落とさず拒否する（kv のつもりで 1 行を受け取る事故を作らない）
run_print_root CODEX_HOME="$CACHE_QUIET_HOME" CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root=xml
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ]; then
  ok "--print-toolkit-root=<未知の形式> は exit 2・stdout 空"
else
  bad "--print-toolkit-root の未知形式が通った (rc=$PRINT_RC)"
fi

# AC 2: FF_DEV_TOOLKIT_ROOT が不正 → 使える cache があっても別候補へ落ちず exit 2・stdout 空
run_print_root FF_DEV_TOOLKIT_ROOT="$WORK/nonexistent-toolkit" CODEX_HOME="$CACHE_QUIET_HOME" \
  CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] \
   && grep -q '明示指定を黙って無視して別の toolkit で走ることはしません' "$WORK/print.err"; then
  ok "--print-toolkit-root: 不正な FF_DEV_TOOLKIT_ROOT は cache へ落ちず exit 2・stdout 空（fail closed はレビュー時と同じ）"
else
  bad "--print-toolkit-root: 不正な明示指定が別候補へ落ちた、または rc が違う (rc=$PRINT_RC)"
  sed 's/^/    | out: /' "$WORK/print.out" >&2
  sed 's/^/    | err: /' "$WORK/print.err" >&2
fi

# AC 3: どこにも無い（env なし・両 cache 空・sidecar は消えた版）→ exit 1・stdout 空
run_print_root CODEX_HOME="$WORK/empty-codex-home" CLAUDE_CONFIG_DIR="$WORK/empty-claude-home" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 1 ] && [ ! -s "$WORK/print.out" ] \
   && grep -q 'multi-agent.sh が見つかりません' "$WORK/print.err"; then
  ok "--print-toolkit-root: どこにも toolkit が無ければ exit 1・stdout 空（診断は stderr）"
else
  bad "--print-toolkit-root: 未解決時の rc / stdout が契約と違う (rc=$PRINT_RC)"
  sed 's/^/    | out: /' "$WORK/print.out" >&2
  sed 's/^/    | err: /' "$WORK/print.err" >&2
fi

# レビュー系オプションとの併用は拒否（黙ってレビューも出力も捨てない）。
# パーサの全分岐を回す: 委譲 argv を増やすもの（--base 以下）と、増やさずに専用変数だけを
# 立てるもの（--list-reviewers / --all-perspectives）の両方。委譲 argv を経由しないフラグを
# 足したときは、シム側の併用条件とこの一覧の両方へ足す（片方だけだと素通りが緑のまま通る）。
for _mix in "--base develop" "--staged" "--timeout 5" "--mode distributed" \
            "--reviewers code-review" "--exclude-reviewers comment-analysis" "--exclude-cli grok-cli" \
            "--review-context-file $WORK/review-context.txt" "--dry-run" "--fresh" "--resume" \
            "--list-reviewers" "--all-perspectives"; do
  # shellcheck disable=SC2086
  run_print_root CODEX_HOME="$CACHE_QUIET_HOME" CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root $_mix
  if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] && [ ! -s "$WORK/argv-print.log" ] \
     && grep -q '同時に指定できません' "$WORK/print.err"; then
    ok "--print-toolkit-root と '${_mix}' の併用は exit 2（委譲も出力もしない）"
  else
    bad "--print-toolkit-root と '${_mix}' の併用が通った (rc=$PRINT_RC)"
  fi
done

# --print-toolkit-root の後ろの --help も拒否する。素通しは usage を stderr へ出して exit 0・
# stdout 空になり、`root="$(...)"` の消費側が「成功して root が空」と読む唯一の経路になる。
run_print_root CODEX_HOME="$CACHE_QUIET_HOME" CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root --help
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] && grep -q -- '--help と同時に指定できません' "$WORK/print.err"; then
  ok "--print-toolkit-root --help は exit 2（exit 0 + stdout 空の経路を残さない）"
else
  bad "--print-toolkit-root --help が exit 0 で通った、または stdout に何か出た (rc=$PRINT_RC)"
fi

# FF_DEV_TOOLKIT_ROOT が妥当なら explicit として解決する（hook 側で上書き不要、の根拠）。
# run_shim は FF_DEV_TOOLKIT_ROOT=$TOOLKIT を渡す既定の起動口。
run_shim --print-toolkit-root=kv
_explicit_want="$(cd "$TOOLKIT" && pwd -P)"
if [ "$RUN_RC" -eq 0 ] && grep -qxF "source=explicit" "$WORK/stdout.log" \
   && [ "$(print_root_physical "$(sed -n 's/^root=//p' "$WORK/stdout.log")")" = "$_explicit_want" ] \
   && [ ! -s "$WORK/argv.log" ]; then
  ok "--print-toolkit-root: 妥当な FF_DEV_TOOLKIT_ROOT は source=explicit として返す（委譲しない）"
else
  bad "--print-toolkit-root: 明示指定が explicit として解決されない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# SKIP_CODEX_REVIEW はレビューの逃がし弁であって解決の逃がし弁ではない。
# pnpm が挟む -- も読み飛ばす（手順書の `pnpm x -- --print-toolkit-root` が動くこと）。
run_print_root SKIP_CODEX_REVIEW=1 CODEX_HOME="$CACHE_QUIET_HOME" CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- -- --print-toolkit-root
if [ "$PRINT_RC" -eq 0 ] && [ "$(print_root_physical "$(cat "$WORK/print.out")")" = "$_print_want" ]; then
  ok "--print-toolkit-root: SKIP_CODEX_REVIEW=1 でも解決結果を出す（-- の透過も読み飛ばす）"
else
  bad "--print-toolkit-root が SKIP_CODEX_REVIEW または -- に巻き込まれた (rc=$PRINT_RC)"
  sed 's/^/    | out: /' "$WORK/print.out" >&2
  sed 's/^/    | err: /' "$WORK/print.err" >&2
fi

# 版不整合（配置済みシムと解決先テンプレートの不一致）はレビュー時と同じく exit 2 で止める。
# ここを素通しにすると、hook は「解決できた root」で別版のスクリプトを叩く。
cp "$CACHE_QUIET_HOME/plugins/cache/market/ff-dev-toolkit/0.38.0/scripts/templates/codex-review.sh" "$WORK/print-template.good"
printf '\n# mismatch\n' >> "$CACHE_QUIET_HOME/plugins/cache/market/ff-dev-toolkit/0.38.0/scripts/templates/codex-review.sh"
run_print_root CODEX_HOME="$CACHE_QUIET_HOME" CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root
mv "$WORK/print-template.good" "$CACHE_QUIET_HOME/plugins/cache/market/ff-dev-toolkit/0.38.0/scripts/templates/codex-review.sh"
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] \
   && grep -q '配置済み shim の版が一致しません' "$WORK/print.err"; then
  ok "--print-toolkit-root: 配置済みシムとの版不整合はレビュー時と同じく exit 2・stdout 空"
else
  bad "--print-toolkit-root: 版不整合を素通しした (rc=$PRINT_RC)"
fi
printf '%s\n' "$FAKE/scripts" > "$SIDECAR"

cp "$TOOLKIT/scripts/agent-config.yaml" "$WORK/agent-config.good"
printf '%s\n' 'version: "2.0"' 'toolkit_version: "0.37.0"' > "$TOOLKIT/scripts/agent-config.yaml"
: > "$WORK/argv.log"
MISMATCH_RC=0
run_isolated_shim FF_DEV_TOOLKIT_ROOT="$TOOLKIT" ARGV_LOG="$WORK/argv.log" \
  bash "$PROJ/scripts/codex-review.sh" --base develop >"$WORK/mismatch.log" 2>&1 || MISMATCH_RC=$?
mv "$WORK/agent-config.good" "$TOOLKIT/scripts/agent-config.yaml"
if [ "$MISMATCH_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q 'agent-config.yaml が一致しません' "$WORK/mismatch.log"; then
  ok "版整合: plugin と agent-config の不一致をレビュー前に拒否する"
else
  bad "版整合: agent-config の不一致を拒否できない (rc=$MISMATCH_RC)"
fi

cp "$TOOLKIT/scripts/templates/codex-review.sh" "$WORK/template.good"
printf '\n# mismatched template\n' >> "$TOOLKIT/scripts/templates/codex-review.sh"
: > "$WORK/argv.log"
MISMATCH_RC=0
run_isolated_shim FF_DEV_TOOLKIT_ROOT="$TOOLKIT" ARGV_LOG="$WORK/argv.log" \
  bash "$PROJ/scripts/codex-review.sh" --base develop >"$WORK/mismatch.log" 2>&1 || MISMATCH_RC=$?
mv "$WORK/template.good" "$TOOLKIT/scripts/templates/codex-review.sh"
if [ "$MISMATCH_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q '配置済み shim の版が一致しません' "$WORK/mismatch.log"; then
  ok "版整合: 解決した toolkit と配置済み shim の不一致をレビュー前に拒否する"
else
  bad "版整合: shim の不一致を拒否できない (rc=$MISMATCH_RC)"
fi

# skill 群が使う正規形（プラグインルート指定）で解決できること。
: > "$WORK/argv.log"
run_isolated_shim FF_DEV_TOOLKIT_ROOT="$FAKE" ARGV_LOG="$WORK/argv.log" \
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

