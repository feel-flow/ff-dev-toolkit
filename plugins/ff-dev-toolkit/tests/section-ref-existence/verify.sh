#!/usr/bin/env bash
#
# 文書が「ファイルパス + 節名」の形で指す節が、そのファイルに実在するかの静的検査
# （Issue `#1826` / OBS-081 の昇格）。
#
# スキルの規定を別ファイルへ移したり節の見出しを変えたりすると、他の文書に残った
# 「パス付きの節参照」が古いファイルを指したまま残る。消費側の掃引は人手の grep に頼って
# おり、OBS-081 で 3 回再発した（PR `#1187` / `#1455` / `#1825`）。本 suite はその参照を
# 機械で解決し、節の移動・改名と同じ PR のうちに赤で気付けるようにする。要約された
# 規則の本文が食い違う類型（`#1187` / `#1455`）や、方針変更後の文言の取り残しは捕まえない
# （前者は TESTING.md「意図的複製の census」の複製削減で扱う）。
#
# 検査する参照の形（コードフェンスの外だけ。フェンスの判定は tests/lib/section-scope.sh の
# section_scope_fence_free_lines を通す — 状態機械をここで書き直さない）:
#   (1) バッククォート 1 個で囲んだパスの直後に「」が続く形。「」が続けて並ぶ連鎖は 1 つずつ
#       照合する（例: パスの直後に「節A」「節B」）
#   (2) Markdown リンク `[text](path)` の直後に「」が続く形（連鎖の扱いは (1) と同じ）
#   (3) (1) / (2) のパスの後に「の」（前後の空白 1 個まで）を挟み、「」の後に「節」が続く形
#   パスは `.md` で終わるもの（`#fragment` は落とす）だけを拾う。空白・`<` `>` `*` `?` を
#   含むトークン、`${…}` が先頭のプラグインルート変数以外に現れるトークンはプレースホルダ
#   として拾わない。2 個以上のバッククォートで囲んだコードスパンは記法の例示として丸ごと
#   読み飛ばす。閉じの無いバッククォート列は文字どおりの記号として読み進める（CommonMark）。
#
# パスの解決（最初に実在したファイルを採る。どれにも無ければ「解決できない」で赤）:
#   - `${FF_DEV_TOOLKIT_ROOT}/` 始まり: 参照元に依らず plugins/ff-dev-toolkit/ を起点にする
#   - `${CLAUDE_PLUGIN_ROOT}/` 始まり: 参照元が plugins/<名>/ の下ならそのプラグインルート、
#     それ以外は plugins/ff-dev-toolkit/ を起点にする
#   - それ以外: 参照元のディレクトリ → 参照元を含むスキルディレクトリ（plugins/<名>/skills/<s>/）
#     → 参照元を含むプラグインルート → リポジトリルート の順
#   - ファイル自身の symlink も辿って物理解決（pwd -P）し、リポジトリの外に出る候補は採らない
#
# 見出しの照合: 解決先のフェンス外にある見出し行（行頭 `#` + 空白）の本文に、節名が部分文字列
# として含まれていれば一致。比較の前に両側からバッククォートと `**` を除く（番号付き見出し
# 「### 3. 承認と起票」や接尾辞付き「## 原則4: …」を節名「承認と起票」「原則4」で指す書き方を
# 通すため）。部分一致なので、別の見出しが同じ語を含むと見逃す方向に倒れる。正規化で空になる
# 節名（「**」など）は全見出しに一致してしまうので判定不能（赤）にする。
#
# 走査対象: リポジトリで追跡している *.md のうち、次の対象外を除いたもの。対象外は
# 「記録した時点の参照を保存するのが正しい文書」と「架空のプロジェクトを指すテスト入力」で、
# 各パターンが追跡ファイルに 1 件も当たらなければ赤にする（名前だけ残った除外の検出）:
#   - CHANGELOG.md（版ごとの変更記録）・docs/08-knowledge/（ACE Playbook・観測台帳）・
#     docs/06-reference/DECISIONS.md（ADR）・docs/superpowers/ と .claude/plans/（過去の計画）
#   - */fixtures/*（テスト入力・期待出力。導入先プロジェクトの架空の文書を指す）
#   各文書の「## Changelog」「## 変更履歴」節（見出しの本文がちょうどその語のもの。同じ深さ
#   以浅の次の見出しまで）も同じ理由で対象外にする。
#
# リポジトリの外の文書（ベンダー文書など）を指す参照は EXTERNAL_REFS の名簿へ理由付きで
# 載せる。名簿のパスが 1 度も参照されなければ赤（名簿だけの取り残し）。
#
# fail-closed:
#   - 抽出・解決・照合の検出力は、一時領域に組み立てた fixture の木で毎回実測し、期待と
#     一致しなければ赤にする（一時領域が作れなければ skip せず赤）
#   - 参照元または解決先のコードフェンスが閉じていない・読めない・抽出の awk が失敗した回は
#     「判定不能」として赤（「参照なし」と読まない）
#   - 横断で拾った参照が 0 件、または一致した参照が 0 件なら「参照ゼロ」ではなく
#     「走査が成立していない」として赤
#
# 既知の限界（倒れる方向を明記する）:
#   - 「§節名」形、「」の後に「節」の無い「の「…」」形は拾わない（見逃し方向。後者は本文の
#     引用が大半で、節参照と区別できない — 2026-09-27 の実測で「の「…」」形の不一致 15 件は
#     ほぼ引用だった）
#   - バッククォートにもリンクにも入っていない素のパスは拾わない（見逃し方向）
#   - 見出しの部分一致（上記）
#
# 空振り検出: 走査対象の一覧を空にした fixture（参照 0 件）を与えると (F10) が赤になり、除外パターンを追跡ファイルに当たらない名前へ変えた fixture を与えると (F11) が赤になる（2026-09-27 実測。対象が無い・除外が空振りした状態を「参照ゼロの緑」へ倒さない）。
# 変異検出: 実リポジトリで retrospective の references/filing.md の見出し「承認と起票」を「承認と提出」へ改名すると (L1) が参照元 3 箇所（workflow-principles.md:27 / auto-trigger.md / ledger.md）を ファイル:行 と節名付きで名指しして赤になる（2026-09-27 実測）。
# 変異検出: 同じ見出しを filing.md から同じ references/ の promotion.md へ移すと (L1) が同じ 3 箇所を名指しして赤になる（2026-09-27 実測。PR `#1825` の取りこぼしの再現）。
# 変異検出: workflow-principles.md の参照パス filing.md を filling.md と誤記すると (L1) が「解決できない」で赤になる（2026-09-27 実測）。
# 変異検出: lib の公開関数を別名へ改名すると、fixture と (L1) の 24 件中 19 件が判定不能で赤になる（2026-09-27 実測）。
# 変異検出: 抽出器・解決器の単一行変異 15 種（閉じの無いバッククォートで行を打ち切る・Changelog 見出しの前方一致・変更履歴の欠落・小見出しで Changelog 除外を解く・2 連以上のスパンを参照に数える・** の正規化の欠落・「の「」節」の空白の変種の欠落・symlink を辿らない・空の節名を一致扱い・FF_DEV_TOOLKIT_ROOT を参照元のプラグインへ解決・プラグインルート / リポジトリルートの候補の欠落・解決先の判定不能を一致扱い・一致 0 件の分岐の欠落）は、それぞれ (F5) (F7) (F13)〜(F16) (F18) のいずれかが赤になる（2026-09-27 実測。レビューの変異注入で生存していた 15 種を fixture で殺した）。
#
# 一時領域が作れない・lib が無い回は skip せず赤で止める（検査が丸ごと消える経路を残さない）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
SECTION_SCOPE_LIB="$PLUGIN_ROOT/tests/lib/section-scope.sh"

