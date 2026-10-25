#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: cache 解決順・版整合・--print-toolkit-root の契約・プラグインルート指定の正規形・配置先の既定。
# 依存: install-cases.sh が定義した ${FAKE} / ${PLACED} / ${SIDECAR} と、recovery-mode-cases.sh が作る ${WORK}/review-context.txt。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

echo "-- cache 解決順・版整合 --"

# 配布先 FFID の fallback-swallow:check は、判定値を作る代入内の `|| true` を
# 常時検出する。動作だけのテストでは旧コードも緑なので、正本の該当形も固定する。
VERSION_SWALLOW_RC=0
grep -nE '^[[:space:]]*(version|config_version)="\$\(.*\|\|[[:space:]]*(true|:)' "$SHIM" \
  > "$WORK/version-swallow.log" || VERSION_SWALLOW_RC=$?
if [ "$VERSION_SWALLOW_RC" -eq 1 ]; then
  ok "版読み取りの判定値を || true / || : で作らない"
else
  bad "版読み取りの握りつぶし形が残る、または検査できない (grep rc=$VERSION_SWALLOW_RC)"
  sed 's/^/    | /' "$WORK/version-swallow.log" >&2
fi

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

# 一致する旧候補を同居させず「一致候補なし」の拒否を測る。
CACHE_REJECT_HOME="$WORK/cache-reject-home"
make_cache_toolkit "$CACHE_REJECT_HOME/plugins/cache/market/ff-dev-toolkit/9.0.0" "9.0.0"
printf '\n# mismatch\n' >> "$CACHE_REJECT_HOME/plugins/cache/market/ff-dev-toolkit/9.0.0/scripts/templates/codex-review.sh"
printf '%s\n' "$FAKE/scripts" > "$SIDECAR"
: > "$WORK/argv-cache.log"
CACHE_RC=0
run_isolated_shim -u FF_DEV_TOOLKIT_ROOT CODEX_HOME="$CACHE_REJECT_HOME" \
  CLAUDE_CONFIG_DIR="$WORK/empty-claude-home" ARGV_LOG="$WORK/argv-cache.log" \
  bash "$PLACED" --base develop >"$WORK/cache.log" 2>&1 || CACHE_RC=$?
if [ "$CACHE_RC" -eq 2 ] && [ ! -s "$WORK/argv-cache.log" ] \
   && grep -q '配置済み shim が内容不一致です' "$WORK/cache.log" \
   && ! grep -q 'source=sidecar' "$WORK/cache.log"; then
  ok "cache: 内容一致候補が無ければ最大候補の不一致で止まり、sidecar へ落とさない"
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

# 壊れた cache 候補だけは警告してスキップする。明示 root や sidecar の
# 読み取り失敗と同じ hard-fail にすると、使える cache も選べなくなる。
BAD_CACHE_ROOT="$CACHE_QUIET_HOME/plugins/cache/market/ff-dev-toolkit/99.0.0"
make_cache_toolkit "$BAD_CACHE_ROOT" "99.0.0"
printf '%s\n' '{"name":"ff-dev-toolkit","version":"broken"}' > "$BAD_CACHE_ROOT/.claude-plugin/plugin.json"
run_print_root CODEX_HOME="$CACHE_QUIET_HOME" CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root=kv
if [ "$PRINT_RC" -eq 0 ] && grep -qxF 'version=0.38.0' "$WORK/print.out" \
   && grep -q 'cache 候補の安定版 version を読めないためスキップ' "$WORK/print.err"; then
  ok "cache: 不正な manifest は警告してスキップし、使える候補を選ぶ"
else
  bad "cache: 不正な manifest が使える候補まで塞いだ、または無警告で飛ばした (rc=$PRINT_RC)"
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

cp "$TOOLKIT/.claude-plugin/plugin.json" "$WORK/explicit-manifest.good"
printf '%s\n' '{"name":"ff-dev-toolkit","version":"broken"}' > "$TOOLKIT/.claude-plugin/plugin.json"
run_print_root FF_DEV_TOOLKIT_ROOT="$TOOLKIT" CODEX_HOME="$CACHE_QUIET_HOME" \
  CLAUDE_CONFIG_DIR="$WORK/no-claude-home" -- --print-toolkit-root
