#!/usr/bin/env bash
# Source-only: GitHub GraphQL が 403 で使えない環境（Claude Code クラウドセッション等）向けの
# REST API (`gh api`) フォールバックと --github-input 案内を集約する共有ライブラリ。
# bash 3.2 互換。呼び出し元のシェルオプションを変更しない。
#
# 提供関数:
#   ff_gh_is_graphql_unavailable <err_text>
#     GraphQL 403 / 利用不可エラーなら 0、それ以外（404・認証切れ・Unknown JSON field・汎用不通）は 1。
#   ff_gh_parse_repo_spec <spec>
#     owner/repo / host/owner/repo / URL から _ff_gh_resolved_host・_ff_gh_resolved_repo を設定。
#   ff_gh_resolve_repo <repo_spec> <cwd>
#     明示 repo → 環境変数 GH_REPO → git config の gh-resolved=base remote → remote.origin.url の順で解決する。
#   ff_gh_rest_pr_view <selector> <repo_spec> <cwd> <err_file>
#     REST PR 応答を gh pr view 相当の JSON（MERGED/OPEN/CLOSED, isCrossRepository 等）へ正規化して出力。
#     制約: REST /pulls/{n} には closingIssuesReferences が無いため常に [] を返す（サイドバー手動リンクのみは拾えない）。
#   ff_gh_rest_pr_list <merged|open> <limit> <repo_spec> <cwd> <err_file>
#     REST PR 一覧を gh pr list 相当の JSON 配列へ正規化して出力（open の未完了打ち切り・merged の要求件数未満打ち切りは fail-closed）。
#   ff_gh_rest_issue_view <num> <repo_spec> <cwd> <err_file>
#     REST Issue 応答を {body, state}（OPEN/CLOSED）へ正規化して出力。
#   ff_gh_rest_issue_comments <num> <repo_spec> <cwd> <err_file>
#     REST Issue コメント一覧を {comments:[{body:...}]} へ正規化して出力（上限到達時は fail-closed）。
#   ff_gh_rest_open_issue_numbers <repo> <limit> <out_file> <err_file>
#     REST open Issue 一覧（pull_request を除外）の番号を 1 行 1 件で out_file へ書く。
#   ff_gh_github_input_hint <cleanup|precheck|lookup>
#     REST でも読めない環境向けに --github-input の最小 index JSON 手順を 1 ブロックで返す。

_ff_gh_resolved_host=""
_ff_gh_resolved_repo=""
_ff_gh_host_explicit=0

ff_gh_is_graphql_unavailable() {
  local msg="${1:-}"
  # 存在しない PR/Issue 番号（例: 番号 403）の 404 エラーへ誤発火させない
  case "$msg" in
    *[Cc][Oo][Uu][Ll][Dd]' '[Nn][Oo][Tt]' '[Rr][Ee][Ss][Oo][Ll][Vv][Ee]' '[Tt][Oo]*)
      return 1 ;;
  esac
  case "$msg" in
    *[Gg][Rr][Aa][Pp][Hh][Qq][Ll]*)
      case "$msg" in
        *[Hh][Tt][Tt][Pp]' '403*|*[Hh][Tt][Tt][Pp][[:space:]]403*|*403' '[Ff][Oo][Rr][Bb][Ii][Dd][Dd][Ee][Nn]*|*[Ss][Tt][Aa][Tt][Uu][Ss]*403*|*'('403')'*|*": 403"*|*[Nn][Oo][Tt]' '[Aa][Vv][Aa][Ii][Ll][Aa][Bb][Ll][Ee]*|*[Uu][Ss][Ee]' '[Tt][Hh][Ee]' '[Rr][Ee][Ss][Tt]' '[Aa][Pp][Ii]*)
          return 0 ;;
      esac
      ;;
  esac
  return 1
}

