# PR を伴わない検証完了 close モード（Issue 番号入力）

`Refs` 運用でマージ後に open のまま残した Issue について post-merge 検証を実環境で実測したとき、または親・統合 Issue の配下にある子 Issue・bundle がすべて完了したことを実測して閉じるときに読む（入力が PR 番号ではなく Issue 番号のみの起動）。通常 PR 経路の [merge-gate.md](merge-gate.md) は使わず、手書きの `sed` 置換によるチェックボックス更新も行わない。

## 前提と対象判定

- 引数は対象の Issue 番号または Issue URL（PR 番号は伴わない）。入力から数値 `ISSUE_NUMBER` を取り出し、URL 指定ならその `owner/repo` が下のコマンドで取得した `TARGET_REPO` と一致することを確かめる（不一致や非数値は停止）
- 下のコマンドで `TARGET_REPO` に対する open な作業 PR の一覧を照会し、当該 Issue を閉じるべき未解決の作業 PR が別途 open になっていないことを確認する（取得失敗や open 作業 PR 残存時は停止）
- 作業用の一時領域 `WORK_DIR` は手順開始時に 1 回だけ排他確保して実値を記録し、後続の呼び出しでもその同じ実値を引き継ぐ（固定名から再構築せず `mktemp` も再実行しない。MSYS では `cygpath -m` 変換に通す）

```bash
TARGET_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || exit 2
# ${ARGUMENTS}（番号または URL）から数値 ISSUE_NUMBER を正規化し、URL 由来なら repo 一致を確認する
gh pr list --repo "$TARGET_REPO" --state open --search "$ISSUE_NUMBER" --limit 20 --json number,title,url || exit 2
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/close-issue-prless-${ISSUE_NUMBER:?}.XXXXXX")" || exit 2
[ -d "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ] || exit 2
if command -v cygpath >/dev/null 2>&1; then WORK_DIR="$(cygpath -m "$WORK_DIR")" || exit 2; fi
```

<!--678d98c84429250b-->
MCP: 取得値: MCP で同じ repo の nameWithOwner と対象 Issue への open PR 一覧を取得。形式: repo JSON と検索上限 20 件の PR JSON 配列。渡し先: TARGET_REPO 固定と ISSUE_NUMBER 正規化・open PR 不在照合。不足時: MCP 必須不足・repo 不一致・open 作業 PR 残存は停止。

## 手順

### 1. 残 AC / 完了条件の実環境 read-back

対象 Issue の本文・`updatedAt`・状態と全ページのコメントを取得する（`head` / `tail` や 100 件上限の切り詰めで切らない）。`state` が既に `CLOSED` の場合は重複更新・重複クローズを行わず、状態と親チェック残存有無を診断して停止する。

```bash
: "${WORK_DIR:?記録済み WORK_DIR の実値を明示}"
[ -d "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ] || exit 2
gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json number,title,body,updatedAt,state > "${WORK_DIR}/issue-${ISSUE_NUMBER}.json" || exit 2
gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}/comments" --paginate --jq '.[] | {id, user: .user.login, body}' > "${WORK_DIR}/comments-${ISSUE_NUMBER}.jsonl" || exit 2
```

<!--567c8eea3ff538b5-->
MCP: 取得値: MCP で対象 Issue の全文 body・updatedAt・state と全ページ comments を取得。形式: repo 固定 Issue JSON と全 page の comment JSON 配列。渡し先: close 条件照合・updatedAt 楽観ロック元値・state 重複判定。不足時: MCP 必須不足・取得失敗・既に CLOSED は停止。

- **`Refs` 運用 Issue の閉じ条件（正本）**: 元の実装 PR マージ時の完了報告コメントに書かれた「post-merge 検証の閉じ条件」と、未チェックの `post-merge:` 行を項目ごとに実環境で実測する
- **親 / 統合 Issue（sub-issues がある場合）**: 配下の子 Issue / bundle 全件の `state` を全ページ取得し、すべて `CLOSED`（完了）であることを実測する（API 失敗または `OPEN` が 1 件でも残っていれば停止）

```bash
gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}/sub_issues" --paginate --jq '.[] | [.number, .state] | @tsv' || exit 2
```

<!--0e0adca74079f5d1-->
MCP: 取得値: MCP で親 Issue 配下の全 sub-issues と各 state を取得。形式: number と state を持つ全 page 配列 JSON。渡し先: 全 sub-issues が CLOSED である完了照合。不足時: MCP 必須不足・API 取得失敗・OPEN 残存は停止。

実測できていない残 AC・未達成項目が 1 件でも残っていれば close せず、未達項目と根拠を報告して停止する。

### 2. `check-issue-body-diff.sh` と楽観ロックによるチェックボックス更新

