#!/usr/bin/env bash
#
# リポジトリ直下の指示文書（root-instructions 経路の届け先）の記載一致検査。
#
# 潰している事故: **2 入口のうち片方にしか規定が無い状態**。Claude Code は
# `CLAUDE.md` だけを自動で読み `AGENTS.md` を読まない（<https://code.claude.com/docs/en/memory>）
# ため、開発ルールは 2 文書へ同じ内容で維持する契約になっている（ADR-056）。散文の
# 「片方を更新したら、もう片方も同じ内容へ更新する」だけではドリフトする — 実測でも、
# 経路表が 2 届け先を宣言していても**中身が 1 行も届いていない**スタブを置ける状態が
# 機械的に許容されていた（2026-09-15 実測）。
#
# 既存のどのゲートも 2 文書の記載一致を見ていない:
#   - host-route-parity は届け先の**実在**（集合一致）と、contracts 表に載っている
#     契約の検出語だけを見る。表に行の無い規定は対象外
#   - docs-gates の AGENTS.md 到達点検査は `AGENTS.md` しか読まない
# 本 suite は契約表に載っていない規定も含めて「2 文書の本文が揃っていること」を見る。
#
# 設計:
#   - 対象ファイルは正本表 docs/06-reference/HOST-PARITY.md の routes 表 `root-instructions`
#     行から導出する（この suite にファイル名を直書きしない。表と実体の集合一致は
#     host-route-parity が両方向で見ているので、届け先が増えればここも自動で追う）
#   - **ホスト固有の差は文書側のマーカーで宣言する**。宣言した区間だけを比較から外し、
#     残り（= 開発ルールの本文）は行単位で完全一致を要求する。正当な差分を許すのに
#     正規化ルール（ホスト名の読み替え表など）を持たせない — 正規化は「正当な差分」と
#     「片方が腐った差分」を区別できず、検出器の側で無限に例外が増える
#   - マーカーが免除するのは**宣言した区間だけ**で、区間の中身が 2 文書で同じなら赤に
#     する。マーカーは「ここは違う」という宣言なので、同じなら宣言が腐っている。
#     verbatim コピー（`cp AGENTS.md CLAUDE.md`）はこの検査で止まる
#
# マーカーの書き方（正本は本 suite の README.md）:
#   行単位:  <末尾に> <!-- host-specific:<ID> -->
#   区間:    <!-- host-specific:<ID>:start --> … <!-- host-specific:<ID>:end -->
#   ID は英数字と `._-` のみ。同じ ID を 2 文書とも持つこと（片方にしか無ければ赤）。
#
# 実体を 1 つも実行しない。マーカーの解析に渡す正規表現は ASCII だけで、本文（日本語を
# 含む）は行単位の文字列比較でしか扱わないのでロケールに依存しない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/root-instructions-parity/verify.sh
#
# run-all-required: no — 対象のリポジトリ直下指示文書も正本表も開発元リポジトリにしか
# ないため、配布先 checkout では丸ごと適用外になる。開発元では repository 直下の docs/ の
# 実在を条件に必ず走り、正本表・対象文書の欠落は skip ではなく赤にする。
#
# 変異検出（2026-09-16 実測。検査 1 つにつき 1 変異で注入し、適用の成否を確認してから
# 結果を読んだ。赤転しなかった変異は無し。検査番号は README.md の「検査項目」に対応）:
#   CLAUDE.md にだけ規定を 1 行足すと (6) が赤になる（AGENTS.md と CLAUDE.md のマーカー外の
#     本文が一致しません + `CLAUDE.md にだけある:`）。このとき host-route-parity は緑のまま
#     = 記載一致はこの suite だけが見ている。
#   共有行を AGENTS.md から 1 行消すと (6) が赤になる（消えた側が `にだけある` に出る）。
#   共有行の順序だけを入れ替えると (6) が赤になる（「最初に分かれる行」。集合比較だけの
#     実装では落ちる差分）。
#   ホスト固有区間（install-entrypoint）の中身を CLAUDE.md 側だけ書き換えても **緑のまま**
#     = 正当なホスト固有差を偽陽性にしない。
#   CLAUDE.md を AGENTS.md への symlink へ置き換えると (2) が赤になる（symlink です +
#     同一ファイルです の 2 行）。
#   CLAUDE.md を AGENTS.md の verbatim コピーへ置き換えると (5) が赤になる（全マーカー区間の
#     「中身が同じです」。symlink 検査では止まらない経路をここが受ける）。
#   CLAUDE.md のマーカー ID を 1 つ改名すると (4) が赤になる（ID の集合不一致）。区間形・
#     行単位形のどちらでも同じ（行単位形は 2026-09-16 のレビュー修正後に追加で実測）。
#   行単位マーカーのある行へマーカー形のコメントをもう 1 つ書き足しても **緑のまま**
#     = 行末で一致したものをその行の宣言として採る。最初の出現から切り出していた版は、
#     壊れた ID を作って (4) を誤検知させていた（レビュー修正の前後で実測）。
#   区間マーカーの `:end` を 1 つ消すと (3) が赤になり、記載一致の判定へ進まない。
#   既存マーカーを除いて 2 文書とも全文を 1 区間で包むと (7) が赤になる（比較対象が 0 行）。
#     既存マーカーを残したまま包んだ場合は (3) の入れ子検出が先に赤になる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
REGISTRY="$REPO_ROOT/docs/06-reference/HOST-PARITY.md"
PARITY_TABLES="$PLUGIN_ROOT/tests/lib/host-parity-tables.sh"

