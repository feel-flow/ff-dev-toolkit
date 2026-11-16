# shellcheck shell=bash
# check-version-claims.sh による ADR 番号衝突プリチェックの fixture テスト。
# shared-version-convergence/verify.sh から source して使う。単体では実行しない。
#
# 環境変数方針: skill-count-consistency の変数名台帳契約を守るため、stub 制御用の環境変数には
# FAKE_CLAIM_* 接頭辞のみを使い、未宣言の FF_* を置かない。

echo "== ADR number collision precheck (origin/<default> + open PRs) =="

ADR_TMP="$TMP/adr-collision"
mkdir -p "$ADR_TMP"

ADR_STUB_BIN="$ADR_TMP/gh-bin"
mkdir -p "$ADR_STUB_BIN"
cat <<'EOF' > "$ADR_STUB_BIN/gh"
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"
action="${2:-}"
if [[ "$sub" != "pr" ]]; then
  echo "unexpected gh command: $*" >&2
  exit 9
fi
case "$action" in
  list)
    case "${FAKE_CLAIM_GH_MODE:-ok}" in
      fail_list)
        echo "simulated gh pr list failure" >&2
        exit 1
        ;;
      bad_json)
        printf '%s\n' 'not-valid-json'
        exit 0
        ;;
      *)
        cat "${FAKE_CLAIM_GH_LIST_FILE:?}"
        exit 0
        ;;
    esac
    ;;
  diff)
    pr_num="${3:-}"
    if [[ "${FAKE_CLAIM_GH_MODE:-ok}" == "fail_diff" ]]; then
      echo "simulated gh pr diff failure for #$pr_num" >&2
      exit 1
    fi
    cat "${FAKE_CLAIM_GH_DIFF_DIR:?}/pr-${pr_num}.diff"
    exit 0
    ;;
  *)
    echo "unexpected gh pr action: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$ADR_STUB_BIN/gh"

adr_init_repo() { # <work_dir> [with-adr|empty-decisions]
  local bare="$ADR_TMP/$(basename "$1").bare.git"
  local seed="$ADR_TMP/$(basename "$1").seed"
  local work="$1"
  local seed_mode="${2:-with-adr}"
  git init -q --bare "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/develop
  git clone -q "$bare" "$seed"
  git -C "$seed" checkout -q -b develop
  ff_git_fixture_init "$seed" "adr-test" "adr@example.com"
  mkdir -p "$seed/docs/06-reference" "$seed/.version-claims" "$seed/scripts"
  printf '%s\n' '# version claims' > "$seed/.version-claims/README.md"
  if [[ "$seed_mode" == "with-adr" ]]; then
    cat <<'EOF' > "$seed/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.0.0"
---

# DECISIONS

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-093 | Initial Base |

## ADR-093: Initial Base

Baseline decision.
EOF
    cat <<'EOF' > "$seed/scripts/helper.sh"
#!/usr/bin/env bash
# Baseline ADR-093
echo ok
EOF
  fi
  git -C "$seed" add -A
  git -C "$seed" commit -q -m "seed develop (${seed_mode})"
  git -C "$seed" push -q -u origin develop
  git clone -q "$bare" "$work"
  ff_git_fixture_init "$work" "adr-test" "adr@example.com"
}

adr_stage_with_claim() { # <repo_dir>
  local repo="$1"
  (cd "$repo" && "$CLAIM_HELPER" --base origin/develop --document docs/06-reference/DECISIONS.md) >/dev/null
  git -C "$repo" add -A
}

EMPTY_PR_LIST="$ADR_TMP/empty-prs.json"
printf '[]\n' > "$EMPTY_PR_LIST"

# --- AC 1a: origin/develop が先行して同じ ADR-094 をマージ済み（stale branch でも衝突を優先報告） ---
ADR_AC1A="$ADR_TMP/ac1a"
adr_init_repo "$ADR_AC1A"
ADR_AC1A_UPSTREAM="$ADR_TMP/ac1a-upstream"
git clone -q "$ADR_TMP/ac1a.bare.git" "$ADR_AC1A_UPSTREAM"
ff_git_fixture_init "$ADR_AC1A_UPSTREAM" "upstream" "up@example.com"
git -C "$ADR_AC1A" checkout -q -b feature/adr-094-local
cat <<'EOF' > "$ADR_AC1A/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.1.0"
---

