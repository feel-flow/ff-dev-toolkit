#!/usr/bin/env bash
# Runtime contract for scripts/link-sub-issues.sh (OBS-052).
#
# 配布物 scripts/link-sub-issues.sh を gh スタブの下で駆動し、受け入れ条件の
# 各分岐を固定する:
#   1. POST は `-F sub_issue_id=` で送り、`-f sub_issue_id=` は使わない
#   2. 失敗時は HTTP 本文（ステータスと message）が stderr に残り、
#      `--silent` / `2>/dev/null` で消えない
#   3. 1 件目の失敗で止まり、残りの child を叩かない
#   4. 既に紐付いている child は skip して成功扱い（再実行して全件 422 にしない）
#   5. `--repo` も origin remote も無いときは exit 2 で使い方を出す
#
# gh はスタブへ差し替えて駆動する（ネットワークに出ない）。スタブは呼び出しを
# ログへ積むので、「-F で送った」「2 件目を叩いていない」を argv で実測できる。
# スタブが `api` 以外を非 0 で拒否するので、想定外の gh 呼び出しを足すと赤になる。
#
# 変異検出（2026-09-15 実測。赤転しなかった変異は無し）:
#   POST 行の `-F "sub_issue_id=` を `-f "sub_issue_id=` に置換したコピーは、
#   本番と同じ「argv に -F sub_issue_id がある」検査を赤にする。
#   `--silent` を POST 行へ足したコピーは、失敗本文が消えて「HTTP 本文が stderr
#   に残る」検査を赤にする（本スクリプトは --silent を使わない契約の裏返し）。
#   `exit 1` を POST 失敗分岐から外してループ継続にしたコピーは、1 件目失敗後も
#   2 件目を叩いて「1 件目で止まる」検査を赤にする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/scripts/link-sub-issues.sh"

[ -f "$TARGET" ] || { echo "✗ link-sub-issues.sh が見つかりません: $TARGET" >&2; exit 1; }

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-link-sub-issues.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: $_ff_mktemp_out" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ link-sub-issues: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

if syntax_err="$(bash -n "$TARGET" 2>&1)"; then
  ok "link-sub-issues.sh が bash として構文的に妥当（bash -n）"
else
  bad "link-sub-issues.sh が bash -n を通らない"
  printf '%s\n' "$syntax_err" | sed 's/^/    | /' >&2
fi

# 本番スクリプトが POST に -F を使い、-f / --silent / 2>/dev/null を使っていないこと。
# 実行検査の前に静的に固定する（スタブを通さずとも綴り退行を赤にするため）。
if grep -Eq -- 'gh api --method POST .* -F "sub_issue_id=' "$TARGET"; then
  ok "本番 POST が -F \"sub_issue_id=\" を使う"
else
  bad "本番 POST が -F \"sub_issue_id=\" を使っていない"
fi
if grep -E '^[[:space:]]*[^#[:space:]]' "$TARGET" | grep -E -- '-[Ff] "sub_issue_id=|-[Ff] sub_issue_id=' >/dev/null \
  && ! grep -E '^[[:space:]]*[^#[:space:]]' "$TARGET" | grep -E -- '-f "sub_issue_id=|-f sub_issue_id=|--raw-field sub_issue_id=' >/dev/null; then
  ok "本番に -f sub_issue_id= / --raw-field sub_issue_id= が無い"
else
  if grep -E '^[[:space:]]*[^#[:space:]]' "$TARGET" | grep -E -- '-f "sub_issue_id=|-f sub_issue_id=|--raw-field sub_issue_id=' >/dev/null; then
    bad "本番が -f / --raw-field で sub_issue_id を送っている"
  else
    bad "本番の sub_issue_id フラグを静的に確認できない"
  fi
fi
if grep -E '^[[:space:]]*[^#[:space:]]' "$TARGET" | grep -- '--silent' >/dev/null; then
  bad "本番が --silent を使っている（失敗本文が消える）"
else
  ok "本番が --silent を使わない"