if [ ! -s "$SECTION_SCOPE_LIB" ]; then
  echo "✗ section-ref-existence: lib が存在しないか空です: $SECTION_SCOPE_LIB" >&2
  exit 1
fi
# source 行は lib のパスを字面で書く（docs-gates が「lib/section-scope.sh を source する suite」を
# この行の字面で数え、TESTING.md の consumer 一覧と突き合わせる）。
# shellcheck source=../lib/section-scope.sh
. "$PLUGIN_ROOT/tests/lib/section-scope.sh"

# 記録した時点の参照を保存するのが正しい文書と、架空のプロジェクトを指すテスト入力。
# 書式: glob|理由。glob は case パターンとしてリポジトリ相対パスへ当てる。
HISTORY_EXCLUDES=(
  "*/CHANGELOG.md|版ごとの変更記録（当時の節名を指すのが正しい）"
  "docs/08-knowledge/*|ACE Playbook・観測台帳（記録時点の参照を保存する）"
  "docs/06-reference/DECISIONS.md|ADR（決定時点の参照を保存する）"
  "docs/superpowers/*|過去の実装計画"
  ".claude/plans/*|過去の計画"
  "*/fixtures/*|テスト入力・期待出力（導入先プロジェクトの架空の文書を指す）"
)

# リポジトリの外の文書を指す参照。書式: 参照に書かれたパス|理由。
EXTERNAL_REFS=(
  "18-sandbox.md|grok CLI のベンダー文書（docs-template/05-operations/deployment/grok-cli-reviewer.md が引用する）"
)

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/section-ref-existence.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  WORK="$(cd "$_ff_mktemp_out" && pwd -P)"
else
  echo "✗ section-ref-existence: 一時ディレクトリを作成できません（検査は 1 件も実行されていません）: $_ff_mktemp_out" >&2
  exit 1
fi

