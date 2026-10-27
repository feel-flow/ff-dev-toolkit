#!/usr/bin/env bash
# 空振り検出: security-glob の不在・空、設定の不在（明示）・読めない・yq 不在・キー検査の失敗・review 配下以外への配置・文字列でない / 空の値・未知の値、変更 0 件、根の判定不能を与えると M1 と M3〜M16 が unknown 以外（no への縮退）で、M2 は --check の緑で赤になる（M10 は root 実行者だけ skip）。
#
# セキュリティに関わる変更の判定と、主担当ホストでの専用ゲートの分岐（Issue `#2391`）。
#
# 固定するもの:
#   S. 分類（scripts/decision-tree/route.sh の security-glob と scripts/review-route.sh の写像）:
#      認証まわりの差分（--git --base の git fixture）は該当 + 根拠の path、docs だけの差分は
#      該当なし、プロジェクト設定の追加パターン・置き換え・env の 3 層が効く
#   G. 分岐: 主担当 claude-code + 該当 → security-review、grok-cli / 判定できないホスト →
#      unsupported と「未対応（主担当 <cli>」の 1 行（「指摘なし」と書かない）、security_review=off
#      → off、該当なし → none
#   B. /security-review の基点: 差分モードの base が origin/HEAD と一致すれば実行、食い違う・
#      origin/HEAD が無い回は unverified（走らせず未確認）、--files は照合しない（unchecked）
#   M. 針が当たらない入力: 分類・設定を読めない回はすべて unknown（no へ倒さない）で、unknown は
#      ゲートの対象から外れない（none にならない）
#
# 規定の正本は docs-template/05-operations/deployment/self-review.md「レビュー担当の選択と
# 利用制限時の継続」の専用セキュリティゲート項。出力行の契約は review-route.sh のヘッダ。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/security-review-gate/verify.sh

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -P -- "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(CDPATH= cd -P -- "${SCRIPT_DIR}/../.." && pwd -P)"
REVIEW_ROUTE_SH="${PLUGIN_ROOT}/scripts/review-route.sh"
ROUTER="${PLUGIN_ROOT}/scripts/decision-tree/route.sh"
TREE="${PLUGIN_ROOT}/scripts/decision-tree/tree.tsv"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

for f in "$REVIEW_ROUTE_SH" "$ROUTER" "$TREE"; do
  [ -s "$f" ] || { echo "✗ 検査対象がありません: $f" >&2; exit 1; }
done
command -v git >/dev/null 2>&1 || { echo "✗ git がありません（--git fixture を作れない）" >&2; exit 1; }

if ! TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/security-review-gate.XXXXXX" 2>&1)" || [ ! -d "$TEST_TMP" ]; then
  echo "✗ 一時ディレクトリを作れません: ${TEST_TMP}" >&2
  exit 1
fi
trap 'chmod -R u+rwx "$TEST_TMP" 2>/dev/null; rm -rf "$TEST_TMP"' EXIT

