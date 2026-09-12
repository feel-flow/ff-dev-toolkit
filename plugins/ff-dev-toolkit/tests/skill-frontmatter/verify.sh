#!/usr/bin/env bash
#
# Skill frontmatter と単一正本のポリシー検査（Issue #141 / #145 / #996 / ACE-147-1）。
#
# `disable-model-invocation: true` はモデルからの呼び出しを塞ぐ。
# しかし実体を同梱スクリプトへ抽出した skill（SKILL.md が
# `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/x.sh" $ARGUMENTS` の 1 行）では、モデルは
# 同じスクリプトを Bash から直接叩けるため、破壊的操作は防げない。塞げるのは
# ラッパーの発見性だけである。一方 docs-template の
# `05-operations/deployment/workflow-principles.md` はフルオート運用のチェーンに
# `/merge-cleanup` を置いており、フラグは必須ステップの可用性だけを削る。
#
# 本 suite は **リポジトリ全プラグイン**の全 skill が Agent Skills 標準の
# frontmatter 構造（name = ディレクトリ名、description の存在と安全性、標準外キー
# の不在、disable-model-invocation の既定 false）を持つことを fail-closed で検証する
# （Issue #996。旧版は `plugins/ff-dev-toolkit/skills/` のみを走査しており、他 8
# プラグイン・108 スキルが無検査だった）。
#
# description に未クォートの「: 」（コロン+半角スペース）を含めると frontmatter が
# 実行時に全欠落する事故クラスも同じ理由で全プラグイン対象にする（ACE-57-1。
# story-spine-abt の実例で `claude plugin validate` が検出したが、本 suite にはこの
# 検査自体が無く、grep 系の機械照合をすり抜けていた）。
#
# 一方、次の 5 検査は ff-dev-toolkit 固有のアーキテクチャ判断（他ホスト（Codex CLI 等）
# からもスクリプト実体を直接叩ける形にする移植性方針、Issue #141 の
# commands/*.md → skills/*/SKILL.md 単一正本移行、観測台帳 OBS-042 発の
# pre-commit-check 新節 pin）に紐づくポリシーであり、他プラグイン（純粋なコンテンツ・
# スキルパック）には適用しない。適用すると frontmatter とは無関係な本文の書き換えを
# 強制することになる（scope 外）:
#   - Issue #141 移行対象 14 skill の欠落検査（MIGRATED_SKILLS）
#   - legacy `commands/*.md` の再追加検査
#   - バージョン固定 cache パスの検査
#   - AskUserQuestion 等ホスト固有ツール名の必須手順使用検査
#   - 観測台帳 OBS-042 / OBS-133 発: pre-commit-check の commit 前チェック節（手順 6 の
#     staged 内容と作業ツリーの一致確認 / 手順 7 の shell 単体チェック / 手順 8 の静的
#     suite プリフライト / 手順 9 の出力テンプレート）の固定文言 pin と、手順 8 の固定表が
#     名指しする suite 名の実在照合
# これら 5 検査は ${PLUGIN_ROOT}（ff-dev-toolkit）のスキルにのみ適用する。
#
# 一時ディレクトリも jq 以外の外部コマンドも要らない純粋なファイル検査なので、
# 書き込み不可の環境でも完走する（marketplace.json の名簿照合にのみ jq を使う）。
# `run-all.sh` では最も安価な本 suite を先頭に置く（Issue #146 でランナーは
# 全 suite を実行する集約方式になったので、並び順は報告の読みやすさの問題）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"
MARKET="$REPO_ROOT/.claude-plugin/marketplace.json"
FF_SKILLS_DIR="$PLUGIN_ROOT/skills"

