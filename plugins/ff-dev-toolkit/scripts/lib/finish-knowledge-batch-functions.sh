#!/usr/bin/env bash
# finish.sh knowledge-commit の「まとめて」モード（ADR-083・Issue `#2690`）。bash 3.2 互換。
# lib/finish-knowledge-commit-functions.sh が kc_load_batch から source する。関数の定義だけを置き、
# 読み込み完了は末尾の sentinel で確認する。
#
#   target  書き込み先を決めて HEAD を起点へ移す。マージごと（既定）は何も動かさず default branch を
#           書き込み先として出す。まとめるモードは origin/<default> と origin/<staging> を取得し、
#           staging に未反映が無ければ default の先端、あれば staging と default を合わせたツリーへ
#           detached で移り、記録を git ディレクトリへ置く。合わせたツリーは `git merge-tree
#           --write-tree` で作業ツリーに触れずに作って知見の置き場の外の差分が無いことを確かめ、
#           `git commit-tree` で merge commit にしてから checkout する（検査より前に checkout も hook の
#           実行も起きない）。記録が既にある回（/ace-curate の probe の後の /retrospective）は移らず、
#           origin/<staging> が先行していないかだけを確かめる。
#   push    （まとめるモード）起点の上の知見コミット 1 つを `<staging>` へ fast-forward で送り、
#           元の場所へ戻って記録を消す。追記が 0 件なら何も送らずに戻る。base は進めない。
#   flush   origin/<staging> を origin/<default> へ取り込む merge commit を、target と同じく merge-tree と
#           commit-tree で作業ツリーに触れずに作り、検査してから base へ送る（--pr のときは使い捨ての
#           ブランチ knowledge/flush-<日時> から PR）。設定がマージごとでも staging に未反映が残っていれば
#           実行できる（戻すときの排出）。LLM の API キーや CI 専用の認証情報には依存しない（手元の git /
#           gh の通常の認証で手動実行する）。
#
# 合わせたツリーを作るので、まとめるモードは `git merge-tree --write-tree` を使える git（2.38 以上）が要る。
# 出力は既存の knowledge-commit と同じ `KEY=value` 行。マージごとの経路はこのファイルを通っても
# 出力を変えない（probe / push / pr は設定が batch のときだけここへ分岐する）。

if [[ "${_finish_kc_batch_loading:-}" != "1" ]]; then
  echo "finish-knowledge-batch-functions.sh は finish.sh knowledge-commit から読み込んでください" >&2
  exit 2
fi

kc_redact() { sed -E 's#(://)[^/[:space:]]*@#\1***@#g'; }

kc_fetch_branch() { # <branch> → 0 / die
  local out
  out="$(git fetch -q origin "+refs/heads/$1:refs/remotes/origin/$1" 2>&1)" \
    || die_env "origin/$1 を取得できません（$(printf '%s' "${out%%$'\n'*}" | kc_redact)）" "認証・通信・remote 設定を確かめて再実行する（古い値で書き込み先を決めない）"
}

# origin に staging があれば取得して sha を返す（stdout）。無ければ空を返し、古い追跡 ref を消す。
kc_fetch_staging() { # <staging>
  local staging="$1" out rc=0
  out="$(git ls-remote --exit-code origin "refs/heads/${staging}" 2>&1)" || rc=$?
  case "$rc" in
    0) kc_fetch_branch "$staging"
       git rev-parse --verify --quiet "refs/remotes/origin/${staging}^{commit}" \
         || die_env "origin/${staging} を解決できません" "git fetch origin ${staging} を確かめてから再実行する" ;;
    2) git update-ref -d "refs/remotes/origin/${staging}" 2>/dev/null || true ;;
    *) die_env "origin の ${staging} の有無を確かめられません（$(printf '%s' "${out%%$'\n'*}" | kc_redact)）" "認証・通信・remote 設定を確かめて再実行する" ;;
  esac
}

kc_batch_conf() { # <default branch> → KD_* / die
  ff_kd_load "$repo_root" "$1" \
    || die_env "反映の設定（${KD_CONF_REL}）を読めないか不正です（上の knowledge-delivery: 行）" "origin/$1 の ${KD_CONF_REL} を直してから再実行する"
}