# 実行環境の設定・ホスト判定を持ち込まない。各検査が必要な env だけを前置する
run_gate() { # [VAR=値 ...] -- <review-route.sh の引数...>
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  RC=0
  OUT="$(cd "$CWD" && env -u FF_JEV_MODE -u FF_JEV_POINTS -u FF_JEV_ENABLED \
    -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
    -u CLAUDECODE -u GROK_AGENT -u MULTI_AGENT_CONFIG \
    -u MULTI_AGENT_SECURITY_GLOB -u MULTI_AGENT_SECURITY_GLOB_EXTRA -u MULTI_AGENT_SECURITY_REVIEW \
    -u WORKFLOW_TIER_BASE ${envs[@]+"${envs[@]}"} \
    bash "$REVIEW_ROUTE_SH" "$@" 2>"$TEST_TMP/stderr")" || RC=$?
}
kv() { printf '%s\n' "$OUT" | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }
all() { printf '%s\n' "$OUT" | awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'; }
assert_gate() { # <label> <sensitive> <gate>
  if [ "$(kv REVIEW_SECURITY_SENSITIVE)" = "$2" ] && [ "$(kv REVIEW_SECURITY_GATE)" = "$3" ]; then
    ok "$1"
  else
    bad "$1: rc=$RC sensitive=[$(kv REVIEW_SECURITY_SENSITIVE)] gate=[$(kv REVIEW_SECURITY_GATE)] line=[$(kv REVIEW_SECURITY_REPORT_LINE)]"
  fi
}

# ---- git fixture: base ブランチと、認証まわり / docs だけを変えた 2 ブランチ -----------------
REPO="$TEST_TMP/repo"
# shellcheck source=../lib/git-fixture.sh
. "${SCRIPT_DIR}/../lib/git-fixture.sh" || { echo "✗ tests/lib/git-fixture.sh を読めません" >&2; exit 1; }
ff_git_fixture_init "$REPO" || { echo "✗ git fixture を初期化できません" >&2; exit 1; }
mkdir -p "$REPO/src/auth" "$REPO/src/lib" "$REPO/docs"
(
  cd "$REPO" || exit 1
  git symbolic-ref HEAD refs/heads/base \
    && printf 'a\n' > src/lib/util.ts && printf 'a\n' > src/auth/login.ts && printf 'a\n' > docs/guide.md \
    && git add -A && git commit -qm base \
    && git checkout -qb auth-change && printf 'b\n' >> src/auth/login.ts && printf 'b\n' >> src/lib/util.ts \
    && git commit -qam auth \
    && git checkout -q base && git checkout -qb docs-change && printf 'b\n' >> docs/guide.md \
    && git commit -qam docs \
    && git update-ref refs/remotes/origin/base base \
    && git update-ref refs/remotes/origin/other docs-change \
    && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/base
) >/dev/null 2>&1 || { echo "✗ git fixture を作れません" >&2; exit 1; }
CWD="$REPO"

echo "security-review-gate S: 分類"
git -C "$REPO" checkout -q auth-change
run_gate CLAUDECODE=1 -- --git --base base
if [ "$RC" -eq 0 ] && [ "$(kv REVIEW_SECURITY_SENSITIVE)" = "yes" ] && [ "$(all REVIEW_SECURITY_EVIDENCE)" = "src/auth/login.ts" ]; then
  ok "S1 認証まわりの差分（--git --base）は該当で、根拠の path は該当したファイルだけ"
else
  bad "S1 認証まわり: rc=$RC sensitive=[$(kv REVIEW_SECURITY_SENSITIVE)] evidence=[$(all REVIEW_SECURITY_EVIDENCE)]"
fi
case "$(kv REVIEW_SECURITY_REPORT_LINE)" in
  "専用セキュリティゲート: /security-review を実行する（根拠: src/auth/login.ts）") ok "S2 報告行に根拠の path が出る" ;;
  *) bad "S2 報告行: [$(kv REVIEW_SECURITY_REPORT_LINE)]" ;;
esac
git -C "$REPO" checkout -q docs-change
run_gate CLAUDECODE=1 -- --git --base base
assert_gate "S3 docs だけの差分は該当なし（ゲート none）" no none
[ "$(kv REVIEW_SECURITY_REPORT_LINE)" = "専用セキュリティゲート: 対象外（該当変更なし）" ] \
  && ok "S4 該当なしの報告行は「対象外（該当変更なし）」" || bad "S4 該当なしの報告行: [$(kv REVIEW_SECURITY_REPORT_LINE)]"
run_gate CLAUDECODE=1 -- --files docs/auth-guide.md SECURITY.md
assert_gate "S5 docs-glob に当たる path は名前に auth / security を含んでも該当にしない" no none
run_gate CLAUDECODE=1 -- --files src/Middleware/AUTH.TS
assert_gate "S6 大文字小文字を区別しない" yes security-review

CFG="$TEST_TMP/agent-config.yaml"
run_gate CLAUDECODE=1 -- --files app/ledger/post.rb
assert_gate "S7 既定のパターンに当たらない path は該当なし（S8 の対照）" no none
printf 'review:\n  security_glob_extra: "app/ledger/*"\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
if [ "$(kv REVIEW_SECURITY_SENSITIVE)" = "yes" ] && [ "$(all REVIEW_SECURITY_EVIDENCE)" = "app/ledger/post.rb" ]; then
  ok "S8 プロジェクト設定の review.security_glob_extra で追加したパターンで該当になる"
