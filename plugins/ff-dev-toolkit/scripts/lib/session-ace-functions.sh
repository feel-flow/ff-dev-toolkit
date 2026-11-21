#!/usr/bin/env bash
# セッション境界で記録した ACE 知見 ID を保存・束縛・参照するヘルパ群（追記専用）。
# ロックは持たず、並行実行で重複行が生じ得るが読み手側（seen[]）で除く。
# bash 3.2 以上（macOS 標準）でそのまま source でき、読み書きの失敗で呼び出し元を止めない。
#
# 状態ファイル群（すべて ${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/ 配下・追記のみ）:
#   session-ace.tsv          <epoch>\t<repo_key>\t<ace_id>\t<commit_sha>\t<env_sid>
#   session-ace-bound.tsv    <commit_sha>\t<sid>\t<epoch>
#   sessions/<sid>.ace       <repo_key>\t<ace_id>\t<commit_sha>\t<epoch>

# 状態ディレクトリのルートを返す（相対パス・`.` / `..`・ルート `/` を拒否し、`//` と末尾 `/` を正規化する）。
ff_session_ace_state_root() {
  local root="" home_dir=""
  if [[ -n "${FF_DEV_TOOLKIT_STATE_DIR:-}" ]]; then
    root="${FF_DEV_TOOLKIT_STATE_DIR}"
  elif [[ -n "${HOME:-}" ]]; then
    home_dir="${HOME}"
    while [[ "$home_dir" != "/" && "$home_dir" == */ ]]; do
      home_dir="${home_dir%/}"
    done
    root="${home_dir}/.config/ff-dev-toolkit"
  else
    return 1
  fi
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  while [[ "$root" == *//* ]]; do
    root="${root%%//*}/${root#*//}"
  done
  while [[ "$root" != "/" && "$root" == */ ]]; do
    root="${root%/}"
  done
  case "/$root/" in
    */./*|*/../*) return 1 ;;
  esac
  [[ -n "$root" && "$root" != "/" ]] || return 1
  printf '%s' "$root"
}

# session_id の安全種別を判定して出力する（empty | valid | invalid）。
# 未束縛センチネル `-` と衝突しないよう `-` 始まり（-*）も invalid とする。
ff_session_ace_sid_class() {
  local sid="${1:-}"
  if [[ -z "$sid" ]]; then
    printf 'empty'
    return 0
  fi
  if [[ "${#sid}" -gt 128 ]]; then
    printf 'invalid'
    return 0
  fi
  case "$sid" in
    .*|-*|*/*|*..*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*)
      printf 'invalid'
      return 0
      ;;
  esac
  printf 'valid'
}

# 環境由来のシステム symlink（macOS の /tmp -> /private/tmp, /var -> /private/var, /etc -> /private/etc）かどうかを判定する。
ff_session_ace_is_macos_sys_link() {
  local p="$1"
  [[ -L "$p" && ( "$p" == "/tmp" || "$p" == "/var" || "$p" == "/etc" ) && -d "/private${p}" ]]
}

# 既存親ディレクトリ鎖に利用者作成 symlink、他ユーザー所有、または非粘着 g+w/o+w 親が無いことを検査する。
ff_session_ace_check_ancestor_chain() {
  local p="$1" info="" mode="" owner="" g_write="" o_write="" sticky=""
  while [[ -n "$p" && "$p" != "/" ]]; do
    while [[ "$p" != "/" && "$p" == */ ]]; do
      p="${p%/}"
    done
    [[ -n "$p" && "$p" != "/" ]] || break
    if [[ -e "$p" || -L "$p" ]]; then
      if [[ -L "$p" ]]; then
        ff_session_ace_is_macos_sys_link "$p" || return 1
      elif [[ -d "$p" ]]; then
        info="$(LC_ALL=C ls -ld -- "$p" 2>/dev/null | LC_ALL=C awk 'NR==1 { print substr($1, 1, 10) "\t" $3 }')" || return 1
        mode="${info%%$'\t'*}"
        owner="${info#*$'\t'}"
        [[ "${#mode}" -eq 10 && -n "$owner" ]] || return 1
        if [[ ! -O "$p" && "$owner" != "root" ]]; then
          return 1
        fi
        g_write="${mode:5:1}"
        o_write="${mode:8:1}"
        sticky="${mode:9:1}"
        if [[ ( "$g_write" == "w" || "$o_write" == "w" ) && "$sticky" != "t" && "$sticky" != "T" ]]; then
          return 1
        fi
      else
        return 1
      fi
    fi
    p="${p%/*}"
    [[ -n "$p" ]] || p="/"
  done
  return 0
}

# 所有ディレクトリが非 symlink かつ g+w / o+w（他者書き込み）を持たないことを検証する。
ff_session_ace_check_owned_dir() {
  local dir="$1" info="" mode=""
  [[ -n "$dir" && -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
  info="$(LC_ALL=C ls -ld -- "$dir" 2>/dev/null | LC_ALL=C awk 'NR==1 { print substr($1, 1, 10) }')" || return 1
  [[ "${#info}" -eq 10 ]] || return 1
  [[ "${info:0:1}" == "d" ]] || return 1
  [[ "${info:5:1}" != "w" && "${info:8:1}" != "w" ]] || return 1
  return 0
}

# 単一ディレクトリ要素が非 symlink・所有ディレクトリであることを保証する（不在なら 0700 で作成し、競合済みも検証する）。
ff_session_ace_ensure_dir_one() {
  local dir="$1"
  [[ -n "$dir" && ! -L "$dir" ]] || return 1
  if [[ ! -e "$dir" ]]; then
    (umask 077 && mkdir -- "$dir" 2>/dev/null) || true
  fi
  ff_session_ace_check_owned_dir "$dir"
}

# state_root と配下の metrics(/sessions) を 1 要素ずつ検証・作成する。
ff_session_ace_ensure_metrics_dirs() {
  local state_root="$1" need_sessions="${2:-0}"
  local cur="" pending=() i=0 parent=""

  [[ -n "$state_root" ]] || return 1
  ff_session_ace_check_ancestor_chain "$state_root" || return 1

  cur="$state_root"
  while [[ -n "$cur" && "$cur" != "/" && ! -e "$cur" ]]; do
    [[ ! -L "$cur" ]] || return 1
    pending=("$cur" ${pending[@]+"${pending[@]}"})
    parent="${cur%/*}"
    [[ -n "$parent" ]] || parent="/"
    [[ "$parent" != "$cur" ]] || break
    cur="$parent"
  done
  i=0
  while [[ "$i" -lt "${#pending[@]}" ]]; do
    ff_session_ace_ensure_dir_one "${pending[$i]}" || return 1
    i=$((i + 1))
  done

  ff_session_ace_ensure_dir_one "$state_root" || return 1
  ff_session_ace_ensure_dir_one "${state_root}/metrics" || return 1
  if [[ "$need_sessions" -eq 1 ]]; then
    ff_session_ace_ensure_dir_one "${state_root}/metrics/sessions" || return 1
  fi
  return 0
}

# 読み取り前に state_root / metrics(/sessions) の安全性を検証する（不在なら作成せず 1 を返す）。
ff_session_ace_verify_metrics_dirs_read() {
  local state_root="$1" need_sessions="${2:-0}"
  [[ -n "$state_root" ]] || return 1
  ff_session_ace_check_ancestor_chain "$state_root" || return 1
  ff_session_ace_check_owned_dir "$state_root" || return 1
  ff_session_ace_check_owned_dir "${state_root}/metrics" || return 1
  if [[ "$need_sessions" -eq 1 ]]; then
    ff_session_ace_check_owned_dir "${state_root}/metrics/sessions" || return 1
  fi
  return 0
}

# 対象ファイルが symlink・ディレクトリ・ハードリンク・他者所有・group/world writable でないことを検証する。
ff_session_ace_check_regular_file() {
  local file="$1" info="" mode="" nlink=""
  [[ -n "$file" && ! -L "$file" ]] || return 1
  if [[ -e "$file" ]]; then
    [[ -f "$file" && -O "$file" ]] || return 1
    info="$(LC_ALL=C ls -l -- "$file" 2>/dev/null | LC_ALL=C awk 'NR==1 { print substr($1, 1, 10) "\t" $2 }')" || return 1
    mode="${info%%$'\t'*}"
    nlink="${info#*$'\t'}"
    [[ "${#mode}" -eq 10 ]] || return 1
    [[ "${mode:0:1}" == "-" && "$nlink" == "1" ]] || return 1
    [[ "${mode:5:1}" != "w" && "${mode:8:1}" != "w" ]] || return 1
  fi
  return 0
}

# ディレクトリを linked worktree 共通のリポジトリ識別子（git common dir 物理絶対パス）へ正規化する。
# 制御文字（タブ・改行・CR 等）を含むパスは拒否する。
ff_session_ace_repo_key() {
  local dir="$1" common="" phys=""
  [[ -n "$dir" && -d "$dir" ]] || return 1
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  if [[ -d "$common" ]]; then
    phys="$(CDPATH='' cd -P -- "$common" 2>/dev/null && pwd -P)" || phys="$common"
  else
    phys="$common"
  fi
  SA_VAL="$phys" LC_ALL=C awk 'BEGIN {
    v = ENVIRON["SA_VAL"]
    if (v == "" || v ~ /[[:cntrl:]]/) exit 1
    printf "%s", v
  }' 2>/dev/null
}

# 確定した知識コミット（pending でない ACE ID 群）を状態ファイルへ fail-soft で追記する（追記専用）。
# TSV 列: <epoch>\t<repo_key>\t<ace_id>\t<commit_sha>\t<env_sid>
ff_session_ace_record_commit() {
  local repo_root="$1" sha="$2" entries_text="$3"
  local state_root="" repo_key="" now_epoch="" env_raw="" env_sid="-" need_sess=0
  local ace_ids="" id="" tsv="" sess_file="" added=0

  [[ -n "$repo_root" && -n "$sha" && -n "$entries_text" ]] || return 0
  sha="${sha//$'\r'/}"
  if ! SA_SHA="$sha" LC_ALL=C awk 'BEGIN {
    s = ENVIRON["SA_SHA"]
    exit (s ~ /^[0-9a-fA-F]+$/ && length(s) >= 7 && length(s) <= 64) ? 0 : 1
  }' 2>/dev/null; then
    return 0
  fi

  ace_ids="$(printf '%s\n' "$entries_text" | LC_ALL=C awk -F '\t' '
    $1 == "E" && $2 == "ace" {
      n = split($3, parts, "/")
      for (i = 1; i <= n; i++) {
        id = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
        if (id ~ /^ACE-[0-9A-Za-z-]+$/ && id !~ /^ACE-pending-/ && id !~ /[[:cntrl:]]/) {
          if (!seen[id]++) print id
        }
      }
    }
  ' 2>/dev/null)" || return 0
  [[ -n "$ace_ids" ]] || return 0

  state_root="$(ff_session_ace_state_root 2>/dev/null)" || return 0
  repo_key="$(ff_session_ace_repo_key "$repo_root" 2>/dev/null)" || return 0
  [[ -n "$repo_key" ]] || return 0

  now_epoch="$(date -u +%s 2>/dev/null)" || return 0
  case "$now_epoch" in
    ''|*[!0123456789]*) return 0 ;;
  esac

  env_raw="${CLAUDE_SESSION_ID:-${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}}"
  if [[ "$(ff_session_ace_sid_class "$env_raw")" == "valid" ]]; then
    env_sid="$env_raw"
    need_sess=1
  fi

  if ! ff_session_ace_ensure_metrics_dirs "$state_root" "$need_sess"; then
    printf '警告: セッション ACE 記録を省略しました（状態ディレクトリの所有者・権限・symlink 検証を満たしません: %s）\n' "$state_root" >&2
    return 0
  fi
  tsv="${state_root}/metrics/session-ace.tsv"
  if ! ff_session_ace_check_regular_file "$tsv"; then
    printf '警告: セッション ACE 記録を省略しました（状態ファイルの所有者・権限・symlink 検証を満たしません: %s）\n' "$tsv" >&2
    return 0
  fi

  (
    umask 077
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$now_epoch" "$repo_key" "$id" "$sha" "$env_sid" >>"$tsv" 2>/dev/null || exit 0
      added=1
    done <<EOF
$ace_ids
EOF
    if [[ "$added" -eq 1 && "$need_sess" -eq 1 ]]; then
      sess_file="${state_root}/metrics/sessions/${env_sid}.ace"
      ff_session_ace_check_regular_file "$sess_file" || exit 0
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if [[ -s "$sess_file" ]] && SA_RK="$repo_key" SA_AID="$id" SA_SHA="$sha" LC_ALL=C awk -F '\t' '
          $1 == ENVIRON["SA_RK"] && $2 == ENVIRON["SA_AID"] && $3 == ENVIRON["SA_SHA"] { found = 1; exit }
          END { exit(found ? 0 : 1) }
        ' "$sess_file" 2>/dev/null; then
          continue
        fi
        printf '%s\t%s\t%s\t%s\n' "$repo_key" "$id" "$sha" "$now_epoch" >>"$sess_file" 2>/dev/null || exit 0
      done <<EOF
$ace_ids
EOF
    fi
  ) || true
  return 0
}