# DECISIONS

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-093 | Initial Base |
| ADR-094 | Local Proposal |

## ADR-093: Initial Base

Baseline decision.

## ADR-094: Local Proposal

Added locally.
EOF
cat <<'EOF' > "$ADR_AC1A/scripts/helper.sh"
#!/usr/bin/env bash
# Refs ADR-094
echo local
EOF
adr_stage_with_claim "$ADR_AC1A"

# 先行して別 PR が origin/develop に ADR-094 をマージ
cat <<'EOF' > "$ADR_AC1A_UPSTREAM/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.1.0"
---

# DECISIONS

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-093 | Initial Base |
| ADR-094 | Upstream Decision |

## ADR-093: Initial Base

Baseline decision.

## ADR-094: Upstream Decision

Merged upstream first.
EOF
git -C "$ADR_AC1A_UPSTREAM" add -A
git -C "$ADR_AC1A_UPSTREAM" commit -q -m "merge ADR-094 on develop"
git -C "$ADR_AC1A_UPSTREAM" push -q origin develop

git -C "$ADR_AC1A" config diff.noprefix true
ac1a_rc=0
ac1a_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE=ok FAKE_CLAIM_GH_LIST_FILE="$EMPTY_PR_LIST" "$CLAIM_VALIDATOR" --root "$ADR_AC1A" 2>&1)" || ac1a_rc=$?
if [[ "$ac1a_rc" -eq 1 && "$ac1a_out" != *"FF_STALE_BASE="* && "$ac1a_out" == *"ADR-094"* && "$ac1a_out" == *"origin/develop"* && "$ac1a_out" == *"Upstream Decision"* && "$ac1a_out" == *"次の空き番号: ADR-095"* && "$ac1a_out" == *"docs/06-reference/DECISIONS.md:13:"* && "$ac1a_out" == *"docs/06-reference/DECISIONS.md:19:"* && "$ac1a_out" == *"scripts/helper.sh:2:"* ]]; then
  ok "AC 1a: origin/develop 先行衝突で rc=1・相手見出し・次空き ADR-095・PR 差分参照(file:line)を名指し"
else
  bad "AC 1a: origin/develop 先行衝突の検出または診断が不十分 (rc=${ac1a_rc})"
  printf '%s\n' "$ac1a_out" | sed 's/^/    | /' >&2
fi

# --- AC 1b: origin/develop が 094/095 を持ち、PR が table 行のみを重複追加 -> 次空き ADR-096 ---
ADR_AC1B="$ADR_TMP/ac1b"
adr_init_repo "$ADR_AC1B"
cat <<'EOF' > "$ADR_AC1B/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.1.0"
---

# DECISIONS

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-093 | Initial Base |
| ADR-094 | Upstream Four |
| ADR-095 | Upstream Five |

## ADR-093: Initial Base

Baseline decision.

## ADR-094: Upstream Four

Four.

## ADR-095: Upstream Five

Five.
EOF
adr_stage_with_claim "$ADR_AC1B"
git -C "$ADR_AC1B" commit -q -m "add 094 and 095 to develop"
git -C "$ADR_AC1B" push -q origin develop
git -C "$ADR_AC1B" checkout -q -b feature/table-dup-094
cat <<'EOF' > "$ADR_AC1B/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.2.0"
---

# DECISIONS

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-093 | Initial Base |
| ADR-094 | Upstream Four |
| ADR-094 | Table-only dup |
| ADR-095 | Upstream Five |

## ADR-093: Initial Base

Baseline decision.

## ADR-094: Upstream Four

Four.

## ADR-095: Upstream Five

Five.
EOF
adr_stage_with_claim "$ADR_AC1B"
ac1b_rc=0
ac1b_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE=ok FAKE_CLAIM_GH_LIST_FILE="$EMPTY_PR_LIST" "$CLAIM_VALIDATOR" --root "$ADR_AC1B" 2>&1)" || ac1b_rc=$?
if [[ "$ac1b_rc" -eq 1 && "$ac1b_out" == *"衝突: ADR-094"* && "$ac1b_out" == *"Upstream Four"* && "$ac1b_out" == *"次の空き番号: ADR-096"* && "$ac1b_out" == *"docs/06-reference/DECISIONS.md:"* ]]; then
  ok "AC 1b/1c: 決定ログ表行のみの追加衝突と次空き ADR-096・見出し優先ラベルを検出"
