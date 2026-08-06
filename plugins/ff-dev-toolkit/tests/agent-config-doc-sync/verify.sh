#!/usr/bin/env bash
#
# agent-config-doc-sync — 4 スキル（multi-review / multi-explore /
# multi-implement / setup-ai-config）の SKILL.md に複製されている
# `.claude/agent-config.yaml` の説明文（「- 設定のカスタマイズ:」bullet）の
# 同期・正確性検査（Issue #244）。
#
# 4 スキルは同じ scripts/multi-agent.sh を叩くため説明も同一であるべきだが、
# 複製された文は「片方だけ訂正される」形で必ずドリフトする。実際に
# multi-review だけが訂正され、残るスキルには「`agents:` を書き換えると
# 挙動が変わる」と誤読させる旧文が残った。さらにその訂正文自体にも
# 「実際に読まれるキー」の列挙漏れがあった（review.main/sub、tasks.<task>.mode）。
# doc↔doc の一致検査は「全員で同じ嘘をつく」状態を検出できないため、
# doc↔code の連動検査を併置する。
#
# 検査は 4 層:
#   1) 4 ファイルの bullet が byte 単位で一致すること（ドリフト検出）
#   2) その文が「実際に読まれるキー」を正しく述べていること（anchor 検査）。
#      一致検査だけだと「全ファイルまとめて旧文へ戻す」変更が緑になるため
#   3) 説明の主張と multi-agent.sh の実装が連動していること（yq 読み取り式に、
#      読まれると主張するキーが実在し、読まれないと主張する agents / fallback
#      が現れないこと）。実装だけが変わって説明が嘘になる退行を捕まえる
#   4) ピン外複製の横断スキャン（skills/*/SKILL.md 全体から同じ説明文の複製を
#      探し、検査対象に居ない複製が増えたら赤にする）。bullet 形式でない複製も
#      「設定のカスタマイズ:」の部分文字列で捕まえる
#
# anchor 検査自体の検出力は 2 種の陰性サンプルで毎回確かめてから本検査へ進む
# （検出器の空振り対策）:
#   - 訂正前の旧文: 全 anchor が**個別に**欠けること（anchor 1 本だけの弱体化も検出）
#   - 列挙漏れのあった旧訂正文: 検査全体が赤くなること
# 正常系（実ファイルが緑になること）も本検査そのものとして常に走る。
#
# 実 CLI・ネットワークを使わない読み取り専用の静的検査。行の抽出・照合は
# 外部コマンドに依らず bash の文字列比較だけで行う。
# Keep this read-only friendly: no temporary files / here-docs / here-strings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

