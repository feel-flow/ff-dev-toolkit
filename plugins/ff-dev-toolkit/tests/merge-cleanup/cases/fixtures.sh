# shellcheck shell=bash
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# bare origin + clone の fixture、トランスクリプトの fixture、mock gh
#
# verify.sh から source される（ok / bad / TMP / TARGET / MOCK / PLUGIN_ROOT / SCRIPT_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2697`）。

# ---- fixture: bare origin + clone --------------------------------------------

git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work"
ff_git_fixture_init "$TMP/work" "merge-cleanup-test" "test@example.com"
cd "$TMP/work"
git config commit.gpgsign false

git switch -q -c develop
echo base > README.md
git add README.md
git commit -qm "init"
git push -qu origin develop

new_branch_with_commit() {
  # $1: branch name / $2: file marker。作成後 develop に戻り、コミット OID を出力する
  git switch -q -c "$1" develop
  echo "$2" > "$2.txt"
  git add "$2.txt"
  git commit -qm "commit on $1"
  git rev-parse HEAD
  git push -qu origin "$1"
  git switch -q develop
}

OID_TARGET="$(new_branch_with_commit 'feature/#10-target' target)"
OID_EXACT="$(new_branch_with_commit 'feature/#1-merged-exact' exact)"
OID_OPEN="$(new_branch_with_commit 'feature/#3-open-reuse' openreuse)"
OID_RELEASE="$(new_branch_with_commit 'release/1.0' release)"

# lease 拒否後の再取得で「期待 OID のまま存在」を再現する branch。
OID_SAME="$(git rev-parse develop)"
git branch 'feature/#15-same-oid' "$OID_SAME"
git push -qu origin 'feature/#15-same-oid'
git branch -q -D 'feature/#15-same-oid'

# Step 4 の削除が失敗し、Step 6 の取り残し掃除が同じ branch を再試行するケース。
# origin へは 6.11 の直前に push する（それ以前の run が取り残しとして拾わないように）。
# mock のフラグはリセットしないので one-shot。同じ PR 番号を 2 回走らせる検証は足せない。
git switch -q -c 'feature/#17-retry-succeeds' develop
echo retry17 > retry17.txt
git add retry17.txt
git commit -qm "commit on feature/#17-retry-succeeds"
OID_RETRY17="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#17-retry-succeeds'

# Step 4 の削除失敗中にリモートが別 OID へ進むケース（15c）。
# origin へは 15c の直前に push する。OID_CHANGED18B は mock git が横から push する。
git switch -q -c 'feature/#18-changed-before-retry' develop
echo changed18 > changed18.txt
git add changed18.txt
git commit -qm "commit on feature/#18-changed-before-retry"
OID_CHANGED18="$(git rev-parse HEAD)"
echo changed18-more > changed18b.txt
git add changed18b.txt
git commit -qm "push that lands while step 4 is failing"
OID_CHANGED18B="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#18-changed-before-retry'

# Step 6 の再試行時点で ref が消えているケース（15d）。
git switch -q -c 'feature/#20-vanished-before-retry' develop
echo vanished20 > vanished20.txt
git add vanished20.txt
git commit -qm "commit on feature/#20-vanished-before-retry"
OID_VANISHED20="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#20-vanished-before-retry'

# run 14（Step 4 が rc=1）で Step 6 が削除に成功する取り残し。対象 PR 以外の成功が
# 対象 PR のサマリーを書き換えないこと・再試行されない対象が failed のまま残ることを見る。
git switch -q -c 'feature/#23-leftover-for-14' develop
echo leftover23 > leftover23.txt
git add leftover23.txt
git commit -qm "commit on feature/#23-leftover-for-14"
OID_LEFTOVER23="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#23-leftover-for-14'

# Step 6 の再試行も失敗するケース（15e）。origin へは 6.14 の直前に push する。
git switch -q -c 'feature/#22-retry-fails' develop
echo retryfail22 > retryfail22.txt
git add retryfail22.txt
git commit -qm "commit on feature/#22-retry-fails"
OID_RETRYFAIL22="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#22-retry-fails'

# 削除反映の fetch --prune が失敗するケース（15f）。origin へは 6.15 の直前に push する。
git switch -q -c 'feature/#21-prune-fails' develop
echo prunefail21 > prunefail21.txt
git add prunefail21.txt
git commit -qm "commit on feature/#21-prune-fails"
OID_PRUNEFAIL21="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#21-prune-fails'

# headRefOid が null で返るケース（6.16）。origin へは 6.16 の直前に push する。
git switch -q -c 'feature/#41-null-oid' develop
echo nulloid41 > nulloid41.txt
git add nulloid41.txt
git commit -qm "commit on feature/#41-null-oid"
OID_NULLOID41="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#41-null-oid'

# 混在ケース（6.17）: gh pr view は null だが、取り残し一覧側の OID は正常。
# Step 6 が (名前, OID) 照合で実際に削除できる構成にする。
git switch -q -c 'feature/#42-null-oid-mixed' develop
echo nulloid42 > nulloid42.txt
git add nulloid42.txt
git commit -qm "commit on feature/#42-null-oid-mixed"
OID_NULLOID42="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#42-null-oid-mixed'

