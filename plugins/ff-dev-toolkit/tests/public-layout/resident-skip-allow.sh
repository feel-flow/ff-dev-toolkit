# shellcheck shell=bash
#
# public-layout の合成実行で、公開 workflow の「Run public suite set」step の前に置く判定。
# knowledge-lookup-resident-acl を step と同じ PATH の bash で単体で回し、suite 自身が先頭（列 0）に出す
# suite 全体の skip の理由行（常駐 helper の経路を持たない）を見た回だけ、その suite を step の skip 許容名簿へ
# 足す。step へは FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES で渡す（公開側の CI は設定しない。header は
# tests/public-layout/verify.sh）。
#
# 起動 shell の能力はここで調べ直さない。判定は suite の先頭の probe に任せ、その結果の理由行だけを鍵にする
# （環境分岐は能力層の外へ書かない）。字下げした部分 skip の行・別の理由の skip・実際に回った回は許容しない。
#
#   ff_public_layout_resident_skip_allow <plugin root> <ログの置き場>
#     rc 0: 単体実行が緑。理由行つきの suite skip なら ff_public_layout_resident_allowed へ suite 名を入れ、
#           許容した旨の 1 行を stdout へ出す。それ以外の緑は ff_public_layout_resident_allowed を空にする
#     rc 1: suite が無い・ログを書けない・単体実行が赤。ログの末尾と理由を stderr へ出し、
#           ff_public_layout_resident_allowed は空にする（呼び出し側は赤で止める）
#
# 前回の呼び出しの値は持ち越さない（毎回空から始める）。bash 3.2 互換。外部コマンドは env / awk / tail。

ff_public_layout_resident_suite="knowledge-lookup-resident-acl"
ff_public_layout_resident_reason="常駐 helper の経路を持たない"
ff_public_layout_resident_allowed=""

ff_public_layout_resident_skip_allow() {
  local root="${1:-}" log="${2:-}" suite rc=0
  ff_public_layout_resident_allowed=""
  suite="${root}/tests/${ff_public_layout_resident_suite}/verify.sh"
  if [[ -z "$root" || ! -f "$suite" ]]; then
    echo "✗ public-layout: 単体で回す ${ff_public_layout_resident_suite} がありません: ${suite}" >&2
    return 1
  fi
  if [[ -z "$log" ]] || ! { : >"$log"; } 2>/dev/null; then
    echo "✗ public-layout: ${ff_public_layout_resident_suite} の単体実行のログを書けません: ${log}" >&2
    return 1
  fi
  # step と同じく外側の run-all のモード指定を持ち込まない
  env -u FF_RUN_ALL_FULL -u FF_RUN_ALL_FAST -u FF_RUN_ALL_CHANGED bash "$suite" >"$log" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tail -n 20 "$log" >&2
    echo "✗ public-layout: ${ff_public_layout_resident_suite} を単体で回すと赤です（rc=${rc}）。suite skip の許容を判断できないため止めます" >&2
    return 1
  fi
  if LC_ALL=C awk -v mark="○ skip:" -v reason="$ff_public_layout_resident_reason" \
    'index($0, mark) == 1 && index($0, reason) > 0 { hit = 1 } END { exit !hit }' "$log"; then
    ff_public_layout_resident_allowed="$ff_public_layout_resident_suite"
    echo "public-layout: 起動 shell が常駐 helper の経路を持たないため ${ff_public_layout_resident_suite} の suite skip を許容した（suite 自身の skip 理由行で確認。公開側の CI の許容名簿は changelog-public-tags だけのまま）"
  fi
  return 0
}
