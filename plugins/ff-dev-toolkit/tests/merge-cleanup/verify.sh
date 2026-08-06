#!/usr/bin/env bash
#
# merge-cleanup.sh の破壊的経路の回帰テスト。
#
# 一時 git リポジトリ（bare origin + clone）と mock gh で以下を検証する:
#   1. 対象 PR のリモートブランチが削除される（OID 一致）
#   2. 取り残し: (名前, OID) 一致のマージ済みブランチは削除される
#   3. 取り残し: 名前一致でも OID 不一致（マージ後 push あり）は削除されない
#   4. 取り残し: open PR の head として再利用中は削除されない
#   5. 取り残し: 保護ブランチ（release/*）は照合一致でも削除されない
#   6. dirty worktree 付き [gone] ブランチは保護され、終了コードが 2（PARTIAL）になる
#   7. 未マージの固有コミットを持つ [gone] ブランチ（手動リモート削除由来）は -D されない
#   8. 対象 PR が MERGED でない場合、破壊的処理の前に exit 1 で中断する
#   9. base を保持する別 worktree が dirty なら変更せず exit 1 で中断する
#  10. base を保持する別 worktree が clean なら、worktree と ignored file を残したまま
#      detached へ退避し、呼び出し元が最新 base ブランチへ復帰する
#  11. 対象 PR のリモートブランチが既に無い場合は、lease 拒否と誤判定しない
#  12. 対象 PR のリモートブランチが別 OID で存在する場合は、lease 拒否として保護する
#  13. lease 拒否後の ref 再取得に失敗した場合は fail-closed で停止する
#  14. lease 拒否後の ref が期待 OID のままなら、原因不明として fail-closed で停止する
#  15. ref 再取得が成功し stderr に警告だけ出ても、空の stdout を存在と誤判定しない
#  16. 削除した worktree のトランスクリプトを、cwd 照合のうえ tar.gz へ回収する
#  17. cwd がこの worktree を指さないものは、名前が一致しても触らない
#  18. cwd を記録した jsonl が無いものは、名前が worktree 由来でも回収しない
#  19. ディレクトリを辿れない場合、読めた分だけで一致と判定せず保護する
#  19b. ファイル単位で読めない場合も同様に保護する（find は成功し grep が失敗する経路）
#  19c. jsonl はあるが cwd を含まない場合は、走査エラーと区別してスキップ扱いにする
#  20. projects 外への symlink は辿らない（リンク先には cwd 一致の中身を置いて検証）
#  21. worktree 外の cwd を併せ持つ履歴も、worktree を指す cwd があれば回収する
#  22. 2 つ目の命名規則（'.'/'_' 保持）のディレクトリも候補に入る
#  23. 保護したものは失敗（PARTIAL）と分けて列挙する
#  24. 無効化の環境変数を尊重し、不正値は黙って無効化せず PARTIAL で報告する
#  25. アーカイブに失敗したら元ディレクトリは残し、書きかけの成果物は残さない
#  26. tar が exit 0 でも中身を検証できなければ元ディレクトリを消さない
#  27. 同名のアーカイブが既にある場合、上書きせず別名で作る（リンク切れの symlink も含む）
#  27b. アーカイブ中に元が変更されたら削除しない（追記分の消失を防ぐ）
#  28. アーカイブ先を作れないときは中断し、「対象なし」と矛盾する報告をしない
#  29. CLAUDE_CONFIG_DIR 由来の既定パスでも回収できる（実ユーザーが通る経路）
#  30. 削除しなかった dirty worktree のトランスクリプトには触れない
#
# あわせて静的検査として、bash 3.2 で変数名にマルチバイト文字が取り込まれる書き方
# （"$VAR（..." のような直付け）が merge-cleanup.sh に無いことを確認する。検出器が
# 空振りしていないことを、違反 fixture への適用で毎回実測してから本検査へ進む。
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/scripts/merge-cleanup.sh"

[ -f "$TARGET" ] || { echo "✗ merge-cleanup.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です" >&2; exit 1; }

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

# トランスクリプト回収の格納先を temp へ固定する。全実行の前に export するので、
# どのケースでも実際の ~/.claude/projects には触れない。
export FF_MERGE_CLEANUP_PROJECTS_DIR="$TMP/projects"
export FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$TMP/archives"
mkdir -p "$FF_MERGE_CLEANUP_PROJECTS_DIR"

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- 静的検査: $VAR 直後のマルチバイト文字 -------------------------------------
#
# macOS 標準の bash 3.2 は $VAR の直後に続くマルチバイト文字を変数名の一部として
# 取り込む。日本語メッセージで "$name（...)" と書くと `name（` を参照することになり、
# set -u 下では `unbound variable` で異常終了する。**これが起きるのは失敗を報告
# しようとした瞬間だけ**なので、正常系が緑のあいだは誰も気付かない。
#
# LC_ALL=C では [:print:] も [:space:] も ASCII しか含まないため、
# 「印字可能でも空白でもないバイト」= マルチバイトの先頭バイトを拾える。
mbcs_adjacent_expansions() {
  # $1: 検査するファイル。違反行を出力する（無ければ何も出さない）
  LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]' "$1" || true
}

