#!/usr/bin/env bash
#
# fixture 用 Git リポジトリの隔離初期化（tests/lib/git-fixture.sh）の回帰（Issue #1348 / #1368）。
#
# suite が `git init` した fixture へ `git -C "$dir" config user.*` で合成 identity
# を書く形は identity の値に依らず、GIT_DIR が export された環境や
# fixture が自前の .git を持たない状況で**呼び出し元リポジトリの .git/config** へ漏れ、
# 以後のコミット全部が合成名義になる（develop の knowledge 直 push 41 件で実測）。
# 本 suite は次を固定する:
#   1. lib を source すると GIT_DIR 系の環境変数が現在のシェルから消え、
#      GIT_CONFIG_GLOBAL / GIT_CONFIG_NOSYSTEM は残る
#   2. GIT_DIR が外側リポジトリを指していても、ヘルパーは fixture 自身へ identity を書き、
#      外側の設定・履歴を汚さない。NAME / EMAIL 引数で identity を差し替えられ、symlink を含む
#      DIR でも物理パス照合で通る
#   3. fixture の git dir が自分自身へ解決されないとき（外側の作業ツリー内で .git 不在、
#      linked worktree の gitfile）、ヘルパーは identity を書かずに非 0
#   4. tests/ 配下で user.name / user.email を直接 `git config` する箇所は lib と本 suite と
#      未移行 allowlist 以外に無く、allowlist の stale entry は赤。ヘルパー利用箇所は lib を
#      source している（-f ガードは verify.sh だけをコピーする selftest に限る）。
#      既定 identity 文字列は lib と本 suite 以外に無い（静的照合）
#   （経路 1 の再現有無は git 版依存のため info 表示のみで、判定に含めない）
#
# 一時領域を使うが実 CLI・ネットワーク・課金は伴わない。
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。必須へ昇格するなら REQUIRED_SUITES へ移す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LIB="$TESTS_DIR/lib/git-fixture.sh"
REAL_GIT="$(command -v git)"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== fixture Git リポジトリの隔離初期化の回帰 =="

if [ ! -f "$LIB" ]; then
  echo "✗ lib が見つかりません: $LIB" >&2
  exit 1
fi

# mktemp の stderr を捨てない（理由は mbcs-guard-failclosed と同じ）。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$(cd "$_ff_mktemp_out" && pwd -P)"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ git-fixture-isolation: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

# suite 自身が継承した GIT_DIR 等に無防備だと、最初の git init が呼び出し元を再初期化しうる。
# 各ケースは自分のサブシェルで export し直すので、親シェルはここで先に中和しておく。
# shellcheck source=../lib/git-fixture.sh
. "$LIB"

# 外側リポジトリ（汚染されてはいけない側）。identity は一切持たせない。
OUTER="$TMP/outer"
mkdir -p "$OUTER"
"$REAL_GIT" -C "$OUTER" init -q
# 外側の identity 読み取り。「キーが無い」(rc=1) だけを空として扱い、リポジトリを読めない
# (rc=128 等) は PROBE-ERROR を返して「無傷」判定を通さない（読めない外側を clean と誤読しない）。
outer_identity() {
  local k rc out
  for k in user.email user.name; do
    rc=0
    out="$("$REAL_GIT" -C "$OUTER" config --local --get-all "$k" 2>&1)" || rc=$?
    case "$rc" in
      0) printf '%s\n' "$out" ;;
      1) ;;
      *) printf 'PROBE-ERROR(%s): %s\n' "$rc" "$out" ;;
    esac
  done
}