まず手順 1 で取得した原本を `${WORK_DIR}/issue-${ISSUE_NUMBER}.orig.md` へ保存して変更対象を確認する。

- **変更対象が 0 件のときはスキップする**: 更新すべき未チェックの `- [ ]` 項目が 0 件（全項目が既に `- [x]`、または親 / 統合 Issue 本文に個別チェック行が無い）であることを `.orig.md` で確認した場合は、本文編集・`check-issue-body-diff.sh` 実行・`PATCH` 送信を行わず手順 3 へ進む（変更前と同一のファイルを `check-issue-body-diff.sh` へ渡すと空振り防止で `exit 2` になる）
- **`ff-effort` ブロックの扱い**: PR の新規実装差分を伴わない検証完了 close（post-merge 検証完了 / 親・統合 Issue の完了確認のみ）では既存の `ff-effort` ブロックをそのまま保持し、ブロック不在でも新設しない（追加工数の書き戻しが必要な場合のみ [effort.md](effort.md) に従い同じ `check-issue-body-diff.sh` の許可範囲内で更新する）

更新する未チェック行が 1 件以上ある場合のみ、実測で達成を確認した項目の `- [ ]` → `- [x]` のみを変更した `${WORK_DIR}/issue-${ISSUE_NUMBER}.md` を作成する（ラベル文言の改変や `sed` での直接差し替えは禁止）。[Markdown 文字列パッチ規律](../../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従い、`check-issue-body-diff.sh` で `exit 0` を確かめ、送信直前に `updatedAt` を再取得して手順 1 時点と一致する場合だけ `PATCH` 送信し、送信直後に fresh GET で `body` の一致を read-back する:

```bash
: "${WORK_DIR:?記録済み WORK_DIR の実値を明示}"
[ -d "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ] || exit 2
JUDGE="${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}/scripts/check-issue-body-diff.sh"
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "$JUDGE" "${WORK_DIR}/issue-${ISSUE_NUMBER}.orig.md" "${WORK_DIR}/issue-${ISSUE_NUMBER}.md"
case $? in
  0) : ;;
  1) echo "✗ 許可範囲外。送信しない" >&2; exit 1 ;;
  2) echo "✗ 検査不成立。送信しない" >&2; exit 2 ;;
  *) echo "✗ 上記以外 = 判定器未起動。送信しない" >&2; exit 2 ;;
esac
EXPECTED_UPDATED_AT="$(jq -r .updatedAt "${WORK_DIR}/issue-${ISSUE_NUMBER}.json")" || exit 2
[ -n "$EXPECTED_UPDATED_AT" ] && [ "$EXPECTED_UPDATED_AT" != "null" ] || exit 2
FRESH_UPDATED_AT="$(gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json updatedAt --jq .updatedAt)" || exit 2
[ "$FRESH_UPDATED_AT" = "$EXPECTED_UPDATED_AT" ] || { echo "✗ updatedAt 不一致のため再取得からやり直す" >&2; exit 2; }
gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}" --method PATCH -F "body=@${WORK_DIR}/issue-${ISSUE_NUMBER}.md" || exit 2
gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json body,updatedAt > "${WORK_DIR}/issue-${ISSUE_NUMBER}.after.json" || exit 2
```

<!--9ab0141f00a1765c-->
MCP: 取得値: MCP で対象 Issue の updatedAt・update_issue 結果・送信後 fresh GET（body / updatedAt）を取得。形式: Issue JSON と本文ファイル原文。渡し先: 手順 2 の updatedAt 楽観ロック突合と送信後 read-back 一致照合。不足時: MCP 必須不足・updatedAt 不一致・read-back 不一致は停止。

### 3. marker 付き完了報告コメントの投稿・更新（再実行でも重複させない）

報告内容を `${WORK_DIR}/close-issue-report-${ISSUE_NUMBER}.md` へ書き出す。既存コメント一覧を全ページ取得し、以下の marker がちょうど 1 件存在する場合はそのコメント ID を `PATCH` で上書き更新し、0 件のときだけ新規投稿する。**同一 marker を持つコメントが 2 件以上**既に存在する場合は上書き先を一意に決めず、重複異常として停止する。

- 単一の元実装 PR がある場合: `<!-- close-issue-report:PR-<元PR番号> -->`
- 単一の元 PR が定まらない親 / 統合 Issue や複数 PR に跨がる `Refs` Issue の場合: `<!-- close-issue-report:ISSUE-<Issue番号> -->`

```bash
: "${WORK_DIR:?記録済み WORK_DIR の実値を明示}"
[ -d "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ] || exit 2
REPORT_FILE="${WORK_DIR}/close-issue-report-${ISSUE_NUMBER}.md"
# 既存コメント全ページで同一 marker の件数を数え、0 件=新規投稿 / 1 件=PATCH 上書き / 2 件以上=停止
gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}/comments" --paginate --jq '.[] | [.id, .body] | @tsv' > "${WORK_DIR}/comments-before-post.tsv" || exit 2
if [ -n "${COMMENT_ID:-}" ]; then
  gh api "repos/${TARGET_REPO}/issues/comments/${COMMENT_ID}" --method PATCH -F "body=@${REPORT_FILE}" || exit 2
else
  gh issue comment "$ISSUE_NUMBER" --repo "$TARGET_REPO" --body-file "$REPORT_FILE" || exit 2
fi
```

<!--37c89c222c37854e-->
MCP: 取得値: MCP で対象 Issue の全ページ comments id / body（marker 件数確認）を取得し、update_issue_comment または add_comment_to_issue を実行。形式: comment id と body の全 page 配列 JSON。渡し先: 手順 3 の close-issue-report コメント反映（重複防止・複数件時は停止）。不足時: MCP 必須不足・2 件以上の重複・更新失敗は停止。

完了報告は [report.md](report.md) に準じつつ、PR を伴わない回は見出しを `## 完了報告（Issue #<Issue番号>）`、参照欄を `- 対象 Issue / sub-issues` または元 PR 参照へ読み替え、検証した根拠（実測結果・対象 SHA や sub-issue 一覧）・元の PR または sub-issue 番号・AC 判定結果を明記する。

### 4. Issue クローズ（`completed`）

すべての閉じ条件が満たされ、チェックボックス（該当時）と完了報告の送信が済んだ後に Issue を閉じる。

```bash
gh issue close "$ISSUE_NUMBER" --repo "$TARGET_REPO" --reason completed || exit 2
```

<!--538929fe427b0f42-->
MCP: 取得値: MCP で update_issue を呼び出し state=closed・state_reason=completed と更新後 state を取得。形式: repository・issue_number と返却 JSON。渡し先: 手順 5 の CLOSED 実測照合と手順 6 の親 Issue 更新。不足時: MCP 必須不足・close 失敗は停止。

### 5. クローズ後 `state` の read-back（省略禁止）

手順 4 の close 実行の終了コードだけで完了とみなさず、API から `state` と `stateReason` を再取得して `CLOSED` / `COMPLETED` を実測する。

```bash
gh issue view "$ISSUE_NUMBER" --repo "$TARGET_REPO" --json number,state,stateReason,closedAt || exit 2
```

<!--9327a737cf31a96f-->
MCP: 取得値: MCP で close 後 Issue の number / state / stateReason / closedAt を fresh 取得。形式: state と state_reason を含む単一 Issue JSON。渡し先: 手順 5 の CLOSED 実測確認と完了報告。不足時: MCP 必須不足・state 非 CLOSED は停止。

`CLOSED` でない場合は原因を診断して停止する。

### 6. 親 Issue がある場合のチェック更新

親 Issue の有無を問い合わせる。REST `/parent` の HTTP 404（Not Found）だけは「親 Issue なし」として扱い、401・403・5xx・通信失敗を親不在に倒さず停止する。

```bash
if PARENT_OUT="$(gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}/parent" 2>&1)"; then
  HAS_PARENT=1 # PARENT_OUT の親番号を用いて下の更新へ進む
else
  case "$PARENT_OUT" in
    *"404"*) HAS_PARENT=0 ;; # 親 Issue なし
    *) echo "✗ 親 Issue の照会に失敗したため停止: $PARENT_OUT" >&2; exit 2 ;;
  esac
fi
```

<!--a8109478df408a05-->
MCP: 取得値: MCP で対象 Issue の parent（number / state / body / updatedAt）を取得。形式: 親 Issue JSON（不在時は HTTP 404 のみ親なし）。渡し先: 手順 6 の親 Issue チェックボックス更新と check-issue-body-diff 検証。不足時: 404 以外の通信・権限失敗は停止。

親 Issue が存在し（`HAS_PARENT=1`）、親の本文に本 Issue に対応する未チェック行（`- [ ]`）がある場合は、親 Issue 番号に対して手順 2 と同じ手順（`.orig.md` 保存 → 該当チェック行のみ `[x]` 化 → `check-issue-body-diff.sh` 検証 → 送信直前 `updatedAt` 楽観ロック突合 → `PATCH` 更新 → fresh read-back）で親 Issue を更新する（親 Issue のチェックを `sed` 等で無検査に書き換えてはならない）。親 Issue が存在しないか親 Issue の更新（必要な場合）を完了した後に `rm -rf "${WORK_DIR}"` で一時作業領域を片付ける。
