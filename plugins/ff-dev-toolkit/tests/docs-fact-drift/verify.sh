#!/usr/bin/env bash
#
# docs/ に手書きした件数・閾値と実体のドリフト検査（Issue #519）。
#
# #512 で docs/ を実体で書き下ろした際、プラグイン数・スキル数・suite 数・MCP ツール数
# などを本文へ手書きした。既存の `skill-count-consistency` は marketplace.json と
# plugin.json だけを見ており **docs/ は 1 文字も読まない**（同 suite のヘッダ自身が
# 「件数そのものをこのファイルに書かない」と述べているとおり、手書きの件数は腐る）。
# 実際に #501 では marketplace の「18」が実体 20 と乖離し、59 suite のどれも検出せず
# Codex のクロスレビューが拾った。
#
# 設計:
#   - 期待値は**すべて実体から導出**する（この suite に数値を書かない）
#   - 各 claim は「正準表現」で照合し、**1 件も一致しなければ赤**（書式変更で抽出が
#     空振りして緑になるのを防ぐ = fail-closed）
#   - 走査対象は `## Changelog` 節を除いた本文（Changelog はその時点の事実の記録で、
#     現在の実体と一致する必要がない）。共通実装は tests/lib/docs-scan.sh
#   - 走査は**フェンスの中身を含む**（ff_docs_claim_body。Issue #525）。本リポジトリの
#     フェンスは例示だけでなく図（```text 構成図 / ```mermaid 依存図）の置き場でもあり、
#     実体の件数が手書きされる。例示として意図的に古い数字を書く場合は claim の除外列で
#     narrowing する（現状そういう記述は無い。全数調査は Issue #525 コメント。なお除外列は
#     **全文書共通の行単位固定文字列**なので、本物の claim 行に現れない語を選ぶこと —
#     文書単位のスコープは持たない）
#
# 正準表現を使う理由: 単位だけで拾うと別概念の数値まで巻き込む（例「移行した 14 スキル」
# 「後続 4 suite の実行を止めた」）。したがって claim ごとに文脈を含む表現を固定し、
# 表現を変えたら**この suite も同時に更新する**運用にする（更新漏れは空振り = 赤で判る）。
#
# ただし正準表現を**リテラルの空白＋数字**に固定すると、`**68** suite` /
# `` `68` suite `` のように件数を Markdown の強調・コードスパンで装飾した記載が一致せず、
# 照合対象から静かに落ちる（Issue #529）。hits は全対象文書で合算されるため、正準表現の
# 記載が 1 件でも残っていれば空振りガード（hits == 0 → 赤）も発火せず、装飾された古い
# 件数だけが見逃される。そこで claim の ERE には数値を直接書かず、プレースホルダ `%N%`
# を置き、**装飾を任意に許す数値**（NUM_ERE）へ機械的に展開する。11 claim すべてへ
# 一様に効くことは A2 の自己検証で機械的に固定する。
#
# 検出範囲の限界（意図的）: 許すのは**数値まわりの装飾**だけで、語順や単位表記そのものを
# 変えた記載（`suite 数は 68` / `68 スイート`）は依然として照合対象に入らない。これらまで
# 拾うには単位語だけで走査することになり、上に挙げた別概念（「移行した 14 スキル」
# 「後続 4 suite」）を巻き込む = 誤検知を claim ごとの除外列で潰し続ける運用になる。
# 同じ理由で、装飾のせいで**単位語との間の空白が落ちた**記載（`**7**プラグイン`）も照合
# しない。NUM_ERE 側で空白を任意にすると `[0-9]+プラグイン` 相当まで一致するようになり、
# 版番号・箇条書き番号・別概念の数値を拾う面が広がる（展開も入り組む）。
# 件数の書き方はレビューで正準形へ寄せる前提とし、ここでは主張しない。
#
# docs/MASTER.md が無いチェックアウト（公開リポジトリ側など）では行頭 `○ skip`。
#
# FF_DOCS_REPO_ROOT で対象リポジトリのルートを差し替えられる（selftest 用）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DEFAULT_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

# shellcheck source=../lib/docs-scan.sh
. "$SCRIPT_DIR/../lib/docs-scan.sh"

DOCS_ROOT="$ROOT/docs"

