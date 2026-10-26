#!/usr/bin/env bash
#
# markdown-patch-discipline-refs: Markdown 文字列パッチ規律の「正本 1 本 + 参照 N 本」の回帰検査。
#
# 守っている事故: **正本は在るのに、守るべき主体が読む経路に無い**（到達性）。
# heredoc → script file の是正（公開 ff-dev-toolkit の `#87`）は正しく入ったが、適用範囲が
# `ace-curate` / `close-issue` の 2 スキルに閉じていた。同じ技法（Markdown 本文への文字列
# パッチ）を使う `create-issue` / `refine-issue` / `retrospective` / `out-of-scope-issue` には
# 1 文字も無く、0 箇所側の作業で同型を踏み直した（公開 ff-dev-toolkit の `#110` / 消費側の
# 観測台帳 OBS-008 は Count 5・promoted）。
#
# さらに 2 スキルの記述は**別文面**だった（`close-issue` は heredoc 回避の理由まで書き、
# `ace-curate` は 1 行）。同じ規律が 2 本ある状態では、片方だけ直っても機械が気づかない
# （ACE-563-1: N 個のプロンプト文書へ複製された共通制約は 1 個の欠落がその観点だけの穴になる）。
#
# したがって本 suite は 2 方向から固定する。片方だけでは担保にならない:
#   - 名簿のスキルが正本を**参照していること**（参照が 1 本消えたら赤）
#   - どのスキルも規律本文を**自分の側へ持たないこと**（正本が 2 本目に増えたら赤）
# 後者が無いと、参照を残したまま本文を再び書き写す変更が緑で通る。
#
# 正本は docs-template/05-operations/deployment/markdown-patch-discipline.md。
# 置き場所が docs-template 配下なのは、公開同期の対象（`--list-targets` の PUBLIC_TARGETS）に
# 載り、かつ**どのスキルも所有しない**ため。スキル配下へ置くと所有スキルだけ参照トークンの
# 形が変わり（`references/x.md` と `../<skill>/references/x.md`）、1 つのリテラルで全件を
# 要求できなくなる（ACE-1767-2: 共有先がリテラルで同じ形を要求していれば到達しない）。
# 先例は同ディレクトリの ace-domain.md（複数スキルが共有する契約文書）。
#
# 参照はコードフェンスの外にあることを要求する。フェンス内のコメントは
# skill-references-existence の抽出対象外で、参照先が壊れても検出されないため
# 「読めるが実在しない参照」を作れてしまう。
#
# 名簿（REQUIRED_SKILLS）は手で維持する並行リストである。**新しいスキルが本文パッチを
# 始めても自動では名簿に載らない** — これは host-route-parity の contracts 表と同じ
# 原理的な限界で、名簿へ足すのは人側の受け持ち。その代わり、名簿に載っている名前が
# 実体から消える方向（改名・削除）は検査が赤にする。
#
# 静的な参照検査と、Python3/一時領域で文書内の照合例を実行する検査。ネットワークと実CLIは使わず、skip 経路を持たない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/markdown-patch-discipline-refs/verify.sh
#
# run-all-required: yes — 正本・名簿のスキル・保存バイト検査はプラグイン配布物の一部で、配布先 checkout でも実在する。skip 経路を持たないため明示宣言で必須名簿へ載せる
# 空振り検出: 一時ファイルの置き場所の節を改名すると (1)・(8) の 4 件、正本の 2 行から cygpath の失敗の停止と W= の出力を外すと 2 件、asdd-work の参照からアンカーを外すと 1 件、refine-issue の手順を /tmp 直書きへ戻すと 1 件が赤（各 rc=1。正常は 48 件 pass。2026-10-25 WSL 実測）。
# 空振り検出: 名簿空/実体不在/正本不在は (2)/(3)/(1) が赤。追加節の欠落/空、規定・参照欠落、照合無効化、値ファイル経路の欠落・改行正規化など17変異を各rc=1で検出し、無害対照1件はrc=0を実測。値ファイル不在・空/0件/複数アンカーは文書内の例を実行して対象不変で停止することを確認。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# フェンス・閉じた HTML コメントのマスクは共有実装を使う（表形式や走査規則を知っている
# コードを 2 箇所へ写すと、同じものを読んでいるはずの検査が別々に腐るため）。
# shellcheck source=../lib/docs-scan.sh
. "$PLUGIN_ROOT/tests/lib/docs-scan.sh"