# ---- 1. source 時に GIT_DIR 系が現在のシェルから消える -------------------------
leftover="$(
  export GIT_DIR="$OUTER/.git" GIT_WORK_TREE="$OUTER" GIT_INDEX_FILE="$OUTER/.git/index" \
    GIT_COMMON_DIR="$OUTER/.git" GIT_OBJECT_DIRECTORY="$OUTER/.git/objects" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$OUTER/.git/objects" GIT_CONFIG="$OUTER/.git/config" \
    GIT_CONFIG_PARAMETERS="'user.name=fixture'" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=fixture@example.invalid
  # shellcheck source=../lib/git-fixture.sh
  . "$LIB"
  printf '%s' "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_INDEX_FILE:-}${GIT_COMMON_DIR:-}${GIT_OBJECT_DIRECTORY:-}${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}${GIT_CONFIG:-}${GIT_CONFIG_PARAMETERS:-}${GIT_CONFIG_COUNT:-}${GIT_CONFIG_KEY_0:-}${GIT_CONFIG_VALUE_0:-}"
)"
if [ -z "$leftover" ]; then
  ok "lib の source で GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_COMMON_DIR / GIT_OBJECT_DIRECTORY / GIT_ALTERNATE_OBJECT_DIRECTORIES / GIT_CONFIG / GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT / GIT_CONFIG_KEY_* / GIT_CONFIG_VALUE_* が現在のシェルから消える"
else
  bad "lib の source 後も GIT_DIR 系が残る: $leftover"
fi
# 意図して隔離に使う変数は触らない
kept="$(
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  # shellcheck source=../lib/git-fixture.sh
  . "$LIB"
  printf '%s|%s' "${GIT_CONFIG_GLOBAL:-}" "${GIT_CONFIG_NOSYSTEM:-}"
)"
if [ "$kept" = "/dev/null|1" ]; then
  ok "GIT_CONFIG_GLOBAL / GIT_CONFIG_NOSYSTEM（suite 側の隔離つまみ）は unset しない"
else
  bad "GIT_CONFIG_GLOBAL / GIT_CONFIG_NOSYSTEM まで消している: $kept"
fi

# ---- 2. GIT_DIR が外側を指していても外側を汚さない ----------------------------
# 経路の実在確認（情報）: lib 無しで同じ手順を踏むと外側へ漏れる git かどうか。
probe_outer="$TMP/probe-outer"
mkdir -p "$probe_outer"
"$REAL_GIT" -C "$probe_outer" init -q
(
  export GIT_DIR="$probe_outer/.git"
  cd "$probe_outer"
  "$REAL_GIT" init -q "$TMP/probe-fx" 2>/dev/null || true
  "$REAL_GIT" -C "$TMP/probe-fx" config user.email fixture@example.invalid 2>/dev/null || true
)
if [ "$("$REAL_GIT" -C "$probe_outer" config --local --get user.email 2>/dev/null || true)" = fixture@example.invalid ]; then
  echo "  ○ info: この git（$("$REAL_GIT" --version)）では GIT_DIR export 下の init+config が外側へ漏れる（Issue #1348 の経路 1 を再現）"
else
  echo "  ○ info: この git（$("$REAL_GIT" --version)）では GIT_DIR export 下の init+config が外側へ漏れない（経路 1 は再現せず。ヘルパーの保証は経路 2 と fail-closed で見る）"
fi

FX="$TMP/fx"
rc=0
(
  export GIT_DIR="$OUTER/.git" GIT_WORK_TREE="$OUTER"
  cd "$OUTER"
  # shellcheck source=../lib/git-fixture.sh
  . "$LIB"
  ff_git_fixture_init "$FX"
  "$REAL_GIT" -C "$FX" commit -q --allow-empty -m fixture
) >"$TMP/case2.log" 2>&1 || rc=$?
# 外側に HEAD が無いことは rc=1（unborn）で見る。128（リポジトリを読めない）を「無傷」に数えない
rc_head=0
"$REAL_GIT" -C "$OUTER" rev-parse --verify -q HEAD >/dev/null 2>&1 || rc_head=$?
if [ "$rc" -eq 0 ] && [ -d "$FX/.git" ] \
  && [ "$("$REAL_GIT" -C "$FX" config --local --get user.email)" = fixture@example.invalid ] \
  && [ "$("$REAL_GIT" -C "$FX" config --local --get user.name)" = fixture ] \
  && [ "$("$REAL_GIT" -C "$FX" log -1 --format='%ae')" = fixture@example.invalid ] \
  && [ -z "$(outer_identity)" ] \
  && [ -d "$OUTER/.git" ] && [ "$rc_head" -eq 1 ]; then
  ok "GIT_DIR / GIT_WORK_TREE が外側を指していても、identity とコミットは fixture 自身へ入り、外側の設定・履歴は無傷"
