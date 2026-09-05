#!/usr/bin/env bash
#
# scripts/check-release-required.sh（毎 sync リリース運用の機械強制ゲート、Issue #549 の
# 手順 R）の検出力を、隔離 fixture への変異注入で実測する。
#
# 検査本体はライブリポジトリの状態を見ない。「公開対象の実変更 + [Unreleased] 非空 +
# version 据え置き」は開発中の PR では正常な状態（リリース準備は sync 直前に行う）で、
# live 検査を run-all へ配線すると通常開発が恒常的に赤くなる。そのため run-all に載る
# 本 suite は、一時領域へ組んだ疑似 SSOT リポジトリ + 疑似公開 clone に対してスクリプトを
# 実行し、判定表（SKILL.md 手順 R）の各分岐と fail-closed 経路を変異で実測するだけにする。
#
# 固定する契約:
#   - 実変更 + [Unreleased] 非空 + version 据え置き → exit 1 / RELEASE_CHECK=RELEASE_REQUIRED
#   - 実変更 + changelog.d 断片 + version 据え置き → exit 1 / RELEASE_CHECK=RELEASE_REQUIRED
#   - 契約外の断片は version / 版節の状態によらず false green にせず CHANGELOG_MISSING
#   - 実変更 + [Unreleased] 空 + version 据え置き → exit 1 / RELEASE_CHECK=CHANGELOG_MISSING
#     （ただし allowlist 内のメタ変更のみなら exit 0）
#   - CHANGELOG footer 行のみの差分 → exit 0（version 据え置きが正。手順 8 の収束保証）
#   - リリース準備済み（bump + 版節昇格）→ exit 0
#   - 判定材料が取得できない（clone 不在・sync commit 不在・タグ 0 件・version 取得不能・
#     基点 SHA 解決不能・sync スクリプト不在）→ exit 2 / RELEASE_CHECK=UNAVAILABLE
#     （exit 1 の「止めるべき状態」と区別できること）
#   - 変異ケースは終了コードだけでなく赤の理由（メッセージ）も照合する
#   - 緑ケースは変異が実際にコミットへ入ったこと（no-op でないこと）を確認する
#   - version の巻き戻し・版節の欠落・空の版節は「bump 済み」として green にしない
#   - 公開 clone のローカル main が origin/main より遅れていても、--fetch 時は
#     origin/main を基点に pull 済みと同じ判定を返し、clone 後に origin へ打たれた
#     タグも取得する（Issue #817 事故 A）
#   - SSOT の HEAD が origin/develop より遅れていたら exit 2 / UNAVAILABLE で中断し、
#     SKIP_REASON が遅れ commit 数を示す（Issue #817 事故 B）。この比較は --fetch の
#     有無に依存しない（origin/develop が解決できる限り常に走る）
#   - SSOT の fetch 失敗は公開側の fetch 失敗と文言で区別できる UNAVAILABLE
#   - origin remote があるのに origin/main / origin/develop を解決できない配置
#     （default branch 改名・single-branch clone 等）は HEAD へ fallback せず UNAVAILABLE
#   - narrow な remote.origin.fetch 構成でも --fetch は明示 refspec で origin/main を
#     強制更新する（FETCH_HEAD だけ更新して stale ref で判定を続けない）
#   - 出力契約（RELEASE_CHECK= / REASON= / SKIP_REASON=）は行頭一致・件数・
#     RELEASE_CHECK の一意性・反対キーの混入ゼロ・理由 ERE のキー行限定まで照合する
#
# root の scripts/check-release-required.sh が存在しない配置（公開リポジトリの
# checkout 等）では行頭 ○ skip + exit 0。jq が無い・一時領域を作れない場合も同様。
#
# 本ファイルは公開同期対象。禁止パターンのリテラル（SSOT リポジトリ名等）を書かないこと
# （sync commit メッセージの組み立てに使う名前は実行時に連結して作る）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
CHECK="${REPO_ROOT:+$REPO_ROOT/scripts/check-release-required.sh}"
SYNC="${REPO_ROOT:+$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh}"
MATERIALIZE="${REPO_ROOT:+$REPO_ROOT/scripts/materialize-dev-toolkit-changelog.sh}"

if [[ -z "$REPO_ROOT" || ! -f "$CHECK" ]]; then
  echo "○ skip: scripts/check-release-required.sh が無いチェックアウトのためスキップ（本 suite は SSOT リポジトリ専用の検査です）"
  exit 0
fi
if [[ ! -f "$SYNC" ]]; then
  echo "✗ 同期スクリプトが存在しません（check-release-required.sh はあるのに --list-targets の依存先が無い）" >&2
  exit 1
fi
if [[ ! -f "$MATERIALIZE" ]]; then
  echo "✗ 断片集約スクリプトが存在しません（check-release-required.sh の contract SSOT が無い）" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が無いため release-required-selftest を実行できません（検査は1件も実行されていません）"
  exit 0
fi

# mktemp の診断を捨てない（run-all case 15）。成功時のパスと失敗時の理由を同じ変数へ受ける。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/release-required-selftest.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため release-required-selftest を実行できません（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

# 途中死が rc=0 に化けるのを防ぐ末尾到達センチネル（ACE-352-1 / ACE-399-5）。
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# SSOT リポジトリ名は禁止パターン検査（公開同期）対象のため実行時に組み立てる。
SSOT_NAME="$(printf '%s%s' 'feelflow-' 'plugins')"

