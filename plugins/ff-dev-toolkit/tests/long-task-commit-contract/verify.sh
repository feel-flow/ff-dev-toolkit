#!/usr/bin/env bash
#
# long-task-commit-contract: 長時間タスク委譲の「こまめコミット」契約の回帰検査（Issue #913）。
#
# 守っている事故: 大規模タスク（15 ファイル規模）を委譲したエージェントが 600 秒
# ストールし、ブランチはコミットゼロで成果全損した実測がある。委譲プロンプトへ
# 「論理的なまとまりごとに commit + push」を明記しフェーズ分割することが対策だが、
# この契約は文書の文言だけが防御であり、文言が消えれば防御はゼロになる。
# 機械の代わりに文を固定する、という位置付けは review-freeze-contract と同じ。
#
# 正本は multi-cli-agent-orchestration.md の「長時間タスクの委譲契約（こまめコミット）」節。
# 消費側 multi-implement/SKILL.md は正本への参照だけを持つ（複製しない）。片方が
# 消えると、正本の規定が実際に委譲を行う読者へ届かなくなる。
#
# 節スコープ照合: 規定本体は正本文書の節を切り出してから照合する。同じ趣旨の文が
# 別の節へ散っただけで緑になると、実際に読まれる場所から規定が消えていても検出
# できない（review-freeze-contract / ACE-810-1 と同じ理由）。節の抽出は fail-closed:
# 開始見出しは完全一致で開き、再入（同じ見出しが 2 度現れる）と終端見出し（次の
# `## ` 見出し）へ未到達のまま EOF へ抜ける形はいずれも中断する。
#
# 一時領域も git も要らない静的検査で、skip 経路を持たない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/long-task-commit-contract/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

ORCHESTRATION="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-agent-orchestration.md"
MULTI_IMPLEMENT="$PLUGIN_ROOT/skills/multi-implement/SKILL.md"

# 節の見出し（完全一致で使う）。消費側リンクのアンカーはこの文字列から導出される
# ため、変えるなら multi-implement/SKILL.md のリンクも同時に直す必要がある。
CONTRACT_HEADING='## 長時間タスクの委譲契約（こまめコミット）'

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

for f in "$ORCHESTRATION" "$MULTI_IMPLEMENT"; do
  [[ -s "$f" ]] || {
    echo "  ✗ 必須ファイルが存在し非空: $f" >&2
    echo "✗ long-task-commit-contract verify: 必須ファイル欠落のため中断" >&2
    exit 1
  }
done

# 見出しから次の `## ` 見出し直前までを取り出す。開始は完全一致、再入と終端未到達は
# いずれも非 0（呼び出し側が fail-closed にできる）。
extract_section() { # <完全一致の見出し> <ファイル> / stdout: 節本文
  awk -v h="$1" '
    $0 == h { if (opened) reopened = 1; opened = 1; inside = 1; next }
    inside && /^## / { inside = 0; closed = 1 }
    inside { print }
    END { if (!opened || !closed || reopened) exit 1 }
  ' "$2"
}

# grep の rc は 0=一致 / 1=不一致 / 2 以上=検査そのものの失敗。3 つを同一視すると
# 「ファイルを読めなかった」が「文言が消えた」という別の診断へ化ける。
doc_has() { # <ファイル> <表示名> <needle> <ラベル>
  [[ -n "$3" ]] || { bad "針が空です（検査が無意味）: $4"; return 0; }
  local rc=0
  grep -qF -- "$3" "$1" || rc=$?
  case "$rc" in
    0) ok "$4" ;;
    1) bad "${4}（$2 に不足: $3）" ;;
    *) bad "${4}（$2 を検査できません — grep rc=${rc}。文言の不足とは別の失敗）" ;;
  esac
}

# 節スコープ用。`[[ == *"$needle"* ]]` のクォート済み右辺はリテラル一致で、
# `*` `?` `[` を含む針もそのままの文字として照合される（現に `**...**` の針が動く）。
# 針は 1 行に収まる文字列に限る（節本文は複数行で、改行をまたぐ針は一致しない）。
section_has() { # <節本文> <表示名> <needle> <ラベル>
  [[ -n "$3" ]] || { bad "針が空です（検査が無意味）: $4"; return 0; }
  if [[ "$1" == *"$3"* ]]; then
    ok "$4"
  else
    bad "${4}（$2 の節内に不足: $3）"
  fi
}

echo "== 長時間タスク委譲のこまめコミット契約 =="
echo
echo "-- 前提: 正本の節スコープ --"