else
  bad "GIT_DIR export 下で外側が汚れた、または fixture が作れない (rc=$rc, outer identity='$(outer_identity | tr '\n' ' ')')"
  sed 's/^/    | /' "$TMP/case2.log" >&2
fi

# 任意の identity を渡せる
FX2="$TMP/fx2"
rc=0
# shellcheck source=../lib/git-fixture.sh
( . "$LIB"; ff_git_fixture_init "$FX2" someone "someone@example.com" ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$("$REAL_GIT" -C "$FX2" config --local --get user.name)" = someone ] \
  && [ "$("$REAL_GIT" -C "$FX2" config --local --get user.email)" = someone@example.com ]; then
  ok "NAME / EMAIL 引数で identity を差し替えられる（既定は fixture / fixture@example.invalid）"
else
  bad "NAME / EMAIL 引数が効かない (rc=$rc)"
fi

# clone 済み work tree でも init し直して identity を書き、remote / HEAD は残す（#1368 の移行形）
SEED="$TMP/clone-seed"
CLONE="$TMP/clone-work"
rc=0
# shellcheck source=../lib/git-fixture.sh
( . "$LIB"; ff_git_fixture_init "$SEED" seed "seed@example.invalid" ) >/dev/null 2>&1 || rc=$?
"$REAL_GIT" -C "$SEED" commit -q --allow-empty -m seed
"$REAL_GIT" clone -q "$SEED" "$CLONE" 2>/dev/null
SEED_HEAD="$("$REAL_GIT" -C "$SEED" rev-parse HEAD)"
rc=0
# shellcheck source=../lib/git-fixture.sh
( . "$LIB"; ff_git_fixture_init "$CLONE" someone "someone@example.com" ) >"$TMP/case-clone.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$("$REAL_GIT" -C "$CLONE" config --local --get user.email)" = someone@example.com ] \
  && [ "$("$REAL_GIT" -C "$CLONE" config --local --get user.name)" = someone ] \
  && [ "$("$REAL_GIT" -C "$CLONE" rev-parse HEAD)" = "$SEED_HEAD" ] \
  && [ "$("$REAL_GIT" -C "$CLONE" remote get-url origin)" = "$SEED" ] \
  && [ -z "$(outer_identity)" ]; then
  ok "clone 済み work tree でも identity を書き、remote と HEAD は残る"
else
  bad "clone 済み work tree で identity が入らない、または remote/HEAD が消えた (rc=$rc)"
  sed 's/^/    | /' "$TMP/case-clone.log" >&2
fi

# symlink を含む DIR（macOS の /tmp → /private/tmp、/var/folders → /private/var が既定）でも
# 物理パス同士の照合で通る。`pwd -P` を落とす退行は「正しい fixture を拒む」側に出る。
mkdir -p "$TMP/real"
ln -s "$TMP/real" "$TMP/link"
rc=0
# shellcheck source=../lib/git-fixture.sh
( . "$LIB"; ff_git_fixture_init "$TMP/link/fx" ) >"$TMP/case-symlink.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -d "$TMP/real/fx/.git" ] \
  && [ "$("$REAL_GIT" -C "$TMP/link/fx" config --local --get user.email)" = fixture@example.invalid ]; then
  ok "symlink を含む DIR でも fixture 自身へ解決され identity が入る（物理パス同士の照合）"
else
  bad "symlink を含む DIR で fixture を拒否した、または identity が入らない (rc=$rc)"
  sed 's/^/    | /' "$TMP/case-symlink.log" >&2
fi