CHANGELOG_REL="oss/ff-dev-toolkit/CHANGELOG.md"
PLUGIN_JSON_REL="plugins/ff-dev-toolkit/.claude-plugin/plugin.json"

# ── fixture 構築 ──────────────────────────────────────────────────────────────

SSOT_FIX="$TMP/ssot"
mkdir -p \
  "$SSOT_FIX/scripts" \
  "$SSOT_FIX/plugins/ff-dev-toolkit/.claude-plugin" \
  "$SSOT_FIX/plugins/ff-dev-toolkit/skills/demo" \
  "$SSOT_FIX/oss/ff-dev-toolkit" \
  "$SSOT_FIX/changelog.d"

cp "$CHECK" "$SSOT_FIX/scripts/check-release-required.sh"
cp "$SYNC" "$SSOT_FIX/scripts/sync-dev-toolkit-to-public.sh"
cp "$MATERIALIZE" "$SSOT_FIX/scripts/materialize-dev-toolkit-changelog.sh"
mkdir -p "$SSOT_FIX/scripts/lib"
cp "$REPO_ROOT/scripts/lib/changelog-fragment-functions.sh" "$SSOT_FIX/scripts/lib/changelog-fragment-functions.sh"
cp "$REPO_ROOT/scripts/lib/changelog-transaction-functions.sh" "$SSOT_FIX/scripts/lib/changelog-transaction-functions.sh"
cp "$REPO_ROOT/plugins/ff-dev-toolkit/scripts/lib/exact-link-functions.sh" "$SSOT_FIX/scripts/lib/exact-link-functions.sh"
chmod +x "$SSOT_FIX/scripts/check-release-required.sh" "$SSOT_FIX/scripts/sync-dev-toolkit-to-public.sh" "$SSOT_FIX/scripts/materialize-dev-toolkit-changelog.sh"
printf '%s\n' '# fragments' > "$SSOT_FIX/changelog.d/README.md"

write_plugin_json() { # $1=version
  printf '{\n  "name": "ff-dev-toolkit",\n  "version": "%s"\n}\n' "$1" \
    > "$SSOT_FIX/$PLUGIN_JSON_REL"
}

# baseline の CHANGELOG（[Unreleased] は見出しのみの空節）
write_changelog_baseline() {
  {
    printf '%s\n' '# Changelog'
    printf '%s\n' ''
    printf '%s\n' '## [Unreleased]'
    printf '%s\n' ''
    printf '%s\n' '## [0.31.0] - 2026-08-01'
    printf '%s\n' ''
    printf '%s\n' '### 追加'
    printf '%s\n' ''
    printf '%s\n' '- 初期リリース'
    printf '%s\n' ''
    printf '%s\n' '[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.31.0...HEAD'
    printf '%s\n' '[0.31.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.31.0'
  } > "$SSOT_FIX/$CHANGELOG_REL"
}

# リリース準備後の CHANGELOG（[Unreleased] 空 + 0.32.0 の版節へ昇格済み）
write_changelog_promoted() {
  {
    printf '%s\n' '# Changelog'
    printf '%s\n' ''
    printf '%s\n' '## [Unreleased]'
    printf '%s\n' ''
    printf '%s\n' '## [0.32.0] - 2026-08-19'
    printf '%s\n' ''
    printf '%s\n' '### 追加'
    printf '%s\n' ''
    printf '%s\n' '- 新しい変更'
    printf '%s\n' ''
    printf '%s\n' '## [0.31.0] - 2026-08-01'
    printf '%s\n' ''
    printf '%s\n' '### 追加'
    printf '%s\n' ''
    printf '%s\n' '- 初期リリース'
    printf '%s\n' ''
    printf '%s\n' '[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.32.0...HEAD'
    printf '%s\n' '[0.32.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.31.0...v0.32.0'
    printf '%s\n' '[0.31.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.31.0'
  } > "$SSOT_FIX/$CHANGELOG_REL"
}

# bump したのに版節が空（昇格が空振り）の CHANGELOG
write_changelog_promoted_empty() {
  {
    printf '%s\n' '# Changelog'
    printf '%s\n' ''
    printf '%s\n' '## [Unreleased]'
    printf '%s\n' ''
    printf '%s\n' '## [0.32.0] - 2026-08-19'
    printf '%s\n' ''
    printf '%s\n' '## [0.31.0] - 2026-08-01'
    printf '%s\n' ''
    printf '%s\n' '### 追加'
    printf '%s\n' ''
    printf '%s\n' '- 初期リリース'
  } > "$SSOT_FIX/$CHANGELOG_REL"
}

write_plugin_json "0.31.0"
write_changelog_baseline
printf '%s\n' '# demo skill' > "$SSOT_FIX/plugins/ff-dev-toolkit/skills/demo/SKILL.md"
printf '%s\n' '# public readme' > "$SSOT_FIX/oss/ff-dev-toolkit/README.md"
printf '%s\n' '# copilot guide' > "$SSOT_FIX/oss/ff-dev-toolkit/USING_WITH_VSCODE_COPILOT.md"

git -C "$SSOT_FIX" init -q
git -C "$SSOT_FIX" config user.email selftest@example.com
git -C "$SSOT_FIX" config user.name release-required-selftest
git -C "$SSOT_FIX" add -A
git -C "$SSOT_FIX" commit -qm "baseline"
BASE_FULL="$(git -C "$SSOT_FIX" rev-parse HEAD)"
BASE_SHORT="$(git -C "$SSOT_FIX" rev-parse --short HEAD)"