# 配布先 checkout には repository の docs/ が無い。そこは検査対象そのものが存在しない
# 適用外なので suite 全体を skip する（部分 skip にすると pass 0 件の偽 green になる）。
if [ ! -d "$REPO_ROOT/docs" ]; then
  echo "○ skip: repository 直下に docs/ が無いためスキップ（配布先 checkout では正本表・リポジトリ直下の指示文書が同梱されず、本 suite の検査は1件も実行されていません）"
  exit 0
fi

if [ ! -f "$REGISTRY" ]; then
  echo "✗ 正本表が見つかりません: docs/06-reference/HOST-PARITY.md" >&2
  echo "  対象ファイルは同表の routes 表 root-instructions 行から導出します。移動したなら本 suite の REGISTRY も直してください" >&2
  exit 1
fi
[ -e "$PARITY_TABLES" ] || { echo "✗ 対象が見つかりません: $PARITY_TABLES" >&2; exit 1; }

# shellcheck disable=SC1090,SC1091 # runtime-checked repo-local shared helper
. "$PARITY_TABLES"
ff_parity_set_registry "$REGISTRY"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

NL='
'

list_has() { # <改行区切りリスト> <要素>
  case "${NL}${1}${NL}" in *"${NL}${2}${NL}"*) return 0 ;; *) return 1 ;; esac
}