echo "== 静的検査: マルチバイト直付けの変数展開 =="

# 検出器が本当に検出できるかを、違反 fixture で毎回実測してから本検査へ進む
MBCS_PROBE="$TMP/mbcs-probe.sh"
printf '%s\n' 'echo "失敗しました: $name（原因不明）"' > "$MBCS_PROBE"
if [ -n "$(mbcs_adjacent_expansions "$MBCS_PROBE")" ]; then
  ok "検出器が違反を検出できる（self-test）"
else
  bad "検出器が違反を検出できない — 以降の静的検査は無意味なので信用しないこと"
fi
printf '%s\n' 'echo "失敗しました: ${name}（原因不明）"' > "$MBCS_PROBE"
if [ -z "$(mbcs_adjacent_expansions "$MBCS_PROBE")" ]; then
  ok "検出器が正しい書き方を誤検出しない（self-test）"
else
  bad "検出器が \${VAR} 形式を誤検出する"
fi

MBCS_HITS="$(mbcs_adjacent_expansions "$TARGET")"
if [ -z "$MBCS_HITS" ]; then
  ok "merge-cleanup.sh に \$VAR 直付けのマルチバイト展開が無い"
else
  bad "merge-cleanup.sh に \$VAR 直付けのマルチバイト展開がある（\${VAR} 形式にすること）"
  printf '%s\n' "$MBCS_HITS" | sed 's/^/     /' >&2
fi


# ---- fixture: bare origin + clone --------------------------------------------

git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work"
cd "$TMP/work"
git config user.email "test@example.com"
git config user.name "merge-cleanup-test"
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

# 取り残し系はローカルブランチを消してリモートだけ残す（過去のマージ漏れを再現）
git branch -q -D 'feature/#1-merged-exact' 'feature/#2-reused' 'feature/#3-open-reuse' 'release/1.0'

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
  git push -q -u origin "$1"
  git worktree add -q "$2" "$1"
  git push -q origin --delete "$1"
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

# 一部の jsonl が読めないケース。読めた分だけで「一致」と判定してはいけない
add_clean_gone_worktree 'feature/#30-wt-scanerr' "$TMP/wt-30"
NAME_SCANERR="$(transcript_name_of "$TMP/wt-30")"
make_transcript_dir "$NAME_SCANERR" "$(cd "$TMP/wt-30" && pwd -P)"
mkdir -p "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked"
printf '{"type":"user","cwd":"/somewhere/else"}\n' \
  > "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked/hidden.jsonl"
chmod 000 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked"

# 同じ「読めない」でも、ディレクトリを辿れない場合（find が失敗する）と
# ファイルを読めない場合（find は成功し grep が失敗する）は別経路になる。
# 片方だけを fixture にすると、もう片方の検出を外しても緑のままになる。
add_clean_gone_worktree 'feature/#38-wt-unreadable' "$TMP/wt-38"
NAME_UNREADABLE="$(transcript_name_of "$TMP/wt-38")"
make_transcript_dir "$NAME_UNREADABLE" "$(cd "$TMP/wt-38" && pwd -P)"
printf '{"type":"user","cwd":"/somewhere/else"}\n' \
  > "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE/unreadable.jsonl"
chmod 000 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE/unreadable.jsonl"

# ---- mock gh ------------------------------------------------------------------

MOCK="$TMP/mock-bin"
mkdir -p "$MOCK"

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
  {"headRefName": "release/1.0", "headRefOid": "$OID_RELEASE", "isCrossRepository": false}
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

cat > "$MOCK/gh" <<SH
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  "pr view 10 --json"*)   cat "$MOCK/pr_view_10.json" ;;
  "pr view 11 --json"*)   cat "$MOCK/pr_view_11.json" ;;
  "pr view 12 --json"*)   cat "$MOCK/pr_view_12.json" ;;
  "pr view 13 --json"*)   cat "$MOCK/pr_view_13.json" ;;
  "pr view 14 --json"*)   cat "$MOCK/pr_view_14.json" ;;
  "pr view 15 --json"*)   cat "$MOCK/pr_view_15.json" ;;
  "pr view 16 --json"*)   cat "$MOCK/pr_view_16.json" ;;
  "pr view 99 --json"*)   cat "$MOCK/pr_view_99.json" ;;
  *"--state merged"*)     cat "$MOCK/pr_list_merged.json" ;;
  *"--state open"*)       cat "$MOCK/pr_list_open.json" ;;
  *) echo "mock gh: unexpected args: \$args" >&2; exit 1 ;;