else
  bad "AC 1b/1c: 決定ログ表行のみ追加または次空き ADR-096 の検出に失敗 (rc=${ac1b_rc})"
  printf '%s\n' "$ac1b_out" | sed 's/^/    | /' >&2
fi

# --- AC 2a: open PR（同一 repo + 同ブランチ名 fork PR の両方）との衝突検出 ---
ADR_AC2="$ADR_TMP/ac2"
adr_init_repo "$ADR_AC2"
git -C "$ADR_AC2" checkout -q -b feature/shared-name
cat <<'EOF' > "$ADR_AC2/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.1.0"
---

# DECISIONS

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-093 | Initial Base |
| ADR-094 | My Proposal |
| ADR-095 | Fork Collision |

## ADR-093: Initial Base

Baseline decision.

## ADR-094: My Proposal

Proposed.

## ADR-095: Fork Collision

Fork collides here.
EOF
cat <<'EOF' > "$ADR_AC2/scripts/helper.sh"
#!/usr/bin/env bash
# Uses ADR-094 and ADR-095
echo ac2
EOF
adr_stage_with_claim "$ADR_AC2"

ADR_DIFF_DIR="$ADR_TMP/diffs"
mkdir -p "$ADR_DIFF_DIR"
cat <<'EOF' > "$ADR_DIFF_DIR/pr-2810.diff"
diff --git a/docs/06-reference/DECISIONS.md b/docs/06-reference/DECISIONS.md
--- a/docs/06-reference/DECISIONS.md
+++ b/docs/06-reference/DECISIONS.md
@@ -16,0 +17,3 @@
+## ADR-094: Parallel Same Repo PR
+
+Same repo open PR.
EOF
cat <<'EOF' > "$ADR_DIFF_DIR/pr-2811.diff"
diff --git a/docs/06-reference/DECISIONS.md b/docs/06-reference/DECISIONS.md
--- a/docs/06-reference/DECISIONS.md
+++ b/docs/06-reference/DECISIONS.md
@@ -16,0 +17,3 @@
+## ADR-095: Fork PR Same Branch Name
+
+Fork open PR.
EOF
cat <<'EOF' > "$ADR_DIFF_DIR/pr-2809.diff"
diff --git a/docs/06-reference/DECISIONS.md b/docs/06-reference/DECISIONS.md
--- a/docs/06-reference/DECISIONS.md
+++ b/docs/06-reference/DECISIONS.md
@@ -16,0 +17,5 @@
+## ADR-094: Self PR
+
+## ADR-095: Self PR
EOF
OPEN_PR_LIST="$ADR_TMP/open-prs.json"
cat <<'EOF' > "$OPEN_PR_LIST"
[
  {"number": 2809, "title": "Self PR", "headRefName": "feature/shared-name", "headRefOid": "0000000000000000000000000000000000000000", "isCrossRepository": false, "files": [{"path": "docs/06-reference/DECISIONS.md"}]},
  {"number": 2810, "title": "Parallel PR", "headRefName": "feature/other", "headRefOid": "1111111111111111111111111111111111111111", "isCrossRepository": false, "files": [{"path": "docs/06-reference/DECISIONS.md"}]},
  {"number": 2811, "title": "Fork PR", "headRefName": "feature/shared-name", "headRefOid": "2222222222222222222222222222222222222222", "isCrossRepository": true, "files": [{"path": "docs/06-reference/DECISIONS.md"}]}
]
EOF