# trap の最終コマンドの終了ステータスが suite の rc を上書きし、途中死が pass に
# 化けるのを防ぐ末尾到達センチネル。
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$WORK"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# フェンス外の行（「行番号<TAB>行」）から参照を「行番号<TAB>パス<TAB>節名」で出す。
# 文書内の Changelog 節（見出しの本文が「Changelog」「変更履歴」ちょうどのもの。「Changelog カテゴリ」の
# ような規範の節は含めない）は読み飛ばす。マルチバイトの区切りは index / substr / length だけで
# 扱い（文字クラスへ入れない）、LC_ALL=C でバイト単位に固定する。前方一致は `==` ではなく
# index で判定する — 文字列の `==` はロケールの照合順序で比べる実装があり、macOS の awk は
# UTF-8 ロケールで「。」と「「」を等しいと判定した（2026-09-27 実測。句点の直後を節参照と誤認）。
extract_refs() {
  LC_ALL=C awk '
    function starts(s, p) { return index(s, p) == 1 }
    BEGIN { OB = "「"; CB = "」"; NO = "の"; SEC = "節" }
    function try_ref(tok, rest,   sec_required, cnt, k, name, q) {
      if (tok ~ /^\$\{(FF_DEV_TOOLKIT_ROOT|CLAUDE_PLUGIN_ROOT)\}\//) {
        if (substr(tok, index(tok, "}") + 1) ~ /[{}$]/) return
      } else if (tok ~ /[{}$]/) return
      if (tok ~ /[[:space:]<>*?]/) return
      sub(/#.*$/, "", tok)
      if (tok !~ /\.md$/) return
      sec_required = 0
      if (starts(rest, OB)) {
      } else if (starts(rest, NO OB)) {
        rest = substr(rest, length(NO) + 1); sec_required = 1
      } else if (starts(rest, " " NO OB)) {
        rest = substr(rest, length(" " NO) + 1); sec_required = 1
      } else if (starts(rest, NO " " OB)) {
        rest = substr(rest, length(NO " ") + 1); sec_required = 1
      } else if (starts(rest, " " NO " " OB)) {
        rest = substr(rest, length(" " NO " ") + 1); sec_required = 1
      } else return
      cnt = 0
      while (starts(rest, OB)) {
        k = index(rest, CB)
        if (k == 0) break
        name = substr(rest, length(OB) + 1, k - length(OB) - 1)
        if (index(name, OB) > 0 || name == "") break
        cnt++
        names[cnt] = name
        rest = substr(rest, k + length(CB))
      }
      if (cnt == 0) return
      if (sec_required && !starts(rest, SEC)) return
      for (q = 1; q <= cnt; q++) print ln "\t" tok "\t" names[q]
    }
    {
      tab = index($0, "\t")
      ln = substr($0, 1, tab - 1)
      line = substr($0, tab + 1)
      if (line ~ /^#+ /) {
        match(line, /^#+/)
        lv = RLENGTH
        if (chg > 0 && lv <= chg) chg = 0
        h = line
        sub(/^#+ +/, "", h)
        sub(/[[:space:]]+$/, "", h)
        if (h == "Changelog" || h == "変更履歴") chg = lv
      }
      if (chg > 0) next
      n = length(line)
      i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "`") {
          run = 0
          while (substr(line, i + run, 1) == "`") run++
          j = i + run
          found = 0
          while (j <= n) {
            if (substr(line, j, 1) == "`") {
              r2 = 0
              while (substr(line, j + r2, 1) == "`") r2++
              if (r2 == run) { found = 1; break }
              j += r2
            } else j++
          }
          # 閉じの無いバッククォート列は文字どおりの記号（CommonMark）。行の残りの参照を捨てない。
          if (!found) { i += run; continue }
          if (run == 1) try_ref(substr(line, i + 1, j - i - 1), substr(line, j + run))
          i = j + run
          continue
        }
        if (c == "]" && substr(line, i + 1, 1) == "(") {
          k = index(substr(line, i + 2), ")")
          if (k > 0) {
            try_ref(substr(line, i + 2, k - 1), substr(line, i + 2 + k))
            i = i + 2 + k
            continue
          }
        }
        i++
      }
    }
  '
}

# $1=ルート $2=参照元（ルート相対） $3=参照に書かれたパス。解決先をルート相対で出して 0、
# 解決できなければ 1。
resolve_ref() {
  local root="$1" src="$2" tok="$3" plugin_root="" skill_dir="" cand dir abs f t hops
  case "$src" in
    plugins/*/*)
      plugin_root="${src#plugins/}"
      plugin_root="plugins/${plugin_root%%/*}"
      case "$src" in
        "$plugin_root"/skills/*/*)
          skill_dir="${src#"$plugin_root"/skills/}"
          skill_dir="$plugin_root/skills/${skill_dir%%/*}"
          ;;
      esac
      ;;
  esac
  local candidates=()
  # shellcheck disable=SC2016 # パターンはプラグインルート変数の名前そのものを字面で照合する
  case "$tok" in
    '${FF_DEV_TOOLKIT_ROOT}/'*)
      candidates+=("plugins/ff-dev-toolkit/${tok#*\}/}")
      ;;
    '${CLAUDE_PLUGIN_ROOT}/'*)
      candidates+=("${plugin_root:-plugins/ff-dev-toolkit}/${tok#*\}/}")
      ;;
    *)
      dir="$(dirname "$src")"
      candidates+=("$dir/$tok")
      [ -n "$skill_dir" ] && candidates+=("$skill_dir/$tok")
      [ -n "$plugin_root" ] && candidates+=("$plugin_root/$tok")
      candidates+=("$tok")
      ;;
  esac
  for cand in "${candidates[@]}"; do
    f="$root/$cand"
    [ -f "$f" ] || continue
    # ファイル自身の symlink も辿ってから境界を見る（親ディレクトリだけを物理解決すると、
    # ルート内に置いた外部ファイルへの symlink を受理してしまう）。
    hops=0
    while [ -L "$f" ]; do
      t="$(readlink "$f")" || continue 2
      case "$t" in
        /*) f="$t" ;;
        *) f="$(dirname "$f")/$t" ;;
      esac
      hops=$((hops + 1))
      [ "$hops" -le 20 ] || continue 2
    done
    abs="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || continue
    case "$abs/" in
      "$root"/*) ;;
      *) continue ;;
    esac
    if [ "$abs" = "$root" ]; then
      basename "$f"
    else
      printf '%s\n' "${abs#"$root"/}/$(basename "$f")"
    fi
    return 0
  done
  return 1
}

# $1=解決先の絶対パス $2=節名。見出しに節名が含まれれば 0、無ければ 1、判定不能なら 2
# （理由を stdout へ出す）。節名は入力の 1 行目で渡す（awk -v はバックスラッシュを解釈し、
# 環境変数は公開面の FF_* 名簿へ載る実体になるため使わない）。正規化で空になる節名
# （「**」など）は index(s, "") が常に真になり全見出しに一致してしまうので判定不能にする。
heading_exists() {
  local lines
  if ! lines="$(section_scope_fence_free_lines "$1")"; then
    printf '%s\n' "$lines"
    return 2
  fi
  { printf '%s\n' "$2"; printf '%s\n' "$lines"; } | LC_ALL=C awk '
    function norm(s) { gsub(/`/, "", s); gsub(/\*\*/, "", s); return s }
    NR == 1 {
      want = norm($0)
      if (want == "") { print "節名が空です（バッククォートと ** を除くと何も残らない）"; empty = 1; exit 2 }
      next
    }
    {
      l = substr($0, index($0, "\t") + 1)
      if (l ~ /^#+ /) {
        sub(/^#+ +/, "", l)
        if (index(norm(l), want) > 0) found = 1
      }
    }
    END { if (empty) exit 2; exit found ? 0 : 1 }
  '
}