# SSOT 鮮度検査（Issue #817）を通すための origin。実リポジトリと同じく develop を
# 既定ブランチにした bare を origin として配線する（--fetch 時に fetch 先が要る）。
# 直後に一度 fetch して refs/remotes/origin/develop を作っておく — スクリプトは
# 「origin remote があるのに origin/develop を解決できない」を UNAVAILABLE にするため、
# これを欠くと S0 以降の全ケースが exit 2 に落ちる（テストの実行順にも依存させない）。
git -C "$SSOT_FIX" branch -M develop
git clone -q --bare "$SSOT_FIX" "$TMP/ssot-origin.git"
git -C "$SSOT_FIX" remote add origin "$TMP/ssot-origin.git"
git -C "$SSOT_FIX" fetch -q origin

make_public() { # $1=dir $2=commit message $3=tag（空なら打たない）
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email selftest@example.com
  git -C "$1" config user.name release-required-selftest
  printf '%s\n' 'public mirror' > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
  # 公開リポジトリの既定ブランチは main（--fetch が origin main を取得する契約）
  git -C "$1" branch -M main
  if [[ -n "$3" ]]; then
    git -C "$1" tag "$3"
  fi
}

SYNC_MSG="sync: ${SSOT_NAME} ${BASE_SHORT} を反映"
PUB="$TMP/public"
make_public "$PUB" "$SYNC_MSG" "v0.31.0"

# ── ヘルパー ──────────────────────────────────────────────────────────────────

OUT=""
RC=0
# gh stub（Issue #836）。--fetch 時の open リリース準備 PR 照会を実 gh へ出さない
# （fixture リポジトリの origin はローカル bare で gh が解決できず、実 gh だと
# 全 --fetch ケースが照会失敗の UNAVAILABLE へ落ちる。ネットワーク不達も
# 「一致」と誤読しない = 応答は FF_STUB_GH_MODE で決定的に制御する）。
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'FF_GH_STUB'
#!/usr/bin/env bash
# 想定は `gh pr list --limit N ...` のみ。想定外の呼び出しは缶詰応答で静かに
# 成功させず大声で落とす（将来の別用途 gh 呼び出しを stub が隠すのを防ぐ）。
# --limit の明示も検証する: 既定 30 件の窓へ戻す退行は検出漏れ = fail-open。
if [ "$1" != "pr" ] || [ "$2" != "list" ]; then
  echo "stub: unexpected gh call: $*" >&2
  exit 64
fi
case " $* " in
  *" --limit "*) : ;;
  *) echo "stub: gh pr list に --limit の明示がない（既定 30 件の窓は検出漏れになる）" >&2; exit 64 ;;
esac
case "${FF_STUB_GH_MODE:-empty}" in
  empty) exit 0 ;;
  found) printf '#4321(chore/#549-release-v9.9.9)\n' ;;
  fail)  echo "stub: gh query failed" >&2; exit 1 ;;
esac
FF_GH_STUB
chmod +x "$STUB_BIN/gh"

run_check() { # $1=--public に渡すパス（省略時は正常な PUB）$2 以降=追加引数
  local pub="${1:-$PUB}"
  shift 2>/dev/null || true
  set +e
  OUT="$(PATH="$STUB_BIN:$PATH" bash "$SSOT_FIX/scripts/check-release-required.sh" --public "$pub" "$@" 2>&1)"
  RC=$?
  set -e
}

expect_check() { # $1=label $2=期待 rc $3=RELEASE_CHECK 値 $4=理由の ERE（空なら照合しない）
  local label="$1" want_rc="$2" marker="$3" reason_re="$4"
  if [[ "$RC" -ne "$want_rc" ]]; then
    bad "${label} (rc=${RC}, 期待 ${want_rc})"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
    return
  fi
  # 出力契約は行単位で照合する（部分一致だとキーの改名・行頭崩れが緑のまま通る）。
  # パイプ + grep -q は SIGPIPE 反転の恐れがあるため shell 内で数える。
  # RELEASE_CHECK= の一意性・反対キー（REASON/SKIP_REASON の他方）の混入ゼロ・
  # 理由 ERE のキー行限定照合まで縛る（出力全体への一致だと、REASON が壊れていても
  # 他の行が偶然一致して green のまま通る）。
  if [[ $'\n'"$OUT"$'\n' != *$'\n'"RELEASE_CHECK=${marker}"$'\n'* ]]; then
    bad "${label}: 行頭一致の RELEASE_CHECK=${marker} 行が出力に無い"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
    return
  fi
  local key="REASON" other="SKIP_REASON" n=0 o=0 c=0 l key_line=""
  if [[ "$want_rc" -eq 2 ]]; then
    key="SKIP_REASON"
    other="REASON"
  fi
  while IFS= read -r l; do
    [[ "$l" == "RELEASE_CHECK="* ]] && c=$((c + 1))
    if [[ "$l" == "${key}="* ]]; then
      n=$((n + 1))
      key_line="$l"
    fi
    [[ "$l" == "${other}="* ]] && o=$((o + 1))
  done < <(printf '%s\n' "$OUT")
  if [[ "$c" -ne 1 ]]; then
    bad "${label}: 行頭一致の RELEASE_CHECK= 行がちょうど 1 行でない（${c} 行）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
    return
  fi
  if [[ "$n" -ne 1 ]]; then
    bad "${label}: 行頭一致の ${key}= 行がちょうど 1 行でない（${n} 行）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
    return
  fi
  if [[ "$o" -ne 0 ]]; then
    bad "${label}: 反対キー ${other}= 行が混入している（${o} 行）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
    return
  fi
  if [[ -n "$reason_re" ]] && ! [[ "$key_line" =~ $reason_re ]]; then
    bad "${label}: ${key}= 行が期待の ERE に一致しない（期待: ${reason_re}）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
    return
  fi
  ok "$label"
}

