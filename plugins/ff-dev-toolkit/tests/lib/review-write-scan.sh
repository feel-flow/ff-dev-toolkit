#!/usr/bin/env bash
#
# レビュー走行中ガード（hooks/guard-review-in-flight.sh）の **Bash 経由の作業ツリー書き込み走査**。
# hook が `hooks/../tests/lib/` から source する共有ライブラリ（`exit-code-guard.sh` /
# `heredoc-strip.sh` と同じ配置。hook 本体の行数を分割閾値の内側に保つため、判定はここに置く）。
#
# 目的: 走行中ロック / レーンが生きている間に、作業ツリー内のファイルを書き換える Bash
# コマンド（`python3` のパッチスクリプト・`sed -i` / `tee` / リダイレクト等）を deny する。
#
# 線引き:
#   - ツリー外（scratchpad / `mktemp -d` / /tmp）への書き込みは止めない。走行中の規定が求める
#     「対応は下書きに留めよ」を実行できなくなるため
#   - レビュー出力先（`${ROOT}/.review-results/`）は編集系ツールと同じく止めない
#   - 書き込み先を判定できない（変数展開・読めないスクリプト・stdin プログラム・未終端 heredoc・
#     cd 先不明の相対パス・マーカー行に書き込み先リテラルが無い）ときは deny 側へ倒す（走行中に
#     限る）。判定できないものを通すと、このガードが守る「レビュー対象と作業ツリーの一致」を
#     ガード自身が破る
#   - gitignore 済みのパスは**ツリー内でも止めない**。結果の破棄を決めるリビジョン指紋
#     （scripts/adapters/adapter-common.sh の capture_repo_snapshot）は
#     `git status --porcelain` / `git diff HEAD` / `git diff --cached` /
#     `git ls-files --others --exclude-standard` の 4 つで組まれており、ignored はその
#     どれにも現れない（同関数の「見えないものを明示しておく」に明記）。指紋に映らない
#     書き込みを止めても守るものが無く、`multi-review` 自身が待ち時間に勧める作業
#     （`gh` の出力を `tmp/` へ受ける形）だけが止まる。判定は `git check-ignore` で、
#     **起動できない / rc が 0 以外はすべて「ignored ではない」= deny 側**へ倒す。
#     免除に当たっても**末端が symlink ならリンク先で判定し直す**（`ignored/link -> tracked`
#     で指紋を動かせるため）。リンクを解決できない回は止める側
#   - インタプリタ（python / node / perl / ruby / awk / sh 系）は**プログラム本文**を取ってから
#     判定する。インライン（`-c` / `-e`）・stdin の heredoc 本文・here-string・`< file`・読める
#     script ファイル（先頭 256 KiB）を本文とし、sh 系（`source` / `.` を含む）は本文を再帰走査
#     （深さ 2 まで）、それ以外は書き込みマーカー（`open(…"w")` / `write_text(` / `writeFileSync(` /
#     `File.write` / perl `-i` 等）を探し、マーカー行の最初のパスリテラルを書き込み先として
#     ツリー包含を判定する（リテラルが無い = 変数経由は判定不能）。マーカーが無ければ読み取り
#     専用として通す（`python3 -c 'print(1)'` を止めない）
#   - `$(…)` / バッククォートの本文はサブシェルとして再帰走査する（`echo "$(rm x)"` を見逃さない）
#   - `cd` は相対パスの解決基準を動かす。サブシェル `( … )` と子シェル（`bash -c` / heredoc /
#     `$(…)`）の中の `cd` は親へ漏らさない（`bash -c 'cd /tmp'; touch README.md` はツリー内）
#   - 既知の限界: マーカー走査はヒューリスティック（`from os import remove as r` は見逃す）。
#     空白を含むパスは素朴なトークン化で割れる。`python3 -m MOD` / `eval` / stdin から読む
#     プログラム（`curl … | sh`）は本文が無いので判定不能側。`npm` / `make` 等のビルドは対象外
#
# 公開関数（hook が呼ぶ）:
#   ff_write_scan_init <ROOT_PHYS> <CWD_PHYS> <OUTPUT_DIR_NAME>
#   ff_write_scan <生コマンド> <HEREDOC_STATE: ok|unterminated|unavailable> <HEREDOC_CODE> <HEREDOC_BODIES>
#     0 = 止める対象（WRITE_REASON に理由、WRITE_OVERRIDE に区間先頭の FF_REVIEW_LOCK_OVERRIDE=1 の有無）
#     1 = 止めない
# 依存: heredoc-strip.sh（入れ子の本文を落とすため。無ければ入れ子は判定不能側）。
# 検査用の差し替え口: FF_WRITE_SCAN_GREP（マーカー走査の grep。失敗（不在 127 等）を
# 「マーカー無し」に畳まず判定不能へ倒すことを suite で実測するため）。
# FF_WRITE_SCAN_GIT（ignored 判定の git。起動できない回を「ignored」に畳まず deny 側へ
# 倒すことを suite で実測するため）。
# 互換性: bash 3.2（stock macOS）。連想配列・readarray・=~ は使わない。

WRITE_HIT=0
WRITE_REASON=""
WRITE_OVERRIDE=0
WRITE_BASE=""      # 相対パスの解決基準（`cd` で動く。空 = 不明）
WS_ROOT_PHYS=""
WS_OUTPUT_DIR=".review-results"
RESOLVED=""
RESOLVE_WHY=""
VAR_TABLE=""
# HEREDOC_STATE / HEREDOC_CODE / HEREDOC_BODIES は呼び出し側（hook）が決めて ff_write_scan の
# 引数で渡す。source 時にここで初期化すると、先に決めた値を上書きしてしまう
WS_SUB_DEPTH=0
WS_RS="$(printf '\001')" # 区間の区切り（改行を含む区間を運ぶ。NUL は $(…) が落とすので使わない）
WS_SUB_BASE=""
WS_SUB_VARS=""

ff_write_scan_init() { # <ROOT_PHYS> <CWD_PHYS> <OUTPUT_DIR_NAME>
  WS_ROOT_PHYS="$1"
  WRITE_BASE="$2"
  WS_OUTPUT_DIR="${3:-.review-results}"
  WRITE_HIT=0
  WRITE_REASON=""
  WRITE_OVERRIDE=0
  VAR_TABLE=""
  WS_SUB_DEPTH=0
}