# source 後に GIT_CONFIG / GIT_DIR が再 export されても、関数冒頭の再 unset で fixture 自身へ入る（経路 3）。
FX3="$TMP/fx3"
rc=0
# shellcheck source=../lib/git-fixture.sh
( . "$LIB"; export GIT_CONFIG="$OUTER/.git/config" GIT_DIR="$OUTER/.git"; ff_git_fixture_init "$FX3" ) >"$TMP/case-gitconfig.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -d "$FX3/.git" ] && [ -z "$(outer_identity)" ] \
  && [ "$("$REAL_GIT" -C "$FX3" config --local --get user.email)" = fixture@example.invalid ]; then
  ok "source 後に GIT_CONFIG / GIT_DIR を再 export しても、関数内の再 unset で fixture 自身へ入り外側は無傷"
else
  bad "GIT_CONFIG / GIT_DIR 再 export 下で外側へ書いた、または fixture が作れない (rc=$rc, outer identity='$(outer_identity | tr '\n' ' ')')"
  sed 's/^/    | /' "$TMP/case-gitconfig.log" >&2
fi

# ---- 3. fixture の git dir が自分自身へ解決されなければ identity を書かない ------
# `git init` を握り潰す stub で「<dir> が外側の作業ツリー内で .git を持たない」状況を
# 作る（経路 2）。ヘルパーは非 0 で止まり、外側へは何も書かないこと。
STUB="$TMP/stub"
mkdir -p "$STUB"
cat >"$STUB/git" <<EOF
#!/usr/bin/env bash
# init（-C <dir> 形と素の形の両方）を no-op にし、他は実 git へ委譲する
if [ "\${1:-}" = -C ] && [ "\${3:-}" = init ]; then exit 0; fi
if [ "\${1:-}" = init ]; then exit 0; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB/git"
SUB="$OUTER/sub"
rc=0
# shellcheck source=../lib/git-fixture.sh
( PATH="$STUB:$PATH"; . "$LIB"; ff_git_fixture_init "$SUB" ) >"$TMP/case3.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$SUB/.git" ] && [ -z "$(outer_identity)" ] \
  && grep -qF "identity は書かない）: $SUB → $OUTER/.git" "$TMP/case3.log"; then
  ok "git dir が外側（$OUTER/.git）へ解決されるとき、identity を書かずに非 0 で止まる（外側は無傷）"
else
  bad "解決先が外側でも identity を書いた、または非 0 にならない (rc=$rc, outer identity='$(outer_identity | tr '\n' ' ')')"
  sed 's/^/    | /' "$TMP/case3.log" >&2
fi

# linked worktree（.git が gitfile）を DIR に渡した場合も、config は共有 .git/config へ向くため拒む。
WT="$TMP/wt"
"$REAL_GIT" -C "$OUTER" -c user.name=seed -c user.email=seed@example.invalid commit -q --allow-empty -m seed
"$REAL_GIT" -C "$OUTER" worktree add -q "$WT" >/dev/null 2>&1
rc=0
# shellcheck source=../lib/git-fixture.sh
( . "$LIB"; ff_git_fixture_init "$WT" ) >"$TMP/case-wt.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$(outer_identity)" ] && grep -q 'identity は書かない' "$TMP/case-wt.log"; then
  ok "linked worktree（gitfile）を DIR に渡すと identity を書かずに非 0（共有 .git/config へ漏らさない）"
else
  bad "linked worktree に identity を書いた、または非 0 にならない (rc=$rc, outer identity='$(outer_identity | tr '\n' ' ')')"
  sed 's/^/    | /' "$TMP/case-wt.log" >&2
fi
"$REAL_GIT" -C "$OUTER" worktree remove --force "$WT" >/dev/null 2>&1 || true

