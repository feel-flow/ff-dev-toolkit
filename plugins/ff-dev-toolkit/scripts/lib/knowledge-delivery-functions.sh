#!/usr/bin/env bash
# 知見の反映先（ADR-083・Issue `#2690`）。bash 3.2 互換。使う外部コマンドは git・awk・date・mv・rm。
#
# 反映のモードは base にコミットした `docs/08-knowledge/knowledge-delivery.conf` で決まる（無ければ
# マージごと = 既定）。環境変数では切り替えない — セッションごとにモードが違うと、base へ直接書く
# セッションと知見専用ブランチ（staging）へ書くセッションが混ざり、並行更新の直列化点が 2 つに割れる。
#
#   mode=per-merge|batch          既定 per-merge
#   staging_branch=<branch>       既定 knowledge/staging（batch で知見を書き込むブランチ）
#   warn_after_days=<1..9999>     既定 7（未反映の最古がこの日数に達したら警告する）
#
# 「まとめて」で書き込む回は、`finish.sh knowledge-commit target`（probe も先に同じ処理をする）が
# 書き込みの起点へ HEAD を移し、その記録を git ディレクトリ（worktree ごと）の `ff-knowledge-target`
# へ置く。add / push / discard はこの記録を読む。
#
# source する側: finish.sh knowledge-commit（lib/finish-knowledge-commit-functions.sh の kc_load_batch）・
# knowledge-commit.sh・knowledge-lookup.sh（lib/knowledge-lookup-unreflected.sh 経由）。
# 結果は KD_* の変数へ入れ、値を返す関数（ff_kd_state_path / ff_kd_paths_outside）だけが stdout を使う。
# 呼び出し側の出力契約に載る行は出さない。

KD_CONF_REL="docs/08-knowledge/knowledge-delivery.conf"
KD_DEFAULT_STAGING="knowledge/staging"
KD_DEFAULT_WARN_DAYS=7
KD_FLUSH_PREFIX="knowledge/flush-"
KD_STATE_NAME="ff-knowledge-target"

ff_kd_reset() {
  KD_MODE="per-merge"
  KD_STAGING="$KD_DEFAULT_STAGING"
  KD_WARN_DAYS="$KD_DEFAULT_WARN_DAYS"
  KD_CONF_PRESENT=0
  KD_SOURCE=""
}

ff_kd_trim() { # <文字列> → KD_TRIMMED
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  KD_TRIMMED="$s"
}

# 知見専用ブランチの名前として使えるか。default branch と同名・既存の知見ブランチの命名
# （chore/ace-from-* は /ace-curate が既存の知見ブランチとして扱い、ace-from-pr-N は件名の Issue 解決に
# 使われる）・flush 用の使い捨てブランチの命名と重なるものは採らない。
ff_kd_valid_staging() { # <branch> <default branch or empty> → 0 / 1（理由は KD_REASON）
  local name="$1" default="${2:-}" normalized=""
  KD_REASON=""
  case "$name" in
    ''|-*|HEAD|*' '*) KD_REASON="ブランチ名として使えない: '${name}'"; return 1 ;;
  esac
  normalized="$(git check-ref-format --branch "$name" 2>/dev/null)" || normalized=""
  if [ "$normalized" != "$name" ]; then KD_REASON="ブランチ名として使えない: '${name}'"; return 1; fi
  if [ -n "$default" ] && [ "$name" = "$default" ]; then KD_REASON="default branch（${default}）と同じ名前は使えない"; return 1; fi
  case "$name" in
    chore/ace-from-*|chore/retro-from-*|*ace-from-pr-*|"${KD_FLUSH_PREFIX}"*)
      KD_REASON="知見ブランチ・flush 用ブランチの命名と重なる: '${name}'"; return 1 ;;
  esac
  case "$KD_FLUSH_PREFIX" in
    "${name}/"*) KD_REASON="flush 用ブランチ（${KD_FLUSH_PREFIX}*）の親ディレクトリと同じ名前は使えない: '${name}'"; return 1 ;;
  esac
  return 0
}