SSOT_REL='docs-template/05-operations/deployment/markdown-patch-discipline.md'
SSOT="$PLUGIN_ROOT/$SSOT_REL"

# スキル配下から見た正本への相対パス。全スキルで同一リテラルであることが本 suite の前提。
REF_TOKEN='../../docs-template/05-operations/deployment/markdown-patch-discipline.md'

# 正本が持つべき 3 点（公開 ff-dev-toolkit の `#110` が列挙した失敗モード）。見出し文字列で
# 固定する — 本文の言い回しではなく節の実在を見る。
REQUIRED_SECTIONS=(
  '## 1. heredoc ではなく coding ヘッダー付きの script file にする'
  '## 2. 値はシェル変数ではなく `sys.argv` で渡す'
  '## 3. パッチと後続コマンドを同じ実行にまとめない'
  '## リテラル書き込みの既定経路'
  '## 一時ファイルの置き場所'
)

# 「一時ファイルの置き場所」節をアンカー付きで指す参照元（プラグインルート起点）。節の改名・削除で
# 各手順から置き場所の求め方へたどれなくなる形を赤にする（MD051 は無効で、skill-references-existence は
# #fragment を落としてから照合するので、ほかの suite では見えない）
TEMP_DIR_ANCHOR='markdown-patch-discipline.md#一時ファイルの置き場所'
TEMP_DIR_REFERRERS=(
  docs-template/05-operations/deployment/git-workflow.md
  skills/asdd-init/SKILL.md
  skills/asdd-work/SKILL.md
  skills/close-issue/references/effort.md
  skills/refine-issue/references/actions.md
)

# Markdown 本文へ文字列パッチを当てうるスキル。
REQUIRED_SKILLS=(
  ace-curate
  close-issue
  create-issue
  refine-issue
  retrospective
  out-of-scope-issue
  multi-implement
  spec-driven
)

# 規律本文がスキル側へ書き戻された兆候。正本の python 例が持つ coding ヘッダーそのもので、
# これがスキルに現れたら「参照ではなく本文」が置かれている。
DUP_SIGNATURE='-*- coding: utf-8 -*-'

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== (1) 規律の正本 =="

if [[ -s "$SSOT" ]]; then
  ok "正本が実在し非空: $SSOT_REL"
else
  bad "正本が存在しないか空です: $SSOT_REL"
  echo "✗ markdown-patch-discipline-refs verify: 正本欠落のため中断" >&2
  exit 1
fi

for section in ${REQUIRED_SECTIONS[@]+"${REQUIRED_SECTIONS[@]}"}; do
  rc=0
  grep -qF -- "$section" "$SSOT" || rc=$?
  case "$rc" in
    0) ok "正本が節を持つ: $section" ;;
    1) bad "正本に節がありません: $section" ;;
    *) bad "正本を読めませんでした（grep rc=${rc}）: $SSOT_REL" ;;
  esac
done

echo "== (2) 名簿が空でない =="