if [ ! -f "$DOCS_ROOT/MASTER.md" ]; then
  echo "○ skip: $DOCS_ROOT/MASTER.md が無いためスキップ（本 suite の検査は1件も実行されていません。docs/ を持つリポジトリで実行してください）"
  exit 0
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- 実体からの導出 ----------------------------------------------------------
# 導出元が読めない場合は空にして「導出できない = 赤」にする（fail-closed）。

# 導出値が 0 のときは「実体が 0 件」ではなく導出失敗として扱う（derive を参照）。
#
# 導出元は**すべて ${ROOT} 基準**にする。suite 自身の位置（${PLUGIN_ROOT}）を混ぜると、
# FF_DOCS_REPO_ROOT で差し替えた fixture ではなく実リポジトリを読んでしまい、
# 「導出元が壊れたら赤」の検出力を selftest で測れなくなる（実際に測って発覚）。
ROOT_PLUGIN="$ROOT/plugins/ff-dev-toolkit"
ROOT_TESTS="$ROOT_PLUGIN/tests"
MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"
INIT_DOCS_SKILL="$ROOT_PLUGIN/skills/init-docs/SKILL.md"
MCP_INDEX="$ROOT_PLUGIN/mcp/src/index.ts"
ACE_SIZE_TS="$ROOT_PLUGIN/docs-template/scripts/ace/check-category-size.ts"
ACE_REPORT_TS="$ROOT_PLUGIN/docs-template/scripts/ace/ace-refine-report.ts"

derive() { # $1=説明 $2=コマンド文字列（数値を stdout へ）
  local label="$1" out
  out="$(eval "$2" 2>/dev/null || true)"
  case "$out" in
    ''|*[!0-9]*) echo "" ; return ;;   # 数値以外（空・複数行・失敗）は導出失敗
  esac
  # **0 も導出失敗として扱う。** `find <消えたディレクトリ> | wc -l` は find が
  # エラー終了しても 0 を出すため、導出元の消失が「実体は 0 件」に化ける。
  # 本 suite の 11 claim はいずれも健全なチェックアウトで必ず 1 以上（プラグイン数・
  # スキル数・suite 数・MCP ツール数・初期セット件数・ACE の各閾値）。
  if [ "$out" -eq 0 ]; then echo "" ; return ; fi
  printf '%s\n' "$out"
}

D_PLUGINS="$(derive plugins "jq '.plugins | length' '$MARKETPLACE'")"
D_SKILLS="$(derive skills "find '$ROOT/plugins' -mindepth 4 -maxdepth 4 -name SKILL.md -type f | wc -l | tr -d ' '")"
D_FF_SKILLS="$(derive ff_skills "find '$ROOT_PLUGIN/skills' -mindepth 2 -maxdepth 2 -name SKILL.md -type f | wc -l | tr -d ' '")"
D_SUITES="$(derive suites "find '$ROOT_TESTS' -mindepth 2 -maxdepth 2 -name verify.sh -type f | wc -l | tr -d ' '")"
D_MCP_TOOLS="$(derive mcp_tools "grep -c '^server.registerTool(' '$MCP_INDEX' | tr -d ' '")"
D_INITIAL_SET="$(derive initial_set "awk '/^### 2\./ { s=1; next } s && /^\`\`\`/ { if (f) exit; f=1; next } f' '$INIT_DOCS_SKILL' | grep -oE '[A-Za-z_]+\.md' | LC_ALL=C sort -u | wc -l | tr -d ' '")"
D_ACE_WARN="$(derive ace_warn "grep -oE 'DEFAULT_WARN_ENTRIES_PER_CATEGORY = [0-9]+' '$ACE_SIZE_TS' | grep -oE '[0-9]+' | head -1")"
D_ACE_BLOCK="$(derive ace_block "grep -oE 'DEFAULT_MAX_ENTRIES_PER_CATEGORY = [0-9]+' '$ACE_SIZE_TS' | grep -oE '[0-9]+' | head -1")"
D_ENTRY_LINES="$(derive entry_lines "grep -oE 'DEFAULT_MAX_ENTRY_LINES = [0-9]+' '$ACE_SIZE_TS' | grep -oE '[0-9]+' | head -1")"
D_PROMOTE="$(derive promote "grep -oE 'DEFAULT_PROMOTE_HELPFUL_MIN = [0-9]+' '$ACE_REPORT_TS' | grep -oE '[0-9]+' | head -1")"