# git init 自体が失敗する分岐（stub が init で非 0）でも identity を書かず、分岐固有の文言で止まる。
STUB_FAIL="$TMP/stub-fail"
mkdir -p "$STUB_FAIL"
cat >"$STUB_FAIL/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${3:-}" = init ]; then exit 1; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB_FAIL/git"
FX4="$TMP/fx4"
rc=0
# shellcheck source=../lib/git-fixture.sh
( PATH="$STUB_FAIL:$PATH"; . "$LIB"; ff_git_fixture_init "$FX4" ) >"$TMP/case-initfail.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$FX4/.git" ] && grep -qF 'git init に失敗（identity は書かない）' "$TMP/case-initfail.log"; then
  ok "git init が失敗したときも identity を書かず、分岐固有の文言で非 0"
else
  bad "git init 失敗分岐が識別できない、または identity を書いた (rc=$rc)"
  sed 's/^/    | /' "$TMP/case-initfail.log" >&2
fi

# ---- 4. 静的照合: identity 非依存。未移行は allowlist のみ。stale allowlist は赤 ----
# grep の rc は 0/1 だけを結果として受け、2 以上（走査不能）は fail-closed にする。
# パイプ終端で rc が隠れないよう、走査結果はファイルへ受けて $? を直接読む（除外は後段で行う）。
CFG_RE='git([[:space:]]+-C[[:space:]]+\S+)?[[:space:]]+config([[:space:]]+--local)?[[:space:]]+user\.(name|email)'
# 未移行ファイル（TESTS_DIR 相対、1 行 1 path）。移行したら消す。空が完成形。
# ここに書いてあるのにヒットしない entry は stale として赤（単調縮小の強制）。
allowlist=""

scan_rc=0
grep -rlE "$CFG_RE" "$TESTS_DIR" --include='*.sh' \
  >"$TMP/direct.raw" 2>&1 || scan_rc=$?
if [ "$scan_rc" -ge 2 ]; then
  bad "静的照合の grep が rc=$scan_rc で失敗（走査不能。fail-closed）: $(cat "$TMP/direct.raw")"
else
  grep -v -F "$LIB" "$TMP/direct.raw" | grep -v -F "$SCRIPT_DIR/" | sed "s#^$TESTS_DIR/##" | sed '/^$/d' | sort -u >"$TMP/hits.txt" || true
  printf '%s\n' "$allowlist" | sed '/^$/d' | sort -u >"$TMP/allow.txt"
  comm -23 "$TMP/hits.txt" "$TMP/allow.txt" >"$TMP/unmigrated.txt" || true
  comm -13 "$TMP/hits.txt" "$TMP/allow.txt" >"$TMP/stale.txt" || true
  unmigrated="$(cat "$TMP/unmigrated.txt")"
  stale="$(cat "$TMP/stale.txt")"
  allow_n="$(grep -c . "$TMP/allow.txt" || true)"
  if [ -n "$unmigrated" ] || [ -n "$stale" ]; then
    [ -n "$unmigrated" ] && {
      bad "user.name / user.email を直接 git config している（ff_git_fixture_init を使うか allowlist へ）:"
      sed 's/^/      /' "$TMP/unmigrated.txt" >&2
    }
    [ -n "$stale" ] && {
      bad "allowlist にヒットしない stale entry がある（移行済みなら消す）:"
      sed 's/^/      /' "$TMP/stale.txt" >&2
    }
  elif [ "$allow_n" -eq 0 ]; then
    ok "tests/ 配下に user.name / user.email を直接 git config する箇所が lib と本 suite 以外に無い"
  else
    ok "tests/ 配下の直接 git config user.* は allowlist ${allow_n} 件に限る（lib / 本 suite 以外）"
  fi
fi