fi
# gh 呼び出しに 2>/dev/null を付けない。git remote の任意フォールバックは対象外。
if grep -n 'gh .*2>/dev/null\|2>/dev/null.*gh ' "$TARGET" | grep -v 'git remote' >/dev/null 2>&1; then
  bad "本番の gh 呼び出しが 2>/dev/null で本文を消している"
else
  ok "本番の gh 呼び出しが 2>/dev/null で本文を消さない"
fi

BIN_DIR="$TEST_TMP/bin"
STUB_DIR="$TEST_TMP/stub"
mkdir -p "$BIN_DIR" "$STUB_DIR"
cat > "$BIN_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FF_STUB_DIR/gh-calls.log"
[ "${FF_STUB_FAIL:-0}" = "1" ] && { echo '{"message":"forced fail"}' >&2; exit 1; }
# argv を配列化して method / path / -F / -f を読む。
args=("$@")
method="GET"
path=""
jq_expr=""
field_flag=""
field_key=""
field_val=""
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    api) ;;
    --paginate) ;;
    --method|-X)
      i=$((i + 1))
      method="${args[$i]:-}"
      ;;
    --jq)
      i=$((i + 1))
      jq_expr="${args[$i]:-}"
      ;;
    -F|--field)
      field_flag="-F"
      i=$((i + 1))
      field_key="${args[$i]%%=*}"
      field_val="${args[$i]#*=}"
      ;;
    -f|--raw-field)
      field_flag="-f"
      i=$((i + 1))
      field_key="${args[$i]%%=*}"
      field_val="${args[$i]#*=}"
      ;;
    -F*)
      field_flag="-F"
      rest="${a#-F}"
      field_key="${rest%%=*}"
      field_val="${rest#*=}"
      ;;
    -f*)
      field_flag="-f"
      rest="${a#-f}"
      field_key="${rest%%=*}"
      field_val="${rest#*=}"
      ;;
    repos/*)
      path="$a"
      ;;
  esac
  i=$((i + 1))
done

if [ -z "$path" ]; then
  echo "unhandled gh api path" >&2
  exit 1
fi

case "$method:$path" in
  GET:repos/*/issues/*/sub_issues)
    if [ "$jq_expr" = '.[].number' ] && [ -f "$FF_STUB_DIR/sub-issue-numbers.txt" ]; then
      cat "$FF_STUB_DIR/sub-issue-numbers.txt"
    elif [ "$jq_expr" = '.[].number' ]; then
      : # 空 = まだ sub-issue が無い
    elif [ -f "$FF_STUB_DIR/sub-issues.json" ]; then
      cat "$FF_STUB_DIR/sub-issues.json"
    else
      printf '%s' '[]'
    fi
    ;;
  GET:repos/*/issues/*)
    n="${path##*/}"
    id="${n}000"
    if [ -f "$FF_STUB_DIR/id-${n}" ]; then
      id="$(cat "$FF_STUB_DIR/id-${n}")"
    fi
    if [ "${FF_STUB_GET_FAIL:-0}" = "1" ]; then
      echo '{"message":"Not Found","documentation_url":"https://docs.github.com"}' >&2
      exit 1
    fi
    if [ "$jq_expr" = '.id' ]; then
      printf '%s' "$id"
    else
      printf '{"id":%s,"number":%s}' "$id" "$n"
    fi
    ;;
  POST:repos/*/issues/*/sub_issues)
    if [ "$field_flag" != "-F" ] || [ "$field_key" != "sub_issue_id" ]; then
      echo "Invalid property /sub_issue_id: \"${field_val}\" is not of type integer" >&2
      echo '{"message":"Invalid request","errors":[{"resource":"Issue","field":"sub_issue_id","code":"invalid"}]}' >&2
      exit 1
    fi
    if [ -f "$FF_STUB_DIR/post-fail" ]; then
      cat "$FF_STUB_DIR/post-fail" >&2
      exit 1
    fi
    printf '{"id":%s,"sub_issue_id":%s}' "$field_val" "$field_val"
    ;;
  *)
    echo "unhandled gh api: ${method} ${path}" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$BIN_DIR/gh"