is_excluded() { # $1=ルート相対パス。HISTORY_EXCLUDES に当たれば 0
  local entry pat
  for entry in ${HISTORY_EXCLUDES[@]+"${HISTORY_EXCLUDES[@]}"}; do
    pat="${entry%%|*}"
    # shellcheck disable=SC2254 # pat は意図した glob
    case "$1" in $pat) return 0 ;; esac
  done
  return 1
}

external_reason() { # $1=参照に書かれたパス。名簿に在れば理由を出して 0
  local entry
  for entry in ${EXTERNAL_REFS[@]+"${EXTERNAL_REFS[@]}"}; do
    if [ "${entry%%|*}" = "$1" ]; then
      printf '%s\n' "${entry#*|}"
      return 0
    fi
  done
  return 1
}

# $1=ルート（物理パス） $2=ルート相対の *.md 一覧ファイル。
# 結果を stdout へ 1 行ずつ出し、赤があれば 1 を返す。最終行は「SUMMARY 参照数 一致数 外部数」。
scan_tree() {
  local root="$1" list="$2" rel refs lines ln tok name target rc reason
  local total=0 matched=0 external=0 red=0 entry pat hit
  local used_external=" "
  # 名簿が空になっても bash 3.2 の set -u で落ちない展開にする（名簿を消し切った状態を
  # 無診断の abort にしない）。
  for entry in ${HISTORY_EXCLUDES[@]+"${HISTORY_EXCLUDES[@]}"}; do
    pat="${entry%%|*}"
    hit=0
    while IFS= read -r rel; do
      # shellcheck disable=SC2254 # pat は意図した glob
      case "$rel" in $pat) hit=1; break ;; esac
    done <"$list"
    if [ "$hit" -eq 0 ]; then
      echo "EXCLUDE_UNUSED 除外パターン '$pat' が追跡ファイルに 1 件も当たりません（名前だけ残った除外。消すか直す）"
      red=1
    fi
  done
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    is_excluded "$rel" && continue
    if ! lines="$(section_scope_fence_free_lines "$root/$rel")"; then
      echo "UNCHECKABLE ${rel}: $lines"
      red=1
      continue
    fi
    [ -n "$lines" ] || continue
    # 抽出の失敗を「参照なし」と読まない（scan_tree は $(...) の中で呼ばれ errexit が効かない）。
    if ! refs="$(printf '%s\n' "$lines" | extract_refs)"; then
      echo "UNCHECKABLE ${rel}: 参照の抽出に失敗しました"
      red=1
      continue
    fi
    [ -n "$refs" ] || continue
    while IFS="$(printf '\t')" read -r ln tok name; do
      total=$((total + 1))
      if reason="$(external_reason "$tok")"; then
        external=$((external + 1))
        used_external="$used_external${tok} "
        continue
      fi
      if ! target="$(resolve_ref "$root" "$rel" "$tok")"; then
        echo "UNRESOLVED ${rel}:${ln} \`$tok\`「${name}」: パスがリポジトリ内のファイルに解決できません（パスを直すか、リポジトリ外の文書なら EXTERNAL_REFS へ理由付きで載せる）"
        red=1
        continue
      fi
      rc=0
      reason="$(heading_exists "$root/$target" "$name")" || rc=$?
      case "$rc" in
        0) matched=$((matched + 1)) ;;
        1)
          echo "MISSING ${rel}:${ln} \`$tok\`「${name}」: 見出しが ${target} にありません（節を移した・改名したなら参照側を直す）"
          red=1
          ;;
        *)
          echo "UNCHECKABLE ${rel}:${ln} \`$tok\`「${name}」: $reason"
          red=1
          ;;
      esac
    done <<EOF