mv "$WORK/explicit-manifest.good" "$TOOLKIT/.claude-plugin/plugin.json"
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] \
   && grep -q 'FF_DEV_TOOLKIT_ROOT の plugin version を読めません' "$WORK/print.err"; then
  ok "明示 root: manifest が不正なら使える cache へ落ちず exit 2"
else
  bad "明示 root: 不正な manifest が cache へ落ちた、または rc が違う (rc=$PRINT_RC)"
fi

printf '%s\n' "$BAD_CACHE_ROOT/scripts" > "$SIDECAR"
run_print_root CODEX_HOME="$WORK/empty-codex-home" CLAUDE_CONFIG_DIR="$WORK/empty-claude-home" -- --print-toolkit-root
printf '%s\n' "$FAKE/scripts" > "$SIDECAR"
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] \
   && grep -q 'sidecar が指す toolkit の version を読めません' "$WORK/print.err"; then
  ok "sidecar: manifest が不正なら exit 2・stdout 空"
else
  bad "sidecar: 不正な manifest を拒否できない (rc=$PRINT_RC)"
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
   && grep -q '配置済み shim が内容不一致です' "$WORK/print.err"; then
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

mv "$TOOLKIT/scripts/agent-config.yaml" "$WORK/agent-config.missing"
run_print_root FF_DEV_TOOLKIT_ROOT="$TOOLKIT" CODEX_HOME="$WORK/empty-codex-home" \
  CLAUDE_CONFIG_DIR="$WORK/empty-claude-home" -- --print-toolkit-root
mv "$WORK/agent-config.missing" "$TOOLKIT/scripts/agent-config.yaml"
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] \
   && grep -q 'agent-config.yaml が一致しません' "$WORK/print.err"; then
  ok "版整合: agent-config が読めなくても exit 2・stdout 空"
else
  bad "版整合: agent-config の読み取り失敗を拒否できない (rc=$PRINT_RC)"
fi

cp "$TOOLKIT/scripts/templates/codex-review.sh" "$WORK/template.good"
printf '\n# mismatched template\n' >> "$TOOLKIT/scripts/templates/codex-review.sh"
: > "$WORK/argv.log"
MISMATCH_RC=0
run_isolated_shim FF_DEV_TOOLKIT_ROOT="$TOOLKIT" ARGV_LOG="$WORK/argv.log" \
  bash "$PROJ/scripts/codex-review.sh" --base develop >"$WORK/mismatch.log" 2>&1 || MISMATCH_RC=$?
mv "$WORK/template.good" "$TOOLKIT/scripts/templates/codex-review.sh"
if [ "$MISMATCH_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q '配置済み shim が内容不一致です' "$WORK/mismatch.log"; then
  ok "版整合: 解決した toolkit と配置済み shim の不一致をレビュー前に拒否する"
else
  bad "版整合: shim の不一致を拒否できない (rc=$MISMATCH_RC)"
fi

# 同じ manifest/config 版でも内容差を識別する。期待値は既知 LF fixture の raw blob
# から作り、本体の行末正規化をテスト側へ複製しない。
ID_KIT="$WORK/content-id-toolkit"
make_cache_toolkit "$ID_KIT" "0.38.0"
ID_KIT="$(cd "$ID_KIT" && pwd -P)"
printf '\n# content identity target\n' >> "$ID_KIT/scripts/templates/codex-review.sh"
ID_LF_TEMPLATE="$WORK/content-id-template.lf"
cp "$ID_KIT/scripts/templates/codex-review.sh" "$ID_LF_TEMPLATE"
ID_TEMPLATE_WANT="git-blob:$(git hash-object --no-filters "$ID_LF_TEMPLATE")"
ID_SHIM_WANT="git-blob:$(git hash-object --no-filters "$SHIM")"
content_ids_match() { # <log> <template ID> <shim ID>
  [ -n "$2" ] && [ -n "$3" ] || return 1
  grep -qxF "       template=$ID_KIT/scripts/templates/codex-review.sh content-id=$2" "$1" \
    && grep -qxF "       shim=$PLACED content-id=$3" "$1"
}
run_print_root FF_DEV_TOOLKIT_ROOT="$ID_KIT" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] && [ ! -s "$WORK/argv-print.log" ] \
   && [ "$ID_TEMPLATE_WANT" != "$ID_SHIM_WANT" ] \
   && content_ids_match "$WORK/print.err" "$ID_TEMPLATE_WANT" "$ID_SHIM_WANT" \
   && grep -q '配置済み shim が内容不一致です' "$WORK/print.err" \
   && grep -q '同じ版番号でも' "$WORK/print.err" \
   && grep -q 'toolkit=.* version=0.38.0' "$WORK/print.err" \
   && grep -q 'setup-multi-agent.sh.*再実行' "$WORK/print.err" \
   && grep -q '正規リリース版.*対象版の toolkit.*明示' "$WORK/print.err"; then
  ok "内容ID: 同じ版の差を両roleの正しいID・原因・対処で識別し、stdout空/rc2で止める"