ws_phys_dir() { # <dir> → 物理パス（失敗は空）
  (cd "$1" 2>/dev/null && pwd -P 2>/dev/null)
}
ws_path_within() { # <phys> <root_phys>
  case "$1" in
    "$2" | "$2"/*) return 0 ;;
  esac
  return 1
}
unquote1() { # <token> → 外側の引用符 1 層を剥がす
  local t="$1"
  case "$t" in
    \"*\") t="${t#\"}"; t="${t%\"}" ;;
    \'*\') t="${t#\'}"; t="${t%\'}" ;;
  esac
  printf '%s' "$t"
}
ws_trim() { # <s>
  local s="$1"
  s="${s#"${s%%[! 	]*}"}"
  s="${s%"${s##*[! 	]}"}"
  printf '%s' "$s"
}

# ---- 変数 -------------------------------------------------------------------------
# コマンド内の単純代入（`O=/path` / `D="$(mktemp -d)"`）と hook 環境の変数だけを展開する。
# それ以外の `$…`（コマンド置換・`${X:-y}` 等）は判定不能。`$(mktemp …)` の代入は一時領域
# （ツリー外）として扱う — 走行中の規定が勧める「`mktemp -d` へ下書き」を止めないため。
# ただしテンプレートにディレクトリが付く形（`mktemp -d ./x.XXXXXX`）はその配置先で判定する。
expand_vars() { # <文字列> → 展開後を stdout。解決できなければ 1
  local s="$1" out="" name val rest
  while :; do
    case "$s" in
      *'$'*) : ;;
      *) printf '%s' "${out}${s}"; return 0 ;;
    esac
    out="${out}${s%%\$*}"
    s="${s#*\$}"
    case "$s" in
      '('* | '') return 1 ;;
      '{'*)
        rest="${s#\{}"
        name="${rest%%\}*}"
        [ "$name" != "$rest" ] || return 1
        s="${rest#*\}}"
        ;;
      *)
        name="$(printf '%s' "$s" | LC_ALL=C sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p')"
        [ -n "$name" ] || return 1
        s="${s#"$name"}"
        ;;
    esac
    case "$name" in
      '' | *[!A-Za-z0-9_]*) return 1 ;;
    esac
    val="$(printf '%s\n' "$VAR_TABLE" | LC_ALL=C sed -n "s/^${name}=//p" | tail -n 1)"
    # $PWD はツール側の cwd（cd 追跡後の解決基準）。hook プロセスの PWD ではない
    if [ -z "$val" ] && [ "$name" = "PWD" ]; then
      [ -n "$WRITE_BASE" ] || return 1
      val="$WRITE_BASE"
    fi
    if [ -z "$val" ]; then
      if printenv "$name" >/dev/null 2>&1; then val="$(printenv "$name")"; else return 1; fi
    fi
    out="${out}${val}"
  done
}
record_assignment() { # <区間> → 単純代入なら VAR_TABLE へ積む（コマンド前置の代入は積まない）
  local seg name value inner tmpl d
  seg="$(ws_trim "$1")"
  case "$seg" in
    export\ * | local\ * | declare\ * | typeset\ *) seg="$(ws_trim "${seg#* }")" ;;
  esac
  case "$seg" in
    [A-Za-z_]*=*) : ;;
    *) return 1 ;;
  esac
  name="${seg%%=*}"
  case "$name" in *[!A-Za-z0-9_]*) return 1 ;; esac
  value="${seg#*=}"
  case "$value" in
    \"*\" | \'*\') value="$(unquote1 "$value")" ;;
  esac
  case "$value" in
    '$(mktemp'*')')
      inner="${value#\$(mktemp}"
      inner="${inner%)}"
      case "$inner" in *' -p'* | *'--tmpdir'*) return 1 ;; esac
      tmpl=""
      for d in $inner; do
        case "$d" in -*) : ;; *) tmpl="$d" ;; esac
      done
      case "$tmpl" in
        */*)
          resolve_target "${tmpl%/*}" || return 1
          value="${RESOLVED}/ff-mktemp-placeholder"
          ;;
        *) value="${TMPDIR:-/tmp}/ff-mktemp-placeholder" ;;
      esac
      ;;
    *'$('* | *'`'*) return 1 ;;
    *[[:space:]]*) return 1 ;; # `NAME=v cmd …` の前置形
    *'$'*) value="$(expand_vars "$value")" || return 1 ;;
  esac
  VAR_TABLE="${VAR_TABLE}
${name}=${value}"
  return 0
}

# ---- パス --------------------------------------------------------------------------
resolve_target() { # <path token> → RESOLVED（物理パス）。判定不能は 1 + RESOLVE_WHY
  local t d rest leaf pd
  t="$(unquote1 "$1")"
  RESOLVED=""
  RESOLVE_WHY=""
  case "$t" in
    *'$('* | *'`'*) RESOLVE_WHY="コマンド置換"; return 1 ;;
    *'$'*) t="$(expand_vars "$t")" || { RESOLVE_WHY="変数展開"; return 1; } ;;
  esac
  case "$t" in
    '') RESOLVE_WHY="空のパス"; return 1 ;;
    '~' | '~/'*) t="${HOME}${t#\~}" ;;
    '~'*) RESOLVE_WHY="~user 形式"; return 1 ;;
  esac
  # glob は最初のメタ文字の手前で切り、ディレクトリ部分だけを見る（`rm -rf x/*` は x）
  case "$t" in
    *[\*\?\[]*)
      t="${t%%[\*\?\[]*}"
      case "$t" in
        */*) t="${t%/*}" ;;
        *) t="." ;;
      esac
      ;;
  esac
  [ "$t" = "/" ] || t="${t%/}"
  case "$t" in
    /*) : ;;
    *)
      [ -n "$WRITE_BASE" ] || { RESOLVE_WHY="cd 先が不明な相対パス"; return 1; }
      t="${WRITE_BASE}/${t}"
      ;;
  esac
  # 存在する最深の祖先を物理化し、残り（未作成のパス・末端）はそのまま繋ぐ（末端の symlink は
  # 辿らない — ツリー内のエントリとして見る）
  d="$t"
  rest=""
  while [ ! -d "$d" ]; do
    leaf="${d##*/}"
    d="${d%/*}"
    [ -n "$d" ] || d=/
    rest="${leaf}/${rest}"
    [ "$d" = "/" ] && break
  done
  pd="$(ws_phys_dir "$d")"
  [ -n "$pd" ] || { RESOLVE_WHY="親ディレクトリを解決できない"; return 1; }
  rest="${rest%/}"
  if [ -n "$rest" ]; then
    [ "$pd" = "/" ] && RESOLVED="/${rest}" || RESOLVED="${pd}/${rest}"
  else
    RESOLVED="$pd"
  fi
  return 0
}
# gitignore 済みか（0 = ignored = 止めない）。ここが走行中ガードの許可条件のうち
# 「指紋に映らない書き込み先」を判定する面で、**判定できない回はすべて deny 側**
# （「ignored ではない」）へ倒す:
#   - `git` を起動できない（PATH に無い / 差し替え口が壊れている）→ rc 127 等
#   - リポジトリ外・パス解決不能 → rc 128
#   - ignored でない → rc 1
# ignored なのは rc 0 の 1 経路だけで、それ以外を許可側へ畳まない（緩める方向の変更を
# 判定不能へ波及させない）。呼ぶのはツリー内と分かった後だけなので、`git` の起動は
# 「止める候補」に当たった回にしか払わない。
#
# **`--no-index` を足さないこと。** `check-ignore` は既定で index を見るので、ignore
# パターンに当たる **tracked なファイル**（`git add -f` された `build/keep.txt` 等）を
# 「ignored ではない」と答える（実測: rc 1）。これは指紋の側と一致している — tracked で
# ある以上その変更は `git status` にも `git diff HEAD` にも出るので、止めなければ結果は
# 破棄される。`--no-index` は純粋なパターン照合へ倒すので、この一致が壊れて fail-open に
# なる。suite の「tracked だが ignore パターンに当たるファイル」の針がここを固定する。
#
# rc 1（本当に ignored でない）と rc 127 / 128（判定そのものが不能）は**同じ「止める」だが
# 別の理由**なので、後者を WS_IGNORE_UNKNOWN / WS_IGNORE_RC で外へ出す。畳むと、git が
# 壊れた環境で ignored なパスへの書き込みが「作業ツリー内へ書き込みます」という**原因を
# 誤って名指しする** deny になり、利用者が ignored 免除の壊れた理由へ辿り着けない。
WS_IGNORE_UNKNOWN=0
WS_IGNORE_RC=""
ws_target_ignored() { # <phys> → 0 = ignored
  local rc
  WS_IGNORE_UNKNOWN=0
  WS_IGNORE_RC=""
  [ -n "$WS_ROOT_PHYS" ] || return 1
  "${FF_WRITE_SCAN_GIT:-git}" -C "$WS_ROOT_PHYS" check-ignore -q -- "$1" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      WS_IGNORE_UNKNOWN=1
      WS_IGNORE_RC="$rc"
      return 1
      ;;
  esac
}