# 混在ケースで lease 拒否になる系（6.18）: 一覧との照合後に別 push が着地する。
# OID_NULLOID43B は mock git が削除 push の最中に横から push する。
git switch -q -c 'feature/#43-null-oid-lease' develop
echo nulloid43 > nulloid43.txt
git add nulloid43.txt
git commit -qm "commit on feature/#43-null-oid-lease"
OID_NULLOID43="$(git rev-parse HEAD)"
echo nulloid43-more > nulloid43b.txt
git add nulloid43b.txt
git commit -qm "push that lands after the leftover match"
OID_NULLOID43B="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#43-null-oid-lease'

# 混在ケースで Step 6 の削除が一般エラーになる系（6.19）。
git switch -q -c 'feature/#44-null-oid-failure' develop
echo nulloid44 > nulloid44.txt
git add nulloid44.txt
git commit -qm "commit on feature/#44-null-oid-failure"
OID_NULLOID44="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#44-null-oid-failure'

# 混在ケースで Step 6 の削除時点に ref が消えている系（6.20）。
git switch -q -c 'feature/#45-null-oid-vanished' develop
echo nulloid45 > nulloid45.txt
git add nulloid45.txt
git commit -qm "commit on feature/#45-null-oid-vanished"
OID_NULLOID45="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#45-null-oid-vanished'

# headRefOid が null で、かつ origin に ref が既に無い系（6.21）。
# origin へは一度も push しない（GitHub の merge 時削除などで消えている状態）。
git switch -q -c 'feature/#46-null-oid-gone' develop
echo nulloid46 > nulloid46.txt
git add nulloid46.txt
git commit -qm "commit on feature/#46-null-oid-gone"
OID_NULLOID46="$(git rev-parse HEAD)"
git switch -q develop
git branch -q -D 'feature/#46-null-oid-gone'

# 名前再利用ケース: マージ済み PR の head OID の後に、さらに push が積まれている
git switch -q -c 'feature/#2-reused' develop
echo reused-merged > reused.txt
git add reused.txt
git commit -qm "merged head of reused"
OID_REUSED_MERGED="$(git rev-parse HEAD)"
echo reused-extra > reused2.txt
git add reused2.txt
git commit -qm "new work pushed after merge"
git push -qu origin 'feature/#2-reused'
git switch -q develop

# クロスペアケース（6.23）: 名前と OID を**別々の**マージ済み PR から借りると
# 一致してしまう構成。origin に残るのは feature/#47-crosspair（現 OID は
# OID_CROSSPAIR_NOW）で、マージ済み一覧には
#   PR A = (feature/#47-crosspair, OID_CROSSPAIR_MERGED)  … 名前は一致するが OID は古い
#   PR B = (feature/#48-crosspair-other, OID_CROSSPAIR_NOW) … OID は一致するが名前が違う
# の 2 件が載る。ペアで照合する現行実装ではどちらとも一致しないが、名前の集合と
# OID の集合を独立に照合する退化では「名前も OID もどれかの head と一致する」ため
# 通ってしまう。feature/#48-crosspair-other は origin へ push しない（OID の供給元
# としてだけ存在させ、削除対象を feature/#47-crosspair 1 本に保つ）。
git switch -q -c 'feature/#47-crosspair' develop
echo crosspair47 > crosspair47.txt
git add crosspair47.txt
git commit -qm "merged head of crosspair"
OID_CROSSPAIR_MERGED="$(git rev-parse HEAD)"
echo crosspair47-extra > crosspair47b.txt
git add crosspair47b.txt
git commit -qm "new work pushed after merge"
OID_CROSSPAIR_NOW="$(git rev-parse HEAD)"
git push -qu origin 'feature/#47-crosspair'
git switch -q develop

# ハードコード保護の検証用（`#1056`）: staging/* はマージ済み + OID 一致でも、
# どんな設定でも削除されない。release/1.0（設定可能な保護）との対比に使う。
OID_STAGING="$(new_branch_with_commit 'staging/keep' stagingkeep)"

# エージェント worktree（`#914`）用の固有コミット。OID を merged list へ載せるため
# ここで作って控え、worktree の組み立ては専用ケースの直前に行う。
make_agent_branch() {
  # $1: branch / $2: marker。コミット OID を出力してブランチをローカルからも消す
  git switch -q -c "$1" develop
  echo "$2" > "$2.txt"
  git add "$2.txt"
  git commit -qm "commit on $1"
  git rev-parse HEAD
  git switch -q develop
  git branch -q -D "$1"
}
OID_AGENT52="$(make_agent_branch 'feature/#52-agent-lock' agent52)"
OID_AGENT53="$(make_agent_branch 'feature/#53-agent-unknown' agent53)"
OID_AGENT54="$(make_agent_branch 'feature/#54-agent-nomatch' agent54)"
OID_AGENT55="$(make_agent_branch 'feature/#55-agent-foreign-lock' agent55)"
OID_AGENT56="$(make_agent_branch 'feature/#56-agent-nolock' agent56)"
OID_AGENT59="$(make_agent_branch 'feature/#59-agent-toctou' agent59)"

# 取り残し系はローカルブランチを消してリモートだけ残す（過去のマージ漏れを再現）
git branch -q -D 'feature/#1-merged-exact' 'feature/#2-reused' 'feature/#3-open-reuse' \
  'release/1.0' 'feature/#47-crosspair' 'staging/keep'

