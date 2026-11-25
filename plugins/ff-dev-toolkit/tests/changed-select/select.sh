#!/usr/bin/env bash
#
# select.sh — 変更ベースの部分ゲート（FF_RUN_ALL_CHANGED）の選択を受け持つ CLI（Issue `#3006`。親 `#2989`）
#
# tests/run-all.sh の ff_changed_select が呼ぶ。分担（入出力は環境変数・標準入出力・終了コード）:
#   - ここ: 参照の導出（derive）・依存の宣言・共有 lib の利用側の逆引き（users）・宣言と実際の参照の照合
#     （check）・走査する suite のファイルの集合（scan）
#   - run-all.sh: 変更一覧の組み立て・契約面の名簿（全件へ倒す名簿・文書契約面の束・選択に入れない suite）・
#     multi-agent.sh の構成ファイルの別名・利用側の合流と根拠の書き換え・ランナー自身の変更での自己検証
#     suite の強制選択。これらの規則の正本はランナーの実装箇所（名簿と規則は tests/run-all/verify.sh の
#     case 47 が固定する）
# 4,000 行を超えたランナーへ、選択のロジックをこれ以上足さない。
#
# 使い方:
# --- usage:start ---
#   select.sh derive <走査するファイル>...    # 環境: FF_CHG_FILES / FF_CHG_TESTS_PREFIX / FF_CHG_TESTS_DIR / FF_CHG_PLUGIN_PREFIX
#   select.sh users --root <リポジトリ> --plugin-prefix <接頭辞>   # 標準入力: 変更パス。標準出力: <利用側のパス>\t<元の変更パス>
#   select.sh check --root <リポジトリ> --tests-dir <tests の実パス> --plugin-prefix <接頭辞>
#   select.sh scan <tests の実パス>              # derive と check が走査する suite のファイルを 1 行ずつ出す
# --- usage:end ---
#
#   パスはリポジトリルート相対。<接頭辞> はプラグインルートのリポジトリ相対（`plugins/ff-dev-toolkit/`。
#   プラグインがリポジトリルートなら空文字）。使い方の誤り（値の無いオプションを含む）は終了コード 2
#   （サブコマンドが無い・未知は 64）。
#
# ── derive（字面の導出） ───────────────────────────────────────────────────
# 宣言の無い suite は、suite のディレクトリにあるスクリプトの各行（コメント行も拾う — 参照の言及は関係の
# 手掛かりで、拾い過ぎは多く回す側）からパス様の token を拾い、変更ファイルと交差させる。
#   token: `/` を含む `[A-Za-z0-9_.*+-]` の連なり（`skills/*/SKILL.md`・`../../docs/x.md`）と、拡張子付きの
#          ファイル名（`hooks.json`・`*.sh`）。シェル変数（`$X` / `${X}` / `${X:-y}`）は `*` へ置き換えてから
#          拾う — `"$PLUGIN_ROOT/skills/$name/SKILL.md"` は `skills/*/SKILL.md` として残る。先頭の `./` `../`
#          `/` と変数由来の `*/` は根の接頭辞なので剥がし、字面（英数字）を持たない token とシステムの絶対パス
#          （`/usr/bin/env`・`/dev/null`・`/tmp/…`）は捨てる。ルートの祖先ディレクトリそのもの
#          （`plugins/ff-dev-toolkit` など）は**捨てない** — ツリー全体を走査する suite はその token しか持た
#          ないことがあり、捨てると配下の変更で選ばれなくなる（祖先 token は配下の全変更と交差する）
#   交差: `/変更パス/` が `/token/` をパス成分の境界で含むこと（`*` は成分内の任意文字列）。完全一致・末尾
#         一致・先頭一致（ディレクトリの token）・途中一致を 1 つの規則で扱う。ただしファイル名だけの token
#         （`verify.sh`）は、ほかの suite のディレクトリ（`tests/<名前>/` 配下。`tests/lib/` は除く）の変更とは
#         交差させない — suite のディレクトリはその suite の私有物で、同名のファイルが全 suite にある。
#         ランナー（`tests/run-all.sh`）や共有 lib（`tests/lib/`）の変更とは交差させる
#   suite 自身のディレクトリ配下の変更はその suite を選ぶ。token を 1 つも導出できない suite は常に選ぶ
#   （導出の空振りを「関係なし」へ倒さない）。
#
# ── 依存の宣言 ─────────────────────────────────────────────────────────────
# suite のスクリプト（ふつうは verify.sh のヘッダ）に次の行を書くと、その suite は字面の照合をやめ、
# 宣言したパターンに一致する変更（と suite 自身のディレクトリ配下の変更）でだけ選ばれる:
#
#   # run-all-depends: <パターン> [<パターン>...]
#   # run-all-not-depends: <パス> <理由>
#
#   パターンはプラグインルート相対。`/` で始めるとリポジトリルート相対。`*` は 1 成分の中の任意の文字列、
#   `**` は成分をまたぐ任意の文字列、末尾 `/` はディレクトリの配下すべて。行は何行に分けてもよい。
#   宣言の無い suite は従来どおり字面の照合で選ぶ（少なく回す側へ倒さない）。
#   run-all-not-depends は、字面には出るが依存ではないファイル（説明のための言及・別 suite の名前を
#   出すだけの行など）を 1 つずつ理由つきで外す。run-all-depends のある suite でだけ意味を持つ（check の
#   「宣言に無い参照」の免除）。run-all-depends の無い suite に書いても選択は変わらないので、check が赤にする。
#
# ── check（宣言と実際の参照の照合） ────────────────────────────────────────────
# 宣言のある suite について、次の食い違いを赤にする（終了コード 1。suite 名と中身を 1 行ずつ出す）:
#   - 宣言に無い参照: suite のスクリプトの字面が、追跡下の実在ファイルを指すのに、宣言のどのパターンにも
#     run-all-not-depends にも当たらない。語は次の順で実在ファイルへ解決する:
#     1. リポジトリ相対・プラグイン相対の完全一致（両方が実在すれば両方）
#     2. 無ければ、ファイル形の語（`/` を含み、最後の成分に拡張子がある）は成分の境界での接尾辞一致で当たる
#        ファイルすべて（derive の字面の照合は `/語/` が `/変更パス/` に含まれれば選ぶので、別の基点から
#        書いた語 `$DOCS/05-operations/x.md` も選択に効いていた。宣言へ移すときにそれを落とさない）
#     3. ファイル名だけの語は、追跡下で 1 つに決まるときだけ
#   - 変数のディレクトリに続くファイル名（`"$TESTS/run-all.sh"`・`"$DIR/$x/README.md"` の最後の成分）は、
#     プラグインの中（無ければリポジトリ全体）で同じ名前のファイルが 1 つなら上の参照として扱う。2 つ以上なら、どれか 1 つが宣言・
#     run-all-not-depends・suite 自身のディレクトリで覆われていることを求め、覆われていなければ「1 つに
#     決まらない名前の参照」として赤にする（どれを使うかを宣言で書かせる）
#   - 宣言した lib を source していない: tests/lib・scripts/lib の具体的なファイルを宣言したのに、suite の
#     スクリプトに source の行（下の users の strict）が無い
#   - 宣言が実体に当たらない: パターンが追跡下のファイルに 1 つも一致しない
#   - 外したファイルを参照していない / 理由が無い / 実在しない: run-all-not-depends の行が古い
#   - run-all-depends の無い suite に run-all-not-depends がある
# glob（`*` を含む語）と、完全一致しないディレクトリの語は宣言を強制しない（字面の照合が拾い過ぎていた汎用の
# 語の正体で、走査する範囲は宣言の側で書く）。宣言の行そのものは字面の走査から外す（外さないと、宣言が
# 自分自身を参照して「宣言に無い参照」も「外したファイルを参照していない」も成立しない）。照合が見るのは
# suite のスクリプトの字面だけ — データファイルにだけ出る依存や、呼んだスクリプトがさらに読むファイルは
# 検出しない。宣言が実際より広い（読まなくなったファイルがまだ宣言に残る）ことも検出しない（多く回す側）。
# 判定できない（git が無い・tests を読めない・追跡下のファイルが 0 件・走査に失敗した）回は終了コード 2。
#
# ── users（共有 lib の利用側の逆引き） ────────────────────────────────────────
# 変わった共有 lib（`lib/` ディレクトリ配下の .sh / .bash。深さは問わない）の名前に触れるファイルを、プラグインの tests・hooks・
# scripts のシェル（fixtures・node_modules を除く）から推移的に集める。共有 lib はブラックボックスにしない —
# 公開関数の指紋で絞らず、利用側をすべて足す（bash の source は変数・関数・trap を共有するので、内部の変更
# でも利用側が壊れうる。指紋で絞るのは lib ごとの単体テストがそろってから）。
# 辺はコメント以外の行（と `# shellcheck source=` の指示）に出る .sh / .bash の名前で張る。lib は source の
# 行の外で名指されることが多い — パスを変数へ入れてから source する・名前を for で回して source する・
# 独自の関数で読む・複数行の一覧・lib を fixture へ写して壊す検査。source の行だけでは辺が切れて利用側を
# 取りこぼすので、名前に触れた行をすべて辺にする（同名は多く回す側へ倒れる）。
# 起点と推移の中継は共有 lib だけにする。実行ファイル（hook・スクリプト・ランナー・suite の入口）は利用側
# として返すが、そこから先へは広げない — 実行ファイルの名前は多くの検査・案内文に出るので、中継すると
# 「名前に触れたファイル」すべてへ広がる（試算で平均の全件比が 96% になった）。実行ファイルの変更と、
# 利用側として返した実行ファイルを実行する suite は、それを変更一覧へ足した derive が字面で拾う。
#
set -uo pipefail

