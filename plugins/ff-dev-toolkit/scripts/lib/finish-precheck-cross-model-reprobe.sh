#!/usr/bin/env bash
# finish.sh の precheck 構成ファイル（クロスモデルレビュー未実施時の再プローブ記録検査。Issue `#2893`）。
# finish-precheck.sh と同じく入口が検査して source する。関数の定義だけを置き、読み込み完了は末尾の sentinel で確認する。
# bash 3.2 互換。OS 固有の date フラグ・環境分岐を使わず、純粋 awk で ISO 8601 時刻を UTC epoch 秒へ変換する。
# pipefail-inherited: finish.sh が set -uo pipefail の下で source する

if [[ "${_finish_precheck_loading:-}" != "1" ]]; then
  echo "finish-precheck-cross-model-reprobe.sh は finish.sh precheck から読み込んでください" >&2
  exit 2
fi

# ── クロスモデルレビュー未実施時の再プローブ記録 ──
# PR 本文に cross-model 未実施の記録（REVIEW_INFRA_FAILURE / 「cross-model 未実施」等）がある PR は、
# マージ前に最新の PR head より新しい再プローブの記録行（例: 再プローブ: PREFLIGHT=<verdict>（<時刻>））を求める。
# 未実施の記録が無い PR（対象外）は、stdout にも stderr にも 1 行も出さず従来どおり通す。
# 最初の一致の後も入力を最後まで読む（上流の SIGPIPE + pipefail で一致を落とさない）。

# ISO 8601 / UTC / JST のタイムゾーン付き日時を UTC epoch 秒へ変換する共通 awk 関数定義。
# 受理形式: YYYY-MM-DD[T ]HH:MM[:SS][.fraction][ ]?(Z|UTC|JST|[+-]HH:?MM)
# タイムゾーン無し・日付のみ・存在しない月日/時刻・1970 年未満は -1（曖昧な時刻を未来へ倒さない）。
_FF_CM_AWK_TS_FUNCS='
  function is_leap(y) {
    return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))
  }
  function days_in_month(y, m) {
    if (m == 2) return is_leap(y) ? 29 : 28
    if (m == 4 || m == 6 || m == 9 || m == 11) return 30
    return 31
  }
  function days_from_civil(y, m, d,    yr, era, yoe, doy, doe) {
    yr = (m <= 2) ? y - 1 : y
    era = int(yr / 400)
    if (yr < 0 && yr % 400 != 0) era--
    yoe = yr - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
  }
  function parse_ts(s,    y, mo, d, h, mi, sec, rest, tz_off, sign, tz_body, tzh, tzm, days, ep) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9](:[0-9][0-9](\.[0-9]+)?)?[ ]?(Z|UTC|JST|[+-][0-9][0-9]:?[0-9][0-9])$/) return -1
    y = substr(s, 1, 4) + 0
    mo = substr(s, 6, 2) + 0
    d = substr(s, 9, 2) + 0
    h = substr(s, 12, 2) + 0
    mi = substr(s, 15, 2) + 0
    rest = substr(s, 17)
    sec = 0
    if (substr(rest, 1, 1) == ":") {
      sec = substr(rest, 2, 2) + 0
      rest = substr(rest, 4)
      if (substr(rest, 1, 1) == ".") {
        sub(/^\.[0-9]+/, "", rest)
      }
    }
    sub(/^ /, "", rest)
    if (y < 1970 || y > 9999 || mo < 1 || mo > 12 || d < 1 || d > days_in_month(y, mo)) return -1
    if (h < 0 || h > 23 || mi < 0 || mi > 59 || sec < 0 || sec > 59) return -1
    if (rest == "Z" || rest == "UTC") {
      tz_off = 0
    } else if (rest == "JST") {
      tz_off = 9 * 3600
    } else {
      sign = (substr(rest, 1, 1) == "+") ? 1 : -1
      tz_body = substr(rest, 2)
      sub(/:/, "", tz_body)
      tzh = substr(tz_body, 1, 2) + 0
      tzm = substr(tz_body, 3, 2) + 0
      if (tzh > 23 || tzm > 59) return -1
      tz_off = sign * (tzh * 3600 + tzm * 60)
    }
    days = days_from_civil(y, mo, d)
    ep = days * 86400 + h * 3600 + mi * 60 + sec - tz_off
    if (ep < 0) return -1
    return ep
  }