# 免除に当たるか（0 = 免除 = 止めない）。ツリー外 / レビュー出力先 / gitignore 済みの 3 つ。
ws_target_exempt() { # <phys>
  ws_path_within "$1" "$WS_ROOT_PHYS" || return 0
  ws_path_within "$1" "${WS_ROOT_PHYS}/${WS_OUTPUT_DIR}" && return 0
  ws_target_ignored "$1" && return 0
  return 1
}

# 末端が symlink のときの最終的な実体（stdout）。解決できなければ 1。
# `resolve_target` は末端の symlink を辿らない（ツリー内のエントリとして見る）ので、
# 免除の判定は**リンク名**に当たってしまう。`ignored/link.txt -> src/app.ts` の形で
# tracked を書き換えられる（実測 2026-09-18: ignored な symlink 経由の追記で
# `git diff HEAD` に tracked が現れた）。同じ穴はツリー外 symlink にも在る。
WS_LINK_MAX=8
ws_final_target() { # <phys>
  local p="$1" n=0 t d pd leaf
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le "$WS_LINK_MAX" ] || return 1
    t="$(readlink "$p" 2>/dev/null)" || return 1
    [ -n "$t" ] || return 1
    case "$t" in
      /*) p="$t" ;;
      *)
        d="${p%/*}"
        [ "$d" != "$p" ] || d="."
        [ -n "$d" ] || d="/"
        p="${d}/${t}"
        ;;
    esac
  done
  leaf="${p##*/}"
  d="${p%/*}"
  [ "$d" != "$p" ] || d="."
  [ -n "$d" ] || d="/"
  pd="$(ws_phys_dir "$d")" || return 1
  [ -n "$pd" ] || return 1
  if [ "$pd" = "/" ]; then printf '/%s' "$leaf"; else printf '%s/%s' "$pd" "$leaf"; fi
}