# 見出しの重複は節の同一性とアンカーの着地先を壊す。
HEADING_COUNT=""
_hc_rc=0
HEADING_COUNT="$(grep -cxF -- "$CONTRACT_HEADING" "$ORCHESTRATION")" || _hc_rc=$?
case "$_hc_rc" in
  0|1)
    if [[ "${HEADING_COUNT:-0}" -eq 1 ]]; then
      ok "契約節の見出しが完全一致でちょうど 1 件（アンカーの導出元が一意）"
    else
      bad "契約節の見出しが ${HEADING_COUNT:-0} 件（期待 1 件）— multi-implement/SKILL.md のアンカーが壊れるか、節抽出が別節を巻き込みます: ${CONTRACT_HEADING}"
    fi
    ;;
  *)
    bad "multi-cli-agent-orchestration.md の見出しを数えられません — grep rc=${_hc_rc}（見出しの件数とは別の失敗）"
    ;;
esac

if SECTION="$(extract_section "$CONTRACT_HEADING" "$ORCHESTRATION")" && [[ -n "$SECTION" ]]; then
  ok "契約節を一意に抽出でき、終端見出しに到達している"
else
  bad "契約節を抽出できません（見出しの重複・改変、または終端見出しへ未到達。節スコープが失われます）"
  echo "✗ long-task-commit-contract verify: 節スコープが成立しないため中断" >&2
  exit 1
fi

echo
echo "-- 正本: 契約 3 項目 --"

# 項目 1: こまめコミットの明記。巨大 commit 指向の否定まで含めて固定する
# （「明記する」だけ残して否定が消えると、1 commit へ束ねる読み方が復活する）。
section_has "$SECTION" "契約節" \
  "**委譲プロンプトに「論理的なまとまりごとに commit + push」を明記する**" \
  "項目1: 委譲プロンプトへのこまめコミット明記が契約として残っている"
section_has "$SECTION" "契約節" \
  "1 つの巨大 commit を目指させない" \
  "項目1: 巨大 commit を目指させない旨が残っている"

# 項目 2: フェーズ分割と切り口（依存順）。切り口が消えると分割単位が恣意化する。
section_has "$SECTION" "契約節" \
  "**タスクが大きい場合はフェーズ分割する**" \
  "項目2: フェーズ分割が契約として残っている"
section_has "$SECTION" "契約節" \
  "切り口は「後段が前段の決定に" \
  "項目2: 分割の切り口（後段が前段の決定に依存する順）が残っている"

# 項目 3: ストール再開時のコミット確認。ゼロ時の後始末（未コミット退避 → 空ブランチ
# 削除）まで含める（確認だけ残して後始末が消えると空ブランチへの継ぎ足しが正当化され、
# 退避が消えるとコミットゼロ = 成果ゼロと誤読して未コミット成果ごと捨てる事故に戻る）。
section_has "$SECTION" "契約節" \
  "**ストール再開時は、まずブランチにコミットが積まれているかを確認する**" \
  "項目3: ストール再開時のコミット確認が契約として残っている"
section_has "$SECTION" "契約節" \
  "コミットゼロでも空ブランチとは限らない" \
  "項目3: コミットゼロ = 成果ゼロではない旨が残っている"
section_has "$SECTION" "契約節" \
  "作業ツリーの未コミット変更・未追跡ファイルを確認し、残っていれば退避" \
  "項目3: 削除前の未コミット成果の退避が残っている"
section_has "$SECTION" "契約節" \
  "空ブランチを削除してクリーンに再開する" \
  "項目3: 何も残っていない場合の空ブランチ削除が残っている"

# 正本宣言。消えると複製が始まり、片方だけ直る形の drift が起きる。
section_has "$SECTION" "契約節" \
  "本節が正本で、他文書はここを参照する" \
  "正本宣言（他文書は参照のみ）が残っている"

echo
echo "-- 消費側: multi-implement/SKILL.md（再掲せず正本を指す） --"

# アンカー文字列だけが残ってリンク記法が壊れる形を通さないよう、Markdown リンクを
# 丸ごと針にする。
doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  "](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#長時間タスクの委譲契約こまめコミット)" \
  "multi-implement が正本の契約節へ Markdown リンクを持つ"
doc_has "$MULTI_IMPLEMENT" "multi-implement/SKILL.md" \
  "規定はここへ複製しない" \
  "multi-implement が規定を複製しないと宣言している"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ long-task-commit-contract verify: $FAIL 件失敗 / $PASS 件成功（実行 $((PASS + FAIL)) 件）" >&2
  exit 1
fi

echo "✓ long-task-commit-contract verify: 全 $PASS 件 pass"
