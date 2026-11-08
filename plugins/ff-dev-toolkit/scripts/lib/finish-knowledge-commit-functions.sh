#!/usr/bin/env bash
# finish.sh の knowledge-commit 構成ファイル。入口が bundled / shebang を検査して source する。
# 関数の定義を置き、読み込み完了は末尾の sentinel で確認する。bash 3.2 互換。
# pipefail-inherited: finish.sh が set -uo pipefail の下で source する
# finish.sh が source 前に代入する名前は、値を変えずに束ね直す（未設定だけ空。
# need_repo と finish_file_init が repo_root / github_tmp を上書きする）。

if [[ "${_finish_kc_loading:-}" != "1" ]]; then
  echo "finish-knowledge-commit-functions.sh は finish.sh knowledge-commit から読み込んでください" >&2
  exit 2
fi

# shellcheck disable=SC2154
github_tmp="${github_tmp-}"
# shellcheck disable=SC2154
repo_root="${repo_root-}"
# shellcheck disable=SC2154
plugin_root="${plugin_root-}"
# shellcheck disable=SC2154
self_dir="${self_dir-}"

# ── knowledge-commit ──────────────────────────────────────────────────────────
kc_default_branch() { # → default branch 名（origin/HEAD から）
  local default_ref
  default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
    || die_env "origin/HEAD を解決できません" "git remote set-head origin --auto を実行してから再実行する"
  [[ "$default_ref" == origin/* ]] || die_env "origin/HEAD が不正です: ${default_ref}" "git remote set-head origin --auto を実行してから再実行する"
  printf '%s' "${default_ref#origin/}"
}

# 「まとめて」モード（ADR-083）の関数を読み込む。設定・記録の読み書きは lib/knowledge-delivery-functions.sh、
# target / push / flush の本体は lib/finish-knowledge-batch-functions.sh、merge commit の直前の合成 identity
# 判定は lib/commit-identity-functions.sh（knowledge-commit.sh の commit と同じ判定）。
kc_load_batch() {
  [[ "${_finish_kc_batch_loaded:-0}" != "1" ]] || return 0
  local lib
  for lib in lib/knowledge-delivery-functions.sh lib/commit-identity-functions.sh lib/finish-knowledge-batch-functions.sh; do
    need_bundled "$lib"
    assert_bundled_shebang_lf "$plugin_root/scripts/$lib"
  done
  # shellcheck source=lib/knowledge-delivery-functions.sh
  . "$plugin_root/scripts/lib/knowledge-delivery-functions.sh" || die_env "反映先の判定 lib を読み込めません" "ff-dev-toolkit を再導入してから skill を呼び直す"
  # shellcheck source=lib/commit-identity-functions.sh
  . "$plugin_root/scripts/lib/commit-identity-functions.sh" || die_env "identity 判定 lib を読み込めません" "ff-dev-toolkit を再導入してから skill を呼び直す"
  _finish_kc_batch_loading=1; _finish_kc_batch_loaded=0
  # shellcheck source=lib/finish-knowledge-batch-functions.sh
  . "$plugin_root/scripts/lib/finish-knowledge-batch-functions.sh" || die_env "まとめるモードの構成ファイルを読み込めません" "ff-dev-toolkit を再導入してから skill を呼び直す"
  [[ "$_finish_kc_batch_loaded" == "1" ]] || die_env "まとめるモードの構成ファイルの読み込みが完了していません" "ff-dev-toolkit を再導入してから skill を呼び直す"
  unset _finish_kc_batch_loading
}

# probe の前段: 手元の origin/<default> 追跡 ref（fetch しない。マージごとの probe の通信を増やさない）の
# 設定が batch のときだけ target で起点へ移り、`protection=batch` を出す。0 = 処理した / 1 = マージごと
kc_probe_batch() {
  local default_ref default
  default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || return 1
  [[ "$default_ref" == origin/* ]] || return 1
  default="${default_ref#origin/}"
  kc_load_batch
  ff_kd_load "$repo_root" "$default" \
    || die_env "反映の設定（${KD_CONF_REL}）を読めないか不正です（上の knowledge-delivery: 行）" "origin/${default} の ${KD_CONF_REL} を直してから再実行する"
  [[ "$KD_MODE" == batch ]] || return 1
  kc_target probe || return 1
  echo "protection=batch (default_branch=${default}, staging=${KD_STAGING})"
  return 0
}

kc_file_probe() {
  local default_branch owner_repo="" protection="unknown" classic="unknown" rulesets="unknown" classic_out
  default_branch="$(kc_default_branch)" || return 2
  if [[ -n "$github_repository" ]] && jq -n --arg repository "$github_repository" '{repository:$repository}' >"$github_tmp/scope.json" \
    && github_file_read "$github_input" knowledge.repo "$github_tmp/scope.json" probe "$github_tmp/position.json" >"$github_tmp/repo.json" 2>/dev/null \
    && jq -e --arg expected "${github_repository#*://*/}" '.nameWithOwner == $expected' "$github_tmp/repo.json" >/dev/null; then
    owner_repo="$(jq -r .nameWithOwner "$github_tmp/repo.json")"
  fi
  if [[ -n "$owner_repo" ]] && jq -n --arg repository "$github_repository" --arg branch "$default_branch" '{repository:$repository,branch:$branch}' >"$github_tmp/scope.json"; then
    # The direct call preserves a recognized HTTP status; error text is not a status.
    if github_file_read "$github_input" knowledge.classic-protection "$github_tmp/scope.json" probe "$github_tmp/position.json" >"$github_tmp/classic.json" 2>/dev/null; then
      if [[ "$GITHUB_INPUT_HTTP_STATUS" == 404 ]]; then
        classic="none"
      elif [[ "$GITHUB_INPUT_HTTP_STATUS" == 200 ]] && jq -e '
        type == "object" and has("required_pull_request_reviews") and has("required_status_checks") and has("restrictions") and
        all(.required_pull_request_reviews, .required_status_checks, .restrictions; . == null or type == "object") and
        (.required_signatures.enabled | type == "boolean") and (.lock_branch.enabled | type == "boolean")
      ' "$github_tmp/classic.json" >/dev/null; then
        classic_out="$(jq -r '([.required_pull_request_reviews, .required_status_checks, .restrictions] | any(. != null)) or (.required_signatures.enabled // false) or (.lock_branch.enabled // false)' "$github_tmp/classic.json")"
        case "$classic_out" in true) classic="protected" ;; false) classic="protected-no-pr" ;; esac
      fi
    fi
    if [[ "$classic" != protected ]] \
      && github_file_read "$github_input" knowledge.rulesets "$github_tmp/scope.json" probe "$github_tmp/position.json" >"$github_tmp/rules.json" 2>/dev/null \
      && [[ "$GITHUB_INPUT_LAST" == true && ( -z "$GITHUB_INPUT_HTTP_STATUS" || "$GITHUB_INPUT_HTTP_STATUS" == 200 ) ]] \
      && jq -e 'type == "array" and all(.[]; .type | type == "string")' "$github_tmp/rules.json" >/dev/null; then
      if jq -e 'any(.[]; .type == "pull_request")' "$github_tmp/rules.json" >/dev/null; then rulesets="protected"; else rulesets="none"; fi
    fi
    if [[ "$classic" == protected || "$rulesets" == protected ]]; then
      protection="protected"
    elif [[ ( "$classic" == none || "$classic" == protected-no-pr ) && "$rulesets" == none ]]; then
      protection="unprotected"
    fi
  fi
  echo "protection=${protection} (default_branch=${default_branch}, classic=${classic}, rulesets=${rulesets})"
}

