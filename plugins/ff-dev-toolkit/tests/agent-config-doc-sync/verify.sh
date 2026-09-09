#!/usr/bin/env bash
#
# agent-config-doc-sync — `.claude/agent-config.yaml` の「実際に読まれるキー」の
# 説明が単一正本であり、その内容が実装と連動していることの検査（Issue #244 / #1023）。
#
# 経緯: 元はこの説明文が 4 スキル（multi-review / multi-explore / multi-implement /
# setup-ai-config）の SKILL.md へ**複製**されており、本 suite は複製同士の byte 一致を
# 見張っていた（複製は「片方だけ訂正される」形で必ずドリフトする。実際に multi-review
# だけが訂正され、残るスキルには「`agents:` を書き換えると挙動が変わる」と誤読させる
# 旧文が残った）。Issue #1023 で複製そのものを畳み、正本を
# docs-template/05-operations/deployment/multi-cli-agent-orchestration.md の
# 「実際に読まれるキー」節へ移して 4 スキルは参照だけを持つ形にした。
# 複製が無くなったので、複製間の一致検査（byte 比較・各ファイルからの bullet 抽出）と
# 「ピンに載っていない複製が増えたら赤」の名簿管理は消えている。
#
# 残す主張は 3 つ:
#   1) 正本節が存在し、「実際に読まれるキー」を正しく述べていること（anchor 検査）。
#      正本が 1 箇所になっても「正本が黙って旧文へ戻る」経路は残るため
#   2) その主張と multi-agent.sh の実装が連動していること（doc↔code）。実装だけが
#      変わって説明が嘘になる退行を捕まえる。doc↔doc の一致検査では原理的に
#      「全員で同じ嘘をつく」状態を検出できないので、こちらが本命
#   3) 消費側 4 スキルが正本への参照を 1 行持ち、説明を複製し直していないこと。
#      参照が消えれば規定は読者へ届かず、複製が復活すればドリフトが戻る
#      （先例: long-task-commit-contract の「正本節 ↔ 消費側参照」）
#
# anchor 検査自体の検出力は 2 種の陰性サンプルで毎回確かめてから本検査へ進む
# （検出器の空振り対策）:
#   - 訂正前の旧文: 全 anchor が**個別に**欠けること（anchor 1 本だけの弱体化も検出）
#   - 列挙漏れのあった旧訂正文: 検査全体が赤くなること
# 正常系（実ファイルが緑になること）も本検査そのものとして常に走る。
#
# 正本節の抽出は fail-closed: 見出しは完全一致で開き、2 度現れたら中断、次の見出しへ
# 到達しないまま EOF へ抜けたら中断する（review-freeze-contract / ACE-810-1 と同じ理由 —
# 節が隣の段まで広がったまま緑になるのを防ぐ）。
#
# 実 CLI・ネットワークを使わない読み取り専用の静的検査。行の抽出・照合は
# 外部コマンドに依らず bash の文字列比較だけで行う。
# Keep this read-only friendly: no temporary files / here-docs / here-strings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
SSOT_DOC="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-agent-orchestration.md"

SKILLS=(multi-review multi-explore multi-implement setup-ai-config)
MARKER='- 設定のカスタマイズ:'
# 消費側が持つべき正本へのリンク（アンカーは SSOT_HEADING から導かれる）
SSOT_HEADING='### 実際に読まれるキー'
SSOT_LINK='../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#実際に読まれるキー'

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== agent-config.yaml 説明文の単一正本 =="

# ---- anchor 検査: 説明が述べるべき内容（実際に読まれるキーと読まれないキー）----
ANCHORS=(
  '実際に読まれるのは `version` / `mode` / `parallel` / `review.main` / `review.sub` / `review.critical_nonblock_perspectives`'
  '`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}`'
  '`exclude_clis` は空白またはカンマ区切りの **1 文字列**で、そこに挙げた CLI をプランから外す'
  '`agents:` と `fallback:` はどのバージョンでも読まれず'
  '`scripts/multi-agent.sh` の `get_cli_*` 関数'
  '読み取りは `yq` 依存'
)
# 複製検出の needle。正本本文にしか現れない一文を使う（消費側の参照行は
# 「どのキーが実際に読まれるか」という別表現なので当たらない）
DUP_NEEDLE="${ANCHORS[0]}"

