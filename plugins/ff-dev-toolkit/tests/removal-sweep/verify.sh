#!/usr/bin/env bash
#
# removal-sweep スキルの 3 系統走査契約の検査（Issue #991）。
#
# 撤去（機能・設定・UI 要素の削除）PR の残存参照は、識別子 / 表示文言 /
# 構造セレクタ・モック応答という**互いに独立した 3 つの結合チャネル**で漏れる。
# 実際に、識別子 grep のみの撤去 PR が E2E の日本語表示文言
# （getByRole の name にロケール実文字列）で漏れ、その学びを踏まえて 2 系統
# （識別子 + 表示文言）を実施し「残存参照なし」と明記した次の撤去 PR ですら、
# CSS クラスの可視性 + モック応答（撤去対象の名前を含まないデータが撤去した
# 分岐を発火させる形）という 3 つ目のチャネルで漏れた。プレイブックの知見は
# 「思い出すもの」なので同一セッション内でも効かず、チェックリストとして
# 機械的に走らせる必要がある — というのが本スキルの存在理由であり、本 suite は
# その 3 系統が SKILL.md から**個別に**消えないことを fail-closed で固定する。
#
# 検査:
#   A. frontmatter の name が directory 名と一致し、description が撤去系の
#      発火条件を含む
#   B. 3 系統の見出しがすべて在る（1 系統でも落ちたら赤 — 「2 系統で十分」への
#      後退がこのスキルが防ぐ事故そのもの）
#   C. 系統ごとの針: 系統 1 = camelCase / snake_case 両表記・型名・定数名、
#      系統 2 = i18n の値を開くこと・ja / en 双方、系統 3 = CSS クラス・
#      getByRole・data-testid・撤去対象を発火させる入力値（モック応答）
#   D. E2E / スナップショット / a11y テストを名指しで走査対象に含める記述
#   E. E2E がデプロイ済み成果物（ウィジェット・SDK・CDN バンドル）を指す構成では
#      ブランチで検出できない、という警告
#   F. 完了条件が「3 系統すべて」と grep 語の PR 記載を要求する（実施した系統
#      だけ書いて完了にする後退を防ぐ）
#
# 針はすべて literal（grep -F）で SKILL.md 本文から照合する。言い換えで針が
# 空振りしたら赤 = 表現を変えるときは本 suite も同時に更新する（docs-fact-drift
# と同じ運用）。外部コマンド・一時領域・ネットワーク不要。
#
# 検査 C の針が過去の漏れ 2 クラスを覆うことの机上対応:
#   - 表示文言クラス（日本語ラベルで getByRole 結合）→ C2 の「i18n の値・
#     ja / en 双方」+ D の E2E 名指し
#   - 構造セレクタ + モック応答クラス（CSS クラス可視性 + 空配列レスポンス）
#     → C3 の「CSS クラス」「発火させる入力値」+ D のスナップショット名指し

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/removal-sweep/SKILL.md"

[ -f "$SKILL" ] || { echo "✗ SKILL.md が見つかりません: $SKILL" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# literal 針の照合。ファイルを直接読む grep なので pipefail の SIGPIPE 反転は
# 起きない（tests/run-all/verify.sh case 10 の対象外の形）。
need() { # $1=検査ラベル $2=literal 針
  if grep -qF -- "$2" "$SKILL"; then
    ok "$1"
  else
    bad "$1 — 針が見つかりません: $2"
  fi
}

echo "== A. frontmatter =="
if grep -qE '^name: removal-sweep$' "$SKILL"; then
  ok "frontmatter name が removal-sweep"
else
  bad "frontmatter name が removal-sweep ではありません"
fi
# description の針は本文ではなく frontmatter の description 行そのものへ当てる
# （本文にも同じ語が出るため、whole-file grep だと description の後退が緑で通る）
DESC_LINE="$(grep -m1 '^description:' "$SKILL" || true)"
if [ -z "$DESC_LINE" ]; then
  bad "frontmatter に description 行がありません"
else
  for pair in \
    "description が撤去系の発火条件を含む|撤去" \
    "description が 3 系統の完走を要求する|3 系統" \
  ; do
    label="${pair%%|*}"; needle="${pair#*|}"
    case "$DESC_LINE" in
      *"$needle"*) ok "$label" ;;
      *) bad "$label — description 行に針がありません: $needle" ;;
    esac
  done
fi

echo "== B. 3 系統の見出し =="
need "系統 1（識別子）の見出し" "系統 1: 識別子"
need "系統 2（表示文言）の見出し" "系統 2: 表示文言"
need "系統 3（構造セレクタ・モック応答）の見出し" "系統 3: 構造セレクタ・モック応答"

echo "== C. 系統ごとの針 =="
need "C1: camelCase / snake_case の両表記" "camelCase / snake_case の両方"
need "C1: 型名の走査" "型名"
need "C1: 定数名の走査" "定数名"
need "C2: i18n の値を開いて確認する" "i18n リソースの**値を開き**"
need "C2: ja / en 双方で grep" "ja / en 双方"
need "C3: CSS クラス" "CSS クラス"
need "C3: getByRole セレクタ" "getByRole"
need "C3: data-testid セレクタ" "data-testid"
need "C3: 撤去対象を発火させる入力値（モック応答）" "発火させる入力値"

echo "== D. テスト資産の名指し走査 =="
need "E2E / スナップショット / a11y の名指し" "E2E / スナップショット / a11y テストのディレクトリは名指しで走査対象に含める"

echo "== E. デプロイ済み成果物の警告 =="
need "デプロイ済み成果物を指す構成の警告見出し" "E2E がデプロイ済み成果物を指す構成"
need "ブランチでは検出できない旨" "ブランチ上の E2E では検出できない"
need "対象構成の例示（ウィジェット・SDK・CDN）" "埋め込みウィジェット・公開 SDK・CDN 配信バンドル"
need "デプロイ後の再検証計画を PR に明記" "デプロイ後に E2E を再実行して検証する"

echo "== F. 完了条件 =="
need "3 系統すべての実施を完了条件にする" "3 系統すべてを実施した"
need "系統ごとの grep 語を PR 本文へ記載する" "grep 語"
need "1 系統の緑を全体の緑と読み替えない" "「識別子で grep して 0 件」を「残存参照なし」と読み替えない"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ removal-sweep: ${FAIL} 件失敗（pass ${PASS}）" >&2
  exit 1
fi
echo "✓ removal-sweep: 全 ${PASS} 件 pass"