kc_probe() {
  if kc_probe_batch; then return 0; fi
  if [[ -n "$github_input" ]]; then kc_file_probe; return $?; fi
  # gh は任意依存: 無ければ API を呼ばず protection=unknown（既定の直 push を試し、拒否されたら PR 経由）
  command -v gh >/dev/null 2>&1 || echo "ℹ️  gh が無いため保護判定は unknown（既定を試し、push が拒否されたら PR 経由へ）" >&2
  # ff-ace-protection-probe:start
  default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" || { echo "origin/HEAD を解決できません。git remote set-head origin --auto 後に再実行してください" >&2; exit 1; }
  [[ "$default_ref" == origin/* ]] || { echo "origin/HEAD が不正です" >&2; exit 1; }
  default_branch="${default_ref#origin/}"
  owner_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || owner_repo=""
  protection="unknown"
  if [[ -n "$owner_repo" ]]; then
    # classic branch protection API: 404 は「classic ルールが無い」を意味するだけで、
    # Rulesets のみで保護されたブランチでもここは 404 を返す。404 だけで unprotected を
    # 確定させず、必ず rulesets API も確認してから最終判定する。
    # 代入行を単独の simple command にすると set -e 下で失敗時に次行の $? 取得へ
    # 到達できず無音で中断するため（実測）、代入自体を && / || で分岐させて安全にする。
    # 200 でも直 push を PR 必須にするとは限らない（force push の禁止だけの保護は直 push が通る）。
    # 直 push を止める項目 — required_pull_request_reviews / required_status_checks /
    # restrictions（未設定は応答に現れず jq では null）と、署名必須・読み取り専用
    # （required_signatures / lock_branch は `{enabled: false}` の形で返るので .enabled を読む）—
    # のどれかがあるときだけ protected とし、どれも無ければ protected-no-pr として rulesets の
    # 判定へ進む。中身を読めない回（jq の結果が true / false 以外）は unknown に倒す（既定を試し拒否で切替）。
    classic="unknown"
    classic_out="$(gh api "repos/${owner_repo}/branches/${default_branch}/protection" --jq '([.required_pull_request_reviews, .required_status_checks, .restrictions] | any(. != null)) or (.required_signatures.enabled // false) or (.lock_branch.enabled // false)' 2>&1)" && classic_rc=0 || classic_rc=$?
    if [[ "$classic_rc" -eq 0 ]]; then
      if [[ "$classic_out" == "true" ]]; then
        classic="protected"
      elif [[ "$classic_out" == "false" ]]; then
        classic="protected-no-pr"
      fi
    elif [[ "$classic_out" == *404* ]]; then
      classic="none"
    fi
    rulesets="unknown"
    if [[ "$classic" != "protected" ]]; then
      # rulesets は non_fast_forward（force push 禁止）・required_signatures 等、直 push
      # 自体は禁止しない type も返す。実際に直 push を PR 必須にする pull_request type の
      # 有無だけを見る（そうしないと force-push 禁止だけの一般的なリポジトリで既定の
      # 直 push が黙って PR 経由へ落ちる）。
      rules_pr_required="$(gh api "repos/${owner_repo}/rules/branches/${default_branch}" --jq 'any(.[]; .type == "pull_request")' 2>/dev/null)" && rules_rc=0 || rules_rc=$?
      if [[ "$rules_rc" -eq 0 ]]; then
        if [[ "$rules_pr_required" == "true" ]]; then
          rulesets="protected"
        else
          rulesets="none"
        fi
      fi
    fi
    if [[ "$classic" == "protected" || "$rulesets" == "protected" ]]; then
      protection="protected"
    elif [[ ( "$classic" == "none" || "$classic" == "protected-no-pr" ) && "$rulesets" == "none" ]]; then
      protection="unprotected"
    fi
  fi
  echo "protection=${protection} (default_branch=${default_branch}, classic=${classic:-n/a}, rulesets=${rulesets:-n/a})"
  # ff-ace-protection-probe:end
}

# 送信範囲の実測（直 push / PR 経由の共通）: default branch に無関係な未 push コミットがあると、
# 同じ push（PR 経由なら同じ PR ブランチ）で一緒に送られる。fetch 後に origin/<default>..HEAD が
# knowledge コミット 1 つだけであることを、ブランチ作成・push より前に確かめる。直 push は
# fast-forward も要る（PR 経由は origin が先行していても PR 側で取り込めるので要らない）
kc_assert_scope() { # <default branch> <出力キー> <fast-forward 必須: 1|0>
  local d="$1" key="$2" need_ff="$3" remote_tip ahead
  git fetch -q origin "+refs/heads/${d}:refs/remotes/origin/${d}" \
    || die_env "origin/${d} を取得できません（送信範囲を判定できない）" "認証・通信・remote 設定を確かめて finish.sh knowledge-commit を再実行する"
  remote_tip="$(git rev-parse --verify --quiet "refs/remotes/origin/${d}")" \
    || die_env "origin/${d} を解決できません" "次を実行してから再実行する: $(ff_shell_argv git fetch origin "$d")"
  if [[ "$need_ff" -eq 1 ]] && ! git merge-base --is-ancestor "$remote_tip" HEAD; then
    echo "${key}=rejected"
    die_stop "origin/${d} が先行しています（non-fast-forward）" "取り込んで記録内容を作り直し、再度 add → commit → push する（--force / --force-with-lease で上書きしない）"
  fi
  ahead="$(git rev-list --count "${remote_tip}..HEAD")" || die_env "送信範囲を数えられません" "git rev-list origin/${d}..HEAD を手で確かめる"
  if [[ "$ahead" -ne 1 ]]; then
    echo "${key}=scope-mismatch"
    die_env "送信範囲が knowledge コミット単独ではありません（origin/${d}..HEAD = ${ahead} コミット: $(git log --format='%h %s' "${remote_tip}..HEAD" | tr '\n' ';')）" "無関係なコミットを退避してから再実行する（git branch <退避名> HEAD~1 → git reset --hard origin/${d} → 知見の add → commit をやり直してから push / pr）。0 件なら送るものが無い（commit ができているか status で確かめる）"
  fi
  return 0
}

kc_push() {
  local default_branch current_branch push_refspec push_log pushed_sha state_rc=0
  kc_load_batch
  ff_kd_state_read "$repo_root" || state_rc=$?
  case "$state_rc" in
    0) kc_push_batch; return $? ;;
    1) ;;
    *) die_env "書き込み先の記録（$(ff_kd_state_path "$repo_root")）を読めません" "finish.sh knowledge-commit discard で記録を消し、元のブランチへ戻ってから target をやり直す" ;;
  esac
  default_branch="$(kc_default_branch)" || exit 2
  # コミット先ブランチの実測ガード: merge-cleanup の退避などで detached HEAD のまま
  # `git push origin <branch>` を打つと、ローカル branch ref が送られ「Everything up-to-date」で
  # 成功に見えたまま手元の knowledge コミットが届かない
  current_branch="$(git symbolic-ref -q --short HEAD)" || current_branch=""
  if [[ -z "${current_branch}" ]]; then
    echo "detached HEAD のため push refspec を HEAD:${default_branch} 形式にします" >&2
    push_refspec="HEAD:${default_branch}"
  elif [[ "${current_branch}" != "${default_branch}" ]]; then
    die_env "現在のブランチ ${current_branch} は ${default_branch} ではありません（直 push の前提と不一致）" "git switch ${default_branch} してから再実行するか、PR 経由（finish.sh knowledge-commit pr）へ切り替える"
  else
    push_refspec="${default_branch}"
  fi
  kc_assert_scope "${default_branch}" KNOWLEDGE_PUSH 1
  # 設定がまとめるモードなら base へ直接 push しない（kc_assert_scope が origin/<default> を取得済み）
  kc_batch_guard "${default_branch}" "push"
  # push 出力を実測する: 終了コードと出力の両方を見る。パイプで tee へ流すと push の終了コードが
  # 失われ、non-fast-forward の rejected 出力（`-> branch` を含む）を成功と誤読するため、
  # ファイルへ落としてから照合する。「Everything up-to-date」は失敗の兆候（何も送っていない）
  push_log="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
  if ! git push origin "${push_refspec}" >"${push_log}" 2>&1; then
    cat "${push_log}"
    # 保護判定が unknown だった、または判定後に設定が変わった TOCTOU の受け皿。拒否理由が
    # 保護ルールなら PR 経由へ切り替える（commit はできているので再 stage・再 commit はしない）
    # classic 保護による拒否全般（GH006 `Protected branch update failed`。必須チェック
    # `Required status check "<名>" is failing` や署名必須もこの行を伴う）と push の制限
    # （`not authorized to push`）による拒否も PR 経由へ寄せる（probe の判定が外れた回の安全網）
    if awk 'index($0, "Changes must be made through a pull request") || index($0, "push declined due to repository rule violations") || index($0, "Protected branch update failed") || index($0, "Required status check") || index($0, "not authorized to push") { f = 1 } END { exit f ? 0 : 1 }' "${push_log}"; then
      rm -f "${push_log}"
      echo "KNOWLEDGE_PUSH=protected"
      echo "✗ push が保護ルールで拒否されました（default branch が保護されています）。finish.sh knowledge-commit pr --branch <名> --title <件名> で PR 経由へ切り替える（commit は残っている）" >&2
      exit 3
    fi
    rm -f "${push_log}"
    echo "KNOWLEDGE_PUSH=rejected"
    echo "✗ push が失敗しました（non-fast-forward なら取り込んで記録内容を作り直し、再度 add → commit → push する）" >&2
    exit 1
  fi
  cat "${push_log}"
  if ! awk -v n="-> ${default_branch}" 'index($0, n) { f = 1 } END { exit f ? 0 : 1 }' "${push_log}"; then
    rm -f "${push_log}"
    echo "KNOWLEDGE_PUSH=not-delivered"
    echo "✗ push 出力に -> ${default_branch} が無く、コミットが届いていません（detached HEAD や参照ずれを疑う）" >&2
    exit 1
  fi
  rm -f "${push_log}"
  pushed_sha="$(git rev-parse HEAD)"
  echo "KNOWLEDGE_PUSH=ok"
  echo "KNOWLEDGE_PUSHED_SHA=${pushed_sha}"
  # 直 push は PR 画面に出ないので、今 push した SHA の CI run を見に行く（headSha が一致する run を
  # 探す。in_progress / queued は完了を待って再確認し、failure なら revert ではなく前進で直す）
  if [[ -n "$github_input" ]]; then
    if [[ -n "$github_repository" ]] && jq -n --arg repository "$github_repository" --arg branch "$default_branch" --arg sha "$pushed_sha" '{repository:$repository,branch:$branch,limit:5,pushed_sha:$sha}' >"$github_tmp/scope.json" \
      && github_file_read "$github_input" knowledge.ci "$github_tmp/scope.json" after-push "$github_tmp/position.json" >"$github_tmp/ci.json" 2>/dev/null \
      && [[ "$GITHUB_INPUT_LAST" == true && ( -z "$GITHUB_INPUT_HTTP_STATUS" || "$GITHUB_INPUT_HTTP_STATUS" == 200 ) ]] \
      && jq -e 'type == "array" and length <= 5 and all(.[]; has("conclusion") and (.conclusion == null or (.conclusion | type == "string")) and
        (.status | type == "string") and (.workflowName | type == "string") and (.headSha | type == "string" and test("^[0-9a-fA-F]{40}$")))' "$github_tmp/ci.json" >/dev/null; then
      jq -r --arg sha "$pushed_sha" '.[] | "KNOWLEDGE_CI=" + (.workflowName // "?") + "\t" + (.status // "?") + "\t" + (.conclusion // "-") + "\t" + (if .headSha == $sha then "this-push" else "other" end)' "$github_tmp/ci.json" \
        || echo "KNOWLEDGE_CI=(unavailable)"
    else
      echo "KNOWLEDGE_CI=(unavailable)"
    fi
  elif command -v gh >/dev/null 2>&1; then
    gh run list --branch "${default_branch}" --limit 5 --json status,conclusion,workflowName,headSha 2>/dev/null \
      | jq -r --arg sha "$pushed_sha" '.[] | "KNOWLEDGE_CI=" + (.workflowName // "?") + "\t" + (.status // "?") + "\t" + (.conclusion // "-") + "\t" + (if .headSha == $sha then "this-push" else "other" end)' 2>/dev/null \
      || echo "KNOWLEDGE_CI=(unavailable)"
  else
    echo "KNOWLEDGE_CI=(unavailable)"
  fi
  return 0
}

# default 開始時だけローカル default branch を origin へ戻す。
# 既存の知見ブランチからの実行では、default 上の別件の未 push commit を変更しない。
# 戻せない回（別 worktree が保持している等）は残存 ref と復帰手順を出して非 0
kc_restore_default() { # <default branch> <開始 branch> → 0 / 1
  [[ "$2" == "$1" ]] || return 0
  local out remaining
  if out="$(git branch -f "$1" "origin/$1" 2>&1)"; then return 0; fi
  remaining="$(git rev-parse --verify --quiet "refs/heads/$1")" || remaining="?"
  {
    echo "✗ ローカル $1 を origin/$1 へ戻せません: ${out}"
    echo "  残存: refs/heads/$1 = ${remaining}（未 push の knowledge commit を含みうる。誤って再 push しないこと）"
    echo "  復帰: $1 を保持する worktree（git worktree list）で git switch --detach してから git branch -f $1 origin/$1 を実行する"
  } >&2
  return 1
}

kc_pr() {
  local branch="" title="" body="" default_branch current_branch upstream
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) [[ $# -ge 2 ]] || usage; branch="$2"; shift 2 ;;
      --title) [[ $# -ge 2 ]] || usage; title="$2"; shift 2 ;;
      --body) [[ $# -ge 2 ]] || usage; body="$2"; shift 2 ;;
      *) echo "✗ 不明な引数: $1" >&2; usage ;;
    esac
  done
  [[ -n "$branch" && -n "$title" ]] || usage
  [[ -n "$github_input" ]] || need_cmd gh "gh をインストールして gh auth login を済ませる"
  default_branch="$(kc_default_branch)" || exit 2
  # まとめるモードでは知見 PR を作らない（知見は staging へ push し、base への反映は flush）
  kc_load_batch
  local st_rc=0
  ff_kd_state_read "$repo_root" || st_rc=$?
  case "$st_rc" in
    0) die_stop "まとめるモードの書き込み中です（target の記録がある）" "finish.sh knowledge-commit push で ${KD_ST_STAGING} へ送る（PR は作らない）" ;;
    1) ;;
    *) die_env "書き込み先の記録（$(ff_kd_state_path "$repo_root")）を読めません" "finish.sh knowledge-commit discard で記録を消してから再実行する" ;;
  esac
  # 設定は fetch した後の origin/<default> で判定する（古い追跡 ref のままだと、base へ入った batch を見落とす）
  kc_fetch_branch "${default_branch}"
  kc_batch_guard "${default_branch}" "PR を作成"
  current_branch="$(git symbolic-ref -q --short HEAD)" || current_branch=""
  if [[ "$current_branch" == "$default_branch" || "$current_branch" == "$branch" ]]; then
    # ブランチ作成・push より前に送信範囲を確かめる（無関係なコミットを PR ブランチへ載せない）
    kc_assert_scope "${default_branch}" KNOWLEDGE_PR 0
  fi
  if [[ "$current_branch" == "$default_branch" ]]; then
    # default branch 上に knowledge commit ができている（直 push が保護で拒否された回）。
    # git switch -c が失敗した場合はまだ default branch 上にいるため、branch -f は行わない
    git switch -c "$branch" || die_env "PR 経由ブランチの作成に失敗しました（commit は ${default_branch} 上のまま残っています）" "ブランチ名 ${branch} が既に無いか確かめて再実行する"
  elif [[ "$current_branch" != "$branch" ]]; then
    die_env "現在のブランチ ${current_branch:-（detached）} が ${default_branch} でも ${branch} でもありません" "knowledge commit を作ったブランチ上で再実行する"
  fi
  # ここから下は失敗時も commit が PR ブランチに残る。
  # default 開始時だけ復帰させる。判定には switch 前の current_branch を使う。
  if ! git push -u origin HEAD; then
    kc_restore_default "${default_branch}" "${current_branch}"
    die_env "PR 経由ブランチの push に失敗しました（commit は ${branch} に残っています）" "認証・通信を確かめて finish.sh knowledge-commit pr を再実行する"
  fi
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=""
  if [[ "$upstream" != "origin/${branch}" ]]; then
    kc_restore_default "${default_branch}" "${current_branch}"
    die_env "upstream が想定と異なります（期待: origin/${branch} / 実際: ${upstream:-（無し）}）" "git push -u origin ${branch} で upstream を揃えて再実行する"
  fi
  local pr_url pushed_sha
  if [[ -n "$github_input" ]]; then
    pushed_sha="$(git rev-parse HEAD)" || return 2
    jq -n --arg repository "$github_repository" '{repository:$repository}' >"$github_tmp/scope.json" || return 2
    jq -n --arg head "$branch" --arg base "$default_branch" --arg title "$title" --arg body "${body:-knowledge の追記}" --arg sha "$pushed_sha" \
      '{head:$head,base:$base,title:$title,body:$body,head_sha:$sha}' >"$github_tmp/arguments.json" || return 2
    jq -n --arg repository "$github_repository" --slurpfile a "$github_tmp/arguments.json" \
      '{operation:"knowledge.pr-create",phase:"after-write",expect:{repository:$repository,state:"OPEN",headRefName:$a[0].head,baseRefName:$a[0].base,title:$a[0].title,body:$a[0].body,headRefOid:$a[0].head_sha},returned:["number","url"]}' >"$github_tmp/readback.json" || return 2
    if github_file_read "$github_input" knowledge.pr-create "$github_tmp/scope.json" after-write "$github_tmp/position.json" >"$github_tmp/pr-readback.json" 2>/dev/null \
      && [[ -z "$GITHUB_INPUT_HTTP_STATUS" || "$GITHUB_INPUT_HTTP_STATUS" == 200 ]] \
      && jq -e --arg repository "$github_repository" --slurpfile a "$github_tmp/arguments.json" '
        (.number | type == "number" and . > 0 and floor == .) and
        (.url == ($repository + "/pull/" + (.number | tostring))) and .state == "OPEN" and
        .headRefName == $a[0].head and .baseRefName == $a[0].base and .headRefOid == $a[0].head_sha and
        .title == $a[0].title and .body == $a[0].body
      ' "$github_tmp/pr-readback.json" >/dev/null; then
      pr_url="$(jq -r .url "$github_tmp/pr-readback.json")"
    else
      _github_input_error knowledge.pr-create 'external PR creation and matching fresh read-back required; no completion yet'
      github_file_plan knowledge.pr-create "$github_tmp/scope.json" "$github_tmp/arguments.json" "$github_tmp/readback.json" || true
      if ! kc_restore_default "${default_branch}" "${current_branch}"; then echo "KNOWLEDGE_DEFAULT_RESTORE=failed"; return 1; fi
      return 2
    fi
  elif ! pr_url="$(gh pr create --base "${default_branch}" --title "${title}" --body "${body:-knowledge の追記}")"; then
    kc_restore_default "${default_branch}" "${current_branch}"
    die_env "PR 作成に失敗しました（commit は push 済みの ${branch} に残っています）" "gh pr create --base ${default_branch} --head ${branch} を手で実行する"
  fi
  echo "KNOWLEDGE_PR=${pr_url}"
  echo "KNOWLEDGE_PR_BRANCH=${branch}"
  if ! kc_restore_default "${default_branch}" "${current_branch}"; then
    echo "KNOWLEDGE_DEFAULT_RESTORE=failed"
    exit 1
  fi
  if [[ "$current_branch" == "$default_branch" ]]; then
    echo "KNOWLEDGE_DEFAULT_RESTORE=ok"
  else
    echo "KNOWLEDGE_DEFAULT_RESTORE=skipped"
  fi
  return 0
}

# `add --ace-playbook <PLAYBOOK>`: /ace-curate のコミット手順がスキル本文の fence で組み立てていた記録パスと
# claim の有無をここで決める（Issue `#2454`）。fence で lib/playbook-changelog-functions.sh を source すると、
# Bash ツールの対話シェルが zsh の回は BASH_SOURCE が空になり、隣の reader を探せず止まる。記録するのは
# PLAYBOOK・選択した Changelog（PLAYBOOK と別のファイルで、変更か未追跡のとき）・同階層 playbook/ の変更と
# 未追跡・PENDING_CANDIDATES.md（在るとき）。PLAYBOOK が HEAD から変わったときだけ同じ文書の --claim を足す
# （保留候補だけの回は claim を再生成しない）。kc_add の local（pathspecs / claim_docs）へ追記する
kc_ace_playbook_collect() { # <PLAYBOOK>
  local book="$1" book_abs book_dir book_top book_prefix book_rel changelog changelog_rel rc doc listing kpath
  [[ -n "$book" ]] || die_env "--ace-playbook の PLAYBOOK パスが空です" "解決済みの PLAYBOOK パスを渡す"
  need_bundled lib/abs-path.sh
  need_bundled lib/git-literal-pathspec.sh
  need_bundled lib/playbook-changelog-functions.sh
  need_bundled lib/knowledge-read-boundary.sh
  # shellcheck source=lib/abs-path.sh
  . "$self_dir/lib/abs-path.sh" || die_env "絶対パスの判定 lib を読めません: $self_dir/lib/abs-path.sh" "ff-dev-toolkit を再導入してから skill を呼び直す"
  assert_bundled_shebang_lf "$self_dir/lib/git-literal-pathspec.sh"
  # shellcheck source=lib/git-literal-pathspec.sh
  . "$self_dir/lib/git-literal-pathspec.sh" || die_env "literal Git lib を読めません" "plugin の同梱 lib を確かめる"
  assert_bundled_shebang_lf "$self_dir/lib/playbook-changelog-functions.sh"
  # shellcheck source=lib/playbook-changelog-functions.sh
  . "$self_dir/lib/playbook-changelog-functions.sh" || die_env "PLAYBOOK Changelog 判定 lib を読めません" "plugin の同梱 lib を確かめる"
  if ff_path_is_absolute "$book"; then book_abs="$book"; else book_abs="$PWD/$book"; fi
  [[ -f "$book_abs" && ! -L "$book_abs" ]] || die_env "PLAYBOOK が無いか symlink です: ${book}" "解決済みの PLAYBOOK パスを渡す"
  book_dir="${book_abs%/*}"
  book_top="$(git -C "$book_dir" rev-parse --show-toplevel 2>/dev/null)" \
    && book_top="$(CDPATH='' cd -P -- "$book_top" && pwd -P)" && [[ "$book_top" == "$repo_root" ]] \
    || die_env "PLAYBOOK が作業中のリポジトリの外です: ${book}" "対象リポジトリの PLAYBOOK を渡す"
  book_prefix="$(git -C "$book_dir" rev-parse --show-prefix)" || die_env "PLAYBOOK のリポジトリ位置を確認できません: ${book}" "作業ツリーの実体パスで再実行する"
  book_rel="${book_prefix}${book_abs##*/}"
  pathspecs+=("$repo_root/$book_rel")
  changelog="$(ff_playbook_changelog_select "$book_abs" "$repo_root")" || die_env "${changelog:-Changelog を選べません: ${book}}" "PLAYBOOK と Changelog の配置を直してから再実行する"
  changelog_rel="$(git -C "${changelog%/*}" rev-parse --show-prefix)${changelog##*/}" || die_env "Changelog のリポジトリ位置を確認できません: ${changelog}" "作業ツリーの実体パスで再実行する"
  if [[ "$changelog_rel" != "$book_rel" ]]; then
    rc=0; ff_git_literal "$repo_root" diff --quiet HEAD -- "$changelog_rel" || rc=$?
    case "$rc" in
      0) rc=0; ff_git_literal "$repo_root" ls-files --error-unmatch -- "$changelog_rel" >/dev/null 2>&1 || rc=$?
         [[ "$rc" -eq 0 ]] || pathspecs+=("$repo_root/$changelog_rel") ;;
      1) pathspecs+=("$repo_root/$changelog_rel") ;;
      *) die_env "Changelog の差分を確認できません: ${changelog_rel}" "git の状態（HEAD の有無・GIT_ICASE_PATHSPECS）を確かめて再実行する" ;;
    esac
  fi
  if [[ -d "$book_dir/playbook" ]]; then
    listing="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
    if ! ff_git_literal "$repo_root" ls-files -z -mo --exclude-standard -- "${book_prefix}playbook" >"$listing"; then
      rm -f -- "$listing"; die_env "playbook/ の変更を列挙できません: ${book_prefix}playbook" "git の状態（HEAD の有無・GIT_ICASE_PATHSPECS）を確かめて再実行する"
    fi
    while IFS= read -r -d '' kpath; do pathspecs+=("$repo_root/$kpath"); done <"$listing"
    rm -f -- "$listing"
  fi
  [[ ! -f "$book_dir/PENDING_CANDIDATES.md" ]] || pathspecs+=("$repo_root/${book_prefix}PENDING_CANDIDATES.md")
  rc=0; ff_git_literal "$repo_root" diff --quiet HEAD -- "$book_rel" || rc=$?
  case "$rc" in
    0) ;;
    1) for doc in ${claim_docs[@]+"${claim_docs[@]}"}; do [[ "$doc" != "$book_rel" ]] || return 0; done
       claim_docs+=("$book_rel") ;;
    *) die_env "PLAYBOOK の差分を確認できません: ${book_rel}" "git の状態（HEAD の有無・GIT_ICASE_PATHSPECS）を確かめて再実行する" ;;
  esac
  return 0
}