_ff_gh_valid_segment() {
  local seg="${1:-}"
  case "$seg" in
    ""|"."|".."|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

ff_gh_parse_repo_spec() {
  local raw="${1:-}" host="" path="" owner="" name="" host_lc="" port=""
  _ff_gh_resolved_host=""
  _ff_gh_resolved_repo=""
  _ff_gh_host_explicit=0
  raw="${raw%$'\r'}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [ -n "$raw" ] || return 1
  while [ "${raw%/}" != "$raw" ]; do raw="${raw%/}"; done
  case "$raw" in
    *.git) raw="${raw%.git}" ;;
  esac
  case "$raw" in
    https://*|http://*)
      raw="${raw#*://}"
      host="${raw%%/*}"
      path="${raw#*/}"
      [ "$path" != "$raw" ] || return 1
      _ff_gh_host_explicit=1
      ;;
    ssh://*)
      raw="${raw#ssh://}"
      host="${raw%%/*}"
      path="${raw#*/}"
      [ "$path" != "$raw" ] || return 1
      _ff_gh_host_explicit=1
      ;;
    git@*:*)
      raw="${raw#git@}"
      host="${raw%%:*}"
      path="${raw#*:}"
      _ff_gh_host_explicit=1
      ;;
    */*/*)
      host="${raw%%/*}"
      path="${raw#*/}"
      _ff_gh_host_explicit=1
      ;;
    */*)
      host=""
      path="$raw"
      ;;
    *)
      return 1
      ;;
  esac
  while [ "${path#/}" != "$path" ]; do path="${path#/}"; done
  while [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  case "$path" in
    */*/*) return 1 ;;
    */*)
      owner="${path%%/*}"
      name="${path#*/}"
      ;;
    *) return 1 ;;
  esac
  _ff_gh_valid_segment "$owner" || return 1
  _ff_gh_valid_segment "$name" || return 1
  if [ -n "$host" ]; then
    case "$host" in
      *@*) host="${host#*@}" ;;
    esac
    case "$host" in
      *:*)
        port="${host##*:}"
        case "$port" in
          ''|*[!0-9]*) return 1 ;;
          *) host="${host%:*}" ;;
        esac
        ;;
    esac
    [ -n "$host" ] || return 1
    host_lc="$(printf '%s' "$host" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    case "$host_lc" in
      github.com) host="" ;;
      *[!a-z0-9.-]*) return 1 ;;
    esac
  fi
  _ff_gh_resolved_host="$host"
  _ff_gh_resolved_repo="${owner}/${name}"
  return 0
}

_ff_gh_resolve_git_default_remote() { # <cwd> -> stdout に spec または URL
  local cwd="${1:-.}" resolved_lines="" line="" key="" val="" rname=""
  local base_count=0 any_resolved=0 base_target=""
  resolved_lines="$(git -C "$cwd" config --get-regexp '^remote\.[^.]+\.gh-resolved$' 2>/dev/null || true)"
  if [ -n "$resolved_lines" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      [ -n "$line" ] || continue
      any_resolved=1
      key="${line%% *}"
      val="${line#* }"
      rname="${key#remote.}"
      rname="${rname%.gh-resolved}"
      case "$val" in
        base)
          base_count=$((base_count + 1))
          base_target="$(git -C "$cwd" config --get "remote.${rname}.url" 2>/dev/null || true)"
          ;;
        base:*)
          base_count=$((base_count + 1))
          base_target="${val#base:}"
          ;;
      esac
    done <<EOF
$resolved_lines
EOF
    if [ "$base_count" -eq 1 ] && [ -n "$base_target" ]; then
      printf '%s\n' "$base_target"
      return 0
    fi
    if [ "$any_resolved" -eq 1 ]; then
      # gh repo set-default で明示設定があるのに base が一意解決できない場合は黙って origin へ落とさない
      return 1
    fi
  fi
  git -C "$cwd" config --get remote.origin.url 2>/dev/null
}

