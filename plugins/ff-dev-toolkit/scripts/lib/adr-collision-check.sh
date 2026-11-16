# shellcheck shell=bash
# PR が新しく足す ADR 番号を origin/<default> と open PR に照らして衝突を検出する共有ライブラリ。
# `scripts/check-version-claims.sh` から source され、単体の入口は作らない。
#
# 抽出・正規化の規約は `tests/docs-gates/adr-number-scan.sh` と揃える:
#   - コードフェンス（``` / ~~~）内の例示・テンプレート行は読まない
#   - 見出し `^##[[:space:]]+ADR-[0-9]+` と `## 決定ログ` 表の `^\|[[:space:]]*ADR-[0-9]+[[:space:]]*\|` を拾う
#   - 番号は数値へ正規化し `ADR-%03d` の形で比較・報告する
#   - awk / sort / comm は ASCII 制御・数値比較の安定化と UTF-8 リテラル一致のため LC_ALL=C を前置する

_ff_adr_extract_records() {
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
    in_fence { next }
    /^##[[:space:]]+決定ログ[[:space:]]*$/ { in_log = 1; next }
    in_log && /^##[[:space:]]/ { in_log = 0 }
    /^##[[:space:]]+ADR-[0-9]+/ {
      n = $0
      sub(/^##[[:space:]]+ADR-/, "", n)
      sub(/[^0-9].*$/, "", n)
      if (n != "") {
        num = n + 0
        id = sprintf("ADR-%03d", num)
        h_cnt[id]++
        lbl = $0
        sub(/[[:space:]]+$/, "", lbl)
        if (h_cnt[id] == 1) label[id] = lbl
        seen[id] = 1
      }
    }
    in_log && /^\|[[:space:]]*ADR-[0-9]+[[:space:]]*\|/ {
      n = $0
      sub(/^\|[[:space:]]*ADR-/, "", n)
      sub(/[^0-9].*$/, "", n)
      if (n != "") {
        num = n + 0
        id = sprintf("ADR-%03d", num)
        t_cnt[id]++
        if (!(id in label)) label[id] = "決定ログ表の行"
        seen[id] = 1
      }
    }
    END {
      for (id in seen) {
        printf "%s\t%d\t%d\t%s\n", id, h_cnt[id] + 0, t_cnt[id] + 0, label[id]
      }
    }
  ' | LC_ALL=C sort
}