# ── マーカーの解析 ───────────────────────────────────────────────────────────
#
# 1 文書を「M <ID>」（マーカーの出現）「R <ID> <本文>」（免除区間の本文）
# 「S <本文>」（比較対象の共有行）のタグ付きストリームへ正規化する。構造の異常
# （入れ子・開きっぱなし・閉じ過多・形の違うマーカー）はここで非 0 にする —
# 黙って S へ倒すと、壊れたマーカーが「全部が共有行」や「全部が免除」へ化ける。
MARK_AWK='
function mid(line, suffix,   t) {
  t = line
  sub(/^<!-- host-specific:/, "", t)
  sub(suffix "$", "", t)
  return t
}
BEGIN { open_id = "" }
{
  line = $0
  if (line ~ /^<!-- host-specific:[A-Za-z0-9._-]+:start -->$/) {
    id = mid(line, ":start -->")
    if (open_id != "") { printf "E\t区間 %s の中で区間 %s が開かれています（入れ子にしない）\n", open_id, id; exit 3 }
    open_id = id
    print "M\t" id
    next
  }
  if (line ~ /^<!-- host-specific:[A-Za-z0-9._-]+:end -->$/) {
    id = mid(line, ":end -->")
    if (open_id == "") { printf "E\t開いていない区間 %s が閉じられています\n", id; exit 3 }
    if (open_id != id) { printf "E\t区間 %s が %s で閉じられています\n", open_id, id; exit 3 }
    open_id = ""
    next
  }
  if (open_id != "") { print "R\t" open_id "\t" line; next }
  if (match(line, / <!-- host-specific:[A-Za-z0-9._-]+ -->$/)) {
    # 切り出しは index() の「最初の出現」ではなく match() が当たった位置から行う。
    # 1 行に 2 つ書かれた場合、最初の出現から切ると別のマーカーの内側を ID として
    # 読んでしまう（行末で一致したものが、この行が宣言しているマーカー）。
    id = mid(substr(line, RSTART + 1), " -->")
    print "M\t" id
    print "R\t" id "\t" substr(line, 1, RSTART - 1)
    next
  }
  if (index(line, "<!-- host-specific") > 0) { printf "E\tマーカーの形が違います: %s\n", line; exit 3 }
  print "S\t" line
}
END { if (open_id != "") { printf "E\t区間 %s が閉じられていません\n", open_id; exit 3 } }
'

tagged_of() { # <パス> : タグ付きストリーム（構造異常なら非 0 で、E 行を返す）
  awk "$MARK_AWK" "$1"
}

ids_of() { # <タグ付きストリーム>
  printf '%s\n' "$1" | awk -F'\t' '$1 == "M" { print $2 }'
}

region_of() { # <タグ付きストリーム> <ID>
  printf '%s\n' "$1" | awk -F'\t' -v id="$2" '
    $1 == "R" && $2 == id { line = $0; sub(/^R\t[^\t]*\t/, "", line); print line }
  '
}

shared_of() { # <タグ付きストリーム>
  printf '%s\n' "$1" | awk '$0 ~ /^S\t/ { line = $0; sub(/^S\t/, "", line); print line }'
}

# 共有行の食い違いを「何行目で分かれたか」と「どちらにだけある行か」の両方で出す。
# 位置比較だけだと差し込み 1 行で以降が全部ずれて読めず、集合比較だけだと**同じ行を
# 並べ替えただけ**の差分が落ちる。
DIFF_AWK='
BEGIN { FS = "\t" }
{
  side = $1
  line = $0
  sub(/^[AB]\t/, "", line)
  if (side == "A") { a[++na] = line; ca[line]++ } else { b[++nb] = line; cb[line]++ }
}
END {
  n = (na < nb) ? na : nb
  split_at = 0
  for (i = 1; i <= n; i++) {
    if (a[i] != b[i]) { split_at = i; break }
  }
  # 共通部分が一致したまま片方が長い場合は、その次の行が分かれ目になる。ループ変数の
  # 走査後の値で判定しない（n == 0 のときは一度も回らないので判定が成立しない）。
  if (split_at == 0 && na != nb) { split_at = n + 1 }
  if (split_at > 0) {
    printf "FIRST\t%d\t%s\t%s\n", split_at, (split_at <= na ? a[split_at] : "(行なし)"), (split_at <= nb ? b[split_at] : "(行なし)")
  }
  for (i = 1; i <= na; i++) if (!(a[i] in cb) && !(a[i] in seen_a)) { seen_a[a[i]] = 1; if (a[i] != "") printf "ONLY_A\t%s\n", a[i] }
  for (i = 1; i <= nb; i++) if (!(b[i] in ca) && !(b[i] in seen_b)) { seen_b[b[i]] = 1; if (b[i] != "") printf "ONLY_B\t%s\n", b[i] }
  printf "COUNT\t%d\t%d\n", na, nb
}
'

echo "== リポジトリ直下の指示文書の記載一致（正本: docs/06-reference/HOST-PARITY.md の routes 表） =="

# ── (1) 対象ファイルの導出と正体 ────────────────────────────────────────────
echo
echo "-- 対象ファイル --"