# PostToolUse 側で knowledge-commit commit 完了後の記録を KNOWLEDGE_COMMIT=<sha> 一致のみで session_id に束ねる（追記専用・fail-soft）。
# tool_resp に有効な commit SHA が無い場合は推測（時間窓フォールバック）を行わず何もしない。
ff_session_ace_bind_hook_commit() {
  local sid="$1" tool_resp="$2"
  local sid_class="" state_root="" tsv="" bound_file="" sess_file="" shas="" now_epoch=""
  local matched="" mline="" m_rk="" m_aid="" m_sha="" m_ep=""

  sid_class="$(ff_session_ace_sid_class "$sid")"
  [[ "$sid_class" == "valid" ]] || return 0

  # 有効な commit SHA が無い場合は他セッションの行を奪わないよう即終了する
  shas="$(printf '%s\n' "$tool_resp" | LC_ALL=C awk '
    /^KNOWLEDGE_COMMIT=/ {
      v = substr($0, 18)
      sub(/\r$/, "", v)
      if (v ~ /^[0-9a-fA-F]+$/ && length(v) >= 7 && length(v) <= 64) {
        if (!seen[v]++) out = (out == "" ? v : out "," v)
      }
    }
    END { printf "%s", out }
  ' 2>/dev/null)" || shas=""
  [[ -n "$shas" ]] || return 0

  state_root="$(ff_session_ace_state_root 2>/dev/null)" || return 0
  ff_session_ace_verify_metrics_dirs_read "$state_root" 0 || return 0
  tsv="${state_root}/metrics/session-ace.tsv"
  [[ -f "$tsv" && -s "$tsv" ]] || return 0
  ff_session_ace_check_regular_file "$tsv" || return 0

  ff_session_ace_ensure_metrics_dirs "$state_root" 1 || return 0
  bound_file="${state_root}/metrics/session-ace-bound.tsv"
  sess_file="${state_root}/metrics/sessions/${sid}.ace"
  ff_session_ace_check_regular_file "$bound_file" || return 0
  ff_session_ace_check_regular_file "$sess_file" || return 0

  now_epoch="$(date -u +%s 2>/dev/null)" || now_epoch="0"
  case "$now_epoch" in
    ''|*[!0123456789]*) now_epoch="0" ;;
  esac

  matched="$(SA_SID="$sid" SA_SHAS="$shas" LC_ALL=C awk -F '\t' -v OFS='\t' '
    BEGIN {
      sid = ENVIRON["SA_SID"]
      n = split(ENVIRON["SA_SHAS"], arr, ",")
      for (i = 1; i <= n; i++) {
        if (arr[i] != "") target_sha[arr[i]] = 1
      }
    }
    NF >= 5 {
      ep = $1
      rkey = $2
      aid = $3
      csha = $4
      esid = $5
      if (rkey == "" || rkey ~ /[[:cntrl:]]/) next
      if (aid !~ /^ACE-[0-9A-Za-z-]+$/ || aid ~ /^ACE-pending-/) next
      if (csha !~ /^[0-9a-fA-F]+$/ || length(csha) < 7 || length(csha) > 64) next
      if (esid != "-" && esid != sid) next
      for (s in target_sha) {
        if (csha == s || index(csha, s) == 1 || index(s, csha) == 1) {
          print rkey, aid, csha, ep
          break
        }
      }
    }
  ' "$tsv" 2>/dev/null)" || return 0

  [[ -n "$matched" ]] || return 0

  (
    umask 077
    while IFS= read -r mline; do
      [[ -n "$mline" ]] || continue
      IFS=$'\t' read -r m_rk m_aid m_sha m_ep <<EOF
$mline
EOF
      [[ -n "$m_rk" && -n "$m_aid" && -n "$m_sha" ]] || continue
      if [[ ! -s "$sess_file" ]] || ! SA_RK="$m_rk" SA_AID="$m_aid" SA_SHA="$m_sha" LC_ALL=C awk -F '\t' '
        $1 == ENVIRON["SA_RK"] && $2 == ENVIRON["SA_AID"] && $3 == ENVIRON["SA_SHA"] { found = 1; exit }
        END { exit(found ? 0 : 1) }
      ' "$sess_file" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\n' "$m_rk" "$m_aid" "$m_sha" "$m_ep" >>"$sess_file" 2>/dev/null || exit 0
      fi
      if [[ ! -s "$bound_file" ]] || ! SA_SHA="$m_sha" SA_SID="$sid" LC_ALL=C awk -F '\t' '
        $1 == ENVIRON["SA_SHA"] && $2 == ENVIRON["SA_SID"] { found = 1; exit }
        END { exit(found ? 0 : 1) }
      ' "$bound_file" 2>/dev/null; then
        printf '%s\t%s\t%s\n' "$m_sha" "$sid" "$now_epoch" >>"$bound_file" 2>/dev/null || exit 0
      fi
    done <<EOF
$matched
EOF
  ) || true
  return 0
}

