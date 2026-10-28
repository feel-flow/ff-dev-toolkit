#!/usr/bin/env bash
#
# レビュー走行中ガード（hooks/guard-review-in-flight.sh）の**レーンの対象ツリー**を決める共有ライブラリ。
# hook がレーンの取得時（`Agent` / `Task` の PreToolUse）に source する。
#
# 何のためにあるか（Issue `#1760` の追記 2 件 / OBS-183 / OBS-299）:
#   レーンはレビューを起動したセッションの cwd のツリー（`<ROOT>/.review-results/`）に置かれる。
#   親が本ツリーに cwd を置いたまま**別 worktree** のレビューを起動すると、レーンは本ツリーに立ち、
#   レビュー対象と無関係な本ツリーの作業（別 worktree の全件ゲート起動・scratchpad への書き込み・
#   knowledge commit）まで凍結していた。凍結が守るのは「レビュー対象のツリーが静止していること」
#   なので、レーンへ**対象ツリー**を記録し、判定はその集合に対して行う。
#
# 決め方: レビューを依頼する prompt に現れる絶対パスのうち、同じリポジトリの worktree
# （`git worktree list --porcelain`）の配下にあるものを拾い、その worktree の toplevel（物理パス）を
# 対象とする。入れ子の worktree は最も深い toplevel に帰属させる。1 本も拾えない回は何も出さない
# （呼び出し側が cwd のツリーを対象にする = 従来と同じ）。
#
# 既知の限界: prompt が別 worktree のパスだけを名指しして cwd のツリーをレビューさせる形
# （「X と比べて」）は、cwd のツリーを対象から外す。レビュー対象のパスを prompt に書く運用
# （委譲プロンプトの対象パス）を前提にしている。
#
# 公開関数:
#   ff_lane_infer_trees <ROOT> <prompt>
#     stdout: 対象ツリーの物理パス（1 行 1 件・重複なし）。拾えなければ空
#     rc: 0 = 判定した（空を含む）/ 1 = worktree 一覧を読めない（呼び出し側は cwd のツリーへ倒す）
# 互換性: bash 3.2（stock macOS）。連想配列・readarray・=~ は使わない。

# 単独sourceでもclaimの私有境界を検証できるよう、既存の共通boundaryを完全に読み込む。
_ff_review_lane_scope_loaded=0
_ff_lane_boundary_lib="${BASH_SOURCE[0]%/*}/../../scripts/lib/multi-agent-boundary.sh"
if [ -L "$_ff_lane_boundary_lib" ] || [ ! -f "$_ff_lane_boundary_lib" ] || [ ! -r "$_ff_lane_boundary_lib" ]; then return 1; fi
_ff_lane_boundary_last="$(awk 'NF { l = $0 } END { print l }' "$_ff_lane_boundary_lib" 2>/dev/null)" || return 1
[ "$_ff_lane_boundary_last" = '_ma_part_loaded="multi-agent-boundary.sh"' ] || return 1
_ma_part_loaded=''
# shellcheck source=../../scripts/lib/multi-agent-boundary.sh
if ! . "$_ff_lane_boundary_lib"; then return 1; fi
[ "${_ma_part_loaded:-}" = multi-agent-boundary.sh ] || return 1
for _ff_lane_required in ff_review_output_prepare ff_review_output_private ff_review_output_regular ff_review_output_marker_matches; do
  [ "$(type -t "$_ff_lane_required" 2>/dev/null)" = function ] || return 1
done

