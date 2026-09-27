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

# 別 worktree に置かれた、このツリーを対象とする生きたレーンを列挙する（Issue `#1935`）。
# レーンは起動したセッションの cwd のツリーに置かれるので、レビュー対象の worktree を cwd とする
# セッションからは自分の `.review-results/` を見ただけでは見えない。同じリポジトリの各 worktree の
# レーン置き場を読み、`tree=` が <ROOT_PHYS> に一致して寿命内のものを数える。読むだけで消さない
# （回収は置き場の持ち主の走査が行う）。symlink の置き場は読まない。
#   ff_lane_foreign_live <ROOT> <ROOT_PHYS> <対応づけ済みの寿命> <未対応づけの寿命>
#     stdout: 1 行 1 本「<perspectives>\t<経過秒>\t<置き場の worktree>」
#     rc: 0 = 判定した（0 本を含む）/ 1 = worktree 一覧を読めない
ff_lane_foreign_live() { # <ROOT> <ROOT_PHYS> <max_age> <pending_age>
  local root="$1" me="$2" max="$3" pend="$4" wl line w d f t e a age limit now match
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
    for f in "$d"/*.lane; do
      [ -f "$f" ] || continue
      match=0
      while IFS= read -r t; do
        [ "$t" = "tree=$me" ] && match=1
      done < "$f"
      [ "$match" -eq 1 ] || continue
      e="$(sed -n 's/^started_epoch=//p' "$f" 2>/dev/null | head -n 1)"
      case "$e" in '' | *[!0-9]*) continue ;; esac
      a="$(sed -n 's/^agent_id=//p' "$f" 2>/dev/null | head -n 1)"
      limit="$max"
      [ -z "$a" ] && [ "$pend" -lt "$max" ] && limit="$pend"
      age=$((now - e))
      [ "$age" -le "$limit" ] && [ "$age" -ge -300 ] || continue
      printf '%s\t%s\t%s\n' "$(sed -n 's/^perspectives=//p' "$f" 2>/dev/null | head -n 1)" "$age" "$w"
    done
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