ADR_HASH='#'
ac2a_rc=0
ac2a_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE=ok FAKE_CLAIM_GH_LIST_FILE="$OPEN_PR_LIST" FAKE_CLAIM_GH_DIFF_DIR="$ADR_DIFF_DIR" "$CLAIM_VALIDATOR" --root "$ADR_AC2" 2>&1)" || ac2a_rc=$?
if [[ "$ac2a_rc" -eq 1 && "$ac2a_out" != *"open PR ${ADR_HASH}2809"* && "$ac2a_out" == *"open PR ${ADR_HASH}2810"* && "$ac2a_out" == *"open PR ${ADR_HASH}2811"* && "$ac2a_out" == *"次の空き番号: ADR-096"* && "$ac2a_out" == *"scripts/helper.sh:"* ]]; then
  ok "AC 2a: 同一 repo の並行 open PR（2810）と同ブランチ名 fork PR（2811）の両衝突を検出し、自 PR（2809）を除外"
else
  bad "AC 2a: open PR / fork PR 衝突検出または自 PR 除外に失敗 (rc=${ac2a_rc})"
  printf '%s\n' "$ac2a_out" | sed 's/^/    | /' >&2
fi

# --- AC 2b & AC 3: 自 PR のみなら衝突なし -> 従来どおりの出力 & rc=0 ---
ADR_CLEAN="$ADR_TMP/ac3-clean"
adr_init_repo "$ADR_CLEAN"
git -C "$ADR_CLEAN" checkout -q -b feature/clean-adr-094
cat <<'EOF' > "$ADR_CLEAN/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.1.0"
---

# DECISIONS

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-093 | Initial Base |
| ADR-094 | Clean Addition |

## ADR-093: Initial Base

Baseline decision.

## ADR-094: Clean Addition

No collision here.
EOF
adr_stage_with_claim "$ADR_CLEAN"

SELF_ONLY_LIST="$ADR_TMP/self-only-prs.json"
cat <<'EOF' > "$SELF_ONLY_LIST"
[
  {"number": 2809, "title": "Self Clean PR", "headRefName": "feature/clean-adr-094", "headRefOid": "0000000000000000000000000000000000000000", "isCrossRepository": false, "files": [{"path": "docs/06-reference/DECISIONS.md"}]},
  {"number": 2812, "title": "Docs only PR", "headRefName": "docs/other", "headRefOid": "3333333333333333333333333333333333333333", "isCrossRepository": false, "files": [{"path": "README.md"}]}
]
EOF

ac3_rc=0
ac3_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE=ok FAKE_CLAIM_GH_LIST_FILE="$SELF_ONLY_LIST" FAKE_CLAIM_GH_DIFF_DIR="$ADR_DIFF_DIR" "$CLAIM_VALIDATOR" --root "$ADR_CLEAN" 2>&1)" || ac3_rc=$?
if [[ "$ac3_rc" -eq 0 && "$ac3_out" == *"✓ version claim は default branch とマージ対象 index/tree の差分に一致しています"* ]]; then
  ok "AC 2b/3: 自 PR と無関係 PR を除き衝突無しのときは従来の緑出力で rc=0"
else
  bad "AC 2b/3: 衝突無し経路の出力または終了コードが従来と異なる (rc=${ac3_rc})"
  printf '%s\n' "$ac3_out" | sed 's/^/    | /' >&2
fi

# --- AC 3 補足: 既存 ADR 編集 + コードフェンス内の例示見出しは新規 ADR と誤認しない ---
ADR_FENCE="$ADR_TMP/ac3-fence"
adr_init_repo "$ADR_FENCE"
git -C "$ADR_FENCE" checkout -q -b feature/fence-and-edit
cat <<'EOF' > "$ADR_FENCE/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.0.1"
---

# DECISIONS

```markdown
## ADR-099: Template Example

| ADR-099 | Template Example |
```

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-093 | Updated Existing Base |

## ADR-093: Updated Existing Base

Edited wording of ADR-093.
EOF
adr_stage_with_claim "$ADR_FENCE"
ac3f_rc=0
ac3f_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE=fail_list "$CLAIM_VALIDATOR" --root "$ADR_FENCE" 2>&1)" || ac3f_rc=$?
if [[ "$ac3f_rc" -eq 0 && "$ac3f_out" == *"✓ version claim は default branch とマージ対象 index/tree の差分に一致しています"* ]]; then
  ok "AC 3 補足: 既存 ADR 編集とフェンス内例示は新規 ADR に数えず gh 取得失敗にも影響されない"