# 変異が実際にコミットへ入ったこと（no-op でないこと）の確認。緑ケースが
# 「何も変えていないから緑」に空振りするのを防ぐ。
assert_committed() { # $1=label $2=diff に現れるべきファイル
  local head changed
  head="$(git -C "$SSOT_FIX" rev-parse HEAD)"
  if [[ "$head" == "$BASE_FULL" ]]; then
    bad "${1}: 変異がコミットされていない（no-op）"
    return 1
  fi
  changed="$(git -C "$SSOT_FIX" diff --name-only "${BASE_FULL}..HEAD")"
  if [[ "$changed" == *"$2"* ]]; then
    ok "${1}: 変異が適用済み（${2} が diff に含まれる）"
    return 0
  fi
  bad "${1}: 期待した変更 ${2} が diff に無い"
  printf '%s\n' "$changed" | sed 's/^/    | /' >&2
  return 1
}

commit_fix() { # $1=message
  git -C "$SSOT_FIX" add -A
  git -C "$SSOT_FIX" commit -qm "$1"
}

reset_ssot() {
  git -C "$SSOT_FIX" reset -q --hard "$BASE_FULL"
  git -C "$SSOT_FIX" clean -fdq
}

touch_skill() {
  printf '%s\n' 'changed line' >> "$SSOT_FIX/plugins/ff-dev-toolkit/skills/demo/SKILL.md"
}

add_unreleased_item() {
  awk 'BEGIN{done=0} {print} /^## \[Unreleased\]$/ && !done {print ""; print "### 変更"; print ""; print "- 新しい変更"; done=1}' \
    "$SSOT_FIX/$CHANGELOG_REL" > "$TMP/cl.new"
  mv "$TMP/cl.new" "$SSOT_FIX/$CHANGELOG_REL"
}

add_footer_line() {
  printf '%s\n' '[0.30.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.29.0...v0.30.0' \
    >> "$SSOT_FIX/$CHANGELOG_REL"
}

echo "== release-required（毎 sync リリース運用ゲート）検出力 selftest =="

# ── S0. baseline: 前回 sync 以降に変更なし → OK ─────────────────────────────
run_check
expect_check "S0 baseline（変更なし）は OK" 0 "OK" "実変更なし"

# ── S1. 実変更 + [Unreleased] 非空 + version 据え置き → RELEASE_REQUIRED ─────
touch_skill
add_unreleased_item
commit_fix "S1"
if assert_committed "S1" "plugins/ff-dev-toolkit/skills/demo/SKILL.md"; then
  run_check
  expect_check "S1 実変更 + Unreleased 非空 + version 据え置きは赤" 1 "RELEASE_REQUIRED" "リリース準備が必要"
fi
reset_ssot

# ── S1b. 実変更 + CHANGELOG 断片 + version 据え置き → RELEASE_REQUIRED ──────
touch_skill
mkdir -p "$SSOT_FIX/changelog.d"
printf '%s\n' '- 断片で記録した変更' > "$SSOT_FIX/changelog.d/764.changed.release-required.md"
commit_fix "S1b"
if assert_committed "S1b" "changelog.d/764.changed.release-required.md"; then
  run_check
  expect_check "S1b 実変更 + 断片 + version 据え置きは赤" 1 "RELEASE_REQUIRED" "リリース準備が必要"
fi
reset_ssot

# ── S1e. 公開対象差分0件でも未消費断片だけで RELEASE_REQUIRED ───────────────
printf '%s\n' '- 追補として残った未消費断片' > "$SSOT_FIX/changelog.d/764.changed.fragment-only.md"
commit_fix "S1e"
if assert_committed "S1e" "changelog.d/764.changed.fragment-only.md"; then
  run_check
  expect_check "S1e 断片だけが残る状態も false green にしない" 1 "RELEASE_REQUIRED" "リリース準備が必要"
fi
reset_ssot

# ── S1f. bump / 版節昇格済みでも有効断片が残れば RELEASE_REQUIRED ────────────
touch_skill
write_plugin_json "0.32.0"
write_changelog_promoted
printf '%s\n' '- 昇格後に残った有効な未消費断片' > "$SSOT_FIX/changelog.d/764.changed.promoted-fragment.md"
commit_fix "S1f"
if assert_committed "S1f" "changelog.d/764.changed.promoted-fragment.md"; then
  run_check
  expect_check "S1f bump / 版節昇格済みでも未消費断片は赤" 1 "RELEASE_REQUIRED" "未公開項目.*残っている"
fi
reset_ssot