# 引数のテキストが全 anchor を含めば 0。欠けていれば MISSING_ANCHORS に列挙して 1
check_anchors() {
  local text="$1" a
  MISSING_ANCHORS=()
  for a in "${ANCHORS[@]}"; do
    [[ "$text" == *"$a"* ]] || MISSING_ANCHORS+=("$a")
  done
  [ "${#MISSING_ANCHORS[@]}" -eq 0 ]
}

# ---- 検出器の空振り検査（本検査より先に走らせ、失敗したら即終了する）----
# 陰性サンプル1: 訂正前の旧文。全 anchor が個別に欠けることを要求する
# （集合として ≥1 本欠けるだけの検証だと、anchor 1 本を旧文にも載っている
#  文字列へ差し替える弱体化が自己検証を素通りする）
OLD_SAMPLE='- 設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される（環境変数 `MULTI_AGENT_CONFIG=<path>` または `--config <path>` でも上書き可）'
SELFTEST_FAIL=0
for a in "${ANCHORS[@]}"; do
  if [[ "$OLD_SAMPLE" == *"$a"* ]]; then
    bad "anchor が訂正前の旧文にも含まれていて検出力がない: $a"
    SELFTEST_FAIL=1
  fi
done
if [ "$SELFTEST_FAIL" -eq 0 ]; then
  ok "全 ${#ANCHORS[@]} anchor が訂正前の旧文で個別に赤くなる（検出力あり）"
fi

# 陰性サンプル2: 列挙漏れのあった旧訂正文（v0.23 時点の「正本」。review.main/sub と
# tasks.<task>.mode が列挙から欠けていた）。検査全体としては赤くなることを要求する
OLD_SAMPLE_V2='- 設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される（環境変数 `MULTI_AGENT_CONFIG=<path>` または `--config <path>` でも上書き可）。ただし**実際に読まれるのは `version` / `mode` / `parallel` と、`version: "2.0"` のときだけ `tasks.<task>.{cost_strategy,timeout,output_dir}` である**（`version` が `2.0` でない場合は v1 形式とみなされ、トップレベルの `cost_strategy` / `timeout` / `output_dir` が読まれる — `version` を書き忘れると `tasks.*` が黙って無視されるので注意）。`agents:` と `fallback:` はどのバージョンでも読まれず、人が読むための対応表にすぎない。実行時のレジストリの正本は `scripts/multi-agent.sh` の `get_cli_*` 関数'
if check_anchors "$OLD_SAMPLE_V2"; then
  bad "anchor 検査が列挙漏れのあった旧訂正文を通してしまう（検出力の退行）"
  SELFTEST_FAIL=1
else
  ok "anchor 検査は列挙漏れのあった旧訂正文で赤くなる"
fi

if [ "$SELFTEST_FAIL" -ne 0 ]; then
  echo "  検査済み ${PASS} 件 / 失敗 ${FAIL} 件"
  echo "✗ 検出器の自己検証に失敗したため、本検査の結果は信頼できません" >&2
  exit 1
fi

# ---- 1) 正本節の抽出（fail-closed）----
if [ ! -r "$SSOT_DOC" ]; then
  bad "正本文書を読み取れない: $SSOT_DOC"
  echo "✗ 正本を読めないため以降の検査へ進めません" >&2
  exit 1
fi

SSOT_TEXT=""
SSOT_OPENED=0
SSOT_CLOSED=0
SSOT_REOPENED=0
IN_SECTION=0
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = "$SSOT_HEADING" ]; then
    if [ "$SSOT_OPENED" -eq 1 ]; then
      SSOT_REOPENED=1
    fi
    SSOT_OPENED=1
    IN_SECTION=1
    continue
  fi
  if [ "$IN_SECTION" -eq 1 ]; then
    case "$line" in
      '## '*|'### '*) IN_SECTION=0; SSOT_CLOSED=1; continue ;;
    esac
    SSOT_TEXT="${SSOT_TEXT}${line}"$'\n'
  fi