kc_add() {
  # `--` より前（書き込み口のオプションと値）と後（明示 pathspec）を別配列に分ける。オプションの値
  # （--category docs 等）を path と取り違えて stage しないため
  local claim_docs=() args=() pathspecs=() file_args=() default_branch doc ace_playbook="" claim_base="" claim_pin=()
  [[ -z "$github_input" ]] || file_args=(--github-input "$github_input")
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --claim) [[ $# -ge 2 ]] || usage; claim_docs+=("$2"); shift 2 ;;
      --ace-playbook) [[ $# -ge 2 ]] || usage; ace_playbook="$2"; shift 2 ;;
      --) shift; pathspecs=("$@"); break ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [[ -z "$ace_playbook" ]] || kc_ace_playbook_collect "$ace_playbook"
  if [[ ${#claim_docs[@]} -gt 0 && -d "$repo_root/.version-claims" ]]; then
    # default branch の鮮度は claim の再生成・stage より前に確かめる（遅れていれば何も変えずに止まる。
    # claim の無い add は書き込み口の add 自身が先頭で同じ検査をする）
    assert_bundled_shebang_lf "${plugin_root}/scripts/knowledge-commit.sh"
    FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" freshness || return $?
    need_bundled update-version-claim.sh
    need_bundled check-version-claims.sh
    default_branch="$(kc_default_branch)" || exit 2
    # まとめるモードの書き込み中は、起点を決めた時点の origin/<default> を claim の基準に固定する
    # （起点の後に base が進んでも、追記は起点のツリーで作っている。進んだ base を基準にすると
    # 検証が「base が先行」で止まり、取り込む手段も無い）
    claim_base="origin/${default_branch}"; claim_pin=()
    kc_load_batch
    if ff_kd_state_read "$repo_root"; then claim_base="$KD_ST_DEFAULT_TIP"; claim_pin=(--base-commit "$KD_ST_DEFAULT_TIP"); fi
    for doc in "${claim_docs[@]}"; do
      assert_bundled_shebang_lf "${plugin_root}/scripts/update-version-claim.sh"
      FF_DEV_TOOLKIT_ROOT="${plugin_root}" "${plugin_root}/scripts/update-version-claim.sh" --base "$claim_base" --document "$doc" \
        || die_env "version claim を再生成できません: ${doc}" "origin/${default_branch} を取り込んでから再実行する"
      [[ -f "$repo_root/.version-claims/${doc}.claim" ]] || die_env "claim が生成されていません: .version-claims/${doc}.claim" "update-version-claim.sh の出力を確かめる"
      pathspecs+=("$repo_root/.version-claims/${doc}.claim")
    done
  fi
  if [[ ${#claim_docs[@]} -gt 0 && -d "$repo_root/.version-claims" ]]; then
    # claim の検証は保留への登録より前に行う（検証が赤のとき、未検証の claim を pending / stage に残さない）。
    # 検証器は文書と claim が index に在ることを要求するので、いったん stage して検証し、赤なら
    # index の該当 entry を元に戻す（登録前に戻すので pending は増えない）
    local -a claim_paths=() ; local p index_before
    for doc in "${claim_docs[@]}"; do claim_paths+=("$doc" ".version-claims/${doc}.claim"); done
    # 明示 pathspec は cwd 相対なので絶対化してから repo root 基準の git へ渡す。絶対パスの判定は共有の
    # 1 関数（Windows の Git Bash ではドライブ文字の形も絶対。Issue `#2367`）
    need_bundled lib/abs-path.sh
    # shellcheck source=lib/abs-path.sh
    . "$self_dir/lib/abs-path.sh" || die_env "絶対パスの判定 lib を読めません: $self_dir/lib/abs-path.sh"
    need_bundled lib/git-literal-pathspec.sh
    assert_bundled_shebang_lf "$self_dir/lib/git-literal-pathspec.sh"
    # shellcheck source=lib/git-literal-pathspec.sh
    . "$self_dir/lib/git-literal-pathspec.sh" || die_env "literal Git lib を読めません" "plugin の同梱 lib を確かめる"
    for p in ${pathspecs[@]+"${pathspecs[@]}"}; do
      [[ -e "$p" ]] || continue
      if ff_path_is_absolute "$p"; then claim_paths+=("$p"); else claim_paths+=("$PWD/$p"); fi
    done
    index_before="$(ff_git_literal "$repo_root" ls-files --stage -- "${claim_paths[@]}" 2>/dev/null)" || index_before=""
    ff_git_literal "$repo_root" add -- "${claim_paths[@]}" || die_env "claim と文書を stage できません" "パスを確かめて再実行する"
    assert_bundled_shebang_lf "${plugin_root}/scripts/check-version-claims.sh"
    if ! FF_DEV_TOOLKIT_ROOT="${plugin_root}" "${plugin_root}/scripts/check-version-claims.sh" --root "$repo_root" ${claim_pin[@]+"${claim_pin[@]}"}; then
      ff_git_literal "$repo_root" reset -q -- "${claim_paths[@]}" 2>/dev/null || true
      [[ -z "$index_before" ]] || printf '%s\n' "$index_before" | git -C "$repo_root" update-index --index-info
      die_stop "version claim の検証が赤です（保留・stage は変更していません）" "claim と文書を直してから finish.sh knowledge-commit add --claim を再実行する"
    fi
  fi
  assert_bundled_shebang_lf "${plugin_root}/scripts/knowledge-commit.sh"
  FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" add ${file_args[@]+"${file_args[@]}"} ${args[@]+"${args[@]}"} -- ${pathspecs[@]+"${pathspecs[@]}"} || return $?
  return 0
}

cmd_knowledge_commit() {
  local sub="${1:-}"
  [[ -n "$sub" ]] || usage
  shift
  local args=() file_args=()
  # Preserve valued options and the -- path boundary while removing only our flag.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) args+=("$@"); break ;;
      --github-input) [[ $# -ge 2 && -n "$2" ]] || usage; github_input="$2"; shift 2 ;;
      --source|--id|--summary|--category|--type|--claim|--ace-playbook|--branch|--title|--body)
        [[ $# -ge 2 ]] || usage; args+=("$1" "$2"); shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}
  need_repo
  need_bundled knowledge-commit.sh
  if [[ -n "$github_input" ]]; then
    case "$sub" in
      add|commit|probe|push) finish_file_init optional ;;
      pr) finish_file_init ;;
      *) echo "✗ --github-input はこの pure Git サブコマンドには使いません: $sub" >&2; usage ;;
    esac
    [[ "$sub" != commit ]] || file_args=(--github-input "$github_input")
  fi
  case "$sub" in
    add) kc_add "$@" ;;
    commit|status|discard)
      assert_bundled_shebang_lf "${plugin_root}/scripts/knowledge-commit.sh"
      FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" "$sub" ${file_args[@]+"${file_args[@]}"} "$@" ;;
    probe) [[ $# -eq 0 ]] || usage; kc_probe ;;
    push) [[ $# -eq 0 ]] || usage; kc_push ;;
    pr) kc_pr "$@" ;;
    target) [[ $# -eq 0 ]] || usage; kc_load_batch; kc_target target ;;
    flush) kc_load_batch; kc_flush "$@" ;;
    *) echo "✗ 不明なサブコマンド: knowledge-commit $sub" >&2; usage ;;
  esac
}

_finish_kc_loaded=1