esac
SH
chmod +x "$MOCK/gh"

REAL_GIT="$(command -v git)"
cat > "$MOCK/git" <<SH
#!/usr/bin/env bash
if [ "\$*" = "ls-remote --heads origin refs/heads/feature/#14-recheck-fails" ]; then
  echo "simulated remote re-check failure" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#15-same-oid:* ]]; then
  echo "simulated stale info for same OID" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#16-warning-missing:* ]]; then
  echo "simulated stale info for missing ref" >&2
  exit 1
fi
if [ "\$*" = "ls-remote --heads origin refs/heads/feature/#16-warning-missing" ]; then
  echo "simulated non-fatal warning" >&2
  exit 0
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
  exit 0
fi
if [ -n "\${MOCK_TAR_CORRUPT:-}" ] && [ "\$1" = "-czf" ]; then
  # 成功を名乗りながら読めない成果物を残す。終了コードだけを信じると、
  # 中身が失われたまま元ディレクトリが消える
  : > "\$2" 2>/dev/null || true
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

# ---- 実行 ----------------------------------------------------------------------

echo "== merge-cleanup 破壊的経路テスト =="

remote_has() { git ls-remote --heads origin "refs/heads/$1" | grep . >/dev/null; }

# 呼び出し元を detached worktree に移し、元 clone が develop を保持する競合を再現する。
# ignored file は clean 判定に出ないが、退避のために worktree ごと消してはならない。
BASE_OWNER="$(git rev-parse --show-toplevel)"
CALLER="$TMP/wt-caller"
printf '%s\n' '.cleanup-owner-preserved' >> "$BASE_OWNER/.git/info/exclude"
echo preserve-me > "$BASE_OWNER/.cleanup-owner-preserved"
git worktree add -q --detach "$CALLER" develop
cd "$CALLER"

# 未マージ PR: 破壊的処理の前に exit 1 で中断し、リモートに手を付けないこと
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 99 > "$TMP/run-99.log" 2>&1
EXIT_99=$?
set -e
if [ "$EXIT_99" -eq 1 ] && remote_has 'feature/#1-merged-exact'; then
  ok "未マージ PR は破壊的処理前に exit 1 で中断"
else
  bad "未マージ PR の中断が期待どおりでない (exit=$EXIT_99)"
fi

# dirty な base 所有 worktree は detach せず、リモート削除前に停止すること
echo work-in-progress > "$BASE_OWNER/base-owner-dirty.txt"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 11 > "$TMP/run-11.log" 2>&1
EXIT_11=$?
set -e
if [ "$EXIT_11" -eq 1 ] \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ] \
  && [ -z "$(git branch --show-current)" ] \
  && remote_has 'feature/#10-target' \
  && grep -q "base ブランチの退避と cleanup を中断" "$TMP/run-11.log"; then
  ok "dirty な base 所有 worktree を変更せず、破壊的処理前に exit 1 で中断"
else
  bad "dirty な base 所有 worktree の保護が期待どおりでない (exit=$EXIT_11)"
fi
rm -f "$BASE_OWNER/base-owner-dirty.txt"

set +e
PATH="$MOCK:$PATH" bash "$TARGET" 10 > "$TMP/run.log" 2>&1
EXIT_CODE=$?
set -e

# 1. 対象 PR のリモートブランチが削除される
if remote_has 'feature/#10-target'; then
  bad "対象 PR のリモートブランチが削除されていない (feature/#10-target)"
else
  ok "対象 PR のリモートブランチを削除 (feature/#10-target)"
fi

# 2. (名前, OID) 一致の取り残しは削除される
if remote_has 'feature/#1-merged-exact'; then
  bad "OID 一致の取り残しが削除されていない (feature/#1-merged-exact)"
else
  ok "OID 一致の取り残しを削除 (feature/#1-merged-exact)"
fi

# 3. OID 不一致（マージ後 push あり）は削除されない
if remote_has 'feature/#2-reused'; then
  ok "OID 不一致の再利用ブランチを保護 (feature/#2-reused)"
else
  bad "マージ後 push のあるブランチが誤削除された (feature/#2-reused)"
fi

# 4. open PR の head は削除されない
if remote_has 'feature/#3-open-reuse'; then
  ok "open PR の head を保護 (feature/#3-open-reuse)"
else
  bad "open PR の head が誤削除された (feature/#3-open-reuse)"
fi

# 5. 保護ブランチは削除されない
if remote_has 'release/1.0'; then
  ok "保護ブランチを保護 (release/1.0)"
else
  bad "保護ブランチが誤削除された (release/1.0)"
fi

# 5.5 未マージの固有コミットを持つ [gone] ブランチは -D されない
if git show-ref -q "refs/heads/feature/#5-unmerged"; then
  ok "未マージ [gone] ブランチを保護 (feature/#5-unmerged)"