else
  bad "AC 3 補足: 既存 ADR 編集またはフェンス内見出しが誤検出された (rc=${ac3f_rc})"
  printf '%s\n' "$ac3f_out" | sed 's/^/    | /' >&2
fi

# --- AC 2c: open PR 取得失敗・不正 JSON・差分失敗・gh 欠落は「未確認」で非 0（緑にしない） ---
OTHER_PR_LIST="$ADR_TMP/other-prs.json"
cat <<'EOF' > "$OTHER_PR_LIST"
[
  {"number": 2810, "title": "Parallel PR", "headRefName": "feature/other", "headRefOid": "1111111111111111111111111111111111111111", "isCrossRepository": false, "files": [{"path": "docs/06-reference/DECISIONS.md"}]}
]
EOF

for fail_mode in fail_list bad_json fail_diff; do
  ac2c_rc=0
  ac2c_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE="$fail_mode" FAKE_CLAIM_GH_LIST_FILE="$OTHER_PR_LIST" FAKE_CLAIM_GH_DIFF_DIR="$ADR_DIFF_DIR" "$CLAIM_VALIDATOR" --root "$ADR_CLEAN" 2>&1)" || ac2c_rc=$?
  if [[ "$ac2c_rc" -eq 2 && "$ac2c_out" != *"FF_STALE_BASE="* && "$ac2c_out" == *"未確認"* ]]; then
    ok "AC 2c (${fail_mode}): open PR 取得失敗を「未確認」で rc=2 停止"
  else
    bad "AC 2c (${fail_mode}): open PR 取得失敗を緑にしたか rc=2 / 「未確認」が欠落 (rc=${ac2c_rc})"
    printf '%s\n' "$ac2c_out" | sed 's/^/    | /' >&2
  fi
done

NO_GH_BIN="$ADR_TMP/no-gh-bin"
mkdir -p "$NO_GH_BIN"
for cmd in git jq awk sort sed grep mktemp cat rm tr basename dirname bash sh; do
  cmd_path="$(command -v "$cmd" 2>/dev/null || true)"
  [[ -n "$cmd_path" && -x "$cmd_path" ]] && ln -sfn "$cmd_path" "$NO_GH_BIN/$cmd"
done
ac2c_nogh_rc=0
ac2c_nogh_out="$(PATH="$NO_GH_BIN" "$CLAIM_VALIDATOR" --root "$ADR_CLEAN" 2>&1)" || ac2c_nogh_rc=$?
if [[ "$ac2c_nogh_rc" -eq 2 && "$ac2c_nogh_out" != *"FF_STALE_BASE="* && "$ac2c_nogh_out" == *"未確認"* ]]; then
  ok "AC 2c (gh 不在): open PR 照合不能を「未確認」で rc=2 停止"
else
  bad "AC 2c (gh 不在): gh 不在時に緑になったか rc=2 / 「未確認」が欠落 (rc=${ac2c_nogh_rc})"
  printf '%s\n' "$ac2c_nogh_out" | sed 's/^/    | /' >&2
fi

# --- CI モード（GITHUB_ACTIONS=true）は open PR 照合を省略し origin 基準のみで動く ---
ac3_ci_rc=0
ac3_ci_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE=fail_list GITHUB_ACTIONS=true "$CLAIM_VALIDATOR" --root "$ADR_CLEAN" 2>&1)" || ac3_ci_rc=$?
if [[ "$ac3_ci_rc" -eq 0 ]]; then
  ok "CI モード（GITHUB_ACTIONS=true）は gh open PR 取得を省いて origin/<default> 基準で通る"
else
  bad "CI モードで gh 失敗により赤になった (rc=${ac3_ci_rc})"
  printf '%s\n' "$ac3_ci_out" | sed 's/^/    | /' >&2
fi

# --- .version-claims 未導入 repository でも DECISIONS.md の ADR 衝突は検出して止める ---
ADR_NOCLAIM="$ADR_TMP/no-claim"
adr_init_repo "$ADR_NOCLAIM"
git -C "$ADR_NOCLAIM" rm -q -r .version-claims
git -C "$ADR_NOCLAIM" commit -q -m "remove version-claims contract"
git -C "$ADR_NOCLAIM" push -q origin develop
git -C "$ADR_NOCLAIM" checkout -q -b feature/no-claim-collision
cat <<'EOF' >> "$ADR_NOCLAIM/docs/06-reference/DECISIONS.md"

