#!/usr/bin/env bash
# 空振り検出: マージ済みかつリモート ref 無しかつ head 一致かつ origin 同一リポジトリの
# 判定を外すと正例が赤。リモート ref が残る・PR が未マージ・gh 失敗・origin 無し・
# 同名で別 commit・fork の PR・--repo を外して GH_REPO に従う、を成功へ倒すと負例が赤。
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する。
run_merged_shelve_cases() {
  local previous="$PWD" root="$TMP/merged-shelve" name mode repo bare bin series repo_p out
  local log rc calls payload archived unmerged_prev old_sha
  mkdir -p "$root"
  shelve_one() { # <name> <mode: merged|unmerged|remote|no-origin|gh-fail|reused|cross>
    name="$1"
    mode="$2"
    repo="$root/$name/repo"
    bare="$root/$name/origin.git"
    bin="$root/$name/bin"
    log="$root/$name/run.log"
    calls="$root/$name/gh-calls"
    rm -rf "${root:?}/${name:?}"
    mkdir -p "$bin"
    ff_git_fixture_init "$repo" "merged-shelve" "shelve@example.invalid"
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" switch -q -c develop
    printf 'base\n' > "$repo/app.txt"
    git -C "$repo" add app.txt
    git -C "$repo" commit -qm init
    git -C "$repo" switch -q -c feature/old
    printf 'old\n' >> "$repo/app.txt"
    git -C "$repo" add app.txt
    git -C "$repo" commit -qm old
    old_sha="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" switch -q -c feature/new
    printf 'new\n' >> "$repo/app.txt"
    git -C "$repo" add app.txt
    git -C "$repo" commit -qm new
    repo_p="$(cd "$repo" && pwd -P)"
    series="$(printf 'repo=%s\nbranch=%s\nbase=%s\nscope=%s\n' "$repo_p" "refs/heads/feature/old" "develop" "branch" | cksum | awk '{ print $1 "-" $2 }')"
    out="$repo_p/.review-results"
    mkdir -p "$out"
    chmod 700 "$out"
    # shellcheck source=../../scripts/lib/multi-agent-boundary.sh
    . "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh"
    ff_review_output_marker "$repo_p" "$out" > "$out/.multi-agent-output-owner"
    chmod 600 "$out/.multi-agent-output-owner"
    printf 'sentinel-old-critical\n<!-- CRITICAL_BLOCK -->\n<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:%s block:code-review nonblock:- -->\n' "$series" > "$out/integrated-report.md"
    # 設定 URL は GitHub の owner/name。転送だけ insteadOf で手元の bare にする。
    # get-url は書き換え後を返すので、実装は remote.origin.url を読む。
    point_origin() {
      git -C "$repo" remote set-url origin "https://github.com/example/fixture.git"
      git -C "$repo" config "url.${bare}/.insteadOf" "https://github.com/example/fixture.git"
    }
    if [[ "$mode" == remote ]]; then
      git init -q --bare "$bare"
      git -C "$repo" remote add origin "$bare"
      point_origin
      git -C "$repo" push -q origin feature/old
    elif [[ "$mode" != no-origin ]]; then
      git init -q --bare "$bare"
      git -C "$repo" remote add origin "$bare"
      point_origin
    fi
    git -C "$repo" branch -D feature/old >/dev/null
    if [[ "$mode" == reused ]]; then
      git -C "$repo" switch -q -c feature/old
      printf 'reused\n' >> "$repo/app.txt"
      git -C "$repo" add app.txt
      git -C "$repo" commit -qm reused
      git -C "$repo" switch -q feature/new
    fi
    case "$mode" in
      merged|remote|no-origin|reused)
        payload="$(printf '[{"number":7,"state":"MERGED","headRefName":"feature/old","headRefOid":"%s","isCrossRepository":false,"headRepositoryOwner":{"login":"example"}}]' "$old_sha")"
        ;;
      cross)
        payload="$(printf '[{"number":7,"state":"MERGED","headRefName":"feature/old","headRefOid":"%s","isCrossRepository":true,"headRepositoryOwner":{"login":"example"}}]' "$old_sha")"
        ;;
      unmerged) payload='[]' ;;
      gh-fail) payload='' ;;
    esac
    cat > "$bin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls"
if [[ "\${1:-}" == pr && "\${2:-}" == list ]]; then
  if [[ "$mode" == gh-fail ]]; then exit 1; fi
  printf '%s\n' '$payload'
  exit 0
fi
exit 1
SH
    chmod +x "$bin/gh"
    cat > "$bin/codex" <<SH
#!/usr/bin/env bash
cat <<'BODY'
sentinel-new-review
## Code Review Results