kc_unreflected_report() { # <default> <staging>
  if ! ff_kd_unreflected "$repo_root" "$1" "$2"; then
    echo "KNOWLEDGE_UNREFLECTED=unknown"
    echo "⚠️  未反映の知見を数えられません（origin/$1..origin/$2）" >&2
    return 0
  fi
  echo "KNOWLEDGE_UNREFLECTED=${KD_UNREFLECTED}"
  [[ -z "$KD_UNREFLECTED_DAYS" ]] || echo "KNOWLEDGE_UNREFLECTED_DAYS=${KD_UNREFLECTED_DAYS}"
  if [[ -n "$KD_UNREFLECTED_DAYS" && "$KD_UNREFLECTED_DAYS" -ge "$KD_WARN_DAYS" ]]; then
    echo "⚠️  未反映の知見が ${KD_UNREFLECTED_DAYS} 日分（${KD_UNREFLECTED} コミット）溜まっています（警告の閾値 ${KD_WARN_DAYS} 日に達した）— finish.sh knowledge-commit flush で base へ反映する" >&2
  fi
}

# 元の場所へ戻る。ブランチから始めた回はそのブランチへ、detached HEAD から始めた回は元の sha へ戻る。
kc_restore_branch() { # <branch or empty> [<元の sha>] → 0 / 1（戻れなければ理由を stderr）
  local out
  if [[ -n "$1" ]]; then
    out="$(git switch -q "$1" 2>&1)" && return 0
    echo "⚠️  元のブランチ $1 へ戻れません（${out%%$'\n'*}）— 作業ツリーの状態を確かめて git switch $1 を手で実行する" >&2
    return 1
  fi
  [[ -n "${2:-}" ]] || return 0
  out="$(git switch -q --detach "$2" 2>&1)" && return 0
  echo "⚠️  元の HEAD（${2:0:12}）へ戻れません（${out%%$'\n'*}）— 作業ツリーの状態を確かめて git switch --detach $2 を手で実行する" >&2
  return 1
}

# 戻り先へ移るコマンド（案内用）。<branch or empty> <元の sha>
kc_restore_hint() {
  if [[ -n "$1" ]]; then printf 'git switch %s' "$1"; else printf 'git switch --detach %s' "$2"; fi
}

# 先行されて書き込みをやり直す手順（案内用。本体は lib/knowledge-delivery-functions.sh の ff_kd_redo_hint）
kc_redo_hint() { ff_kd_redo_hint "$repo_root" "$KD_ST_START" "$(kc_restore_hint "$KD_ST_RESTORE" "$KD_ST_ORIGIN")"; }