else
  bad "内容ID: 同じ版の差の診断が不正 (rc=$PRINT_RC)"
fi

awk '{ printf "%s\r\n", $0 }' "$ID_LF_TEMPLATE" > "$ID_KIT/scripts/templates/codex-review.sh"
run_print_root FF_DEV_TOOLKIT_ROOT="$ID_KIT" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 2 ] && content_ids_match "$WORK/print.err" "$ID_TEMPLATE_WANT" "$ID_SHIM_WANT"; then
  ok "内容ID: CRLF template のIDは既知LF内容のIDと一致する"
else
  bad "内容ID: 行末CRが識別子へ混入した (rc=$PRINT_RC)"
fi
cp "$ID_LF_TEMPLATE" "$ID_KIT/scripts/templates/codex-review.sh"

# 読めない対象と、空の実ファイル（正規のblob）は別物。
rm "$ID_KIT/scripts/templates/codex-review.sh"
run_print_root FF_DEV_TOOLKIT_ROOT="$ID_KIT" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] \
   && [ ! -s "$WORK/argv-print.log" ] \
   && content_ids_match "$WORK/print.err" '(取得不可)' "$ID_SHIM_WANT" \
   && grep -q 'template が存在しません' "$WORK/print.err" \
   && ! grep -q '内容不一致\|内容が異なる場合' "$WORK/print.err"; then
  ok "内容ID: template不在は取得不可を名指しし、相手のIDで埋めずrc2"
else
  bad "内容ID: template不在の診断が不正 (rc=$PRINT_RC)"
fi
: > "$ID_KIT/scripts/templates/codex-review.sh"
ID_EMPTY_WANT="git-blob:$(git hash-object --no-filters "$ID_KIT/scripts/templates/codex-review.sh")"
run_print_root FF_DEV_TOOLKIT_ROOT="$ID_KIT" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 2 ] && content_ids_match "$WORK/print.err" "$ID_EMPTY_WANT" "$ID_SHIM_WANT" \
   && grep -q '配置済み shim が内容不一致です' "$WORK/print.err"; then
  ok "内容ID: 空実ファイルは正規のblob IDを出し、shimとの不一致でrc2"
else
  bad "内容ID: 空実ファイルを取得不可と混同した (rc=$PRINT_RC)"
fi
cp "$ID_LF_TEMPLATE" "$ID_KIT/scripts/templates/codex-review.sh"

# 権限で読めない template は内容差と断定しない。root は chmod の対照を分けて報告する。
chmod 000 "$ID_KIT/scripts/templates/codex-review.sh"
if [ -r "$ID_KIT/scripts/templates/codex-review.sh" ]; then
  echo "  ○ skip: chmod 000 でも読める環境のためtemplate権限の診断は未実測"
else
  run_print_root FF_DEV_TOOLKIT_ROOT="$ID_KIT" -- --print-toolkit-root
  if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] && [ ! -s "$WORK/argv-print.log" ] \
     && content_ids_match "$WORK/print.err" '(取得不可)' "$ID_SHIM_WANT" \
     && grep -q 'template を読み取れません' "$WORK/print.err" \
     && ! grep -q '内容不一致\|内容が異なる場合' "$WORK/print.err"; then
    ok "内容ID: template権限不足は読取り不能を名指しし、内容差と断定せずrc2"
  else
    bad "内容ID: template権限不足の原因が不正 (rc=$PRINT_RC)"
  fi