TARGETS="$(ff_parity_route_paths root-instructions)"
n_targets="$(printf '%s\n' "$TARGETS" | awk '{ n += NF } END { print n + 0 }')"
if [ "$n_targets" -lt 2 ]; then
  echo "✗ routes 表の root-instructions が届け先を 2 つ以上宣言していません（${n_targets} 件）" >&2
  echo "  2 入口必須は ADR-056。1 件に戻すなら本 suite ごと不要になるので、表と一緒に判断してください" >&2
  exit 1
fi

structure_ok=1
for rel in $TARGETS; do
  path="$REPO_ROOT/$rel"
  if [ -L "$path" ]; then
    bad "${rel} が symlink です（2 文書は別々に維持する。symlink はホスト固有の差を持てません）"
    structure_ok=0
    continue
  fi
  if [ ! -f "$path" ]; then
    bad "${rel} が通常ファイルとして実在しません"
    structure_ok=0
    continue
  fi
done

# 同一 inode（hard link）も別々の維持にならない。片方を編集したつもりで両方が動く。
for rel in $TARGETS; do
  for other in $TARGETS; do
    [ "$rel" != "$other" ] || continue
    if [ -f "$REPO_ROOT/$rel" ] && [ -f "$REPO_ROOT/$other" ] && [ "$REPO_ROOT/$rel" -ef "$REPO_ROOT/$other" ]; then
      bad "${rel} と ${other} が同一ファイルです（hard link）"
      structure_ok=0
    fi
  done
done

if [ "$structure_ok" -eq 1 ]; then
  ok "対象 ${n_targets} 件がそれぞれ独立した通常ファイル: $(printf '%s' "$TARGETS" | awk '{ $1 = $1; print }')"
else
  echo >&2
  echo "✗ root-instructions-parity verify: ${FAIL} 件失敗（対象ファイルの正体が前提を満たしません）" >&2
  exit 1
fi

# ── (2) マーカー構造 ────────────────────────────────────────────────────────
echo
echo "-- ホスト固有マーカー --"

BASE_REL=""
BASE_TAGGED=""
BASE_IDS=""
parse_ok=1
for rel in $TARGETS; do
  tagged=""
  if ! tagged="$(tagged_of "$REPO_ROOT/$rel")"; then
    bad "${rel} のホスト固有マーカーが壊れています: $(printf '%s\n' "$tagged" | awk -F'\t' '$1 == "E" { print $2; exit }')"
    parse_ok=0
    continue
  fi
  ids="$(ids_of "$tagged")"
  dup="$(printf '%s\n' "$ids" | awk 'NF { if (seen[$0]++ == 1) print $0 }')"
  if [ -n "$dup" ]; then
    bad "${rel} に同じマーカー ID が複数あります: $(printf '%s' "$dup" | tr '\n' ' ')"
    parse_ok=0
    continue
  fi
  if [ -z "$BASE_REL" ]; then
    BASE_REL="$rel"
    BASE_TAGGED="$tagged"
    BASE_IDS="$ids"
  fi
done

if [ "$parse_ok" -ne 1 ]; then
  echo >&2
  echo "✗ root-instructions-parity verify: ${FAIL} 件失敗（マーカーを解析できないので記載一致は判定していません）" >&2
  exit 1
fi
ok "全 ${n_targets} 文書のホスト固有マーカーが解析可能（区間の対応・ID の一意性）"

# ── (3) 記載一致（マーカー外の本文） ────────────────────────────────────────
echo
echo "-- 記載一致 --"

base_shared="$(shared_of "$BASE_TAGGED")"
base_shared_lines="$(printf '%s\n' "$base_shared" | awk 'NF { n++ } END { print n + 0 }')"
if [ "$base_shared_lines" -eq 0 ]; then
  bad "${BASE_REL} の比較対象が 0 行です — マーカーで全文を免除すると、この検査は何も見ていません"
fi