# staging と default を合わせたツリーを作業ツリーに触れずに作り、知見の置き場の外の差分が無いことを
# 確かめる。結果のツリーは KC_MERGED_TREE へ入れる。checkout も hook の実行もしないので、staging に
# 紛れた変更は検査より前に書き手の手元へ出ない。共通の祖先が複数ある（flush と書き込みが重なった後の
# criss-cross）場合も、git が実際に作るツリーをそのまま検査する。
# <default tip> <staging tip> <出力キー>
kc_merged_tree() {
  local out rc=0 first outside
  KC_MERGED_TREE=""
  out="$(git merge-tree --write-tree --no-messages "$1" "$2" 2>&1)" || rc=$?
  first="${out%%$'\n'*}"
  case "$rc" in
    0) ;;
    1)
      # 衝突のときだけ 1 行目がツリーの sha になる（解決できない ref 等の失敗も rc 1 で返る）
      if [[ "$first" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
        echo "$3=conflict"
        die_stop "origin/<staging> と origin/<default> を合わせると知見ファイルが衝突します（base 側で同じ知見ファイルの同じ行が変わった）" "base 側の変更を取り込んで衝突を解いた知見コミットを staging へ足す: git switch --detach origin/<staging> → git merge origin/<default> → 衝突を解く（version / ace_entry_count / Changelog は merged tree から再生成）→ git push origin HEAD:<staging> → 元の場所へ戻ってやり直す（force push はしない）"
      fi
      echo "$3=merge-failed"
      die_env "staging と default を合わせたツリーを作れません（$(printf '%s' "$first" | kc_redact)）" "git merge-tree --write-tree $1 $2 を手で確かめる" ;;
    129)
      echo "$3=merge-failed"
      die_env "この git は merge-tree --write-tree を使えません（$(git --version 2>/dev/null)）。まとめるモードは git 2.38 以上が要る" "git を 2.38 以上へ更新してから再実行する" ;;
    *)
      echo "$3=merge-failed"
      die_env "staging と default を合わせたツリーを作れません（rc=${rc}: $(printf '%s' "$first" | kc_redact)）" "git merge-tree --write-tree $1 $2 を手で確かめる" ;;
  esac
  [[ "$first" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || die_env "merge-tree の出力からツリーを読めません: ${first}" "git merge-tree --write-tree $1 $2 を手で確かめる"
  outside="$(ff_kd_paths_outside "$repo_root" "$1" "$first")" \
    || die_env "合わせたツリーの差分を列挙できません" "git diff --raw $1 $first を手で確かめる"
  if [[ -n "$outside" ]]; then
    echo "$3=outside-knowledge"
    die_stop "staging を合わせると知見の置き場（${KD_ALLOWED_PREFIXES}）の外に差分が出ます: $(printf '%s' "$outside" | tr '\n' ' ')" "checkout も merge もしない。知見以外の変更（または置き場の外へ移された知見ファイル）を確かめ、知見以外の変更を staging から取り除いてから再実行する（base 側で知見ファイルを移すときは、先に flush する）"
  fi
  KC_MERGED_TREE="$first"
}

# マージごとの経路で、設定が batch に変わっていないかを確かめる（直列化点を 2 つに割らない）。
# 追跡 ref は呼び出し側が fetch 済みであること。<default> <操作の名前>
kc_batch_guard() {
  local rc=0
  ff_kd_load "$repo_root" "$1" || rc=$?
  [[ "$rc" -eq 0 ]] || die_env "反映の設定（${KD_CONF_REL}）を読めないか不正です（上の knowledge-delivery: 行）" "origin/$1 の ${KD_CONF_REL} を直してから再実行する"
  if [[ "$KD_MODE" == batch ]]; then
    die_stop "反映の設定がまとめるモード（${KD_SOURCE}）なので、知見を $1 へ直接$2しません" "finish.sh knowledge-commit target で書き込み先（${KD_STAGING}）へ移って書き直し、push で送る。base への反映は finish.sh knowledge-commit flush"
  fi
}

kc_target_report() { # <default> <staging> <start>
  echo "KNOWLEDGE_DELIVERY=batch"
  echo "KNOWLEDGE_TARGET=$2"
  echo "KNOWLEDGE_START=$3"
  kc_unreflected_report "$1" "$2"
}

# 書き込み先を決めて起点へ移る。<呼び出し元: target|probe>
kc_target() {
  local caller="${1:-target}" default staging start_branch start_sha staging_tip default_tip start rc=0 git_dir
  default="$(kc_default_branch)" || exit 2
  kc_fetch_branch "$default"
  kc_batch_conf "$default"
  ff_kd_state_read "$repo_root" || rc=$?
  [[ "$rc" -ne 2 ]] || die_env "書き込み先の記録（$(ff_kd_state_path "$repo_root")）を読めません" "finish.sh knowledge-commit discard で記録を消し、元の場所へ戻ってから再実行する"
  if [[ "$KD_MODE" != batch ]]; then
    [[ "$rc" -ne 0 ]] || die_env "設定はマージごとですが、まとめるモードの書き込み先の記録が残っています" "finish.sh knowledge-commit discard で記録を消し、$(kc_restore_hint "$KD_ST_RESTORE" "$KD_ST_ORIGIN") で戻ってから再実行する"
    [[ "$caller" == probe ]] && return 1
    echo "KNOWLEDGE_DELIVERY=per-merge"
    echo "KNOWLEDGE_TARGET=${default}"
    # まとめるモードから戻した直後など、staging に未反映が残っていれば知らせる（追跡 ref だけを読む）
    if ff_kd_unreflected "$repo_root" "$default" "$KD_STAGING" && [[ "$KD_UNREFLECTED" -gt 0 ]]; then
      echo "⚠️  設定はマージごとですが、origin/${KD_STAGING} に未反映の知見が ${KD_UNREFLECTED} コミット残っています — finish.sh knowledge-commit flush で base へ反映する（flush は設定によらず実行できる）" >&2
    fi
    return 0
  fi
  staging="$KD_STAGING"
  staging_tip="$(kc_fetch_staging "$staging")" || exit 2
  default_tip="$(git rev-parse --verify --quiet "refs/remotes/origin/${default}^{commit}")" \
    || die_env "origin/${default} を解決できません" "git fetch origin ${default} を確かめてから再実行する"
  if [[ "$rc" -eq 0 ]]; then
    # 記録がある（同じセッションで既に移った）。移り直さず、先行だけを確かめる。止まっても起点に残る
    # （追記を退避できるようにするため。戻り先は案内に出す）
    [[ "$KD_ST_STAGING" == "$staging" && "$KD_ST_DEFAULT" == "$default" ]] \
      || die_env "書き込み先の記録（${KD_ST_STAGING} / ${KD_ST_DEFAULT}）と設定（${staging} / ${default}）が食い違います" "finish.sh knowledge-commit discard で記録を消し、$(kc_restore_hint "$KD_ST_RESTORE" "$KD_ST_ORIGIN") で戻ってから再実行する"
    git merge-base --is-ancestor "$KD_ST_START" HEAD 2>/dev/null \
      || die_env "HEAD が書き込み先の起点（${KD_ST_START:0:12}）から外れています" "finish.sh knowledge-commit discard で記録を消し、$(kc_restore_hint "$KD_ST_RESTORE" "$KD_ST_ORIGIN") で戻ってから target をやり直す"
    if [[ -n "$staging_tip" ]] && ! git merge-base --is-ancestor "$staging_tip" HEAD; then
      echo "KNOWLEDGE_TARGET_FRESH=stale"
      die_stop "origin/${staging} が先行しています（別のセッションが知見を書いた）" "$(kc_redo_hint)"
    fi
    echo "KNOWLEDGE_TARGET_FRESH=ok"
    kc_target_report "$default" "$staging" "$KD_ST_START"
    return 0
  fi
  start_branch="$(git symbolic-ref -q --short HEAD)" || start_branch=""
  start_sha="$(git rev-parse --verify --quiet HEAD)" || die_env "HEAD を解決できません" "作業ツリーの状態を確かめて再実行する"
  case "$start_branch" in
    chore/ace-from-*|chore/retro-from-*)
      die_env "まとめるモードでは知見ブランチ（${start_branch}）を使いません" "${default} へ戻ってから再実行する（知見は ${staging} へ push し、base への反映は flush で行う）" ;;
  esac
  git_dir="$(git rev-parse --absolute-git-dir)" || die_env "git ディレクトリを解決できません" "作業ツリーの実体パスで再実行する"
  [[ ! -s "${git_dir}/ff-knowledge-pending" ]] \
    || die_stop "知見の保留記録が残っています（起点へ移ると保留の基点が変わる）" "finish.sh knowledge-commit status で確かめ、確定するか discard してから target を実行する"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die_stop "作業ツリーか index に未コミットの変更があります（書き込みの起点へ移れない）" "コミットするか退避してから再実行する（知見の追記は起点へ移ってから書く）"
  fi
  if [[ -z "$staging_tip" ]] || git merge-base --is-ancestor "$staging_tip" "$default_tip"; then
    start="$default_tip"
  else
    # 合わせたツリーを検査してから起点を決める（検査より前に checkout しない）
    kc_merged_tree "$default_tip" "$staging_tip" KNOWLEDGE_TARGET
    if git merge-base --is-ancestor "$default_tip" "$staging_tip"; then
      start="$staging_tip"
    else
      ff_commit_identity_check "$repo_root" || exit 1
      start="$(git commit-tree "$KC_MERGED_TREE" -p "$staging_tip" -p "$default_tip" -m "Merge branch '${default}' into ${staging}" 2>&1)" \
        || die_env "起点の merge commit を作れません（${start%%$'\n'*}）" "git の identity（user.name / user.email）を確かめて再実行する"
    fi
  fi
  git switch -q --detach "$start" || die_env "起点（${start:0:12}）へ移れません" "作業ツリーの状態を確かめて再実行する"
  ff_kd_state_write "$repo_root" batch "$staging" "$default" "$start" "${staging_tip:--}" "$default_tip" "${start_branch:--}" "$start_sha" \
    || { kc_restore_branch "$start_branch" "$start_sha" || true; die_env "書き込み先の記録を書けません（$(ff_kd_state_path "$repo_root")）" "git ディレクトリへ書けるか確かめて再実行する"; }
  kc_target_report "$default" "$staging" "$start"
  return 0
}