echo "== A. 期待値の導出 =="
for pair in \
  "プラグイン数:$D_PLUGINS" \
  "総スキル数:$D_SKILLS" \
  "ff-dev-toolkit スキル数:$D_FF_SKILLS" \
  "suite 数:$D_SUITES" \
  "MCP ツール数:$D_MCP_TOOLS" \
  "初期セット件数:$D_INITIAL_SET" \
  "ACE refine 目安:$D_ACE_WARN" \
  "ACE ブロック上限:$D_ACE_BLOCK" \
  "ACE 1 エントリ行数:$D_ENTRY_LINES" \
  "ACE 昇格 Helpful:$D_PROMOTE" \
; do
  label="${pair%%:*}"; val="${pair#*:}"
  # ${val} を波括弧で囲む: bash 3.2 は 波括弧なしの val に続く多バイト文字を変数名の一部として読み、
  # set -u 下で unbound variable になる（run-all case 11 の MBCS ガード対象）
  if [ -n "$val" ]; then
    ok "${label} = ${val}（実体から導出）"
  else
    bad "${label} を実体から導出できません（導出元の場所か書式が変わった可能性。fail-closed）"
  fi
done

# ---- claim の照合 ------------------------------------------------------------
# claim 定義: name|期待値|数値を捕まえる ERE|除外する行の固定文字列|必須の固定文字列
# 空欄は「指定なし」。同じ単位が別概念に使われる claim は 4/5 列目で narrowing する。
#
# 3 列目の ERE には数値を直接書かず `%N%` を置く（Issue #529）。照合直前に NUM_ERE へ
# 展開され、`68` / `**68**` / `` `68` `` のいずれも同じ 1 件として拾える。
# 装飾として許すのは `*`（強調）と `` ` ``（コードスパン）だけに絞る:
#   - 全角空白は**入れない**。ブラケット式に多バイト文字を書くと LC_ALL=C 下で
#     バイト単位に分解される（run-all case 11 の MBCS ガードが見ている壊れ方）
#   - `_`（強調の別記法）も入れない。本リポジトリの docs に用例が無く、許容文字を
#     増やすほど別概念を巻き込む面が広がるだけになる
# 展開後も 1 一致に含まれる数値は 1 つのまま（装飾クラスに数字を含めないため）。
NUM_ERE='[*`]*[0-9]+[*`]*'
#
# 実装上の注意（性能）: 行ごとに grep を起動すると 1 万行 × 全 claim で 10 万プロセス
# 規模になり、suite 単体で 10 分を超える。**ファイル単位で 1 回 grep して一致行だけを
# 取り出し**、その数行に対してのみフィルタと数値抽出を行う。
CLAIMS=(
  # 「調査時点」を含む行は歴史スナップショット（例: DECISIONS.md ADR-024 の
  # 「調査時点（2026-08-10、7 プラグイン・98 スキル）」）であり、現在値の主張では
  # ないため照合から除外する（プラグイン数・総スキル数の 2 claim。selftest G22）
  "プラグイン数|${D_PLUGINS}|%N% プラグイン|調査時点|"
  "総スキル数（計 N スキル）|${D_SKILLS}|計 %N% スキル||"
  "総スキル数（N プラグイン・N スキル）|${D_SKILLS}|プラグイン・%N% スキル|調査時点|"
  "ff-dev-toolkit スキル数|${D_FF_SKILLS}|ff-dev-toolkit（%N% スキル||"
  "suite 数|${D_SUITES}|%N% suite|後続|"
  "MCP ツール数|${D_MCP_TOOLS}|%N% ツール|コミット|spec-docs"
  "初期セット件数|${D_INITIAL_SET}|初期セット %N% ファイル||"
  "ACE refine 目安|${D_ACE_WARN}|refine 目安 %N%||"
  "ACE ブロック上限|${D_ACE_BLOCK}|ブロック上限 %N%||"
  "ACE 1 エントリ行数|${D_ENTRY_LINES}|エントリ %N% 行||"
  "ACE 昇格 Helpful|${D_PROMOTE}|Helpful >= %N%||昇格"
)

# claim ごとの ERE を照合用へ展開する（`%N%` → NUM_ERE）
claim_ere() { # $1=claim 定義行
  local raw
  raw="$(printf '%s' "$1" | cut -d'|' -f3)"
  printf '%s' "${raw//%N%/${NUM_ERE}}"
}

