#!/usr/bin/env bash
#
# SKILL.md が参照する相対パス（references）の実在検査（Issue #889 候補1）。
#
# スキルは progressive disclosure のために本文から `references/xxx.md` や兄弟スキルの
# `../<skill>/references/xxx.md` を相対パスで参照する。この参照はプラグイン配布後も
# スキルディレクトリ起点で解決されるため、改名・移動・タイポで壊れると **スキルは
# 読み込めるのに参照先だけ静かに開けない** fail-silent になる（#882 の behavioral-
# economics では手動の python 検査で通したが、ゲート化されていなかった）。
# 本 suite は plugins/*/skills/*/SKILL.md を横断し、参照の実在を機械検査する。
# 検査対象の形式は 2 つ: (1) バッククォート単一トークン、(2) Markdown リンク
# `[text](path)` の相対パス。いずれもコードフェンス外のみ。
#
# 抽出規則（誤検知源を先に潰す設計。変更時は fixtures/ と本ヘッダを併せて更新）:
#   - バッククォート形式: インラインのバッククォート単一トークンのみ。散文中の裸の
#     「references/…」言及は対象外（パス主張ではない）
#   - リンク形式: フェンス外の `](path)` の path。インラインコード内のリンク例
#     （`[x](../fake.md)` のようなバッククォート内の記法説明）は対象外
#   - コードフェンス（``` / ~~~、3 連以上、インデント許容、閉じは同種・同長以上）の
#     内側は抽出しない。レポート例示（proofread-markdown の `../images/missing.jpeg`
#     等）や記法例（ace-refine の PLAYBOOK リンク例等）がフェンス内に置かれる実例が
#     あるため
#   - どちらの形式も `../` または `references/` で始まるトークンだけを拾う。
#     `docs/…` のような消費側プロジェクト起点のパス（ace-curate の
#     docs/08-knowledge/PLAYBOOK.md リンク等）はスキルディレクトリ起点で解決できない
#     ため対象外
#   - 空白・`<` `>`（プレースホルダ: `../<category>.md` 等）・`*` `?`（グロブ）・
#     バックスラッシュを含むトークンは除外する（パスではなく例示・散文）
#   - `#fragment` は解決前に落とす（anchor 付き参照は Markdown として正当）
#   - 末尾 `/` はディレクトリ実在（-d）、それ以外はファイル/ディレクトリ実在（-e）で判定
#   - 実在しても、物理解決（pwd -P）した先が当該プラグインの配布ルート
#     `plugins/<plugin>/` の外に出る参照は ESCAPES_PLUGIN_ROOT として赤にする
#     （配布物はプラグイン単位なので、外への参照は配布先で必ず壊れる）。
#     物理解決はディレクトリなら参照先全体を、ファイルなら親ディレクトリを解決して
#     ファイル名を結合する。末尾が .. のトークン（../../.. 等）は必ずディレクトリ
#     なので全体解決側に入り、「plugin_root/..」の文字列のまま内側判定になる
#     fail-open を起こさない
#   - 閉じられないままファイル末尾に達したフェンスは UNCLOSED_FENCE として構造違反
#     （後続トークンが静かに未抽出になるのを防ぐ。skill-bash-blocks と同じ扱い）
#
# 既知の限界（誤検知/見逃しの倒れる方向を明記する。変更時はこの一覧を更新すること）:
#   - バッククォートにもリンクにも入っていない素のパス記述は非検出（見逃し方向）
#   - `references/` 起点でない同一スキル内参照（`assets/x.md` 等）は対象外（見逃し方向）
#   - 走査集合は plugins/*/skills/*/SKILL.md の 1 グロブのみ。skill-bash-blocks が見る
#     docs-template/.github/skills/*/SKILL.md やリポジトリローカルの .claude/skills は
#     対象外 — それらは plugin_root の導出（skill_dir/../..）が成立せず、単純なグロブ
#     追加は境界検査の誤検知になる。拡張は plugin_root 導出の再設計と併せて行うこと
#     （Issue #889 判断記録の候補6）
#   - リンク形式の regex はパスに `)` を含む形（(draft).md 等）を途中で打ち切って
#     誤検知方向に、タイトル付き `](path "title")` は空白フィルタで見逃し方向に倒れる
#     （live 実測ではリンク型トークンは 3 件のみでいずれも該当なし。増えたら拡張）
#   - 最終要素自体がプラグイン外を指す symlink であるファイル参照は境界検査を通過
#     しうる（ファイルは親ディレクトリのみ物理解決するため。skills 配下に symlink は
#     現在 0 件で、リポジトリ内コンテンツによる自己参照のみを扱う本検査の脅威モデル外）
#   - 走査対象は SKILL.md のみで、references/*.md 自身が書く相対参照（2 hop 目）は
#     対象外（見逃し方向）。live の references/*.md には `references/…` 起点の表記が
#     実在し（genai-consultant の 5 トークン）、ファイル相対では解決しない — 2 hop 目
#     の走査拡張は参照起点の規約（ファイル相対かスキルルート相対か）の決定を伴う
#     follow-up（Issue #889 判断記録の候補7）
#
# fail-closed:
#   - 抽出器・解決器の検出力は fixtures/ の violation / clean / variants / tree fixture
#     で毎回実測し、期待と一致しなければ横断検査へ進まず赤にする
#   - SKILL.md が 0 件、または横断抽出トークンが 0 件なら「参照ゼロ」ではなく
#     「走査が成立していない」として赤にする（実測: 全プラグインで 150+ トークン）
#   - 全緑時の検査件数を EXPECTED_CHECKS で固定する。EXPECTED_* の全文一致は検査の
#     中身を守るが、assert 呼び出しごと削除された検査は検出できないため、件数側から
#     「検査が黙って消えていない」ことを固定する（検査を増減したら併せて更新）
#
# 一時ディレクトリを使わない read-only の静的検査（依存: awk・grep・sed・dirname と
# bash 組み込みのみ。ヒアストリング/ヒアドキュメントも使わない — bash はそれらを
# 一時ファイルで実装するため、書き込み不可の環境で suite ごと落ちる）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGINS_DIR="$(cd "$PLUGIN_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PLUGINS_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# expected / actual の全文一致を検査し、不一致なら両方を並べて報告する。
assert_output_equals() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    bad "${label}: 結果が期待と不一致:"
    { echo "    expected:"; printf '%s\n' "$expected" | sed 's/^/    | /'
      echo "    actual:";   printf '%s\n' "$actual"   | sed 's/^/    | /'; } >&2
  fi
}