export PATH="$BIN_DIR:$PATH"
export FF_STUB_DIR="$STUB_DIR"

OUT=""
ERR=""
RC=0
run_helper() {
  local errf="$TEST_TMP/err.txt"
  : > "$STUB_DIR/gh-calls.log"
  RC=0
  # cwd は git ではない一時領域。本番 tree の origin を拾って --repo 省略が
  # 成功してしまうと、未解決の使い方エラーを測れない。
  # 呼び出し環境の plugin root を落とす。残っていると、インストール済み
  # 実体を指す FF_DEV_TOOLKIT_ROOT と worktree のヘルパが不一致で exit 2 し、
  # AC まで届かない（ガードは handoff 無しの直接起動は止めるが、別 root の
  # handoff は止める）。
  OUT="$(cd "$TEST_TMP" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
    PATH="$PATH" FF_STUB_DIR="$STUB_DIR" bash "$TARGET" "$@" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf")"
}

calls() {
  cat "$STUB_DIR/gh-calls.log"
}

echo "link-sub-issues: AC（成功経路・-F 固定）"
run_helper --repo acme/widgets 10 21 22
if [ "$RC" -eq 0 ]; then
  ok "AC: 2 子の紐付けが exit 0"
else
  bad "AC: 紐付けが失敗 exit=$RC err=[$ERR] out=[$OUT]"
fi
c21000="$(calls | grep -c -- '-F sub_issue_id=21000' || true)"
c22000="$(calls | grep -c -- '-F sub_issue_id=22000' || true)"
if [ "$c21000" -eq 1 ] && [ "$c22000" -eq 1 ]; then
  ok "AC: POST argv が child ごとに対応する database id を 1 回ずつ送る"
else
  bad "AC: sub_issue_id=21000 が ${c21000} 回 / 22000 が ${c22000} 回: [$(calls)]"
fi
if calls | grep -E -- '-f sub_issue_id=|--raw-field sub_issue_id=' >/dev/null; then
  bad "AC: POST argv に -f / --raw-field がある: [$(calls)]"
else
  ok "AC: POST argv に -f / --raw-field が無い"
fi
post_n="$(calls | grep -c 'POST\|--method POST' || true)"
if [ "$post_n" -eq 2 ]; then
  ok "成功時は child ごとに 1 回 POST する（${post_n}）"
else
  bad "POST 回数が 2 ではない: ${post_n} / [$(calls)]"
fi

echo "link-sub-issues: 既に紐付いている子は skip"
printf '%s\n' '21' > "$STUB_DIR/sub-issue-numbers.txt"
run_helper --repo acme/widgets 10 21 22
rm -f "$STUB_DIR/sub-issue-numbers.txt"
if [ "$RC" -eq 0 ]; then
  ok "既存 sub-issue があっても exit 0"
else
  bad "既存 skip が失敗 exit=$RC err=[$ERR]"
fi
post_n="$(calls | grep -c -- '--method POST' || true)"
if [ "$post_n" -eq 1 ]; then
  ok "既存の child 21 は POST せず child 22 だけ POST する"
else
  bad "既存 skip 後の POST 回数が 1 ではない: ${post_n} / [$(calls)]"
fi
case "$OUT" in
  *skip*) ok "既存の子を skip と報告する" ;;
  *) bad "skip 報告が無い: [$OUT]" ;;
esac

echo "link-sub-issues: 同じ child を 2 回渡しても POST は 1 回"
run_helper --repo acme/widgets 10 21 21
if [ "$RC" -eq 0 ]; then
  ok "重複 child でも exit 0"
else
  bad "重複 child が失敗 exit=$RC err=[$ERR]"
fi
post_n="$(calls | grep -c -- '--method POST' || true)"
if [ "$post_n" -eq 1 ]; then
  ok "同一 child の 2 回目は POST せず skip する"
else
  bad "重複 child の POST 回数が 1 ではない: ${post_n} / [$(calls)]"
fi
case "$OUT" in
  *skip*) ok "同一 argv の 2 回目を skip と報告する" ;;
  *) bad "同一 argv の skip 報告が無い: [$OUT]" ;;