## ADR-093: Duplicate Without Claim Contract

Collides with ADR-093.
EOF
git -C "$ADR_NOCLAIM" add docs/06-reference/DECISIONS.md
ac_noclaim_rc=0
ac_noclaim_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE=ok FAKE_CLAIM_GH_LIST_FILE="$EMPTY_PR_LIST" "$CLAIM_VALIDATOR" --root "$ADR_NOCLAIM" 2>&1)" || ac_noclaim_rc=$?
if [[ "$ac_noclaim_rc" -eq 1 && "$ac_noclaim_out" == *"衝突: ADR-093"* && "$ac_noclaim_out" == *"次の空き番号: ADR-094"* ]]; then
  ok "version claim 未導入 repository でも DECISIONS.md の ADR 衝突を非 0 で検出"
else
  bad "version claim 未導入 repository で ADR 衝突を見逃した (rc=${ac_noclaim_rc})"
  printf '%s\n' "$ac_noclaim_out" | sed 's/^/    | /' >&2
fi

# --- AC 1d: merge-base に DECISIONS.md が無い（または ADR 0 件）状態から新設した ADR の衝突も検出 ---
ADR_AC1D="$ADR_TMP/ac1d"
adr_init_repo "$ADR_AC1D" empty-decisions
git -C "$ADR_AC1D" checkout -q -b feature/new-decisions-doc
mkdir -p "$ADR_AC1D/docs/06-reference"
cat <<'EOF' > "$ADR_AC1D/docs/06-reference/DECISIONS.md"
---
title: "DECISIONS"
version: "1.0.0"
---

# DECISIONS

## 決定ログ

| ID | 決定 |
| -- | ---- |
| ADR-001 | Local Initial ADR |

## ADR-001: Local Initial ADR

Created from empty merge-base.
EOF
adr_stage_with_claim "$ADR_AC1D"
AC1D_PR_LIST="$ADR_TMP/ac1d-prs.json"
cat <<'EOF' > "$AC1D_PR_LIST"
[
  {"number": 2812, "title": "Bootstrap ADR-001", "headRefName": "feature/bootstrap-adr1", "headRefOid": "3333333333333333333333333333333333333333", "isCrossRepository": false, "files": [{"path": "docs/06-reference/DECISIONS.md"}]}
]
EOF
cat <<'EOF' > "$ADR_DIFF_DIR/pr-2812.diff"
diff --git a/docs/06-reference/DECISIONS.md b/docs/06-reference/DECISIONS.md
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/docs/06-reference/DECISIONS.md
@@ -0,0 +1,6 @@
+## 決定ログ
+| ADR-001 | Parallel Bootstrap |
+## ADR-001: Parallel Bootstrap
EOF
ac1d_rc=0
ac1d_out="$(PATH="$ADR_STUB_BIN:$PATH" FAKE_CLAIM_GH_MODE=ok FAKE_CLAIM_GH_LIST_FILE="$AC1D_PR_LIST" FAKE_CLAIM_GH_DIFF_DIR="$ADR_DIFF_DIR" "$CLAIM_VALIDATOR" --root "$ADR_AC1D" 2>&1)" || ac1d_rc=$?
if [[ "$ac1d_rc" -eq 1 && "$ac1d_out" == *"ADR-001"* && "$ac1d_out" == *"open PR ${ADR_HASH}2812"* && "$ac1d_out" == *"次の空き番号: ADR-002"* && "$ac1d_out" == *"docs/06-reference/DECISIONS.md:12:"* && "$ac1d_out" == *"docs/06-reference/DECISIONS.md:14:"* ]]; then
  ok "AC 1d: merge-base に ADR が 0 件の状態で新設した ADR-001 の衝突と次空き ADR-002 を検出"
else
  bad "AC 1d: 空 merge-base からの新設 ADR 衝突を見逃したか診断が不足 (rc=${ac1d_rc})"
  printf '%s\n' "$ac1d_out" | sed 's/^/    | /' >&2
fi