'

# stdin: PR 本文 / stdout: cross-model 未実施の記録として認める最初の可視行（無ければ空）。
# コードフェンス・HTML コメント内は ff_precheck_scan_lines visible で除外し、引用行（`>` およびリスト内引用 `- >` / `1. >`）も数えない。
ff_precheck_cross_model_skip_line() {
  ff_precheck_scan_lines visible | LC_ALL=C awk '
    BEGIN { found = "" }
    found != "" { next }
    {
      # 行頭の引用およびリスト内の引用（- > ... / 1. > ...）は除外する
      if ($0 ~ /^[[:space:]]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)*>/) next
      # REVIEW_INFRA_FAILURE は識別子境界で一致（バッククォートや括弧の中も記録として拾う）
      if ($0 ~ /(^|[^A-Za-z0-9_])REVIEW_INFRA_FAILURE([^A-Za-z0-9_]|$)/) {
        found = $0
        next
      }
      # cross-model / クロスモデル + 未実施（ASCII は大小区別なし。日本語バイトは LC_ALL=C で保全。
      # 同梱 PR テンプレートの「クロスモデルレビュー（…）: 未実施」やテーブル区切り「|」も拾う。
      # LC_ALL=C の否定文字クラス [^）] は 3 バイト（0xEF/0xBC/0x89）の単一バイト否定になり
      # 全角括弧内の「ー」「ド」「／」等で一致が破綻するため、index() で全角括弧ペアを空白へ畳む）
      low = tolower($0)
      norm = low
      lp = "（"; rp = "）"; lpl = length(lp); rpl = length(rp)
      while ((p = index(norm, lp)) > 0) {
        q = index(substr(norm, p + lpl), rp)
        if (!q) break
        norm = substr(norm, 1, p - 1) " " substr(norm, p + lpl + q + rpl - 1)
      }
      if (norm ~ /(cross[- ]model|クロスモデル)([[:space:]*_`|:-]|レビュー|review|：|—|–|・|\([^)]*\))*未実施/) {
        found = $0
        next
      }
    }
    END { if (found != "") print found }'
}

ff_precheck_iso8601_to_epoch() { # <timestamp> → stdout: epoch 秒 / rc 1
  printf '%s\n' "$1" | LC_ALL=C awk "${_FF_CM_AWK_TS_FUNCS}"'
    {
      ep = parse_ts($0)
      if (ep < 0) exit 1
      printf "%.0f\n", ep
      ok = 1
    }
    END { if (!ok) exit 1 }'
}

# stdin: PR 本文 / stdout: <status>\t<max_epoch>\t<line>
#   status = valid（有効行が 1 件以上。最大 epoch の行を返す）
#          | invalid（行頭「再プローブ:」行はあるが、有効な PREFLIGHT=<verdict>（<TZ付き時刻>）が 0 件）
#          | missing（行頭「再プローブ:」行が 0 件）
# フェンス・HTML コメント・引用行・地の文言及は数えない。
ff_precheck_cross_model_reprobe_scan() {
  ff_precheck_scan_lines visible | LC_ALL=C awk "${_FF_CM_AWK_TS_FUNCS}"'
    BEGIN {
      key = "再プローブ"
      colon = "："
      lparen = "（"
      rparen = "）"
      best_ep = -1
      best_line = ""
      invalid_line = ""
    }
    {
      if ($0 ~ /^[[:space:]]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)*>/) next
      i = index($0, key)
      if (!i) next
      if (substr($0, 1, i - 1) !~ /^[[:space:]*_+0-9.)-]*$/) next
      rest = substr($0, i + length(key))
      sub(/^[[:space:]*_]*/, "", rest)
      if (substr(rest, 1, 1) == ":") rest = substr(rest, 2)
      else if (substr(rest, 1, length(colon)) == colon) rest = substr(rest, length(colon) + 1)
      else next

      # ここで行頭「再プローブ:」行と確定。太字内コロン（**再プローブ:** PREFLIGHT=...）も含めて装飾と空白を剥がす。
      val = rest
      sub(/^[[:space:]*_`]+/, "", val)
      if (substr(val, 1, 10) != "PREFLIGHT=") {
        invalid_line = $0
        next
      }
      after_pf = substr(val, 11)
      # verdict は非空の識別子（<verdict> などのプレースホルダは不可）
      if (!match(after_pf, /^[A-Za-z0-9_.-]+/)) {
        invalid_line = $0
        next
      }
      after_v = substr(after_pf, RLENGTH + 1)
      sub(/^[[:space:]*_`]*/, "", after_v)
      # 括弧（全角または半角）から時刻部分を取り出す
      inner = ""
      if (substr(after_v, 1, length(lparen)) == lparen) {
        s2 = substr(after_v, length(lparen) + 1)
        j = index(s2, rparen)
        if (!j) { invalid_line = $0; next }
        inner = substr(s2, 1, j - 1)
      } else if (substr(after_v, 1, 1) == "(") {
        s2 = substr(after_v, 2)
        j = index(s2, ")")
        if (!j) { invalid_line = $0; next }
        inner = substr(s2, 1, j - 1)
      } else {
        invalid_line = $0
        next
      }
      sub(/^[[:space:]]+/, "", inner)
      sub(/[[:space:]]+$/, "", inner)
      # 括弧内の先頭に時刻があり、後ろに補足（/ , ; 空白+説明）が続いても時刻トークンを切り出す
      ts = ""
      if (match(inner, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9](:[0-9][0-9](\.[0-9]+)?)?[ ]?(Z|UTC|JST|[+-][0-9][0-9]:?[0-9][0-9])/)) {
        tail = substr(inner, RLENGTH + 1)
        if (tail == "" || tail ~ /^([[:space:]]|[\/,;]|、|・)/) {
          ts = substr(inner, 1, RLENGTH)
        }
      }
      if (ts == "") {
        invalid_line = $0
        next
      }
      ep = parse_ts(ts)
      if (ep < 0) {
        invalid_line = $0
        next
      }
      if (ep > best_ep) {
        best_ep = ep
        best_line = $0
      }
    }
    END {
      if (best_ep >= 0) {
        printf "valid\t%.0f\t%s\n", best_ep, best_line
      } else if (invalid_line != "") {
        printf "invalid\t\t%s\n", invalid_line
      } else {
        printf "missing\t\t\n"
      }
    }'
}

# PR の head コミットの時刻（UTC epoch 秒）を返す。手元 git を正本にし、無ければ API commits[].committedDate を使う。
ff_precheck_head_commit_epoch() { # <PR JSON> <head OID> → stdout: epoch 秒 / 取得不能は rc 1
  local pr_json="$1" head_oid="$2" ep="" api_ts=""
  case "$head_oid" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  ep="$(git -C "$repo_root" show -s --format='%ct' "${head_oid}^{commit}" -- 2>/dev/null | tr -d '\r')" || ep=""
  case "$ep" in
    ''|*[!0-9]*) ep="" ;;
    *) printf '%s\n' "$ep"; return 0 ;;
  esac
  api_ts="$(printf '%s' "$pr_json" | jq -r --arg oid "$head_oid" '
    ([(.commits // [])[] | select(.oid == $oid) | (.committedDate // "")] | .[0] // "")
  ' 2>/dev/null | tr -d '\r')" || api_ts=""
  if [[ -n "$api_ts" ]]; then
    ep="$(ff_precheck_iso8601_to_epoch "$api_ts")" || ep=""
    if [[ -n "$ep" ]]; then
      printf '%s\n' "$ep"
      return 0
    fi
  fi
  return 1
}

ff_precheck_cross_model_reprobe() { # <PR JSON> <base> <head OID> <PR 本文> [head ref]
  local pr_json="$1" base_ref="$2" head_oid="$3" body_text="$4" head_ref="${5:-}"
  local skip_line="" skip_rc=0 scan="" scan_rc=0 status="" rest="" reprobe_epoch="" record_line="" head_epoch=""
  local reason="" next="" format_hint="" fetch_target=""
  skip_line="$(printf '%s\n' "$body_text" | ff_precheck_cross_model_skip_line)" || skip_rc=$?
  [[ "$skip_rc" -eq 0 ]] || die_env "PR 本文の cross-model 未実施記録の検査に失敗しました（rc=${skip_rc}）" "awk が通る状態で finish.sh precheck を再実行する"
  # 未実施の記録が無い PR 本文は対象外 — 従来どおり何も出さない
  [[ -n "$skip_line" ]] || return 0

  echo "CROSS_MODEL_SKIP_RECORD=${skip_line}"
  scan="$(printf '%s\n' "$body_text" | ff_precheck_cross_model_reprobe_scan)" || scan_rc=$?
  [[ "$scan_rc" -eq 0 ]] || die_env "PR 本文の再プローブ記録の検査に失敗しました（rc=${scan_rc}）" "awk が通る状態で finish.sh precheck を再実行する"
  status="${scan%%$'\t'*}"
  rest="${scan#*$'\t'}"
  reprobe_epoch="${rest%%$'\t'*}"
  record_line="${rest#*$'\t'}"

  format_hint="再プローブ: PREFLIGHT=<verdict>（<タイムゾーン付き ISO 8601 時刻。例: 2026-11-20T12:34:56Z または 2026-11-20T21:34:56+09:00>）"
  case "$status" in
    missing)
      echo "CROSS_MODEL_REPROBE_GATE=missing"
      reason="PR 本文に cross-model 未実施の記録（CROSS_MODEL_SKIP_RECORD=）がありますが、マージ前の再プローブ記録行がありません"
      next="導入先の文書にある再プローブ手順で cross-model レビューの疎通・利用枠を再確認する。再プローブが ok なら cross-model レビューを実施してからマージし、失敗なら PR 本文に「${format_hint}」の行を追記してから finish.sh precheck を再実行する"
      ;;
    invalid)
      echo "CROSS_MODEL_REPROBE_GATE=invalid"
      echo "CROSS_MODEL_REPROBE_RECORD=${record_line}"
      reason="PR 本文に再プローブ行はありますが、書式または時刻（タイムゾーン付き ISO 8601）を解釈できません"
      next="導入先の文書にある再プローブ手順で再確認し、PR 本文の記録行を「${format_hint}」の書式（Z / UTC / JST / +09:00 等のタイムゾーン必須）で書き直してから finish.sh precheck を再実行する"
      ;;
    valid)
      if ! head_epoch="$(ff_precheck_head_commit_epoch "$pr_json" "$head_oid")"; then
        echo "CROSS_MODEL_REPROBE_GATE=unknown"
        echo "CROSS_MODEL_REPROBE_RECORD=${record_line}"
        reason="PR の head コミット時刻を取得できないため、再プローブ記録の鮮度を照合できません"
        case "$head_oid" in
          ''|*[!0-9a-fA-F]*) fetch_target="$head_ref" ;;
          *) fetch_target="$head_oid" ;;
        esac
        if [[ -n "$fetch_target" ]]; then
          next="先に $(ff_shell_argv git fetch origin "$base_ref" "$fetch_target") で PR の head コミットを取り込んでから finish.sh precheck を再実行する。再プローブ記録は PR の head より新しい時刻の「${format_hint}」が必要（再プローブ手順は導入先の文書を参照）"
        else
          next="先に $(ff_shell_argv git fetch origin "$base_ref") で PR の最新コミットを取り込んでから finish.sh precheck を再実行する。再プローブ記録は PR の head より新しい時刻の「${format_hint}」が必要（再プローブ手順は導入先の文書を参照）"
        fi
      elif [[ "$reprobe_epoch" -gt "$head_epoch" ]]; then
        echo "CROSS_MODEL_REPROBE_GATE=fresh"
        echo "CROSS_MODEL_REPROBE_RECORD=${record_line}"
        return 0
      else
        echo "CROSS_MODEL_REPROBE_GATE=stale"
        echo "CROSS_MODEL_REPROBE_RECORD=${record_line}"
        reason="PR 本文の再プローブ記録が PR の head コミットより新しくありません（最新の head に対して再プローブされていません）"
        next="導入先の文書にある再プローブ手順で最新の head に対して再確認する。再プローブが ok なら cross-model レビューを実施してからマージし、失敗なら head より新しい時刻で「${format_hint}」を PR 本文へ追記してから finish.sh precheck を再実行する"
      fi
      ;;
    *)
      die_env "再プローブ記録の判定に失敗しました（status=${status:-（空）}）" "awk が通る状態で finish.sh precheck を再実行する"
      ;;
  esac

  if [[ -z "$blocked_reason" ]]; then
    blocked_reason="$reason"
    blocked_next="$next"
  else
    blocked_reason="${blocked_reason}／さらに${reason}"
    blocked_next="${blocked_next}。あわせて、${next}"
  fi
  return 0
}

_finish_precheck_cross_model_reprobe_loaded=1