# ── S1c. 契約外断片 + version 据え置き → false green にしない ───────────────
touch_skill
printf '%s\n' '- typo fragment' > "$SSOT_FIX/changelog.d/764.change.typo.md"
commit_fix "S1c"
if assert_committed "S1c" "changelog.d/764.change.typo.md"; then
  run_check
  expect_check "S1c 契約外断片を無診断で読み飛ばさない" 1 "CHANGELOG_MISSING" "contract 違反"
fi
reset_ssot

# ── S1d. 契約外断片 + bump / 版節昇格済みでも green にしない ────────────────
touch_skill
write_plugin_json "0.32.0"
write_changelog_promoted
printf '%s\n' '- typo fragment' > "$SSOT_FIX/changelog.d/764.change.typo.md"
commit_fix "S1d"
if assert_committed "S1d" "changelog.d/764.change.typo.md"; then
  run_check
  expect_check "S1d bump 済みでも契約外断片を green にしない" 1 "CHANGELOG_MISSING" "contract 違反"
fi
reset_ssot

# ── S2. 実変更 + [Unreleased] 空 + version 据え置き → CHANGELOG_MISSING ──────
touch_skill
commit_fix "S2"
if assert_committed "S2" "plugins/ff-dev-toolkit/skills/demo/SKILL.md"; then
  run_check
  expect_check "S2 実変更 + Unreleased 空は CHANGELOG 記載漏れとして赤" 1 "CHANGELOG_MISSING" "記載漏れの疑い"
fi
reset_ssot

# ── S3. allowlist 内のメタ変更のみ + [Unreleased] 空 → OK ───────────────────
printf '%s\n' 'typo fix' >> "$SSOT_FIX/oss/ff-dev-toolkit/README.md"
printf '%s\n' 'typo fix' >> "$SSOT_FIX/oss/ff-dev-toolkit/USING_WITH_VSCODE_COPILOT.md"
commit_fix "S3"
if assert_committed "S3" "oss/ff-dev-toolkit/README.md"; then
  run_check
  expect_check "S3 allowlist 内のメタ変更のみは OK" 0 "OK" "メタ変更のみ"
fi
reset_ssot

# ── S4. allowlist + 非 allowlist の混在 + [Unreleased] 空 → CHANGELOG_MISSING ─
# （allowlist が非 allowlist の変更を覆い隠さないこと）
printf '%s\n' 'typo fix' >> "$SSOT_FIX/oss/ff-dev-toolkit/README.md"
touch_skill
commit_fix "S4"
if assert_committed "S4" "plugins/ff-dev-toolkit/skills/demo/SKILL.md"; then
  run_check
  expect_check "S4 allowlist 混在でも非 allowlist の変更は赤" 1 "CHANGELOG_MISSING" "記載漏れの疑い"
fi
reset_ssot

# ── S5. CHANGELOG footer 行のみの差分 → OK（version 据え置きが正） ────────────
add_footer_line
commit_fix "S5"
if assert_committed "S5" "$CHANGELOG_REL"; then
  run_check
  expect_check "S5 footer 行のみの差分は OK" 0 "OK" "footer 行のみ"
fi
reset_ssot

# ── S6. footer 行 + 実質行の混在 → footer 判定に飲み込まれず赤 ────────────────
add_footer_line
add_unreleased_item
commit_fix "S6"
if assert_committed "S6" "$CHANGELOG_REL"; then
  run_check
  expect_check "S6 footer + 実質行の混在は footer 扱いにならず赤" 1 "RELEASE_REQUIRED" "リリース準備が必要"
fi
reset_ssot

# ── S7. リリース準備済み（bump + 版節昇格 + [Unreleased] 空）→ OK ────────────
touch_skill
write_changelog_promoted
write_plugin_json "0.32.0"
commit_fix "S7"
if assert_committed "S7" "$PLUGIN_JSON_REL"; then
  run_check
  expect_check "S7 リリース準備済み（bump + 昇格）は OK" 0 "OK" "リリース準備済み"
fi
reset_ssot

# ── S8. bump 済みなのに [Unreleased] に項目が残る → 昇格未完了として赤 ────────
touch_skill
add_unreleased_item
write_plugin_json "0.32.0"
commit_fix "S8"
if assert_committed "S8" "$PLUGIN_JSON_REL"; then
  run_check
  expect_check "S8 bump 済み + Unreleased 残存は昇格未完了として赤" 1 "RELEASE_REQUIRED" "未完了の疑い"
fi
reset_ssot

# ── S10. version 巻き戻し（最新タグより古い）は bump 済み扱いにしない ─────────
touch_skill
write_plugin_json "0.30.0"
commit_fix "S10"
if assert_committed "S10" "$PLUGIN_JSON_REL"; then
  run_check
  expect_check "S10 version 巻き戻しは bump 済み扱いにならず赤" 1 "RELEASE_REQUIRED" "巻き戻しの疑い"
fi
reset_ssot

# ── S11. bump 済みだが対応する版節が無い → 昇格漏れとして赤 ───────────────────
touch_skill
write_plugin_json "0.32.0"
commit_fix "S11"
if assert_committed "S11" "$PLUGIN_JSON_REL"; then
  run_check
  expect_check "S11 bump 済み + 版節なしは昇格漏れとして赤" 1 "RELEASE_REQUIRED" "版節 ## \[0\.32\.0\] が CHANGELOG に無い"
fi
reset_ssot