# 書き込みを終えて元の場所へ戻る（記録を消す）。push の成功時と、送るものが無い回に使う
kc_finish_write() {
  ff_kd_state_clear "$repo_root" || echo "⚠️  書き込み先の記録を消せません（finish.sh knowledge-commit discard で消す）" >&2
  if kc_restore_branch "$KD_ST_RESTORE" "$KD_ST_ORIGIN"; then
    echo "KNOWLEDGE_RESTORE=${KD_ST_RESTORE:-${KD_ST_ORIGIN}}"
  else
    echo "KNOWLEDGE_RESTORE=failed"
  fi
}

# まとめるモードの push。target の記録が前提。
kc_push_batch() {
  local default staging tip parent count push_log pushed_sha outside
  default="$KD_ST_DEFAULT"; staging="$KD_ST_STAGING"
  [[ -z "$(git symbolic-ref -q --short HEAD)" ]] \
    || die_env "まとめるモードの書き込みは detached HEAD（target が移した起点）で行います" "finish.sh knowledge-commit discard で記録を消し、$(kc_restore_hint "$KD_ST_RESTORE" "$KD_ST_ORIGIN") で戻ってから target をやり直す"
  # 追記が 0 件で終わった回（候補なし・観測なし）: 何も送らず、元の場所へ戻って記録を消す
  if [[ "$(git rev-parse HEAD)" == "$KD_ST_START" ]]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "KNOWLEDGE_PUSH=uncommitted"
      die_stop "起点の上に未コミットの追記があります（送るコミットが無い）" "knowledge-commit add → commit で確定してから push する。要らない追記なら git restore --source=${KD_ST_START} --staged --worktree -- <変更したパス>（git diff --name-only ${KD_ST_START} で確かめる）で外してから push する"
    fi
    echo "KNOWLEDGE_PUSH=nothing"
    echo "KNOWLEDGE_DELIVERY=batch"
    kc_finish_write
    return 0
  fi
  tip="$(kc_fetch_staging "$staging")" || exit 2
  # 送信範囲: 起点の上の知見コミット 1 つだけ（起点が手元の merge commit なら、それも一緒に送る）
  parent="$(git rev-parse --verify --quiet 'HEAD^1')" || parent=""
  count="$(git rev-list --parents -n 1 HEAD | awk '{ print NF - 1 }')" || count=""
  if [[ "$parent" != "$KD_ST_START" || "$count" != 1 ]]; then
    echo "KNOWLEDGE_PUSH=scope-mismatch"
    die_env "送信範囲が起点（${KD_ST_START:0:12}）の上の知見コミット 1 つではありません（HEAD^ = ${parent:0:12}）" "knowledge-commit commit で 1 コミットに畳んでから push する（無関係なコミットは退避する）"
  fi
  outside="$(ff_kd_paths_outside "$repo_root" 'HEAD^' HEAD)" \
    || die_env "送る知見コミットの変更を列挙できません" "git show --name-only HEAD を手で確かめる"
  if [[ -n "$outside" ]]; then
    echo "KNOWLEDGE_PUSH=outside-knowledge"
    die_env "知見コミットに知見の置き場（${KD_ALLOWED_PREFIXES}）以外の変更があります: $(printf '%s' "$outside" | tr '\n' ' ')" "知見の置き場の外のファイルを記録から外し、knowledge-commit add → commit をやり直す（まとめるモードの Playbook と台帳は docs/08-knowledge/ に置く）"
  fi
  if [[ -n "$tip" ]] && ! git merge-base --is-ancestor "$tip" HEAD; then
    echo "KNOWLEDGE_PUSH=rejected"
    die_stop "origin/${staging} が先行しています（non-fast-forward。別のセッションが知見を書いた）" "$(kc_redo_hint)"
  fi
  push_log="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
  if ! git push origin "HEAD:refs/heads/${staging}" >"$push_log" 2>&1; then
    cat "$push_log"; rm -f "$push_log"
    echo "KNOWLEDGE_PUSH=rejected"
    echo "✗ ${staging} への push が拒否されました（non-fast-forward なら知見コミットを取り消して target からやり直す。保護されているなら ${staging} を直接 push できるようにする）" >&2
    exit 1
  fi
  cat "$push_log"
  if ! awk -v n="-> ${staging}" 'index($0, n) { f = 1 } END { exit f ? 0 : 1 }' "$push_log"; then
    rm -f "$push_log"
    echo "KNOWLEDGE_PUSH=not-delivered"
    echo "✗ push 出力に -> ${staging} が無く、コミットが届いていません" >&2
    exit 1
  fi
  rm -f "$push_log"
  pushed_sha="$(git rev-parse HEAD)"
  git fetch -q origin "+refs/heads/${staging}:refs/remotes/origin/${staging}" 2>/dev/null || true
  echo "KNOWLEDGE_PUSH=ok"
  echo "KNOWLEDGE_PUSHED_SHA=${pushed_sha}"
  echo "KNOWLEDGE_DELIVERY=batch"
  echo "KNOWLEDGE_TARGET=${staging}"
  echo "KNOWLEDGE_CI=(unavailable)"
  # 届いた後は、元の場所へ戻って記録を消すことを先に済ませる。件数の報告は失敗しても止めない
  kc_finish_write
  if ff_kd_load "$repo_root" "$default" 2>/dev/null; then
    kc_unreflected_report "$default" "$staging"
  else
    echo "KNOWLEDGE_UNREFLECTED=unknown"
  fi
  return 0
}