### Summary
- Critical: 0
- verdict: none
BODY
SH
    chmod +x "$bin/codex"
    rc=0
    (
      cd "$repo"
      run_isolated PATH="$bin:$PATH" GH_REPO=evil/evil bash "$MULTI_AGENT" \
        --task review --mode distributed --cli codex-cli --perspective code-review \
        --base develop --timeout 60
    ) >"$log" 2>&1 || rc=$?
  }

  shelve_one positive merged
  archived="$(find "$root/positive/repo/.review-results" -mindepth 1 -maxdepth 1 -type d -name '.prev-*' -print -quit)"
  if [[ "$rc" -eq 0 ]] \
    && grep -qF 'archived it and started a new series' "$log" \
    && [[ -n "$archived" && -f "$archived/integrated-report.md" ]] \
    && grep -qF 'sentinel-old-critical' "$archived/integrated-report.md" \
    && grep -qF 'sentinel-new-review' "$root/positive/repo/.review-results/integrated-report.md" \
    && ! grep -qF 'refs/heads/feature/old' <<<"$(git -C "$root/positive/repo" for-each-ref --format='%(refname)' refs/heads)" \
    && grep -F -- '--repo example/fixture' "$root/positive/gh-calls" >/dev/null \
    && ! grep -F -- 'evil/evil' "$root/positive/gh-calls" >/dev/null; then
    ok "マージ済みでリモート ref が無い系列は、削除済みブランチでも退避して新しいレビューを始める"
  else
    bad "マージ済み系列の自動退避が新しいレビューを始めない (rc=$rc)"
    tail -20 "$log" | sed 's/^/    | /' >&2
  fi

  shelve_one unmerged unmerged
  unmerged_prev="$(find "$root/unmerged/repo/.review-results" -mindepth 1 -maxdepth 1 -type d -name '.prev-*' -print -quit || true)"
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'belongs to another branch/base/scope' "$log" \
    && grep -qF 'sentinel-old-critical' "$root/unmerged/repo/.review-results/integrated-report.md" \
    && [[ -z "$unmerged_prev" ]]; then
    ok "PR がマージ済みでないときは退避せず、今までどおり止まる"
  else
    bad "未マージの系列を退避した、または従来の中断になっていない (rc=$rc)"
  fi

  shelve_one remote remote
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'belongs to another branch/base/scope' "$log" \
    && cmp -s "$root/remote/repo/.review-results/integrated-report.md" <(printf 'sentinel-old-critical\n<!-- CRITICAL_BLOCK -->\n<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:%s block:code-review nonblock:- -->\n' "$(printf 'repo=%s\nbranch=%s\nbase=%s\nscope=%s\n' "$(cd "$root/remote/repo" && pwd -P)" "refs/heads/feature/old" "develop" "branch" | cksum | awk '{ print $1 "-" $2 }')"); then
    ok "リモート ref が残っているときはマージ済みでも退避しない"
  else
    bad "リモート ref が残る系列を退避した (rc=$rc)"
  fi

  shelve_one ghfail gh-fail
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'belongs to another branch/base/scope' "$log" \
    && grep -qF 'sentinel-old-critical' "$root/ghfail/repo/.review-results/integrated-report.md"; then
    ok "gh の照会が失敗したときは退避しない"
  else
    bad "gh 失敗でも退避するか、従来の中断にならない (rc=$rc)"
  fi

  shelve_one noorigin no-origin
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'belongs to another branch/base/scope' "$log" \
    && { [[ ! -s "$root/noorigin/gh-calls" ]] || ! grep -q 'pr list' "$root/noorigin/gh-calls"; } \
    && grep -qF 'sentinel-old-critical' "$root/noorigin/repo/.review-results/integrated-report.md"; then
    ok "origin が無いときは gh を呼ばずに従来どおり止まる"
  else
    bad "origin 無しで gh を呼んだか、従来の中断にならない (rc=$rc)"
  fi

  shelve_one cross cross
  unmerged_prev="$(find "$root/cross/repo/.review-results" -mindepth 1 -maxdepth 1 -type d -name '.prev-*' -print -quit || true)"
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'belongs to another branch/base/scope' "$log" \
    && grep -qF 'sentinel-old-critical' "$root/cross/repo/.review-results/integrated-report.md" \
    && [[ -z "$unmerged_prev" ]]; then
    ok "fork のマージ済み PR では origin の系列を退避しない"
  else
    bad "fork の PR で系列を退避した (rc=$rc)"
    tail -20 "$log" | sed 's/^/    | /' >&2
  fi

  shelve_one reused reused
  unmerged_prev="$(find "$root/reused/repo/.review-results" -mindepth 1 -maxdepth 1 -type d -name '.prev-*' -print -quit || true)"
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'belongs to another branch/base/scope' "$log" \
    && grep -qF 'sentinel-old-critical' "$root/reused/repo/.review-results/integrated-report.md" \
    && [[ -z "$unmerged_prev" ]]; then
    ok "同名ブランチの先端がマージ済み PR の head と違うときは退避しない"
  else
    bad "作り直した同名ブランチの未マージ系列を退避した (rc=$rc)"
    tail -20 "$log" | sed 's/^/    | /' >&2
  fi

  cd "$previous" || return
}