echo "== A2. claim 定義の自己検証（装飾許容が全 claim へ一様に効くこと）=="
# `%N%` を使わず生の `[0-9]` を書いた claim は、装飾された記載をそのぶんだけ見逃す
# （Issue #529 の穴が 1 claim だけ残る形）。claim を足すときの歯止めとしてここで弾く。
BAD_CLAIMS=""
for claim in "${CLAIMS[@]}"; do
  c_name="$(printf '%s' "${claim}" | cut -d'|' -f1)"
  c_raw="$(printf '%s' "${claim}" | cut -d'|' -f3)"
  case "${c_raw}" in
    *'%N%'*) ;;
    *) BAD_CLAIMS="${BAD_CLAIMS}${c_name}（%N% が無い） " ; continue ;;
  esac
  case "${c_raw}" in
    *'[0-9]'*|*'[[:digit:]]'*) BAD_CLAIMS="${BAD_CLAIMS}${c_name}（生の数値クラスを含む） " ;;
  esac
done
if [ -z "${BAD_CLAIMS}" ]; then
  ok "全 ${#CLAIMS[@]} claim が %N% で数値を表現している（装飾された件数も同じ 1 件として拾う）"
else
  bad "数値を %N% で表現していない claim があります: ${BAD_CLAIMS}"
fi

# NUM_ERE 自身の性質もここで固定する。claim 側が全部 %N% でも、NUM_ERE を `[0-9]+` へ
# 戻せば装飾許容は消える（上のループは通過してしまう）。直接プローブして、**戻し変異が
# ゲート単体で赤になる**ようにしておく。素の数値も引き続き一致すること（後方互換）まで見る。
# `grep -q` は最初の一致で終了して上流を SIGPIPE で殺し、pipefail 下では一致していても
# 非 0 になるため、件数で受ける。
DEC_MISS=""
for probe in '**1**' '`1`' '*1*' '1'; do
  probe_hits="$(printf '%s\n' "${probe}" | grep -cE "^${NUM_ERE}$" || true)"
  [ "${probe_hits:-0}" -ne 0 ] || DEC_MISS="${DEC_MISS}${probe} "
done
if [ -z "${DEC_MISS}" ]; then
  ok "NUM_ERE が装飾付き・素の数値の双方に一致する（**1** / \`1\` / *1* / 1）"
else
  bad "NUM_ERE が次の表記に一致しません: ${DEC_MISS}（装飾許容が失われています）"
fi

echo "== B. 走査対象の導出 =="
# ACE Playbook の分割ファイル（08-knowledge/playbook/**）は追記型の歴史記録で、
# 本文の書き換えが運用上禁止されている（過去の実測値が現在の実体と一致する必要はなく、
# 直せもしない）。したがって走査対象は Frontmatter 付与対象の仕様文書に限定する
# （#513 と同じ導出を共有ヘルパーで行う）。
if ! TARGET_DOCS="$(ff_docs_actual_targets "$DOCS_ROOT" "$DOCS_ROOT/MASTER.md")"; then
  bad "走査対象を導出できません（MASTER.md §Frontmatter 付与しない表の抽出に失敗。fail-closed）"
  TARGET_DOCS=""
fi
target_n=0
[ -z "$TARGET_DOCS" ] || target_n="$(printf '%s\n' "$TARGET_DOCS" | wc -l | tr -d ' ')"
if [ "$target_n" -gt 0 ]; then
  ok "走査対象 ${target_n} 文書（ACE 分割ファイルは対象外）"
else
  bad "走査対象が 0 件です（抽出の空振りを緑にしない）"
fi

echo "== C. docs/ の手書き件数と実体の照合 =="

# claim ごとの集計を「名前=hits:mismatch」の 1 行として持つ（bash 3.2 に連想配列がない）
TALLY=""
tally_add() { # $1=claim index $2=hits の増分 $3=mismatch の増分
  TALLY="${TALLY}${1} ${2} ${3}
"
}