$refs
EOF
  done <"$list"
  for entry in ${EXTERNAL_REFS[@]+"${EXTERNAL_REFS[@]}"}; do
    case "$used_external" in
      *" ${entry%%|*} "*) ;;
      *)
        echo "EXTERNAL_UNUSED 外部参照の名簿 '${entry%%|*}' を指す参照がありません（名簿だけの取り残し。消す）"
        red=1
        ;;
    esac
  done
  if [ "$total" -eq 0 ]; then
    echo "EMPTY 参照を 1 件も拾えません（参照ゼロではなく走査の不成立を疑う。走査対象か抽出規則が腐っている）"
    red=1
  elif [ "$matched" -eq 0 ]; then
    echo "EMPTY 一致した参照が 0 件です（解決か照合の規則が腐っている）"
    red=1
  fi
  echo "SUMMARY $total $matched $external"
  return "$red"
}

# ---- fixture: 抽出・解決・照合の検出力を一時領域の木で実測する ----

FX_OUT=""
FX_RC=0
# $1=ケース名。$WORK/<ケース名>/ 配下の *.md を一覧にして走査する。
run_fixture() {
  local root="$WORK/$1"
  (cd "$root" && find . -name '*.md' -type f | sed 's|^\./||' | LC_ALL=C sort) >"$WORK/$1.list"
  set +e
  FX_OUT="$(scan_tree "$root" "$WORK/$1.list")"
  FX_RC=$?
  set -e
}

# $1=ラベル $2=期待 rc $3=出力に含まれるべき断片（空なら不問） $4=含まれてはいけない断片（任意）
expect_fixture() {
  if [ "$FX_RC" -ne "$2" ]; then
    bad "${1}（rc=${FX_RC} / 期待 ${2}）"
    printf '%s\n' "$FX_OUT" | sed 's/^/    | /' >&2
    return
  fi
  if [ -n "$3" ] && [[ "$FX_OUT" != *"$3"* ]]; then
    bad "${1}（出力に '$3' がありません）"
    printf '%s\n' "$FX_OUT" | sed 's/^/    | /' >&2
    return
  fi
  if [ -n "${4:-}" ] && [[ "$FX_OUT" == *"$4"* ]]; then
    bad "${1}（出力に '$4' が出ています）"
    printf '%s\n' "$FX_OUT" | sed 's/^/    | /' >&2
    return
  fi
  ok "$1"
}

# 各ケースの木へ、全除外パターンに当たる空ファイルを置く（除外の空振り検出を個別ケースで
# 踏まないため。F11 だけがこれを崩す）。
seed_excludes() {
  local root="$WORK/$1"
  mkdir -p "$root/plugins/x" "$root/docs/08-knowledge" "$root/docs/06-reference" \
    "$root/docs/superpowers" "$root/.claude/plans" "$root/plugins/x/tests/fixtures"
  : >"$root/plugins/x/CHANGELOG.md"
  : >"$root/docs/08-knowledge/OBSERVATIONS.md"
  : >"$root/docs/06-reference/DECISIONS.md"
  : >"$root/docs/superpowers/plan.md"
  : >"$root/.claude/plans/plan.md"
  : >"$root/plugins/x/tests/fixtures/input.md"
  printf '## 外部\n\n`18-sandbox.md`「vendor」\n' >"$root/external.md"
}

new_case() { # $1=ケース名
  mkdir -p "$WORK/$1"
  seed_excludes "$1"
}

echo "== fixture（抽出・解決・照合の検出力） =="

# F1: 見出しが実在する参照（直後の「」・連鎖・の「」節・リンク）は緑。
new_case f1
mkdir -p "$WORK/f1/plugins/demo/skills/s/references"
printf '# S\n\n## 承認と起票\n\n### 3. 手順 `B`\n\n## 原則4: 例\n' >"$WORK/f1/plugins/demo/skills/s/SKILL.md"
printf '# Doc\n\n' >"$WORK/f1/doc.md"
{
  printf '正本は `plugins/demo/skills/s/SKILL.md`「承認と起票」「手順 B」。\n'
  printf '番号は `plugins/demo/skills/s/SKILL.md` の「原則4」節。\n'
  printf 'リンクは [x](plugins/demo/skills/s/SKILL.md#a)「承認と起票」。\n'
} >>"$WORK/f1/doc.md"
run_fixture f1
expect_fixture "F1: 実在する見出しを指す参照（連鎖・の「」節・リンク・番号付き見出し）は緑" 0 "SUMMARY 5 4 1"

