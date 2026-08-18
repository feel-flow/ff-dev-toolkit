#!/usr/bin/env bash
#
# 対象プロジェクトの docs/ を検査する suite の共有実装（Issue #513 / #519 / #518）。
#
# 3 つの suite が「docs/ を歩く」「Frontmatter を読む」「フェンス / コメント境界を
# 尊重する」を必要とするため、実装を 1 か所に置く（同じ走査を 3 本書くと、片方だけ
# 直される drift がそのまま検出漏れになる）。
#
# 提供する関数:
#   ff_docs_rule_targets <master_md>   規則側の対象一覧（MASTER.md から導出）
#   ff_docs_exclusion_patterns <master_md>  除外パターン（付与しない表から導出）
#   ff_docs_actual_targets <docs_root> <master_md>
#                                      実体側の対象一覧（FS から導出、除外規則適用）
#   ff_docs_fm_verdict <file>          Frontmatter / Changelog 構造の判定
#   ff_docs_mask_spans <file>          閉じたフェンスは空行化・閉じたコメントは該当文字を除去
#   ff_docs_body <file>                走査用の本文（Frontmatter・マスク済み・Changelog 節を除く）
#
# 設計上の制約:
#   - bash 3.2 互換（連想配列・mapfile を使わない）
#   - 正規表現は ASCII クラスのみ（BSD ツールの MBCS 事故防止。run-all case 11）
#   - パイプ入力への grep -q は使わない（SIGPIPE 事故防止。run-all case 10）
#   - **一覧をこのファイルに直書きしない**。両側を導出して比較するのが目的なので、
#     ここに件数や対象名を持つと最初に腐る（`skill-count-consistency` と同じ方針）

# 規則側の対象一覧を MASTER.md から導出して stdout へ 1 行 1 件で出す。
#
# 内訳（いずれも MASTER.md 内の記述から導出。ハードコードしない）:
#   1. §関連ドキュメント の相対リンク（コア7文書の 6 件 + 初期セットのその他文書）
#   2. MASTER.md 自身（§Frontmatter が「コア7文書（MASTER/...）」と規定している）
#   3. §Frontmatter 付与対象表の「ACE Playbook 索引」行に書かれたパス
ff_docs_rule_targets() {
  local master="$1"
  {
    # 1. §関連ドキュメント の ](./path.md) 形式のリンク
    awk '
      /^## 関連ドキュメント/ { in_sec = 1; next }
      in_sec && /^## / { exit }
      in_sec { print }
    ' "$master" | grep -oE '\]\(\./[A-Za-z0-9_/-]+\.md\)' | sed -e 's|^](\./||' -e 's|)$||'
    # 2. MASTER.md 自身
    echo "MASTER.md"
    # 3. 付与対象表の ACE Playbook 索引 行の 1 つ目のバッククォート
    awk -F'`' '/^\| ACE Playbook 索引/ { print $2; exit }' "$master"
  } | LC_ALL=C sort -u
}

# 実体側の対象一覧を docs/ の実ファイルから導出して stdout へ 1 行 1 件で出す。
# 除外は MASTER.md §Frontmatter の「付与しない（非仕様文書）」表の第 1 列から導出する。
ff_docs_actual_targets() {
  local docs_root="$1" master="$2"
  local excl pat rel matched
  excl="$(ff_docs_exclusion_patterns "$master")" || return 1
  # 除外は shell の case による glob 一致で行う（awk -v は値に改行を含められない —
  # BSD awk は "newline in string" で落ちる。ここを awk に寄せると macOS だけ壊れる）。
  # 表記の `docs/` 接頭辞と末尾 `**` は剥がして前方一致の glob へ正規化する。
  local norm=""
  # プロセス置換を使う（here-doc / here-string は bash が一時ファイルを作るため、
  # 書き込み不可の TMPDIR では `cannot create temp file for here document` で落ちる。
  # 本 suite は純粋なファイル検査なので read-only 環境でも完走できるべき）
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    pat="${pat#docs/}"
    case "$pat" in */\*\*) pat="${pat%\*\*}*" ;; esac
    norm="$norm$pat
"
  done < <(printf '%s\n' "$excl")
  find "$docs_root" -name '*.md' -type f | sed -e "s|^$docs_root/||" | LC_ALL=C sort | {
    while IFS= read -r rel; do
      matched=0
      while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        # shellcheck disable=SC2254 # pat は意図的に glob として展開する
        case "$rel" in $pat) matched=1; break ;; esac
      done < <(printf '%s\n' "$norm")
      [ "$matched" -eq 1 ] || printf '%s\n' "$rel"
    done
  }
}

