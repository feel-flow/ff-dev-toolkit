#!/usr/bin/env bash
# Issue #1011: docs-template に consumer-local の review 入口が再混入していないかを
# 読み取り専用で走査する。verify.sh から source して使い、単体では実行しない。

find_consumer_local_review_entries() {
  local root="$1" single_matches wrapper_matches direct_matches inline_matches multiline_matches
  local probe_matches probe_rc=0
  local dot_matches single_rc=0 wrapper_rc=0 direct_rc=0 inline_rc=0 multiline_rc=0
  local dot_rc=0 found=false
  single_matches="$(grep -R -nE --include='*.md' \
    '(^|[^[:alnum:]_.-])(/[^[:space:]]*/)?(bash|sh|zsh)([[:space:]]+[^[:space:]]+)*[[:space:]]+[^[:alnum:]_./-]*(\./)?scripts/(\./|/)*(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)' \
    "$root" 2>&1)" || single_rc=$?
  if [ "$single_rc" -gt 1 ]; then
    printf '%s\n' "$single_matches" >&2
    return "$single_rc"
  fi

  # shell builtin / env wrapper を挟んでも、最終的に consumer-local resource を起動する
  # なら同じ失敗になる。途中の option や環境変数代入もまとめて追う。
  wrapper_matches="$(grep -R -nE --include='*.md' \
    '(^|[^[:alnum:]_./-])(command|exec|env|source)([[:space:]]+[^[:space:]]+)*[[:space:]]+[^[:alnum:]_./-]*(\./)?scripts/(\./|/)*(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)' \
    "$root" 2>&1)" || wrapper_rc=$?
  if [ "$wrapper_rc" -gt 1 ]; then
    printf '%s\n' "$wrapper_matches" >&2
    return "$wrapper_rc"
  fi

  dot_matches="$(grep -R -nE --include='*.md' \
    '(^[[:space:]]*(([-+*]|[0-9]+[.)])[[:space:]]+)?|[|][[:space:]]*)\.[[:space:]]+[^[:alnum:]_./-]*(\./)?scripts/(\./|/)*(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)' \
    "$root" 2>&1)" || dot_rc=$?
  if [ "$dot_rc" -gt 1 ]; then
    printf '%s\n' "$dot_matches" >&2
    return "$dot_rc"
  fi

  # 行頭または表セルで直接起動する形を見る。散文中の path 名は
  # 「plugin同梱 / consumer未配置」の説明に必要なので対象外にする。
  direct_matches="$(grep -R -nE --include='*.md' \
    '(^[[:space:]]*(([-+*]|[0-9]+[.)])[[:space:]]+)?|[|][[:space:]]*)[^[:alnum:]_./-]*(\./)?scripts/(\./|/)*(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)' \
    "$root" 2>&1)" || direct_rc=$?
  if [ "$direct_rc" -gt 1 ]; then
    printf '%s\n' "$direct_matches" >&2
    return "$direct_rc"
  fi

  # inline code の裸 path は同梱物の説明にも必要なため、`--` option を伴う実行例だけを拒否する。
  inline_matches="$(grep -R -nE --include='*.md' \
    '`[^`]*(\./)?scripts/(\./|/)*(setup-multi-agent|multi-agent|multi-review)\.sh[[:space:]]+--[^`[:space:]]+' \
    "$root" 2>&1)" || inline_rc=$?
  if [ "$inline_rc" -gt 1 ]; then
    printf '%s\n' "$inline_matches" >&2
    return "$inline_rc"
  fi

  # 実行前 probe も consumer-local path を正しい場所だと教える入口になる。`test -x`
  # と `[ -x ... ]` は実行コマンド用の scanner へ掛からないため、別に固定する。
  probe_matches="$(grep -R -nE --include='*.md' \
    '(^|[[:space:]|;])(test[[:space:]]+|\[[[:space:]]+)-[frsx][[:space:]]+[^[:alnum:]_./-]*(\./)?scripts/(\./|/)*(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)' \
    "$root" 2>&1)" || probe_rc=$?
  if [ "$probe_rc" -gt 1 ]; then
    printf '%s\n' "$probe_matches" >&2
    return "$probe_rc"
  fi

  multiline_matches="$(find "$root" -type f -name '*.md' -exec awk '
    FNR == 1 { after_bash_continuation = 0 }
    after_bash_continuation \
      && $0 ~ /^[[:space:]]*[^[:alnum:]_.\/-]*(\.\/)?scripts\/((\.\/)|\/)*(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)/ {
        print FILENAME ":" FNR ":" $0
    }
    {
      after_bash_continuation = ($0 ~ /(^|[^[:alnum:]_-])(bash|sh|zsh)([[:space:]]+[^[:space:]\\]+)*[[:space:]]*\\[[:space:]]*$/)
    }
  ' {} + 2>&1)" || multiline_rc=$?
  if [ "$multiline_rc" -ne 0 ]; then
    printf '%s\n' "$multiline_matches" >&2
    return "$multiline_rc"
  fi

  if [ "$single_rc" -eq 0 ]; then printf '%s\n' "$single_matches"; found=true; fi
  if [ "$wrapper_rc" -eq 0 ]; then printf '%s\n' "$wrapper_matches"; found=true; fi
  if [ "$dot_rc" -eq 0 ]; then printf '%s\n' "$dot_matches"; found=true; fi
  if [ "$direct_rc" -eq 0 ]; then printf '%s\n' "$direct_matches"; found=true; fi
  if [ "$inline_rc" -eq 0 ]; then printf '%s\n' "$inline_matches"; found=true; fi
  if [ "$probe_rc" -eq 0 ]; then printf '%s\n' "$probe_matches"; found=true; fi
  if [ -n "$multiline_matches" ]; then printf '%s\n' "$multiline_matches"; found=true; fi
  [ "$found" = true ]
}