# 設定の本文を解釈する。<本文> <出どころ> <default branch or empty> → 0 / 2（理由を stderr）
ff_kd_parse() {
  local text="$1" source="$2" default="${3:-}" line key value seen=" " n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    ff_kd_trim "$line"; line="$KD_TRIMMED"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) printf 'knowledge-delivery: %s の %s 行目が key=value ではない\n' "$source" "$n" >&2; return 2 ;;
    esac
    ff_kd_trim "${line%%=*}"; key="$KD_TRIMMED"
    ff_kd_trim "${line#*=}"; value="$KD_TRIMMED"
    case "$seen" in *" ${key} "*) printf 'knowledge-delivery: %s で %s が重複している\n' "$source" "$key" >&2; return 2 ;; esac
    seen="${seen}${key} "
    case "$key" in
      mode)
        case "$value" in
          per-merge|batch) KD_MODE="$value" ;;
          *) printf 'knowledge-delivery: %s の mode は per-merge か batch（値: %s）\n' "$source" "$value" >&2; return 2 ;;
        esac ;;
      staging_branch) KD_STAGING="$value" ;;
      warn_after_days)
        case "$value" in
          [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) KD_WARN_DAYS="$value" ;;
          *) printf 'knowledge-delivery: %s の warn_after_days は 1〜9999 の整数（値: %s）\n' "$source" "$value" >&2; return 2 ;;
        esac ;;
      *) printf 'knowledge-delivery: %s に未知のキー %s がある（mode / staging_branch / warn_after_days だけ）\n' "$source" "$key" >&2; return 2 ;;
    esac
  done <<EOF
$text
EOF
  if ! ff_kd_valid_staging "$KD_STAGING" "$default"; then
    printf 'knowledge-delivery: %s の staging_branch: %s\n' "$source" "$KD_REASON" >&2
    return 2
  fi
  return 0
}

# 設定を読む。出どころは origin/<default> の追跡 ref（あれば）→ HEAD の順。作業ツリーの未コミットの
# 編集は読まない（コミットした値だけがセッション間で揃う）。
# <repo dir> <default branch or empty> → 0 = 読めた（不在は per-merge）/ 2 = 壊れている・読めない
ff_kd_load() {
  local repo="$1" default="${2:-}" ref="" kind="" text=""
  ff_kd_reset
  if [ -n "$default" ] && git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/${default}^{commit}" >/dev/null 2>&1; then
    ref="refs/remotes/origin/${default}"
  elif git -C "$repo" rev-parse --verify --quiet "HEAD^{commit}" >/dev/null 2>&1; then
    ref="HEAD"
  else
    KD_SOURCE="（コミットが無い）"
    return 0
  fi
  KD_SOURCE="${ref}:${KD_CONF_REL}"
  # 「不在」と「読めない」を分ける（ls-tree は不在なら空で 0、読めなければ非 0）。読めない回を不在＝
  # マージごとへ倒すと、まとめるモードのリポジトリで base へ直接書く側へ倒れる
  kind="$(git -C "$repo" ls-tree "$ref" -- "$KD_CONF_REL" 2>/dev/null)" \
    || { printf 'knowledge-delivery: %s を確かめられない\n' "$KD_SOURCE" >&2; return 2; }
  [ -n "$kind" ] || return 0
  kind="$(printf '%s\n' "$kind" | awk 'NR == 1 { print $2 }')"
  [ "$kind" = blob ] || { printf 'knowledge-delivery: %s がファイルではない（%s）\n' "$KD_SOURCE" "$kind" >&2; return 2; }
  text="$(git -C "$repo" cat-file -p "${ref}:${KD_CONF_REL}" 2>/dev/null)" \
    || { printf 'knowledge-delivery: %s を読めない\n' "$KD_SOURCE" >&2; return 2; }
  KD_CONF_PRESENT=1
  ff_kd_parse "$text" "$KD_SOURCE" "$default"
}

# ── 書き込み先の記録（worktree ごとの git ディレクトリ） ──────────────────────
ff_kd_state_path() { # <repo dir> → stdout
  local gd
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 2
  printf '%s/%s\n' "$gd" "$KD_STATE_NAME"
}