ff_gh_resolve_repo() { # <repo_spec> <cwd>
  local repo_spec="${1:-}" cwd="${2:-.}" origin_url="" gh_host_lc=""
  _ff_gh_resolved_host=""
  _ff_gh_resolved_repo=""
  _ff_gh_host_explicit=0
  if [ -n "$repo_spec" ]; then
    ff_gh_parse_repo_spec "$repo_spec" || return 1
  elif [ -n "${GH_REPO:-}" ]; then
    ff_gh_parse_repo_spec "$GH_REPO" || return 1
  else
    origin_url="$(_ff_gh_resolve_git_default_remote "$cwd")" || return 1
    ff_gh_parse_repo_spec "$origin_url" || return 1
  fi
  if [ "$_ff_gh_host_explicit" -eq 0 ] && [ -z "$_ff_gh_resolved_host" ] && [ -n "${GH_HOST:-}" ]; then
    gh_host_lc="$(printf '%s' "$GH_HOST" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [ "$gh_host_lc" != "github.com" ]; then
      _ff_gh_resolved_host="$GH_HOST"
    fi
  fi
  return 0
}

_ff_gh_api() { # <endpoint> <err_file>
  local endpoint="$1" err_file="${2:-/dev/null}" host="$_ff_gh_resolved_host" gh_host_lc=""
  # github.com が明示されたリポジトリで環境に別 GH_HOST がある場合、gh api が GH_HOST へ
  # 誤送信しないよう --hostname github.com を明示する。
  if [ -z "$host" ] && [ "$_ff_gh_host_explicit" -eq 1 ] && [ -n "${GH_HOST:-}" ]; then
    gh_host_lc="$(printf '%s' "$GH_HOST" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [ "$gh_host_lc" != "github.com" ]; then
      host="github.com"
    fi
  fi
  if [ -n "$host" ]; then
    gh api --hostname "$host" "$endpoint" 2>"$err_file" </dev/null
  else
    gh api "$endpoint" 2>"$err_file" </dev/null
  fi
}