[ -d "$PLUGINS_DIR" ] || { echo "✗ plugins ディレクトリが見つかりません: $PLUGINS_DIR" >&2; exit 1; }
[ -d "$FF_SKILLS_DIR" ] || { echo "✗ ff-dev-toolkit の skills ディレクトリが見つかりません: $FF_SKILLS_DIR" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq is required" >&2; exit 1; }
[ -f "$MARKET" ] || { echo "✗ marketplace.json が見つかりません: $MARKET" >&2; exit 1; }

# Issue #141 で移行した14手順。将来 skill が増えてもよいが、この14件の欠落は
# Codex 対応範囲の後退なので fail-closed で拒否する（ff-dev-toolkit 固有）。
MIGRATED_SKILLS=(
  ace-curate ace-setup assess-impact close-issue create-issue init-docs
  merge-cleanup multi-explore multi-implement multi-review pre-commit-check
  refine-issue setup-ai-config validate-docs
)
for migrated in "${MIGRATED_SKILLS[@]}"; do
  [ -s "$FF_SKILLS_DIR/$migrated/SKILL.md" ] || {
    echo "✗ Issue #141 の移行対象 skill が見つからないか空です: $migrated" >&2
    exit 1
  }
done

# Issue #141 で commands/*.md は同名 skills/*/SKILL.md へ正本移行した。
# legacy command を再追加すると Codex から見えない第2正本が復活するため拒否する
# （ff-dev-toolkit 固有）。
if [ -d "$PLUGIN_ROOT/commands" ] && find "$PLUGIN_ROOT/commands" -type f -name '*.md' -print -quit | grep . >/dev/null; then
  echo "✗ legacy commands/*.md が残っています。skills/<name>/SKILL.md を単一正本にしてください" >&2
  exit 1
fi

# `disable-model-invocation` を意図的に許容する skill 名（"<plugin>/<skill>" 形式）。
# 追加するときは必ず理由をコメントで残す（例: 人間が発火タイミングを決めるべき
# 対話専用コマンドで、ワークフロー正本が自動実行を要求していない）。
ALLOWLIST=()

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

is_allowlisted() {
  local name="$1" entry
  for entry in ${ALLOWLIST[@]+"${ALLOWLIST[@]}"}; do
    [ "$entry" = "$name" ] && return 0
  done
  return 1
}

# 観測台帳 OBS-042 / OBS-133 発: pre-commit-check の手順 6「staged 内容と作業ツリーの
# 一致確認」・手順 7「staged shell ファイルの単体チェック」・手順 8「staged ファイル種別
# ごとの静的 suite プリフライト」・手順 9 の出力テンプレートの各節が消えないことを pin
# する（節を変更したのに固定文言検査が無い状態を作らない規定。ff-dev-toolkit 固有）。
# 手順 6 は手順 7・8 の前提ゲートである。手順 7・8 は staged パスから検査対象を選ぶのに
# 実体は作業ツリーを読むので、両者が食い違うと staged 側の違反を「違反なし」と報告した
# まま commit を通す。一致確認の手順そのもの（index と作業ツリーの差分を取るコマンド）と、
# 不一致を「違反なし」ではなく判定不能へ倒す文言の双方を pin する（片方だけ残ると、
# 手順が消えても「判定不能」の語だけが散文に残って緑で通る）。
# 手順 8 の固定表は「種別 → 単体で回す静的 suite」を名指しする。名指しした suite 名が
# 実在の tests/<name>/verify.sh と一致することは下の照合が機械的に確かめる（表だけ直して
# suite を消す・改名する drift は、プリフライトの実行手順を静かに空振りさせるため）。
# shellcheck source=../lib/section-scope.sh
. "$SCRIPT_DIR/../lib/section-scope.sh"

PRE_COMMIT_SKILL="$PLUGIN_ROOT/skills/pre-commit-check/SKILL.md"
[ -s "$PRE_COMMIT_SKILL" ] || { echo "✗ pre-commit-check/SKILL.md が見つかりません: $PRE_COMMIT_SKILL" >&2; exit 1; }

check_pre_commit_shell_step() {
  local heading="$1" needle="$2" label="$3" reason
  if reason="$(section_scope_contains "$PRE_COMMIT_SKILL" "$heading" "$needle")"; then
    ok "pre-commit-check — $label"
  else
    bad "pre-commit-check — ${label}（${reason}）"
  fi
}

PRE_COMMIT_CONSISTENCY_HEADING='### 6. staged 内容と作業ツリーの一致確認'
PRE_COMMIT_SHELL_HEADING='### 7. staged shell ファイルの単体チェック'
PRE_COMMIT_OUTPUT_HEADING='### 9. 結果の出力'

# 手順 6（手順 7・8 の前提ゲート）。針はコード行・判定規則そのものを指す — 同じ語が
# 散文にも現れる針だと、実体を消しても散文が残って緑で通る。
check_pre_commit_shell_step "$PRE_COMMIT_CONSISTENCY_HEADING" 'git diff --name-only --' \
  'index と作業ツリーの差分を取る一致確認コマンド'
check_pre_commit_shell_step "$PRE_COMMIT_CONSISTENCY_HEADING" '不一致のため判定不能' \
  '不一致を「判定不能」として報告する規定'
check_pre_commit_shell_step "$PRE_COMMIT_CONSISTENCY_HEADING" '「違反なし」とは書かない' \
  '判定不能を「違反なし」と書かない（緑扱いにしない）規定'
check_pre_commit_shell_step "$PRE_COMMIT_CONSISTENCY_HEADING" 'git add <名指ししたファイル>' \
  '不一致時に利用者が取る次の一手（stage し直して回し直す）の案内'

check_pre_commit_shell_step "$PRE_COMMIT_SHELL_HEADING" 'mbcs_scan' 'mbcs_scan の呼び出し記述'
check_pre_commit_shell_step "$PRE_COMMIT_SHELL_HEADING" 'exit_code_scan' 'exit_code_scan の呼び出し記述'
check_pre_commit_shell_step "$PRE_COMMIT_SHELL_HEADING" '1 ファイルずつ' 'mbcs_scan/exit_code_scan を 1 ファイルずつ呼ぶ規定（バッチ呼び出しはファイル境界をまたいで行番号・内容が破損する）'
check_pre_commit_shell_step "$PRE_COMMIT_SHELL_HEADING" '検査不能' '検査不能→commit へ進まない fail-closed の記述'
check_pre_commit_shell_step "$PRE_COMMIT_SHELL_HEADING" '手順 6 の一致確認' \
  '手順 6 が不一致だったファイルを判定不能として扱う委譲'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" 'shell 単体チェック' '出力テンプレートの shell 単体チェック節'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" '✅ 違反なし' '出力テンプレート4状態: 違反なし'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" '❌ 違反あり' '出力テンプレート4状態: 違反あり'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" '○ 対象なし' '出力テンプレート4状態: 対象なし'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" '❌ 検査不能' '出力テンプレート4状態: 検査不能'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" '### staged 内容と作業ツリーの一致確認' \
  '出力テンプレートの一致確認節'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" '❌ 不一致のため判定不能' \
  '出力テンプレート: 不一致のため判定不能の状態'

PRE_COMMIT_PREFLIGHT_HEADING='### 8. staged ファイル種別ごとの静的 suite プリフライト'
PRE_COMMIT_TABLE_HEADING='#### 種別 → 単体で回す静的 suite（固定表）'
PRE_COMMIT_STEPS_HEADING='#### プリフライトの実行手順'

# 手順 8 の散文が持つべき規定。プリフライトは全件ゲートの絞り込みではないこと（全件ゲートの
# 既定を変更連動選択にする設計を退けた過去の判断との整合）、監視 glob を持たない固定表で
# あること、「対象なし」と「実行できなかった」を「違反なし」へ倒さないことを pin する。
check_pre_commit_shell_step "$PRE_COMMIT_PREFLIGHT_HEADING" '全件ゲートを置き換えない' \
  'プリフライトが全件ゲートを置き換えない規定'
check_pre_commit_shell_step "$PRE_COMMIT_PREFLIGHT_HEADING" '監視 glob ではなく固定表' \
  '監視 glob を持たず固定表で名指しする規定'
check_pre_commit_shell_step "$PRE_COMMIT_PREFLIGHT_HEADING" '対象なし' \
  '該当種別が無いときは「対象なし」として 1 行で報告する規定'
check_pre_commit_shell_step "$PRE_COMMIT_PREFLIGHT_HEADING" '手順 6 の一致確認' \
  '手順 6 が不一致なら本手順を緑扱いにしない委譲'
check_pre_commit_shell_step "$PRE_COMMIT_STEPS_HEADING" '実行できなかった' \
  '「実行できなかった」と「違反なし」を区別する fail-closed の記述'
check_pre_commit_shell_step "$PRE_COMMIT_STEPS_HEADING" '違反なしへ倒さない' \
  'suite 不在・依存不足・skip を違反なしへ倒さない規定'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" '静的 suite プリフライト' \
  '出力テンプレートの静的 suite プリフライト節'
check_pre_commit_shell_step "$PRE_COMMIT_OUTPUT_HEADING" '❌ 実行できなかった' \
  '出力テンプレート: プリフライトの「実行できなかった」状態'

# 固定表（| 種別 | staged パスの条件 | 単体で回す suite |）の 3 列目が名指しする suite 名を
# 実体（tests/<name>/verify.sh）と機械照合する。表が空・行が減った・suite 名を 1 つも
# 持たない行があるときは「照合対象ゼロで緑」にならないよう fail-closed で赤にする。
# 外部コマンドは awk だけを使う（本 suite は一時領域も jq 以外の外部コマンドも要らない
# 純粋なファイル検査である。here-doc / here-string は一時ファイルを要求するので使わない）。
PRE_COMMIT_TABLE_MIN_ROWS=3

# want=rows: データ行数 / want=empty: suite 名を 1 つも持たない行番号 / want=names:
# 重複除去した suite 名（空白区切り）。いずれも 1 行だけを返す。
pre_commit_table_field() {
  printf '%s\n' "$2" | awk -F'|' -v want="$1" '
    /^[[:space:]]*\|/ {
      if ($0 ~ /^[[:space:]]*\|[[:space:]]*[-:][-:[:space:]|]*$/) next
      if ($2 ~ /種別/) next
      rows++
      n = split($4, parts, "`")
      hits = 0
      for (i = 2; i <= n; i += 2) {
        if (parts[i] == "") continue
        hits++
        if (!(parts[i] in seen)) { seen[parts[i]] = 1; names = names (names == "" ? "" : " ") parts[i] }
      }
      if (hits == 0) empty = empty (empty == "" ? "" : " ") rows
    }
    END {
      if (want == "rows") print rows + 0
      else if (want == "empty") print empty
      else print names
    }
  '
}

if ! pre_commit_table="$(section_scope_extract "$PRE_COMMIT_SKILL" "$PRE_COMMIT_TABLE_HEADING")"; then
  bad "pre-commit-check — 種別→suite 固定表を切り出せません（${pre_commit_table}）"
else
  pre_commit_rows="$(pre_commit_table_field rows "$pre_commit_table")"
  pre_commit_empty="$(pre_commit_table_field empty "$pre_commit_table")"
  pre_commit_suites="$(pre_commit_table_field names "$pre_commit_table")"

  case "$pre_commit_rows" in
    ''|*[!0-9]*)
      bad "pre-commit-check — 種別→suite 固定表の行数を数えられません（表の形が変わっています）"
      ;;
    *)
      if [ "$pre_commit_rows" -lt "$PRE_COMMIT_TABLE_MIN_ROWS" ]; then
        bad "pre-commit-check — 種別→suite 固定表の行が ${pre_commit_rows} 件です（${PRE_COMMIT_TABLE_MIN_ROWS} 系統以上であること）"
      else
        ok "pre-commit-check — 種別→suite 固定表が ${pre_commit_rows} 系統ある"
      fi
      ;;
  esac

  if [ -n "$pre_commit_empty" ]; then
    bad "pre-commit-check — 種別→suite 固定表に suite 名を 1 つも名指ししない行があります（行: ${pre_commit_empty}）"
  fi

  if [ -z "$pre_commit_suites" ]; then
    bad "pre-commit-check — 種別→suite 固定表から suite 名を 1 件も抽出できません（照合が空振りします）"
  else
    # suite 名に空白は入らない前提で単語分割して回す（分割は意図的）。
    # shellcheck disable=SC2086
    for pre_commit_suite in $pre_commit_suites; do
      case "$pre_commit_suite" in
        *[!A-Za-z0-9._-]*)
          bad "pre-commit-check — 固定表の suite 名に使えない文字があります: ${pre_commit_suite}"
          continue
          ;;
      esac
      if [ -f "$PLUGIN_ROOT/tests/$pre_commit_suite/verify.sh" ]; then
        ok "pre-commit-check — 固定表の suite 名が実在する: tests/${pre_commit_suite}/verify.sh"
      else
        bad "pre-commit-check — 固定表の suite 名に対応する実体がありません: tests/${pre_commit_suite}/verify.sh"
      fi
    done
  fi
