#!/usr/bin/env bash
#
# ROADMAP のリリース表に書かれた版・日付が CHANGELOG の実体と一致することの検査（Issue #841）。
#
# 背景: `docs/07-project-management/ROADMAP.md` §3「バージョンロードマップ」の表末尾が
# `v0.29.0 ... ← 現行` のまま 26 版・10 日ぶん取り残されていた。既存ゲートはどれも
# ROADMAP を読んでいない — `changelog-contract` は plugin.json と CHANGELOG 先頭だけを
# 見て docs/ を 1 文字も読まず、`docs-fact-drift` は件数・閾値の **数値** claim 専用で
# 版番号は対象外（derive() が数値以外を導出失敗として弾く）。
#
# 設計:
#   - **現在値マーカーを禁止する**（検査 D）。`← 現行` のように「今どこか」を ROADMAP へ
#     手書きすると、リリースのたびに追従が要る = 必ず腐る。2026-08-24 の 1 日だけで 6 版
#     出ており、抜粋表を毎回書き換える運用は成立しない。現行版の正本は plugin.json
#     （と CHANGELOG 先頭）で、その一致は `changelog-contract` が既に見ている。
#     したがって ROADMAP 側は**履歴の抜粋に徹する**ことにし、腐る書き方そのものを弾く。
#   - 残る検査は「書いてある版が実在するか」（B）と「日付が実体と合っているか」（C）。
#     どちらも追従を要求しない — 過去の版と日付は後から変わらないため、リリースを重ねても
#     赤にならない。抜粋なので**全版の掲載は求めない**（部分集合であることは検査しない）。
#   - 抽出が 0 件なら赤（fail-closed）。表の書式を変えて照合が空振りしたまま緑になるのを防ぐ。
#
# ROADMAP を持たないチェックアウト（公開リポジトリ側など）では行頭 `○ skip`。
# FF_DOCS_REPO_ROOT で対象リポジトリのルートを差し替えられる（selftest 用）。
#
# read-only 環境で動かせるよう一時ファイルを作らない。
#
# run-all-required: no — live docs 不在は正当な適用外。ゲートの検出力は対の selftest が必須名簿側で担保する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DEFAULT_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

ROADMAP="$ROOT/docs/07-project-management/ROADMAP.md"

if [ ! -f "$ROADMAP" ]; then
  echo "○ skip: $ROADMAP が無いためスキップ（本 suite の検査は1件も実行されていません。docs/ を持つリポジトリで実行してください）"
  exit 0
fi

# CHANGELOG の解決は**レイアウトで分岐する**。`oss/ff-dev-toolkit/` があるのは SSOT
# モノレポで、そこに CHANGELOG が無いのはリポジトリの破損であって「別の場所にある」
# ではない。リポジトリ直下へ fallback すると、たまたま別の CHANGELOG が一致して緑に
# なり、SSOT の欠落を隠す。直下を見るのは oss/ を持たない配置（公開 checkout 等）だけ。
CHANGELOG=""
if [ -d "$ROOT/oss/ff-dev-toolkit" ]; then
  CHANGELOG="$ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
  if [ ! -f "$CHANGELOG" ]; then
    echo "✗ SSOT レイアウトなのに $CHANGELOG がありません（リポジトリ直下へ fallback せず赤にします）" >&2
    exit 1
  fi
elif [ -f "$ROOT/CHANGELOG.md" ]; then
  CHANGELOG="$ROOT/CHANGELOG.md"
else
  echo "✗ CHANGELOG.md が見つかりません（oss/ff-dev-toolkit/ と リポジトリ直下 を確認）" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- A. リリース表からの抽出 --------------------------------------------------
# `### バージョンロードマップ` 節の**最初の**コードフェンスを表とみなし、その中の
# `vX.Y.Z  YYYY-MM-DD` 行を拾う。罫線（├── / └──）の有無は問わない — 書式の装飾に
# 依存すると、装飾を変えた瞬間に空振りして静かに緑になる。
#
# 範囲の決め方（どちらも「検査域が広がって別物を読む」事故への対処）:
#   - 節の終端はフェンス外の**任意の見出し**（`#` 始まり）。`### ` だけで止めると、
#     直後の小節を消したり表を章末へ動かしたりした瞬間に後続の `## ` 節まで走査域へ
#     入り、無関係なフェンスの版を「表に載っている」と誤読する（実測で再現）
#   - 節内にフェンスが 2 つ以上あるときは**どれが表か決められない**ので赤にする。
#     連結すると、表を消しても別フェンスの版で緑になれてしまう
echo "== A. リリース表の抽出 =="

FENCE_COUNT="$(
  awk '
    /^### バージョンロードマップ/ { sec = 1; next }
    sec && !infence && /^#/ { exit }
    sec && /^```/ { infence = !infence; if (infence) n++ ; next }
    END { print n + 0 }
  ' "$ROADMAP"
)"

if [ "$FENCE_COUNT" -gt 1 ]; then
  bad "リリース表の節にコードフェンスが ${FENCE_COUNT} 個あります（どれが表か決められないため赤。表は 1 つに保ってください）"
  echo "  ROADMAP: $ROADMAP" >&2
  exit 1
fi

FENCE_BODY="$(
  awk '
    /^### バージョンロードマップ/ { sec = 1; next }
    sec && !infence && /^#/ { exit }
    sec && /^```/ { infence = !infence; if (infence) n++ ; next }
    sec && infence && n == 1 { print }
  ' "$ROADMAP"
)"