ff_lane_body_field() { # 一度だけ安全に読んだsnapshotのフィールド。
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

ff_lane_record_limit() { # <public|claim> <agent_id> <max> <pending>
  local limit="$3"
  if [ "$1" = public ] && [ -z "$2" ] && [ "$4" -lt "$3" ]; then limit="$4"; fi
  printf '%s\n' "$limit"
}

ff_lane_claim_body_is_valid() {
  printf '%s\n' "$1" | awk '
    /^writer_pid=[0-9]+$/ { seen["writer"]++; next }
    /^task=subagent-review$/ { seen["task"]++; next }
    /^head=.+$/ { seen["head"]++; next }
    /^started=.+$/ { seen["started"]++; next }
    /^started_epoch=[0-9]+$/ { seen["epoch"]++; next }
    /^perspectives=.+$/ { seen["type"]++; next }
    /^agent_id=[A-Za-z0-9_-]*$/ { seen["agent"]++; next }
    END { split("writer task head started epoch type agent", keys, " "); for (i in keys) if (seen[keys[i]] != 1) exit 1 }
  '
}

# ローカルと別worktreeの読み手が同じsnapshot/遷移規則を使う。私有claimは変更しない。
ff_lane_visit_records() { # <lane-dir> <callback> <claims-safe:0|1>
  local dir="$1" callback="$2" claims_safe="$3" pass phase f work body changed index cached rc count=0
  local seen_paths=() seen_bodies=()
  for pass in 1 2 3; do
    changed=0
    # globは各段へ到達してから展開する。公開→claimとclaim→公開の両方向を拾い、
    # 読めたbodyをメモリに保持する。移動のためopenできなかった候補は次の巡で読み直す。
    for phase in public claim public; do
      if [ "$phase" = public ]; then
        for f in "$dir"/*.lane; do
          if [ "$f" = "$dir/*.lane" ] && [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
          if ! ff_review_output_regular "$f" >/dev/null 2>&1 || [ ! -r "$f" ]; then
            { [ -e "$f" ] || [ -L "$f" ]; } || changed=1
            continue
          fi
          if body="$(cat "$f" 2>/dev/null)"; then
            cached=0; index=0
            while [ "$index" -lt "$count" ]; do
              if [ "${seen_paths[$index]}" = "$f" ] && [ "${seen_bodies[$index]}" = "$body" ]; then cached=1; break; fi
              index=$((index + 1))
            done
            [ "$cached" -eq 0 ] || continue
            rc=0; "$callback" "$f" public "$body" || rc=$?
            case "$rc" in
              0) seen_paths[count]="$f"; seen_bodies[count]="$body"; count=$((count + 1)) ;;
              2) changed=1 ;;
              *) return "$rc" ;;
            esac
          else changed=1; fi
        done
      elif [ "$claims_safe" -eq 1 ]; then
        for work in "$dir"/.lane-work.*; do
          ff_review_output_private "$work" true >/dev/null 2>&1 || continue
          f="$work/claimed.lane"
          ff_review_output_regular "$f" >/dev/null 2>&1 && [ -r "$f" ] || continue
          if body="$(cat "$f" 2>/dev/null)"; then
            ff_lane_claim_body_is_valid "$body" || continue
            cached=0; index=0
            while [ "$index" -lt "$count" ]; do
              if [ "${seen_paths[$index]}" = "$f" ] && [ "${seen_bodies[$index]}" = "$body" ]; then cached=1; break; fi
              index=$((index + 1))
            done
            [ "$cached" -eq 0 ] || continue
            rc=0; "$callback" "$f" claim "$body" || rc=$?
            case "$rc" in
              0) seen_paths[count]="$f"; seen_bodies[count]="$body"; count=$((count + 1)) ;;
              2) changed=1 ;;
              *) return "$rc" ;;
            esac
          else changed=1; fi
        done
      fi
    done
    [ "$changed" -eq 1 ] || return 0
  done
  # 見えていた候補が最後まで移動し続けた回を「0本」にしない。安定したrecordはtree=
  # を維持し、この判定不能な遷移だけはcallbackの呼出元targetを保守的に凍結する。
  "$callback" '' unstable ''
}

ff_lane_foreign_record() { # ff_lane_foreign_liveのcallback。me/w/now/max/pendは呼出元local。
  local f="$1" kind="$2" body="$3" t e a age limit match=0
  if [ "$kind" = unstable ]; then printf 'transition\t0\t%s\n' "$w"; return 0; fi
  while IFS= read -r t; do
    [ "$t" = "tree=$me" ] && match=1
  done <<EOF
$body
EOF
  [ "$match" -eq 1 ] || return 0
  e="$(ff_lane_body_field "$body" started_epoch)"
  case "$e" in '' | *[!0-9]*) return 0 ;; esac
  a="$(ff_lane_body_field "$body" agent_id)"
  limit="$(ff_lane_record_limit "$kind" "$a" "$max" "$pend")"
  age=$((now - e))
  [ "$age" -le "$limit" ] && [ "$age" -ge -300 ] || return 0
  printf '%s\t%s\t%s\n' "$(ff_lane_body_field "$body" perspectives)" "$age" "$w"
}

# 別 worktree に置かれた、このツリーを対象とする生きたレーンを列挙する（Issue `#1935`）。
# レーンは起動したセッションの cwd のツリーに置かれるので、レビュー対象の worktree を cwd とする
# セッションからは自分の `.review-results/` を見ただけでは見えない。同じリポジトリの各 worktree の
# レーン置き場を読み、`tree=` が <ROOT_PHYS> に一致して寿命内のものを数える。読むだけで消さない
# （回収は置き場の持ち主の走査が行う）。symlink の置き場は読まない。
#   ff_lane_foreign_live <ROOT> <ROOT_PHYS> <対応づけ済みの寿命> <未対応づけの寿命>
#     stdout: 1 行 1 本「<perspectives>\t<経過秒>\t<置き場の worktree>」
#     rc: 0 = 判定した（0 本を含む）/ 1 = worktree 一覧を読めない
ff_lane_foreign_live() { # <ROOT> <ROOT_PHYS> <max_age> <pending_age>
  local root="$1" me="$2" max="$3" pend="$4" wl line w d now claims_safe w_phys
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in '' | *[!0-9]*) return 1 ;; esac
  wl="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in 'worktree '*) : ;; *) continue ;; esac
    w="${line#worktree }"
    [ "$(cd "$w" 2>/dev/null && pwd -P 2>/dev/null)" != "$me" ] || continue
    d="${w}/.review-results/.review-in-flight.d"
    [ -d "$d" ] || continue
    [ -L "${w}/.review-results" ] && continue
    [ -L "$d" ] && continue
    claims_safe=0
    w_phys="$(cd "$w" 2>/dev/null && pwd -P 2>/dev/null)"
    if ff_review_output_private "${w}/.review-results" true >/dev/null 2>&1 \
      && ff_review_output_private "$d" >/dev/null 2>&1 \
      && ff_review_output_marker_matches "${w}/.review-results/.multi-agent-output-owner" "$w_phys" "${w_phys}/.review-results" >/dev/null 2>&1; then
      claims_safe=1
    fi
    ff_lane_visit_records "$d" ff_lane_foreign_record "$claims_safe" || return 1
  done <<EOF
$wl
EOF
  return 0
}

ff_lane_infer_trees() { # <ROOT> <prompt>
  local root="$1" prompt="$2" wl line w p cands c best bestlen out="" pairs=""
  wl="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) : ;;
      *) continue ;;
    esac
    w="${line#worktree }"
    [ -d "$w" ] || continue
    p="$(cd "$w" 2>/dev/null && pwd -P 2>/dev/null)"
    [ -n "$p" ] || continue
    pairs="${pairs}${w}	${p}
"
  done <<EOF
$wl
EOF
  [ -n "$pairs" ] || return 0
  cands="$(printf '%s\n' "$prompt" | LC_ALL=C grep -oE '/[^][:space:]"'"'"'`<>|;,()[]+' 2>/dev/null)" || cands=""
  while IFS= read -r c; do
    # 文末の句読点（`…/repo.` / `…/repo。`）はパスの一部ではない。C ロケールのバイト単位で落とす
    # （bash の case の範囲式は照合順序に依存するので使わない）
    c="$(printf '%s' "$c" | LC_ALL=C sed -E 's/([.:!?]|[^ -~])+$//')"
    [ -n "$c" ] || continue
    best=""
    bestlen=0
    while IFS='	' read -r w p; do
      [ -n "$w" ] || continue
      for line in "$w" "$p"; do
        case "$c" in
          "$line" | "$line"/*)
            if [ "${#line}" -gt "$bestlen" ]; then
              best="$p"
              bestlen="${#line}"
            fi
            ;;
        esac
      done
    done <<EOF
$pairs
EOF
    [ -n "$best" ] || continue
    case "
${out}" in
      *"
${best}
"*) : ;;
      *) out="${out}${best}
" ;;
    esac
  done <<EOF
$cands
EOF
  printf '%s' "$out"
  return 0
}

_ff_review_lane_scope_loaded=1