done < "$SSOT_DOC"

if [ "$SSOT_OPENED" -ne 1 ]; then
  bad "正本節が見つからない（見出しは完全一致で探します）: ${SSOT_HEADING} — ${SSOT_DOC}"
elif [ "$SSOT_REOPENED" -eq 1 ]; then
  bad "正本の見出しが 2 度以上現れる（節の切り出しが多義になる）: ${SSOT_HEADING}"
elif [ "$SSOT_CLOSED" -ne 1 ]; then
  bad "正本節が次の見出しへ到達せず EOF まで広がっている（節スコープが壊れています）: ${SSOT_HEADING}"
else
  ok "正本節「${SSOT_HEADING}」を ${SSOT_DOC##*/} から切り出せる"
fi

if [ "$SSOT_OPENED" -ne 1 ] || [ "$SSOT_REOPENED" -eq 1 ] || [ "$SSOT_CLOSED" -ne 1 ]; then
  echo "  検査済み ${PASS} 件 / 失敗 ${FAIL} 件"
  echo "✗ 正本節を切り出せないため内容検査へ進めません" >&2
  exit 1
fi

# ---- 2) 正本が実際の挙動を正しく述べている（anchor 検査）----
if check_anchors "$SSOT_TEXT"; then
  ok "正本節が実際に読まれるキー（version / mode / parallel / review.main / review.sub / review.critical_nonblock_perspectives / exclude_clis / tasks.*）と読まれないキー（agents / fallback）を正しく述べている"
else
  bad "正本節に述べるべき内容が欠けている（説明は 1 物理行である前提 — 折り返した場合も欠落扱いになる）:"
  for a in "${MISSING_ANCHORS[@]}"; do
    echo "    | 欠落 anchor: $a" >&2
  done
fi

# ---- 3) 説明の主張と multi-agent.sh の実装の連動検査 ----
# 説明が「読まれる」と主張するキーの yq 読み取り式が実在し、「読まれない」と
# 主張する agents / fallback への yq 参照が存在しないことを突き合わせる。
# 実装側だけが変わって説明が嘘になる退行（どちらの向きでも）をここで赤にする。
if [ ! -r "$MULTI_AGENT" ]; then
  bad "multi-agent.sh を読み取れない: $MULTI_AGENT"
else
  YQ_LINES=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *yq*) YQ_LINES="${YQ_LINES}${line}"$'\n' ;;
    esac
  done < "$MULTI_AGENT"

  # 読まれると主張するキーの読み取り式（トップレベルは「'.key」の形で v2 の
  # tasks.* と区別する。${TASK_TYPE} は single quote 内なので展開されない）
  REQUIRED_READS=(
    "'.version"
    "'.mode"
    "'.parallel"
    "'.review.main"
    "'.review.sub"
    "'.review.critical_nonblock_perspectives"
    "'.exclude_clis"
    '.tasks.${TASK_TYPE}.mode'
    '.tasks.${TASK_TYPE}.cost_strategy'
    '.tasks.${TASK_TYPE}.timeout'
    '.tasks.${TASK_TYPE}.output_dir'
    "'.cost_strategy"
    "'.timeout"
    "'.output_dir"
  )
  LINK_FAIL=0
  for pat in "${REQUIRED_READS[@]}"; do
    if [[ "$YQ_LINES" != *"$pat"* ]]; then
      bad "説明が「読まれる」と主張するキーの yq 読み取り式が multi-agent.sh に見当たらない: ${pat}（実装が変わったなら正本節と本検査を同時に更新すること）"
      LINK_FAIL=1
    fi
  done
  if [ "$LINK_FAIL" -eq 0 ]; then
    ok "説明が「読まれる」と主張する全キー（${#REQUIRED_READS[@]} 式）の yq 読み取りが multi-agent.sh に実在する"
  fi

  FORBIDDEN_FAIL=0
  for pat in '.agents' '.fallback'; do
    if [[ "$YQ_LINES" == *"$pat"* ]]; then
      bad "multi-agent.sh の yq 行に $pat への参照がある — 説明の「agents: と fallback: は読まれない」が嘘になる。実装を変えたなら正本節と本検査を同時に更新すること"
      FORBIDDEN_FAIL=1
    fi
  done
  if [ "$FORBIDDEN_FAIL" -eq 0 ]; then
    ok "multi-agent.sh の yq 行に .agents / .fallback への参照が無い（「読まれない」の主張と一致）"
  fi