fi
chmod 644 "$ID_KIT/scripts/templates/codex-review.sh"

# 比較器と一時領域の失敗は、内容差にも一致にも倒さない。
ID_COMPARE_BIN="$WORK/content-compare-error"
mkdir -p "$ID_COMPARE_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'echo compare-error >> "$COMPARE_CALLS"' 'exit 2' > "$ID_COMPARE_BIN/cmp"
chmod +x "$ID_COMPARE_BIN/cmp"
: > "$WORK/compare-calls"
run_print_root FF_DEV_TOOLKIT_ROOT="$ID_KIT" PATH="$ID_COMPARE_BIN:$PATH" \
  COMPARE_CALLS="$WORK/compare-calls" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] && [ ! -s "$WORK/argv-print.log" ] \
   && [ -s "$WORK/compare-calls" ] \
   && grep -q '内容の一致を確認できません.*正規化入力の比較に失敗しました' "$WORK/print.err" \
   && ! grep -q '内容不一致\|内容が異なる場合' "$WORK/print.err"; then
  ok "内容比較: cmpの実行失敗は比較不能としてstdout空/rc2（不一致と断定しない）"
else
  bad "内容比較: cmp失敗を誤分類した、またはfixture未到達 (rc=$PRINT_RC)"
fi
run_print_root FF_DEV_TOOLKIT_ROOT="$TOOLKIT" TMPDIR="$WORK/absent-temp-parent" -- --print-toolkit-root
if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] && [ ! -s "$WORK/argv-print.log" ] \
   && grep -q '内容の一致を確認できません.*比較用の一時ディレクトリを作成できません' "$WORK/print.err" \
   && ! grep -q '内容不一致\|内容が異なる場合' "$WORK/print.err"; then
  ok "内容比較: 一時領域を作れない回は同内容でも比較不能としてstdout空/rc2"
else
  bad "内容比較: 一時領域失敗を一致/不一致へ倒した (rc=$PRINT_RC)"
fi

# git が無くても cmp で確定した不一致は変えない。解決に必要なコマンドだけの PATH。
ID_NO_GIT="$WORK/content-id-no-git"
mkdir -p "$ID_NO_GIT"
for id_name in bash basename dirname sed grep cmp mktemp rm cat; do
  id_command="$(command -v "$id_name")"
  ln -s "$id_command" "$ID_NO_GIT/$id_name"
done
if env PATH="$ID_NO_GIT" bash -c 'command -v git' >/dev/null 2>&1; then
  bad "内容ID: git不在fixtureの隔離が失敗した"
else
  run_print_root FF_DEV_TOOLKIT_ROOT="$ID_KIT" PATH="$ID_NO_GIT" -- --print-toolkit-root
  if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] && [ ! -s "$WORK/argv-print.log" ] \
     && content_ids_match "$WORK/print.err" '(取得不可)' '(取得不可)' \
     && grep -q '配置済み shim が内容不一致です' "$WORK/print.err" \
     && grep -q '内容 ID を取得できません' "$WORK/print.err" \
     && ! grep -q '内容の一致を確認できません' "$WORK/print.err"; then
    ok "内容ID: git不在でも比較で確定した内容不一致を保持し、ID取得不可は補足にする"
  else
    bad "内容ID: git不在が確定した不一致の原因を変えた (rc=$PRINT_RC)"
  fi
fi

# 正常一致ではhashを呼ばない。故障は対象プリミティブだけへ注入し、他のgit/sedは実体へ転送。
ID_REAL_GIT="$(command -v git)"
ID_REAL_SED="$(command -v sed)"
ID_FAULT_CASES=0
for id_mode in partial empty warning read; do
  ID_BIN="$WORK/content-id-$id_mode"
  mkdir -p "$ID_BIN"
  printf '%s\n' "$id_mode" > "$ID_BIN/mode"
  printf '%s\n' "$ID_KIT/scripts/templates/codex-review.sh" > "$ID_BIN/target"
  : > "$ID_BIN/hash-calls"
  {
    cat <<'ID_GIT'
#!/usr/bin/env bash
stub_dir="$(dirname "$0")"
if [ "${1:-}" = hash-object ] && [ "${2:-}" = --stdin ]; then
  echo hash >> "$stub_dir/hash-calls"
  case "$(cat "$stub_dir/mode")" in
    partial) cat >/dev/null; echo 1111111111111111111111111111111111111111; exit 9 ;;
    empty) cat >/dev/null; exit 0 ;;
    warning) echo 'id fixture: successful git warning' >&2 ;;
    read) ;;
    *) exit 97 ;;
  esac