# 文書を外側、claim を内側に回す（本文の取り出しを 1 文書 1 回に抑える）
while IFS= read -r rel; do
  [ -n "${rel}" ] || continue
  # ff_docs_body ではなく claim 用の本文を使う（フェンス内の図に手書きした件数も
  # 走査する。Issue #525。Changelog 境界の判定はフェンスを消したマスクで行われる）
  body="$(ff_docs_claim_body "${DOCS_ROOT}/${rel}")"
  idx=0
  for claim in "${CLAIMS[@]}"; do
    idx=$((idx + 1))
    c_expect="$(printf '%s' "${claim}" | cut -d'|' -f2)"
    c_ere="$(claim_ere "${claim}")"
    c_skip="$(printf '%s' "${claim}" | cut -d'|' -f4)"
    c_need="$(printf '%s' "${claim}" | cut -d'|' -f5)"
    [ -n "${c_expect}" ] || continue   # 導出失敗は A で赤にしている
    matched="$(printf '%s\n' "${body}" | grep -E "${c_ere}" || true)"
    [ -n "${matched}" ] || continue
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      if [ -n "${c_skip}" ]; then
        case "${line}" in *"${c_skip}"*) continue ;; esac
      fi
      if [ -n "${c_need}" ]; then
        case "${line}" in *"${c_need}"*) ;; *) continue ;; esac
      fi
      # 一致は**1 件ずつ read で受ける**。`for hit in $(...)` は単語分割に加えて
      # パス名展開も通るため、装飾を許した ERE が返す `**68** suite` のような一致が
      # glob として解釈される（Issue #529）。read なら空白も装飾記号もそのまま運べる。
      while IFS= read -r hit; do
        [ -n "${hit}" ] || continue
        # 1 つの一致に数値が 2 つ以上入る ERE は claim 定義の誤り（どちらを比べるべきか
        # 決まらない）。黙って先頭を採らず赤にする。
        nums="$(printf '%s\n' "${hit}" | grep -oE '[0-9]+' | wc -l | tr -d ' ')"
        if [ "${nums}" -ne 1 ]; then
          c_name="$(printf '%s' "${claim}" | cut -d'|' -f1)"
          echo "  ✗ ${c_name}: 正準表現が 1 一致に数値を ${nums} 個含みます（claim 定義の誤り）: ${hit}" >&2
          tally_add "${idx}" 1 1
          continue
        fi
        num="$(printf '%s\n' "${hit}" | grep -oE '[0-9]+')"
        if [ "${num}" = "${c_expect}" ]; then
          tally_add "${idx}" 1 0
        else
          tally_add "${idx}" 1 1
          c_name="$(printf '%s' "${claim}" | cut -d'|' -f1)"
          echo "  ✗ ${c_name}: ${rel} の記載 ${num} が実体 ${c_expect} と一致しません" >&2
          printf '      %s\n' "${line}" >&2
        fi
      done < <(printf '%s\n' "${line}" | grep -oE "${c_ere}" || true)
    done < <(printf '%s\n' "${matched}")
  done
done < <(printf '%s\n' "${TARGET_DOCS}")

# claim ごとに hits / mismatch を合計して判定する
idx=0
for claim in "${CLAIMS[@]}"; do
  idx=$((idx + 1))
  c_name="$(printf '%s' "${claim}" | cut -d'|' -f1)"
  c_expect="$(printf '%s' "${claim}" | cut -d'|' -f2)"
  if [ -z "${c_expect}" ]; then
    bad "${c_name}: 期待値が導出できていないため照合できません"
    continue
  fi
  sums="$(printf '%s\n' "${TALLY}" | awk -v i="${idx}" '$1 == i { h += $2; m += $3 } END { printf "%d %d\n", h, m }')"
  hits="$(printf '%s' "${sums}" | cut -d' ' -f1)"
  mism="$(printf '%s' "${sums}" | cut -d' ' -f2)"
  if [ "${hits}" -eq 0 ]; then
    bad "${c_name}: 正準表現に 1 件も一致しません（表現を変えたら本 suite も更新する。抽出の空振りを緑にしない）"
  elif [ "${mism}" -gt 0 ]; then
    bad "${c_name}: ${mism} 件が実体（${c_expect}）と一致しません（内訳は上記）"
  else
    ok "${c_name}: ${hits} 件すべてが実体（${c_expect}）と一致"
  fi
done

echo ""
echo "結果: pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ 検査が 1 件も成立していません" >&2
  exit 1
fi
echo "✅ docs-fact-drift: all checks passed"