fi

# ---- 4) 消費側 4 スキルが正本を参照している（複製ではなく参照）----
REF_FAIL=0
for skill in "${SKILLS[@]}"; do
  file="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  if [ ! -r "$file" ]; then
    bad "$skill/SKILL.md を読み取れない: $file"
    REF_FAIL=1
    continue
  fi
  count=0
  linked=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$MARKER"*)
        count=$((count + 1))
        # Markdown リンクの閉じ括弧まで含めて照合する（部分一致だと
        # `#実際に読まれるキー-broken` のような存在しないアンカーへ差し替えられても
        # 「$SSOT_LINK を含む」で緑になってしまう）。
        case "$line" in
          *"]($SSOT_LINK)"*) linked=1 ;;
        esac
        ;;
    esac
  done < "$file"
  if [ "$count" -ne 1 ]; then
    bad "$skill/SKILL.md の「設定のカスタマイズ」行が ${count} 行（1 行のみを想定 — 参照ごと消えた、行頭の文言が変わった、または 1 物理行でなくなった）"
    REF_FAIL=1
  elif [ "$linked" -ne 1 ]; then
    bad "$skill/SKILL.md の「設定のカスタマイズ」行が正本を参照していない（期待するリンク: ${SSOT_LINK}）"
    REF_FAIL=1
  fi
done
if [ "$REF_FAIL" -eq 0 ]; then
  ok "消費側 ${#SKILLS[@]} スキルが正本への参照行をちょうど 1 行ずつ持つ"
fi

# ---- 5) 説明の複製が復活していない ----
# 正本本文にしか現れない一文を skills/*/SKILL.md 全体から探す。1 件でも見つかれば
# 説明が再び複製された（= ドリフトの土台が戻った）ということなので赤にする。
# 照合前に改行・タブ・連続空白を単一空白へ正規化する（needle 側・ファイル側の両方）。
# 行単位の生テキスト一致だと、正本の一文を改行で折り返して再複製されても
# 1 行としては一致せず「複製が無い」と緑になってしまう。
normalize_ws() {
  printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' '
}
DUP_NEEDLE_NORM="$(normalize_ws "$DUP_NEEDLE")"
DUP_FILES=""
for f in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  FILE_NORM="$(normalize_ws "$(cat "$f")")"
  case "$FILE_NORM" in
    *"$DUP_NEEDLE_NORM"*) DUP_FILES="${DUP_FILES}    | $f"$'\n' ;;
  esac
done
if [ -n "$DUP_FILES" ]; then
  bad "正本の説明文が SKILL.md へ複製されている — 参照だけを残して本文は正本へ寄せること:"
  printf '%s' "$DUP_FILES" >&2
else
  ok "skills/*/SKILL.md に正本説明文の複製が無い"
fi

echo
echo "検査済み ${PASS} 件 / 失敗 ${FAIL} 件"
if [ "$FAIL" -gt 0 ]; then
  echo "✗ agent-config-doc-sync: 失敗があります" >&2
  echo "  説明の正本は ${SSOT_DOC} の「${SSOT_HEADING}」節。スキル側は参照だけを持ちます" >&2
  exit 1
fi
echo "✓ agent-config-doc-sync: すべて通過"