fi

# frontmatter（先頭 `---` から 2 つ目の `---` まで）を stdout へ出す。
# CR は落とす（CRLF ファイルで `/^---$/` が一致せず、抽出が静かに空になるのを防ぐ）。
extract_frontmatter() {
  awk '{ sub(/\r$/, "") } /^---$/{ n++; next } n==1{ print } n==2{ exit }' "$1"
}

echo "== Skill frontmatter・単一正本ポリシー検査（全プラグイン） =="

shopt -s nullglob
SKILL_FILES=("$PLUGINS_DIR"/*/skills/*/SKILL.md)
shopt -u nullglob

if [ "${#SKILL_FILES[@]}" -eq 0 ]; then
  echo "✗ plugins/*/skills/*/SKILL.md が 1 件も見つかりません（検査対象ゼロは異常）" >&2
  exit 1
fi

# 走査対象の下限ガード（固定リテラルではなく marketplace.json の名簿と、実際に
# $SKILL_FILES へ寄与したプラグイン名の集合から導出）。
# marketplace.json に載る各プラグインのうち skills/ を持つものは、$SKILL_FILES に
# 1 件以上寄与していることを要求する。再 glob ではなく $SKILL_FILES の中身そのもの
# から集合を作るので、走査パスが誤って特定プラグイン（過去実績: ff-dev-toolkit
# のみ）へ縮んだ場合も確実に検出できる（fail-closed）。
MARKET_PLUGIN_NAMES="$(jq -r '.plugins[].name' "$MARKET")"
if [ -z "$MARKET_PLUGIN_NAMES" ]; then
  echo "✗ marketplace.json の plugins[] が空です: $MARKET" >&2
  exit 1
