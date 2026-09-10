#!/usr/bin/env bash
# utf8-locale.sh — マルチバイト正規表現を持つ suite のロケールを UTF-8 に固定する共通処理。
#
# 背景: Claude Code cloud など `LANG` / `LC_ALL` / `LC_CTYPE` が未設定（実効 LC_CTYPE=POSIX）の
# 環境では、`[^）]*` や `[^[:alnum:]_./-]*` のように日本語を含む・日本語を飲み込む正規表現が
# バイト列として評価され、docs-gates / docs-gates-runtime が docs の内容と無関係に赤になる
# （2026-09-08 のクラウド実測。`LC_ALL=C.UTF-8` を付けると全件 pass した）。
#
# 方針（Phase B 設計書 docs/superpowers/specs/2026-09-10-cloud-env-setup.md）:
#   - 正規表現をバイト非依存へ書き換える案は、対象 needle が多数（docs-gates だけで
#     数百件）で退行検出の再実測も要るため採らない。suite 側の入口で 1 回ロケールを固定する
#     最小変更にする
#   - 既に実効 LC_CTYPE が UTF-8 なら何もしない（利用者の ja_JP.UTF-8 等を上書きしない）
#   - `locale -a` に C.UTF-8 / C.utf8 / en_US.UTF-8 のいずれかがあればそれを LC_ALL に export する
#   - 無ければ 1 行警告して続行する（fail-closed にはしない: ロケール不在は環境都合であり、
#     赤になる検査は docs-gates 側が具体名で報告する）
#
# 使い方: `. "$SCRIPT_DIR/../lib/utf8-locale.sh"` のあと `ff_ensure_utf8_locale`。
# bash 3.2 互換。`set -euo pipefail` 下で動く。`grep -q` をパイプ下流に置かない。
#
# テストシーム:
#   FF_UTF8_LOCALE_CMD   `locale` コマンドの差し替え（既定: locale）。
#                        stub で `locale -a` の出力と実効 LC_CTYPE を差し替えて分岐を実測する

# 実効 LC_CTYPE を返す（`locale` が無ければ空）。
ff_effective_ctype() {
  local cmd="${FF_UTF8_LOCALE_CMD:-locale}" out
  command -v "$cmd" >/dev/null 2>&1 || { printf '%s\n' ""; return 0; }
  out="$("$cmd" 2>/dev/null | sed -n 's/^LC_CTYPE=//p' | head -n 1 | tr -d '"' || true)"
  printf '%s\n' "$out"
}

# `locale -a` から使える UTF-8 ロケール名を 1 つ返す（優先順: C.UTF-8 → C.utf8 → en_US.UTF-8）。
# 無ければ空を返す。
ff_pick_utf8_locale() {
  local cmd="${FF_UTF8_LOCALE_CMD:-locale}" list cand
  command -v "$cmd" >/dev/null 2>&1 || { printf '%s\n' ""; return 0; }
  list="$("$cmd" -a 2>/dev/null || true)"
  for cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    # 行単位で一致させる（部分文字列で拾わない）。here-string は書き込み可能な TMPDIR を
    # 要求する（bash が一時ファイルへ落とす）ので、外部プロセスも一時領域も要らない case で見る
    case "
${list}
" in
      *"
${cand}
"*)
        printf '%s\n' "$cand"
        return 0
        ;;
    esac
  done
  printf '%s\n' ""
}

# 実効 LC_CTYPE が UTF-8 でなければ UTF-8 ロケールを LC_ALL に固定する。
# 戻り値は常に 0（固定できないときは stderr へ 1 行警告）。
ff_ensure_utf8_locale() {
  local ctype pick
  ctype="$(ff_effective_ctype)"
  case "$ctype" in
    *UTF-8*|*utf8*|*UTF8*|*utf-8*) return 0 ;;
  esac
  pick="$(ff_pick_utf8_locale)"
  if [ -n "$pick" ]; then
    export LC_ALL="$pick"
    echo "ℹ️  実効 LC_CTYPE が UTF-8 でない（${ctype:-unset}）ため LC_ALL=${pick} に固定しました（マルチバイト正規表現を持つ検査のため）" >&2
  else
    echo "⚠️  UTF-8 ロケールが無いため（LC_CTYPE=${ctype:-unset}、locale -a に C.UTF-8 / en_US.UTF-8 なし）docs-gates / docs-gates-runtime ほかマルチバイト正規表現を持つ suite は誤判定します" >&2
  fi
  return 0
}