# dirty worktree 付き [gone] ブランチ: リモートを先に消して prune 対象にする
git worktree add -q "$TMP/wt-dirty" 'feature/#10-target' 2>/dev/null || \
  git worktree add -q "$TMP/wt-dirty" 'feature/#10-target'
echo work-in-progress > "$TMP/wt-dirty/wip.txt"

# 未マージの固有コミットを持つ [gone] ブランチ: リモートを手動削除して再現。
# mock の merged list に載せないため、-D エスカレーションのゲートで保護されるべき
git switch -q -c 'feature/#5-unmerged' develop
echo unmerged-work > unmerged.txt
git add unmerged.txt
git commit -qm "unmerged unique commit"
git push -qu origin 'feature/#5-unmerged'
git push -q origin --delete 'feature/#5-unmerged'
git switch -q develop

# ---- トランスクリプト回収の fixture -------------------------------------------

add_clean_gone_worktree() {
  # $1: branch / $2: worktree path
  # develop と同じ HEAD（= git branch -d だけで消せる）の [gone] ブランチと
  # clean な worktree を用意し、-D エスカレーションの経路と独立させる。
  git branch -q "$1" develop
  # hook 導入後も fixture 組み立てが止まらないよう、セットアップ push だけ
  # --no-verify する。cleanup 本体の削除経路は env で抜ける契約を別途検証する。
  git push -q --no-verify -u origin "$1"
  git worktree add -q "$2" "$1"
  git push -q --no-verify origin --delete "$1"
}

transcript_name_of() {
  # $1: 実在するディレクトリ。Claude Code がセッショントランスクリプトに使う
  # 名前（symlink 解決済み絶対パスの英数字以外を '-' に潰したもの）を返す。
  # macOS の $TMPDIR は /var -> /private/var の symlink 配下なので、
  # 解決前のパスから作ると実装と一致しない。
  ( cd "$1" && pwd -P ) | sed 's/[^a-zA-Z0-9]/-/g'
}

make_transcript_dir() {
  # $1: ディレクトリ名 / $2: jsonl に記録する cwd（空なら jsonl を作らない）
  local dir="$FF_MERGE_CLEANUP_PROJECTS_DIR/$1"
  mkdir -p "$dir"
  if [ -n "$2" ]; then
    printf '{"type":"user","cwd":"%s","message":"hello"}\n' "$2" > "$dir/session.jsonl"
  else
    # 本体の 30 日クリーンアップで jsonl だけ消え、subagents/ が残った状態
    mkdir -p "$dir/subagents"
    echo leftover > "$dir/subagents/leftover.txt"
  fi
}

# cwd 一致 → アーカイブされる
add_clean_gone_worktree 'feature/#20-wt-match' "$TMP/wt-20"
NAME_MATCH="$(transcript_name_of "$TMP/wt-20")"
make_transcript_dir "$NAME_MATCH" "$(cd "$TMP/wt-20" && pwd -P)"

# cwd が別プロジェクトを指す → 触らない
add_clean_gone_worktree 'feature/#21-wt-mismatch' "$TMP/wt-21"
NAME_MISMATCH="$(transcript_name_of "$TMP/wt-21")"
make_transcript_dir "$NAME_MISMATCH" "/somewhere/else/project"

# jsonl が無く、名前から worktree 由来と判別できる → アーカイブされる
mkdir -p "$TMP/worktrees"
add_clean_gone_worktree 'feature/#22-wt-nojsonl' "$TMP/worktrees/wt-22"
NAME_NOJSONL="$(transcript_name_of "$TMP/worktrees/wt-22")"
make_transcript_dir "$NAME_NOJSONL" ""

# jsonl はあるが cwd を 1 つも含まない → 触らない。
# プラグインが書く付随データ（skill-injections.jsonl 等）の常態がこれで、
# 「jsonl が 1 つも無い」ケースとは別の経路を通る（grep が一致 0 件で終わる）
add_clean_gone_worktree 'feature/#39-wt-nocwd' "$TMP/wt-39"
NAME_NOCWD="$(transcript_name_of "$TMP/wt-39")"
mkdir -p "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NOCWD/vercel-plugin"
printf '{"timestamp":"t","event":"skill","injectedSkills":[]}\n' \
  > "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NOCWD/vercel-plugin/skill-injections.jsonl"

# jsonl も worktree 由来の手掛かりも無い → 触らない
add_clean_gone_worktree 'feature/#23-wt-opaque' "$TMP/wt-23"
NAME_OPAQUE="$(transcript_name_of "$TMP/wt-23")"
make_transcript_dir "$NAME_OPAQUE" ""

# 削除されない dirty worktree の分は、cwd が一致していても最後まで残ること
NAME_DIRTY="$(transcript_name_of "$TMP/wt-dirty")"
make_transcript_dir "$NAME_DIRTY" "$(cd "$TMP/wt-dirty" && pwd -P)"