# コードフェンス外から参照トークンを「行番号:トークン」で出力する。対象は
# (1) インラインバッククォート単一トークン、(2) Markdown リンク `](path)` の path
# （インラインコードを除去した残りから抽出）。フェンス追跡は skill-bash-blocks と
# 同じ状態機械（``` / ~~~、3 連以上、インデント許容、閉じは同種・同長以上）。
scan_reference_tokens() {
  awk '
    function keep(tok) {
      if (tok !~ /^(\.\.\/|references\/)/) return 0
      if (tok ~ /[[:space:]<>*?\\]/) return 0
      return 1
    }
    { sub(/\r$/, "") }
    in_block == 1 {
      stripped = $0
      sub(/^[[:space:]]*/, "", stripped)
      sub(/[[:space:]]*$/, "", stripped)
      if (stripped ~ /^(`+|~+)$/ && substr(stripped, 1, 1) == fence_char && length(stripped) >= fence_len) in_block = 0
      next
    }
    /^[[:space:]]*(```|~~~)/ {
      fence = $0
      sub(/^[[:space:]]*/, "", fence)
      fence_char = substr(fence, 1, 1)
      fence_len = 0
      while (substr(fence, fence_len + 1, 1) == fence_char) fence_len++
      in_block = 1
      open_line = FNR
      next
    }
    {
      rest = $0
      while (match(rest, /`[^`]+`/)) {
        tok = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        if (keep(tok)) print FNR ":" tok
      }
      # リンク形式はインラインコードを除去した残りから拾う（バッククォート内の
      # リンク記法例を実パス主張と誤認しない）。
      nocode = $0
      gsub(/`[^`]+`/, " ", nocode)
      rest = nocode
      while (match(rest, /\]\([^)]+\)/)) {
        tok = substr(rest, RSTART + 2, RLENGTH - 3)
        rest = substr(rest, RSTART + RLENGTH)
        if (keep(tok)) print FNR ":" tok
      }
    }
    END {
      # 閉じ忘れフェンスは以降の全行を飲み込み、参照トークンが静かに未抽出になる
      # （負の主張の検査対象が無言で縮む）ため構造違反として報告する。
      if (in_block == 1) print open_line ":UNCLOSED_FENCE フェンスが EOF まで閉じられていない"
    }
  ' "$1"
}

# 1 ファイルの抽出トークンをスキルディレクトリ起点で解決し、違反だけを出力する。
#   - 実在しない参照: 「行番号:トークン」
#   - 実在するがプラグイン配布ルート外: 「行番号:トークン ESCAPES_PLUGIN_ROOT」
#   - UNCLOSED_FENCE は素通しで違反扱い
# ヒアストリングは一時ファイルを要するため使わず、scanner の出力をパイプで受ける
# （ループはサブシェルだが、出力しか使わないので変数更新に依存しない）。
resolve_broken() {
  local file="$1" skill_dir plugin_root hit tok path target real base
  skill_dir="$(cd "$(dirname "$file")" && pwd -P)"
  plugin_root="$(cd "$skill_dir/../.." && pwd -P)"
  scan_reference_tokens "$file" | while IFS= read -r hit; do
    tok="${hit#*:}"
    case "$tok" in
      "UNCLOSED_FENCE"*) printf '%s\n' "$hit"; continue ;;
    esac
    path="${tok%%#*}"
    target="$skill_dir/$path"
    if [[ "$path" == */ ]]; then
      if [ ! -d "$target" ]; then printf '%s\n' "$hit"; continue; fi
      real="$(cd "$target" && pwd -P)"
    elif [ ! -e "$target" ]; then
      printf '%s\n' "$hit"; continue
    elif [ -d "$target" ]; then
      # 末尾が .. や . のトークン（例 ../../..）は必ずディレクトリなのでこちらへ入る。
      # 親だけの物理解決だと real が「plugin_root/..」の文字列のまま内側判定になる
      # fail-open があるため、ディレクトリは全体を物理解決する。
      real="$(cd "$target" && pwd -P)"
    else
      base="${target##*/}"
      case "$base" in
        .|..) printf '%s\n' "$hit ESCAPES_PLUGIN_ROOT"; continue ;; # -d が偽なら到達しないはずの fail-closed 防御
      esac
      real="$(cd "${target%/*}" && pwd -P)/$base"
    fi
    case "$real" in
      "$plugin_root"|"$plugin_root"/*) : ;;
      *) printf '%s\n' "$hit ESCAPES_PLUGIN_ROOT" ;;
    esac
  done
}

echo "== SKILL.md references 参照の実在検査 =="

# ---- 自己検証（検出力の実測を恒久化） -----------------------------------------
# 抽出・解決 fixture が期待どおりに赤くならない = 検出器が壊れている状態で本検査を
# 先へ進めない。負の主張（壊れた参照ゼロ）の検査は、検出力の正の主張を先に通す。
for fixture in extract-violation.md extract-clean.md extract-variants.md \
               tree/skills/skill-a/SKILL.md outside.md; do
  [ -f "$FIXTURES_DIR/$fixture" ] || { echo "✗ fixture がありません: $FIXTURES_DIR/$fixture" >&2; exit 1; }
done

EXPECTED_EXTRACT="3:references/a.md
4:../skill-b/references/b.md
5:../skill-b/references/
6:../..
7:../category.md#ace-001
8:references/x.md
8:../y.md
9:../docs-template/principles.md
10:references/z.md#sec
11:references/m.md
11:../n.md
13:UNCLOSED_FENCE フェンスが EOF まで閉じられていない"
actual_extract="$(scan_reference_tokens "$FIXTURES_DIR/extract-violation.md")" \
  || { echo "✗ 自己検証の scan が失敗しました（extract-violation.md）" >&2; exit 1; }
assert_output_equals "抽出 fixture の全トークンを期待どおり抽出（バッククォート・リンク・fragment・ディレクトリ・複数/行・UNCLOSED_FENCE）" \
  "$EXPECTED_EXTRACT" "$actual_extract"

clean_extract="$(scan_reference_tokens "$FIXTURES_DIR/extract-clean.md")" \
  || { echo "✗ 自己検証の scan が失敗しました（extract-clean.md）" >&2; exit 1; }
assert_output_equals "非検出 fixture（フェンス内例示・プレースホルダ・グロブ・空白・裸の言及・別接頭辞・スキーム・インラインコード内リンク例）を誤検知しない" \
  "" "$clean_extract"

# 非検出主張のデコイ実在確認: clean fixture から負荷担体が消えると「誤検知しない」が
# 空主張になる。代表 3 種（プレースホルダ・フェンス内例示・インラインコード内リンク例）
# の存在を正の主張で固定する。
if grep -F '`../<category>.md#ace-xxx`' "$FIXTURES_DIR/extract-clean.md" >/dev/null \
   && grep -F '`../images/missing.jpeg`' "$FIXTURES_DIR/extract-clean.md" >/dev/null \
   && grep -F '`[x](../fake.md)`' "$FIXTURES_DIR/extract-clean.md" >/dev/null; then
  ok "非検出 fixture のデコイ（プレースホルダ / フェンス内例示 / インラインコード内リンク例）が実在する"
else
  bad "非検出 fixture のデコイが欠落しています（extract-clean.md を確認）"
fi

EXPECTED_VARIANTS="3:references/crlf.md
16:../w/workflow.md"
actual_variants="$(scan_reference_tokens "$FIXTURES_DIR/extract-variants.md")" \
  || { echo "✗ 自己検証の scan が失敗しました（extract-variants.md）" >&2; exit 1; }
assert_output_equals "フェンス変種 fixture（CRLF・4 連バッククォート・内側の短い疑似閉じ・タグ違い）を期待どおり処理" \
  "$EXPECTED_VARIANTS" "$actual_variants"

# CRLF fixture の実在確認: 行末 CR が失われると変種検査が普通の LF 検査に退化する。
if grep -c $'\r$' "$FIXTURES_DIR/extract-variants.md" >/dev/null; then
  ok "フェンス変種 fixture が CRLF 行末を保持している"
else
  bad "フェンス変種 fixture に CRLF 行末がありません（extract-variants.md を確認）"
fi

EXPECTED_BROKEN="8:references/gone.md
9:../skill-b/references/gone.md
10:../nope/references/
11:references/ok.md/
12:../skill-b/references/gone2.md
13:../../../outside.md ESCAPES_PLUGIN_ROOT
14:../../.. ESCAPES_PLUGIN_ROOT"
actual_broken="$(resolve_broken "$FIXTURES_DIR/tree/skills/skill-a/SKILL.md")" \
  || { echo "✗ 自己検証の resolve が失敗しました（tree fixture）" >&2; exit 1; }
assert_output_equals "解決 fixture の違反だけを期待どおり検出（実在するファイル・兄弟・ディレクトリ・fragment 付き・リンク形式は緑 / 欠落とルート外脱出は赤）" \
  "$EXPECTED_BROKEN" "$actual_broken"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ skill-references-existence verify: 検出器の自己検証に失敗（横断検査は実行しない）" >&2
  exit 1
fi

# ---- 全 SKILL.md 横断検査 ------------------------------------------------------
shopt -s nullglob
SKILL_FILES=("$PLUGINS_DIR"/*/skills/*/SKILL.md)
shopt -u nullglob

if [ "${#SKILL_FILES[@]}" -eq 0 ]; then
  echo "✗ SKILL.md が 1 件も見つかりません（検査対象ゼロは異常）: $PLUGINS_DIR" >&2
  exit 1
fi

# 正の主張: 参照形式ごとの実在コントロールが検査対象に入っており、抽出器が live データ
# からそのトークンを実際に拾う。グロブの起点ずれ・抽出 regex の腐りで対象が静かに
# 空振りする事故を防ぐ（コントロールを移動・改名したらここも更新すること）。
# コントロールは全件 ff-dev-toolkit 内で完結させる — 公開 checkout（PUBLIC_TARGETS =
# plugins/ff-dev-toolkit + oss のみ）には他プラグインが存在せず、他プラグインの
# ファイルを要求すると公開側で suite ごと赤になるため。兄弟スキル形式
# （../<skill>/references/…）は ff-dev-toolkit の live に実例が無いので、その検出力は
# fixture ツリー（tree/skills/skill-a → skill-b）が担う。
# 照合はトークン部分の行単位完全一致（部分一致だと .bak 等の別トークンでも通ってしまう）。
check_control_token() {
  local file="$1" want="$2" label="$3" found
  if [ ! -f "$file" ]; then
    bad "コントロールが検査対象にありません: ${file#"$REPO_ROOT"/}"
    return
  fi
  found="$(scan_reference_tokens "$file" | awk -v want="$want" '
    { tok = substr($0, index($0, ":") + 1); if (tok == want) n++ }
    END { print n + 0 }
  ')" || { echo "✗ scanner 自体が失敗しました: $file" >&2; exit 1; }
  if [ "$found" -gt 0 ]; then
    ok "コントロール（${label}）から ${want} を抽出できる"
  else
    bad "コントロール（${label}）から ${want} を抽出できません（抽出器の空振りか、コントロール側の参照が変更された。移動・改名ならこの検査のコントロール定義を更新）: ${file#"$REPO_ROOT"/}"
  fi
}
check_control_token "$PLUGINS_DIR/ff-dev-toolkit/skills/spec-driven/SKILL.md" \
  "references/spec-docs-map.md" "同一スキル内・バッククォート"
check_control_token "$PLUGINS_DIR/ff-dev-toolkit/skills/ace-curate/SKILL.md" \
  "../.." "../ 起点・バッククォート"
check_control_token "$PLUGINS_DIR/ff-dev-toolkit/skills/close-issue/SKILL.md" \
  "../../docs-template/05-operations/deployment/workflow-principles.md" "リンク形式"

total_tokens=0
for file in "${SKILL_FILES[@]}"; do
  count="$(scan_reference_tokens "$file" | awk -F: '$2 !~ /^UNCLOSED_FENCE/ { n++ } END { print n + 0 }')" \
    || { echo "✗ scanner 自体が失敗しました: $file" >&2; exit 1; }
  total_tokens=$((total_tokens + count))
  broken="$(resolve_broken "$file")" \
    || { echo "✗ resolver 自体が失敗しました: $file" >&2; exit 1; }
  if [ -n "$broken" ]; then
    bad "${file#"$REPO_ROOT"/} に存在しない references 参照（またはプラグイン外参照・構造違反）がある:"
    printf '%s\n' "$broken" | sed 's/^/    | /' >&2
    echo "    参照先を追加するか、パスをスキルディレクトリ起点でプラグイン配布ルート内の実在パスへ修正してください" >&2
  fi
done

if [ "$total_tokens" -eq 0 ]; then
  bad "横断抽出トークンが 0 件です（参照ゼロではなく走査の不成立を疑う。抽出規則か対象グロブが腐っている）"
fi

if [ "$FAIL" -eq 0 ]; then
  ok "全 ${#SKILL_FILES[@]} 件の SKILL.md の references 参照 ${total_tokens} 件がすべて実在しプラグイン内に収まる"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-references-existence verify: $FAIL 件失敗" >&2
  exit 1
fi

# 全緑時の検査件数ガード: EXPECTED_* の全文一致では assert 呼び出しごと削除された
# 検査を検出できないため、件数の一致まで固定する（検査を増減したらここも更新）。
EXPECTED_CHECKS=10
if [ "$PASS" -ne "$EXPECTED_CHECKS" ]; then
  echo "✗ skill-references-existence verify: 全緑だが検査件数が期待と不一致（expected: ${EXPECTED_CHECKS} / actual: ${PASS}）。検査が黙って消えたか、増減時の EXPECTED_CHECKS 更新漏れ" >&2
  exit 1
fi
echo "✓ skill-references-existence verify: 全 $PASS 件 pass"