if [[ ${#REQUIRED_SKILLS[@]} -ge 2 ]]; then
  ok "名簿が 2 件以上（${#REQUIRED_SKILLS[@]} 件）"
else
  bad "名簿が空か 1 件です（${#REQUIRED_SKILLS[@]} 件）。1 件以下では「正本 + 参照」の担保が成立しません"
fi

echo "== (3) 名簿のスキルが実体として存在する =="

for skill in ${REQUIRED_SKILLS[@]+"${REQUIRED_SKILLS[@]}"}; do
  if [[ -s "$PLUGIN_ROOT/skills/$skill/SKILL.md" ]]; then
    ok "実体あり: skills/$skill/SKILL.md"
  else
    bad "名簿にあるスキルの SKILL.md がありません（改名・削除？）: skills/$skill/SKILL.md"
  fi
done

echo "== (4) 各スキルがフェンス外で正本を参照する =="

for skill in ${REQUIRED_SKILLS[@]+"${REQUIRED_SKILLS[@]}"}; do
  skill_md="$PLUGIN_ROOT/skills/$skill/SKILL.md"
  [[ -s "$skill_md" ]] || continue   # (3) で既に赤
  hits=0
  # マスク後（フェンス・閉じた HTML コメントを潰した写し）で数える。
  hits="$(ff_docs_mask_spans "$skill_md" | grep -cF -- "$REF_TOKEN" || true)"
  if [[ "$hits" -ge 1 ]]; then
    ok "フェンス外に正本への参照あり（$hits 件）: skills/$skill/SKILL.md"
  else
    bad "フェンス外に正本への参照がありません: skills/$skill/SKILL.md（'$REF_TOKEN' を本文へ置いてください）"
  fi
done

echo "== (5) 参照先がスキルディレクトリ起点で解決する =="

for skill in ${REQUIRED_SKILLS[@]+"${REQUIRED_SKILLS[@]}"}; do
  resolved="$PLUGIN_ROOT/skills/$skill/$REF_TOKEN"
  if [[ -e "$resolved" ]]; then
    ok "参照が解決する: skills/$skill → $SSOT_REL"
  else
    bad "参照がスキルディレクトリ起点で解決しません: skills/$skill/$REF_TOKEN"
  fi
done

echo "== (6) 規律本文がスキル側へ複製されていない =="

dup_found=0
for skill_md in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
  [[ -e "$skill_md" ]] || continue
  rc=0
  grep -qF -- "$DUP_SIGNATURE" "$skill_md" || rc=$?
  case "$rc" in
    0) bad "規律本文がスキルへ複製されています（正本は 1 本）: ${skill_md#"$PLUGIN_ROOT/"}"; dup_found=1 ;;
    1) : ;;
    *) bad "スキルを読めませんでした（grep rc=${rc}）: ${skill_md#"$PLUGIN_ROOT/"}"; dup_found=1 ;;
  esac
done
[[ "$dup_found" -eq 0 ]] && ok "どのスキルも規律本文の署名（${DUP_SIGNATURE}）を持たない"

echo "== (7) 生成scriptと実行前照合の契約 =="
# shellcheck source=../lib/section-scope.sh
. "$PLUGIN_ROOT/tests/lib/section-scope.sh"
for needle in '生成 script 自身の作成・再編集も同じ経路' '期待値を生成物自身から作らない' '実行前に保存バイトを独立の期待値と照合'; do
  if section_scope_contains "$SSOT" '## リテラル書き込みの既定経路' "$needle" >/dev/null; then
    ok "リテラル節の本体に規定あり: $needle"
  else
    bad "リテラル節の本体に規定がありません: $needle"
  fi
done
if ff_docs_mask_spans "$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md" | grep -F '(./markdown-patch-discipline.md#リテラル書き込みの既定経路)' >/dev/null; then
  ok "git-workflowの実装入口が正本節を参照"
else
  bad "git-workflowの実装入口から正本節へ到達できません"
fi
if section_scope_contains "$SSOT" '## 2. 値はシェル変数ではなく `sys.argv` で渡す' 'escape を含むアンカー・置換値はコマンド引数へ直接埋め込まない' >/dev/null; then
  ok "escapeを含む値はファイルで渡す規定がある"
else
  bad "escapeを含む値を引数へ直接渡さない規定がありません"