# 候補名が projects 外への symlink → 辿らない（パストラバーサル防止）。
# リンク先には「ガードが無ければ確実に回収されてしまう」内容（cwd 一致の jsonl）を
# 置く。ここを空にすると、後段の所有者確認で弾かれるだけの fixture になり、
# ガードを両方外しても緑のままになる。
add_clean_gone_worktree 'feature/#24-wt-symlink' "$TMP/wt-24"
NAME_SYMLINK="$(transcript_name_of "$TMP/wt-24")"
mkdir -p "$TMP/outside-transcripts"
echo keep-me > "$TMP/outside-transcripts/keep.txt"
printf '{"type":"user","cwd":"%s","message":"hello"}\n' "$(cd "$TMP/wt-24" && pwd -P)" \
  > "$TMP/outside-transcripts/session.jsonl"
ln -s "$TMP/outside-transcripts" "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SYMLINK"

# セッションが途中で親リポジトリへ移動した履歴。worktree を指す cwd が 1 つでも
# あれば回収する（全 cwd の一致を要求すると正当なものを取りこぼす）
add_clean_gone_worktree 'feature/#28-wt-multicwd' "$TMP/wt-28"
NAME_MULTICWD="$(transcript_name_of "$TMP/wt-28")"
make_transcript_dir "$NAME_MULTICWD" "$(cd "$TMP/wt-28" && pwd -P)"
printf '{"type":"user","cwd":"%s","message":"moved"}\n' "$(cd "$TMP/work" && pwd -P)" \
  >> "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_MULTICWD/session.jsonl"

# 2 つ目の命名規則（'.' と '_' を保持）だけが存在するケース。$TMPDIR は
# 'tmp.XXXX' を含むので 2 つの規則は必ず別名になり、A 側の名前は存在しない
add_clean_gone_worktree 'feature/#29-wt-variant-b' "$TMP/wt-29"
NAME_VARIANT_B="$( (cd "$TMP/wt-29" && pwd -P) | sed 's/[^a-zA-Z0-9._]/-/g' )"
NAME_VARIANT_A="$(transcript_name_of "$TMP/wt-29")"
if [ "$NAME_VARIANT_B" = "$NAME_VARIANT_A" ]; then
  echo "  ✗ fixture 前提が崩れています（2 つの命名規則が同一）" >&2
  FAIL=$((FAIL + 1))
fi
make_transcript_dir "$NAME_VARIANT_B" "$(cd "$TMP/wt-29" && pwd -P)"

# find が一部の jsonl を走査できないケース。権限bitはrootで無効なので、
# 後段のpath限定stubがこのディレクトリだけfind失敗にする。
add_clean_gone_worktree 'feature/#30-wt-scanerr' "$TMP/wt-30"
NAME_SCANERR="$(transcript_name_of "$TMP/wt-30")"
make_transcript_dir "$NAME_SCANERR" "$(cd "$TMP/wt-30" && pwd -P)"
mkdir -p "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked"
printf '{"type":"user","cwd":"/somewhere/else"}\n' \
  > "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked/hidden.jsonl"

# 同じ「読めない」でも、find 失敗と grep 失敗は別経路になる。
# 片方だけを fixture にすると、もう片方の検出を外しても緑のままになる。
# こちらもpath限定stubでgrep失敗を注入し、uidに依存させない。
add_clean_gone_worktree 'feature/#38-wt-unreadable' "$TMP/wt-38"
NAME_UNREADABLE="$(transcript_name_of "$TMP/wt-38")"
make_transcript_dir "$NAME_UNREADABLE" "$(cd "$TMP/wt-38" && pwd -P)"
printf '{"type":"user","cwd":"/somewhere/else"}\n' \
  > "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE/unreadable.jsonl"

# ---- mock gh ------------------------------------------------------------------

MOCK="$TMP/mock-bin"
mkdir -p "$MOCK"

# 権限bitで読み取り失敗を作るとroot実行時に前提が崩れる。対象pathだけを
# 失敗させ、それ以外は実コマンドへ委譲する。markerはfixtureの発火証拠にする。
REAL_FIND="$(command -v find)"
cat > "$MOCK/find" <<SH
#!/usr/bin/env bash
case "\${1-}" in
*/"$NAME_SCANERR")
  : > "$TMP/mock-find-failed"
  echo "simulated transcript find failure" >&2
  exit 1
  ;;
esac
exec "$REAL_FIND" "\$@"
SH
chmod +x "$MOCK/find"

REAL_GREP="$(command -v grep)"
cat > "$MOCK/grep" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
  */"$NAME_UNREADABLE"/unreadable.jsonl)
    : > "$TMP/mock-grep-failed"
    echo "simulated transcript grep failure" >&2
    exit 2
    ;;
  esac
done
exec "$REAL_GREP" "\$@"
SH
chmod +x "$MOCK/grep"