SKILLS=(multi-review multi-explore multi-implement setup-ai-config)
MARKER='- 設定のカスタマイズ:'
# ピン外スキャン用（bullet 前置なし。段落形式の複製もこれで捕まえる）
PHRASE='設定のカスタマイズ:'

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== agent-config.yaml 説明文の ${#SKILLS[@]} スキル同期 =="

# ---- anchor 検査: 説明が述べるべき内容（実際に読まれるキーと読まれないキー）----
ANCHORS=(
  '実際に読まれるのは `version` / `mode` / `parallel` / `review.main` / `review.sub`'
  '`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}`'
  '`agents:` と `fallback:` はどのバージョンでも読まれず'
  '`scripts/multi-agent.sh` の `get_cli_*` 関数'
  '読み取りは `yq` 依存'
)

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

# ---- 各 SKILL.md から bullet を抽出（各ファイルにちょうど 1 行あること）----
BULLETS=()
EXTRACT_FAIL=0
for skill in "${SKILLS[@]}"; do
  file="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  if [ ! -f "$file" ]; then
    bad "$skill/SKILL.md が見つからない: $file"
    EXTRACT_FAIL=1
    continue
  fi
  if [ ! -r "$file" ]; then
    bad "$skill/SKILL.md を読み取れない（権限を確認してください）: $file"
    EXTRACT_FAIL=1
    continue
  fi
  count=0
  found=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$MARKER"*) count=$((count + 1)); found="$line" ;;
    esac
  done < "$file"
  if [ "$count" -eq 1 ]; then
    ok "$skill/SKILL.md に「設定のカスタマイズ」bullet がちょうど 1 行ある"
    BULLETS+=("$found")
  elif [ "$count" -eq 0 ]; then
    bad "$skill/SKILL.md に「設定のカスタマイズ」bullet が無い（説明ごと消えた、行頭の文言が変わった、または 1 物理行でなくなった — 本検査は bullet が 1 物理行である前提）"
    EXTRACT_FAIL=1
  else
    bad "$skill/SKILL.md に「設定のカスタマイズ」bullet が ${count} 行ある（1 行のみを想定。byte 比較が多義になる）"
    EXTRACT_FAIL=1
  fi
done

if [ "$EXTRACT_FAIL" -ne 0 ]; then
  echo "  検査済み ${PASS} 件 / 失敗 ${FAIL} 件"
  echo "✗ 抽出に失敗したため一致・内容検査へ進めません" >&2
  exit 1
fi

# ---- 1) 全ファイルの bullet が byte 単位で一致 ----
REF="${BULLETS[0]}"
DRIFT=0
for ((i = 1; i < ${#BULLETS[@]}; i++)); do
  if [ "${BULLETS[$i]}" != "$REF" ]; then
    bad "${SKILLS[$i]}/SKILL.md の bullet が ${SKILLS[0]} と一致しない（複製がドリフトしている）"
    DRIFT=1
  fi
done
if [ "$DRIFT" -eq 0 ]; then
  ok "${#SKILLS[@]} スキルの bullet が byte 単位で一致する"
fi

# ---- 2) 共通の bullet が実際の挙動を正しく述べている（anchor 検査）----
if check_anchors "$REF"; then
  ok "bullet が実際に読まれるキー（version / mode / parallel / review.main / review.sub / tasks.*）と読まれないキー（agents / fallback）を正しく述べている"
else
  bad "bullet に述べるべき内容が欠けている（bullet は 1 物理行である前提 — 折り返した場合も欠落扱いになる）:"
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
      bad "説明が「読まれる」と主張するキーの yq 読み取り式が multi-agent.sh に見当たらない: $pat（実装が変わったなら 4 スキルの説明と本検査を同時に更新すること）"
      LINK_FAIL=1
    fi
  done
  if [ "$LINK_FAIL" -eq 0 ]; then
    ok "説明が「読まれる」と主張する全キー（${#REQUIRED_READS[@]} 式）の yq 読み取りが multi-agent.sh に実在する"
  fi

  FORBIDDEN_FAIL=0
  for pat in '.agents' '.fallback'; do
    if [[ "$YQ_LINES" == *"$pat"* ]]; then
      bad "multi-agent.sh の yq 行に $pat への参照がある — 説明の「agents: と fallback: は読まれない」が嘘になる。実装を変えたなら 4 スキルの説明と本検査を同時に更新すること"
      FORBIDDEN_FAIL=1
    fi
  done
  if [ "$FORBIDDEN_FAIL" -eq 0 ]; then
    ok "multi-agent.sh の yq 行に .agents / .fallback への参照が無い（「読まれない」の主張と一致）"
  fi
fi

# ---- 4) ピン外複製の横断スキャン ----
# skills/*/SKILL.md 全体から「設定のカスタマイズ:」を含むファイルを探し、
# 検査対象（SKILLS）に居ない複製を赤にする。旧文が段落形式（bullet 前置なし）で
# 複製されて MARKER をすり抜けた実例があるため、部分文字列で探す。
# ピン済みファイルのヒット数がピン数と一致することも要求する — この一致が
# スキャン自体の検出力の証明になる（部分文字列判定が壊れればヒット 0 で赤くなる）
PINNED_HITS=0
UNPINNED_FILES=""
for f in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  has_phrase=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$PHRASE"*) has_phrase=1; break ;;
    esac
  done < "$f"
  [ "$has_phrase" -eq 1 ] || continue
  base="$(basename "$(dirname "$f")")"
  pinned=0
  for skill in "${SKILLS[@]}"; do
    [ "$base" = "$skill" ] && { pinned=1; break; }
  done
  if [ "$pinned" -eq 1 ]; then
    PINNED_HITS=$((PINNED_HITS + 1))
  else
    UNPINNED_FILES="${UNPINNED_FILES}    | $f"$'\n'
  fi
done

if [ -n "$UNPINNED_FILES" ]; then
  bad "検査対象外のスキルに「設定のカスタマイズ」の複製がある — SKILLS へ追加して同一文へ揃えるか、複製をやめて対象スキルへの参照にすること:"
  printf '%s' "$UNPINNED_FILES" >&2
fi
if [ "$PINNED_HITS" -ne "${#SKILLS[@]}" ]; then
  bad "ピン済みファイルのスキャンヒット数が ${PINNED_HITS}（期待 ${#SKILLS[@]}）— 横断スキャン自体が壊れている可能性"
elif [ -z "$UNPINNED_FILES" ]; then
  ok "skills/*/SKILL.md 全体で「設定のカスタマイズ」の複製は検査対象の ${#SKILLS[@]} ファイルだけ"
fi

echo
echo "検査済み ${PASS} 件 / 失敗 ${FAIL} 件"
if [ "$FAIL" -gt 0 ]; then
  echo "✗ agent-config-doc-sync: 失敗があります" >&2
  echo "  訂正の正本は skills/multi-review/SKILL.md の bullet。${#SKILLS[@]} ファイルへ同一文を複製してください" >&2
  exit 1
fi
echo "✓ agent-config-doc-sync: すべて通過"