fi
ID_GIT
    printf 'exec %q "$@"\n' "$ID_REAL_GIT"
  } > "$ID_BIN/git"
  {
    cat <<'ID_SED'
#!/usr/bin/env bash
stub_dir="$(dirname "$0")"
if [ "$(cat "$stub_dir/mode")" = read ] && [ "${2:-}" = "$(cat "$stub_dir/target")" ]; then
  echo unreadable >> "$stub_dir/read-calls"
  echo 'id fixture: cannot read template' >&2
  exit 7
fi
ID_SED
    printf 'exec %q "$@"\n' "$ID_REAL_SED"
  } > "$ID_BIN/sed"
  chmod +x "$ID_BIN/git" "$ID_BIN/sed"
  run_print_root FF_DEV_TOOLKIT_ROOT="$ID_KIT" PATH="$ID_BIN:$PATH" -- --print-toolkit-root
  ID_FAULT_CASES=$((ID_FAULT_CASES + 1))
  id_template='(取得不可)'; id_shim='(取得不可)'
  case "$id_mode" in
    warning) id_template="$ID_TEMPLATE_WANT"; id_shim="$ID_SHIM_WANT" ;;
    read) id_shim="$ID_SHIM_WANT" ;;
  esac
  if [ "$PRINT_RC" -eq 2 ] && [ ! -s "$WORK/print.out" ] && [ ! -s "$WORK/argv-print.log" ] \
     && [ "$(wc -l < "$ID_BIN/hash-calls" | tr -d ' ')" -eq 2 ] \
     && content_ids_match "$WORK/print.err" "$id_template" "$id_shim"; then
    case "$id_mode" in
      warning)
        if grep -q 'successful git warning' "$WORK/print.err"; then
          ok "内容ID: git成功時のstderrをIDへ混ぜない（呼出し2件）"
        else bad "内容ID: warning対照へ到達していない"; fi ;;
      read)
        if [ -s "$ID_BIN/read-calls" ] && grep -q '内容の一致を確認できません.*正規化入力を読み取れません' "$WORK/print.err" \
           && ! grep -q '内容不一致\|内容が異なる場合' "$WORK/print.err"; then
          ok "内容ID: 読取り失敗後の空blob出力を採用せず、失敗側だけ取得不可（呼出し2件）"
        else bad "内容ID: 読取り失敗対照へ到達していない"; fi ;;
      *)
        if grep -q '配置済み shim が内容不一致です' "$WORK/print.err" \
           && grep -q '内容 ID を取得できません' "$WORK/print.err"; then
          ok "内容ID: hash $id_mode 出力は両側とも取得不可でも内容不一致を保持（呼出し2件）"
        else bad "内容ID: hash $id_mode が確定した不一致を変えた"; fi ;;
    esac
  else
    bad "内容ID: hash/読取り $id_mode の失敗をIDにした、または対照未到達 (rc=$PRINT_RC)"
  fi
  run_print_root FF_DEV_TOOLKIT_ROOT="$TOOLKIT" PATH="$ID_BIN:$PATH" -- --print-toolkit-root
  if [ "$PRINT_RC" -eq 0 ] && [ "$(wc -l < "$ID_BIN/hash-calls" | tr -d ' ')" -eq 2 ]; then
    ok "内容ID: 正常一致では追加hashなし ($id_mode)"
  else
    bad "内容ID: 正常一致へhash依存を追加した ($id_mode rc=$PRINT_RC)"
  fi
 done
if [ "$ID_FAULT_CASES" -eq 4 ]; then
  ok "内容ID: hash/読取り故障のcase集合は4件すべて実行済み"
else
  bad "内容ID: hash/読取り故障のcase集合が空または不足 ($ID_FAULT_CASES)"
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