# 走査契約そのもの（live tree は移行済みなので、temp tree で検出漏れと stale を固定する）
SCAN_TREE="$TMP/scan-tree"
mkdir -p "$SCAN_TREE/lib" "$SCAN_TREE/evil" "$SCAN_TREE/git-fixture-isolation"
printf '%s\n' 'git -C "$abs" config --local user.name "$name"' >"$SCAN_TREE/lib/git-fixture.sh"
printf '%s\n' 'git config user.email test@example.com' >"$SCAN_TREE/evil/verify.sh"
printf '%s\n' '# isolation' >"$SCAN_TREE/git-fixture-isolation/verify.sh"
scan_rc=0
grep -rlE "$CFG_RE" "$SCAN_TREE" --include='*.sh' >"$TMP/scan.raw" 2>&1 || scan_rc=$?
grep -v -F "$SCAN_TREE/lib/git-fixture.sh" "$TMP/scan.raw" | grep -v -F "$SCAN_TREE/git-fixture-isolation/" \
  | sed "s#^$SCAN_TREE/##" | sed '/^$/d' | sort -u >"$TMP/scan-hits.txt" || true
if [ "$scan_rc" -lt 2 ] && [ "$(cat "$TMP/scan-hits.txt")" = "evil/verify.sh" ]; then
  ok "静的照合は fixture 以外の identity（test@example.com）も未移行として拾う"
else
  bad "静的照合が fixture 以外の identity を見逃す (rc=$scan_rc, hits='$(tr '\n' ' ' <"$TMP/scan-hits.txt")')"
fi
: >"$TMP/scan-allow-empty.txt"
printf '%s\n' "gone/verify.sh" >"$TMP/scan-allow-stale.txt"
comm -13 "$TMP/scan-hits.txt" "$TMP/scan-allow-empty.txt" >"$TMP/scan-stale-empty.txt" || true
comm -13 "$TMP/scan-hits.txt" "$TMP/scan-allow-stale.txt" >"$TMP/scan-stale.txt" || true
if [ ! -s "$TMP/scan-stale-empty.txt" ] && [ "$(cat "$TMP/scan-stale.txt")" = "gone/verify.sh" ]; then
  ok "allowlist が空なら stale は出ず、ヒットしない entry は stale として赤になる"
else
  bad "allowlist の stale 判定が空と非空で区別できない"
fi

# 移行済みの利用箇所（ヘルパーは既定 identity を持つため、fixture 文字列ではなく呼び出しで数える）
users="$(grep -rlF 'ff_git_fixture_init' "$TESTS_DIR" --include='*.sh' 2>/dev/null \
  | grep -v -F "$LIB" | grep -v -F "$SCRIPT_DIR/" | grep -v -F "$TESTS_DIR/run-all.sh" || true)"
if [ -z "$users" ]; then
  bad "ff_git_fixture_init を使う suite が 1 件も見つからない（走査の空振り。fail-closed）"
else
  missing=""
  src_re='^[[:space:]]*(\.|source)[[:space:]]+.*lib/git-fixture\.sh'
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # lib の source は同ファイルか、同ディレクトリの verify.sh（cases ファイルを source する親）
    # lint 用の source= 指示コメント行では満たさない（実際の . / source 行だけ）。cases ファイルは
    # 同階層または 1 つ上の verify.sh（cases を source する親）でよい
    if ! grep -qE "$src_re" "$f" && ! grep -qE "$src_re" "$(dirname "$f")/verify.sh" 2>/dev/null \
      && ! grep -qE "$src_re" "$(dirname "$(dirname "$f")")/verify.sh" 2>/dev/null; then
      missing="$missing $f"
    fi
  done <<EOF
$users
EOF
  # consumer 名簿を件数 + ファイル名で pin する（1 件でも raw init + config へ戻れば赤。
  # 移行を増やしたらこの名簿も更新する）
  expected_users="adapter-argv-limit/verify.sh