# 付与しない表の第 1 列（バッククォート内）を 1 行 1 件で stdout へ。
# 一時ファイルを作らない（suite の read-only 契約と、TMPDIR 不可環境での skip 回避）。
# 1 件も取れなければ抽出の空振りなので非 0 で返す（fail-closed）。
ff_docs_exclusion_patterns() {
  local master="$1" out
  # 表は「付与しない」見出しの直後に現れ、最初の非テーブル行で終わる。
  # 別見出しで打ち切る形（例: 付与する）は、文書内の出現順が入れ替わると
  # 区間が末尾まで伸びて無関係な表の行まで拾うため使わない。
  out="$(awk -F'`' '
    /^\*\*付与しない/ { in_sec = 1; next }
    in_sec && /^\| `/ { rows = 1; print $2; next }
    in_sec && /^\|/   { next }          # ヘッダ・区切り行
    in_sec && rows     { exit }          # 表が終わった
  ' "$master")"
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# Frontmatter / Changelog 構造の判定。stdout に "OK" または "NG:<理由>" を出す。
#
# 検査内容は tests/docs-template-frontmatter/verify.sh の C〜G を基にした契約:
#   先頭行が --- / Frontmatter が閉じている / 必須6フィールドが引用符付きで揃う /
#   version が SemVer / status が値域内 / changeImpact は存在時のみ小文字値域 /
#   `## Changelog` 見出しがある（Frontmatter より後ろ）
#
# ただし次の 4 点は docs-template-frontmatter より**厳しい**（PR #524 のレビュー）:
#   - 重複キーを拒否する。「有効な行が 1 本あれば OK」にすると
#     `version: "2.1.0"` と `version: "invalid"` の併記が通り、宣言と YAML パーサの
#     実効値（多くは後勝ち）が食い違う。キー名は正規化して数えるので
#     `version : "x"`（コロン前の空白）と `"version"` / `'version'`（引用符付きキー）も拾う。
#     行頭アンカーのため、インデントされた入れ子キーとコメント行は数えない
#   - SemVer の先頭ゼロを拒否する（`01.0.0` / `1.02.3` は SemVer 違反）
#   - `created` / `updated` の形式（YYYY-MM-DD）と前後関係（updated >= created）を見る
#   - `## Changelog` を Frontmatter より後ろに限る（YAML コメントとして 1 行置くだけで
#     通ってしまうのを防ぐ）
# docs-template-frontmatter 側への反映と、そちらが本 lib を使う形への統合は Issue #526。
ff_docs_fm_verdict() {
  local f="$1"
  [ -f "$f" ] || { echo "NG:ファイルが存在しません"; return 0; }
  if [ "$(head -1 "$f")" != "---" ]; then
    echo "NG:先頭行が Frontmatter 開始（---）ではありません"
    return 0
  fi
  local close_line
  close_line="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$f")"
  if [ -z "$close_line" ]; then
    echo "NG:Frontmatter が閉じていません（2 行目以降に --- がない）"
    return 0
  fi
  # `## Changelog` の有無はマスク後の行で判定する（フェンス内の例示を本物の節と
  # 数えないため）。Frontmatter の各フィールドは行位置が要るので原文で見る。
  # 探索は Frontmatter の閉じ行より後ろに限る — `## Changelog` は YAML コメントとしても
  # 成立する（`#` 始まり）ので、Frontmatter 内に 1 行置くだけで本文の節が無くても
  # 通ってしまう。マスクは行数を保つので原文と行番号が一致する。
  local has_changelog=0
  # ここも exit しない（上流の SIGPIPE を避ける）
  if [ -n "$(ff_docs_mask_spans "$f" | awk -v fm_end="$close_line" \
       'NR > fm_end && /^## Changelog$/ { found = 1 } END { if (found) print "1" }')" ]; then
    has_changelog=1
  fi
  local flags
  flags="$(awk -v fm_end="$close_line" '
    BEGIN { nkeys = split("title version status owner created updated changeImpact", KEYS, " ") }
    NR >= 2 && NR < fm_end {
      # キーの出現回数を数える。重複キーは YAML として不正で、実効値はパーサ依存
      # （多くは後勝ち）。フラグを OR で立てるだけだと
      # `version: "2.1.0"` + `version: "invalid"` が通り、ゲートが保証した値と
      # 実際に読まれる値が食い違う。
      #
      # キー名は正規化して数える — `version : "x"`（コロン前の空白）、
      # `"version": "x"` と `'version': "x"`（引用符付きキー）はどれも YAML として
      # 同じキーなので、完全前置（index == 1）だけで数えると取り逃す。行頭アンカーなので
      # インデントされた入れ子キーとコメント行は数えない。既知キー以外
      # （MASTER.md §任意フィールド の reviewers / tags 等）も対象にする
      if (match($0, /^["\047]?[A-Za-z][A-Za-z0-9_-]*["\047]?[ \t]*:/)) {
        k = substr($0, 1, RLENGTH); sub(/[ \t]*:$/, "", k); gsub(/["\047]/, "", k)
        cnt[k]++
        if (!(k in SEEN)) { SEEN[k] = 1; nfound++; FOUND[nfound] = k }
      }
      if ($0 ~ /^title: "[^"]+"$/)    f["title"] = 1
      if ($0 ~ /^version: "[^"]+"$/)  f["version"] = 1
      # SemVer は各要素の先頭ゼロを認めない（01.0.0 / 1.02.3 は違反）
      if ($0 ~ /^version: "(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"$/) f["semver"] = 1
      if ($0 ~ /^status: "[^"]+"$/)   f["status"] = 1
      if ($0 ~ /^status: "(draft|review|approved|deprecated)"$/) f["statusdom"] = 1
      if ($0 ~ /^owner: "[^"]+"$/)    f["owner"] = 1
      if ($0 ~ /^created: "[^"]+"$/)  f["created"] = 1
      if ($0 ~ /^updated: "[^"]+"$/)  f["updated"] = 1
      # 日付は YYYY-MM-DD（月 01-12 / 日 01-31）。暦としての妥当性（2 月 30 日など）は
      # 見ない — 狙いは誤記と雛形の残りを弾くことで、暦計算は範囲外
      if ($0 ~ /^created: "[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])"$/) f["cfmt"] = 1
      if ($0 ~ /^updated: "[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])"$/) f["ufmt"] = 1
      if ($0 ~ /^changeImpact:/)      f["ci"] = 1
      # 引用符は「両側あり」か「両側なし」のみ受理する（片側だけは YAML として不正）。
      # docs-template 側は常に引用符付きだが、本リポジトリの PLAYBOOK.md は
      # scripts/ace/sync-playbook-frontmatter.ts が引用符なしで書くため両形を許す。
      if ($0 ~ /^changeImpact: "(low|medium|high)"$/) f["cidom"] = 1
      if ($0 ~ /^changeImpact: (low|medium|high)$/)   f["cidom"] = 1
    }
    END {
      # 重複キーは固定順で並べる（awk の for-in は順序不定なのでメッセージが揺れる）。
      # 既知キーを宣言順で先に、それ以外を出現順で後に置く
      dup = ""
      for (ki = 1; ki <= nkeys; ki++) {
        if (cnt[KEYS[ki]] > 1) { dup = (dup == "" ? KEYS[ki] : dup "," KEYS[ki]); DONE[KEYS[ki]] = 1 }
      }
      for (ki = 1; ki <= nfound; ki++) {
        if (cnt[FOUND[ki]] > 1 && !(FOUND[ki] in DONE)) {
          dup = (dup == "" ? FOUND[ki] : dup "," FOUND[ki]); DONE[FOUND[ki]] = 1
        }
      }
      printf "title=%d version=%d semver=%d status=%d statusdom=%d owner=%d created=%d updated=%d ci=%d cidom=%d cfmt=%d ufmt=%d dupkeys=%s\n", \
        f["title"], f["version"], f["semver"], f["status"], f["statusdom"], \
        f["owner"], f["created"], f["updated"], f["ci"], f["cidom"], \
        f["cfmt"], f["ufmt"], (dup == "" ? "-" : dup)
    }
  ' "$f")"
  # 重複キーは他の違反より先に報告する（欠落や値域違反として説明されると原因を誤る）
  case " $flags " in
    *" dupkeys=- "*) ;;
    *) echo "NG:Frontmatter に重複キーがあります（YAML として不正・実効値がパーサ依存）: ${flags##*dupkeys=}"; return 0 ;;
  esac
  local key missing=""
  for key in title version status owner created updated; do
    case " $flags " in *" $key=1 "*) ;; *) missing="$missing $key" ;; esac
  done
  [ -z "$missing" ] || { echo "NG:必須フィールドが欠落または引用符なし:${missing}"; return 0; }
  case " $flags " in *" semver=1 "*) ;; *) echo 'NG:version が SemVer 形式（"x.y.z"・先頭ゼロ不可）ではありません'; return 0 ;; esac
  case " $flags " in *" statusdom=1 "*) ;; *) echo "NG:status が値域（draft/review/approved/deprecated）外です"; return 0 ;; esac
  case " $flags " in *" cfmt=1 "*) ;; *) echo "NG:created が YYYY-MM-DD 形式ではありません"; return 0 ;; esac
  case " $flags " in *" ufmt=1 "*) ;; *) echo "NG:updated が YYYY-MM-DD 形式ではありません"; return 0 ;; esac
  # 前後関係。ISO 8601 の日付は辞書順比較がそのまま日付順になる
  local cval uval
  cval="$(awk -v fm_end="$close_line" 'NR >= 2 && NR < fm_end && /^created: "/ { gsub(/^created: "|"$/, ""); print; exit }' "$f")"
  uval="$(awk -v fm_end="$close_line" 'NR >= 2 && NR < fm_end && /^updated: "/ { gsub(/^updated: "|"$/, ""); print; exit }' "$f")"
  if [[ -n "$cval" && -n "$uval" && "$uval" < "$cval" ]]; then
    echo "NG:updated（${uval}）が created（${cval}）より前です"
    return 0
  fi
  case " $flags " in
    *" ci=1 "*)
      case " $flags " in *" cidom=1 "*) ;; *) echo "NG:changeImpact が小文字の low/medium/high ではありません"; return 0 ;; esac
      ;;
  esac
  [ "$has_changelog" -eq 1 ] || { echo "NG:## Changelog セクションがありません（フェンス / コメント内の例示は数えません）"; return 0; }
  echo "OK"
}

