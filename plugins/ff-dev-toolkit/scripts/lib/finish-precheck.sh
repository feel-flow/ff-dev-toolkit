#!/usr/bin/env bash
# finish.sh の precheck 構成ファイル。入口が bundled / shebang を検査して source する。
# 関数の定義だけを置き、読み込み完了は末尾の sentinel で確認する。bash 3.2 互換。
# pipefail-inherited: finish.sh が set -uo pipefail の下で source する

if [[ "${_finish_precheck_loading:-}" != "1" ]]; then
  echo "finish-precheck.sh は finish.sh precheck から読み込んでください" >&2
  exit 2
fi

# ── precheck ───────────────────────────────────────────────────────────────────
cmd_precheck() {
  local PR_NUMBER="" MERGE_SUBJECT="" MERGE_BODY="" have_subject=0 have_body=0 GATE_RECORD="" have_gate_record=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subject) [[ $# -ge 2 ]] || usage; MERGE_SUBJECT="$2"; have_subject=1; shift 2 ;;
      --body) [[ $# -ge 2 ]] || usage; MERGE_BODY="$2"; have_body=1; shift 2 ;;
      --gate-record) [[ $# -ge 2 ]] || usage; GATE_RECORD="$2"; have_gate_record=1; shift 2 ;;
      -h|--help) usage ;;
      -*) echo "✗ 不明な引数: $1" >&2; usage ;;
      *) [[ -z "$PR_NUMBER" ]] || usage; PR_NUMBER="$1"; shift ;;
    esac
  done
  is_pr_number "$PR_NUMBER" || die_env "PR 番号が数字ではありません: ${PR_NUMBER:-（空）}" "finish.sh precheck <PR番号> の形で渡す"
  [[ "$have_subject" -eq "$have_body" ]] || die_env "--subject と --body は両方渡す（片方だけだと squash メッセージの供給源がリポジトリ設定へ戻る）" "両方を渡して再実行する"
  # 別 checkout の記録は checks の待機より前に読めることを確かめる。読めないまま進むと、待機の
  # 後で検査不成立になるだけでなく、ここで黙って既定の記録へ戻る実装に化けても気付けない
  if [[ "$have_gate_record" -eq 1 ]]; then
    [[ -n "$GATE_RECORD" && -f "$GATE_RECORD" && -r "$GATE_RECORD" ]] \
      || die_env "--gate-record の記録を読めません（存在しない・ファイルでない・読み取り権限が無い）: ${GATE_RECORD:-（空）}" "別 checkout の記録のパス（WSL の clone なら \`git rev-parse --absolute-git-dir\` の下の ff-dev-toolkit/gate-record を //wsl.localhost/<distro>/… で）を確かめて再実行する。既定の記録へは戻さない"
  fi
  need_cmd gh "gh をインストールして gh auth login を済ませる"
  need_cmd jq "jq をインストールする"
  need_repo
  need_bundled check-closing-keywords.sh
  need_bundled check-merge-freshness.sh
  need_bundled effort-report.sh

  local PR_JSON PR_FIELDS="number,state,isDraft,headRefName,headRefOid,baseRefName,title,body,closingIssuesReferences,commits,statusCheckRollup,additions,deletions,files,isCrossRepository"
  PR_JSON="$(gh_pr_view_or_die "$PR_NUMBER" "$PR_FIELDS")" || exit $?
  local pr_state head_ref base_ref head_oid pr_title is_draft is_cross
  pr_state="$(printf '%s' "$PR_JSON" | jq -r '.state // ""')"
  is_draft="$(printf '%s' "$PR_JSON" | jq -r '.isDraft // false')"
  head_ref="$(printf '%s' "$PR_JSON" | jq -r '.headRefName // ""')"
  base_ref="$(printf '%s' "$PR_JSON" | jq -r '.baseRefName // ""')"
  head_oid="$(printf '%s' "$PR_JSON" | jq -r '.headRefOid // ""')"
  pr_title="$(printf '%s' "$PR_JSON" | jq -r '.title // ""')"
  # `//` は false を欠損扱いにするので、null 判定で分ける（同一リポジトリの PR を unknown に落とさない）
  is_cross="$(printf '%s' "$PR_JSON" | jq -r 'if .isCrossRepository == null then "unknown" else (.isCrossRepository | tostring) end')"
  [[ -n "$head_ref" && -n "$base_ref" ]] || die_env "PR #${PR_NUMBER} の head / base ブランチ名を読めません" "gh pr view ${PR_NUMBER} --json headRefName,baseRefName の出力を確かめる"
  printf 'PR_NUMBER=%s\nPR_STATE=%s\nPR_IS_DRAFT=%s\nPR_HEAD_REF=%s\nPR_HEAD_OID=%s\nPR_BASE_REF=%s\nPR_TITLE=%s\n' \
    "$PR_NUMBER" "$pr_state" "$is_draft" "$head_ref" "$head_oid" "$base_ref" "$pr_title"
  [[ "$pr_state" == "OPEN" ]] || echo "⚠️  PR #${PR_NUMBER} は OPEN ではありません（state=${pr_state}）。以降の判定は参考値" >&2

  local TARGET_REPO TARGET_REPO_URL TARGET_REPO_INFO
  TARGET_REPO_INFO="$(gh repo view --json nameWithOwner,url 2>/dev/null)" \
    || die_env "リポジトリ情報（owner/repo・URL）を取得できません" "gh repo view が通る cwd（origin が GitHub のリポジトリ）で再実行する"
  TARGET_REPO="$(printf '%s' "$TARGET_REPO_INFO" | jq -er '.nameWithOwner | select(type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))')" \
    || die_env "リポジトリ名（owner/repo）を解決できません" "gh repo view --json nameWithOwner,url の応答を確かめて再実行する"
  TARGET_REPO_URL="$(printf '%s' "$TARGET_REPO_INFO" | jq -er --arg repo "$TARGET_REPO" '
    .url | select(type == "string")
    | select(test("^https?://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/"))
    | select(sub("^https?://[^/]+/"; "") == $repo)
  ')" || die_env "ホストを含むリポジトリ URL を解決できません。merge コマンドを生成しない" "gh repo view --json nameWithOwner,url が同一リポジトリの完全な URL を返す状態に直して再実行する（GH_HOST から補完しない）"
  echo "TARGET_REPO=${TARGET_REPO}"

  # ── 1. 対象 Issue の検出（PR 本文からの抽出は機械で行う。目視で拾わない） ──
  local PR_BODY REFS_RAW CLOSES_RAW API_CLOSES_TOKENS CLOSES_UNION REFS_ONLY EXTRACT_RC
  PR_BODY="$(printf '%s' "$PR_JSON" | jq -r '.body // ""')"
  # 拾う綴りは Ref / Refs のみ（大文字小文字は問わない。コロンが続く形も可）。`関連 #N` や
  # 裸の `#N` は拾わない。awk の現在行を $(0) と書くのは、裸のドル記号 + 0 が skill 読み込み時の
  # 引数展開で PR 番号へ置換された実測（本文から定数文字列に化けて抽出 0 件で素通り）の名残で、
  # script 側でも同じ形を保つ（awk では $ は演算子なので $(0) は現在行と完全に同義）。
  REFS_RAW="$(set -o pipefail
    printf '%s\n' "${PR_BODY}" | awk '
      {
        line = $(0)
        while (match(line, /(^|[^A-Za-z])[Rr][Ee][Ff][Ss]?[ \t:]*([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?#[0-9]+/)) {
          token = substr(line, RSTART, RLENGTH)
          sub(/^([^A-Za-z])?[Rr][Ee][Ff][Ss]?[ \t:]*/, "", token)
          print token
          line = substr(line, RSTART + RLENGTH)
        }
      }' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || die_env "Refs 参照の抽出に失敗（awk rc=${EXTRACT_RC}）" "awk と sort が PATH に在ることを確かめて再実行する"
  # 本文からの closing keyword 抽出。拾う綴りは GitHub の closing keyword 9 語（大文字小文字は
  # 問わない。コロンが続く形も可）。語中一致（hotfix の fix、enclose の close、auto_fix の fix）は
  # (^|[^a-z0-9_]) で除外する。Refs / 関連 / 裸の #N は拾わない。
  CLOSES_RAW="$(set -o pipefail
    LC_ALL=C
    printf '%s\n' "${PR_BODY}" | awk '
      {
        line = tolower($(0))
        while (match(line, /(^|[^a-z0-9_])(closed|closes|close|fixed|fixes|fix|resolved|resolves|resolve)[ \t:]*([a-z0-9._-]+\/[a-z0-9._-]+)?#[0-9]+/)) {
          token = substr(line, RSTART, RLENGTH)
          sub(/^([^a-z0-9_])?(closed|closes|close|fixed|fixes|fix|resolved|resolves|resolve)[ \t:]*/, "", token)
          print token
          line = substr(line, RSTART + RLENGTH)
        }
      }' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || die_env "closing keyword 参照の抽出に失敗（awk rc=${EXTRACT_RC}）" "awk と sort が PATH に在ることを確かめて再実行する"
  # API 由来を owner/repo#N に正規化する。空配列でも jq は 0 件で成功する。
  API_CLOSES_TOKENS="$(printf '%s' "$PR_JSON" | jq -r '
    (.closingIssuesReferences // [])[]
    | (.url | sub("https://github.com/"; "") | sub("/issues/"; "#"))
  ')" || die_env "closingIssuesReferences を正規化できません" "gh pr view ${PR_NUMBER} --json closingIssuesReferences の出力を確かめる"
  # 裸の #N を現在のリポジトリで修飾し、API 由来と本文由来を 1 件に畳む。
  # 集合キーは小文字化して畳む（GitHub の owner/repo は大小を区別しない）。
  CLOSES_UNION="$(set -o pipefail
    LC_ALL=C
    printf '%s\n' "${API_CLOSES_TOKENS}" "${CLOSES_RAW}" \
    | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print token
        }
      ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || die_env "Closes 和集合の正規化に失敗（awk rc=${EXTRACT_RC}）" "awk と sort が PATH に在ることを確かめて再実行する"
  # Refs のうち Closes 和集合に含まれないもの（同じ Issue を二重に照合しない）。
  # closing 集合は -v に載せない（awk -v は改行を保持しない実装がある）。C 行を先に流す。
  REFS_ONLY="$(set -o pipefail
    LC_ALL=C
    {
      printf '%s\n' "${CLOSES_UNION}" | awk 'NF{print "C\t" $(0)}'
      printf '%s\n' "${REFS_RAW}" | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print "R\t" token
        }
      '
    } | awk -F'\t' '
      $1 == "C" { seen[$2] = 1; next }
      $1 == "R" && !($2 in seen) { print $2 }
    ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || die_env "Refs 差集合の正規化に失敗（awk rc=${EXTRACT_RC}）" "awk と sort が PATH に在ることを確かめて再実行する"

  local tok
  while IFS= read -r tok; do [[ -n "$tok" ]] && printf 'CLOSES=%s\n' "$tok"; done <<<"$CLOSES_UNION"
  while IFS= read -r tok; do [[ -n "$tok" ]] && printf 'REFS=%s\n' "$tok"; done <<<"$REFS_ONLY"
  local api_close_count body_close_count auto_unreliable=0
  api_close_count="$(printf '%s\n' "${API_CLOSES_TOKENS}" | awk 'NF{c++} END{print c+0}')"
  body_close_count="$(printf '%s\n' "${CLOSES_RAW}" | awk 'NF{c++} END{print c+0}')"
  if [[ "$api_close_count" -eq 0 && "$body_close_count" -gt 0 ]]; then auto_unreliable=1; fi
  echo "AUTO_CLOSE_UNRELIABLE=${auto_unreliable}"
  # 両群とも空なら照合する Issue が無い。checks の待機・鮮度照合・merge コマンド生成へ進まない
  # （進めると「対象なし」の PR に ready を出し、貼れば通る merge コマンドまで生成する）
  if [[ -z "$CLOSES_UNION" && -z "$REFS_ONLY" ]]; then
    echo "PRECHECK=no-target"
    echo "ℹ️  参照から検出できる対象 Issue がありません（Closes 群・Refs 群とも空）。checks の待機・鮮度照合・merge コマンド生成は行いません" >&2
    return 0
  fi

  # 関係の分類（鮮度・コミット数）に使う ref を取り込む。失敗しても止めない — 鮮度照合側の
  # --fetch が同じことを試み、取れなければ RELATION=unknown として報告へ出る
  local fetched=1
  git fetch -q origin "+refs/heads/${base_ref}:refs/remotes/origin/${base_ref}" "+refs/heads/${head_ref}:refs/remotes/origin/${head_ref}" >/dev/null 2>&1 \
    || { fetched=0; echo "⚠️  origin から ${base_ref} / ${head_ref} を取り込めませんでした（関係の分類が unknown になりえます）" >&2; }

  # ── 1b. PR のコミット一覧（完了報告の「主要コミット」欄へ貼る。hash を記憶から書かせない） ──
  # 正本は手元の git log（base..head の実コミット。件名は %s）。git の結果を正本にしない回
  # （先端 OID が空 = 右辺が手元 HEAD に化ける / fetch 失敗 = 古い base で余分なコミットを含みうる /
  # git log の失敗・0 件）は API の commits で代替し、git log と同じ新しい順へ並べ替える。
  # 出所は PR_COMMITS_SOURCE で名指しし、理由は stderr へ出す（空のまま黙って通さない）
  local pr_commits_out="" pr_commits_source="git" pr_commits_why="" c_line jq_err
  if [[ -z "$head_oid" ]]; then
    pr_commits_why="PR の先端 OID（headRefOid）が空である"
  elif [[ "$fetched" -ne 1 ]]; then
    pr_commits_why="origin から ${base_ref} / ${head_ref} を取り込めず、手元の base が古い可能性がある"
  elif ! pr_commits_out="$(git log --format='%h %s' "origin/${base_ref}..${head_oid}" 2>/dev/null)"; then
    pr_commits_why="git log origin/${base_ref}..${head_oid} を手元で解決できない"
  elif [[ -z "$pr_commits_out" ]]; then
    pr_commits_why="git log origin/${base_ref}..${head_oid} が 0 件である"
  fi
  if [[ -n "$pr_commits_why" ]]; then
    pr_commits_source="api"
    jq_err="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
    pr_commits_out="$(printf '%s' "$PR_JSON" | jq -r '(.commits // []) | reverse | .[] | (.oid[0:7] + " " + .messageHeadline)' 2>"$jq_err")" \
      || { echo "⚠️  API の commits を読めません（jq: $(cat "$jq_err")）" >&2; pr_commits_out=""; }
    rm -f "$jq_err"
    if [[ -n "$pr_commits_out" ]]; then
      echo "⚠️  ${pr_commits_why}ため、PR_COMMITS は API の commits から出します（件数は API の上限で切り詰められうる）" >&2
    else
      pr_commits_source="unavailable"
      echo "⚠️  ${pr_commits_why}うえ、API の commits も空のため PR_COMMITS を出せません" >&2
    fi
  fi
  echo "PR_COMMITS_SOURCE=${pr_commits_source}"
  while IFS= read -r c_line; do [[ -n "$c_line" ]] && printf 'PR_COMMITS=%s\n' "$c_line"; done <<<"$pr_commits_out"

  # ── 2. closing keyword 抵触検査（Refs 群があるときだけ） ──
  local GUARD="$plugin_root/scripts/check-closing-keywords.sh"
  local refs_args=() closes_args=() keyword_gate="none" message_gate="not-required" blocked_reason="" blocked_next=""
  while IFS= read -r tok; do [[ -n "$tok" ]] && refs_args+=(--refs-issue "$tok"); done <<<"$REFS_ONLY"
  while IFS= read -r tok; do [[ -n "$tok" ]] && closes_args+=(--closes-issue "$tok"); done <<<"$CLOSES_UNION"
  if [[ ${#refs_args[@]} -gt 0 ]]; then
    local SURFACE GATE_OUT gate_status expected_commits actual_commits NON_TITLE_CONFLICTS
    SURFACE="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
    # パイプで直結すると上流の失敗が最終段の終了コードに隠れる（jq は部分出力してから死ぬ）。
    # いったん実体化して確定させる。
    printf '%s' "$PR_JSON" | jq -r '
      ("title\t" + .title),
      ((.commits // [])[] | ("commit:" + .oid[0:7] + "\t" + .messageHeadline)),
      ((.commits // [])[] | select(.messageBody != "")
        | "commit-body:" + .oid[0:7] + "\t" + (.messageBody | gsub("\n"; " ")))
    ' >"$SURFACE" || { rm -f "$SURFACE"; die_env "検査面（PR タイトル + コミット）を組み立てられません" "gh pr view ${PR_NUMBER} --json title,commits の出力を確かめる"; }
    # 取得したコミット数がブランチの実コミット数と一致することを確認する
    # （API 側で切り詰められると、落ちた側の `fix: #N` は検査されないまま緑になる）
    actual_commits="$(printf '%s' "$PR_JSON" | jq -r '(.commits // []) | length')"
    expected_commits="$(git rev-list --count "origin/${base_ref}..${head_oid}" 2>/dev/null)" \
      || { rm -f "$SURFACE"; die_env "コミット数を照合できません（origin/${base_ref}..${head_oid} を手元で解決できない）" "git fetch origin ${base_ref} ${head_ref} のうえ再実行する"; }
    [[ "$expected_commits" -eq "$actual_commits" ]] \
      || { rm -f "$SURFACE"; die_env "コミット取得が切り詰められています（期待 ${expected_commits} / 取得 ${actual_commits}）" "PR のコミット数を減らす（squash）か、gh の版を上げてから再実行する"; }
    GATE_OUT="$(mktemp)" || { rm -f "$SURFACE"; die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"; }
    assert_bundled_shebang_lf "${GUARD}"
      FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${GUARD}" --repo "${TARGET_REPO}" "${refs_args[@]}" ${closes_args[@]+"${closes_args[@]}"} <"${SURFACE}" >"${GATE_OUT}"
    gate_status=$?
      rm -f "$SURFACE"
    awk -F'\t' '
      $1 == "INSPECTED" { print "KEYWORD_INSPECTED=" $2; next }
      $1 == "CONFLICT" { print "KEYWORD_CONFLICT=" $2 "\t" $3 "\t" $4; next }
      $1 == "SUGGEST" { print "KEYWORD_SUGGEST=" $2 "\t" $3 "\t" $4; next }
    ' "$GATE_OUT"
    NON_TITLE_CONFLICTS="$(awk -F'\t' '$1 == "CONFLICT" && $2 != "title" { count++ } END { print count + 0 }' "$GATE_OUT")"
    rm -f "$GATE_OUT"
    case "$gate_status" in
      0) keyword_gate="ok" ;;
      1)
        if [[ "$NON_TITLE_CONFLICTS" -eq 0 ]]; then
          keyword_gate="conflict-title"
          blocked_reason="PR タイトルが Refs 運用の Issue を閉じる（改題で消せる抵触）"
          blocked_next="gh pr edit ${PR_NUMBER} --title '<Issue 参照を含まない件名>' で改題してから finish.sh precheck を再実行する"
        else
          # コミットの件名・本文は書き換えられない。--subject / --body の明示（下の 2b）だけが解消手段
          keyword_gate="conflict-commit"
        fi ;;
      *) die_env "closing keyword 抵触検査が成立していません（status=${gate_status}）" "scripts/check-closing-keywords.sh を直接実行して原因を確かめる（抵触なしとして扱わない）" ;;
    esac
    echo "KEYWORD_GATE=${keyword_gate}"
    # 2b. 実際に渡す squash メッセージの検査（これがマージの条件）。Refs 運用では両方明示が既定
    if [[ "$have_subject" -eq 1 ]]; then
      assert_bundled_shebang_lf "${GUARD}"
          printf 'merge-subject\t%s\nmerge-body\t%s\n' "${MERGE_SUBJECT}" "${MERGE_BODY}" \
        | FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${GUARD}" --repo "${TARGET_REPO}" "${refs_args[@]}" ${closes_args[@]+"${closes_args[@]}"} >/dev/null
      gate_status=$?
          case "$gate_status" in
        0) message_gate="ok" ;;
        1) message_gate="conflict"
           [[ -n "$blocked_reason" ]] || { blocked_reason="実際に渡す squash メッセージ（--subject / --body）が Refs 運用の Issue を閉じる"; blocked_next="件名・本文から Issue 参照を外して finish.sh precheck を再実行する"; } ;;
        *) die_env "squash メッセージの抵触検査が成立していません（status=${gate_status}）" "scripts/check-closing-keywords.sh を直接実行して原因を確かめる" ;;
      esac
    else
      message_gate="required"
      [[ -n "$blocked_reason" ]] || { blocked_reason="Refs 運用の Issue があるのに --subject / --body が無い（squash メッセージの供給源がリポジトリ設定へ戻り、コミットの fix: #N で閉じうる）"; blocked_next="finish.sh precheck ${PR_NUMBER} --subject '<件名>' --body '<本文>' で実際に渡す文字列を検査する"; }
    fi
  else
    echo "KEYWORD_GATE=none"
  fi
  echo "MERGE_MESSAGE_GATE=${message_gate}"

  # ── 3. 工数の実測（Closes 群の同一リポジトリ Issue） ──
  local change_class repo_l
  change_class="$(printf '%s' "$PR_JSON" | jq -r 'if (((.files // []) | length) > 0 and ([(.files // [])[].path | test("[.]md$")] | all)) then "docs-only" elif ((.additions // 0) + (.deletions // 0)) <= 10 then "small" else "other" end')"
  repo_l="$(printf '%s' "$TARGET_REPO" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    case "$tok" in
      "${repo_l}#"*)
        local n="${tok#*#}"
        assert_bundled_shebang_lf "$plugin_root/scripts/effort-report.sh"
        FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "$plugin_root/scripts/effort-report.sh" --issue-metrics "$n" --repo-dir "$repo_root" 2>/dev/null \
          | awk -v n="$n" -F'=' 'NF >= 2 { key = $1; sub(/^[^=]*=/, ""); print "EFFORT_" n "_" key "=" $0 }' \
          || printf 'EFFORT_%s_%s=(unmeasured)\n' "$n" wallclock_actual_h "$n" instruction_bytes "$n" review_rounds "$n" gate_minutes
        echo "EFFORT_${n}_change_class=${change_class}" ;;
      *) echo "EFFORT_SKIPPED=${tok}（別リポジトリの Issue。記録は作業中のリポジトリの行だけを読む）" ;;
    esac
  done <<<"$CLOSES_UNION"

  # ── 4. checks の有無で分岐する（待つか、ローカルゲートを根拠にするか） ──
  # PR トリガーの CI を持たないリポジトリでは `gh pr checks --watch` が `no checks reported` で
  # 即終了する。これを CI 通過と早合点しない。既定は PR トリガーの CI がある形で、checks の
  # 完了と成功がマージの根拠になる。取得失敗は「checks 無し」へ倒さず検査不成立。
  local rollup_count checks="none" checks_report checks_out
  rollup_count="$(printf '%s' "$PR_JSON" | jq -r '(.statusCheckRollup // []) | length')"
  if [[ "$rollup_count" == "0" ]]; then
    checks_report="この PR に登録された checks は無い。マージ可否はローカル全件ゲート + 鮮度照合で判定する"
  else
    # watch の非 0 は通信エラーでも起きる。API 到達可否ではなく checks の実値で判定する。
    # 未完了または取得不能が続いても無限に待たない。再待機は --watch 自身が行う。
    local check_attempt=0 max_check_attempts=3 check_json check_total check_failed check_pending
    while (( check_attempt < max_check_attempts )); do
      check_attempt=$((check_attempt + 1))
      if checks_out="$(gh pr checks "${PR_NUMBER}" --watch --fail-fast 2>&1)"; then
        checks="passed"
        checks_report="全 checks の完了と成功を確認済み（${rollup_count} 件）"
        break
      fi
      printf '%s\n' "${checks_out}" >&2
      if ! check_json="$(gh pr view "${PR_NUMBER}" --json statusCheckRollup 2>&1)" \
        || ! printf '%s' "$check_json" | jq -e '(.statusCheckRollup | type) == "array"' >/dev/null 2>&1; then
        continue
      fi
      check_total="$(printf '%s' "$check_json" | jq -r '.statusCheckRollup | length')"
      check_failed="$(printf '%s' "$check_json" | jq -r '[.statusCheckRollup[] | select((.conclusion // .state // "" | ascii_upcase) as $s | ["FAILURE","ERROR","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","CANCELLED","STALE"] | index($s)) | (.name // .context // "(名称不明)")] | join(", ")')"
      if [[ -n "$check_failed" ]]; then
        echo "CHECKS=failed"
        die_stop "失敗した check: ${check_failed}" "赤い check を直して push し、finish.sh precheck を再実行する（マージへ進まない）"
      fi
      check_pending="$(printf '%s' "$check_json" | jq -r '[.statusCheckRollup[] | select((.conclusion // .state // "" | ascii_upcase) as $s | ["SUCCESS","NEUTRAL","SKIPPED"] | index($s) | not)] | length')"
      if (( check_total > 0 && check_pending == 0 )); then
        checks="passed"
        checks_report="全 checks の完了と成功を確認済み（${check_total} 件）"
        break
      fi
    done
    if [[ "$checks" != "passed" ]]; then
      echo "CHECKS=unavailable"
      die_env "checks の成否は未確定（watch / checks 再取得が ${max_check_attempts} 回で完了せず）" "ネットワーク・認証と GitHub 上の checks の状態を確認してから finish.sh precheck を再実行する（check の失敗として扱わない）"
    fi
  fi
  echo "CHECKS=${checks}"
  echo "CHECKS_REPORT=${checks_report}"

  # ── 4b. 返信の無いレビュースレッド（自動レビュー bot の inline を含む） ──
  # /multi-review → /close-issue → merge のチェーンは PR に付いた bot の inline コメントをどこでも
  # 読まない。bot は push の十数分後にレビューを付けるため、マージ直前のここで 1 回だけ全件読む
  # （早すぎる確認の 0 件を「指摘なし」と読まない）。時点検査なので、この読み取りの後に届いた
  # レビューは次の precheck まで見えない — レビューの「完了」を告げる汎用の信号は無く、待つ
  # 機構は置かない（設計上の受容。references/merge-gate.md 2c）。判定は「返信があるか」だけで
  # 内容は見ない。取得失敗・解釈不能はスレッド 0 件へ倒さず検査不成立（未返信の有無は未確定）。
  local rt_query rt_json rt_err rt_after="" rt_page=0 rt_nodes="[]" rt_author="" rt_next rt_total rt_lines rt_unanswered rt_line
  rt_query='query($owner: String!, $name: String!, $number: Int!, $after: String) {
    repository(owner: $owner, name: $name) { pullRequest(number: $number) {
      author { login }
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { id isResolved isOutdated
          comments(first: 100) { totalCount nodes { author { login } body path line originalLine } } } } } } }'
  rt_err="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
  while :; do
    rt_page=$((rt_page + 1))
    [[ "$rt_page" -le 50 ]] || { rm -f "$rt_err"; echo "REVIEW_THREADS_SOURCE=unavailable"; die_env "レビュースレッドのページ送りが 50 ページを超えました（PR #${PR_NUMBER}）" "スレッドを resolve して減らすか PR を分割してから finish.sh precheck を再実行する（0 件として扱わない）"; }
    # JSON は stdout だけで受ける（stderr を混ぜると gh の警告で jq の型検査が落ち「解釈不能」に化ける）
    if [[ -n "$rt_after" ]]; then
      rt_json="$(gh api graphql -f query="$rt_query" -f owner="${TARGET_REPO%%/*}" -f name="${TARGET_REPO#*/}" -F number="$PR_NUMBER" -f after="$rt_after" 2>"$rt_err")"
    else
      rt_json="$(gh api graphql -f query="$rt_query" -f owner="${TARGET_REPO%%/*}" -f name="${TARGET_REPO#*/}" -F number="$PR_NUMBER" 2>"$rt_err")"
    fi \
      || { echo "REVIEW_THREADS_SOURCE=unavailable"; local rt_e; rt_e="$(cat "$rt_err")"; rm -f "$rt_err"; die_env "レビュースレッドを取得できません（gh api graphql: ${rt_e:-（stderr なし）}）。未返信の有無は未確定" "gh auth status で認証・到達を確かめて finish.sh precheck を再実行する（スレッド 0 件として扱わない）"; }
    printf '%s' "$rt_json" | jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' >/dev/null 2>&1 \
      || { echo "REVIEW_THREADS_SOURCE=unavailable"; rm -f "$rt_err"; die_env "レビュースレッドの応答を解釈できません（reviewThreads.nodes が配列でない。応答の先頭: $(printf '%s' "$rt_json" | head -c 200 | tr '\n' ' ')）" "gh api graphql の応答（PR #${PR_NUMBER}）を確かめて finish.sh precheck を再実行する（スレッド 0 件として扱わない）"; }
    [[ -n "$rt_author" ]] || rt_author="$(printf '%s' "$rt_json" | jq -r '.data.repository.pullRequest.author.login // ""')"
    # 畳み込んだ配列は標準入力で渡す。jq の引数（--argjson）に載せると、スレッドの本文が積もった配列が
    # Linux の引数 1 つの上限（128KB）や Windows のコマンドライン全体の上限（約 32KB。Git Bash から起動する
    # jq では UTF-8 のバイト数で効く）を超え、jq が起動できずに判定不能へ倒れる（Issue `#2029`）
    rt_nodes="$(printf '%s\n%s\n' "$rt_nodes" "$rt_json" \
      | jq -cs 'if length == 2 and (.[0] | type == "array") then .[0] + .[1].data.repository.pullRequest.reviewThreads.nodes
                else error("unexpected review thread pages") end')" \
      || { rm -f "$rt_err"; die_env "レビュースレッドを畳み込めません（jq）" "gh api graphql の応答（PR #${PR_NUMBER}）を確かめて finish.sh precheck を再実行する"; }
    # hasNextPage は true / false 以外（欠落・null）を「次ページ無し」へ倒さない（101 件目以降の未返信が消える）
    rt_next="$(printf '%s' "$rt_json" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | if type == "boolean" then tostring else "invalid" end')"
    case "$rt_next" in
      false) break ;;
      true) : ;;
      *) rm -f "$rt_err"; echo "REVIEW_THREADS_SOURCE=unavailable"; die_env "レビュースレッドの pageInfo.hasNextPage を読めません（PR #${PR_NUMBER}）" "gh api graphql の応答を確かめて finish.sh precheck を再実行する（0 件として扱わない）" ;;
    esac
    rt_after="$(printf '%s' "$rt_json" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""')"
    [[ -n "$rt_after" ]] || { rm -f "$rt_err"; echo "REVIEW_THREADS_SOURCE=unavailable"; die_env "レビュースレッドの次ページの cursor が空です（PR #${PR_NUMBER}）" "gh api graphql の応答を確かめて finish.sh precheck を再実行する（0 件として扱わない）"; }
  done
  rm -f "$rt_err"
  rt_total="$(printf '%s' "$rt_nodes" | jq 'length')"
  # 未返信 = 未 resolve で、起点の author 以外の投稿が 1 件も無い（bot 自身の追記だけでは返信にならない）
  # スレッド。起点が PR 作者のもの（作者自身のメモ）は数えない — ただし PR 作者を読めなかった回は
  # 除外しない（作者不明で「作者のメモ」と同一視しない）。comments(first: 100) を超える長いスレッド
  # （totalCount > 取得件数）は読めていない側に返信がありうるので未返信に数えない（totalCount で判定）。
  # 行は id / path:line / 起点 author / current|outdated / 本文先頭 60 字
  rt_lines="$(printf '%s' "$rt_nodes" | jq -r --arg author "$rt_author" '
    .[] | select(.isResolved | not)
    | select(.comments.totalCount <= (.comments.nodes | length))
    | (.comments.nodes[0].author.login // "(unknown)") as $origin
    | select(($author == "") or ($origin != $author))
    | select(([.comments.nodes[] | (.author.login // "(unknown)")] | map(select(. != $origin)) | length) == 0)
    | [ .id,
        ((.comments.nodes[0].path // "-") + ":" + ((.comments.nodes[0].line // .comments.nodes[0].originalLine // 0) | tostring)),
        $origin,
        (if .isOutdated then "outdated" else "current" end),
        ((.comments.nodes[0].body // "") | gsub("[\r\n\t]+"; " ") | .[0:60]) ] | @tsv')" \
    || die_env "レビュースレッドの判定に失敗（jq）" "gh api graphql の応答（PR #${PR_NUMBER}）を確かめて finish.sh precheck を再実行する"
  rt_unanswered="$(printf '%s\n' "$rt_lines" | awk 'NF { c++ } END { print c + 0 }')" || rt_unanswered=""
  case "$rt_unanswered" in ''|*[!0-9]*) die_env "未返信スレッドの件数を数えられません（awk）" "awk が PATH に在ることを確かめて finish.sh precheck を再実行する" ;; esac
  echo "REVIEW_THREADS_SOURCE=graphql"
  echo "REVIEW_THREADS=${rt_total}"
  echo "REVIEW_THREADS_UNANSWERED=${rt_unanswered}"
  while IFS= read -r rt_line; do [[ -n "$rt_line" ]] && printf 'REVIEW_THREAD=%s\n' "$rt_line"; done <<<"$rt_lines"
  # 件数ではなく行の有無で止める（数え損ねを黙って 0 にしない）。先着の停止理由があれば併記する
  if [[ -n "$rt_lines" ]]; then
    if [[ -z "$blocked_reason" ]]; then
      blocked_reason="返信の無いレビュースレッドが ${rt_unanswered} 件あります（REVIEW_THREAD= 行。自動レビュー bot の指摘を含む）"
      blocked_next="各スレッドへ判定（この PR で直す / follow-up Issue の番号 / 退ける理由）を返信するか resolve してから finish.sh precheck を再実行する（返信は GraphQL addPullRequestReviewThreadReply。内容の当否は返信で残す。返信せずにマージへ進まない）"
    else
      blocked_reason="${blocked_reason}／さらに返信の無いレビュースレッドが ${rt_unanswered} 件あります（REVIEW_THREAD= 行）"
      blocked_next="${blocked_next}。あわせて各スレッドへ判定を返信するか resolve する"
    fi
  fi

  # ── 5. ゲート実測鮮度の照合（マージ直前） ──
  # 照合直前に読み直す — 先端だけでなく PR 全体を（手順 1 からの経過中 — checks の待機を含む — に先端・本文・タイトルが
  # 変わっている可能性がある）。先端だけを読み直すと、待機中に本文へ足された Refs やタイトルの
  # 改題が初回の判定（対象 Issue・抵触検査・工数）をすり抜ける。判定に使った全フィールドを
  # 初回と比べ、差があれば止めて最初からやり直させる（checks の結果は待機で変わるので、
  # 比べるのは checks の有無だけ）。
  # 先端は remote-tracking ref ではなく API の値を使い、ここで得た値を --match-head-commit へそのまま
  # 渡す（照合した先端とマージする先端を同じにする）。remote-tracking ref は前回 fetch 時点の
  # スナップショットなので、fetch を忘れた回に「古い先端 == 古い実測対象」で一致してしまう。
  local PR_JSON_AGAIN snap_before snap_after snap_diff
  PR_JSON_AGAIN="$(gh_pr_view_or_die "$PR_NUMBER" "$PR_FIELDS")" || exit $?
  # 2 つのスナップショットは標準入力で渡す（PR 本文を含むので、引数に載せると上の畳み込みと同じ上限で
  # jq が起動できない。Issue `#2029`。Windows で 10KB 超の本文から実測）
  snap_before="$(pr_snapshot <<<"$PR_JSON")" && snap_after="$(pr_snapshot <<<"$PR_JSON_AGAIN")" \
    && snap_diff="$(printf '%s\n%s\n' "$snap_before" "$snap_after" \
      | jq -rs 'if length == 2 and (.[0] | type == "object") and (.[1] | type == "object")
                then .[0] as $a | .[1] as $b | [$a | keys[] as $k | select($a[$k] != $b[$k]) | $k] | join(",")
                else error("unexpected snapshots") end')" \
    || die_env "PR の読み直し結果を初回と比べられません（jq）" "gh pr view ${PR_NUMBER} --json ${PR_FIELDS} の出力を確かめる"
  if [[ -n "$snap_diff" ]]; then
    echo "PR_SNAPSHOT=changed"
    echo "PR_SNAPSHOT_DIFF=${snap_diff}"
    die_stop "判定の途中で PR が変わりました（${snap_diff}）。初回の判定（対象 Issue・抵触検査・工数）は変更前の値に基づいています" "finish.sh precheck ${PR_NUMBER} を最初から再実行する（Refs 運用は --subject / --body 付き。途中の出力を流用しない）"
  fi
  echo "PR_SNAPSHOT=unchanged"
  local REMOTE_HEAD FRESHNESS FRESH_OUT FRESH_STATUS FRESH_REPORT FRESH_REASON="" FRESH_ACTION="" FRESH_RECORD
  REMOTE_HEAD="$(printf '%s' "$PR_JSON_AGAIN" | jq -r '.headRefOid // ""')"
  [[ -n "$REMOTE_HEAD" ]] || die_env "リモート先端（headRefOid）が空です" "gh pr view ${PR_NUMBER} --json headRefOid の出力を確かめる"
  FRESHNESS="$plugin_root/scripts/check-merge-freshness.sh"
  # --gate-record は別 checkout（WSL の clone など）で回したゲートの記録。照合も報告もその記録で
  # 行い、ブランチ照合だけを外す宣言を添える（外すのは明示した記録だけ。既定パス・
  # FF_GATE_RECORD_FILE の記録には従来どおり掛かる）
  local -a fresh_record_args=() print_record_args=()
  if [[ "$have_gate_record" -eq 1 ]]; then
    fresh_record_args=(--record "${GATE_RECORD}" --record-from-other-checkout)
    print_record_args=(--record "${GATE_RECORD}")
  fi
  assert_bundled_shebang_lf "${FRESHNESS}"
  FRESH_OUT="$(FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${FRESHNESS}" --remote-head "${REMOTE_HEAD}" --fetch ${fresh_record_args[@]+"${fresh_record_args[@]}"})"
  FRESH_STATUS=$?
  case "${FRESH_STATUS}" in
    0)
      # 一致。報告には実測の素性（ゲート名・モード）も載せる — 高速モードの記録を
      # 「全件実行で通した」と読ませないため（モードは合否には使わない）
      assert_bundled_shebang_lf "${FRESHNESS}"
      FRESH_RECORD="$(FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${FRESHNESS}" --print-record ${print_record_args[@]+"${print_record_args[@]}"} 2>/dev/null || true)"
      local fresh_gate fresh_mode fresh_result fresh_branch
      fresh_gate="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^GATE=//p')"
      fresh_mode="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^MODE=//p')"
      fresh_result="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^RESULT=//p')"
      FRESH_REPORT="✅ 一致（${fresh_gate:-ゲート不明} / モード ${fresh_mode:-不明} / ${fresh_result:-結果不明}）"
      if [[ "$have_gate_record" -eq 1 ]]; then
        # 別 checkout の記録で通したことを報告に残す（手元の記録で測ったと読ませない）
        fresh_branch="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^BRANCH=//p' | head -n 1)"
        FRESH_REPORT="${FRESH_REPORT} — 別 checkout の記録: ${GATE_RECORD}（BRANCH=${fresh_branch:-不明}）"
      fi
      ;;
    1)
      printf '%s\n' "${FRESH_OUT}" >&2
      echo "FRESH_STATUS=1"
      echo "✗ 止める: リモート先端がゲート実測対象と一致しません（取り込んで測り直すこと）" >&2
      echo "  次の一手: 上の RELATION / ACTION に従って取り込み（force-push で押し切らない）、ゲートを回し直してから finish.sh precheck を再実行する" >&2
      # 先着の停止理由（抵触・未返信スレッド）があれば併記する — 鮮度だけ直して再実行し、もう一度止まる
      # 2 段停止を作らない
      if [[ -n "$blocked_reason" ]]; then
        echo "PRECHECK=blocked"
        echo "  併発: ${blocked_reason}" >&2
        echo "  併発の次の一手: ${blocked_next}" >&2
      fi
      exit 1
      ;;
    2)
      # 判定不能。止めないが REASON と ACTION を両方そのまま報告へ載せる（黙って素通りさせない）
      FRESH_REASON="$(printf '%s\n' "${FRESH_OUT}" | sed -n 's/^REASON=//p' | head -n 1)"
      FRESH_ACTION="$(printf '%s\n' "${FRESH_OUT}" | sed -n 's/^ACTION=//p' | head -n 1)"
      FRESH_REPORT="⚠️ 判定不能 — ${FRESH_REASON} / 次の一手: ${FRESH_ACTION}"
      ;;
    *)
      printf '%s\n' "${FRESH_OUT}" >&2
      echo "FRESH_STATUS=${FRESH_STATUS}"
      echo "✗ 判定不能: 鮮度照合が成立していません（status=${FRESH_STATUS}）。一致として扱わない" >&2
      echo "  復帰: scripts/check-merge-freshness.sh の使い方エラー・リポジトリの状態を直して再実行する" >&2
      exit 2
      ;;
  esac
  echo "FRESH_STATUS=${FRESH_STATUS}"
  echo "FRESH_REPORT=${FRESH_REPORT}"
  # ── 6. 判定不能のとき全件ゲートを回し直すか ──
  local rerun="" rerun_reason=""
  if [[ "$FRESH_STATUS" -eq 2 ]]; then
    echo "FRESH_REASON=${FRESH_REASON}"
    echo "FRESH_ACTION=${FRESH_ACTION}"
    case "$FRESH_REASON" in
      *"部分実行"*)
        if [[ "$checks" == "passed" ]]; then
          rerun="no"; rerun_reason="記録が部分実行で checks が全件成功（PR の checks がリモート先端を実測している。リリース前・契約面の変更時は除く）"
        else
          rerun="yes"; rerun_reason="記録が部分実行で checks による裏付けが無い"
        fi ;;
      *"汚れていました"*) rerun="yes"; rerun_reason="汚れた木で測った記録（checks が成功していても回し直す）" ;;
      *"記録がありません"*|*"記録先を解決できません"*) rerun="yes"; rerun_reason="実測の記録が無い（checks が成功していても回し直す）" ;;
      *) rerun="see-action"; rerun_reason="FRESH_ACTION に従う（${FRESH_REASON}）" ;;
    esac
    echo "RERUN_FULL_GATE=${rerun}"
    echo "RERUN_REASON=${rerun_reason}"
  fi

  # ── 7. merge コマンドの生成 ──
  # 2 の抵触で止める回は、停止判定より先にコマンドを出さない（出した時点で「貼れば通る」形になる）
  if [[ -n "$blocked_reason" ]]; then
    echo "PRECHECK=blocked"
    die_stop "$blocked_reason" "$blocked_next"
  fi
  # base / head が別 worktree に保持されていれば、既存の互換経路として separate-push にする。
  # この経路では照合済み head OID の lease を明示する。--repo を明示した gh v2.102.0 はローカル
  # ブランチを切り替え・削除しないため、その後始末は /merge-cleanup が担当する。
  # 一覧が取れない回は保持者 0 とみなさず（fail-open で --delete-branch 付きを出さない）、生成しない
  local wt_list wt_path="" wt_phys="" wt_branch="" base_held="" head_held="" line
  wt_list="$(git worktree list --porcelain 2>&1)" \
    || die_env "worktree の一覧を取得できません（git worktree list: ${wt_list}）。保持者を判定できないため merge コマンドを生成しない" "git worktree list --porcelain が通る状態（壊れた worktree は git worktree prune）に直してから finish.sh precheck を再実行する"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt_path="${line#worktree }"; wt_branch=""
        # repo_root は pwd -P の物理パス。git はパスを別の綴りで返しうる（Windows の Git Bash では
        # `C:/repo` に対して repo_root が `/c/repo`）ので、同じく物理パスへ揃えてから比べる。揃えないと
        # 自分の worktree を保持者と読み、毎回 --delete-branch を落としていた（Issue `#2018`）。
        # 解決できない（消えた worktree）ときは綴りのまま比べる
        wt_phys="$(CDPATH='' cd -P -- "$wt_path" 2>/dev/null && pwd -P)" || wt_phys="$wt_path" ;;
      "branch refs/heads/"*)
        wt_branch="${line#branch refs/heads/}"
        [[ "$wt_phys" == "$repo_root" ]] && continue
        [[ "$wt_branch" == "$base_ref" ]] && base_held="$wt_path"
        [[ "$wt_branch" == "$head_ref" ]] && head_held="$wt_path" ;;
    esac
  done <<<"$wt_list"
  local DELETE_FLAG=" --delete-branch" delete_mode="delete-branch" head_delete=""
  if [[ -n "$base_held" || -n "$head_held" ]]; then
    DELETE_FLAG=""; delete_mode="separate-push"
    [[ -z "$base_held" ]] || echo "BASE_HELD_BY=${base_held}"
    [[ -z "$head_held" ]] || echo "HEAD_HELD_BY=${head_held}"
    # リモートブランチの削除は同一リポジトリの PR に限る（fork の PR の head は相手のリポジトリにあり、
    # origin の同名ブランチは別物）。削除は照合した先端 OID を lease に載せ、マージ後に同名ブランチが
    # 再利用されていればサーバー側で拒否させる
    if [[ "$is_cross" == "false" ]]; then
      head_delete="lease"
    else
      head_delete="skipped-fork"
      echo "⚠️  head ブランチの削除コマンドは生成しません（isCrossRepository=${is_cross}: fork の PR、または判定不能）" >&2
    fi
    echo "HEAD_DELETE=${head_delete}"
  fi
  echo "DELETE_BRANCH_MODE=${delete_mode}"
  # リモートブランチの削除は merge の成功に条件付ける（`&&` で 1 コマンドにする）。別行にすると
  # merge が失敗（checks 未完了・先端不一致・競合）した回にも削除だけが走り、未マージの PR の
  # head ブランチが消えて PR が閉じる
  local delete_tail="" delete_body="" delete_script="$plugin_root/scripts/lib/finish-delete-merged-head.sh"
  if [[ "$head_delete" == "lease" ]]; then
    need_bundled lib/finish-delete-merged-head.sh
    assert_bundled_shebang_lf "$delete_script"
    delete_body="$(cat "$delete_script")" \
      || die_env "head 削除の同梱 script を読めません。merge コマンドを生成しない" "ff-dev-toolkit を再導入してから skill を呼び直す"
    [[ -n "$delete_body" ]] || die_env "head 削除の同梱 script が空です。merge コマンドを生成しない" "ff-dev-toolkit を再導入してから skill を呼び直す"
    q "$delete_body" >/dev/null && q "$repo_root" >/dev/null && q "$head_ref" >/dev/null && q "$REMOTE_HEAD" >/dev/null \
      || die_env "引用に失敗（sed が使えない）。merge コマンドを生成しない" "sed を PATH に戻して再実行する"
    # 生成時に本文を固定する。マージ後に plugin が更新・除去されても、このコマンドは単体で動く。
    # consumer root を位置引数へ固定し、実行 cwd や plugin の origin を削除対象にしない。
    delete_tail="$(printf ' \\\n  && bash -c %s ff-delete-merged-head %s %s %s' "$(q "$delete_body")" "$(q "$repo_root")" "$(q "$head_ref")" "$(q "$REMOTE_HEAD")")"
  fi
  local quoted_target_repo="" quoted_merge_subject="" quoted_merge_body=""
  quoted_target_repo="$(q "$TARGET_REPO_URL")" \
    || die_env "引用に失敗（sed が使えない）。merge コマンドを生成しない" "sed を PATH に戻して再実行する"
  if [[ "$have_subject" -eq 1 ]]; then
    # 引用は全てコマンド出力前に済ませ、失敗時に開始マーカーも出さない。
    quoted_merge_subject="$(q "$MERGE_SUBJECT")" && quoted_merge_body="$(q "$MERGE_BODY")" \
      || die_env "引用に失敗（sed が使えない）。merge コマンドを生成しない" "sed を PATH に戻して再実行する"
  fi
  echo "MERGE_COMMAND_BEGIN"
  if [[ "$have_subject" -eq 1 ]]; then
    printf 'gh pr merge %s --repo %s --squash --match-head-commit %s%s \\\n  --subject %s \\\n  --body %s%s\n' \
      "${PR_NUMBER}" "$quoted_target_repo" "${REMOTE_HEAD}" "${DELETE_FLAG:-}" "$quoted_merge_subject" "$quoted_merge_body" "${delete_tail:-}"
  else
    printf 'gh pr merge %s --repo %s --squash --match-head-commit %s%s%s\n' "${PR_NUMBER}" "$quoted_target_repo" "${REMOTE_HEAD}" "${DELETE_FLAG:-}" "${delete_tail:-}"
  fi
  echo "MERGE_COMMAND_END"

  if [[ "$FRESH_STATUS" -eq 2 && "$rerun" != "no" ]]; then
    echo "PRECHECK=undetermined"
    {
      echo "✗ 判定不能: ゲート実測鮮度を確定できません — ${FRESH_REASON}"
      echo "  復帰: RERUN_FULL_GATE=${rerun}（${rerun_reason}）。記録の仕組みを持つプロジェクトでは clean な木で全件ゲートを回してから finish.sh precheck を再実行する。持たないプロジェクトでは判定不能が常態なので、上の FRESH_REASON / FRESH_ACTION を完了報告へそのまま載せて MERGE_COMMAND で進む（skill 側の判断）"
    } >&2
    exit 2
  fi
  echo "PRECHECK=ready"
  return 0
}

_finish_precheck_loaded=1