# F2: 見出しを別ファイルへ移した参照は、参照元の ファイル:行 と節名を名指しして赤。
new_case f2
mkdir -p "$WORK/f2/plugins/demo/skills/s/references"
printf '# S\n\n## 概要\n' >"$WORK/f2/plugins/demo/skills/s/SKILL.md"
printf '# F\n\n## 承認と起票\n' >"$WORK/f2/plugins/demo/skills/s/references/filing.md"
printf '# Doc\n\n正本は `skills/s/SKILL.md`「承認と起票」。\n' >"$WORK/f2/plugins/demo/docs.md"
run_fixture f2
expect_fixture "F2: 別ファイルへ移した見出しを指す参照は ファイル:行 と節名を名指しして赤" 1 \
  "MISSING plugins/demo/docs.md:3 \`skills/s/SKILL.md\`「承認と起票」"

# F3: 解決できないパスは黙って緑にせず列挙して赤。
new_case f3
printf '# Doc\n\n`docs/nowhere.md`「節」\n' >"$WORK/f3/doc.md"
run_fixture f3
expect_fixture "F3: 解決できないパスは列挙して赤" 1 "UNRESOLVED doc.md:3 \`docs/nowhere.md\`「節」"

# F4: コードフェンスの中・2 連バッククォートの例示・プレースホルダ・節の無い「の「」」は拾わない。
new_case f4
{
  printf '# Doc\n\n```text\n`docs/nowhere.md`「節」\n```\n\n'
  printf '例示は `` `docs/nowhere.md`「節」 `` と書く。\n'
  printf '`skills/<名>/SKILL.md`「<節名>」\n'
  printf '`docs/nowhere.md` の「引用文」を参照。\n'
  printf '`t.md`「A」\n'
} >"$WORK/f4/doc.md"
printf '# T\n\n## A\n' >"$WORK/f4/t.md"
run_fixture f4
expect_fixture "F4: フェンス内・2 連バッククォート・プレースホルダ・節の無い引用は拾わない" 0 "SUMMARY 2 1 1" "nowhere"

# F12: 句点などマルチバイト文字の直後を「」と取り違えない（ロケールの照合順序で比べる awk の
# `==` は「。」と「「」を等しいと判定した。2026-09-27 実測）。
new_case f12
printf '# T\n\n## A\n' >"$WORK/f12/t.md"
printf '# Doc\n\n（`nowhere.md`。`b` は対策あり」を書く）と `t.md`「A」\n' >"$WORK/f12/doc.md"
run_fixture f12
expect_fixture "F12: 句点の直後を節参照と誤認しない" 0 "SUMMARY 2 1 1" "nowhere"

# F5: スキル相対・文書相対・プラグインルート変数の解決。
new_case f5
mkdir -p "$WORK/f5/plugins/demo/skills/s/references" "$WORK/f5/plugins/demo/docs-template/sub"
printf '# R\n\n## 振り分け\n' >"$WORK/f5/plugins/demo/skills/s/references/r.md"
printf '# T\n\n## テンプレ節\n' >"$WORK/f5/plugins/demo/docs-template/t.md"
printf '# S\n\n`references/r.md`「振り分け」\n' >"$WORK/f5/plugins/demo/skills/s/SKILL.md"
printf '# R2\n\n`references/r.md`「振り分け」\n' >"$WORK/f5/plugins/demo/skills/s/references/r2.md"
printf '# U\n\n`../t.md`「テンプレ節」と `${CLAUDE_PLUGIN_ROOT}/docs-template/t.md`「テンプレ節」\n' >"$WORK/f5/plugins/demo/docs-template/sub/u.md"
# FF_DEV_TOOLKIT_ROOT は参照元のプラグインに依らず ff-dev-toolkit を指す。見出しを変えて区別する。
printf '# V\n\n`${FF_DEV_TOOLKIT_ROOT}/docs-template/t.md`「本体節」\n' >"$WORK/f5/v.md"
printf '# W\n\n`${FF_DEV_TOOLKIT_ROOT}/docs-template/t.md`「本体節」\n' >"$WORK/f5/plugins/demo/w.md"
mkdir -p "$WORK/f5/plugins/ff-dev-toolkit/docs-template"
printf '# T\n\n## 本体節\n' >"$WORK/f5/plugins/ff-dev-toolkit/docs-template/t.md"
run_fixture f5
expect_fixture "F5: スキル相対・文書相対・プラグインルート変数（CLAUDE_PLUGIN_ROOT は参照元のプラグイン、FF_DEV_TOOLKIT_ROOT は ff-dev-toolkit）を解決する" 0 "SUMMARY 7 6 1"