# 閉じたコードフェンス / 閉じた HTML コメントの中身を取り除いて stdout へ。
#
# 見出しや数値の「例示」を実体と取り違えないための前処理（例: フェンス内に書いた
# `## Changelog` を本物の節と誤認すると、以降の本文が走査から落ちる）。
#
# 3 つの narrowing（同梱 MCP の maskClosedSpans と同一の規則。Issue #517 / #519）:
#   1. 単一パスで左から処理する — 先に開いたマーカーが勝ち、その区間内のマーカーは
#      検査しない（コメント内の ``` が外側のフェンスと対にならない）
#   2. 閉じていない opener はその行だけ飛ばす — 走査を打ち切ると、後続の閉じた span が
#      素通りして例示を実在記述と数えてしまう。**飛ばすのは対応探索だけで、その行の
#      文字は本文に残る**（`<!-- N suite` の件数記載は走査対象になる。この pin は
#      docs-fact-drift-selftest G17）。CommonMark の
#      「閉じ忘れコメントは文書末尾まで」とは意図的に異なる規則で、同梱 MCP の
#      maskCommentAt が未閉鎖時に i+1 を返すのと同じ振る舞いに揃えている
#   3. コメントは**コメントされた文字だけ**を消す — `N suite <!-- 注 -->` の記載自体が
#      走査対象から消えると、ドリフト検査が誤って成功する
#
# 既知の制限（いずれも同梱 MCP の maskClosedSpans / maskCommentAt と同一挙動。片側だけ
# 直すと乖離するため両実装まとめて Issue #527 で扱う）:
#   - コメント開始の探索が**インラインコードスパンを区別しない** — 散文中の
#     `` `<!--` `` が後続の `-->`（mermaid の矢印を含む）と対になり、間の本文が落ちる。
#     現挙動は docs-fact-drift-selftest G18 で固定している
#   - フェンスの**インデント上限を見ていない** — CommonMark はフェンスの字下げを 3 桁まで
#     とし、4 桁以上はインデントコードブロックだが、`^[ \t]*` は無制限に許す。現在の
#     docs に 4 桁以上のフェンス行は無い（実測）ため実害は出ていない
ff_docs_mask_spans() {
  awk '
    # --- フェンス判定 ---------------------------------------------------------
    # 開始マーカーを見つけたら FC（記号）と FL（長さ）へ入れ、開始桁を返す。
    function fence_open(s,   m) {
      if (match(s, /^[ \t]*(```+|~~~+)/) == 0) return 0
      m = substr(s, RSTART, RLENGTH); sub(/^[ \t]*/, "", m)
      FC = substr(m, 1, 1); FL = length(m)
      return index(s, FC)
    }
    # 閉じマーカーか。CommonMark に合わせ「同記号・同長以上・後続は空白のみ」を要求
    # する（```markdown の中の ```ts は content なので閉じない）。
    function fence_closes(s, c, l,   t) {
      if (s !~ /^[ \t]*(```+|~~~+)[ \t]*$/) return 0
      t = s; sub(/^[ \t]*/, "", t); sub(/[ \t]*$/, "", t)
      return (substr(t, 1, 1) == c && length(t) >= l)
    }
    # --- コメント除去 ---------------------------------------------------------
    # line[i] の桁 at から始まるコメントを 1 つ消し、次に検査すべき行番号を返す。
    # 同一行で閉じた場合は同じ行を返す（2 つ目のコメントやフェンスを見落とさない）。
    # コメント部分だけを消すので `68 suite <!-- 注 -->` の本文は残る。
    # 変数名に close を使わない: BSD awk は組み込み関数 close() と衝突して
    # syntax error になる（GNU awk では通るため macOS だけ壊れる形）
    function mask_comment(i, at,   rel, abs_end, j, close_at, tail) {
      rel = index(substr(line[i], at), "-->")
      if (rel > 0) {
        abs_end = at + rel - 1
        line[i] = substr(line[i], 1, at - 1) substr(line[i], abs_end + 3)
        return i
      }
      close_at = 0
      for (j = i + 1; j <= n; j++) if (index(line[j], "-->") > 0) { close_at = j; break }
      if (close_at == 0) return i + 1     # 未閉鎖: この行だけ飛ばして走査を続ける
      tail = substr(line[close_at], index(line[close_at], "-->") + 3)
      line[i] = substr(line[i], 1, at - 1)
      for (j = i + 1; j < close_at; j++) line[j] = ""
      line[close_at] = tail
      return close_at                     # 残った後半をもう一度検査する
    }
    { line[NR] = $0 }
    END {
      n = NR
      i = 1
      # 単一パスで左から処理する。これが 2 種の入れ子を正しく扱う要点で、
      # 先に開いたマーカーが勝ち、その区間内のマーカーは一切検査されない
      # （コメント内の ``` が外側のフェンスと対にならない）。
      # 未閉鎖の opener はその行だけ飛ばす（走査全体を打ち切ると、後続の
      # 閉じた span が素通りして例示を実在記述と数えてしまう）。
      # 同型の判断は同梱 MCP の maskClosedSpans と共通（Issue #517 / #519）。
      while (i <= n) {
        fpos = fence_open(line[i])
        fc = FC; fl = FL
        cpos = index(line[i], "<!--")
        if (fpos > 0 && (cpos == 0 || fpos < cpos)) {
          close_at = 0
          for (j = i + 1; j <= n; j++) if (fence_closes(line[j], fc, fl)) { close_at = j; break }
          if (close_at == 0) { i++; continue }
          for (k = i; k <= close_at; k++) line[k] = ""
          i = close_at + 1
        } else if (cpos > 0) {
          i = mask_comment(i, cpos)
        } else i++
      }
      for (i = 1; i <= n; i++) print line[i]
    }
  ' "$1"
}

# 走査用の本文を stdout へ。Frontmatter とフェンス / コメント内、および
# `## Changelog` 節（以降 EOF まで）を除く。
#
# Changelog を除くのは、そこに書かれた数値・記述が**その時点の事実の記録**であり、
# 現在の実体と一致する必要がないため（歴史記述を drift として赤にしない）。
ff_docs_body() {
  # 下流の awk で `exit` しない: パイプの上流（ff_docs_mask_spans）が SIGPIPE で死に、
  # `set -o pipefail` + `set -e` の呼び出し側を無言で殺す（run-all case 10 と同型の罠。
  # 実測: read-only 環境の検証中に「== C == の直後で出力が止まる」形で踏んだ）
  ff_docs_mask_spans "$1" | awk '
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/   { in_fm = 0; next }
    in_fm              { next }
    /^## Changelog$/   { after_changelog = 1 }
    !after_changelog   { print }
  '
}