# 単一の REST PR オブジェクトを gh pr view の JSON 契約へ正規化する jq 定義。
# REST の /pulls?state=closed は merged を持たず merged_at のみを持つため、両方を見て MERGED とする。
# head.repo / base.repo のどちらかが null（削除済み fork 等）のときは安全側で isCrossRepository=true。
# 制約: REST /pulls/{n} は GraphQL の closingIssuesReferences を返さないため常に [] とする
# （サイドバー手動リンクのみで本文に closing keyword がない Issue は REST 経路の限界として本文走査対象外）。
_ff_gh_norm_pr_jq='
def norm_pr:
  {
    number: .number,
    state: (
      if (.merged == true) or (.merged_at != null) then "MERGED"
      elif ((.state // "") | ascii_downcase) == "open" then "OPEN"
      else "CLOSED"
      end
    ),
    isDraft: (.draft // false),
    headRefName: (.head.ref // null),
    headRefOid: (.head.sha // null),
    baseRefName: (.base.ref // null),
    baseRefOid: (.base.sha // null),
    title: (.title // ""),
    body: (.body // ""),
    url: (.html_url // ""),
    isCrossRepository: (
      if (.head.repo == null) or (.base.repo == null) then true
      elif ((.head.repo.id != null) and (.base.repo.id != null)) then (.head.repo.id != .base.repo.id)
      elif ((.head.repo.full_name != null) and (.base.repo.full_name != null)) then
        ((.head.repo.full_name | ascii_downcase) != (.base.repo.full_name | ascii_downcase))
      else true
      end
    ),
    closingIssuesReferences: []
  };
'

ff_gh_rest_pr_view() { # <selector> <repo_spec> <cwd> <err_file>
  local selector="${1:-}" repo_spec="${2:-}" cwd="${3:-.}" err_file="${4:-/dev/null}"
  local pr_num="" branch="" head_query="" enc_head="" raw="" url_rest="" url_host="" url_repo="" url_num=""
  _ff_gh_resolved_host=""
  _ff_gh_resolved_repo=""
  _ff_gh_host_explicit=0
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "jq が見つからないため REST API フォールバックを解釈できません" >"$err_file"; return 1; }

  # PR URL: https://host/owner/repo/pull/123...
  case "$selector" in
    https://*/pull/[0-9]*|http://*/pull/[0-9]*)
      url_rest="${selector#*://}"
      url_host="${url_rest%%/*}"
      url_rest="${url_rest#*/}"
      url_repo="${url_rest%/pull/*}"
      url_num="${url_rest##*/pull/}"
      url_num="${url_num%%[/?#]*}"
      case "$url_num" in
        ''|*[!0-9]*)
          printf '%s\n' "PR URL から番号を解決できません: ${selector}" >"$err_file"
          return 1
          ;;
      esac
      if ! ff_gh_parse_repo_spec "https://${url_host}/${url_repo}"; then
        printf '%s\n' "PR URL からリポジトリを解決できません: ${selector}" >"$err_file"
        return 1
      fi
      pr_num="$url_num"
      ;;
    [0-9]*)
      case "$selector" in
        *[!0-9]*) ;;
        *) pr_num="$selector" ;;
      esac
      ;;
  esac

  if [ -n "$pr_num" ]; then
    if [ -z "$_ff_gh_resolved_repo" ]; then
      if ! ff_gh_resolve_repo "$repo_spec" "$cwd"; then
        printf '%s\n' "リポジトリ（owner/repo）を解決できないため REST API で PR を取得できません" >"$err_file"
        return 1
      fi
    fi
    raw="$(_ff_gh_api "repos/${_ff_gh_resolved_repo}/pulls/${pr_num}" "$err_file")" || return 1
    printf '%s' "$raw" | jq -e 'type == "object" and (.number | type == "number") and (.state | type == "string")' >/dev/null 2>&1 || {
      printf '%s\n' "REST API の PR 応答を解釈できません" >"$err_file"
      return 1
    }
    printf '%s' "$raw" | jq -c "${_ff_gh_norm_pr_jq} norm_pr"
    return $?
  fi

  # ブランチ名または現在ブランチ
  if ! ff_gh_resolve_repo "$repo_spec" "$cwd"; then
    printf '%s\n' "リポジトリ（owner/repo）を解決できないため REST API で PR を取得できません" >"$err_file"
    return 1
  fi
  if [ -n "$selector" ]; then
    branch="$selector"
  else
    branch="$(git -C "$cwd" branch --show-current 2>/dev/null)" || branch=""
    branch="${branch%$'\r'}"
    if [ -z "$branch" ]; then
      printf '%s\n' "現在のブランチ名を取得できないため REST API で PR を特定できません" >"$err_file"
      return 1
    fi
  fi
  case "$branch" in
    *:*) head_query="$branch" ;;
    *) head_query="${_ff_gh_resolved_repo%%/*}:${branch}" ;;
  esac
  enc_head="$(jq -rn --arg v "$head_query" '$v | @uri' 2>"$err_file")" || { [ -s "$err_file" ] || printf '%s\n' "ブランチ名の URI エンコードに失敗しました" >"$err_file"; return 1; }
  enc_head="${enc_head//$'\r'/}"
  raw="$(_ff_gh_api "repos/${_ff_gh_resolved_repo}/pulls?state=open&head=${enc_head}&per_page=10" "$err_file")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "array" and length == 1 and (.[0].number | type == "number") and (.[0].state | type == "string")' >/dev/null 2>&1; then
    printf '%s\n' "ブランチ ${branch} に対応する open PR を REST API で一意に特定できません" >"$err_file"
    return 1
  fi
  printf '%s' "$raw" | jq -c "${_ff_gh_norm_pr_jq} .[0] | norm_pr"
}

ff_gh_rest_pr_list() { # <merged|open> <limit> <repo_spec> <cwd> <err_file>
  local mode="${1:-}" limit="${2:-1000}" repo_spec="${3:-}" cwd="${4:-.}" err_file="${5:-/dev/null}"
  local tmp_dir="" page=1 max_pages=10 page_pad="" page_file="" norm_file="" page_len="" kept=0 total=0 complete=0 endpoint="" jq_rc=0
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "jq が見つからないため REST API 一覧を解釈できません" >"$err_file"; return 1; }
  case "$mode" in
    merged|open) ;;
    *) printf '%s\n' "未知の PR 一覧種別です: ${mode}" >"$err_file"; return 1 ;;
  esac
  case "$limit" in
    ''|*[!0-9]*) limit=1000 ;;
  esac
  [ "$limit" -ge 1 ] 2>/dev/null || limit=1000
  if ! ff_gh_resolve_repo "$repo_spec" "$cwd"; then
    printf '%s\n' "リポジトリ（owner/repo）を解決できないため REST API で PR 一覧を取得できません" >"$err_file"
    return 1
  fi
  if [ "$mode" = "open" ]; then
    max_pages=$(( (limit + 99) / 100 ))
    [ "$max_pages" -le 10 ] || max_pages=10
  else
    # closed 一覧には未マージの closed PR が混ざるため、上限ページ数を広めに取る
    max_pages=$(( (limit + 99) / 100 + 5 ))
    [ "$max_pages" -le 20 ] || max_pages=20
  fi
  tmp_dir="$(mktemp -d)" || { printf '%s\n' "一時ディレクトリを作成できません" >"$err_file"; return 1; }
  while [ "$page" -le "$max_pages" ]; do
    if [ "$mode" = "open" ]; then
      endpoint="repos/${_ff_gh_resolved_repo}/pulls?state=open&sort=created&direction=desc&per_page=100&page=${page}"
    else
      # gh pr list --state merged と同じ作成日時降順で取得する
      endpoint="repos/${_ff_gh_resolved_repo}/pulls?state=closed&sort=created&direction=desc&per_page=100&page=${page}"
    fi
    printf -v page_pad '%04d' "$page"
    page_file="${tmp_dir}/page-${page_pad}.raw"
    norm_file="${tmp_dir}/norm-${page_pad}.json"
    if ! _ff_gh_api "$endpoint" "$err_file" >"$page_file"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! jq -e 'type == "array"' "$page_file" >/dev/null 2>&1; then
      printf '%s\n' "REST API の PR 一覧応答が配列ではありません" >"$err_file"
      rm -rf "$tmp_dir"
      return 1
    fi
    page_len="$(jq -r 'length' "$page_file" 2>"$err_file")" || { [ -s "$err_file" ] || printf '%s\n' "REST API の PR 一覧件数を読めません" >"$err_file"; rm -rf "$tmp_dir"; return 1; }
    page_len="${page_len//$'\r'/}"
    if [ "$mode" = "open" ]; then
      jq -c '[.[] | {headRefName: (.head.ref // null)}]' "$page_file" >"$norm_file" 2>"$err_file" || { [ -s "$err_file" ] || printf '%s\n' "REST API の open PR 一覧整形に失敗しました" >"$err_file"; rm -rf "$tmp_dir"; return 1; }
      kept="$page_len"
    else
      jq -c "${_ff_gh_norm_pr_jq} [.[] | select(.merged_at != null) | norm_pr | {headRefName, headRefOid, isCrossRepository, baseRefName}]" \
        "$page_file" >"$norm_file" 2>"$err_file" || { [ -s "$err_file" ] || printf '%s\n' "REST API の merged PR 一覧整形に失敗しました" >"$err_file"; rm -rf "$tmp_dir"; return 1; }
      kept="$(jq -r 'length' "$norm_file" 2>"$err_file")" || { [ -s "$err_file" ] || printf '%s\n' "REST API の merged PR 件数を読めません" >"$err_file"; rm -rf "$tmp_dir"; return 1; }
      kept="${kept//$'\r'/}"
    fi
    total=$((total + kept))
    if [ "$page_len" -lt 100 ]; then
      complete=1
      break
    fi
    if [ "$total" -ge "$limit" ]; then
      break
    fi
    page=$((page + 1))
  done
  # open PR 一覧が 100 件/ページのまま上限で打ち切られた場合は取りこぼしの恐れがあるため fail-closed。
  # merged PR 一覧も末尾未到達のまま要求件数未満でページ上限へ達したら全件取得と誤認させないため fail-closed。
  if [ "$mode" = "open" ] && [ "$complete" -ne 1 ]; then
    printf '%s\n' "REST API の open PR 一覧が走査上限（${limit} 件 / ${max_pages} ページ）に達したため完全な一覧を確認できません" >"$err_file"
    rm -rf "$tmp_dir"
    return 1
  fi
  if [ "$mode" = "merged" ] && [ "$complete" -ne 1 ] && [ "$total" -lt "$limit" ]; then
    printf '%s\n' "REST API の merged PR 一覧が走査上限（${max_pages} ページ）に達し要求件数（${limit} 件）を満たせなかったため完全な一覧を確認できません" >"$err_file"
    rm -rf "$tmp_dir"
    return 1
  fi
  jq -cs --argjson lim "$limit" 'add | .[0:$lim]' "${tmp_dir}"/norm-*.json 2>"$err_file" || jq_rc=$?
  if [ "$jq_rc" -ne 0 ] && [ ! -s "$err_file" ]; then
    printf '%s\n' "REST API の PR 一覧結合に失敗しました" >"$err_file"
  fi
  rm -rf "$tmp_dir"
  return "$jq_rc"
}