kc_flush() {
  local type="knowledge" use_pr=0 branch="" dry_run=0 default staging staging_tip default_tip
  local subjects n title body push_log rc=0 pr_url merge_sha
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) [[ $# -ge 2 ]] || usage; type="$2"; shift 2 ;;
      --pr) use_pr=1; shift ;;
      --branch) [[ $# -ge 2 ]] || usage; branch="$2"; use_pr=1; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) echo "✗ 不明な引数: $1" >&2; usage ;;
    esac
  done
  [[ "$type" =~ ^[a-z][a-z-]*$ ]] || die_env "--type は英小文字の commit type です: ${type}" "--type knowledge / chore 等を渡す"
  if [[ -n "$branch" ]]; then
    case "$branch" in "${KD_FLUSH_PREFIX}"?*) ;; *) die_env "--branch は ${KD_FLUSH_PREFIX} で始めます: ${branch}" "名前を直して再実行する" ;; esac
    git check-ref-format --branch "$branch" >/dev/null 2>&1 || die_env "ブランチ名として使えません: ${branch}" "名前を直して再実行する"
  fi
  default="$(kc_default_branch)" || exit 2
  kc_fetch_branch "$default"
  kc_batch_conf "$default"
  staging="$KD_STAGING"
  staging_tip="$(kc_fetch_staging "$staging")" || exit 2
  default_tip="$(git rev-parse --verify --quiet "refs/remotes/origin/${default}^{commit}")" \
    || die_env "origin/${default} を解決できません" "git fetch origin ${default} を確かめてから再実行する"
  if [[ -z "$staging_tip" ]] || git merge-base --is-ancestor "$staging_tip" "$default_tip"; then
    echo "KNOWLEDGE_FLUSH=nothing"
    echo "KNOWLEDGE_UNREFLECTED=0"
    return 0
  fi
  subjects="$(git log --no-merges --reverse --format='- %s' "${default_tip}..${staging_tip}")" \
    || die_env "未反映のコミットを列挙できません" "git log origin/${default}..origin/${staging} を手で確かめる"
  n="$(printf '%s\n' "$subjects" | awk 'NF { c++ } END { print c + 0 }')"
  # 取り込んだ後のツリーを作業ツリーに触れずに作って検査する（衝突・範囲外ならここで止まる）
  kc_merged_tree "$default_tip" "$staging_tip" KNOWLEDGE_FLUSH
  if [[ "$dry_run" -eq 1 ]]; then
    echo "KNOWLEDGE_FLUSH=dry-run"
    echo "KNOWLEDGE_FLUSH_PENDING=${n}"
    printf '%s\n' "$subjects"
    git -c core.quotePath=false diff --name-only "$default_tip" "$KC_MERGED_TREE" | awk 'NF { print "  変更するパス: " $0 }'
    return 0
  fi
  title="${type}: 未反映の知見を ${default} へ反映する（${n} コミット）"
  body="$(printf '%s から未反映の知見を merge commit で取り込む（ADR-083）。\n\n%s\n' "$staging" "$subjects")"
  ff_commit_identity_check "$repo_root" || exit 1
  # 親の順は default → staging（base の first-parent 履歴に flush の merge commit だけが並ぶ）。
  # commit-tree は hook を起動しないので、staging に紛れた hook も動かない
  merge_sha="$(git commit-tree "$KC_MERGED_TREE" -p "$default_tip" -p "$staging_tip" -m "Merge branch '${staging}' into ${default}" -m "$body" 2>&1)" \
    || die_env "flush の merge commit を作れません（${merge_sha%%$'\n'*}）" "git の identity（user.name / user.email）を確かめて再実行する"
  if [[ "$use_pr" -eq 0 ]]; then
    push_log="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
    git push origin "${merge_sha}:refs/heads/${default}" >"$push_log" 2>&1 || rc=$?
    cat "$push_log"
    if [[ "$rc" -ne 0 ]]; then
      if awk 'index($0, "Changes must be made through a pull request") || index($0, "push declined due to repository rule violations") || index($0, "Protected branch update failed") || index($0, "Required status check") || index($0, "not authorized to push") { f = 1 } END { exit f ? 0 : 1 }' "$push_log"; then
        rm -f "$push_log"
        echo "KNOWLEDGE_FLUSH=protected"
        echo "✗ ${default} が保護されていて直接 push できません。finish.sh knowledge-commit flush --pr で PR 経由にする" >&2
        exit 3
      fi
      rm -f "$push_log"
      echo "KNOWLEDGE_FLUSH=rejected"
      echo "✗ ${default} への push が失敗しました（base が進んだなら flush をやり直す。--force で上書きしない）" >&2
      exit 1
    fi
    if ! awk -v n="-> ${default}" 'index($0, n) { f = 1 } END { exit f ? 0 : 1 }' "$push_log"; then
      rm -f "$push_log"
      echo "KNOWLEDGE_FLUSH=not-delivered"
      echo "✗ push 出力に -> ${default} が無く、flush が届いていません" >&2
      exit 1
    fi
    rm -f "$push_log"
    echo "KNOWLEDGE_FLUSH=ok"
    echo "KNOWLEDGE_FLUSHED_SHA=${merge_sha}"
    echo "KNOWLEDGE_FLUSH_COMMITS=${n}"
    git fetch -q origin "+refs/heads/${default}:refs/remotes/origin/${default}" 2>/dev/null || true
    return 0
  fi
  need_cmd gh "gh をインストールして gh auth login を済ませる（flush の PR 経路は gh を使う）"
  [[ -n "$branch" ]] || branch="${KD_FLUSH_PREFIX}$(date -u +%Y%m%dT%H%M%SZ)"
  git push origin "${merge_sha}:refs/heads/${branch}" \
    || die_env "flush 用ブランチ ${branch} を push できません" "認証・通信を確かめて flush --pr をやり直す"
  if ! pr_url="$(gh pr create --base "$default" --head "$branch" --title "$title" --body "$(printf '%s\n\n**マージは「Create a merge commit」で行う**（squash / rebase すると %s の祖先関係が切れ、反映済みの知見も未反映として数え続ける）。\n' "$body" "$staging")")"; then
    die_env "flush の PR を作れません（${branch} は push 済み）" "gh pr create --base ${default} --head ${branch} を手で実行する"
  fi
  echo "KNOWLEDGE_FLUSH=pr"
  echo "KNOWLEDGE_FLUSH_PR=${pr_url}"
  echo "KNOWLEDGE_FLUSH_BRANCH=${branch}"
  echo "KNOWLEDGE_FLUSH_COMMITS=${n}"
  return 0
}

_finish_kc_batch_loaded=1