_ff_adr_extract_open_pr_additions() {
  local adr_doc="$1" pr_num="$2" pr_title="$3"
  PR_TITLE="$pr_title" LC_ALL=C awk -v doc="$adr_doc" -v pr="$pr_num" '
    BEGIN {
      in_target = 0; in_plus_fence = 0; in_minus_fence = 0
      title = ENVIRON["PR_TITLE"]
      gsub(/[\t\r\n]+/, " ", title)
    }
    { sub(/\r$/, "") }
    /^diff --git / { in_target = 0; in_plus_fence = 0; in_minus_fence = 0; next }
    $0 == ("+++ b/" doc) { in_target = 1; in_plus_fence = 0; in_minus_fence = 0; next }
    /^\+\+\+ / { in_target = 0; next }
    !in_target { next }
    /^@@ / { in_plus_fence = 0; in_minus_fence = 0; next }
    /^--- / { next }
    /^\\ / { next }
    {
      prefix = substr($0, 1, 1)
      body = substr($0, 2)
      if (prefix == " ") {
        if (body ~ /^[[:space:]]*(```|~~~)/) {
          in_plus_fence = !in_plus_fence
          in_minus_fence = !in_minus_fence
        }
        next
      }
      if (prefix == "+") {
        if (body ~ /^[[:space:]]*(```|~~~)/) {
          in_plus_fence = !in_plus_fence
          next
        }
        if (in_plus_fence) next
        if (body ~ /^##[[:space:]]+ADR-[0-9]+/) {
          n = body
          sub(/^##[[:space:]]+ADR-/, "", n)
          sub(/[^0-9].*$/, "", n)
          if (n != "") {
            id = sprintf("ADR-%03d", n + 0)
            ph[id]++
            seen[id] = 1
          }
        } else if (body ~ /^\|[[:space:]]*ADR-[0-9]+[[:space:]]*\|/) {
          n = body
          sub(/^\|[[:space:]]*ADR-/, "", n)
          sub(/[^0-9].*$/, "", n)
          if (n != "") {
            id = sprintf("ADR-%03d", n + 0)
            pt[id]++
            seen[id] = 1
          }
        }
      } else if (prefix == "-") {
        if (body ~ /^[[:space:]]*(```|~~~)/) {
          in_minus_fence = !in_minus_fence
          next
        }
        if (in_minus_fence) next
        if (body ~ /^##[[:space:]]+ADR-[0-9]+/) {
          n = body
          sub(/^##[[:space:]]+ADR-/, "", n)
          sub(/[^0-9].*$/, "", n)
          if (n != "") {
            id = sprintf("ADR-%03d", n + 0)
            mh[id]++
          }
        } else if (body ~ /^\|[[:space:]]*ADR-[0-9]+[[:space:]]*\|/) {
          n = body
          sub(/^\|[[:space:]]*ADR-/, "", n)
          sub(/[^0-9].*$/, "", n)
          if (n != "") {
            id = sprintf("ADR-%03d", n + 0)
            mt[id]++
          }
        }
      }
    }
    END {
      for (id in seen) {
        if ((ph[id] + 0 > mh[id] + 0) || (pt[id] + 0 > mt[id] + 0)) {
          printf "%s\t%s\t%s\n", id, pr, title
        }
      }
    }
  ' | LC_ALL=C sort
}

_ff_adr_collision_run() {
  local tmp_dir="$1" root="$2" default_base="$3" default_ref_label="$4" skip_open_prs="$5"
  local adr_doc="docs/06-reference/DECISIONS.md"
  local merge_base diff_rc=0
  local mb_records_file="$tmp_dir/mb.tsv"
  local cur_records_file="$tmp_dir/cur.tsv"
  local origin_records_file="$tmp_dir/origin.tsv"
  local added_adrs_file="$tmp_dir/added.txt"
  local open_pr_adds_file="$tmp_dir/open-pr-adds.tsv"
  local collisions_file="$tmp_dir/collisions.txt"
  local collided_nums_file="$tmp_dir/collided-nums.txt"
  local refs_file="$tmp_dir/refs.txt"
  local gh_err_file="$tmp_dir/gh.err"

  merge_base="$(git -C "$root" merge-base "$default_base" HEAD 2>/dev/null)" || {
    echo "✗ ADR 衝突検査の merge-base を解決できません" >&2
    return 2
  }

  # DECISIONS.md が merge-base から変更されていなければ新規 ADR も無いので即抜ける
  if git -C "$root" cat-file -e "${merge_base}:${adr_doc}" 2>/dev/null; then
    if git -C "$root" diff --cached --no-ext-diff --quiet "$merge_base" -- "$adr_doc" 2>/dev/null; then
      return 0
    else
      diff_rc=$?
      [[ "$diff_rc" -eq 1 ]] || {
        echo "✗ index の ${adr_doc} の差分を検査できません" >&2
        return 2
      }
    fi
  fi

  local cur_content mb_content=""
  cur_content="$(git -C "$root" show ":${adr_doc}" 2>/dev/null)" || {
    echo "✗ index の ${adr_doc} を読み込めません" >&2
    return 2
  }
  printf '%s\n' "$cur_content" | _ff_adr_extract_records > "$cur_records_file"

  if git -C "$root" cat-file -e "${merge_base}:${adr_doc}" 2>/dev/null; then
    mb_content="$(git -C "$root" show "${merge_base}:${adr_doc}" 2>/dev/null)" || {
      echo "✗ merge-base の ${adr_doc} を読み込めません" >&2
      return 2
    }
    printf '%s\n' "$mb_content" | _ff_adr_extract_records > "$mb_records_file"
  else
    : > "$mb_records_file"
  fi

  MB_F="$mb_records_file" LC_ALL=C awk -F '\t' '
    BEGIN { mb_f = ENVIRON["MB_F"] }
    FILENAME == mb_f { h[$1] = $2 + 0; t[$1] = $3 + 0; next }
    (($2 + 0) > (h[$1] + 0) || ($3 + 0) > (t[$1] + 0)) { print $1 }
  ' "$mb_records_file" "$cur_records_file" | LC_ALL=C sort -u > "$added_adrs_file"

  # PR が新しく足す ADR 番号が 0 件なら従来どおり無出力で 0
  [[ -s "$added_adrs_file" ]] || return 0

  if git -C "$root" cat-file -e "${default_base}:${adr_doc}" 2>/dev/null; then
    local origin_content
    origin_content="$(git -C "$root" show "${default_base}:${adr_doc}" 2>/dev/null)" || {
      echo "✗ ${default_ref_label} の ${adr_doc} を読み込めません" >&2
      return 2
    }
    printf '%s\n' "$origin_content" | _ff_adr_extract_records > "$origin_records_file"
  else
    : > "$origin_records_file"
  fi

  : > "$collisions_file"
  : > "$collided_nums_file"

  # 照合先 1: 最新の origin/<default>
  LC_ALL=C awk -F '\t' -v ref_label="$default_ref_label" '
    NR == FNR { added[$1] = 1; next }
    ($1 in added) {
      printf "  - 衝突: %s（相手: %s の %s）\n", $1, ref_label, $4
    }
  ' "$added_adrs_file" "$origin_records_file" >> "$collisions_file"

  LC_ALL=C awk -F '\t' '
    NR == FNR { added[$1] = 1; next }
    ($1 in added) {
      n = $1
      sub(/^ADR-/, "", n)
      print (n + 0)
    }
  ' "$added_adrs_file" "$origin_records_file" >> "$collided_nums_file"

  # 照合先 2: open PR の同じ文書差分（CI / snapshot / --base-commit の既定 pin 時のみ省略）
  : > "$open_pr_adds_file"
  local open_pr_unverified=""
  if [[ "$skip_open_prs" -eq 0 ]]; then
    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
      open_pr_unverified="gh または jq コマンドが見つかりません"
    else
      local pr_list_json="" gh_list_rc=0
      if pr_list_json="$(CDPATH='' cd -P -- "$root" && GH_PROMPT_DISABLED=1 gh pr list --state open --limit 200 --json number,title,headRefName,headRefOid,isCrossRepository,files 2>"$gh_err_file")"; then
        gh_list_rc=0
      else
        gh_list_rc=$?
      fi
      if [[ "$gh_list_rc" -ne 0 ]]; then
        local gh_err_line=""
        IFS= read -r gh_err_line < "$gh_err_file" || true
        open_pr_unverified="gh pr list 失敗（rc=${gh_list_rc}${gh_err_line:+: $gh_err_line}）"
      elif ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$pr_list_json"; then
        open_pr_unverified="gh pr list の応答 JSON を解析できません"
      elif [[ "$(jq -r 'length' <<<"$pr_list_json")" -ge 200 ]]; then
        open_pr_unverified="open PR が上限 200 件に達したため全件照合できません"
      else
        local cur_branch cur_head candidate_prs=""
        cur_branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        cur_head="$(git -C "$root" rev-parse --verify HEAD 2>/dev/null || true)"
        if ! candidate_prs="$(jq -r --arg cb "$cur_branch" --arg ch "$cur_head" --arg doc "$adr_doc" '
          .[]
          | select(
              (
                ((.headRefOid // "") != "" and $ch != "" and .headRefOid == $ch)
                or ((.isCrossRepository == false) and $cb != "" and (.headRefName // "") == $cb)
              ) | not
            )
          | select(((.files // []) | length) >= 100 or (((.files // []) | map(.path) | index($doc)) != null))
          | "\(.number)\t\(.title // "" | gsub("[\\r\\n\\t]+"; " "))"
        ' <<<"$pr_list_json" 2>"$gh_err_file")"; then
          open_pr_unverified="gh pr list の候補抽出に失敗しました"
        else
          local pr_num pr_title pr_diff gh_diff_rc
          while IFS=$'\t' read -r pr_num pr_title; do
            [[ -n "$pr_num" ]] || continue
            gh_diff_rc=0
            if pr_diff="$(CDPATH='' cd -P -- "$root" && GH_PROMPT_DISABLED=1 gh pr diff "$pr_num" 2>"$gh_err_file")"; then
              gh_diff_rc=0
            else
              gh_diff_rc=$?
            fi
            if [[ "$gh_diff_rc" -ne 0 ]]; then
              local diff_err_line=""
              IFS= read -r diff_err_line < "$gh_err_file" || true
              open_pr_unverified="PR #${pr_num} の差分を取得できません（rc=${gh_diff_rc}${diff_err_line:+: $diff_err_line}）"
              break
            fi
            printf '%s\n' "$pr_diff" | _ff_adr_extract_open_pr_additions "$adr_doc" "$pr_num" "$pr_title" >> "$open_pr_adds_file"
          done <<<"$candidate_prs"
        fi
      fi
    fi

    if [[ -s "$open_pr_adds_file" ]]; then
      LC_ALL=C awk -F '\t' '
        NR == FNR { added[$1] = 1; next }
        ($1 in added) {
          if ($3 != "") {
            printf "  - 衝突: %s（相手: open PR #%s %s）\n", $1, $2, $3
          } else {
            printf "  - 衝突: %s（相手: open PR #%s）\n", $1, $2
          }
        }
      ' "$added_adrs_file" "$open_pr_adds_file" >> "$collisions_file"

      LC_ALL=C awk -F '\t' '
        NR == FNR { added[$1] = 1; next }
        ($1 in added) {
          n = $1
          sub(/^ADR-/, "", n)
          print (n + 0)
        }
      ' "$added_adrs_file" "$open_pr_adds_file" >> "$collided_nums_file"
    fi
  fi

  if [[ ! -s "$collisions_file" && -z "$open_pr_unverified" ]]; then
    return 0
  fi

  if [[ -s "$collisions_file" ]]; then
    local next_free
    next_free="$(CUR_F="$cur_records_file" LC_ALL=C awk -F '\t' '
      BEGIN { max_n = 0; cur_f = ENVIRON["CUR_F"] }
      FILENAME == cur_f { cur_taken[$1] = 1; next }
      {
        taken[$1] = 1
        n = $1
        sub(/^ADR-/, "", n)
        if (n + 0 > max_n) max_n = n + 0
      }
      END {
        next_n = max_n + 1
        while (sprintf("ADR-%03d", next_n) in taken || sprintf("ADR-%03d", next_n) in cur_taken) {
          next_n++
        }
        printf "ADR-%03d\n", next_n
      }
    ' "$origin_records_file" "$mb_records_file" "$open_pr_adds_file" "$cur_records_file")"

    if ! git -C "$root" -c core.quotePath=false diff --cached --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ -U0 "$merge_base" 2>/dev/null \
      | LC_ALL=C awk -v nums_file="$collided_nums_file" '
        BEGIN {
          while ((getline line < nums_file) > 0) {
            if (line != "") target[line + 0] = 1
          }
          close(nums_file)
          cur_file = ""
          new_ln = 0
        }
        { sub(/\r$/, "") }
        /^diff --git / { cur_file = ""; new_ln = 0; next }
        /^\+\+\+ b\// { cur_file = substr($0, 7); next }
        /^\+\+\+ \/dev\/null$/ { cur_file = ""; next }
        /^--- / { next }
        /^@@ / {
          plus_part = $0
          sub(/^@@ [^ ]* \+/, "", plus_part)
          sub(/[, ].*$/, "", plus_part)
          new_ln = plus_part + 0
          next
        }
        cur_file != "" && /^\+/ {
          body = substr($0, 2)
          ln = new_ln
          new_ln++
          tmp = body
          matched = 0
          while (match(tmp, /ADR-[0-9]+/)) {
            tok = substr(tmp, RSTART + 4, RLENGTH - 4) + 0
            if (tok in target) { matched = 1; break }
            tmp = substr(tmp, RSTART + RLENGTH)
          }
          if (matched) {
            snippet = body
            sub(/^[[:space:]]+/, "", snippet)
            if (length(snippet) > 120) snippet = substr(snippet, 1, 117) "..."
            printf "%s:%d: %s\n", cur_file, ln, snippet
          }
        }
      ' > "$refs_file"; then
      : > "$refs_file"
    fi

    {
      echo "✗ ADR 番号の衝突を検出しました（${adr_doc}）:"
      cat "$collisions_file"
      if [[ -n "$open_pr_unverified" ]]; then
        echo "  - open PR 照合: 未確認（${open_pr_unverified}）"
      fi
      echo "  - 次の空き番号: ${next_free}"
      echo "  - 付け替え対象（PR 差分内の参照）:"
      if [[ -s "$refs_file" ]]; then
        sed 's/^/    - /' "$refs_file"
      else
        echo "    - （該当参照なし）"
      fi
    } >&2
    return 1
  fi

  echo "✗ ADR 番号の open PR 照合が未確認のため通過できません: 未確認（${open_pr_unverified}）" >&2
  return 2
}

ff_check_adr_collision() { # <repo_root> <default_base_sha> <default_ref_label> <skip_open_prs:0|1>
  local root="$1" default_base="$2" default_ref_label="$3" skip_open_prs="${4:-0}"
  local adr_doc="docs/06-reference/DECISIONS.md"

  # index に DECISIONS.md が無ければ即 0（既存テストの repository で git stub 等を踏まない）
  git -C "$root" cat-file -e ":${adr_doc}" 2>/dev/null || return 0

  local tmp_dir rc=0
  if ! tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ff-adr-check.XXXXXX" 2>/dev/null)" || [[ ! -d "$tmp_dir" ]]; then
    echo "✗ ADR 衝突検査用の一時ディレクトリを作成できません" >&2
    return 2
  fi
  _ff_adr_collision_run "$tmp_dir" "$root" "$default_base" "$default_ref_label" "$skip_open_prs" || rc=$?
  rm -rf "$tmp_dir"
  return "$rc"
}