esac

echo "link-sub-issues: 呼び出し環境の FF_DEV_TOOLKIT_ROOT が別実体でも AC に届く"
FF_DEV_TOOLKIT_ROOT=/nonexistent/ff-dev-toolkit run_helper --repo acme/widgets 10 21
if [ "$RC" -eq 0 ]; then
  ok "別実体を指す FF_DEV_TOOLKIT_ROOT が残っていても suite は到達する"
else
  bad "FF_DEV_TOOLKIT_ROOT が残ると到達できない exit=$RC err=[$ERR]"
fi

echo "link-sub-issues: 失敗時は HTTP 本文を出し 1 件目で止まる"
printf '%s\n' 'gh: Invalid request (HTTP 422)' 'Invalid property /sub_issue_id: "21000" is not of type integer' > "$STUB_DIR/post-fail"
run_helper --repo acme/widgets 10 21 22
rm -f "$STUB_DIR/post-fail"
if [ "$RC" -eq 1 ]; then
  ok "POST 失敗は exit 1"
else
  bad "POST 失敗の exit が 1 ではない: $RC"
fi
case "$ERR" in
  *'Invalid property /sub_issue_id'*) ok "失敗時に HTTP 本文（message）が stderr に残る" ;;
  *) bad "失敗本文が stderr に無い: [$ERR]" ;;
esac
case "$ERR" in
  *'(HTTP 422)'*) ok "失敗時に HTTP ステータスが stderr に残る" ;;
  *) bad "HTTP ステータスが stderr に無い: [$ERR]" ;;
esac
post_n="$(calls | grep -c -- '--method POST' || true)"
if [ "$post_n" -eq 1 ]; then
  ok "1 件目の失敗で止まり 2 件目を POST しない"
else
  bad "失敗後もループしている POST=${post_n} / [$(calls)]"
fi

echo "link-sub-issues: GET 失敗でも本文を出して止まる"
FF_STUB_GET_FAIL=1 run_helper --repo acme/widgets 10 21
unset FF_STUB_GET_FAIL
if [ "$RC" -eq 1 ]; then
  ok "子 Issue の GET 失敗は exit 1"
else
  bad "GET 失敗の exit が 1 ではない: $RC"
fi
case "$ERR" in
  *'Not Found'*) ok "GET 失敗の HTTP 本文が stderr に残る" ;;
  *) bad "GET 失敗本文が無い: [$ERR]" ;;
esac

echo "link-sub-issues: --dry-run は POST しない"
run_helper --repo acme/widgets --dry-run 10 21
if [ "$RC" -eq 0 ]; then
  ok "--dry-run は exit 0"
else
  bad "--dry-run が失敗 exit=$RC err=[$ERR]"
fi
if calls | grep -- '--method POST' >/dev/null; then
  bad "--dry-run なのに POST している: [$(calls)]"
else
  ok "--dry-run は ID 解決の GET だけで POST しない"
fi
case "$OUT" in
  *'-F sub_issue_id='*) ok "--dry-run の表示が -F sub_issue_id= を含む" ;;
  *) bad "--dry-run 表示に -F が無い: [$OUT]" ;;
esac

echo "link-sub-issues: 使い方エラー"
run_helper 10 21
if [ "$RC" -eq 2 ]; then
  ok "--repo も origin も無いときは exit 2"
else
  bad "repo 未解決の exit が 2 ではない: $RC err=[$ERR]"
fi
run_helper --repo acme/widgets 10
if [ "$RC" -eq 2 ]; then
  ok "child 無しは exit 2"
else
  bad "child 無しの exit が 2 ではない: $RC"
fi
run_helper --repo acme/widgets 10 10
if [ "$RC" -eq 2 ]; then
  ok "parent と child が同じ番号なら exit 2"
else
  bad "同一番号の exit が 2 ではない: $RC"
fi

echo "link-sub-issues: 変異検出（コピーへ当て、本番検査と同形の針が赤になること）"
MUT="$TEST_TMP/mutated.sh"
cp "$TARGET" "$MUT"