fi

# skills/ を持たないプラグインの明示除外リスト（"理由" 付きで追加する）。
# 現状は marketplace.json 掲載の全 9 プラグインが skills/ を持つため空。
NO_SKILLS_PLUGINS=()

# $SKILL_FILES から実際に走査されたプラグイン名の集合を作る（bash 3.2 に連想配列が
# 無いため、改行区切り文字列 + case 前方一致で「含まれるか」を照合する）。
SCANNED_PLUGIN_NAMES=""
for file in "${SKILL_FILES[@]}"; do
  scanned_plugin="$(basename "$(dirname "$(dirname "$(dirname "$file")")")")"
  case $'\n'"$SCANNED_PLUGIN_NAMES"$'\n' in
    *$'\n'"$scanned_plugin"$'\n'*) ;;
    *) SCANNED_PLUGIN_NAMES="${SCANNED_PLUGIN_NAMES}${SCANNED_PLUGIN_NAMES:+$'\n'}${scanned_plugin}" ;;
  esac
done

while IFS= read -r plugin_name; do
  [ -n "$plugin_name" ] || continue

  is_excluded=0
  for excluded in ${NO_SKILLS_PLUGINS[@]+"${NO_SKILLS_PLUGINS[@]}"}; do
    if [ "$excluded" = "$plugin_name" ]; then
      is_excluded=1
      break
    fi
  done
  if [ "$is_excluded" -eq 1 ]; then
    echo "  ○ ${plugin_name}: NO_SKILLS_PLUGINS により skills/ 不在を許容"
    continue
  fi

  plugin_skills_dir="$PLUGINS_DIR/$plugin_name/skills"
  if [ ! -d "$plugin_skills_dir" ]; then
    echo "✗ ${plugin_name}: marketplace.json に掲載されていますが skills/ がありません（skills/ を持たないなら理由付きで NO_SKILLS_PLUGINS へ追加してください）" >&2
    exit 1
  fi

  case $'\n'"$SCANNED_PLUGIN_NAMES"$'\n' in
    *$'\n'"$plugin_name"$'\n'*) ;;
    *)
      echo "✗ ${plugin_name}: skills/ はあるのに走査対象（変数 SKILL_FILES）に含まれていません（走査範囲が縮んでいる可能性）" >&2
      exit 1
      ;;
  esac