else
  bad "未マージの固有コミットを持つ [gone] ブランチが誤削除された (feature/#5-unmerged)"
fi

# 6. dirty worktree と対応ブランチが残っている + PARTIAL 終了
if [ -f "$TMP/wt-dirty/wip.txt" ] && git show-ref -q "refs/heads/feature/#10-target"; then
  ok "dirty worktree と対応 [gone] ブランチを保護"
else
  bad "dirty worktree または対応ブランチが失われた"
fi

if [ "$EXIT_CODE" -eq 2 ]; then
  ok "部分失敗（dirty worktree）で終了コード 2 (PARTIAL)"
else
  bad "終了コードが 2 ではない: $EXIT_CODE"
fi

# 6.5 clean な base 所有 worktree は detached へ退避し、呼び出し元が base へ復帰する。
# ignored file と worktree 自体は残す。
if [ "$(git branch --show-current)" = "develop" ] \
  && [ -z "$(git -C "$BASE_OWNER" branch --show-current)" ] \
  && [ -f "$BASE_OWNER/.cleanup-owner-preserved" ] \
  && git worktree list --porcelain | grep -F "worktree $BASE_OWNER" >/dev/null; then
  ok "clean な base 所有 worktree と ignored file を保ち、呼び出し元を develop へ復帰"
else
  bad "clean な base 所有 worktree の退避または呼び出し元の develop 復帰に失敗"
fi

# 6.6 リモート ref が既に無い場合、`stale info` を lease 拒否と誤表示しない。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-12.log" 2>&1
EXIT_12=$?
set -e
if [ "$EXIT_12" -eq 2 ] \
  && grep -q "リモートブランチは既に削除されていました" "$TMP/run-12.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-12.log"; then
  ok "削除済みリモート branch を already removed と判定"
else
  bad "削除済みリモート branch の判定が期待どおりでない (exit=$EXIT_12)"
fi

# 6.7 ref が別 OID で存在する真の競合は、従来どおり lease 拒否で保護する。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 13 > "$TMP/run-13.log" 2>&1
EXIT_13=$?
set -e
if [ "$EXIT_13" -eq 2 ] \
  && remote_has 'feature/#2-reused' \
  && grep -q "マージ後に更新されています" "$TMP/run-13.log"; then
  ok "別 OID で存在するリモート branch を lease 拒否として保護"
else
  bad "別 OID リモート branch の lease 保護が期待どおりでない (exit=$EXIT_13)"
fi

# 6.8 ref 再取得が失敗した場合は「削除済み」と推測せず致命的エラーにする。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 14 > "$TMP/run-14.log" 2>&1
EXIT_14=$?
set -e
if [ "$EXIT_14" -eq 1 ] \
  && grep -q "remote re-check failed" "$TMP/run-14.log" \
  && grep -q "simulated remote re-check failure" "$TMP/run-14.log"; then
  ok "lease 拒否後の ref 再取得失敗を fail-closed で停止"
else
  bad "ref 再取得失敗が fail-closed になっていない (exit=$EXIT_14)"
fi

# 6.9 ref が期待 OID のまま存在する場合は、競合 push と断定せず原因不明で停止する。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 15 > "$TMP/run-15.log" 2>&1
EXIT_15=$?
set -e
if [ "$EXIT_15" -eq 1 ] \
  && remote_has 'feature/#15-same-oid' \
  && grep -q "remote re-check returned the expected OID" "$TMP/run-15.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-15.log"; then
  ok "期待 OID のまま残る ref を原因不明として fail-closed で停止"
else
  bad "期待 OID のまま残る ref の判定が期待どおりでない (exit=$EXIT_15)"
fi

# 6.10 stdout が空なら、成功時の stderr 警告を ref 存在と誤読しない。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 16 > "$TMP/run-16.log" 2>&1
EXIT_16=$?
set -e
if [ "$EXIT_16" -eq 2 ] \
  && grep -q "リモートブランチは既に削除されていました" "$TMP/run-16.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-16.log"; then
  ok "成功時 stderr 警告を ref 存在と誤読せず already removed と判定"
else
  bad "成功時 stderr 警告の分離が期待どおりでない (exit=$EXIT_16)"
fi

# 7. サマリーに失敗項目が列挙されている（状態がサマリーまで届く）
if grep -q "worktree に未コミット変更あり" "$TMP/run.log"; then
  ok "失敗項目がサマリーに列挙される"
else
  bad "失敗項目がサマリーに出ていない"
fi

# ---- トランスクリプト回収（Step 5.5） ------------------------------------------

archive_of() {
  # $1: トランスクリプトディレクトリ名。対応する tar.gz のパスを stdout へ返す。
  # 見つからないのは正常系（保護されたケース）なので、非ゼロで落とさない。
  ls "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$1"-*.tar.gz 2>/dev/null | head -1 || true
}