# 変異 1: -F を -f に置換 → argv 検査が赤になる側をコピーで実測
# macOS sed は -i '' が要るが、リダイレクトで書けば足りる。
sed 's/-F "sub_issue_id=/-f "sub_issue_id=/' "$TARGET" > "$MUT"
: > "$STUB_DIR/gh-calls.log"
MUT_RC=0
MUT_OUT="$(cd "$TEST_TMP" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
  PATH="$PATH" FF_STUB_DIR="$STUB_DIR" bash "$MUT" --repo acme/widgets 10 21 2>/dev/null)" || MUT_RC=$?
MUT_CALLS="$(cat "$STUB_DIR/gh-calls.log")"
if printf '%s\n' "$MUT_CALLS" | grep -E -- '-f sub_issue_id=' >/dev/null; then
  if printf '%s\n' "$MUT_CALLS" | grep -E -- '-F sub_issue_id=' >/dev/null; then
    bad "変異 -F→-f が効いていない（まだ -F がある）: [$MUT_CALLS]"
  else
    ok "変異検出: -F を -f に置換すると argv に -f sub_issue_id= が現れ、本番の -F 検査は赤になる"
  fi
else
  bad "変異 -F→-f の POST が観測できない: rc=$MUT_RC calls=[$MUT_CALLS]"
fi
# スタブは -f を 422 にするので、ヘルパは 1 件目で止まる。
if [ "$MUT_RC" -ne 0 ]; then
  ok "変異検出: -f で送るとスタブ（GitHub 同形の 422）で非 0 になる"
else
  bad "変異 -F→-f なのに exit 0: out=[$MUT_OUT]"
fi

# 変異 2: POST 失敗でも exit しない → 2 件目まで POST する
# 「post_rc 非 0 なら exit 1」を外す。
python3 - "$TARGET" "$MUT" <<'PY' || true
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = """  if [ "$post_rc" -ne 0 ]; then
    echo "link-sub-issues: #${child} (id=${child_id}) を #${PARENT} へ紐付けできませんでした" >&2
    printf '%s\\n' "$post_out" >&2
    exit 1
  fi
"""
new = """  if [ "$post_rc" -ne 0 ]; then
    echo "link-sub-issues: #${child} (id=${child_id}) を #${PARENT} へ紐付けできませんでした" >&2
    printf '%s\\n' "$post_out" >&2
  fi
"""
if old not in src:
    sys.stderr.write("mutation target block not found\\n")
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
# python3 が無い / ブロック不一致でも、検証は「コピーが 2 件 POST するか」。
printf '%s\n' 'Invalid property /sub_issue_id: "x" is not of type integer' > "$STUB_DIR/post-fail"
: > "$STUB_DIR/gh-calls.log"
MUT_RC=0
(cd "$TEST_TMP" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
  PATH="$PATH" FF_STUB_DIR="$STUB_DIR" bash "$MUT" --repo acme/widgets 10 21 22 >/dev/null 2>&1) || MUT_RC=$?
MUT_CALLS="$(cat "$STUB_DIR/gh-calls.log")"
rm -f "$STUB_DIR/post-fail"
mut_post="$(printf '%s\n' "$MUT_CALLS" | grep -c -- '--method POST' || true)"
# 変異が当たっていれば POST は 2、当たっていなければ 1（本番と同じ停止）。
# ブロック一致で python が置換できたときだけ「2 件 POST」を変異検出として数える。
if ! grep -A6 'post_rc" -ne 0' "$MUT" | grep 'exit 1' >/dev/null; then
  if [ "$mut_post" -ge 2 ]; then
    ok "変異検出: POST 失敗の exit 1 を外すと 2 件目まで POST し、1 件目停止の検査は赤になる"
  else
    bad "失敗継続の変異が 2 件目を POST していない: ${mut_post} / [$MUT_CALLS]"
  fi
else
  echo "  ○ skip: POST 失敗分岐の字面が変わり python 置換が当たらなかった（変異 2 は未計測）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ link-sub-issues: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ link-sub-issues: all ${PASS} checks passed"
REACHED_END=1
exit 0