# 版らしき行（`vX.Y.Z` を含む行）は**全行**が版+日付として解析できること。
# 「解析できた行が 1 件以上あれば緑」にすると、1 行だけ日付書式が壊れた版が抽出から
# 静かに落ちて未検査になる（`2026/08/10` や `v` 落ち。実測で再現）。fail-closed は
# 全滅時だけでなく**行単位**で効かせる。
CANDIDATES="$(printf '%s\n' "$FENCE_BODY" | { grep -E 'v[0-9]+\.[0-9]+\.[0-9]+' || true; })"
ENTRIES="$(
  printf '%s\n' "$CANDIDATES" \
    | sed -nE 's/.*v([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1 \2/p'
)"
UNPARSED="$(
  printf '%s\n' "$CANDIDATES" \
    | { grep -vE '.*v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}' || true; } \
    | { grep -v '^$' || true; }
)"

count_lines() { # 空文字列を 0 と数える（`grep -c ''` は空入力でも 1 行と数えない）
  if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c '' | tr -d ' '; fi
}
ENTRY_COUNT="$(count_lines "$ENTRIES")"

if [ "$ENTRY_COUNT" -eq 0 ]; then
  bad "リリース表から '版 + 日付' を 1 件も抽出できません（節見出し・フェンス・行書式のいずれかが変わった可能性。fail-closed）"
  echo "  ROADMAP: $ROADMAP" >&2
  echo "  検査は成立していません" >&2
  exit 1
fi
ok "リリース表から ${ENTRY_COUNT} 件の '版 + 日付' を抽出"

if [ -n "$UNPARSED" ]; then
  bad "版を含むのに '版 + 日付' として解析できない行があります（未検査のまま緑にしない）"
  printf '%s\n' "$UNPARSED" | sed 's/^/      /' >&2
else
  ok "版を含む行はすべて解析できた（解析漏れ 0 行）"
fi

# ---- B/C. CHANGELOG の実体との照合 --------------------------------------------
echo "== B. 版が CHANGELOG に実在すること =="
echo "== C. 日付が CHANGELOG と一致すること =="

MISSING=""
MISMATCH=""
while IFS=' ' read -r ver date; do
  [ -n "$ver" ] || continue
  # awk 一発で取る。`grep | head | sed` は (1) head の早期終了で grep が SIGPIPE を
  # 受ける (2) 不在版で grep が exit 1 を返し pipefail + set -e で suite ごと落ちる
  # (3) それを塞ぐ `|| true` が読み取り異常まで握りつぶす、の 3 つを同時に抱える。
  # awk は不在でも exit 0 なので、「不在」と「異常」を呼び出し側で分けられる。
  actual="$(
    awk -v ver="$ver" '
      BEGIN { esc = ver; gsub(/\./, "\\.", esc); re = "^## \\[?" esc "\\]? - " }
      $0 ~ re {
        if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
          print substr($0, RSTART, RLENGTH); exit
        }
      }
    ' "$CHANGELOG"
  )"
  if [ -z "$actual" ]; then
    MISSING="${MISSING}v${ver} "
  elif [ "$actual" != "$date" ]; then
    MISMATCH="${MISMATCH}v${ver}(ROADMAP=${date} CHANGELOG=${actual}) "
  fi
done <<EOF
$ENTRIES
EOF

if [ -n "$MISSING" ]; then
  bad "CHANGELOG に存在しない版が ROADMAP に載っています: ${MISSING}"
else
  ok "抽出した全 ${ENTRY_COUNT} 版が CHANGELOG に実在"
fi

if [ -n "$MISMATCH" ]; then
  bad "日付が CHANGELOG と食い違っています: ${MISMATCH}"
else
  ok "抽出した全 ${ENTRY_COUNT} 版の日付が CHANGELOG と一致"
fi

# ---- D. 現在値マーカーの禁止 ---------------------------------------------------
# 「今どこか」を ROADMAP へ手書きさせない（腐る書き方の構造的排除）。
#
# 検出範囲は**リリース表のフェンス内に限る**。マーカーが腐るのは表の 1 行として版へ
# 付いた場合であり、「マーカーを書くな」と規定する散文はマーカー文字列を含んでいても
# 正当（文書全体を対象にすると、禁止事項を説明する文が自分で赤を出す）。
#
# 検出は**語彙とは別に矢印そのもの**でも行う。`← 現行` の 2 表記だけをブロックリストに
# すると、`（現行）` / `← 現在` / `※ 最新` / `<- current` が素通りし、同じ腐り方が別表記で
# 再発できる（実測で確認）。表の説明列に矢印を書く正当な用途は無い — 罫線は別文字
# （├ U+251C / └ U+2514 / ─ U+2500）なので、`←` と `<-` を弾いても誤検知しない。
#
# 固定文字列で検索する — 多バイト文字をブラケット式へ入れると LC_ALL=C 下で
# バイト単位に分解される（run-all case 11 の MBCS ガードが見ている壊れ方）。
echo "== D. 現在値マーカー（表の中の「いまここ」表記）が無いこと =="

MARKER_HITS="$(
  printf '%s\n' "$FENCE_BODY" \
    | { grep -n -e '←' -e '<-' -e '現行' -e '現在' -e '最新' || true; }
)"
if [ -n "$MARKER_HITS" ]; then
  bad "ROADMAP に現在値マーカーがあります（リリースのたびに追従が要る = 腐る書き方）"
  printf '%s\n' "$MARKER_HITS" | sed 's/^/      /' >&2
  echo "      → マーカーを外し、現行版の参照先（plugin.json / CHANGELOG 先頭）を示す記述へ置き換えてください" >&2
else
  ok "現在値マーカーなし（現行版の正本は plugin.json 側。changelog-contract が検査）"
fi

echo
echo "ROADMAP:   $ROADMAP"
echo "CHANGELOG: $CHANGELOG"
echo "結果: pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