cat > "$MOCK/pr_view_10.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#10-target",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "test target PR",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_list_merged.json" <<JSON
[
  {"headRefName": "feature/#10-target", "headRefOid": "$OID_TARGET", "isCrossRepository": false},
  {"headRefName": "feature/#1-merged-exact", "headRefOid": "$OID_EXACT", "isCrossRepository": false},
  {"headRefName": "feature/#2-reused", "headRefOid": "$OID_REUSED_MERGED", "isCrossRepository": false},
  {"headRefName": "feature/#3-open-reuse", "headRefOid": "$OID_OPEN", "isCrossRepository": false},
  {"headRefName": "release/1.0", "headRefOid": "$OID_RELEASE", "isCrossRepository": false},
  {"headRefName": "feature/#17-retry-succeeds", "headRefOid": "$OID_RETRY17", "isCrossRepository": false},
  {"headRefName": "feature/#18-changed-before-retry", "headRefOid": "$OID_CHANGED18", "isCrossRepository": false},
  {"headRefName": "feature/#20-vanished-before-retry", "headRefOid": "$OID_VANISHED20", "isCrossRepository": false},
  {"headRefName": "feature/#21-prune-fails", "headRefOid": "$OID_PRUNEFAIL21", "isCrossRepository": false},
  {"headRefName": "feature/#22-retry-fails", "headRefOid": "$OID_RETRYFAIL22", "isCrossRepository": false},
  {"headRefName": "feature/#23-leftover-for-14", "headRefOid": "$OID_LEFTOVER23", "isCrossRepository": false},
  {"headRefName": "feature/#41-null-oid", "headRefOid": null, "isCrossRepository": false},
  {"headRefName": "feature/#42-null-oid-mixed", "headRefOid": "$OID_NULLOID42", "isCrossRepository": false},
  {"headRefName": "feature/#43-null-oid-lease", "headRefOid": "$OID_NULLOID43", "isCrossRepository": false},
  {"headRefName": "feature/#44-null-oid-failure", "headRefOid": "$OID_NULLOID44", "isCrossRepository": false},
  {"headRefName": "feature/#45-null-oid-vanished", "headRefOid": "$OID_NULLOID45", "isCrossRepository": false},
  {"headRefName": "feature/#46-null-oid-gone", "headRefOid": "$OID_NULLOID46", "isCrossRepository": false},
  {"headRefName": "feature/#47-crosspair", "headRefOid": "$OID_CROSSPAIR_MERGED", "isCrossRepository": false},
  {"headRefName": "feature/#48-crosspair-other", "headRefOid": "$OID_CROSSPAIR_NOW", "isCrossRepository": false},
  {"headRefName": "staging/keep", "headRefOid": "$OID_STAGING", "isCrossRepository": false},
  {"headRefName": "feature/#50-null-merged-oid", "headRefOid": null, "isCrossRepository": false},
  {"headRefName": "feature/#52-agent-lock", "headRefOid": "$OID_AGENT52", "isCrossRepository": false},
  {"headRefName": "feature/#53-agent-unknown", "headRefOid": "$OID_AGENT53", "isCrossRepository": false},
  {"headRefName": "feature/#55-agent-foreign-lock", "headRefOid": "$OID_AGENT55", "isCrossRepository": false},
  {"headRefName": "feature/#56-agent-nolock", "headRefOid": "$OID_AGENT56", "isCrossRepository": false},
  {"headRefName": "feature/#59-agent-toctou", "headRefOid": "$OID_AGENT59", "isCrossRepository": false}
]
JSON

cat > "$MOCK/pr_list_open.json" <<JSON
[
  {"headRefName": "feature/#3-open-reuse"}
]
JSON

cat > "$MOCK/pr_view_99.json" <<JSON
{
  "state": "OPEN",
  "headRefName": "feature/#99-open",
  "headRefOid": "0000000000000000000000000000000000000000",
  "baseRefName": "develop",
  "title": "still open PR",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_11.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#10-target",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "dirty base owner guard",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_12.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#12-already-removed",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "already removed remote",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_13.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#2-reused",
  "headRefOid": "$OID_REUSED_MERGED",
  "baseRefName": "develop",
  "title": "remote updated after merge",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_14.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#14-recheck-fails",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "remote re-check failure",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_15.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#15-same-oid",
  "headRefOid": "$OID_SAME",
  "baseRefName": "develop",
  "title": "same oid after lease rejection",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_16.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#16-warning-missing",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "missing ref with stderr warning",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_17.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#17-retry-succeeds",
  "headRefOid": "$OID_RETRY17",
  "baseRefName": "develop",
  "title": "step 4 failure retried by step 6",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_18.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#18-changed-before-retry",
  "headRefOid": "$OID_CHANGED18",
  "baseRefName": "develop",
  "title": "remote advanced while step 4 was failing",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_20.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#20-vanished-before-retry",
  "headRefOid": "$OID_VANISHED20",
  "baseRefName": "develop",
  "title": "ref vanished before the step 6 retry",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_21.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#21-prune-fails",
  "headRefOid": "$OID_PRUNEFAIL21",
  "baseRefName": "develop",
  "title": "post-delete fetch --prune fails",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_22.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#22-retry-fails",
  "headRefOid": "$OID_RETRYFAIL22",
  "baseRefName": "develop",
  "title": "step 6 retry fails as well",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_41.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#41-null-oid",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_42.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#42-null-oid-mixed",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null but the merged list has it",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_43.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#43-null-oid-lease",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null and the leftover deletion is lease-rejected",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_44.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#44-null-oid-failure",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null and the leftover deletion fails outright",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_45.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#45-null-oid-vanished",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null and the ref vanishes before the leftover deletion",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_46.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#46-null-oid-gone",
  "headRefOid": null,
  "baseRefName": "develop",
  "title": "headRefOid is null and the remote ref is already gone",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/gh" <<SH
#!/usr/bin/env bash
args="\$*"
# 46.1 / 46.2: --help と引数なしが PR 番号として解釈されていないことを、ログの文言では
# なく「gh を一度も呼んでいない」で見るための記録。
printf '%s\n' "\$args" >> "$TMP/gh-calls.log"
# 46.5: ガード情報（MERGED 一覧）の取得を失敗させ、fail-closed な縮退を再現する。
# フラグはケースの直前に作り直後に消すので、他の run へは漏れない。
if [ -f "$TMP/ghfail-merged.enabled" ]; then
  case "\$args" in
    *"--state merged"*) echo "simulated gh pr list failure" >&2; exit 1 ;;
  esac