# 戻り先は 2 つ持つ: 移る前のブランチ（無ければ -）と、移る前の HEAD の sha。detached HEAD から始めた回
# （worktree の /merge-cleanup の後など）はブランチが無いので sha へ戻る。戻らないと、未反映の知見と
# staging の merge を載せた HEAD のまま次の作業ブランチを切ってしまう。
# <repo dir> <mode> <staging> <default> <start sha> <staging tip or -> <default tip> <restore branch or -> <origin sha>
ff_kd_state_write() {
  local file tmp
  file="$(ff_kd_state_path "$1")" || return 2
  tmp="${file}.tmp.$$"
  {
    printf 'mode=%s\nstaging=%s\ndefault=%s\nstart=%s\nstaging_tip=%s\ndefault_tip=%s\nrestore=%s\norigin=%s\nepoch=%s\n' \
      "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "$(date +%s)"
  } >"$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 2; }
  mv -f -- "$tmp" "$file" 2>/dev/null || { rm -f -- "$tmp"; return 2; }
}

# <repo dir> → 0 = 記録あり（KD_ST_* へ）/ 1 = 記録なし / 2 = 読めない・壊れている
ff_kd_state_read() {
  local file line key value
  KD_ST_MODE=""; KD_ST_STAGING=""; KD_ST_DEFAULT=""; KD_ST_START=""
  KD_ST_STAGING_TIP=""; KD_ST_DEFAULT_TIP=""; KD_ST_RESTORE=""; KD_ST_ORIGIN=""; KD_ST_EPOCH=""
  file="$(ff_kd_state_path "$1")" || return 2
  [ -e "$file" ] || [ -L "$file" ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      mode) KD_ST_MODE="$value" ;;
      staging) KD_ST_STAGING="$value" ;;
      default) KD_ST_DEFAULT="$value" ;;
      start) KD_ST_START="$value" ;;
      staging_tip) KD_ST_STAGING_TIP="$value" ;;
      default_tip) KD_ST_DEFAULT_TIP="$value" ;;
      restore) KD_ST_RESTORE="$value" ;;
      origin) KD_ST_ORIGIN="$value" ;;
      epoch) KD_ST_EPOCH="$value" ;;
      *) return 2 ;;
    esac
  done <"$file"
  [ "$KD_ST_MODE" = batch ] && [ -n "$KD_ST_STAGING" ] && [ -n "$KD_ST_DEFAULT" ] \
    && [ -n "$KD_ST_START" ] && [ -n "$KD_ST_DEFAULT_TIP" ] && [ -n "$KD_ST_STAGING_TIP" ] \
    && [ -n "$KD_ST_RESTORE" ] && [ -n "$KD_ST_ORIGIN" ] || return 2
  [ "$KD_ST_STAGING_TIP" != "-" ] || KD_ST_STAGING_TIP=""
  [ "$KD_ST_RESTORE" != "-" ] || KD_ST_RESTORE=""
  return 0
}

ff_kd_state_clear() { # <repo dir>
  local file
  file="$(ff_kd_state_path "$1")" || return 2
  rm -f -- "$file"
}

# ── 先行されたときのやり直し手順（案内） ────────────────────────────────────
# 印字どおりに実行できる形にする（tests/knowledge-delivery の K5 が実際に流す）。退避・戻すパスは、
# 起点からの実際の変更をその場で列挙する（無いパスを pathspec に入れると git restore 全体が失敗する）。
# 起点の上に知見コミットがある（push が拒否された）回も、reset --soft で起点へ HEAD を戻してから restore
# するので、元の場所へ switch できる。<repo> <起点の sha> <戻り先へ移るコマンド> → stdout
ff_kd_redo_hint() {
  local paths p q=""
  paths="$(git -C "$1" -c core.quotePath=false diff --name-only "$2" 2>/dev/null)" || paths=""
  while IFS= read -r p; do [ -n "$p" ] || continue; q="${q} $(printf '%q' "$p")"; done <<EOF
$paths
EOF
  if [ -n "$q" ]; then
    printf '%s' "追記をパッチへ退避（git diff $2 --${q} > <パッチ>）→ git reset -q --soft $2 → git restore --source=$2 --staged --worktree --${q} → "
  else
    printf '%s' "git reset -q --soft $2 → "
  fi
  printf '%s' "finish.sh knowledge-commit discard → $3 → finish.sh knowledge-commit target → パッチを参照し、取り込んだ後のツリーで照合・Count・採番を引き直して追記し直す（--force で上書きしない）"
}