done <<< "$MARKET_PLUGIN_NAMES"
echo "  ○ marketplace.json の全プラグインが走査対象に 1 件以上寄与（下限ガード）"

for file in "${SKILL_FILES[@]}"; do
  skill_dir_name="$(basename "$(dirname "$file")")"
  plugin_name="$(basename "$(dirname "$(dirname "$(dirname "$file")")")")"
  name="${plugin_name}/${skill_dir_name}"
  case "$file" in
    "$PLUGIN_ROOT"/*) is_ff_dev_toolkit=1 ;;
    *) is_ff_dev_toolkit=0 ;;
  esac

  # 先頭行が正確に `---` であることを要求する。BOM 付き・先頭空行・別形式のときは
  # frontmatter を特定できないので、黙って pass させず loud に落とす
  # （負の主張の検査は「本当に見たのか」を先に確かめないと自己無効化する）。
  if ! first_line="$(head -n 1 "$file")"; then
    bad "$name — 先頭行を読み取れませんでした"
    continue
  fi
  first_line="${first_line%$'\r'}"
  if [ "$first_line" != "---" ]; then
    bad "$name — 先頭行が '---' ではありません（BOM / 先頭空行 / frontmatter 無し）: $(printf '%q' "$first_line")"
    continue
  fi

  # 抽出そのものの失敗を pass に埋もらせない（pipefail 下でも command substitution の
  # 終了ステータスを明示的に見る）。
  if ! frontmatter="$(extract_frontmatter "$file")"; then
    bad "$name — frontmatter の抽出に失敗しました"
    continue
  fi

  # 正の主張: 抽出結果が空でなく、既知キーを含む。これが無いと「0 行を検査して ✓」
  # という空虚な pass を許してしまう。
  if [ -z "$frontmatter" ]; then
    bad "$name — frontmatter が空です（抽出範囲を特定できていない可能性）"
    continue
  fi
  description_line="$(printf '%s\n' "$frontmatter" | grep -E '^[[:space:]]*description:' | head -n 1 || true)"
  if [ -z "$description_line" ]; then
    bad "$name — frontmatter に description: がありません（抽出範囲が誤っている可能性）"
    continue
  fi
  if ! declared_name="$(printf '%s\n' "$frontmatter" | awk -F: '/^[[:space:]]*name:/{ sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')"; then
    bad "$name — frontmatter の name 抽出に失敗しました"
    continue
  fi
  declared_name="$(printf '%s' "$declared_name" | tr -d "\"'[:space:]")"
  if [ "$declared_name" != "$skill_dir_name" ]; then
    bad "$name — frontmatter name がディレクトリ名と一致しません: $(printf '%q' "$declared_name")"
    continue
  fi

  # description の値が未クォートで「: 」（コロン+半角スペース）を含むと、YAML
  # frontmatter の解析が壊れて name/description ごと実行時に全欠落する（ACE-57-1）。
  # ダブル/シングルクォートで囲われた値はエスケープされるため対象外にする。
  description_value="$(printf '%s' "$description_line" | sed -E 's/^[[:space:]]*description:[[:space:]]*//')"
  first_char="${description_value:0:1}"
  if [ "$first_char" != '"' ] && [ "$first_char" != "'" ]; then
    case "$description_value" in
      *": "*)
        bad "$name — description の値が未クォートで「: 」(コロン+半角スペース) を含みます（frontmatter 全欠落の実害。ACE-57-1）"
        continue
        ;;
    esac
  fi

  unsupported_keys="$(printf '%s\n' "$frontmatter" | awk -F: '
    /^[A-Za-z0-9_-]+:/ {
      key=$1
      if (key != "name" && key != "description" && key != "license" &&
          key != "allowed-tools" && key != "metadata") print key
    }
  ')"
  if [ -n "$unsupported_keys" ]; then
    bad "$name — Agent Skills 標準外の frontmatter key があります: $(printf '%s' "$unsupported_keys" | paste -sd, -)"
    continue
  fi

  # 以下 2 検査は ff-dev-toolkit 固有の移植性ポリシー（ヘッダー参照）。他プラグインは
  # 対象外（frontmatter とは無関係な本文の書き換えを強制しないため）。
  if [ "$is_ff_dev_toolkit" -eq 1 ]; then
    if grep -Eq '(/cache/|plugins/cache)[^`[:space:]]*/[0-9]+\.[0-9]+' "$file"; then
      bad "$name — バージョン固定 cache パスが含まれています"
      continue
    fi
    if grep -Eq 'AskUserQuestion|`(Task|Write|Edit)` ツール' "$file"; then
      bad "$name — 特定ホスト固有のツール名を必須手順に使用しています"
      continue
    fi
  fi

  # フラグ行を集める。grep の終了コード 1（不一致）は正常、2 以上は検査自体の失敗。
  set +e
  flag_lines="$(printf '%s\n' "$frontmatter" | grep -E '^[[:space:]]*disable-model-invocation:')"
  grep_status=$?
  set -e
  if [ "$grep_status" -ge 2 ]; then
    bad "$name — frontmatter の検査自体が失敗しました（grep exit ${grep_status}）"
    continue
  fi

  if [ "$grep_status" -eq 1 ]; then
    ok "$name — name/description 正常、disable-model-invocation なし"
    continue
  fi

  # 値を正規化して `false` 以外を拒否する。true / True / TRUE / 'true' / "true" /
  # yes / on / 行末コメント付き / 値を次行に書いた形（値が空になる）をまとめて捕まえる。
  offending=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    value="${line#*:}"
    value="${value%%#*}"
    value="$(printf '%s' "$value" | tr -d '"'"'"'[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [ "$value" != "false" ]; then
      offending="$line"
      break
    fi
  done <<EOF
$flag_lines
EOF

  if [ -z "$offending" ]; then
    ok "$name — disable-model-invocation は明示 false（既定値と同じなので実害なし）"
    continue
  fi

  if is_allowlisted "$name"; then
    ok "$name — disable-model-invocation あり（ALLOWLIST 記載）"
    continue
  fi

  bad "$name — disable-model-invocation が有効になっています: $(printf '%q' "$offending")"
  echo "    このフラグは実体をスクリプトへ抽出した skill では破壊的操作を防げず" >&2
  echo "    （同じスクリプトを Bash から直接叩ける）、ワークフロー正本" >&2
  echo "    （docs-template の 05-operations/deployment/workflow-principles.md）が" >&2
  echo "    チェーンに置く必須ステップの可用性だけを削ります。詳細は ACE-147-1。" >&2
  echo "    真に任意の skill なら本ファイルの ALLOWLIST へ理由付きで追加してください。" >&2
done

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-frontmatter verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ skill-frontmatter verify: 全 $PASS 件 pass"