# 対象リポジトリ（および同一 session_id）で記録された確定 ACE ID 群を `, ` 区切りで出力する。
ff_session_ace_lookup_for_repo() {
  local sid="$1" repo_dir="$2"
  local sid_class="" state_root="" repo_key="" sess_file="" tsv="" bound_file="" now_epoch=""

  sid_class="$(ff_session_ace_sid_class "$sid")"
  [[ "$sid_class" != "invalid" ]] || return 0

  state_root="$(ff_session_ace_state_root 2>/dev/null)" || return 0
  repo_key="$(ff_session_ace_repo_key "$repo_dir" 2>/dev/null)" || return 0
  [[ -n "$repo_key" ]] || return 0

  if [[ "$sid_class" == "valid" ]]; then
    ff_session_ace_verify_metrics_dirs_read "$state_root" 1 || return 0
    sess_file="${state_root}/metrics/sessions/${sid}.ace"
    [[ -f "$sess_file" && -s "$sess_file" ]] || return 0
    ff_session_ace_check_regular_file "$sess_file" || return 0
    SA_RK="$repo_key" LC_ALL=C awk -F '\t' '
      BEGIN { rk = ENVIRON["SA_RK"] }
      NF >= 4 && $1 == rk && $2 ~ /^ACE-[0-9A-Za-z-]+$/ && $2 !~ /^ACE-pending-/ && $3 ~ /^[0-9a-fA-F]+$/ && length($3) >= 7 {
        if (!seen[$2]++) {
          out = (out == "" ? $2 : out ", " $2)
        }
      }
      END { if (out != "") printf "%s", out }
    ' "$sess_file" 2>/dev/null || true
    return 0
  fi

  # session_id が空のホスト向けフォールバック: 未束縛行を 12 時間（43200 秒）の窓で読む（既束縛 SHA は除外）
  ff_session_ace_verify_metrics_dirs_read "$state_root" 0 || return 0
  tsv="${state_root}/metrics/session-ace.tsv"
  [[ -f "$tsv" && -s "$tsv" ]] || return 0
  ff_session_ace_check_regular_file "$tsv" || return 0

  bound_file="${state_root}/metrics/session-ace-bound.tsv"
  if [[ -e "$bound_file" || -L "$bound_file" ]]; then
    ff_session_ace_check_regular_file "$bound_file" || return 0
  else
    bound_file=""
  fi

  now_epoch="$(date -u +%s 2>/dev/null)" || return 0
  case "$now_epoch" in
    ''|*[!0123456789]*) return 0 ;;
  esac

  SA_RK="$repo_key" SA_NOW="$now_epoch" SA_BOUND="$bound_file" LC_ALL=C awk -F '\t' '
    BEGIN {
      rk = ENVIRON["SA_RK"]
      now_e = ENVIRON["SA_NOW"] + 0
      bf = ENVIRON["SA_BOUND"]
      if (bf != "") {
        while ((getline line < bf) > 0) {
          split(line, bp, "\t")
          if (bp[1] != "") bound_sha[bp[1]] = 1
        }
        close(bf)
      }
    }
    NF >= 5 && $2 == rk && $5 == "-" && $3 ~ /^ACE-[0-9A-Za-z-]+$/ && $3 !~ /^ACE-pending-/ && $4 ~ /^[0-9a-fA-F]+$/ && length($4) >= 7 {
      if ($4 in bound_sha) next
      diff = now_e - ($1 + 0)
      if (diff >= -5 && diff <= 43200) {
        if (!seen[$3]++) {
          out = (out == "" ? $3 : out ", " $3)
        }
      }
    }
    END { if (out != "") printf "%s", out }
  ' "$tsv" 2>/dev/null || true
  return 0
}