# 8. cwd 照合が一致したトランスクリプトは中身ごとアーカイブされ、元は消える
ARCHIVE_MATCH="$(archive_of "$NAME_MATCH")"
# grep -q はパイプ入力だと早期終了で tar 側を落とすため、いったんファイルへ落とす
ARCHIVE_LIST="$TMP/archive-list.txt"
: > "$ARCHIVE_LIST"
if [ -n "$ARCHIVE_MATCH" ]; then
  tar -tzf "$ARCHIVE_MATCH" > "$ARCHIVE_LIST" 2>/dev/null || true
fi
if [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_MATCH" ] \
  && [ -n "$ARCHIVE_MATCH" ] \
  && grep -q 'session\.jsonl' "$ARCHIVE_LIST"; then
  ok "cwd 一致のトランスクリプトを中身ごと tar.gz 化して元を削除"
else
  bad "cwd 一致のトランスクリプトのアーカイブが期待どおりでない ($NAME_MATCH)"
fi

# 9. cwd がこの worktree を指さないものは、名前が一致しても触らない。
#    ただし異常ではないので PARTIAL には数えない
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_MISMATCH/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_MISMATCH")" ] \
  && grep -q -- "$NAME_MISMATCH: cwd がこの worktree を指していない" "$TMP/run.log" \
  && ! grep -q "トランスクリプト回収: cwd" "$TMP/run.log"; then
  ok "cwd が別を指すものを保護し、失敗ではなくスキップとして報告"
else
  bad "cwd 不一致のトランスクリプトの保護が期待どおりでない ($NAME_MISMATCH)"
fi