fi
if section_scope_contains "$SSOT" '## 5. 適用後は目視ではなく述語で突き合わせる' '最終ファイルの対象リテラルが独立の期待バイト・出現数と一致' >/dev/null; then
  ok "最終ファイルも独立の期待値で照合する"
else
  bad "scriptだけでなく最終ファイルも照合する規定がありません"
fi
echo "== (8) 一時ファイルの置き場所 =="
# 正本の節が求め方の 2 行（TMPDIR 起点・cygpath -m の失敗で止める・変換後の値を出力）を持つ
for needle in 'W="${TMPDIR:-/tmp}/' 'W="$(cygpath -m "$W")" || exit 2' 'echo "W=$W"'; do
  if section_scope_contains "$SSOT" '## 一時ファイルの置き場所' "$needle" >/dev/null; then
    ok "置き場所の節に求め方がある: ${needle}"
  else
    bad "置き場所の節に求め方がありません: ${needle}"
  fi
done
# 節を指す参照元が、フェンスの外にアンカー付きの参照を持つ
if [[ ${#TEMP_DIR_REFERRERS[@]} -lt 1 ]]; then
  bad "置き場所の節の参照元の名簿が空です"
fi
for rel in ${TEMP_DIR_REFERRERS[@]+"${TEMP_DIR_REFERRERS[@]}"}; do
  if [[ ! -s "$PLUGIN_ROOT/$rel" ]]; then
    bad "置き場所の節の参照元がありません（改名・削除？）: ${rel}"
  elif ff_docs_mask_spans "$PLUGIN_ROOT/$rel" | grep -F -- "$TEMP_DIR_ANCHOR" >/dev/null; then
    ok "置き場所の節へのアンカー付き参照あり: ${rel}"
  else
    bad "置き場所の節へのアンカー付き参照がフェンスの外にありません: ${rel}（'${TEMP_DIR_ANCHOR}'）"
  fi
done
# 名簿のスキル（本文パッチで一時ファイルを使う）の手順例に /tmp の直書きが無い。Windows の Git Bash では
# python / node のコードやホストのファイル編集機能がドライブ直下の別の場所を読む
tmp_found=0
for skill in ${REQUIRED_SKILLS[@]+"${REQUIRED_SKILLS[@]}"}; do
  for md in "$PLUGIN_ROOT/skills/$skill/SKILL.md" "$PLUGIN_ROOT"/skills/"$skill"/references/*.md; do
    [[ -e "$md" ]] || continue
    rc=0
    grep -nF -- '/tmp/' "$md" >&2 || rc=$?
    case "$rc" in
      0) bad "手順例に /tmp の直書きがあります（作業ディレクトリは置き場所の節の 2 行で求める）: ${md#"$PLUGIN_ROOT/"}"; tmp_found=1 ;;
      1) : ;;
      *) bad "スキルを読めませんでした（grep rc=${rc}）: ${md#"$PLUGIN_ROOT/"}"; tmp_found=1 ;;
    esac
  done
done
[[ "$tmp_found" -eq 0 ]] && ok "名簿のスキルの手順例に /tmp の直書きが無い"

BYTE_CASES="$SCRIPT_DIR/literal-cases.py"
if [[ ! -r "$BYTE_CASES" || ! -s "$BYTE_CASES" ]]; then
  bad "保存バイトの実行検査が無いか空、または読めません"
elif ! command -v python3 >/dev/null 2>&1; then
  bad "保存バイトの実行検査に必要なpython3がありません"
elif python3 -I -X utf8 "$BYTE_CASES" "$SSOT"; then
  ok "文書内の照合例が正常値/誤変換/対象不在を区別する"
else
  bad "文書内の照合例または保存バイトの検査が失敗"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✓ markdown-patch-discipline-refs verify: 全 $PASS 件 pass"
  exit 0
fi
echo "✗ markdown-patch-discipline-refs verify: $FAIL 件 fail / $PASS 件 pass" >&2
exit 1