# F6: 連鎖の 2 つ目だけが無い場合も赤（先頭 1 件で打ち切らない）。
new_case f6
printf '# T\n\n## A\n' >"$WORK/f6/t.md"
printf '# Doc\n\n`t.md`「A」「B」\n' >"$WORK/f6/doc.md"
run_fixture f6
expect_fixture "F6: 連鎖の 2 つ目の節が無ければ赤" 1 "MISSING doc.md:3 \`t.md\`「B」"

# F7: 解決先のコードフェンス内の見出しは数えない。解決先のフェンスが閉じていなければ判定不能で赤。
new_case f7
printf '# T\n\n```md\n## 例示の見出し\n```\n' >"$WORK/f7/t.md"
printf '# U\n\n```bash\n## 未閉じ\n' >"$WORK/f7/u.md"
printf '# Doc\n\n`t.md`「例示の見出し」\n`u.md`「未閉じ」\n' >"$WORK/f7/doc.md"
run_fixture f7
expect_fixture "F7: 解決先のフェンス内の見出しは数えない" 1 "MISSING doc.md:3"
expect_fixture "F7: 解決先の未閉じフェンスは判定不能で赤" 1 "UNCHECKABLE doc.md:4"
expect_fixture "F7: 参照元の未閉じフェンスは判定不能で赤" 1 "UNCHECKABLE u.md:"

# F8: 除外する文書と文書内の Changelog 節の参照は見ない。
new_case f8
printf '# T\n\n## 現行\n' >"$WORK/f8/t.md"
printf '# 変更\n\n`../../t.md`「旧節」\n' >"$WORK/f8/plugins/x/CHANGELOG.md"
printf '# Doc\n\n`t.md`「現行」\n\n## Changelog\n\n- `t.md`「旧節」\n\n## 次の節\n\n`t.md`「現行」\n' >"$WORK/f8/doc.md"
run_fixture f8
expect_fixture "F8: 除外文書と Changelog 節の参照は見ない（節の後は再開する）" 0 "SUMMARY 3 2 1"

# F9: リポジトリの外へ出るパスは解決しない。
new_case f9
printf '# Doc\n\n`../outside.md`「節」\n' >"$WORK/f9/doc.md"
printf '# O\n\n## 節\n' >"$WORK/outside.md"
run_fixture f9
expect_fixture "F9: ルートの外へ出るパスは解決しない" 1 "UNRESOLVED doc.md:3"

# F10: 走査対象が空なら参照ゼロの緑にしない（空振り検出）。
new_case f10
: >"$WORK/f10.list"
set +e
FX_OUT="$(scan_tree "$WORK/f10" "$WORK/f10.list")"
FX_RC=$?
set -e
expect_fixture "F10: 走査対象が空なら赤（参照ゼロの緑にしない）" 1 "EMPTY"

# F11: 追跡ファイルに当たらない除外パターン・参照されない外部名簿は赤。
new_case f11
printf '# T\n\n## A\n' >"$WORK/f11/t.md"
printf '# Doc\n\n`t.md`「A」\n' >"$WORK/f11/doc.md"
rm -f "$WORK/f11/docs/superpowers/plan.md" "$WORK/f11/external.md"
run_fixture f11
expect_fixture "F11: 当たらない除外パターンは赤" 1 "EXCLUDE_UNUSED 除外パターン 'docs/superpowers/*'"
expect_fixture "F11: 参照されない外部名簿は赤" 1 "EXTERNAL_UNUSED 外部参照の名簿 '18-sandbox.md'"

# F13: 解決候補の順序（文書相対 → スキル → プラグインルート → リポジトリルート。近い候補が勝つ）。
new_case f13
mkdir -p "$WORK/f13/plugins/demo/skills/s/references" "$WORK/f13/plugins/demo/docs" "$WORK/f13/docs"
printf '# S\n\n## S節\n' >"$WORK/f13/plugins/demo/skills/s/SKILL.md"
printf '# 近\n\n## 近い節\n' >"$WORK/f13/plugins/demo/skills/s/references/x.md"
printf '# 遠\n\n## 遠い節\n' >"$WORK/f13/plugins/demo/skills/s/x.md"
printf '# A\n\n`skills/s/SKILL.md`「S節」\n' >"$WORK/f13/plugins/demo/docs/a.md"
printf '# B\n\n`plugins/demo/skills/s/SKILL.md`「S節」\n' >"$WORK/f13/docs/b.md"
printf '# C\n\n`x.md`「近い節」\n`x.md`「遠い節」\n' >"$WORK/f13/plugins/demo/skills/s/references/c.md"
run_fixture f13
expect_fixture "F13: プラグインルート・リポジトリルートへ戻って解決し、候補が複数あれば近い方を採る" 1 \
  "MISSING plugins/demo/skills/s/references/c.md:4 \`x.md\`「遠い節」"
expect_fixture "F13: 解決の一致数（近い候補の見出しだけが一致する）" 1 "SUMMARY 5 3 1"

