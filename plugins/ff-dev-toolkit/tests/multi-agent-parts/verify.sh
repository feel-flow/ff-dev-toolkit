#!/usr/bin/env bash
#
# multi-agent.sh の分割（入口 + 開始時に source する構成ファイル）の契約検査（ADR-075）。
#
# multi-agent.sh は本体を責務ごとに scripts/lib/multi-agent-*.sh へ分け、入口の
# MULTI_AGENT_PARTS の順で開始時に 1 回だけ source する。CLI の完走後の工程は plugin root から
# 何も読まない（ADR-073）。本 suite が固定するもの:
#   A. 名簿と実体の一致: MULTI_AGENT_PARTS（tests/lib/multi-agent-sources.sh が読む）と
#      scripts/lib/multi-agent-*.sh の集合が等しい。名簿から漏れた構成ファイルは読まれず、
#      名簿にだけある構成ファイルは起動を止める
#   B. 行数: 入口と各構成ファイルが docs/MASTER.md の「分割を必須」の閾値（1200 行）以下。
#      分割前の 1 本は変更のたびに伸びていたので、閾値を越えた時点で赤にして分け直しを促す
#   C. 構成ファイルの形: 1 行目が shebang（shellcheck の SC2148 を避ける）、行頭の
#      `# pipefail-inherited:` 宣言がある（pipefail を入口から継承するので、宣言が無いと
#      tests/lib/pipefail-grep-q.sh の検出器が無検査にする）、最後の行が読み込み完了の印
#      `_ma_part_loaded="<名前>"`、root guard の写しを持たない（source 先で BASH_SOURCE が変わり、
#      guard が別の root を名乗って止まる）、adapter-common.sh を読み直さない（readonly の
#      再代入で set -e が落ちる）、トップレベルに set / trap を持たない、コマンドとしての
#      source / . を持たない（構成ファイルは入口の名簿の順でだけ読まれる。ADR-075 決定 3）
#   D. 読み込みの停止: 置き場の scripts/lib が symlink、構成ファイルが不在・symlink・空・読めない・
#      途中で切れている（関数の境界で切れた形と関数の途中で切れた形の両方）とき、CLI を 1 つも
#      起動する前に rc=2 と ADR-036 の案内（別の版を探さない）で止まる。root guard も rc=2 で
#      同じ書き出しの案内を出すので、読み込み部に固有の文言があり guard の文言が無いことまで
#      見る。揃っていれば --help が rc=0 で、同じ起動形で stub の CLI が実際に起動する（「CLI を
#      起動していない」の判定が空振りしていないことの正対照）
#   E. registry の境界外検査が構成ファイルにも掛かる: get_cli_* の定義・ALL_CLIS への書き込み・
#      registry 区間そのものを構成ファイルへ置くと、cli_registry_load が名指しで拒否する
#   F. adapter-common.sh の分割: 入口と scripts/lib/adapter-common-*.sh が 1200 行以下。
#      構成ファイルは shebang・pipefail 継承の宣言・末尾の読み込み完了の印を持ち、
#      root guard の写しと adapter-common.sh の読み直しとコマンドとしての source を持たない。
#      本文に元からある trap は禁止しない。構成ファイルが不在・空・途中で切れている・
#      symlink のとき、入口の source が rc=2 と ADR-036 の案内
#      （「CLI はまだ 1 つも起動していません。」）で止まる。揃った入口の source は
#      rc=0 で cli_available を定義する
#
# 空振り検出: 名簿の区間を消した入口では ma_sources_load が「名簿（1 件以上）が見つかりません」で赤、構成ファイルが 0 本の写しでは「名簿の構成ファイルがありません」で赤（どちらも本 suite の (A) / (E) 末尾で毎回実測する）。(C) の source 検査は、構成ファイルの関数の中へ `source x` を足した写しで赤になる（毎回実測する）。
# 空振り検出: 入口の「ファイルが無い」分岐を外した写しを与えると、「構成ファイルの不在: rc=2 と読み込み部の案内で止まらない」の 1 件だけが赤になる（2026-10-21 実測。成功 59。判定は rc=2 のまま、針「がありません」が外れ、次の分岐の「が 0 バイトです」になる。CLI は起動しない）。
# 依存は bash 3.2・POSIX ユーティリティ・mktemp。一時領域が無いと (D) / (E) と空振りの実測が
# 成立しないので、skip せず赤にする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
SCRIPTS="$PLUGIN_ROOT/scripts"
ENTRY="$SCRIPTS/multi-agent.sh"
MASTER_SPLIT_LIMIT=1200