ff_gh_rest_issue_view() { # <num> <repo_spec> <cwd> <err_file>
  local num="${1:-}" repo_spec="${2:-}" cwd="${3:-.}" err_file="${4:-/dev/null}" raw=""
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "jq が見つからないため REST API Issue 応答を解釈できません" >"$err_file"; return 1; }
  case "$num" in
    ''|*[!0-9]*) printf '%s\n' "Issue 番号が数字ではありません: ${num}" >"$err_file"; return 1 ;;
  esac
  if ! ff_gh_resolve_repo "$repo_spec" "$cwd"; then
    printf '%s\n' "リポジトリ（owner/repo）を解決できないため REST API で Issue を取得できません" >"$err_file"
    return 1
  fi
  raw="$(_ff_gh_api "repos/${_ff_gh_resolved_repo}/issues/${num}" "$err_file")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object" and (.number | type == "number") and has("body") and (.body == null or (.body | type == "string")) and (.state | type == "string")' >/dev/null 2>&1; then
    printf '%s\n' "REST API の Issue 応答を解釈できません" >"$err_file"
    return 1
  fi
  printf '%s' "$raw" | jq -c '{body: .body, state: (.state | ascii_upcase)}'
}

ff_gh_rest_issue_comments() { # <num> <repo_spec> <cwd> <err_file>
  local num="${1:-}" repo_spec="${2:-}" cwd="${3:-.}" err_file="${4:-/dev/null}"
  local tmp_dir="" page=1 max_pages=10 page_pad="" page_file="" norm_file="" page_len="" complete=0 jq_rc=0
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "jq が見つからないため REST API コメント応答を解釈できません" >"$err_file"; return 1; }
  case "$num" in
    ''|*[!0-9]*) printf '%s\n' "Issue 番号が数字ではありません: ${num}" >"$err_file"; return 1 ;;
  esac
  if ! ff_gh_resolve_repo "$repo_spec" "$cwd"; then
    printf '%s\n' "リポジトリ（owner/repo）を解決できないため REST API でコメントを取得できません" >"$err_file"
    return 1
  fi
  tmp_dir="$(mktemp -d)" || { printf '%s\n' "一時ディレクトリを作成できません" >"$err_file"; return 1; }
  while [ "$page" -le "$max_pages" ]; do
    printf -v page_pad '%04d' "$page"
    page_file="${tmp_dir}/page-${page_pad}.raw"
    norm_file="${tmp_dir}/norm-${page_pad}.json"
    if ! _ff_gh_api "repos/${_ff_gh_resolved_repo}/issues/${num}/comments?per_page=100&page=${page}" "$err_file" >"$page_file"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! jq -e 'type == "array"' "$page_file" >/dev/null 2>&1; then
      printf '%s\n' "REST API のコメント応答が配列ではありません" >"$err_file"
      rm -rf "$tmp_dir"
      return 1
    fi
    page_len="$(jq -r 'length' "$page_file" 2>"$err_file")" || { [ -s "$err_file" ] || printf '%s\n' "REST API のコメント件数を読めません" >"$err_file"; rm -rf "$tmp_dir"; return 1; }
    page_len="${page_len//$'\r'/}"
    jq -c '[.[] | {body: (.body // "")}]' "$page_file" >"$norm_file" 2>"$err_file" || { [ -s "$err_file" ] || printf '%s\n' "REST API のコメント整形に失敗しました" >"$err_file"; rm -rf "$tmp_dir"; return 1; }
    if [ "$page_len" -lt 100 ]; then
      complete=1
      break
    fi
    page=$((page + 1))
  done
  if [ "$complete" -ne 1 ]; then
    printf '%s\n' "REST API のコメント一覧が走査上限（${max_pages} ページ）に達したため完全な一覧を確認できません" >"$err_file"
    rm -rf "$tmp_dir"
    return 1
  fi
  jq -cs '{comments: add}' "${tmp_dir}"/norm-*.json 2>"$err_file" || jq_rc=$?
  if [ "$jq_rc" -ne 0 ] && [ ! -s "$err_file" ]; then
    printf '%s\n' "REST API のコメント一覧結合に失敗しました" >"$err_file"
  fi
  rm -rf "$tmp_dir"
  return "$jq_rc"
}