fi
case "\$args" in
  "pr view 10 --json"*)   cat "$MOCK/pr_view_10.json" ;;
  "pr view 11 --json"*)   cat "$MOCK/pr_view_11.json" ;;
  "pr view 12 --json"*)   cat "$MOCK/pr_view_12.json" ;;
  "pr view 13 --json"*)   cat "$MOCK/pr_view_13.json" ;;
  "pr view 14 --json"*)   cat "$MOCK/pr_view_14.json" ;;
  "pr view 15 --json"*)   cat "$MOCK/pr_view_15.json" ;;
  "pr view 16 --json"*)   cat "$MOCK/pr_view_16.json" ;;
  "pr view 17 --json"*)   cat "$MOCK/pr_view_17.json" ;;
  "pr view 18 --json"*)   cat "$MOCK/pr_view_18.json" ;;
  "pr view 20 --json"*)   cat "$MOCK/pr_view_20.json" ;;
  "pr view 21 --json"*)   cat "$MOCK/pr_view_21.json" ;;
  "pr view 22 --json"*)   cat "$MOCK/pr_view_22.json" ;;
  "pr view 41 --json"*)   cat "$MOCK/pr_view_41.json" ;;
  "pr view 42 --json"*)   cat "$MOCK/pr_view_42.json" ;;
  "pr view 43 --json"*)   cat "$MOCK/pr_view_43.json" ;;
  "pr view 44 --json"*)   cat "$MOCK/pr_view_44.json" ;;
  "pr view 45 --json"*)   cat "$MOCK/pr_view_45.json" ;;
  "pr view 46 --json"*)   cat "$MOCK/pr_view_46.json" ;;
  "pr view 60 --json"*)   cat "$MOCK/pr_view_60.json" ;;
  "pr view 61 --json"*)   cat "$MOCK/pr_view_61.json" ;;
  "pr view 62 --json"*)   cat "$MOCK/pr_view_62.json" ;;
  "pr view 63 --json"*)   cat "$MOCK/pr_view_63.json" ;;
  "pr view 64 --json"*)   cat "$MOCK/pr_view_64.json" ;;
  "pr view 65 --json"*)   cat "$MOCK/pr_view_65.json" ;;
  "pr view 99 --json"*)   cat "$MOCK/pr_view_99.json" ;;
  "pr view 90 --json"*)   cat "$MOCK/pr_view_90.json" ;;
  "pr view 91 --json"*)   cat "$MOCK/pr_view_91.json" ;;
  *"--state merged"*)
    # 実物の gh と同じく --limit を尊重する（Issue 835 の照合上限が実際に gh へ渡り、
    # 打ち切りが起きることを検証できるようにするため）
    mock_limit=1000
    mock_prev=""
    for mock_arg in "\$@"; do
      if [ "\$mock_prev" = "--limit" ]; then mock_limit="\$mock_arg"; fi
      mock_prev="\$mock_arg"
    done
    jq ".[0:\${mock_limit}]" "$MOCK/pr_list_merged.json"
    ;;
  *"--state open"*)       cat "$MOCK/pr_list_open.json" ;;
  *) echo "mock gh: unexpected args: \$args" >&2; exit 1 ;;
esac
SH
chmod +x "$MOCK/gh"

REAL_GIT="$(command -v git)"
cat > "$MOCK/git" <<SH
#!/usr/bin/env bash
# 6.6b / 6.6c / 40.x: 削除 push を「実行しなかった」ことを文言ではなく呼び出しで見るための記録
# （公開 ff-dev-toolkit#137）。mock が push を横取りする分岐より前に置き、全 push を残す。
if [ "\${1:-}" = "push" ]; then
  printf '%s\n' "\$*" >> "$TMP/git-push-calls.log"
fi
# 6.6c: 削除前の照合（ls-remote --exit-code）そのものを失敗させる。フラグはケースの
# 直前に作り直後に消すので、他の run へは漏れない。
if [ -f "$TMP/precheck-fail.enabled" ] \
  && [ "\$*" = "ls-remote --exit-code --heads origin refs/heads/feature/#12-already-removed" ]; then
  echo "simulated pre-check failure" >&2
  exit 128
fi
# 6.8: 削除前の照合（--exit-code 付き）は素通しで match にし、push の lease 拒否後の
# 再取得（--exit-code 無し）だけを失敗させる。照合と push の間の競合で再取得へ
# 落ちる経路の再現で、push 自体は ref を消さずに stale info を返す。
if [ "\$*" = "ls-remote --heads origin refs/heads/feature/#14-recheck-fails" ]; then
  echo "simulated remote re-check failure" >&2
  exit 1