# F14: 抽出の変種と壊れた入力（の の前後の空白・** の正規化・2 連バッククォート・閉じの無い
# バッククォート列の後ろ・空の「」・閉じの無い「・${…} の尾・グロブ・Changelog の小節・変更履歴・
# 規範の「Changelog カテゴリ」節）。拾うべき 6 件だけを拾い、壊れた入力は拾わず止まらない。
new_case f14
printf '# T\n\n## A\n\n## **強調**節\n' >"$WORK/f14/t.md"
{
  printf '# Doc\n\n'
  printf '`t.md`の「A」節\n'
  printf '`t.md` の 「A」節\n'
  printf '`t.md`の 「A」節\n'
  printf '`t.md`「強調節」\n'
  printf '``nowhere.md``「Z」\n'
  printf 'Use ``` for fences; see `t.md`「A」\n'
  printf '`nowhere.md`「」\n'
  printf '`nowhere.md`「閉じない\n'
  printf '`${FF_DEV_TOOLKIT_ROOT}/${X}/nowhere.md`「Z」\n'
  printf '`docs/*.md`「Z」と `a?.md`「Z」\n'
  printf '\n## Changelog\n\n### 1.0\n\n`nowhere.md`「旧」\n'
  printf '\n## 変更履歴\n\n`nowhere.md`「旧」\n'
  printf '\n## Changelog カテゴリ\n\n`t.md`「A」\n'
} >"$WORK/f14/doc.md"
run_fixture f14
expect_fixture "F14: 抽出の変種を拾い、壊れた入力・履歴節は拾わない" 0 "SUMMARY 7 6 1" "nowhere"

# F15: 拾えたのが外部参照だけ（一致 0 件）なら赤。
new_case f15
run_fixture f15
expect_fixture "F15: 一致した参照が 0 件なら赤" 1 "EMPTY 一致した参照が 0 件"

# F16: 正規化で空になる節名は全見出しに一致させず判定不能で赤。
new_case f16
printf '# T\n\n## A\n' >"$WORK/f16/t.md"
printf '# Doc\n\n`t.md`「A」\n`t.md`「**」\n' >"$WORK/f16/doc.md"
run_fixture f16
expect_fixture "F16: 正規化で空になる節名は判定不能で赤" 1 "UNCHECKABLE doc.md:4"

# F17: 一覧にあるのに読めない参照元は判定不能で赤（参照なしと読まない）。
new_case f17
printf '# T\n\n## A\n' >"$WORK/f17/t.md"
printf '# Doc\n\n`t.md`「A」\n' >"$WORK/f17/doc.md"
run_fixture f17
printf 'gone.md\n' >>"$WORK/f17.list"
set +e
FX_OUT="$(scan_tree "$WORK/f17" "$WORK/f17.list")"
FX_RC=$?
set -e
expect_fixture "F17: 読めない参照元は判定不能で赤" 1 "UNCHECKABLE gone.md"

# F18: ルート外のファイルを指す symlink は解決しない。ルート内を指す symlink は解決する。
new_case f18
printf '# T\n\n## A\n' >"$WORK/f18/t.md"
printf '# O\n\n## 外\n' >"$WORK/outside18.md"
ln -s "$WORK/outside18.md" "$WORK/f18/link.md"
ln -s t.md "$WORK/f18/inlink.md"
printf '# Doc\n\n`link.md`「外」\n`inlink.md`「A」\n' >"$WORK/f18/doc.md"
run_fixture f18
expect_fixture "F18: ルート外へ出る symlink は解決しない" 1 "UNRESOLVED doc.md:3"
expect_fixture "F18: ルート内の symlink は解決する" 1 "SUMMARY 3 1 1"

# ---- live: リポジトリ全体 ----

echo "== live（リポジトリで追跡している *.md） =="

LIVE_LIST="$WORK/live.list"
if ! git -C "$REPO_ROOT" -c core.quotePath=false ls-files -- '*.md' >"$LIVE_LIST"; then
  bad "L0: git ls-files が失敗しました（走査対象を列挙できません）"
elif [ ! -s "$LIVE_LIST" ]; then
  bad "L0: 追跡している *.md が 0 件です（走査が成立していない）"
else
  set +e
  LIVE_OUT="$(scan_tree "$REPO_ROOT" "$LIVE_LIST")"
  LIVE_RC=$?
  set -e
  summary="$(printf '%s\n' "$LIVE_OUT" | awk '$1 == "SUMMARY" { print $2 " 件（一致 " $3 " / 外部 " $4 "）" }')"
  if [ "$LIVE_RC" -eq 0 ]; then
    ok "L1: パス付きの節参照 ${summary} がすべて実在する見出しを指す"
  else
    bad "L1: パス付きの節参照に、実在しない見出し・解決できないパス・判定不能がある（${summary}）:"
    printf '%s\n' "$LIVE_OUT" | awk '$1 != "SUMMARY"' | sed 's/^/    | /' >&2
  fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ section-ref-existence verify: $FAIL 件失敗 / $PASS 件成功" >&2
  REACHED_END=1
  exit 1
fi

echo "✓ section-ref-existence verify: 全 $PASS 件 pass"
REACHED_END=1