ff_gh_rest_open_issue_numbers() { # <repo> <limit> <out_file> <err_file>
  local repo="${1:-}" limit="${2:-1000}" out_file="$3" err_file="${4:-/dev/null}"
  local tmp_dir="" page=1 max_pages=20 page_pad="" page_file="" page_len="" nums="" total=0 n=""
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "jq が見つからないため REST API で open Issue 一覧を取得できません" >"$err_file"; return 1; }
  case "$limit" in
    ''|*[!0-9]*) limit=1000 ;;
  esac
  [ "$limit" -ge 1 ] 2>/dev/null || limit=1000
  if ! ff_gh_resolve_repo "$repo" "."; then
    printf '%s\n' "リポジトリ（owner/repo）を解決できないため REST API で open Issue 一覧を取得できません: ${repo}" >"$err_file"
    return 1
  fi
  tmp_dir="$(mktemp -d)" || { printf '%s\n' "一時ディレクトリを作成できません" >"$err_file"; return 1; }
  : >"$out_file"
  while [ "$page" -le "$max_pages" ]; do
    printf -v page_pad '%04d' "$page"
    page_file="${tmp_dir}/page-${page_pad}.raw"
    if ! _ff_gh_api "repos/${_ff_gh_resolved_repo}/issues?state=open&per_page=100&page=${page}" "$err_file" >"$page_file"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! jq -e 'type == "array" and all(.[]; (.number | type == "number" and . > 0 and floor == .))' "$page_file" >/dev/null 2>&1; then
      printf '%s\n' "REST API の open Issue 一覧応答を解釈できません" >"$err_file"
      rm -rf "$tmp_dir"
      return 1
    fi
    page_len="$(jq -r 'length' "$page_file" 2>"$err_file")" || { [ -s "$err_file" ] || printf '%s\n' "REST API の open Issue 件数を読めません" >"$err_file"; rm -rf "$tmp_dir"; return 1; }
    page_len="${page_len//$'\r'/}"
    # GitHub REST /issues は PR も返すため pull_request == null で Issue のみに絞る
    nums="$(jq -r '.[] | select(.pull_request == null) | .number' "$page_file" 2>"$err_file")" || { [ -s "$err_file" ] || printf '%s\n' "REST API の open Issue 番号抽出に失敗しました" >"$err_file"; rm -rf "$tmp_dir"; return 1; }
    if [ -n "$nums" ]; then
      while IFS= read -r n || [ -n "$n" ]; do
        n="${n//$'\r'/}"
        [ -n "$n" ] || continue
        printf '%s\n' "$n" >>"$out_file"
        total=$((total + 1))
        if [ "$total" -ge "$limit" ]; then
          rm -rf "$tmp_dir"
          return 0
        fi
      done <<EOF