fi
if [[ "\$*" == "push --force-with-lease=refs/heads/feature/#14-recheck-fails:"* ]]; then
  echo "simulated stale info after the pre-check matched" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#15-same-oid:* ]]; then
  echo "simulated stale info for same OID" >&2
  exit 1
fi
# 6.10: 削除前の照合では ref が在り（match）、push の瞬間には消えている競合を再現する。
# 実際に消してから stale info を返し、再取得（下の warning 付き空 stdout）へ落とす。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#16-warning-missing:* ]]; then
  SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0 "$REAL_GIT" push -q origin \
    --delete 'feature/#16-warning-missing'
  echo "simulated stale info for missing ref" >&2
  exit 1
fi
# 15f: 削除反映の fetch --prune を失敗させる（Step 3 の 1 回目は通す）。
# 有効化フラグは 6.15 の直前に作り、直後に消すので他 run へ漏れない。
if [ -f "$TMP/prune21.enabled" ] && [ "\$*" = "fetch --prune origin" ]; then
  if [ -f "$TMP/prune21.first" ]; then
    echo "simulated fetch --prune failure" >&2
    exit 1
  fi
  : > "$TMP/prune21.first"
fi
# 15e: Step 4 も Step 6 の再試行も失敗する（リモートは期待 OID のまま残る）。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#22-retry-fails:* ]]; then
  # 出力を一切出さずに失敗する（last_push_error が空になる経路のフォールバック検証）
  exit 1
fi
# 15j: 混在ケースで Step 6 の削除 push が一般エラーで失敗する（stale info ではない）。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#44-null-oid-failure:* ]]; then
  echo "simulated transport failure for the leftover deletion" >&2
  exit 1
fi
# 47: 復旧コマンドの引用。取り残し検証での削除を一般エラーで失敗させる（フラグはケースの直前に作り直後に消す）
if [ -f "$TMP/f25-push-fail.enabled" ] && [[ "\$*" == push\ --force-with-lease=refs/heads/q/f25-e* ]]; then
  echo "simulated transport failure for the quoting case" >&2
  exit 1
fi
# 15k: 混在ケースで、Step 6 の削除 push の時点には ref が消えている。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#45-null-oid-vanished:* ]]; then
  SKIP_SIMPLE_GIT_HOOKS=1 "$REAL_GIT" push -q origin \
    --delete 'feature/#45-null-oid-vanished'
  echo "error: unable to delete 'feature/#45-null-oid-vanished': remote ref does not exist" >&2
  exit 1
fi
# 15i: 混在ケースで Step 6 の削除 push が lease 拒否になる。照合（ls-remote）の後に
# 別の push が着地した状況を再現する。再取得は素通りさせるので rc=3 へ落ちる。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#43-null-oid-lease:* ]]; then
  SKIP_SIMPLE_GIT_HOOKS=1 "$REAL_GIT" push -q --force origin \
    "$OID_NULLOID43B:refs/heads/feature/#43-null-oid-lease"
  echo "stale info: simulated push landed after the leftover match" >&2
  exit 1
fi
# 15c: Step 4 の削除 push が失敗する間に、別の push がリモートへ着地する。
# stale info ではない一般的な失敗なので、再取得を経ずに rc=1 へ落ちる経路も兼ねる。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#18-changed-before-retry:* ]]; then
  SKIP_SIMPLE_GIT_HOOKS=1 "$REAL_GIT" push -q --force origin \
    "$OID_CHANGED18B:refs/heads/feature/#18-changed-before-retry"
  echo "simulated transport failure while another push landed" >&2
  exit 1
fi
# 15d: Step 4 は一般的な失敗で rc=1。Step 6 の再試行時点では ref が消えている
# （Step 6 の ls-remote には映っていたが、削除 push までの間に外部が消した）。
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#20-vanished-before-retry:* ]]; then
  if [ ! -f "$TMP/vanished20.attempted" ]; then
    : > "$TMP/vanished20.attempted"
    echo "simulated transport failure" >&2
    exit 1
  fi
  SKIP_SIMPLE_GIT_HOOKS=1 "$REAL_GIT" push -q origin \
    --delete 'feature/#20-vanished-before-retry'
  echo "error: unable to delete 'feature/#20-vanished-before-retry': remote ref does not exist" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/#17-retry-succeeds:* ]] \
  && [ ! -f "$TMP/retry17.attempted" ]; then
  : > "$TMP/retry17.attempted"
  echo "simulated stale info for first attempt" >&2
  exit 1
fi
if [ "\$*" = "ls-remote --heads origin refs/heads/feature/#16-warning-missing" ]; then
  echo "simulated non-fatal warning" >&2
  FF_REACHED_END=1
  exit 0
fi
# 32.5 系: status の故障注入。ガード側（除外を適用した status。pathspec に :(top) を
# 含む）・報告側（肯定形。:(glob,top) で始まる）・素の status（除外未設定の既定経路）を
# 別フラグに分ける。1 つのフラグで前方一致させると、Step 1 のガード側が先に落ちて
# 報告側の失敗経路へ一度も到達しない。フラグは各ケースの直前に作り直後に消すので、
# 他の run には漏れない。-C 付き（base 所有 worktree 経路）も同じ判定に乗る。
if [ -f "$TMP/statusfail-guard.enabled" ] && [[ "\$*" == *status\ --porcelain\ --\ :\(top\)* ]]; then
  echo "simulated git status failure" >&2
  exit 1