target_in_tree() { # <phys> → 0 = 止める対象（ツリー内・出力先でない・ignored でない）
  local ws_final
  ws_target_exempt "$1" || return 0
  # 免除に当たっても、末端が symlink なら**リンク先**で判定し直す。リンク名の ignore /
  # ツリー外は「その名前で解決される実体」の話ではない。解決できない（壊れたリンク・
  # 深すぎる連鎖・readlink 不在）回は止める側。
  if [ -L "$1" ]; then
    ws_final="$(ws_final_target "$1")" || return 0
    ws_target_exempt "$ws_final" || return 0
  fi
  return 1
}
judge_target() { # <path token> <何の書き込みか> → 0 = hit
  case "$(unquote1 "$1")" in
    /dev/null | /dev/stdout | /dev/stderr | /dev/tty | /dev/fd/*) return 1 ;;
  esac
  if ! resolve_target "$1"; then
    WRITE_HIT=1
    WRITE_REASON="書き込み先を判定できません（${RESOLVE_WHY}: ${1}。${2}）"
    return 0
  fi
  if target_in_tree "$RESOLVED"; then
    WRITE_HIT=1
    if [ "${WS_IGNORE_UNKNOWN:-0}" -eq 1 ]; then
      # 「ツリー内だから止めた」と「ignored かを判定できないから止めた」は別の原因。
      # 畳むと、git が壊れた環境で ignored なパスが誤った理由で名指しされる。
      WRITE_REASON="gitignore 済みかを判定できません（git check-ignore rc=${WS_IGNORE_RC:-?}: ${RESOLVED}。${2}）"
    else
      WRITE_REASON="作業ツリー内へ書き込みます: ${RESOLVED}（${2}）"
    fi
    return 0
  fi
  return 1
}
undeterminable() { # <理由>
  WRITE_HIT=1
  WRITE_REASON="書き込み先を判定できません（${1}）"
  return 0
}

# ---- 引数 --------------------------------------------------------------------------
NONOPTS=()
collect_nonopts() { # <値を取るオプション（空白区切り）> <args...> → NONOPTS
  local valued="$1" dd=0 a
  shift
  NONOPTS=()
  while [ "$#" -gt 0 ]; do
    a="$1"
    shift
    if [ "$dd" -eq 1 ]; then NONOPTS[${#NONOPTS[@]}]="$a"; continue; fi
    case "$a" in
      '<' | '<<' | '<<-' | '<<<') [ "$#" -gt 0 ] && shift; continue ;; # 入力リダイレクトは対象ではない
      '<'*) continue ;;
      --) dd=1 ;;
      -?*)
        case " $valued " in
          *" $a "*) [ "$#" -gt 0 ] && shift ;;
        esac
        ;;
      *) NONOPTS[${#NONOPTS[@]}]="$a" ;;
    esac
  done
}
opt_value() { # <opt> <args...> → 直後の値（無ければ空）
  local opt="$1"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$opt" ]; then printf '%s' "${2:-}"; return 0; fi
    case "$1" in "$opt"=*) printf '%s' "${1#*=}"; return 0 ;; esac
    shift
  done
  return 1
}
is_write_head() { # <basename>
  case "$1" in
    tee | sed | gsed | cp | install | ln | rsync | scp | mv | rm | rmdir | unlink | shred | mkdir | touch | truncate | mkfifo | chmod | chown | chgrp | patch | dd | mktemp | tar | unzip | zip | gzip | gunzip | bzip2 | bunzip2 | xz | unxz | zstd | curl | wget | find | xargs | eval | git | sort | sponge) return 0 ;;
  esac
  return 1
}
is_interp_head() { # <basename>
  case "$1" in
    python | python2 | python3 | node | perl | ruby | bash | sh | zsh | ksh | dash | awk | gawk | source | .) return 0 ;;
  esac
  return 1
}

# ---- 区間分割（引用符・置換を保つ）---------------------------------------------------
# 区切り子: `;`（`;;` 含む）/ `&&` / `||` / `|`（`>|` は除く）/ 単独の `&`（リダイレクト由来の
# `2>&1` `>&2` `&>` は除く）/ 改行。引用符の内側と `$(…)` / バッククォートの内側では割らない。
ws_split_segments() { # <code> → 区間を \001 区切りで出す（引用符・置換が行をまたぐ区間は改行を含む）
  printf '%s\n' "$1" | LC_ALL=C awk '
    function emit(x) { printf "%s%s%c", kind, x, 1; kind = "S" }
    BEGIN { seg = ""; q = ""; depth = 0; kind = "N" }
    {
      s = $0; n = length(s); prev = " "
      if (q != "" || depth > 0) seg = seg "\n"; else kind = "N"
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); nx = substr(s, i + 1, 1)
        if (q != "") {
          seg = seg c
          if (c == "\\" && q == "\"") { seg = seg nx; i++; continue }
          if (c == q) q = ""
          continue
        }
        if (c == "\\") { seg = seg c nx; i++; prev = "_"; continue }
        if (c == "\047" || c == "\"") { q = c; seg = seg c; continue }
        if (c == "`") { seg = seg c; i++; while (i <= n && substr(s, i, 1) != "`") { seg = seg substr(s, i, 1); i++ } seg = seg "`"; continue }
        if (c == "$" && nx == "(") { depth++; seg = seg c nx; i++; continue }
        if (depth > 0) { if (c == "(") depth++; else if (c == ")") depth--; seg = seg c; continue }
        if (c == ";") { emit(seg); seg = ""; kind = "S"; if (nx == ";") i++; prev = ";"; continue }
        if (c == "&" && nx == "&") { emit(seg); seg = ""; kind = "A"; i++; prev = "&"; continue }
        if (c == "|" && nx == "|") { emit(seg); seg = ""; kind = "O"; i++; prev = "|"; continue }
        if (c == "|" && prev != ">") { emit(seg); seg = ""; kind = "P"; if (nx == "&") i++; prev = "|"; continue }
        if (c == "&" && prev != ">" && prev != "<" && nx != ">" && nx != "-" && nx !~ /[0-9]/) { emit(seg); seg = ""; kind = "B"; prev = "&"; continue }
        seg = seg c
        if (c != " " && c != "\t") prev = c
      }
      if (q == "" && depth == 0) { emit(seg); seg = "" }
    }
    END { if (seg != "") emit(seg) }
  '
}
# `$(…)` とバッククォートの本文を 1 行 1 件で取り出す（入れ子は外側だけ）
ws_extract_substs() { # <区間>
  printf '%s\n' "$1" | LC_ALL=C awk '
    {
      s = $0; n = length(s); depth = 0; body = ""; q = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); nx = substr(s, i + 1, 1)
        if (depth == 0) {
          if (c == "\\") { i++; continue }
          if (c == "\047" && q == "") { q = c; continue }
          if (c == "\047" && q == c) { q = ""; continue }
          if (q != "") continue
          if (c == "$" && nx == "(") { depth = 1; body = ""; i++; continue }
          if (c == "`") { body = ""; i++; while (i <= n && substr(s, i, 1) != "`") { body = body substr(s, i, 1); i++ } print body; continue }
          continue
        }
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) { print body; continue } }
        body = body c
      }
    }
  '
}

# ---- インタプリタ ---------------------------------------------------------------------
# プログラム本文の書き込みマーカー（言語別。ヒューリスティック）
ws_marker_re() { # <lang> → 正規表現を stdout
  case "$1" in
    python*)
      printf '%s' 'open\([^)]*["'"'"'][^"'"'"']*[wax+]["'"'"']|open\([^)]*mode *= *["'"'"'][^"'"'"']*[wax+]|write_text\(|write_bytes\(|os\.(remove|unlink|rename|renames|replace|makedirs|mkdir|rmdir|removedirs|truncate|chmod|chown|symlink|link)\(|shutil\.|\.(unlink|rename|replace|touch|mkdir|rmdir|symlink_to|hardlink_to)\(|fileinput\.input\([^)]*inplace|subprocess\.|os\.system\(|os\.popen\(|os\.exec|\.to_(csv|json|excel|parquet)\(|savefig\(|pickle\.dump\(' ;;
    node)
      printf '%s' '(writeFile|appendFile|createWriteStream|copyFile|unlink|rm|rmdir|mkdir|rename|truncate|chmod|cp)(Sync)?\(|child_process|execSync\(|spawn(Sync)?\(|outputFile' ;;
    perl)
      printf '%s' 'open *\(? *[^,]+, *["'"'"']? *(>|>>|\+<)|unlink|rename|mkdir|rmdir|system *\(|`' ;;
    ruby)
      printf '%s' 'File\.(write|open\([^)]*["'"'"'][wa]|delete|unlink|rename|truncate)|FileUtils\.|IO\.write|Dir\.(mkdir|rmdir)|system *\(|`' ;;
    awk | gawk)
      printf '%s' '>>? *"|>>? *[A-Za-z_]|system\(' ;;
    *) return 1 ;;
  esac
}
# マーカー行を全部返す。rc 0 = あり / 1 = なし / 2 = 走査失敗
ws_marker_lines() { # <lang> <program>
  local re out rc
  re="$(ws_marker_re "$1")" || return 1
  out="$(printf '%s\n' "$2" | LC_ALL=C "${FF_WRITE_SCAN_GREP:-grep}" -E -- "$re" 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$out"; return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}
# 文字列の先頭にあるパスリテラル（"…" / '…'。先頭に引用符が無ければ空）
ws_leading_literal() { # <text>
  printf '%s\n' "$1" | LC_ALL=C sed -n 's/^[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*$/\1/p' | head -n 1
}
# 文字列の末尾側にあるパスリテラル（`Path("a")` の "a"。末尾に `)` `.` が続く形）
ws_trailing_literal() { # <text>
  printf '%s\n' "$1" | LC_ALL=C sed -n 's/^.*["'"'"']\([^"'"'"']*\)["'"'"'][^"'"'"']*$/\1/p' | head -n 1
}
# 本文を判定する。<hb> <lang> <program> <src> <depth>
ws_judge_program() {
  local hb="$1" lang="$2" prog="$3" src="$4" depth="$5" line lit marker rc
  if [ "$lang" = "sh" ]; then
    if [ "$depth" -ge 2 ]; then
      undeterminable "入れ子のシェル実行が深すぎる（${hb}）"
      return 0
    fi
    ws_scan_nested "$prog" $((depth + 1))
    return $?
  fi
  local lines re rest before after
  lines="$(ws_marker_lines "$lang" "$prog")"
  rc=$?
  case "$rc" in
    1) return 1 ;;
    2) undeterminable "書き込みマーカーの走査（grep）に失敗"; return 0 ;;
  esac
  re="$(ws_marker_re "$lang")"
  # マーカー行ごと・マーカーごとに書き込み先を判定する（最初の 1 つで許可しない）。
  # 関数形（`open(` / `os.remove(` / `writeFileSync(`）は `(` の直後のリテラル、メソッド形
  # （`Path("a").write_text(`）は手前のリテラルを対象にする。対象がリテラルでなければ判定不能
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rest="$line"
    while :; do
      marker="$(printf '%s' "$rest" | LC_ALL=C "${FF_WRITE_SCAN_GREP:-grep}" -Eo -- "$re" 2>/dev/null | head -n 1)"
      [ -n "$marker" ] || break
      before="${rest%%"$marker"*}"
      after="${rest#*"$marker"}"
      case "$marker" in
        subprocess.* | os.system\(* | os.popen\(* | os.exec* | child_process* | execSync\(* | spawn* | system* | \`* | shutil.* | FileUtils.* | fileinput.*)
          undeterminable "任意コマンド起動・対象を特定できないユーティリティを使う ${hb} プログラム（${marker}。${src}）"
          return 0
          ;;
        .* | write_text\(* | write_bytes\(*) lit="$(ws_trailing_literal "$before")" ;;
        open\(*) lit="$(ws_leading_literal "${marker#open(}")" ;;
        \>*\") lit="${after%%\"*}" ;;   # awk `print > "file"`
        \>*) lit="" ;;                    # awk `print > var`
        *\() lit="$(ws_leading_literal "$after")" ;;
        *) lit="" ;;
      esac
      if [ -z "$lit" ]; then
        undeterminable "${hb} プログラムの書き込み先がリテラルではない（${marker}。${src}）"
        return 0
      fi
      judge_target "$lit" "${hb} プログラムの ${marker}（${src}）" && return 0
      rest="$after"
    done
  done <<EOF
$lines
EOF
  return 1
}
# インタプリタ区間: 本文を取り、判定する。<basename> <生の区間> <深さ> <args...>
judge_interpreter() {
  local hb="$1" raw="$2" depth="$3" a prog="" src="" valued script lang has_heredoc=0 stdin_file="" skip=0 nonopt=0
  shift 3
  lang="$hb"
  case "$hb" in
    bash | sh | zsh | ksh | dash | source | .) lang="sh" ;;
  esac
  # 入力リダイレクトを引数から取り除く: `<<WORD`（heredoc = stdin プログラム）/ `<<<`（here-string
  # = インライン本文）/ `< file`（= script ファイル）。opener の語を script と誤認しない。
  set -- "$@" --ff-end--
  while [ "$1" != "--ff-end--" ]; do
    a="$1"
    shift
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
      '<<<') [ "$1" != "--ff-end--" ] && { prog="$(unquote1 "$1")"; src="here-string"; skip=1; } ;;
      '<<<'*) prog="$(unquote1 "${a#<<<}")"; src="here-string" ;;
      '<<' | '<<-') has_heredoc=1; skip=1 ;;
      '<<'*) has_heredoc=1 ;;
      '<') [ "$1" != "--ff-end--" ] && { stdin_file="$1"; skip=1; } ;;
      '<'*) stdin_file="${a#<}" ;;
      *) set -- "$@" "$a" ;;
    esac
  done
  shift
  # 1) インライン本文（-c / -e / -p / --eval / --print）は生の区間から引用符ごと取る
  if [ -z "$src" ]; then
    for a in "$@"; do
      case "$lang:$a" in
        sh:-c | python*:-c | node:-e | node:--eval | node:-p | node:--print | perl:-e | perl:-E | ruby:-e | awk:-e | gawk:-e | \
        sh:-[a-zA-Z]*c | python*:-[a-zA-Z]*c | perl:-[a-zA-Z]*[eE] | ruby:-[a-zA-Z]*e)
          prog="${raw#*"$a"}"
          prog="$(ws_trim "$prog")"
          case "$prog" in
            \"*) prog="${prog#\"}"; prog="${prog%\"*}" ;;
            \'*) prog="${prog#\'}"; prog="${prog%\'*}" ;;
            *) prog="${prog%% *}" ;;
          esac
          src="inline"
          break
          ;;
      esac
    done
  fi
  # awk はプログラムが第 1 非オプション引数（引用符ごと生の区間から取る）
  if [ -z "$src" ] && { [ "$hb" = "awk" ] || [ "$hb" = "gawk" ]; }; then
    for a in "$@"; do
      case "$a" in
        -i | --in-place | -i*) undeterminable "awk の in-place 編集（${a}）"; return 0 ;;
      esac
    done
    prog="${raw#*"$hb"}"
    prog="$(ws_trim "$prog")"
    while :; do
      case "$prog" in
        -v\ * | -F\ * | -f\ *) prog="${prog#* }"; prog="${prog#* }"; prog="$(ws_trim "$prog")" ;;
        -[!\ ]*\ *) prog="${prog#* }"; prog="$(ws_trim "$prog")" ;;
        *) break ;;
      esac
    done
    case "$prog" in
      \"*) prog="${prog#\"}"; prog="${prog%%\"*}" ;;
      \'*) prog="${prog#\'}"; prog="${prog%%\'*}" ;;
      *) prog="${prog%% *}" ;;
    esac
    [ -n "$prog" ] || return 1
    src="inline"
  fi
  if [ -z "$src" ] && [ -n "$stdin_file" ]; then
    if resolve_target "$stdin_file" && [ -f "$RESOLVED" ] && [ -r "$RESOLVED" ]; then
      prog="$(LC_ALL=C head -c 262144 "$RESOLVED" 2>/dev/null)"
      src="file"
    else
      undeterminable "stdin のファイルを読めない（${hb} < ${stdin_file}）"
      return 0
    fi
  fi
  if [ -z "$src" ]; then
    case "$lang" in
      python*) valued="-m -W -X -Q --check-hash-based-pycs" ;;
      node) valued="-r --require --input-type --loader --import" ;;
      perl) valued="-e -E -M -I -m" ;;
      ruby) valued="-e -r -I -E -C -x" ;;
      sh) valued="-o -O" ;;
    esac
    for a in "$@"; do
      case "$lang:$a" in
        python*:-m) undeterminable "モジュール実行（${hb} -m）は本文を取れない"; return 0 ;;
        *:--version | *:-V | *:--help | *:-h | *:-version) return 1 ;;
      esac
    done
    collect_nonopts "$valued" "$@"
    nonopt="${#NONOPTS[@]}"
    if [ "$nonopt" -eq 0 ] || [ "${NONOPTS[0]}" = "-" ]; then
      if [ "$has_heredoc" -eq 1 ]; then
        [ "$HEREDOC_STATE" = "ok" ] || { undeterminable "heredoc を解析できない（${HEREDOC_STATE}）"; return 0; }
        prog="$HEREDOC_BODIES"
        src="heredoc"
      else
        undeterminable "stdin から読むプログラム（${hb}。本文が無い）"
        return 0
      fi
    else
      script="${NONOPTS[0]}"
      if ! resolve_target "$script"; then
        undeterminable "スクリプトのパスを解決できない（${RESOLVE_WHY}: ${script}）"
        return 0
      fi
      if [ -f "$RESOLVED" ] && [ -r "$RESOLVED" ]; then
        prog="$(LC_ALL=C head -c 262144 "$RESOLVED" 2>/dev/null)"
        src="file"
      else
        undeterminable "スクリプトを読めない（${RESOLVED}）"
        return 0
      fi
    fi
  fi
  case "$prog" in
    '$'* | '`'*) undeterminable "${hb} の本文が変数展開・コマンド置換（${src}）"; return 0 ;;
  esac
  ws_judge_program "$hb" "$lang" "$prog" "$src" "$depth"
}

# ---- 1 区間 ----------------------------------------------------------------------------
# <区間> <深さ> → 0 = hit
scan_segment() {
  local seg="$1" depth="$2" toks n i tok t target inq hb head seg_override=0 a body
  set -f
  # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
  toks=($seg)
  set +f
  n=${#toks[@]}
  [ "$n" -gt 0 ] || return 1
  # a) `$(…)` / バッククォートの本文はサブシェルとして先に走査する
  while IFS= read -r body; do
    [ -n "$body" ] || continue
    if ws_scan_nested "$body" $((depth + 1)); then return 0; fi
  done <<EOF
$(ws_extract_substs "$seg")
EOF
  # b) 前置き（グループ括弧・制御語・環境代入・ラッパ）を剥がし、区間先頭の override を確定する
  while [ "$n" -gt 0 ]; do
    case "${toks[$((n - 1))]}" in
      ')' | '}' | ';' | '&' | ';;' | 'fi' | 'done' | 'esac') n=$((n - 1)) ;;
      *) break ;;
    esac
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in
      '(' | '{' | '&' | '!' | do | then | else | elif | if | while | until | time | exec | builtin | env | command | sudo | nohup) i=$((i + 1)) ;;
      case)
        # `case x in pat) cmd` — パターン（`)` で終わる語）までを読み飛ばす
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in *')') i=$((i + 1)); break ;; *) i=$((i + 1)) ;; esac
        done
        ;;
      *')') i=$((i + 1)) ;; # case のパターン（`x)`）
      FF_REVIEW_LOCK_OVERRIDE=1) seg_override=1; i=$((i + 1)) ;;
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  WRITE_OVERRIDE="$seg_override"
  # c) リダイレクト（区間のどこにあっても書き込み）。引用文字列の内側は飛ばす
  inq=""
  t=0
  while [ "$t" -lt "$n" ]; do
    tok="${toks[$t]}"
    t=$((t + 1))
    if [ -n "$inq" ]; then
      case "$tok" in *"$inq") inq="" ;; esac
      continue
    fi
    case "$tok" in
      \'*\' | \"*\") continue ;;
      \'?*) inq="'"; continue ;;
      \"?*) inq='"'; continue ;;
      '>(' | '>('*) undeterminable "プロセス置換への書き込み（>(…)）"; return 0 ;;
      '>' | '>>' | '>|' | '&>' | '&>>' | [0-9]'>' | [0-9]'>>' | [0-9]'>|')
        [ "$t" -lt "$n" ] || continue
        target="${toks[$t]}"
        t=$((t + 1))
        case "$target" in '&'*) continue ;; esac # `> &2` 形の fd 複製
        judge_target "$target" "リダイレクト ${tok}" && return 0
        ;;
      '>&'* | [0-9]'>&'* | '&>&'*) : ;; # fd 複製・閉鎖
      '>'\"* | '>'\'* | '>>'\"* | '>>'\'* | [0-9]'>'\"* | [0-9]'>'\'* | '&>'\"* | '&>'\'*)
        # 引用符付きの密着形（`>"README.md"`）
        t="${tok#[0-9]}"
        t="${t#&}"
        t="${t#>}"
        t="${t#>}"
        judge_target "$t" "リダイレクト >" && return 0
        ;;
      *\"* | *\'*) : ;; # 引用符を含む語（`"a>b"` 等）は判定しない
      *'>'*)
        # 密着形: `>file` / `2>file` / `&>file` / `hi>file`（語の途中の `>` も同じ）
        a="${tok%%>*}"
        target="${tok#"$a">}"
        target="${target#>}"
        target="${target#|}"
        case "$target" in
          '' | '&'*) : ;;
          *) judge_target "$target" "リダイレクト >" && return 0 ;;
        esac
        ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1
  head="${toks[$i]}"
  hb="${head##*/}"
  i=$((i + 1))
  # 引数からは出力リダイレクトの語（判定済み）を除く。`tee OUT >/dev/null` の `>/dev/null` を
  # 書き込み先と誤認しない。`<` 系はインタプリタが stdin として読むので残す
  set --
  while [ "$i" -lt "$n" ]; do
    tok="${toks[$i]}"
    i=$((i + 1))
    case "$tok" in
      '>' | '>>' | '>|' | '&>' | '&>>' | [0-9]'>' | [0-9]'>>' | [0-9]'>|') i=$((i + 1)); continue ;;
      '*' | "*") : ;;
      '>'* | '&>'* | [0-9]'>'*) continue ;;
    esac
    set -- "$@" "$tok"
  done
  case "$hb" in
    cd)
      if [ "$#" -eq 0 ] || [ "$1" = "-" ]; then WRITE_BASE=""; return 1; fi
      a="$1"
      case "$a" in -*) shift; a="${1:-}" ;; esac
      if [ -n "$a" ] && resolve_target "$a"; then WRITE_BASE="$RESOLVED"; else WRITE_BASE=""; fi
      return 1
      ;;
    pushd | popd) WRITE_BASE=""; return 1 ;;
    eval) undeterminable "eval は本文を静的に取れない"; return 0 ;;
    git)
      # 別リポジトリ指定（-C）は git 走査の担当。ここでは cwd のリポジトリへの書き込み系だけ
      for a in "$@"; do case "$a" in -C | --git-dir* | --work-tree*) return 1 ;; esac; done
      collect_nonopts "-c --namespace --exec-path" "$@"
      [ "${#NONOPTS[@]}" -gt 0 ] || return 1
      case "${NONOPTS[0]}" in
        rm | mv | clean | commit | rebase | checkout | switch | merge | reset | apply | cherry-pick | revert | am | pull)
          [ -n "$WRITE_BASE" ] || { undeterminable "git ${NONOPTS[0]}（cd 先が不明）"; return 0; }
          if target_in_tree "$WRITE_BASE"; then
            WRITE_HIT=1
            WRITE_REASON="作業ツリー内へ書き込みます: ${WRITE_BASE}（git ${NONOPTS[0]}）"
            return 0
          fi
          ;;
      esac
      return 1
      ;;
    tee)
      collect_nonopts "" "$@"
      for a in "${NONOPTS[@]+"${NONOPTS[@]}"}"; do
        [ "$a" = "-" ] && continue
        judge_target "$a" "tee" && return 0
      done
      return 1
      ;;
    sed | gsed)
      local inplace=0 has_script_opt=0 first=1
      for a in "$@"; do
        case "$a" in
          --in-place*) inplace=1 ;;
          -e | -f | --expression | --file | --expression=* | --file=*) has_script_opt=1 ;;
          --*) : ;;
          -*i*) inplace=1 ;;
        esac
      done
      [ "$inplace" -eq 1 ] || return 1
      collect_nonopts "-e -f --expression --file" "$@"
      for a in "${NONOPTS[@]+"${NONOPTS[@]}"}"; do
        case "$a" in "''" | '""') continue ;; esac
        if [ "$has_script_opt" -eq 0 ] && [ "$first" -eq 1 ]; then first=0; continue; fi
        first=0
        judge_target "$a" "sed -i" && return 0
      done
      return 1
      ;;
    perl)
      local pinplace=0 cl
      for a in "$@"; do
        case "$a" in
          --* | -M* | -I* | -m*) : ;;
          -*)
            # 短いクラスタ（`-pi` / `-i.bak` / `-ni`）に `i` を含むときだけ in-place
            cl="${a#-}"
            cl="${cl%%.*}"
            case "$cl" in *i*) pinplace=1 ;; esac
            ;;
        esac
      done
      if [ "$pinplace" -eq 1 ]; then
        collect_nonopts "-e -E -M -I -m" "$@"
        for a in "${NONOPTS[@]+"${NONOPTS[@]}"}"; do
          judge_target "$a" "perl -i" && return 0
        done
      fi
      judge_interpreter "$hb" "$seg" "$depth" "$@"
      return $?
      ;;
    cp | install | ln | rsync | scp)
      local dest="" valued=""
      case "$hb" in
        install) valued="-m -o -g -t --target-directory" ;;
        ln) valued="-t --target-directory" ;;
        rsync) valued="-e --rsh" ;;
        cp) valued="-t --target-directory" ;;
      esac
      dest="$(opt_value -t "$@")" || dest="$(opt_value --target-directory "$@")" || dest=""
      if [ -n "$dest" ]; then judge_target "$dest" "$hb" && return 0; return 1; fi
      collect_nonopts "$valued" "$@"
      [ "${#NONOPTS[@]}" -ge 2 ] || { undeterminable "${hb} の書き込み先が無い"; return 0; }
      judge_target "${NONOPTS[$((${#NONOPTS[@]} - 1))]}" "$hb" && return 0
      return 1
      ;;
    mv)
      local dest=""
      dest="$(opt_value -t "$@")" || dest="$(opt_value --target-directory "$@")" || dest=""
      [ -n "$dest" ] && judge_target "$dest" "mv" && return 0
      collect_nonopts "-t --target-directory" "$@"
      for a in "${NONOPTS[@]+"${NONOPTS[@]}"}"; do
        judge_target "$a" "mv（移動元も作業ツリーの変更）" && return 0
      done
      return 1
      ;;
    rm | rmdir | unlink | shred | mkdir | touch | truncate | mkfifo | chmod | chown | chgrp | gzip | gunzip | bzip2 | bunzip2 | xz | unxz | zstd)
      local valued="" skip1=0
      case "$hb" in
        touch) valued="-t -r -d --reference --date" ;;
        truncate) valued="-s -r --size --reference" ;;
        mkdir) valued="-m --mode" ;;
        chown | chgrp) valued="--reference"; skip1=1 ;;
        chmod) skip1=1 ;;
        gzip | gunzip | bzip2 | bunzip2 | xz | unxz | zstd)
          for a in "$@"; do case "$a" in -c | --stdout | -t | --test | -l | --list) return 1 ;; esac; done
          ;;
      esac
      collect_nonopts "$valued" "$@"
      for a in "${NONOPTS[@]+"${NONOPTS[@]}"}"; do
        if [ "$skip1" -eq 1 ]; then skip1=0; continue; fi
        judge_target "$a" "$hb" && return 0
      done
      return 1
      ;;
    patch)
      local pdir=""
      pdir="$(opt_value -d "$@")" || pdir="$(opt_value --directory "$@")" || pdir=""
      [ -n "$pdir" ] || pdir="."
      judge_target "$pdir" "patch" && return 0
      return 1
      ;;
    sort)
      local out=""
      out="$(opt_value -o "$@")" || out="$(opt_value --output "$@")" || out=""
      [ -n "$out" ] && judge_target "$out" "sort -o" && return 0
      return 1
      ;;
    sponge)
      collect_nonopts "" "$@"
      for a in "${NONOPTS[@]+"${NONOPTS[@]}"}"; do judge_target "$a" "sponge" && return 0; done
      return 1
      ;;
    dd)
      for a in "$@"; do
        case "$a" in of=*) judge_target "${a#of=}" "dd of=" && return 0 ;; esac
      done
      return 1
      ;;
    mktemp)
      local tdir=""
      tdir="$(opt_value -p "$@")" || tdir="$(opt_value --tmpdir "$@")" || tdir=""
      if [ -n "$tdir" ]; then judge_target "$tdir" "mktemp -p" && return 0; return 1; fi
      collect_nonopts "-p --tmpdir" "$@"
      [ "${#NONOPTS[@]}" -gt 0 ] || return 1
      case "${NONOPTS[0]}" in
        */*) judge_target "${NONOPTS[0]%/*}" "mktemp" && return 0 ;;
        *) : ;; # TMPDIR 配下
      esac
      return 1
      ;;
    tar)
      local mode="" tdir="" tfile="" prevf=0 first=1 cl
      # フラグは先頭クラスタ（`xf`）でも `-`/`--` 付き（どの位置でも）でも読む。`f` を含む
      # クラスタの直後の引数がアーカイブ名
      for a in "$@"; do
        if [ "$prevf" -eq 1 ]; then tfile="$a"; prevf=0; first=0; continue; fi
        case "$a" in
          --extract | --get) mode="x" ;;
          --create | --append | --update) mode="c" ;;
          --file=*) tfile="${a#--file=}" ;;
          --file) prevf=1 ;;
          --*) : ;;
          -*)
            cl="${a#-}"
            case "$cl" in *x*) mode="x" ;; *c* | *r* | *u*) mode="c" ;; esac
            case "$cl" in *f) prevf=1 ;; esac
            ;;
          *)
            if [ "$first" -eq 1 ]; then
              cl="$a"
              case "$cl" in *x*) mode="x" ;; *c* | *r* | *u*) mode="c" ;; esac
              case "$cl" in *f*) prevf=1 ;; esac
            fi
            ;;
        esac
        first=0
      done
      case "$mode" in
        x)
          tdir="$(opt_value -C "$@")" || tdir="$(opt_value --directory "$@")" || tdir="."
          judge_target "$tdir" "tar -x" && return 0
          ;;
        c)
          [ -n "$tfile" ] && [ "$tfile" != "-" ] && judge_target "$tfile" "tar -c" && return 0
          ;;
      esac
      return 1
      ;;
    zip)
      collect_nonopts "" "$@"
      [ "${#NONOPTS[@]}" -gt 0 ] || return 1
      judge_target "${NONOPTS[0]}" "zip" && return 0
      return 1
      ;;
    unzip)
      local tdir=""
      tdir="$(opt_value -d "$@")" || tdir="."
      for a in "$@"; do case "$a" in -l | -t | -Z | -p | -c) return 1 ;; esac; done
      judge_target "$tdir" "unzip" && return 0
      return 1
      ;;
    curl)
      local out="" prevo=0
      out="$(opt_value --output "$@")" || out=""
      for a in "$@"; do
        if [ "$prevo" -eq 1 ]; then out="$a"; prevo=0; continue; fi
        case "$a" in
          --remote-name | --remote-header-name) judge_target "." "curl -O" && return 0 ;;
          --*) : ;;
          -*o) prevo=1 ;;            # `-o FILE` / `-sSLo FILE`
          -*O* | -*J*) judge_target "." "curl -O" && return 0 ;; # `-O` / `-sO`
        esac
      done
      if [ -n "$out" ]; then judge_target "$out" "curl -o" && return 0; fi
      return 1
      ;;
    wget)
      local out=""
      out="$(opt_value -O "$@")" || out="$(opt_value --output-document "$@")" || out=""
      if [ -n "$out" ]; then judge_target "$out" "wget -O" && return 0; return 1; fi
      out="$(opt_value -P "$@")" || out="$(opt_value --directory-prefix "$@")" || out="."
      for a in "$@"; do case "$a" in --spider) return 1 ;; esac; done
      judge_target "$out" "wget" && return 0
      return 1
      ;;
    find)
      local writes=0 nxt="" starts=0 j
      j=1
      while [ "$j" -le "$#" ]; do
        eval "a=\${$j}"
        case "$a" in
          -delete) writes=1 ;;
          -exec | -execdir | -ok | -okdir)
            eval "nxt=\${$((j + 1)):-}"
            nxt="${nxt##*/}"
            if is_write_head "$nxt" || is_interp_head "$nxt"; then writes=1; fi
            ;;
        esac
        j=$((j + 1))
      done
      [ "$writes" -eq 1 ] || return 1
      for a in "$@"; do
        case "$a" in
          -* | '(' | '!') break ;;
          *) starts=1; judge_target "$a" "find（-delete / -exec）" && return 0 ;;
        esac
      done
      [ "$starts" -eq 1 ] || { judge_target "." "find（-delete / -exec）" && return 0; }
      return 1
      ;;
    xargs)
      local wrapped=""
      collect_nonopts "-I -i -n -P -L -s -d -a -E" "$@"
      [ "${#NONOPTS[@]}" -gt 0 ] && wrapped="${NONOPTS[0]##*/}"
      if [ -n "$wrapped" ] && { is_write_head "$wrapped" || is_interp_head "$wrapped"; }; then
        undeterminable "xargs 経由の ${wrapped}（対象は stdin から来る）"
        return 0
      fi
      return 1
      ;;
  esac
  if is_interp_head "$hb"; then
    judge_interpreter "$hb" "$seg" "$depth" "$@"
    return $?
  fi
  # `./patch.sh` / `/abs/x.py` の直接実行: 読める通常ファイルなら shebang（無ければ拡張子）で
  # 言語を決め、本文をインタプリタと同じ規則で判定する。読めなければ判定不能
  case "$head" in
    */*)
      local shebang="" lang2="sh"
      if resolve_target "$head" && [ -f "$RESOLVED" ] && [ -r "$RESOLVED" ]; then
        shebang="$(LC_ALL=C head -n 1 "$RESOLVED" 2>/dev/null)"
        case "$shebang" in
          '#!'*python*) lang2="python3" ;;
          '#!'*node*) lang2="node" ;;
          '#!'*perl*) lang2="perl" ;;
          '#!'*ruby*) lang2="ruby" ;;
          '#!'*awk*) lang2="awk" ;;
          '#!'*) lang2="sh" ;;
          *)
            case "$head" in
              *.py) lang2="python3" ;; *.js | *.mjs | *.cjs) lang2="node" ;; *.pl) lang2="perl" ;; *.rb) lang2="ruby" ;; *.awk) lang2="awk" ;;
            esac
            ;;
        esac
        ws_judge_program "$hb" "$lang2" "$(LC_ALL=C head -c 262144 "$RESOLVED" 2>/dev/null)" "file" "$depth"
        return $?
      fi
      case "$head" in
        ./* | ../* | /*) undeterminable "直接実行するスクリプトを読めない（${head}）"; return 0 ;;
      esac
      ;;
  esac
  return 1
}

# ---- コマンド全体 -----------------------------------------------------------------------
# 入れ子（`bash -c '…'` / sh の heredoc 本文 / `$(…)`）は自分で heredoc を落とし、cd と変数の
# 状態を親へ漏らさない。<生の本文> <深さ> → 0 = hit
ws_scan_nested() {
  local raw="$1" depth="$2" code rc base_saved vars_saved state_saved bodies_saved sub_saved
  base_saved="$WRITE_BASE"; vars_saved="$VAR_TABLE"; sub_saved="$WS_SUB_DEPTH"
  state_saved="$HEREDOC_STATE"; bodies_saved="$HEREDOC_BODIES"
  if [ "$(type -t ff_heredoc_strip 2>/dev/null)" = "function" ]; then
    code="$(ff_heredoc_strip "$raw")"
    rc=$?
    case "$rc" in
      0) HEREDOC_STATE=ok; HEREDOC_BODIES="$(ff_heredoc_bodies "$raw" 2>/dev/null)" || HEREDOC_BODIES="" ;;
      3) HEREDOC_STATE=unterminated; code="$raw" ;;
      *) HEREDOC_STATE=unavailable; code="$raw" ;;
    esac
  else
    HEREDOC_STATE=unavailable
    code="$raw"
  fi
  WS_SUB_DEPTH=0
  ws_scan_code "$code" "$depth"
  rc=$?
  WRITE_BASE="$base_saved"; VAR_TABLE="$vars_saved"; WS_SUB_DEPTH="$sub_saved"
  HEREDOC_STATE="$state_saved"; HEREDOC_BODIES="$bodies_saved"
  return $rc
}
ws_scan_code() { # <heredoc 除去後の本文> <深さ> → 0 = hit
  local code="$1" depth="$2" segs seg rc=1 trimmed opened=0
  if [ "$HEREDOC_STATE" != "ok" ]; then
    case "$HEREDOC_STATE" in
      unterminated) undeterminable "heredoc が終端していない（引用符・算術式の中の << を含む可能性）" ;;
      *) undeterminable "heredoc 除去ヘルパを使えない（tests/lib/heredoc-strip.sh）" ;;
    esac
    return 0
  fi
  local kind base_before vars_before override_hit=0 prev_base="$WRITE_BASE" prev_vars="$VAR_TABLE"
  segs="$(ws_split_segments "$code")"
  while IFS= read -r -d "$WS_RS" seg || [ -n "$seg" ]; do
    kind="${seg%%[!NSAOPB]*}"
    kind="${kind:0:1}"
    seg="${seg#?}"
    trimmed="$(ws_trim "$seg")"
    [ -n "$trimmed" ] || continue
    if [ "$kind" = "B" ]; then
      # 直前の区間は `&` で background に投げられた = サブシェル。その cd と代入は親へ漏れない
      WRITE_BASE="$prev_base"
      VAR_TABLE="$prev_vars"
    fi
    prev_base="$WRITE_BASE"
    prev_vars="$VAR_TABLE"
    base_before="$WRITE_BASE"
    vars_before="$VAR_TABLE"
    # サブシェル `( … )` の cd / 代入は親へ漏らさない（開きで保存し、閉じで復元する）
    opened=0
    case "$trimmed" in
      '('*)
        if [ "$WS_SUB_DEPTH" -eq 0 ]; then WS_SUB_BASE="$WRITE_BASE"; WS_SUB_VARS="$VAR_TABLE"; fi
        WS_SUB_DEPTH=$((WS_SUB_DEPTH + 1))
        opened=1
        ;;
    esac
    if ! record_assignment "$trimmed"; then
      if scan_segment "$trimmed" "$depth"; then
        # 区間先頭の override が付いた書き込みは通す（その区間だけ）。走査は続け、
        # override の無い書き込みが後ろにあれば止める
        if [ "${WRITE_OVERRIDE:-0}" -eq 1 ]; then
          override_hit=1
          WRITE_HIT=0
          WRITE_REASON=""
        else
          rc=0
          break
        fi
      fi
    fi
    # パイプ（`x | cd d`）・background（`cd d &`）の区間はサブシェルで走るので cd と代入は親へ
    # 漏れない。`&&` / `||` で繋いだ区間の cd は条件付き（実行されないことがある）なので、
    # 動いた基準は「不明」へ倒す（以後の相対パスは判定不能 = deny 側）
    case "$kind" in
      P) WRITE_BASE="$base_before"; VAR_TABLE="$vars_before" ;;
      A | O) [ "$WRITE_BASE" = "$base_before" ] || WRITE_BASE="" ;;
    esac
    case "$trimmed" in
      *')' | *');;' | *') ;;')
        if [ "$WS_SUB_DEPTH" -gt 0 ]; then
          case "$trimmed" in
            *')')
              WS_SUB_DEPTH=$((WS_SUB_DEPTH - 1))
              [ "$WS_SUB_DEPTH" -eq 0 ] && { WRITE_BASE="$WS_SUB_BASE"; VAR_TABLE="$WS_SUB_VARS"; }
              ;;
          esac
        fi
        ;;
    esac
  done <<EOF
$segs
EOF
  if [ "$rc" -ne 0 ] && [ "$override_hit" -eq 1 ]; then
    WRITE_HIT=1
    WRITE_OVERRIDE=1
    WRITE_REASON="override 付きの書き込み（区間先頭の FF_REVIEW_LOCK_OVERRIDE=1）"
    return 0
  fi
  return $rc
}
ff_write_scan() { # <生コマンド> <HEREDOC_STATE> <HEREDOC_CODE> <HEREDOC_BODIES> → 0 = hit
  WRITE_HIT=0
  WRITE_REASON=""
  WRITE_OVERRIDE=0
  HEREDOC_STATE="$2"
  HEREDOC_CODE="$3"
  HEREDOC_BODIES="$4"
  WS_SUB_DEPTH=0
  ws_scan_code "$HEREDOC_CODE" 0
}