# shellcheck source=../lib/multi-agent-sources.sh
. "$SCRIPT_DIR/../lib/multi-agent-sources.sh"
# shellcheck source=../lib/cli-registry-parser.sh
. "$SCRIPT_DIR/../lib/cli-registry-parser.sh"
# shellcheck source=../lib/adapter-common-sources.sh
. "$SCRIPT_DIR/../lib/adapter-common-sources.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "✗ multi-agent-parts: 一時ディレクトリを作れません（(D) / (E) と空振りの実測が成立しないので赤にする）: ${_ff_mktemp_out}" >&2
  exit 1
fi
FF_REACHED_END=0
cleanup() {
  local rc=$?
  chmod -R u+rwX "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
  if [ "$rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ multi-agent-parts: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

[ -f "$ENTRY" ] || { echo "✗ 入口がありません: $ENTRY" >&2; exit 1; }

echo "== (A) 名簿と実体の一致 =="
ma_sources_load "$SCRIPTS"
LISTED="$(for f in "${MA_SOURCES[@]:1}"; do printf '%s\n' "${f##*/}"; done | LC_ALL=C sort)"
ON_DISK=""
for f in "$SCRIPTS"/lib/multi-agent-*.sh; do
  [ -e "$f" ] || continue
  ON_DISK="${ON_DISK}${f##*/}"$'\n'
done
ON_DISK="$(printf '%s' "$ON_DISK" | LC_ALL=C sort)"
if [ -z "$ON_DISK" ]; then
  bad "scripts/lib/multi-agent-*.sh の構成ファイルがありません（集合比較が空振りしている）"
elif [ "$LISTED" = "$ON_DISK" ]; then
  ok "MULTI_AGENT_PARTS と scripts/lib/multi-agent-*.sh が一致（$(printf '%s\n' "$ON_DISK" | awk 'END { print NR }') 本）"
else
  bad "MULTI_AGENT_PARTS と scripts/lib/multi-agent-*.sh が一致しない"
  diff <(printf '%s\n' "$LISTED") <(printf '%s\n' "$ON_DISK") | sed 's/^/    | /' >&2 || true
fi

# 空振りの実測: 名簿の区間を消した入口では読み出しそのものが赤になる
NOLIST="$TMP/nolist/scripts"
mkdir -p "$NOLIST"
sed 's/^MULTI_AGENT_PARTS=($/_removed_parts_list=(/' "$ENTRY" > "$NOLIST/multi-agent.sh"
if cmp -s "$ENTRY" "$NOLIST/multi-agent.sh"; then
  bad "空振りの実測: 名簿の区間を消す変異を注入できない（入口の書式が変わった）"
elif ( ma_sources_load "$NOLIST" ) >/dev/null 2>&1; then
  bad "空振りの実測: 名簿の区間が無い入口でも ma_sources_load が通る"
else
  ok "空振りの実測: 名簿の区間が無い入口は ma_sources_load が拒否する"
fi

echo "== (B) 行数（docs/MASTER.md の分割必須の閾値 ${MASTER_SPLIT_LIMIT} 行以下） =="
for f in "${MA_SOURCES[@]}"; do
  n="$(wc -l < "$f" | tr -d ' ')"
  if [ "$n" -le "$MASTER_SPLIT_LIMIT" ]; then
    ok "${f#"$PLUGIN_ROOT"/}: ${n} 行"
  else
    bad "${f#"$PLUGIN_ROOT"/}: ${n} 行（${MASTER_SPLIT_LIMIT} 行を超えた。責務ごとに構成ファイルを分け直す — 手順は ADR-075）"
  fi
done

echo "== (C) 構成ファイルの形 =="
# コマンドとしての source / . （行頭の空白の後。コメント行は除く）を持つか
has_source_command() { # <file>。パイプの下流に grep -q を置かない（pipefail 下で一致が反転する）
  awk '/^[[:space:]]*#/ { next } /^[[:space:]]*(source|\.)[[:space:]]/ { found = 1; exit } END { exit !found }' "$1"
}
_src_probe="$TMP/source-probe.sh"
{ printf '%s\n' 'f() {'; printf '  %s\n' 'source "$x"'; printf '%s\n' '}'; } > "$_src_probe"
if has_source_command "$_src_probe"; then
  ok "空振りの実測: 関数の中へ source を足した写しは source 検査が拒否する"
else
  bad "空振りの実測: 関数の中の source を source 検査が見つけられない"
fi
for f in "${MA_SOURCES[@]:1}"; do
  name="${f##*/}"
  problems=""
  IFS= read -r first < "$f" || first=""
  [ "$first" = "#!/usr/bin/env bash" ] || problems="${problems} 1行目がshebangでない"
  grep -q '^# pipefail-inherited:' "$f" || problems="${problems} pipefail-inherited宣言が無い"
  last="$(awk 'NF { l = $0 } END { print l }' "$f")"
  [ "$last" = "_ma_part_loaded=\"${name}\"" ] || problems="${problems} 最後の行が読み込み完了の印でない"
  if grep -q 'ff-dev-toolkit-script-root-guard:' "$f"; then
    problems="${problems} root-guardの写しがある"
  fi
  if grep -qE '^[[:space:]]*(source|\.)[[:space:]].*adapter-common\.sh' "$f"; then
    problems="${problems} adapter-common.shを読み直している"
  fi
  if grep -qE '^(set|trap)[[:space:]]' "$f"; then
    problems="${problems} トップレベルにset/trapがある"
  fi
  if has_source_command "$f"; then
    problems="${problems} sourceがある"
  fi
  if [ -z "$problems" ]; then
    ok "${name}: shebang・pipefail 継承の宣言・末尾の読み込み完了の印あり、guard の写し / adapter-common の読み直し / トップレベルの set・trap / source なし"
  else
    bad "${name}:${problems}"
  fi
done

echo "== (D) 読み込みの停止（写しで実測） =="
# 写しは scripts/ と manifest だけ。handoff を外して直接起動として走らせ、root guard の判定を
# 本 suite の関心（構成ファイルの読み込み）から切り離す。
make_copy() { # <dir>
  mkdir -p "$1/.claude-plugin"
  cp -R "$SCRIPTS" "$1/scripts"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$1/.claude-plugin/plugin.json"
}
STUB="$TMP/bin"
mkdir -p "$STUB"
LAUNCH_MARK="$TMP/cli-launched"
for cli in codex claude grok copilot; do
  printf '#!/usr/bin/env bash\n: > "%s"\necho stub\n' "$LAUNCH_MARK" > "$STUB/$cli"
  chmod +x "$STUB/$cli"
done
WORKDIR="$TMP/work"
mkdir -p "$WORKDIR"
run_copy() { # <copy dir> <log> args...
  local dir="$1" log="$2"
  shift 2
  ( cd "$WORKDIR" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
      -u MULTI_AGENT_CONFIG PATH="$STUB:$PATH" bash "$dir/scripts/multi-agent.sh" "$@" ) > "$log" 2>&1
}

INTACT="$TMP/intact"
make_copy "$INTACT"
rc=0
run_copy "$INTACT" "$TMP/intact.log" --help || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Usage:' "$TMP/intact.log"; then
  ok "構成ファイルが揃った写しは --help が rc=0"
else
  bad "構成ファイルが揃った写しの --help が通らない (rc=${rc})"
  tail -5 "$TMP/intact.log" | sed 's/^/    | /' >&2
fi

# 停止の各ケースと同じ起動形。codex-cli は版の確認と自動更新（npm / Homebrew）を起動前に試みるので
# 使わない。stub の claude だけを起こす
STOP_PROBE_ARGS=(--task explore --description probe --cli claude-code --timeout 30)
# 正対照: 構成ファイルが揃った写しは同じ起動形で stub の CLI を実際に起こす。起きなければ、
# 下の「CLI を起動していない」は何も測っていない
rm -f "$LAUNCH_MARK"
rc=0
run_copy "$INTACT" "$TMP/intact-launch.log" "${STOP_PROBE_ARGS[@]}" || rc=$?
if [ -e "$LAUNCH_MARK" ]; then
  ok "正対照: 構成ファイルが揃った写しは同じ起動形で stub の CLI を起動する (rc=${rc})"
else
  bad "正対照: 構成ファイルが揃った写しでも stub の CLI が起動しない（停止ケースの「CLI 未起動」が空振りする。rc=${rc}）"
  tail -6 "$TMP/intact-launch.log" | sed 's/^/    | /' >&2
fi

if [ -f "$SCRIPT_DIR/../lib/msys-case.sh" ]; then
  # shellcheck source=../lib/msys-case.sh
  . "$SCRIPT_DIR/../lib/msys-case.sh"
fi
# <ラベル> <「構成ファイル」に続く理由の文言> <写しの名前> <写しの scripts/lib で壊すコマンド...>
expect_stop() {
  local label="$1" reason="$2" dir="$TMP/broken-$3" log="$TMP/stop-$3.log"
  shift 3
  rm -rf "$dir"
  make_copy "$dir"
  ( cd "$dir/scripts/lib" && "$@" )
  rm -f "$LAUNCH_MARK"
  rc=0
  run_copy "$dir" "$log" "${STOP_PROBE_ARGS[@]}" || rc=$?
  # 置き場は adapter-common.sh と共有する。orchestrator は loader より前に
  # adapter-common.sh を source するので、symlink の置き場はそちらが先に止める。
  # 案内の主体はどちらか一方。ファイル単位の理由は multi-agent.sh のまま。
  local subject_hit=0
  if grep -F "ff-dev-toolkit更新後にこのskillを再呼び出してください（multi-agent.sh の構成ファイル${reason}）" "$log" >/dev/null; then
    subject_hit=1
  fi
  if grep -F "ff-dev-toolkit更新後にこのskillを再呼び出してください（adapter-common.sh の構成ファイル${reason}）" "$log" >/dev/null; then
    subject_hit=1
  fi
  if [ "$rc" -eq 2 ] \
    && [ "$subject_hit" -eq 1 ] \
    && grep -F '別のインストール領域へ切り替えて実行しないこと' "$log" >/dev/null \
    && ! grep -F 'plugin rootが固定値と一致しません' "$log" >/dev/null \
    && [ ! -e "$LAUNCH_MARK" ]; then
    ok "${label}: CLI を起動する前に rc=2 と再呼び出しの案内で止まる（root guard の停止ではない）"
  else
    bad "${label}: rc=2 と読み込み部の案内で止まらない、または CLI を起動した (rc=${rc}, CLI 起動=$([ -e "$LAUNCH_MARK" ] && echo あり || echo なし))"
    tail -6 "$log" | sed 's/^/    | /' >&2
  fi
}
msys_skip() { # <理由>。MSYS / Cygwin で ln -s がコピーになるケースだけを字下げの skip にする
  declare -F ff_skip_msys_case >/dev/null 2>&1 && ff_skip_msys_case "${OSTYPE:-}" "$1"
}
expect_stop "構成ファイルの不在" "がありません" missing rm -f multi-agent-report.sh
if ! msys_skip "構成ファイルの symlink（ln -s がコピーになる）"; then
  expect_stop "構成ファイルが symlink" "が symlink です" symlink sh -c 'mv multi-agent-plan.sh plan.real && ln -s plan.real multi-agent-plan.sh'
fi
if ! msys_skip "置き場 scripts/lib の symlink（ln -s がコピーになる）"; then
  # 置き場ごと別の場所（別のインストール領域を模す）へ向ける。構成ファイル自体は通常ファイル。
  # 通常の起動は adapter-common.sh が先に止まる（共有の置き場を source 時に見る）。
  expect_stop "置き場 scripts/lib が symlink" "の置き場が通常のディレクトリではないか symlink です" libdir \
    sh -c 'cd .. && mv lib lib.elsewhere && ln -s lib.elsewhere lib'
  # multi-agent.sh 自身の分岐は、adapter-common.sh が先に exit するため通常経路では到達しない。
  # 入口を検査だけの stub に差し替えると、その分岐が残っていることを測れる。
  dir="$TMP/broken-libdir-ma"
  log="$TMP/stop-libdir-ma.log"
  rm -rf "$dir"
  make_copy "$dir"
  printf '%s\n' '#!/usr/bin/env bash' '# stub: 置き場の検査を multi-agent.sh に残す' ':' \
    > "$dir/scripts/adapters/adapter-common.sh"
  ( cd "$dir/scripts/lib" && sh -c 'cd .. && mv lib lib.elsewhere && ln -s lib.elsewhere lib' )
  rm -f "$LAUNCH_MARK"
  rc=0
  run_copy "$dir" "$log" "${STOP_PROBE_ARGS[@]}" || rc=$?
  if [ "$rc" -eq 2 ] \
    && grep -qF 'ff-dev-toolkit更新後にこのskillを再呼び出してください（multi-agent.sh の構成ファイルの置き場が通常のディレクトリではないか symlink です）' "$log" \
    && grep -qF '別のインストール領域へ切り替えて実行しないこと' "$log" \
    && [ ! -e "$LAUNCH_MARK" ]; then
    ok "置き場 scripts/lib が symlink: adapter-common を stub にすると multi-agent.sh の案内で止まる"
  else
    bad "置き場 scripts/lib が symlink: multi-agent.sh 自身の案内で止まらない (rc=${rc})"
    tail -8 "$log" | sed 's/^/    | /' >&2
  fi
fi
expect_stop "構成ファイルが空" "が 0 バイトです" empty sh -c ': > multi-agent-lanes.sh'
# 関数の境界で切れたファイルは構文としては読めてしまう（定義が足りないまま CLI が走り、完走後に
# 落ちる）。関数の途中で切れたファイルは source が構文エラーで落ち、案内を出す前に set -e で
# 止まる。どちらも source の前に最後の行の読み込み完了の印を照合して見分ける
expect_stop "構成ファイルが関数の境界で切れている" "が末尾まで読めていません（最後の行が読み込み完了の印ではありません）" truncated \
  sh -c 'grep -v "^_ma_part_loaded=" multi-agent-report.sh > cut.tmp && mv cut.tmp multi-agent-report.sh'
expect_stop "構成ファイルが関数の途中で切れている" "が末尾まで読めていません（最後の行が読み込み完了の印ではありません）" midfunc \
  sh -c 'n="$(grep -n "^generate_explore_report() {" multi-agent-report.sh | cut -d: -f1)" && [ -n "$n" ] && head -n "$((n + 2))" multi-agent-report.sh > cut.tmp && mv cut.tmp multi-agent-report.sh'
probe="$TMP/readable-probe"
: > "$probe"
chmod 000 "$probe"
if [ -r "$probe" ]; then
  # root と MSYS は mode 000 でも読めるので、読み取り不可の状態を作れない
  echo "  ○ skip: 構成ファイルが読めない場合（mode 000 でも読める実行者。root か MSYS で走っている）"
else
  expect_stop "構成ファイルが読めない" "を読み取れません" unreadable chmod 000 multi-agent-advice.sh
fi
chmod 600 "$probe"

echo "== (E) registry の境界外検査が構成ファイルにも掛かる =="
if cli_registry_load "${MA_SOURCES[@]}"; then
  ok "入口と構成ファイルの全体で registry の静的解析が通る"
else
  bad "入口と構成ファイルの registry 解析が通らない: ${CLI_REGISTRY_ERROR}"
fi
REG="$TMP/registry"
# <ラベル> <期待するエラー断片> <注入先の構成ファイル名> <追記する行>
expect_registry_reject() {
  local label="$1" needle="$2" part="$3" line="$4" dir
  dir="$REG/$part-${#line}"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$SCRIPTS" "$dir/scripts"
  printf '\n%s\n' "$line" >> "$dir/scripts/lib/$part"
  ma_sources_load "$dir/scripts"
  if cli_registry_load "${MA_SOURCES[@]}"; then
    bad "${label}: 構成ファイル ${part} への注入を受理した"
  elif [[ "$CLI_REGISTRY_ERROR" == *"$part"*"$needle"* ]]; then
    ok "${label}: ${part} を名指しして拒否する"
  else
    bad "${label}: 拒否したが名指しが違う: ${CLI_REGISTRY_ERROR}"
  fi
}
# shellcheck disable=SC2016 # 注入する shell 行そのもの
expect_registry_reject "get_cli_* の定義" "registry 境界外で定義できません" multi-agent-report.sh 'get_cli_command() { echo x; }'
expect_registry_reject "ALL_CLIS への書き込み" "registry 境界外で書き換えられません" multi-agent-plan.sh 'ALL_CLIS="claude-code"'
ma_sources_load "$SCRIPTS"

# registry 区間を構成ファイルへ移すと、入口だけを読む templates/codex-review.sh の候補導出が
# 黙って空になる。parser は区間が入口に無いことを拒否する。
MOVED="$TMP/registry-moved"
mkdir -p "$MOVED"
cp -R "$SCRIPTS" "$MOVED/scripts"
awk -v part="$MOVED/scripts/lib/multi-agent-lanes.sh" '
  $0 == "# ── All known CLI names ──" { inside = 1 }
  inside { print >> part; if ($0 == "# ── CLI Registry End ──") inside = 0; next }
  { print }
' "$ENTRY" > "$MOVED/scripts/multi-agent.sh"
ma_sources_load "$MOVED/scripts"
if cli_registry_load "${MA_SOURCES[@]}"; then
  bad "registry 区間を構成ファイルへ移しても受理した"
elif [[ "$CLI_REGISTRY_ERROR" == *"レジストリ境界が入口にありません"* ]]; then
  ok "registry 区間を構成ファイルへ移すと「入口にありません」で拒否する"
else
  bad "registry 区間の移動を拒否したが理由が違う: ${CLI_REGISTRY_ERROR}"
fi
ma_sources_load "$SCRIPTS"

# 空振りの実測: 構成ファイルが 0 本の写しは ma_sources_load が「名簿の構成ファイルがありません」で拒否する
EMPTY="$TMP/no-parts/scripts"
mkdir -p "$EMPTY/lib"
cp "$ENTRY" "$EMPTY/multi-agent.sh"
if ( ma_sources_load "$EMPTY" ) >/dev/null 2>&1; then
  bad "空振りの実測: 構成ファイルが 0 本でも ma_sources_load が通る"
else
  ok "空振りの実測: 構成ファイルが 0 本の写しは ma_sources_load が拒否する"
fi

echo "== (F) adapter-common.sh の構成ファイル =="
AC_ENTRY="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
ac_sources_load "$AC_ENTRY"
for f in "${AC_SOURCES[@]}"; do
  n="$(wc -l < "$f" | tr -d ' ')"
  if [ "$n" -le "$MASTER_SPLIT_LIMIT" ]; then
    ok "${f#"$PLUGIN_ROOT"/}: ${n} 行"
  else
    bad "${f#"$PLUGIN_ROOT"/}: ${n} 行（${MASTER_SPLIT_LIMIT} 行を超えた。責務ごとに構成ファイルを分け直す — 手順は ADR-075）"
  fi
done
_ac_i=0
for f in "${AC_SOURCES[@]}"; do
  if [ "$_ac_i" -eq 0 ]; then
    _ac_i=1
    continue
  fi
  name="${f##*/}"
  problems=""
  IFS= read -r first < "$f" || first=""
  [ "$first" = "#!/usr/bin/env bash" ] || problems="${problems} 1行目がshebangでない"
  grep -q '^# pipefail-inherited:' "$f" || problems="${problems} pipefail-inherited宣言が無い"
  last="$(awk 'NF { l = $0 } END { print l }' "$f")"
  [ "$last" = "_ac_part_loaded=\"${name}\"" ] || problems="${problems} 最後の行が読み込み完了の印でない"
  if grep -q 'ff-dev-toolkit-script-root-guard:' "$f"; then
    problems="${problems} root-guardの写しがある"
  fi
  if grep -qE '^[[:space:]]*(source|\.)[[:space:]].*adapter-common\.sh' "$f"; then
    problems="${problems} adapter-common.shを読み直している"
  fi
  if grep -qE '^set[[:space:]]' "$f"; then
    problems="${problems} トップレベルにsetがある"
  fi
  if has_source_command "$f"; then
    problems="${problems} sourceがある"
  fi
  if [ -z "$problems" ]; then
    ok "${name}: shebang・pipefail 継承の宣言・末尾の読み込み完了の印あり、guard の写し / adapter-common の読み直し / トップレベルの set / source なし"
  else
    bad "${name}:${problems}"
  fi
done

rc=0
ac_out="$(bash -c 'set -euo pipefail; . "$1"; declare -F cli_available' _ "$AC_ENTRY" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [[ "$ac_out" == *cli_available* ]]; then
  ok "正対照: 入口を source すると rc=0 で cli_available が定義される"
else
  bad "正対照: 入口の source が rc=0 で cli_available を定義しない (rc=${rc})"
  printf '%s\n' "$ac_out" | tail -6 | sed 's/^/    | /' >&2
fi

# <ラベル> <「構成ファイル」に続く理由の文言> <写しの名前> <写しの lib で壊すコマンド...>
ac_expect_stop() {
  local label="$1" reason="$2" name="$3" dir log rc
  shift 3
  dir="$TMP/ac-broken-$name"
  log="$TMP/ac-stop-$name.log"
  rm -rf "$dir"
  mkdir -p "$dir/adapters" "$dir/lib"
  cp "$AC_ENTRY" "$dir/adapters/adapter-common.sh"
  cp "$PLUGIN_ROOT"/scripts/lib/adapter-common-*.sh "$dir/lib/"
  ( cd "$dir/lib" && "$@" )
  rc=0
  bash -c 'set -euo pipefail; . "$1"' _ "$dir/adapters/adapter-common.sh" >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] \
    && grep -qF "ff-dev-toolkit更新後にこのskillを再呼び出してください（adapter-common.sh の構成ファイル${reason}）" "$log" \
    && grep -qF 'CLI はまだ 1 つも起動していません。' "$log" \
    && grep -qF '別のインストール領域へ切り替えて実行しないこと' "$log"; then
    ok "${label}: source の時点で rc=2 と再呼び出しの案内で止まる"
  else
    bad "${label}: rc=2 と読み込み部の案内で止まらない (rc=${rc})"
    tail -8 "$log" | sed 's/^/    | /' >&2
  fi
}
ac_expect_stop "構成ファイルの不在" "がありません" missing rm -f adapter-common-git.sh
ac_expect_stop "構成ファイルが空" "が 0 バイトです" empty sh -c ': > adapter-common-review.sh'
ac_expect_stop "構成ファイルが関数の境界で切れている" "が末尾まで読めていません（最後の行が読み込み完了の印ではありません）" truncated \
  sh -c 'grep -v "^_ac_part_loaded=" adapter-common-git.sh > cut.tmp && mv cut.tmp adapter-common-git.sh'
ac_expect_stop "構成ファイルが関数の途中で切れている" "が末尾まで読めていません（最後の行が読み込み完了の印ではありません）" midfunc \
  sh -c 'n="$(grep -n "^cli_available() {" adapter-common-git.sh | cut -d: -f1)" && [ -n "$n" ] && head -n "$((n + 2))" adapter-common-git.sh > cut.tmp && mv cut.tmp adapter-common-git.sh'
if ! msys_skip "adapter-common の構成ファイルの symlink（ln -s がコピーになる）"; then
  ac_expect_stop "構成ファイルが symlink" "が symlink です" symlink \
    sh -c 'mv adapter-common-cli.sh cli.real && ln -s cli.real adapter-common-cli.sh'
fi
if ! msys_skip "adapter-common の置き場 lib の symlink（ln -s がコピーになる）"; then
  ac_expect_stop "置き場 lib が symlink" "の置き場が通常のディレクトリではないか symlink です" libdir \
    sh -c 'cd .. && mv lib lib.elsewhere && ln -s lib.elsewhere lib'
fi
ac_probe="$TMP/ac-readable-probe"
: > "$ac_probe"
chmod 000 "$ac_probe"
if [ -r "$ac_probe" ]; then
  echo "  ○ skip: adapter-common の構成ファイルが読めない場合（mode 000 でも読める実行者。root か MSYS で走っている）"
else
  ac_expect_stop "構成ファイルが読めない" "を読み取れません" unreadable chmod 000 adapter-common-output.sh
fi
chmod 600 "$ac_probe"

echo
echo "multi-agent-parts: pass=${PASS} fail=${FAIL}"
FF_REACHED_END=1
[ "$FAIL" -eq 0 ]