fi
if [ -f "$TMP/statusfail-ignored.enabled" ] && [[ "\$*" == *status\ --porcelain\ --\ :\(glob,top\)* ]]; then
  echo "simulated git status failure (ignored list)" >&2
  exit 1
fi
if [ -f "$TMP/statusfail-plain.enabled" ] && [[ "\$*" == *status\ --porcelain ]]; then
  echo "simulated git status failure (plain)" >&2
  exit 1
fi
# 32.5e: stderr へ何も出さずに失敗する（詳細不明メッセージの分岐を通す）
if [ -f "$TMP/statusfail-silent.enabled" ] && [[ "\$*" == *status\ --porcelain ]]; then
  exit 1
fi
# 32.7d: base 所有 worktree（-C <実パス>）のガード status だけを失敗させる。
# Step 1 は -C "" で呼ぶため \$2 が空になり一致しない（Step 1 を先に落とすと
# Step 3 の失敗経路へ一度も到達しない）。
if [ -f "$TMP/statusfail-basewt.enabled" ] && [[ "\$*" == -C\ /* ]] \
  && [[ "\$*" == *status\ --porcelain\ --\ :\(top\)* ]]; then
  echo "simulated git status failure (base worktree)" >&2
  exit 1
fi
# 32.7c: base 所有 worktree の status を「exit 0 + stderr に警告」にする。
# 走査が不完全なまま通ってしまう形（Permission denied 等）の再現。
if [ -f "$TMP/statuswarn-basewt.enabled" ] && [[ "\$*" == -C\ * ]] \
  && [[ "\$*" == *status\ --porcelain* ]]; then
  echo "warning: could not open directory 'videos/': Permission denied" >&2
  exec "$REAL_GIT" "\$@"
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$MOCK/git"

REAL_TAR="$(command -v tar)"
cat > "$MOCK/tar" <<SH
#!/usr/bin/env bash
if [ -n "\${MOCK_TAR_FAIL:-}" ] && [ "\$1" = "-czf" ]; then
  # 中途半端な成果物を残して失敗する状況を再現する（-czf の次が出力先）
  : > "\$2" 2>/dev/null || true
  echo "simulated tar failure" >&2
  exit 1
fi
if [ -n "\${MOCK_TAR_APPEND:-}" ] && [ "\$1" = "-czf" ]; then
  # アーカイブを作った直後に、生きたセッションが元へ書き足した状況を再現する
  # （引数は -czf <出力> -C <projects> ./<名前>）
  "$REAL_TAR" "\$@" || exit \$?
  printf '%s\n' '{"appended":true}' >> "\$4/\$5/session.jsonl" 2>/dev/null || true
  FF_REACHED_END=1
  exit 0
fi
if [ -n "\${MOCK_TAR_CORRUPT:-}" ] && [ "\$1" = "-czf" ]; then
  # 成功を名乗りながら読めない成果物を残す。終了コードだけを信じると、
  # 中身が失われたまま元ディレクトリが消える
  : > "\$2" 2>/dev/null || true
  FF_REACHED_END=1
  exit 0
fi
exec "$REAL_TAR" "\$@"
SH
chmod +x "$MOCK/tar"

REAL_DATE="$(command -v date)"
cat > "$MOCK/date" <<SH
#!/usr/bin/env bash
if [ -n "\${MOCK_FIXED_STAMP:-}" ] && [ "\$1" = "+%Y%m%d-%H%M%S" ]; then
  # アーカイブ名の衝突を再現するため、タイムスタンプを固定する
  printf '%s\n' "\$MOCK_FIXED_STAMP"
  FF_REACHED_END=1
  exit 0
fi
exec "$REAL_DATE" "\$@"
SH
chmod +x "$MOCK/date"

REAL_DU="$(command -v du)"
cat > "$MOCK/du" <<SH
#!/usr/bin/env bash
if [ -n "\${MOCK_DU_FAIL:-}" ]; then
  echo "simulated du failure" >&2
  exit 1
fi
exec "$REAL_DU" "\$@"
SH
chmod +x "$MOCK/du"

# 43.6 (TOCTOU): エージェント worktree の使い捨てパス除去（rm -rf .../wt-59/.review-results）の
# 直後に、生きたセッションが新しいファイルを書き込んだ状況を再現する。除去は実際に行い、
# その worktree へ landed-later.txt を落とす。force なしの `git worktree remove` は
# この新ファイルを理由に拒否するはず（--force に退行すると巻き込んで消える）。
REAL_RM="$(command -v rm)"
cat > "$MOCK/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
  */wt-59/.review-results)
    "$REAL_RM" "\$@" || exit \$?
    echo landed > "\${arg%/.review-results}/landed-later.txt"
    : > "$TMP/mock-rm-toctou-fired"
    exit 0
    ;;
  esac
done
exec "$REAL_RM" "\$@"
SH
chmod +x "$MOCK/rm"

# suite-cases-end: fixtures.sh