# ── S12. bump 済みで版節はあるが項目が空 → 昇格の空振りとして赤 ───────────────
touch_skill
write_changelog_promoted_empty
write_plugin_json "0.32.0"
commit_fix "S12"
if assert_committed "S12" "$PLUGIN_JSON_REL"; then
  run_check
  expect_check "S12 bump 済み + 空の版節は昇格の空振りとして赤" 1 "RELEASE_REQUIRED" "項目が 1 件も無い"
fi
reset_ssot

# ── S13. 最新タグの選択が数値順であること（辞書順退行の検出） ─────────────────
PUB_MULTI="$TMP/public-multitag"
make_public "$PUB_MULTI" "$SYNC_MSG" "v0.9.4"
git -C "$PUB_MULTI" tag v0.10.1
run_check "$PUB_MULTI"
if [[ $'\n'"$OUT"$'\n' == *$'\n'"LATEST_TAG=v0.10.1"$'\n'* ]]; then
  ok "S13 複数タグから数値順の最新（v0.10.1 > v0.9.4）を選ぶ"
else
  bad "S13 最新タグ選択が数値順でない（辞書順退行の疑い）"
  printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
fi

# ── S14. footer 行のみの CHANGELOG + 別ファイルの実変更の混在 → 赤 ────────────
# （footer 除外が CHANGELOG 以外の実変更まで飲み込まないこと）
add_footer_line
touch_skill
commit_fix "S14"
if assert_committed "S14" "plugins/ff-dev-toolkit/skills/demo/SKILL.md"; then
  run_check
  expect_check "S14 footer のみの CHANGELOG + skill 実変更の混在は赤" 1 "CHANGELOG_MISSING" "記載漏れの疑い"
fi
reset_ssot

# ── S15/U7. --fetch の成否 ────────────────────────────────────────────────────
# origin を持つ clone では fetch 成功のうえ通常判定、origin 不在では検査不能。
PUB_FETCH="$TMP/public-fetch"
make_public "$PUB_FETCH" "$SYNC_MSG" "v0.31.0"
git -C "$PUB_FETCH" remote add origin "$PUB_FETCH"
run_check "$PUB_FETCH" --fetch
expect_check "S15 --fetch は origin があれば最新化のうえ通常判定（OK）" 0 "OK" "実変更なし"

# SSOT 側の fetch 失敗（U8）と区別するため公開側の文言まで照合する
run_check "$PUB" --fetch
expect_check "U7 --fetch で origin 不在なら検査不能（exit 2）" 2 "UNAVAILABLE" "公開側 clone の fetch に失敗"

# ── S16. 公開 clone のローカル main が stale でも --fetch は origin/main 基準 ──
# Issue #817 事故 A の再現: 並行セッションが公開側へ push した sync commit が
# ローカル main に無いと、base が 1 世代前に解決され誤判定（fail-open）していた。
# 「SSOT の変更は公開 origin へ sync 済み・clone のローカル main だけが stale」を
# 実入力で組み、pull 済みの場合と同じ判定（OK / base=最新 sync）を要求する。
touch_skill
commit_fix "S16"
if assert_committed "S16" "plugins/ff-dev-toolkit/skills/demo/SKILL.md"; then
  NEW_FULL="$(git -C "$SSOT_FIX" rev-parse HEAD)"
  NEW_SHORT="$(git -C "$SSOT_FIX" rev-parse --short HEAD)"
  # SSOT 側の鮮度検査を green に保つ（HEAD == origin/develop）
  git -C "$SSOT_FIX" push -q origin develop
  PUB_STALE_ORIGIN="$TMP/public-stale-origin"
  make_public "$PUB_STALE_ORIGIN" "$SYNC_MSG" "v0.31.0"
  PUB_STALE="$TMP/public-stale"
  git clone -q "$PUB_STALE_ORIGIN" "$PUB_STALE"
  git -C "$PUB_STALE" config user.email selftest@example.com
  git -C "$PUB_STALE" config user.name release-required-selftest
  # clone 後に origin 側だけ進める = 並行セッションの push（clone は stale のまま）。
  # タグも clone 後に origin へ打つ — --fetch を明示 refspec 化してタグ追従が消える
  # 退行（LATEST_TAG が古いまま）をここで検出する。
  printf '%s\n' 'newer sync' >> "$PUB_STALE_ORIGIN/README.md"
  git -C "$PUB_STALE_ORIGIN" add -A
  git -C "$PUB_STALE_ORIGIN" commit -qm "sync: ${SSOT_NAME} ${NEW_SHORT} を反映"
  git -C "$PUB_STALE_ORIGIN" tag v0.32.0
  run_check "$PUB_STALE" --fetch
  expect_check "S16 stale なローカル main でも --fetch は origin/main 基準で OK" 0 "OK" "実変更なし"
  if [[ $'\n'"$OUT"$'\n' == *$'\n'"BASE_SHA=${NEW_FULL}"$'\n'* ]]; then
    ok "S16 BASE_SHA が origin/main の最新 sync commit（pull 済みと同じ基点）"
  else
    bad "S16 BASE_SHA が stale なローカル main から解決されている疑い（期待 ${NEW_FULL}）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
  fi
  if [[ $'\n'"$OUT"$'\n' == *$'\n'"LATEST_TAG=v0.32.0"$'\n'* ]]; then
    ok "S16 clone 後に origin へ打たれたタグを --fetch が取得している（タグ鮮度）"
  else
    bad "S16 LATEST_TAG が clone 時点の古いタグのまま（--fetch のタグ追従が消えた疑い）"
    printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
  fi
  git -C "$SSOT_FIX" push -qf origin "${BASE_FULL}:develop"