# ── 知見専用ブランチに載せてよい変更 ─────────────────────────────────────────
# staging は保護しない前提なので、知見の置き場（docs/08-knowledge/ と、その version claim）以外の変更が
# 紛れると、flush がそれをレビューなしで base へ運び、target が checkout した hook やスクリプトが書き手の
# 手元で動く。target（起点へ移る前）・push（送る前）・flush（取り込む前）の 3 か所で、この範囲の外を拒否する。
KD_ALLOWED_PREFIXES="docs/08-knowledge/ .version-claims/docs/08-knowledge/"

# <repo dir> <from> <to> → stdout へ範囲外の変更（1 行 1 件。無ければ空）/ 0 = 取得できた / 2 = git が失敗
# パスが置き場の中でも、変更後が通常ファイル（100644 / 100755）か削除（000000）でなければ範囲外とする。
# シンボリックリンク（120000）や gitlink（160000）は置き場の外を指せるため、パスだけでは足りない。
# 反映の設定ファイル自身は置き場の中にあるが、範囲外とする（staging から設定を書き換えて base へ運べない）。
ff_kd_paths_outside() {
  local list
  list="$(git -C "$1" -c core.quotePath=false diff --raw --no-renames --no-abbrev "$2" "$3" 2>/dev/null)" || return 2
  printf '%s\n' "$list" | awk -F '\t' -v allowed="$KD_ALLOWED_PREFIXES" -v conf="$KD_CONF_REL" '
    BEGIN { n = split(allowed, pre, " ") }
    NF >= 2 {
      split($1, meta, " "); mode = meta[2]; path = $2; ok = 0
      for (i = 1; i <= n; i++) if (index(path, pre[i]) == 1) ok = 1
      if (path == conf) ok = 0
      if (mode != "100644" && mode != "100755" && mode != "000000") { print path "（mode " mode "）"; next }
      if (!ok) print path
    }'
}

# ── 未反映の集計（追跡 ref だけを読む。fetch はしない） ──────────────────────
# <repo dir> <default> <staging> → 0。KD_UNREFLECTED（default..staging の merge 以外のコミット数）、
# KD_UNREFLECTED_DAYS（その最古のコミット日からの経過日数。0 件なら空）、
# KD_STAGING_TIP（追跡 ref の sha。無ければ空）を入れる。2 = git が失敗した
ff_kd_unreflected() {
  local repo="$1" default="$2" staging="$3" times="" now oldest
  KD_UNREFLECTED=0; KD_UNREFLECTED_DAYS=""; KD_STAGING_TIP=""
  KD_STAGING_TIP="$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/${staging}^{commit}" 2>/dev/null)" || KD_STAGING_TIP=""
  [ -n "$KD_STAGING_TIP" ] || return 0
  git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/${default}^{commit}" >/dev/null 2>&1 || return 2
  times="$(git -C "$repo" log --no-merges --format=%ct "refs/remotes/origin/${default}..refs/remotes/origin/${staging}" 2>/dev/null)" || return 2
  [ -n "$times" ] || return 0
  now="$(date +%s)"
  oldest="$(printf '%s\n' "$times" | awk 'NF { if (min == "" || $1 < min) min = $1; n++ } END { print n + 0, min }')"
  KD_UNREFLECTED="${oldest%% *}"
  oldest="${oldest#* }"
  KD_UNREFLECTED_DAYS=$(( (now - oldest) / 86400 ))
  [ "$KD_UNREFLECTED_DAYS" -ge 0 ] || KD_UNREFLECTED_DAYS=0
  return 0
}