else
  bad "S8 追加パターン: sensitive=[$(kv REVIEW_SECURITY_SENSITIVE)] evidence=[$(all REVIEW_SECURITY_EVIDENCE)]"
fi
mkdir -p "$REPO/.claude"
cp "$CFG" "$REPO/.claude/agent-config.yaml"
run_gate CLAUDECODE=1 -- --files app/ledger/post.rb
assert_gate "S9 MULTI_AGENT_CONFIG が無ければ <repo>/.claude/agent-config.yaml を読む" yes security-review
rm -f "$REPO/.claude/agent-config.yaml"
printf 'review:\n  security_glob: "app/ledger/*"\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files src/auth/login.ts
assert_gate "S10 review.security_glob は既定を置き換える（既定の *auth* が外れる）" no none
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" "MULTI_AGENT_SECURITY_GLOB=src/*" -- --files src/auth/login.ts
assert_gate "S11 env はプロジェクト設定より優先する" yes security-review
run_gate CLAUDECODE=1 "MULTI_AGENT_SECURITY_GLOB_EXTRA=app/ledger/*" -- --files app/ledger/post.rb
assert_gate "S12 env の MULTI_AGENT_SECURITY_GLOB_EXTRA だけでも追加できる" yes security-review
printf 'review: {security_glob_extra: "app/ledger/*"}\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
assert_gate "S13 フロー形式（review: {security_glob_extra: …}）のキーも読む" yes security-review
printf 'review:\n  "security_glob_extra": "app/ledger/*"\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
assert_gate "S14 引用付きのキーも読む" yes security-review
run_gate CLAUDECODE=1 -- --files src/auth/a.ts src/session/b.ts docs/auth.md
if [ "$(all REVIEW_SECURITY_EVIDENCE | awk 'NF { n++ } END { print n + 0 }')" = "2" ] \
  && [ "$(kv REVIEW_SECURITY_REPORT_LINE)" = "専用セキュリティゲート: /security-review を実行する（根拠: src/auth/a.ts ほか 1 件）" ]; then
  ok "S15 根拠が複数なら 1 行 1 path で全件を出し、報告行は「ほか N 件」"
else
  bad "S15 複数の根拠: evidence=[$(all REVIEW_SECURITY_EVIDENCE)] line=[$(kv REVIEW_SECURITY_REPORT_LINE)]"
fi

echo "security-review-gate G: 主担当ホストでの分岐"
run_gate CLAUDECODE=1 -- --files src/auth/login.ts
[ "$(kv REVIEW_PRIMARY_HOST)" = "claude-code" ] && ok "G1 CLAUDECODE=1 は主担当 claude-code" || bad "G1 主担当: [$(kv REVIEW_PRIMARY_HOST)]"
run_gate GROK_AGENT=1 -- --files src/auth/login.ts
assert_gate "G2 主担当 grok-cli で該当 → unsupported" yes unsupported
line="$(kv REVIEW_SECURITY_REPORT_LINE)"
case "$line" in
  *"未対応（主担当 grok-cli"*) case "$line" in *指摘なし*) bad "G3 未対応の行が「指摘なし」を含む: [$line]" ;; *) ok "G3 未対応は「未対応（主担当 grok-cli」と記録し「指摘なし」と書かない" ;; esac ;;
  *) bad "G3 未対応の行: [$line]" ;;
esac
run_gate -- --files src/auth/login.ts
line="$(kv REVIEW_SECURITY_REPORT_LINE)"
if [ "$(kv REVIEW_PRIMARY_HOST)" = "unknown" ] && [ "$(kv REVIEW_SECURITY_GATE)" = "unsupported" ]; then
  case "$line" in
    *"未対応（主担当 unknown"*) case "$line" in *指摘なし*) bad "G4 「指摘なし」を含む: [$line]" ;; *) ok "G4 ホストを判定できない（Codex 等）回は unknown / unsupported と「未対応（主担当 unknown」（黙って省略しない）" ;; esac ;;
    *) bad "G4 判定できないホストの報告行: [$line]" ;;
  esac
else
  bad "G4 判定できないホスト: host=[$(kv REVIEW_PRIMARY_HOST)] gate=[$(kv REVIEW_SECURITY_GATE)]"
fi
run_gate CLAUDECODE=1 GROK_AGENT=1 -- --files src/auth/login.ts
[ "$(kv REVIEW_PRIMARY_HOST)" = "unknown" ] && ok "G5 両方の印が立つ回は入れ子の向きが分からないので unknown" || bad "G5 両方: [$(kv REVIEW_PRIMARY_HOST)]"
run_gate CLAUDECODE=1 MULTI_AGENT_SECURITY_REVIEW=off -- --files src/auth/login.ts
assert_gate "G6 security_review=off（env）は判定を出したうえで off" yes off
printf 'review:\n  security_review: "off"\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files src/auth/login.ts
assert_gate "G7 security_review=off（プロジェクト設定）" yes off
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" MULTI_AGENT_SECURITY_REVIEW=auto -- --files src/auth/login.ts
assert_gate "G8 env の auto はプロジェクト設定の off より優先する" yes security-review
run_gate CLAUDECODE=1 -- --files src/auth/login.ts --lines 40
[ "$RC" -eq 0 ] && [ "$(kv REVIEW_ROUTE)" = "full" ] && [ "$(kv REVIEW_LANES)" = "codex:1+claude:4" ] \
  && ok "G9 専用ゲートの行は経路（REVIEW_ROUTE / LANES）を変えない" || bad "G9 経路: rc=$RC route=[$(kv REVIEW_ROUTE)]"

echo "security-review-gate B: /security-review の基点（origin/HEAD）と base の照合"
git -C "$REPO" checkout -q auth-change
run_gate CLAUDECODE=1 -- --git --base origin/base
[ "$(kv REVIEW_SECURITY_BASE_CHECK)" = "match" ] && [ "$(kv REVIEW_SECURITY_GATE)" = "security-review" ] \
  && ok "B1 base が origin/HEAD と一致 → match / security-review" || bad "B1 一致: check=[$(kv REVIEW_SECURITY_BASE_CHECK)] gate=[$(kv REVIEW_SECURITY_GATE)]"
run_gate CLAUDECODE=1 -- --git --base origin/other
line="$(kv REVIEW_SECURITY_REPORT_LINE)"
if [ "$(kv REVIEW_SECURITY_BASE_CHECK)" = "mismatch" ] && [ "$(kv REVIEW_SECURITY_GATE)" = "unverified" ]; then
  case "$line" in
    *"未確認（/security-review の基点 origin/base が base origin/other と食い違います"*) ok "B2 base が origin/HEAD と食い違う → unverified と「未確認」の 1 行（走らせない）" ;;
    *) bad "B2 食い違いの報告行: [$line]" ;;
  esac
else
  bad "B2 食い違い: check=[$(kv REVIEW_SECURITY_BASE_CHECK)] gate=[$(kv REVIEW_SECURITY_GATE)]"
fi
git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD
run_gate CLAUDECODE=1 -- --git --base origin/base
[ "$(kv REVIEW_SECURITY_BASE_CHECK)" = "no-origin-head" ] && [ "$(kv REVIEW_SECURITY_GATE)" = "unverified" ] \
  && ok "B3 origin/HEAD が無い → unverified（/security-review はそのままでは動かない）" || bad "B3 origin/HEAD なし: check=[$(kv REVIEW_SECURITY_BASE_CHECK)] gate=[$(kv REVIEW_SECURITY_GATE)]"
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/base
run_gate CLAUDECODE=1 -- --files src/auth/login.ts
[ "$(kv REVIEW_SECURITY_BASE_CHECK)" = "unchecked" ] && ok "B4 --files は base を持たないので unchecked" || bad "B4 --files: [$(kv REVIEW_SECURITY_BASE_CHECK)]"
run_gate GROK_AGENT=1 -- --git --base origin/other
[ "$(kv REVIEW_SECURITY_GATE)" = "unsupported" ] && ok "B5 主担当 claude-code 以外は基点の照合より未対応が先" || bad "B5 grok + 食い違い: [$(kv REVIEW_SECURITY_GATE)]"
# 名前が揃っていても指すコミットが違えば食い違い（ローカルの base が origin より古い回）
git -C "$REPO" update-ref refs/remotes/origin/base docs-change
run_gate CLAUDECODE=1 -- --git --base base
[ "$(kv REVIEW_SECURITY_BASE_CHECK)" = "mismatch" ] && [ "$(kv REVIEW_SECURITY_GATE)" = "unverified" ] \
  && ok "B6 base と origin/HEAD は名前ではなくコミットで照合する（名前一致・コミット不一致 → mismatch）" \
  || bad "B6 コミット照合: check=[$(kv REVIEW_SECURITY_BASE_CHECK)] gate=[$(kv REVIEW_SECURITY_GATE)]"
git -C "$REPO" update-ref refs/remotes/origin/base base
# 決定木のルータが無い配置: 何も判定できないので unknown / unverified と未確認の 1 行、exit 2
NOROUTER="$TEST_TMP/norouter"
mkdir -p "$NOROUTER/scripts" "$NOROUTER/.claude-plugin"
cp "$REVIEW_ROUTE_SH" "$NOROUTER/scripts/"
cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$NOROUTER/.claude-plugin/"
RC=0
OUT="$(cd "$CWD" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT CLAUDECODE=1 bash "$NOROUTER/scripts/review-route.sh" --files src/auth/login.ts 2>/dev/null)" || RC=$?
[ "$RC" -eq 2 ] && [ "$(kv REVIEW_SECURITY_SENSITIVE)" = "unknown" ] && [ "$(kv REVIEW_SECURITY_GATE)" = "unverified" ] \
  && [ "$(kv REVIEW_SECURITY_REPORT_LINE)" = "専用セキュリティゲート: 未確認（判定不能: 決定木のルータがありません）" ] \
  && ok "B7 ルータが無い配置は unknown / unverified と「未確認」の 1 行で exit 2" \
  || bad "B7 ルータ不在: rc=$RC gate=[$(kv REVIEW_SECURITY_GATE)] line=[$(kv REVIEW_SECURITY_REPORT_LINE)]"

echo "security-review-gate M: 針が当たらない入力は unknown（no へ倒さない）"
NOSEC_TREE="$TEST_TMP/tree-nosec.tsv"
awk -F'\t' '!($1 == "rule" && $3 == "security-glob")' "$TREE" > "$NOSEC_TREE"
run_gate CLAUDECODE=1 -- --files src/auth/login.ts --tree "$NOSEC_TREE"
assert_gate "M1 木データに security-glob が無い → unknown（ゲートの対象のまま）" unknown security-review
RC=0; bash "$ROUTER" --check --tree "$NOSEC_TREE" --plugin-root "$PLUGIN_ROOT" >"$TEST_TMP/check.out" 2>&1 || RC=$?
[ "$RC" -eq 1 ] && grep -q 'rule security-glob がありません' "$TEST_TMP/check.out" \
  && ok "M2 route.sh --check は security-glob の欠落を赤にする" || bad "M2 --check: rc=$RC"
run_gate CLAUDECODE=1 "MULTI_AGENT_SECURITY_GLOB= " -- --files src/auth/login.ts
assert_gate "M3 空白だけの security-glob → unknown" unknown security-review
printf 'tasks:\n  review:\n    security_glob_extra: "app/ledger/*"\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
assert_gate "M4 security_* キーを review 配下以外（tasks.review）に置いた → unknown" unknown security-review
printf 'review:\n  security_review: false\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
assert_gate "M5 文字列でない値（YAML の false）→ unknown（off にも auto にも読み替えない）" unknown security-review
printf 'review:\n  security_glob_extra:\n    - "app/ledger/*"\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
assert_gate "M6 YAML リストのパターン → unknown" unknown security-review
run_gate CLAUDECODE=1 MULTI_AGENT_SECURITY_REVIEW=disabled -- --files app/ledger/post.rb
assert_gate "M7 security_review の未知の値 → unknown" unknown security-review
: > "$TEST_TMP/empty.txt"
run_gate CLAUDECODE=1 -- --files-from "$TEST_TMP/empty.txt"
assert_gate "M8 変更 0 件 → unknown（空集合を該当なしにしない）" unknown security-review
run_gate CLAUDECODE=1 -- --files src/lib/util.ts --lines abc
[ "$RC" -eq 2 ] && [ "$(kv REVIEW_SECURITY_SENSITIVE)" = "unknown" ] \
  && ok "M9 根が判定不能（exit 2）の回も unknown" || bad "M9 判定不能: rc=$RC sensitive=[$(kv REVIEW_SECURITY_SENSITIVE)]"
printf 'review:\n  security_glob_extra: "app/ledger/*"\n' > "$CFG"
chmod 000 "$CFG"
if [ -r "$CFG" ]; then
  echo "  ○ skip: 権限を外してもファイルを読める実行者（root 等）なので M10 は未実行"
else
  run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
  assert_gate "M10 読めないプロジェクト設定 → unknown" unknown security-review
fi
chmod 644 "$CFG"
NOYQ_PATH="$TEST_TMP/noyq-bin"
mkdir -p "$NOYQ_PATH"
for tool in bash env git awk grep sed cat tr mktemp dirname rm cut sort; do
  p="$(command -v "$tool" 2>/dev/null)" && [ -n "$p" ] && ln -s "$p" "$NOYQ_PATH/$tool"
done
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" "PATH=$NOYQ_PATH" -- --files app/ledger/post.rb
assert_gate "M11 yq が無い環境で security_* キーがある → unknown（追加パターンを黙って捨てない）" unknown security-review
# yq が無い環境でキーの有無を見る awk 自体が失敗した回（rc 2 以上）を「キーが無い」と読まない。
# キーを持たない設定で測る — 正常なら no（M12a の対照）、検査の失敗だけが unknown にする
BADAWK_PATH="$TEST_TMP/badawk-bin"
mkdir -p "$BADAWK_PATH"
REAL_AWK="$(command -v awk)"
printf '#!/bin/sh\ncase "$*" in *security_*) exit 2 ;; esac\nexec "%s" "$@"\n' "$REAL_AWK" > "$BADAWK_PATH/awk"
chmod +x "$BADAWK_PATH/awk"
printf 'version: "2.0"\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" "PATH=$NOYQ_PATH" -- --files app/ledger/post.rb
assert_gate "M12a 対照: yq の無い環境でキーを持たない設定は no" no none
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" "PATH=$BADAWK_PATH:$NOYQ_PATH" -- --files app/ledger/post.rb
assert_gate "M12 設定キーの検査（awk）が失敗した → unknown" unknown security-review
assert_reason() { # <label> <理由の部分文字列>
  case "$(kv REVIEW_SECURITY_REPORT_LINE)" in
    *"$2"*) ok "$1" ;;
    *) bad "$1: line=[$(kv REVIEW_SECURITY_REPORT_LINE)]" ;;
  esac
}
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$TEST_TMP/no-such-config.yaml" -- --files app/ledger/post.rb
assert_gate "M13 MULTI_AGENT_CONFIG で明示したファイルが無い → unknown（既定へ戻さない）" unknown security-review
assert_reason "M13a 報告行は明示した設定ファイルの不在を名指しする" "MULTI_AGENT_CONFIG の設定ファイルがありません"
printf 'review:\n  security_review: auto\ntasks:\n  review:\n    security_glob_extra: "app/ledger/*"\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
assert_gate "M14 review 配下の正しいキーと置き場違いのキーの併記 → unknown（置き場違いを黙って捨てない）" unknown security-review
assert_reason "M14a 報告行は置き場違いを名指しする" "review 配下以外にあります"
printf 'review:\n  security_glob_extra: ""\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" -- --files app/ledger/post.rb
assert_gate "M15 review 配下の空文字の値 → unknown" unknown security-review
assert_reason "M15a 報告行は空の値を名指しする（置き場違いと誤報しない）" "review.security_glob_extra が空です"
printf 'review: {security_glob_extra: "app/ledger/*"}\n' > "$CFG"
run_gate CLAUDECODE=1 "MULTI_AGENT_CONFIG=$CFG" "PATH=$NOYQ_PATH" -- --files app/ledger/post.rb
assert_gate "M16 yq が無い環境でフロー形式のキーがある → unknown（行頭一致で見落とさない）" unknown security-review

echo ""
echo "security-review-gate: passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