fi
reset_ssot

# ── S17. SSOT の HEAD が origin/develop より遅れていたら UNAVAILABLE ──────────
# Issue #817 事故 B の再現: 並行セッションの PR が origin/develop に入っているのに
# ローカル develop が古いままリリース準備を始めると重複する。fail-closed で中断し、
# SKIP_REASON が遅れ commit 数を機械可読で示すこと。
touch_skill
commit_fix "S17"
git -C "$SSOT_FIX" push -q origin develop
git -C "$SSOT_FIX" reset -q --hard "$BASE_FULL"
if [[ "$(git -C "$SSOT_FIX" rev-list --count "HEAD..origin/develop")" -eq 1 ]]; then
  ok "S17: HEAD が origin/develop より 1 commit 遅れた fixture を構築"
  run_check "$PUB_FETCH" --fetch
  expect_check "S17 stale な develop は検査不能（exit 2）で中断" 2 "UNAVAILABLE" "origin/develop より 1 commit 遅れている"
  # 鮮度比較は --fetch の有無に依存しない（origin/develop が解決できる限り常に走る）。
  # 「DO_FETCH のときだけ比較する」への退行をここで検出する。
  run_check "$PUB_STALE"
  expect_check "S17 fetch 無しでも既存の origin/develop で遅れを検出する" 2 "UNAVAILABLE" "origin/develop より 1 commit 遅れている"
else
  bad "S17: 遅れ fixture の構築に失敗（HEAD..origin/develop が 1 でない）"
fi
git -C "$SSOT_FIX" push -qf origin "${BASE_FULL}:develop"
reset_ssot

# ── U8. SSOT の fetch 失敗は検査不能（公開側の fetch 失敗と文言で区別できる） ──
# 変異検査で「SSOT fetch の失敗を握りつぶす（|| true 化）」が生き残った経路を塞ぐ。
git -C "$SSOT_FIX" remote set-url origin "$TMP/no-such-origin.git"
run_check "$PUB_FETCH" --fetch
expect_check "U8 SSOT の fetch 失敗は検査不能（exit 2）" 2 "UNAVAILABLE" "SSOT の fetch に失敗"
git -C "$SSOT_FIX" remote set-url origin "$TMP/ssot-origin.git"

# ── S19. open なリリース準備 PR の検出（Issue #836） ─────────────────────────
# --fetch 時のみ gh（stub）で照会し、head が chore/#549-release-* の open PR が
# あれば UNAVAILABLE で中断（重複準備の直列化）。照会失敗も fail-closed。
# 非発動の対照は S15（stub 既定 = empty で OK のまま）が担う。
FF_STUB_GH_MODE=found run_check "$PUB_FETCH" --fetch
expect_check "S19 open なリリース準備 PR があれば検査不能（exit 2）で中断" 2 "UNAVAILABLE" "open なリリース準備 PR が存在する.*#4321"
FF_STUB_GH_MODE=fail run_check "$PUB_FETCH" --fetch
expect_check "S19 PR 照会の失敗は素通りさせず検査不能（exit 2）" 2 "UNAVAILABLE" "open なリリース準備 PR の照会に失敗"
FF_STUB_GH_MODE=found run_check "$PUB_FETCH"
expect_check "S19 --fetch なし（offline fixture）では本検出は発動しない" 0 "OK" "実変更なし"

# ── U9. origin remote があるのに origin/main を解決できない公開 clone は検査不能 ──
# default branch 改名・single-branch clone 等で HEAD へ静かに fallback すると、
# 事故 A（stale な基点からの誤判定）が fallback 経由で再発する（fail-open）。
PUB_NOREF="$TMP/public-noref"
make_public "$PUB_NOREF" "$SYNC_MSG" "v0.31.0"
git -C "$PUB_NOREF" remote add origin "$PUB_NOREF"   # remote はあるが一度も fetch していない
run_check "$PUB_NOREF"
expect_check "U9 origin があるのに origin/main を解決できない clone は検査不能（exit 2）" 2 "UNAVAILABLE" "origin/main を解決できない"

# ── U10. origin remote があるのに origin/develop を解決できない SSOT は検査不能 ──
git -C "$SSOT_FIX" update-ref -d refs/remotes/origin/develop
run_check "$PUB"
expect_check "U10 origin があるのに origin/develop を解決できない SSOT は検査不能（exit 2）" 2 "UNAVAILABLE" "origin/develop を解決できない"
git -C "$SSOT_FIX" fetch -q origin

# ── S18. narrow な remote.origin.fetch でも --fetch は origin/main を強制更新する ──
# 素の `git fetch origin main` は narrow な refspec 構成で FETCH_HEAD しか更新せず、
# fetch 成功後も stale な origin/main で判定を続ける（fail-open）。明示 refspec
# （+refs/heads/main:refs/remotes/origin/main）への退行防止。clone 時点の origin/main
# には sync commit が無く、fetch が効いて初めて OK になる構図にしてある。
PUB_NARROW_ORIGIN="$TMP/public-narrow-origin"
make_public "$PUB_NARROW_ORIGIN" "initial commit" "v0.31.0"
PUB_NARROW="$TMP/public-narrow"
git clone -q "$PUB_NARROW_ORIGIN" "$PUB_NARROW"
git -C "$PUB_NARROW" config remote.origin.fetch "+refs/heads/__none__:refs/remotes/origin/__none__"
printf '%s\n' 'sync arrives' >> "$PUB_NARROW_ORIGIN/README.md"
git -C "$PUB_NARROW_ORIGIN" add -A
git -C "$PUB_NARROW_ORIGIN" commit -qm "$SYNC_MSG"
run_check "$PUB_NARROW" --fetch
expect_check "S18 narrow な remote.origin.fetch でも --fetch は origin/main を更新して判定する" 0 "OK" "実変更なし"