$nums
EOF
    fi
    if [ "$page_len" -lt 100 ]; then
      rm -rf "$tmp_dir"
      return 0
    fi
    page=$((page + 1))
  done
  # ページ走査上限に達して末尾へ到達できなかった場合は取りこぼし防止のため fail-closed
  printf '%s\n' "REST API の open Issue 一覧が走査上限（${max_pages} ページ）に達したため完全な一覧を確認できません" >"$err_file"
  rm -rf "$tmp_dir"
  return 1
}

ff_gh_github_input_hint() { # <cleanup|precheck|lookup>
  local ctx="${1:-cleanup}"
  case "$ctx" in
    precheck)
      printf '%s' 'GitHub MCP や gh api 等で取得・正規化した JSON をファイルへ保存し（必須: finish.precheck.repo [nameWithOwner / url]・finish.precheck.pr [phase: initial / after-threads]・finish.precheck.threads [phase: after-checks]、必要に応じ finish.precheck.issue-body / finish.precheck.issue-comments / finish.precheck.checks-retry — 契約詳細は skills/close-issue/references/merge-gate.md）、index JSON（{"version":1,"responses":[{"operation":"finish.precheck.repo","scope":{"repository":"https://github.com/<owner>/<repo>"},"phase":"initial","body":"repo.json"},{"operation":"finish.precheck.pr","scope":{"repository":"https://github.com/<owner>/<repo>","pr":<PR番号>},"phase":"initial","body":"pr-initial.json"},{"operation":"finish.precheck.threads","scope":{"repository":"https://github.com/<owner>/<repo>","pr":<PR番号>,"first":100,"comments_first":100},"phase":"after-checks","body":"threads.json"},{"operation":"finish.precheck.pr","scope":{"repository":"https://github.com/<owner>/<repo>","pr":<PR番号>},"phase":"after-threads","body":"pr-after.json"}]}）を組み立てて --github-input /absolute/path/to/index.json で再実行してください'
      ;;
    lookup)
      printf '%s' 'GitHub MCP や gh api 等で open Issue 一覧（各要素に number を持つ JSON 配列、PR は除外）を保存し、index JSON（{"version":1,"responses":[{"operation":"lookup.open-set","scope":{"repository":"https://github.com/<owner>/<repo>","state":"open","limit":1000},"phase":"lookup","last":true,"body":"open-issues.json"}]}）を組み立てて --github-input /absolute/path/to/index.json で再実行してください'
      ;;
    *)
      printf '%s' 'GitHub MCP や gh api 等で取得した JSON を gh pr view/list 相当の契約フィールドへ正規化して保存し（cleanup.pr の pr.json は state/headRefName/headRefOid/baseRefName/title/isCrossRepository が必須。gh api の生応答は不可）、index JSON（{"version":1,"responses":[{"operation":"finish.cleanup.state","scope":{"repository":"https://github.com/<owner>/<repo>","pr":<PR番号>},"phase":"cleanup-state","body":"state.json"},{"operation":"cleanup.pr","scope":{"repository":"https://github.com/<owner>/<repo>","pr":<PR番号>},"phase":"cleanup-pr","body":"pr.json"},{"operation":"cleanup.merged-list","scope":{"repository":"https://github.com/<owner>/<repo>","state":"merged","limit":1000},"phase":"cleanup-guards","last":true,"body":"merged.json"},{"operation":"cleanup.open-list","scope":{"repository":"https://github.com/<owner>/<repo>","state":"open","limit":1000},"phase":"cleanup-guards","last":true,"body":"open.json"}]}）を組み立てて --github-input /absolute/path/to/index.json で再実行してください'
      ;;
  esac
}

# merge-cleanup.sh が構成ファイルの読み込み完了を確かめる印（最後の行に置く）
_mc_part_loaded="gh-rest-fallback.sh"