usage() { sed -n '/^# --- usage:start ---$/,/^# --- usage:end ---$/p' "$0" | sed '1d;$d;s/^#//' >&2; }

# ── 字面の語の切り出し（derive と check で共有する awk 関数） ──────────────────────
COMMON_AWK='
  function longest_literal(t,   parts, n, i, best) {
    n = split(t, parts, "*")
    best = ""
    for (i = 1; i <= n; i++) if (length(parts[i]) > length(best)) best = parts[i]
    return best
  }
  # 語を正規化して返す。捨てる語は空文字。
  function normalize(tok,   t) {
    if (tok ~ /^\/(usr|bin|sbin|dev|tmp|etc|proc|opt|var|private|System|Library|Users|home)(\/|$)/) return ""
    t = tok
    while (1) {
      if (substr(t, 1, 2) == "./") { t = substr(t, 3); continue }
      if (substr(t, 1, 3) == "../") { t = substr(t, 4); continue }
      if (substr(t, 1, 1) == "/") { t = substr(t, 2); continue }
      if (substr(t, 1, 2) == "*/") { t = substr(t, 3); continue }
      break
    }
    sub(/\/+$/, "", t)
    if (t !~ /[A-Za-z0-9]/) return ""
    return t
  }
  # 宣言の行（走査から外す）
  function is_decl_line(line) {
    return (line ~ /^[[:space:]]*#[[:space:]]*run-all-(not-)?depends:/)
  }
  # 1 行から語を切り出して TOKS[1..n] に入れ、件数を返す。生の行を渡す — 変数（`$X` / `${X}` / `$1` 等）は
  # ここで `*` へ置き換えてから拾う
  function line_tokens(line,   n) {
    n = 0
    gsub(/\$\{[^}]*\}/, "*", line)
    gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, "*", line)
    gsub(/\$[0-9@#?*]/, "*", line)
    while (match(line, /[A-Za-z0-9_.*+-]*\/[A-Za-z0-9_.*+\/-]*/)) {
      TOKS[++n] = substr(line, RSTART, RLENGTH)
      line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
    }
    while (match(line, /[A-Za-z0-9_*+-]+\.[A-Za-z][A-Za-z0-9]*/)) {
      TOKS[++n] = substr(line, RSTART, RLENGTH)
      line = substr(line, RSTART + RLENGTH)
    }
    return n
  }
  # 宣言のパターンを、リポジトリ相対のパスに当てる正規表現へ変える
  function decl_regex(p, prefix,   re, dir, i, c, n) {
    if (substr(p, 1, 1) == "/") p = substr(p, 2); else p = prefix p
    dir = (substr(p, length(p), 1) == "/")
    # 1 文字ずつ変える（ブラケット式の中のエスケープは awk の実装で解釈が割れる）
    re = ""
    n = length(p)
    for (i = 1; i <= n; i++) {
      c = substr(p, i, 1)
      if (c == "*") {
        if (substr(p, i + 1, 1) == "*") { re = re ".*"; i++ } else re = re "[^/]*"
      } else if (index(".+?()|^$\\{}[]", c) > 0) re = re "\\" c
      else re = re c
    }
    if (dir) return "^" re ".*$"
    return "^" re "$"
  }
  # 宣言の行からパターンを DP[s, 1..DN[s]] へ足す（空白区切り。行頭の "# run-all-depends:" を剥がす）
  function add_decl(s, line,   rest, n, i, parts) {
    rest = line
    sub(/^[[:space:]]*#[[:space:]]*run-all-depends:[[:space:]]*/, "", rest)
    n = split(rest, parts, /[[:space:]]+/)
    for (i = 1; i <= n; i++) if (parts[i] != "") { DN[s]++; DP[s, DN[s]] = parts[i] }
    DECLARED[s] = 1
  }
  # suite 名を走査ファイルのパスから取る（tests/<名前>/...）
  function suite_of(path, dir,   s, j) {
    if (substr(path, 1, length(dir)) != dir) return ""
    s = substr(path, length(dir) + 1)
    j = index(s, "/")
    return (j > 1) ? substr(s, 1, j - 1) : ""
  }
'

# ── 走査する suite のファイル（derive と check で同じ集合を読む）────────────────────────
# tests/<suite>/ 配下（深さ 2 以上）のスクリプト。共有 lib・fixtures・node_modules は suite の参照として読まない。
scan_files() { # <tests の実パス>
  local tdir="$1"
  find "$tdir" \( -path "$tdir/lib" -o -name fixtures -o -name node_modules \) -prune \
    -o -type f -path "$tdir/*/*" \( -name '*.sh' -o -name '*.bash' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.js' -o -name '*.ts' -o -name '*.py' \) -print 2>/dev/null
}

# ── derive ────────────────────────────────────────────────────────────────
# 出力は走査した suite ごとに 1 行: `S<TAB>名前<TAB>根拠`（選ぶ）/ `R<TAB>名前`（選ばない）。
cmd_derive() {
  [ "$#" -gt 0 ] || { echo "select.sh derive: 走査するファイルが 0 件" >&2; return 2; }
  awk "$COMMON_AWK"'
    # ほかの suite のディレクトリ（tests/<名前>/ 配下。共有 lib の tests/lib/ を除く）の変更か
    function in_suite_dir(p,   rest, j) {
      if (substr(p, 1, length(pre)) != pre) return 0
      rest = substr(p, length(pre) + 1)
      j = index(rest, "/")
      return (j > 1 && substr(rest, 1, j - 1) != "lib")
    }
    function consider(s, tok,   t, key, lit, re, i, bare) {
      t = normalize(tok)
      if (t == "") return
      key = s SUBSEP t
      if (key in SEEN) return
      SEEN[key] = 1
      NTOK[s]++
      if (s in EV) return
      lit = longest_literal(t)
      bare = (index(t, "/") == 0 && index(t, "*") == 0)
      re = ""
      for (i = 1; i <= NC; i++) {
        if (C[i] == "" || index(C[i], lit) == 0) continue
        if (bare && in_suite_dir(C[i])) continue
        if (re == "") {
          re = t
          gsub(/\./, "\\.", re)
          gsub(/\+/, "\\+", re)
          gsub(/\*/, "[^/]*", re)
          re = "/" re "/"
        }
        if (("/" C[i] "/") ~ re) { EV[s] = C[i] " ← " tok; return }
      }
    }
    BEGIN {
      NC = split(ENVIRON["FF_CHG_FILES"], C, "\n")
      pre = ENVIRON["FF_CHG_TESTS_PREFIX"]
      prefix = ENVIRON["FF_CHG_PLUGIN_PREFIX"]
      dir = ENVIRON["FF_CHG_TESTS_DIR"] "/"
      for (i = 1; i <= NC; i++) {
        if (C[i] == "" || substr(C[i], 1, length(pre)) != pre) continue
        rest = substr(C[i], length(pre) + 1)
        j = index(rest, "/")
        if (j > 1) { n = substr(rest, 1, j - 1); if (!(n in OWN)) OWN[n] = C[i] }
      }
    }
    FNR == 1 {
      s = suite_of(FILENAME, dir)
      if (s != "") SUITES[s] = 1
    }
    s == "" { next }
    is_decl_line($0) {
      if ($0 ~ /run-all-depends:/) add_decl(s, $0)
      next
    }
    {
      nt = line_tokens($0)
      for (k = 1; k <= nt; k++) consider(s, TOKS[k])
    }
    END {
      for (s in SUITES) {
        if (s in OWN) { print "S\t" s "\t" OWN[s] " ← suite 自身のディレクトリ"; continue }
        if (s in DECLARED) {
          hit = ""
          for (k = 1; k <= DN[s] && hit == ""; k++) {
            re = decl_regex(DP[s, k], prefix)
            for (i = 1; i <= NC; i++) if (C[i] != "" && C[i] ~ re) { hit = C[i] " ← 宣言 " DP[s, k]; break }
          }
          if (hit != "") print "S\t" s "\t" hit
          else if (DN[s] == 0) print "S\t" s "\t宣言の行にパターンが無い（fail-safe で常に選ぶ）"
          else print "R\t" s
          continue
        }
        if (s in EV) print "S\t" s "\t" EV[s]
        else if (!(s in NTOK)) print "S\t" s "\t参照パスを 1 つも導出できない（fail-safe で常に選ぶ）"
        else print "R\t" s
      }
    }
  ' "$@"
}

# ── 名前の辺（<名指される basename>\t<名指すファイルのリポジトリ相対パス>）──────────────────────
# strict: source の行（行頭・`;` `&` `|` `(` `{` `!` と `if` `then` `do` `else` `elif` `while` `until` の後の
#         `. x` / `source x`。行末のコメントは除く）と `# shellcheck source=` の指示に出る .sh / .bash だけ。check の
#         「宣言した lib を source していない」に使う（説明の文字列やコメントで触れただけを「使う」に数えない）。
# broad : コメント以外の行に出る .sh / .bash の名前すべて（と `# shellcheck source=` の指示）。users に使う。
# find・awk のどれか 1 つでも失敗したら非 0 で返す（欠けた辺のまま成功に見せない）。
shell_files() { # <root> <plugin_prefix>
  local root="$1" pfx="$2" d
  for d in tests hooks scripts; do
    [ -d "$root/${pfx}$d" ] || continue
    find "$root/${pfx}$d" \( -name fixtures -o -name node_modules \) -prune -o -type f \( -name '*.sh' -o -name '*.bash' \) -print || return 2
  done
}

source_edges() { # <root> <plugin_prefix> <strict|broad>
  local root="$1" pfx="$2" mode="$3" f
  shell_files "$root" "$pfx" | while IFS= read -r f; do
    awk -v rel="${f#"$root"/}" -v mode="$mode" '
      function emit_all(line) {
        while (match(line, /[A-Za-z0-9_.-]+\.(sh|bash)/)) {
          print substr(line, RSTART, RLENGTH) "\t" rel
          line = substr(line, RSTART + RLENGTH)
        }
      }
      /^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+source=/ { emit_all($0); next }
      /^[[:space:]]*#/ { next }
      mode == "broad" { emit_all($0); next }
      # strict: 行末のコメント（空白の後の #）は読み込み先ではないので外してから拾う
      /(^|[;&|({!]|then|do|else|elif|if|while|until)[[:space:]]*(\.|source)[[:space:]]+[^[:space:]=]/ {
        line = $0
        sub(/[[:space:]]+#.*$/, "", line)
        emit_all(line)
        next
      }
    ' "$f" || { echo "select.sh: 名前の辺を読めない: ${f}" >&2; exit 2; }
  done | sort -u
}

need_value() { # <サブコマンド> <オプション> <残りの引数の数> <値>
  if [ "$3" -lt 2 ] || [ -z "$4" ]; then
    echo "select.sh $1: $2 に値が無い" >&2
    return 2
  fi
}

# ── users ─────────────────────────────────────────────────────────────────
cmd_users() {
  local root="" pfx="" edges changed
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) need_value users "$1" "$#" "${2-}" || return 2; root="$2"; shift 2 ;;
      --plugin-prefix) [ "$#" -ge 2 ] || { echo "select.sh users: $1 に値が無い" >&2; return 2; }; pfx="$2"; shift 2 ;;
      *) echo "select.sh users: 未知の引数: $1" >&2; return 2 ;;
    esac
  done
  [ -n "$root" ] && [ -d "$root" ] || { echo "select.sh users: --root が無い・読めない" >&2; return 2; }
  edges="$(source_edges "$root" "$pfx" broad)" || { echo "select.sh users: 名前の辺を集められない（判定不能）" >&2; return 2; }
  changed="$(cat)"
  # 変わった共有 lib の basename から、辺を逆向きに推移的にたどる（中継も共有 lib だけ）
  awk -F'\t' -v pfx="$pfx" '
    # 共有 lib か（`lib/` ディレクトリの配下。深さは問わない — ランナーが全件の名簿から外す範囲と揃える）
    function is_lib(path) { return (path ~ /(^|\/)lib\/.+\.(sh|bash)$/) }
    FNR == NR { if (NF == 2) { n = ++EN[$1]; EU[$1, n] = $2 }; next }
    {
      p = $0
      if (!is_lib(p)) next
      if (pfx != "" && substr(p, 1, length(pfx)) != pfx) next
      b = p; sub(/.*\//, "", b)
      nq = 0; delete Q; delete SEENB
      Q[++nq] = b; SEENB[b] = 1
      for (qi = 1; qi <= nq; qi++) {
        cur = Q[qi]
        for (k = 1; k <= EN[cur]; k++) {
          u = EU[cur, k]
          if (!(u in OUT)) { OUT[u] = p; ORDER[++no] = u }
          if (!is_lib(u)) continue
          ub = u; sub(/.*\//, "", ub)
          if (!(ub in SEENB)) { SEENB[ub] = 1; Q[++nq] = ub }
        }
      }
    }
    END { for (i = 1; i <= no; i++) print ORDER[i] "\t" OUT[ORDER[i]] }
  ' <(printf '%s\n' "$edges") <(printf '%s\n' "$changed")
}

# ── check ─────────────────────────────────────────────────────────────────
cmd_check() {
  local root="" tdir="" pfx="" tracked tlist edges rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) need_value check "$1" "$#" "${2-}" || return 2; root="$2"; shift 2 ;;
      --tests-dir) need_value check "$1" "$#" "${2-}" || return 2; tdir="$2"; shift 2 ;;
      --plugin-prefix) [ "$#" -ge 2 ] || { echo "select.sh check: $1 に値が無い" >&2; return 2; }; pfx="$2"; shift 2 ;;
      *) echo "select.sh check: 未知の引数: $1" >&2; return 2 ;;
    esac
  done
  [ -n "$root" ] && [ -d "$root" ] || { echo "select.sh check: --root が無い・読めない（判定不能）" >&2; return 2; }
  [ -n "$tdir" ] && [ -d "$tdir" ] || { echo "select.sh check: --tests-dir が無い・読めない（判定不能）" >&2; return 2; }
  if ! tracked="$(git -C "$root" ls-files --cached --others --exclude-standard 2>/dev/null)"; then
    echo "select.sh check: 追跡下のファイル一覧を取れない（git が無い・リポジトリでない。判定不能）" >&2
    return 2
  fi
  [ -n "$tracked" ] || { echo "select.sh check: 追跡下のファイルが 0 件（判定不能）" >&2; return 2; }
  edges="$(source_edges "$root" "$pfx" strict)" || { echo "select.sh check: source の辺を集められない（判定不能）" >&2; return 2; }
  tlist="$(mktemp "${TMPDIR:-/tmp}/ff-chgsel-tracked.XXXXXX")" || return 2
  printf '%s\n' "$tracked" > "$tlist"
  local -a scan=()
  local f
  while IFS= read -r f; do [ -n "$f" ] && scan+=("$f"); done < <(scan_files "$tdir")
  if [ "${#scan[@]}" -eq 0 ]; then
    rm -f "$tlist"
    echo "select.sh check: 走査する suite のファイルが 0 件（判定不能）" >&2
    return 2
  fi
  FF_CHG_TRACKED_LIST="$tlist" FF_CHG_EDGES="$edges" FF_CHG_PLUGIN_PREFIX="$pfx" FF_CHG_TESTS_DIR="$tdir" \
    FF_CHG_TESTS_REL="${pfx}tests/" awk "$COMMON_AWK"'
    # 語を追跡下のファイルへ解決して RES[1..n] に入れ、件数を返す（順は先頭コメントの「宣言に無い参照」）。
    # glob（`*` を含む語）は解決しない。完全一致しない語のうち、最後の成分に拡張子が無いもの（ディレクトリの
    # 語）も解決しない。
    function resolve(t,   n, k, last) {
      delete RES
      n = 0
      if (t == "" || index(t, "*") > 0) return 0
      if (t in TRACKED) RES[++n] = t
      if (prefix != "" && (prefix t) in TRACKED) RES[++n] = prefix t
      if (n > 0) return n
      if (index(t, "/") == 0) {
        if (index(t, ".") > 0 && (t in BASECOUNT) && BASECOUNT[t] == 1) { RES[1] = BASEPATH[t]; return 1 }
        return 0
      }
      last = t
      sub(/.*\//, "", last)
      if (index(last, ".") == 0) return 0
      for (k = 1; k <= SUFN[t]; k++) RES[++n] = SUFP[t, k]
      return n
    }
    function covered(s, path,   k) {
      for (k = 1; k <= DN[s]; k++) if (path ~ decl_regex(DP[s, k], prefix)) return 1
      return 0
    }
    # 覆われている（suite 自身のディレクトリ・外したファイル・宣言）か
    function settled(s, path) {
      return (index(path, trel s "/") == 1 || ((s SUBSEP path) in NOTDEP) || covered(s, path))
    }
    function add_ref(s, p, where) {
      if ((s SUBSEP p) in REF) return
      REF[s SUBSEP p] = where
      NREF[s]++
      RP[s, NREF[s]] = p
    }
    function bad(s, msg) { print "✗ " s ": " msg; NBAD++ }
    # 変数のディレクトリに続くファイル名の候補を CAND[1..n] に入れ、件数を返す。プラグインの中に同名が
    # あればそれだけ、無ければリポジトリ全体（プラグインの外のスクリプトを呼ぶ suite を見逃さない）
    function cands(t,   i) {
      delete CAND
      NCAND = 0
      if (PBN[t] > 0) { for (i = 1; i <= PBN[t]; i++) CAND[++NCAND] = PBP[t, i] }
      else { for (i = 1; i <= BASECOUNT[t]; i++) CAND[++NCAND] = RBP[t, i] }
      return NCAND
    }
    BEGIN {
      prefix = ENVIRON["FF_CHG_PLUGIN_PREFIX"]
      dir = ENVIRON["FF_CHG_TESTS_DIR"] "/"
      trel = ENVIRON["FF_CHG_TESTS_REL"]
      while ((getline tp < ENVIRON["FF_CHG_TRACKED_LIST"]) > 0) {
        if (tp == "") continue
        TRACKED[tp] = 1
        bn = tp; sub(/.*\//, "", bn)
        BASECOUNT[bn]++; BASEPATH[bn] = tp
        # 同名ファイル（変数のディレクトリに続くファイル名の解決に使う。プラグインの中を先に見る）
        if (substr(tp, 1, length(prefix)) == prefix) { PBN[bn]++; PBP[bn, PBN[bn]] = tp }
        RBP[bn, BASECOUNT[bn]] = tp
        NTRACKED++
        # 成分の境界で切った接尾辞（`/` を 1 つ以上含むもの）→ パスの索引
        suf = tp
        while ((j = index(suf, "/")) > 0) {
          suf = substr(suf, j + 1)
          if (index(suf, "/") == 0) break
          SUFN[suf]++
          SUFP[suf, SUFN[suf]] = tp
        }
      }
      ne = split(ENVIRON["FF_CHG_EDGES"], EL, "\n")
      for (i = 1; i <= ne; i++) {
        if (split(EL[i], ef, "\t") != 2) continue
        SRCED[ef[2], ef[1]] = 1
      }
    }
    FNR == 1 {
      s = suite_of(FILENAME, dir)
      rel = (s == "") ? "" : trel substr(FILENAME, length(dir) + 1)
      if (s != "") SUITES[s] = 1
    }
    s == "" { next }
    is_decl_line($0) {
      if ($0 ~ /run-all-depends:/) { add_decl(s, $0); DLOC[s] = rel ":" FNR }
      else {
        line = $0
        sub(/^[[:space:]]*#[[:space:]]*run-all-not-depends:[[:space:]]*/, "", line)
        np = split(line, nparts, /[[:space:]]+/)
        NN[s]++
        NP[s, NN[s]] = nparts[1]
        NR_[s, NN[s]] = (np >= 2 && nparts[2] != "") ? 1 : 0
        NLOC[s, NN[s]] = rel ":" FNR
      }
      next
    }
    {
      nt = line_tokens($0)
      for (k = 1; k <= nt; k++) {
        t = normalize(TOKS[k])
        # 変数のディレクトリに続くファイル名（生の語に `*` があり、正規化でファイル名だけが残る）
        if (index(TOKS[k], "*") > 0 && t != "" && index(t, "/") == 0 && index(t, "*") == 0 && index(t, ".") > 0) {
          if (!((s SUBSEP t) in VBSET)) {
            VBSET[s, t] = 1
            VBN[s]++
            VBT[s, VBN[s]] = t
            VBLOC[s, VBN[s]] = rel ":" FNR " の " TOKS[k]
          }
          continue
        }
        nr = resolve(t)
        for (r = 1; r <= nr; r++) add_ref(s, RES[r], rel ":" FNR " の " TOKS[k])
      }
    }
    END {
      if (NTRACKED == 0) { print "select.sh check: 追跡下のファイルを読めない（判定不能）" > "/dev/stderr"; exit 2 }
      declared = 0
      for (s in SUITES) {
        if (!(s in DECLARED)) {
          if (NN[s] > 0) bad(s, "run-all-depends が無いのに run-all-not-depends がある（単独では選択も照合も変わらない。" NLOC[s, 1] "）")
          continue
        }
        declared++
        if (DN[s] == 0) bad(s, "宣言の行にパターンが無い（" DLOC[s] "）")
        # 宣言が実体に当たらない
        for (k = 1; k <= DN[s]; k++) {
          re = decl_regex(DP[s, k], prefix)
          hit = 0
          for (tp in TRACKED) if (tp ~ re) { hit = 1; break }
          if (!hit) bad(s, "宣言が実体に当たらない: " DP[s, k])
          # 宣言した lib を source していない（具体的な lib のファイルだけを見る）
          p = DP[s, k]
          if (index(p, "*") == 0 && substr(p, length(p), 1) != "/" && p ~ /(^|\/)(tests|scripts)\/lib\/[^\/]+\.(sh|bash)$/) {
            b = p; sub(/.*\//, "", b)
            found = 0
            for (kk in SRCED) {
              split(kk, sk, SUBSEP)
              if (sk[2] == b && index(sk[1], trel s "/") == 1) { found = 1; break }
            }
            if (!found) bad(s, "宣言した lib を source していない: " p)
          }
        }
        # 変数のディレクトリに続くファイル名: 候補が 1 つに決まるなら参照として数える
        for (k = 1; k <= VBN[s]; k++) {
          if (cands(VBT[s, k]) == 1) add_ref(s, CAND[1], VBLOC[s, k])
        }
        # 外したファイル
        for (k = 1; k <= NN[s]; k++) {
          nr = resolve(normalize(NP[s, k]))
          if (nr == 0) { bad(s, "run-all-not-depends のファイルが実在しない: " NP[s, k] "（" NLOC[s, k] "）"); continue }
          if (!NR_[s, k]) bad(s, "run-all-not-depends に理由が無い: " NP[s, k] "（" NLOC[s, k] "）")
          refd = 0
          for (r = 1; r <= nr; r++) {
            NOTDEP[s, RES[r]] = 1
            if ((s SUBSEP RES[r]) in REF) refd = 1
            b = RES[r]; sub(/.*\//, "", b)
            if ((s SUBSEP b) in VBSET) refd = 1
          }
          if (!refd) bad(s, "run-all-not-depends で外したファイルを参照していない: " NP[s, k] "（" NLOC[s, k] "）")
        }
        # 宣言に無い参照
        for (k = 1; k <= NREF[s]; k++) {
          p = RP[s, k]
          if (settled(s, p)) continue
          bad(s, "宣言に無い参照: " p "（" REF[s SUBSEP p] "）")
        }
        # 変数のディレクトリに続くファイル名が 1 つに決まらない: どれか 1 つが覆われていれば足りる
        for (k = 1; k <= VBN[s]; k++) {
          t = VBT[s, k]
          nc = cands(t)
          if (nc < 2) continue
          ok = 0
          for (i = 1; i <= nc && !ok; i++) if (settled(s, CAND[i])) ok = 1
          if (!ok) bad(s, "1 つに決まらない名前の参照: " t "（候補 " nc " 件。どれを使うかを宣言か run-all-not-depends で書く。" VBLOC[s, k] "）")
        }
      }
      printf "changed-select check: declared=%d violations=%d\n", declared, NBAD + 0
      exit (NBAD > 0) ? 1 : 0
    }
  ' "${scan[@]}"
  rc=$?
  rm -f "$tlist"
  return "$rc"
}

case "${1-}" in
  derive) shift; cmd_derive "$@" ;;
  users) shift; cmd_users "$@" ;;
  check) shift; cmd_check "$@" ;;
  scan)
    shift
    [ "$#" -eq 1 ] && [ -d "$1" ] || { echo "select.sh scan: tests の実パスを 1 つ渡すこと" >&2; exit 2; }
    scan_files "$1"
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 64 ;;
esac