# 10. cwd を記録した jsonl が無いものは、名前がどう見えても回収しない
if [ -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NOJSONL" ] \
  && [ -z "$(archive_of "$NAME_NOJSONL")" ] \
  && grep -q -- "$NAME_NOJSONL: cwd を記録した jsonl が無く所有者を確認できない" "$TMP/run.log"; then
  ok "cwd を記録した jsonl が無いものは、名前が worktree 由来でも回収しない"
else
  bad "jsonl 無しケースの保護が期待どおりでない ($NAME_NOJSONL)"
fi

# 10.5 jsonl はあるが cwd を含まないものも残す。失敗ではなくスキップとして扱う
#      （これを部分失敗に数えると、この系統のディレクトリがあるだけで毎回 PARTIAL になる）
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NOCWD/vercel-plugin/skill-injections.jsonl" ] \
  && [ -z "$(archive_of "$NAME_NOCWD")" ] \
  && grep -q -- "$NAME_NOCWD: cwd を記録した jsonl が無く所有者を確認できない" "$TMP/run.log" \
  && ! grep -q "トランスクリプト回収: jsonl 走査エラーで保護 ($NAME_NOCWD)" "$TMP/run.log"; then
  ok "jsonl はあるが cwd を含まないものを、走査エラーと区別してスキップ扱いにする"
else
  bad "cwd を含まない jsonl の扱いが期待どおりでない ($NAME_NOCWD)"
fi

# 11. 名前からも判別できないものも同じ経路で残る
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_OPAQUE/subagents/leftover.txt" ] \
  && [ -z "$(archive_of "$NAME_OPAQUE")" ]; then
  ok "cwd の証拠が無いものを保護"
else
  bad "照合根拠なしケースの保護が期待どおりでない ($NAME_OPAQUE)"
fi

# 12. projects 外へ解決される symlink は辿らない。
#     リンク先には cwd 一致の jsonl を置いてあるので、ガードが無ければ確実に
#     回収されてしまう構成になっている
#     結果（リンク先が無事）だけを見ると、後段のアーカイブ件数照合が偶然止めた
#     場合も緑になるため、どのガードで止めたのかまで固定する。なお containment
#     ガード単独は、静的なファイル配置では -L に先回りされて到達しないので、
#     ここでは -L が働いたことを直接押さえる。
if [ -f "$TMP/outside-transcripts/keep.txt" ] \
  && [ -f "$TMP/outside-transcripts/session.jsonl" ] \
  && [ -L "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SYMLINK" ] \
  && [ -z "$(archive_of "$NAME_SYMLINK")" ] \
  && grep -q "シンボリックリンクのため辿りません" "$TMP/run.log"; then
  ok "projects 外を指す symlink を辿らず、cwd 一致の中身ごとリンク先を保護"
else
  bad "symlink のパストラバーサル防止が期待どおりでない ($NAME_SYMLINK)"
fi

# 12.5 セッションが親リポジトリへ移動した履歴も回収する（cwd の存在判定）
if [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_MULTICWD" ] \
  && [ -n "$(archive_of "$NAME_MULTICWD")" ]; then
  ok "worktree 外の cwd を併せ持つ履歴も、worktree を指す cwd があれば回収"
else
  bad "複数 cwd を持つトランスクリプトの回収が期待どおりでない ($NAME_MULTICWD)"
fi

# 12.6 2 つ目の命名規則で作られたディレクトリも候補に入る
if [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_VARIANT_B" ] \
  && [ -n "$(archive_of "$NAME_VARIANT_B")" ]; then
  ok "'.'/'_' を保持する命名規則のディレクトリも候補として回収"
else
  bad "2 つ目の命名規則が候補になっていない ($NAME_VARIANT_B)"
fi

# 12.7 一部の jsonl が読めない場合、読めた分だけで一致と判定しない
if [ -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR" ] \
  && [ -z "$(archive_of "$NAME_SCANERR")" ] \
  && grep -q "トランスクリプト回収: jsonl 走査エラーで保護 ($NAME_SCANERR)" "$TMP/run.log"; then
  ok "jsonl を読み切れない場合は、一致する cwd が見えていても保護して PARTIAL"
else
  bad "jsonl 走査エラー時の保護が期待どおりでない ($NAME_SCANERR)"
fi
chmod 755 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_SCANERR/locked" 2>/dev/null || true

# 12.8 ファイル単位で読めない場合も同様に保護する（find は成功し grep が失敗する経路）
if [ -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE" ] \
  && [ -z "$(archive_of "$NAME_UNREADABLE")" ] \
  && grep -q "トランスクリプト回収: jsonl 走査エラーで保護 ($NAME_UNREADABLE)" "$TMP/run.log"; then
  ok "読めない jsonl が混ざっている場合も、見えた分だけで判定せず保護"
else
  bad "読めない jsonl の保護が期待どおりでない ($NAME_UNREADABLE)"
fi
chmod 644 "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_UNREADABLE/unreadable.jsonl" 2>/dev/null || true

# 13. サマリーに回収件数と容量が出る
if grep -qE "アーカイブした worktree トランスクリプト: 3 件 / 元 [1-9][0-9]* KB → アーカイブ [1-9][0-9]* KB" "$TMP/run.log"; then
  ok "サマリーにアーカイブ件数と、元サイズ→アーカイブサイズを表示"
else
  bad "サマリーのアーカイブ件数・容量が期待どおりでない"
fi

# 13.5 保護したものは PARTIAL とは別枠で列挙される
if grep -q "所有者を確認できず残したトランスクリプト:" "$TMP/run.log"; then
  ok "保護したトランスクリプトを失敗項目と分けて列挙"
else
  bad "保護したトランスクリプトの列挙が無い"
fi

# 14. FF_MERGE_CLEANUP_TRANSCRIPTS=off なら worktree を消しても回収しない
add_clean_gone_worktree 'feature/#25-wt-off' "$TMP/wt-25"
NAME_OFF="$(transcript_name_of "$TMP/wt-25")"
make_transcript_dir "$NAME_OFF" "$(cd "$TMP/wt-25" && pwd -P)"
set +e
FF_MERGE_CLEANUP_TRANSCRIPTS=off PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-off.log" 2>&1
set -e
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_OFF/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_OFF")" ] \
  && ! [ -d "$TMP/wt-25" ] \
  && grep -q "無効（FF_MERGE_CLEANUP_TRANSCRIPTS=off）" "$TMP/run-off.log"; then
  ok "off 指定でトランスクリプトを回収せず、サマリーに無効と表示"
else
  bad "off 指定時の挙動が期待どおりでない ($NAME_OFF)"
fi

# 15. 値が不正なら黙って無効化せず fail-loud にする
add_clean_gone_worktree 'feature/#26-wt-bogus' "$TMP/wt-26"
NAME_BOGUS="$(transcript_name_of "$TMP/wt-26")"
make_transcript_dir "$NAME_BOGUS" "$(cd "$TMP/wt-26" && pwd -P)"
set +e
FF_MERGE_CLEANUP_TRANSCRIPTS=bogus PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-bogus.log" 2>&1
EXIT_BOGUS=$?
set -e
if [ "$EXIT_BOGUS" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_BOGUS/session.jsonl" ] \
  && grep -q "トランスクリプト回収: FF_MERGE_CLEANUP_TRANSCRIPTS の値が不正" "$TMP/run-bogus.log"; then
  ok "環境変数の値が不正なら回収せず PARTIAL で報告"
else
  bad "不正な環境変数値の扱いが期待どおりでない (exit=$EXIT_BOGUS)"
fi

# 16. アーカイブに失敗したら元ディレクトリを残し、書きかけの成果物も残さない
add_clean_gone_worktree 'feature/#27-wt-tarfail' "$TMP/wt-27"
NAME_TARFAIL="$(transcript_name_of "$TMP/wt-27")"
make_transcript_dir "$NAME_TARFAIL" "$(cd "$TMP/wt-27" && pwd -P)"
set +e
MOCK_TAR_FAIL=1 PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-tarfail.log" 2>&1
EXIT_TARFAIL=$?
set -e
if [ "$EXIT_TARFAIL" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_TARFAIL/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_TARFAIL")" ] \
  && [ -z "$(ls "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR"/.merge-cleanup-archive-* 2>/dev/null || true)" ] \
  && grep -q "tar が失敗しました。元ディレクトリは残します" "$TMP/run-tarfail.log"; then
  ok "アーカイブ失敗時は元ディレクトリを残し、書きかけの成果物も残さない"
else
  bad "アーカイブ失敗時の挙動が期待どおりでない (exit=$EXIT_TARFAIL)"
fi

# 16.5 tar が成功を名乗っても、読み直せないアーカイブを根拠に元を消さない
add_clean_gone_worktree 'feature/#31-wt-corrupt' "$TMP/wt-31"
NAME_CORRUPT="$(transcript_name_of "$TMP/wt-31")"
make_transcript_dir "$NAME_CORRUPT" "$(cd "$TMP/wt-31" && pwd -P)"
set +e
MOCK_TAR_CORRUPT=1 PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-corrupt.log" 2>&1
EXIT_CORRUPT=$?
set -e
if [ "$EXIT_CORRUPT" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_CORRUPT/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_CORRUPT")" ] \
  && grep -q "元ディレクトリは残します" "$TMP/run-corrupt.log" \
  && ! grep -q "対象のトランスクリプトはありませんでした" "$TMP/run-corrupt.log"; then
  ok "tar が exit 0 でも中身を検証できなければ元ディレクトリを消さない"
else
  bad "壊れたアーカイブの検出が期待どおりでない (exit=$EXIT_CORRUPT)"
fi

# 16.6 既存のアーカイブを黙って上書きしない
add_clean_gone_worktree 'feature/#32-wt-collide' "$TMP/wt-32"
NAME_COLLIDE="$(transcript_name_of "$TMP/wt-32")"
make_transcript_dir "$NAME_COLLIDE" "$(cd "$TMP/wt-32" && pwd -P)"
mkdir -p "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR"
# 実時刻に頼ると「たまたま同じ秒に実行された場合だけ衝突する」テストになり、
# ほぼ常に衝突しないまま緑になる。タイムスタンプを固定して必ず衝突させる。
COLLIDE_STAMP="19990101-000000"
COLLIDE_EXISTING="$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$NAME_COLLIDE-$COLLIDE_STAMP.tar.gz"
echo "precious-existing-archive" > "$COLLIDE_EXISTING"
set +e
MOCK_FIXED_STAMP="$COLLIDE_STAMP" PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-collide.log" 2>&1
set -e
COLLIDE_COUNT="$(ls "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$NAME_COLLIDE"-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
if [ -f "$COLLIDE_EXISTING" ] \
  && grep -q "precious-existing-archive" "$COLLIDE_EXISTING" \
  && [ "$COLLIDE_COUNT" -ge 2 ]; then
  ok "同名のアーカイブが既にある場合、上書きせず別名で作る"
else
  bad "既存アーカイブの上書き回避が期待どおりでない (count=$COLLIDE_COUNT)"
fi

# 16.65 アーカイブ中に元へ書き足されたら、その分を失うので削除しない。
#       件数照合だけでは「既存ファイルへの追記」を検出できない
add_clean_gone_worktree 'feature/#36-wt-append' "$TMP/wt-36"
NAME_APPEND="$(transcript_name_of "$TMP/wt-36")"
make_transcript_dir "$NAME_APPEND" "$(cd "$TMP/wt-36" && pwd -P)"
set +e
MOCK_TAR_APPEND=1 PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-append.log" 2>&1
EXIT_APPEND=$?
set -e
if [ "$EXIT_APPEND" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_APPEND/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_APPEND")" ] \
  && grep -q "アーカイブ中に元が変更されました" "$TMP/run-append.log"; then
  ok "アーカイブ中に元が変更されたら削除しない（追記分の消失を防ぐ）"
else
  bad "アーカイブ中の変更検出が期待どおりでない (exit=$EXIT_APPEND)"
fi

# 16.66 アーカイブ名の位置に壊れた symlink があっても、辿らず上書きもしない
add_clean_gone_worktree 'feature/#37-wt-brokenlink' "$TMP/wt-37"
NAME_BROKEN="$(transcript_name_of "$TMP/wt-37")"
make_transcript_dir "$NAME_BROKEN" "$(cd "$TMP/wt-37" && pwd -P)"
mkdir -p "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR"
BROKEN_STAMP="19990202-000000"
BROKEN_LINK="$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$NAME_BROKEN-$BROKEN_STAMP.tar.gz"
ln -s "$TMP/no-such-target" "$BROKEN_LINK"
set +e
MOCK_FIXED_STAMP="$BROKEN_STAMP" PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-broken.log" 2>&1
set -e
if [ -L "$BROKEN_LINK" ] \
  && [ ! -e "$TMP/no-such-target" ] \
  && [ -f "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR/$NAME_BROKEN-$BROKEN_STAMP-1.tar.gz" ]; then
  ok "壊れた symlink を上書き先とみなさず、別名でアーカイブする"
else
  bad "壊れた symlink の扱いが期待どおりでない ($NAME_BROKEN)"
fi

# 16.7 アーカイブ先を作れないときは Step を中断し、「対象なし」と誤報しない
add_clean_gone_worktree 'feature/#33-wt-nodir' "$TMP/wt-33"
NAME_NODIR="$(transcript_name_of "$TMP/wt-33")"
make_transcript_dir "$NAME_NODIR" "$(cd "$TMP/wt-33" && pwd -P)"
echo "not a directory" > "$TMP/blocking-file"
set +e
FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$TMP/blocking-file/archives" \
  PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-nodir.log" 2>&1
EXIT_NODIR=$?
set -e
if [ "$EXIT_NODIR" -eq 2 ] \
  && [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_NODIR/session.jsonl" ] \
  && grep -q "アーカイブ先を作成できません" "$TMP/run-nodir.log" \
  && grep -q "worktree トランスクリプトの回収: 中断（アーカイブ先を作成できない" "$TMP/run-nodir.log" \
  && ! grep -q "対象のトランスクリプトはありませんでした" "$TMP/run-nodir.log"; then
  ok "アーカイブ先を作れないときは中断し、「対象なし」と矛盾する報告をしない"
else
  bad "アーカイブ先作成失敗時の挙動が期待どおりでない (exit=$EXIT_NODIR)"
fi

# 16.75 容量計測に失敗しても、回収そのものは止めない。
#       pipefail + errexit の下では、代入内のパイプ失敗が Step 全体を落としうる
add_clean_gone_worktree 'feature/#35-wt-dufail' "$TMP/wt-35"
NAME_DUFAIL="$(transcript_name_of "$TMP/wt-35")"
make_transcript_dir "$NAME_DUFAIL" "$(cd "$TMP/wt-35" && pwd -P)"
set +e
MOCK_DU_FAIL=1 PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-dufail.log" 2>&1
set -e
if [ ! -d "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_DUFAIL" ] \
  && [ -n "$(archive_of "$NAME_DUFAIL")" ] \
  && grep -q "容量を計測できませんでした" "$TMP/run-dufail.log" \
  && grep -q "マージ後 Cleanup 結果" "$TMP/run-dufail.log"; then
  ok "容量計測に失敗しても回収を続行し、サマリーまで到達する"
else
  bad "du 失敗時の挙動が期待どおりでない ($NAME_DUFAIL)"
fi

# 16.8 本番の設定パス（CLAUDE_CONFIG_DIR 由来）でも動く。
#      テストが常に FF_* で上書きしていると、実ユーザーが通る唯一の経路が
#      一度も実行されないまま緑になる
add_clean_gone_worktree 'feature/#34-wt-realconf' "$TMP/wt-34"
CONFIG_HOME="$TMP/claude-config"
mkdir -p "$CONFIG_HOME/projects"
NAME_REALCONF="$(transcript_name_of "$TMP/wt-34")"
mkdir -p "$CONFIG_HOME/projects/$NAME_REALCONF"
printf '{"type":"user","cwd":"%s"}\n' "$(cd "$TMP/wt-34" && pwd -P)" \
  > "$CONFIG_HOME/projects/$NAME_REALCONF/session.jsonl"
set +e
env -u FF_MERGE_CLEANUP_PROJECTS_DIR -u FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR \
  CLAUDE_CONFIG_DIR="$CONFIG_HOME" PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-realconf.log" 2>&1
set -e
if [ ! -d "$CONFIG_HOME/projects/$NAME_REALCONF" ] \
  && [ -n "$(ls "$CONFIG_HOME/transcript-archives/$NAME_REALCONF"-*.tar.gz 2>/dev/null || true)" ]; then
  ok "CLAUDE_CONFIG_DIR 由来の既定パス（projects / transcript-archives）で回収できる"
else
  bad "既定の設定パス導出が期待どおりでない ($NAME_REALCONF)"
fi

# 17. dirty worktree は削除されないので、そのトランスクリプトにも触らない
if [ -f "$FF_MERGE_CLEANUP_PROJECTS_DIR/$NAME_DIRTY/session.jsonl" ] \
  && [ -z "$(archive_of "$NAME_DIRTY")" ]; then
  ok "削除されなかった dirty worktree のトランスクリプトには触れない"
else
  bad "dirty worktree のトランスクリプトが処理された"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ merge-cleanup verify: $FAIL 件失敗（詳細: 実行ログ抜粋）" >&2
  tail -40 "$TMP/run.log" >&2
  exit 1
fi
echo "✓ merge-cleanup verify: 全 $PASS 件 pass"