adapter-base-ref-freshness/verify.sh
adapter-model-args/verify.sh
adapter-prompt-guard/verify.sh
adapter-prompt-utf8/verify.sh
changelog-fragments/cases/footer.sh
changelog-fragments/cases/parallel-branches.sh
changelog-public-tags-selftest/verify.sh
docs-gates-runtime/ci-example-cases.sh
guard-checkout-restore/verify.sh
markdownlint-selftest/verify.sh
mbcs-guard-failclosed/verify.sh
merge-cleanup/verify.sh
multi-agent-critical-marker/verify.sh
multi-agent-ignore-paths/verify.sh
multi-agent-plan/verify.sh
multi-agent-resume/verify.sh
multi-agent-review-banner/verify.sh
multi-agent-revision-guard/verify.sh
multi-agent-serialization/verify.sh
multi-agent-skip-poisoned-cli/verify.sh
multi-agent-stale-outputs/verify.sh
multi-agent-timeout/verify.sh
release-required-selftest/verify.sh
review-capture-fail-loud/verify.sh
review-diff-scope/verify.sh
review-wrapper-shim/verify.sh
reviewer-pair/verify.sh
shared-version-convergence/cases/claim-helper-failures.sh
shared-version-convergence/cases/merge-races.sh
shared-version-convergence/verify.sh
sync-forbidden-patterns/verify.sh
sync-sha-contract/reuse-runtime.sh
sync-sha-contract/src-sha-runtime.sh
update-check/verify.sh"
  actual_users="$(printf '%s\n' "$users" | sed "s#^$TESTS_DIR/##" | sort)"
  expected_count="$(printf '%s\n' "$expected_users" | grep -c .)"
  if [ "$actual_users" != "$expected_users" ]; then
    missing="$missing 名簿不一致（期待: $(printf '%s' "$expected_users" | tr '\n' ' ')/ 実体: $(printf '%s' "$actual_users" | tr '\n' ' '))"
  fi
  if [ -z "$missing" ]; then
    ok "ff_git_fixture_init を使う ${expected_count} ファイル（名簿一致）すべてが lib を source している"
  else
    bad "ff_git_fixture_init を使うが lib を source していない:$missing"
  fi
  # -f ガードは verify.sh だけをコピーする selftest に限る。必須 suite が optional source
  # だと GIT_DIR 継承下で raw git init が外側を汚してから command not found になる。
  guarded="$(grep -rlE 'if \[ -f .*lib/git-fixture\.sh' "$TESTS_DIR" --include='*.sh' 2>/dev/null \
    | grep -v -F "$LIB" | grep -v -F "$SCRIPT_DIR/" || true)"
  expected_guard="release-required-selftest/verify.sh
sync-forbidden-patterns/verify.sh"
  actual_guard="$(printf '%s\n' "$guarded" | sed "s#^$TESTS_DIR/##" | sed '/^$/d' | sort)"
  if [ "$actual_guard" != "$expected_guard" ]; then
    bad "git-fixture.sh の -f source ガードが copy-only selftest 2 件以外にある（期待: $(printf '%s' "$expected_guard" | tr '\n' ' ')/ 実体: $(printf '%s' "$actual_guard" | tr '\n' ' '))"
  else
    ok "git-fixture.sh の -f source ガードは verify.sh だけをコピーする 2 suite に限る"
  fi
fi
# 移行前の形（fixture を自前で git init → config）が残っていないこと。fixture identity の
# 文字列そのものは lib の既定値へ寄せたので、tests/ の他の場所に現れないはず。
scan_rc=0
grep -rlF 'fixture@example.invalid' "$TESTS_DIR" --include='*.sh' >"$TMP/stray.raw" 2>&1 || scan_rc=$?
stray="$(grep -v -F "$LIB" "$TMP/stray.raw" | grep -v -F "$SCRIPT_DIR/" || true)"
if [ "$scan_rc" -ge 2 ]; then
  bad "静的照合の grep が rc=$scan_rc で失敗（走査不能。fail-closed）: $(cat "$TMP/stray.raw")"
elif [ -z "$stray" ]; then
  ok "fixture identity の文字列は lib と本 suite 以外に無い"
else
  bad "fixture identity を lib 以外で直書きしている（ff_git_fixture_init の既定値を使うこと）:"
  printf '      %s\n' "$stray" >&2
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ git-fixture-isolation verify: $FAIL 件失敗（$PASS 件成功）" >&2
  exit 1
fi
echo "✓ git-fixture-isolation verify: 全 $PASS 件 pass"
FF_REACHED_END=1
exit 0