# ── U1〜U6. 判定材料が取得できない → exit 2 / UNAVAILABLE（exit 1 と区別） ────

run_check "$TMP/does-not-exist"
expect_check "U1 公開側 clone 不在は検査不能（exit 2）" 2 "UNAVAILABLE" "clone が存在しない"

PUB_NOSYNC="$TMP/public-nosync"
make_public "$PUB_NOSYNC" "initial commit" "v0.31.0"
run_check "$PUB_NOSYNC"
expect_check "U2 sync commit が無い公開側は検査不能（exit 2）" 2 "UNAVAILABLE" "sync commit が見つからない"

PUB_NOTAG="$TMP/public-notag"
make_public "$PUB_NOTAG" "$SYNC_MSG" ""
run_check "$PUB_NOTAG"
expect_check "U3 SemVer タグ 0 件の公開側は検査不能（exit 2）" 2 "UNAVAILABLE" "タグ.*無い"

printf '%s\n' '{ broken json' > "$SSOT_FIX/$PLUGIN_JSON_REL"
commit_fix "U4"
if assert_committed "U4" "$PLUGIN_JSON_REL"; then
  run_check
  expect_check "U4 plugin.json から version を読めない場合は検査不能（exit 2）" 2 "UNAVAILABLE" "version を取得できない"
fi
reset_ssot

PUB_BOGUS="$TMP/public-bogus"
make_public "$PUB_BOGUS" "sync: ${SSOT_NAME} 0123456789abcdef0123456789abcdef01234567 を反映" "v0.31.0"
run_check "$PUB_BOGUS"
expect_check "U5 同期基点 SHA を SSOT 履歴で解決できない場合は検査不能（exit 2）" 2 "UNAVAILABLE" "同期基点.*解決できない"

rm "$SSOT_FIX/scripts/sync-dev-toolkit-to-public.sh"
if [[ ! -x "$SSOT_FIX/scripts/sync-dev-toolkit-to-public.sh" ]]; then
  ok "U6: sync スクリプトの除去が適用済み"
  run_check
  expect_check "U6 sync スクリプト不在は検査不能（exit 2）" 2 "UNAVAILABLE" "存在しないか実行権限がない"
else
  bad "U6: sync スクリプトを除去できていない（変異が no-op）"
fi
reset_ssot

# ── U11. materialize 自体が検査不能なら contract 違反へ縮退しない ─────────────
mkdir "$SSOT_FIX/changelog.d/.ff-changelog.lock"
run_check "$PUB"
expect_check "U11 writer lock 中の断片検査不能は exit 2 / UNAVAILABLE" 2 "UNAVAILABLE" "CHANGELOG 断片 contract を検査できない"
rmdir "$SSOT_FIX/changelog.d/.ff-changelog.lock"

# ── U12. materialize の silent contract failure を success に縮退しない ─────
cp "$SSOT_FIX/scripts/materialize-dev-toolkit-changelog.sh" "$TMP/materialize-backup.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$SSOT_FIX/scripts/materialize-dev-toolkit-changelog.sh"
chmod +x "$SSOT_FIX/scripts/materialize-dev-toolkit-changelog.sh"
run_check "$PUB"
expect_check "U12 無診断の断片 contract 違反も CHANGELOG_MISSING" 1 "CHANGELOG_MISSING" "無診断で contract 違反終了"
mv "$TMP/materialize-backup.sh" "$SSOT_FIX/scripts/materialize-dev-toolkit-changelog.sh"

# ── S9. check スクリプトが無い配置（公開 checkout）では本 suite 自身が ○ skip ──
PUBCO="$TMP/public-checkout"
mkdir -p "$PUBCO/plugins/ff-dev-toolkit/tests/release-required-selftest"
cp "$SCRIPT_DIR/verify.sh" "$PUBCO/plugins/ff-dev-toolkit/tests/release-required-selftest/verify.sh"
git -C "$PUBCO" init -q
git -C "$PUBCO" config user.email selftest@example.com
git -C "$PUBCO" config user.name release-required-selftest
set +e
skip_out="$(bash "$PUBCO/plugins/ff-dev-toolkit/tests/release-required-selftest/verify.sh" 2>&1)"
skip_rc=$?
set -e
if [[ "$skip_rc" -eq 0 && $'\n'"$skip_out" == *$'\n○ skip'* ]]; then
  ok "S9 check スクリプトが無い checkout は行頭 ○ skip で exit 0"
else
  bad "S9 スクリプト不在の skip 契約が崩れた (rc=${skip_rc})"
  printf '%s\n' "$skip_out" | sed 's/^/    | /' >&2
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ release-required selftest: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  REACHED_END=1
  exit 1
fi
echo "✓ release-required selftest: 全 ${PASS} 件 pass"
REACHED_END=1
exit 0