for rel in $TARGETS; do
  [ "$rel" != "$BASE_REL" ] || continue
  tagged="$(tagged_of "$REPO_ROOT/$rel")"
  ids="$(ids_of "$tagged")"

  # ID の集合一致。片方にだけあるマーカーは「片側だけを免除した」状態で、
  # そこに書いた規定はもう片方へ届かないまま緑になる。
  only_base=""
  only_other=""
  for id in $BASE_IDS; do
    list_has "$ids" "$id" || only_base="${only_base} ${id}"
  done
  for id in $ids; do
    list_has "$BASE_IDS" "$id" || only_other="${only_other} ${id}"
  done
  if [ -n "$only_base" ] || [ -n "$only_other" ]; then
    bad "ホスト固有マーカーの ID が ${BASE_REL} と ${rel} で一致しません"
    [ -n "$only_base" ] && echo "      ${BASE_REL} にだけある:${only_base}" >&2
    [ -n "$only_other" ] && echo "      ${rel} にだけある:${only_other}" >&2
  else
    ok "ホスト固有マーカーの ID が ${BASE_REL} と ${rel} で一致（$(printf '%s' "$BASE_IDS" | tr '\n' ' ')）"
  fi

  # 免除区間の中身が同じなら、その区間は「ホスト固有」ではない。マーカーの腐りと、
  # 片方をもう片方の verbatim コピーで置き換えた状態（symlink 検査では止まらない）が
  # ここで赤になる。
  for id in $BASE_IDS; do
    list_has "$ids" "$id" || continue
    if [ "$(region_of "$BASE_TAGGED" "$id")" = "$(region_of "$tagged" "$id")" ]; then
      bad "ホスト固有マーカー ${id} の中身が ${BASE_REL} と ${rel} で同じです（ホスト固有の差が無いならマーカーを外し、共有本文として揃える）"
    else
      ok "ホスト固有マーカー ${id} が ${BASE_REL} と ${rel} で実際に異なる"
    fi
  done

  # マーカー外の本文は行単位で完全一致。
  other_shared="$(shared_of "$tagged")"
  if [ "$base_shared" = "$other_shared" ]; then
    ok "${BASE_REL} と ${rel} のマーカー外の本文が完全一致（${base_shared_lines} 行）"
    continue
  fi

  bad "${BASE_REL} と ${rel} のマーカー外の本文が一致しません"
  report="$( { printf '%s\n' "$base_shared" | awk '{ print "A\t" $0 }'; printf '%s\n' "$other_shared" | awk '{ print "B\t" $0 }'; } | awk "$DIFF_AWK" )"
  printf '%s\n' "$report" | while IFS= read -r line; do
    case "$line" in
      FIRST*)
        idx="$(printf '%s' "$line" | awk -F'\t' '{ print $2 }')"
        la="$(printf '%s' "$line" | awk -F'\t' '{ print substr($3, 1, 60) }')"
        lb="$(printf '%s' "$line" | awk -F'\t' '{ print substr($4, 1, 60) }')"
        echo "      最初に分かれる行（マーカー外 ${idx} 行目）:" >&2
        echo "        ${BASE_REL}: ${la}" >&2
        echo "        ${rel}: ${lb}" >&2
        ;;
      ONLY_A*)
        echo "      ${BASE_REL} にだけある: $(printf '%s' "$line" | awk -F'\t' '{ print substr($2, 1, 80) }')" >&2
        ;;
      ONLY_B*)
        echo "      ${rel} にだけある: $(printf '%s' "$line" | awk -F'\t' '{ print substr($2, 1, 80) }')" >&2
        ;;
      COUNT*)
        echo "      マーカー外の行数: ${BASE_REL}=$(printf '%s' "$line" | awk -F'\t' '{ print $2 }') / ${rel}=$(printf '%s' "$line" | awk -F'\t' '{ print $3 }')" >&2
        ;;
    esac
  done
done

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ root-instructions-parity verify: $FAIL 件失敗" >&2
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ root-instructions-parity verify: pass が 0 件 — 検査が成立していません" >&2
  exit 1
fi
echo "✓ root-instructions-parity verify: 全 $PASS 件 pass"
