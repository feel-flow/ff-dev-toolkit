# shellcheck shell=bash
# pipefail-inherited: knowledge-lookup.sh が set -euo pipefail の下で source する
# knowledge-lookup-store.sh — Playbook と台帳の実配置を確定する関数。
#
# knowledge-lookup.sh から source する（ROOT / PLAYBOOK / TMP / TAB と snapshot_store_input を
# 共有し、ACE_PLAYBOOK_PATH を読む）。単体では実行しない。入口は最終行の完了印を source の前に照合する（ACE-2233-2）。
# 分割は Issue `#2694`（docs/MASTER.md のファイルサイズの閾値）。

# ── store の実配置を確定する ─────────────────────────────────────────────────
# 既定パスの不在だけを根拠に「未導入」と結論しない（/retrospective 起票前の既存確認 手順 2 と
# 同じ規則）。root 配下で同名ファイルを探し、候補が 1 件ならそれを採る。複数なら曖昧として
# 採らず、候補を報告する（推測で 1 つを選ばない）。docs-template（配布テンプレート）・oss
# （同期ミラー）・node_modules・.git は候補から外す。
# 戻り値: 0 = 確定（stdout にパス）/ 1 = 不在 / 3 = 曖昧（stderr に候補）
resolve_store() { # <既定の相対パス> <ファイル名> <明示パス>
  local default_rel="$1" fname="$2" explicit="$3" cands="" n=0
  if [ -n "${explicit}" ]; then
    printf '%s\n' "${explicit}"
    return 0
  fi
  if [ -e "${ROOT}/${default_rel}" ] || [ -L "${ROOT}/${default_rel}" ]; then
    printf '%s\n' "${ROOT}/${default_rel}"
    return 0
  fi
  cands="$(find "${ROOT}" \( -path '*/node_modules' -o -path '*/.git' -o -path '*/docs-template' -o -path "${ROOT}/oss" \) -prune -o \( -type f -o -type l \) -name "${fname}" -print 2>/dev/null | LC_ALL=C sort)" || return 2
  if [ -z "${cands}" ]; then
    return 1
  fi
  n="$(printf '%s\n' "${cands}" | awk 'END { print NR }')"
  if [ "${n}" -eq 1 ]; then
    printf '%s\n' "${cands}"
    return 0
  fi
  printf '%s の候補が %s 件あり確定できません（--playbook / --ledger で指定してください）:\n' "${fname}" "${n}" >&2
  printf '%s\n' "${cands}" | sed 's/^/    /' >&2
  return 3
}

# ── ACE Playbook の配置解決（/ace-curate・/ace-refine と共有する唯一の resolver） ──────
# 優先順: --playbook → ACE_PLAYBOOK_PATH → 記録済み配置 → 既定パス → 探索。
# /ace-curate・/ace-refine は `--resolve-playbook` モードでこの関数を呼ぶ。規則を各スキルの
# 散文へ複製すると片方だけが直る — ace-curate が記録済み配置を読むようになった後も、本
# スクリプトは既定パスと探索しか見ず、Playbook の実体を docs-template/ に置くリポジトリで
# 「Playbook なし」と報告し続けた（Issue `#2142`）。
# 記録済み配置: root の AGENTS.md・CLAUDE.md・docs/MASTER.md（docs 索引）に書かれた、
# `PLAYBOOK.md` で終わるパス（リンク先・バッククォート・地の文を問わない。`#` 以降は落ちる）。
# root 相対と記載ファイルのディレクトリ相対の両方で試し、実在する通常ファイルだけを採る。
# 採らないもの: 認可後の実体が root 外のもの・oss/・node_modules/・.git/ の配下と、plugin が同梱する配布テンプレート
# （`.claude-plugin/plugin.json` を持つディレクトリ直下の docs-template/）。記載の絶対パス・`~` は
# root / 記載ファイルの下へ連結して解くので実在せず、構造上採られない（ホスト固有のパスを記録にしない）。
# 判定（候補 = 認可済み実体pathで重複を除いた実在候補。選択/探索には論理配置を使う）:
#   - 候補 0 件 → 既定パス → 探索へ進む
#   - 既定パスに実体がある → 候補が既定パスを含めばそれを採る（他の候補は旧配置の注記と読む）。
#     含まなければ記録と実体の矛盾として曖昧（記録が 1 件でも、旧配置のスタブを指している
#     かもしれないので既定パスを黙って置き換えない）
#   - 既定パスに実体が無い → 候補 1 件なら確定、2 件以上なら記録の矛盾として曖昧
# docs-template/ を一律に外す prune は最後の探索段だけに掛け、記録段は plugin 同梱テンプレートに
# 限って外す — 記録・環境変数で名指しされた docs-template/ 配下の Playbook まで外すと、テンプレ
# 配布リポジトリの実体が常に不在になる。記載ファイルを読めなかった回は戻り値 2（読み取り失敗）。
# 出力: `<source><TAB><path>`（source = explicit / env / recorded:<記載ファイル> / default / search）
# 戻り値: 0 = 確定 / 1 = 不在 / 2 = 記載ファイルの読み取り失敗 / 3 = 曖昧（stderr に候補）
# 出力は `<論理パス><TAB><認可済みの実体>`。呼び出し側が同じパスをもう一度認可しないよう、
# ここで得た実体も返す（認可 1 回は Git Bash で約 0.4 秒。Issue `#2477`）
ace_record_candidate() { # <path> → 認可後、親を正規化し論理leafを保ったパスと実体を stdout へ
  local p="$1" d="" pre="" real="" role_parent=""
  [ -e "${p}" ] || [ -L "${p}" ] || return 1
  real="$(ff_knowledge_authorize "$p" "$ROOT")" || return 1
  d="$(ff_knowledge_canonical_dir "${p%/*}")" || return 1
  for role_parent in "$d" "${real%/*}"; do
    case "${role_parent}/" in "${ROOT}/"*) ;; *) return 1 ;; esac
    case "${role_parent}/" in "${ROOT}/oss/"*|*/node_modules/*|*/.git/*) return 1 ;; esac
    case "${role_parent}/" in
      */docs-template/*)
        pre="${role_parent}/"; pre="${pre%%/docs-template/*}"
        [ -f "${pre}/.claude-plugin/plugin.json" ] && return 1
        ;;
    esac
  done
  printf '%s/%s\t%s\n' "${d}" "${p##*/}" "${real}"
}
resolve_playbook() {
  local env_path="${ACE_PLAYBOOK_PATH:-}" rec="" src="" tok="" base="" c="" seen="" tried="" hit="" n=0 first_src="" first="" def="" record_snapshot="" physical="" def_physical=""
  local nl='
'
  if [ -n "${PLAYBOOK}" ]; then
    printf 'explicit\t%s\n' "${PLAYBOOK}"
    return 0
  fi
  # 空白だけの値は未設定と同じ（check-entry-format.ts の ACE_PLAYBOOK_PATH 解決と揃える。
  # 相対パスは同じく cwd 基準）。設定されていれば実在を問わず採る — 読めなければ呼び出し側が
  # 読み取り失敗にする（明示の名指しを探索で上書きしない）。
  if [ -n "${env_path//[[:space:]]/}" ]; then
    printf 'env\t%s\n' "${env_path}"
    return 0
  fi
  for rec in AGENTS.md CLAUDE.md docs/MASTER.md; do
    [ -e "${ROOT}/${rec}" ] || [ -L "${ROOT}/${rec}" ] || continue
    printf '%s\n' "${rec}" >>"${TMP}/ace-record-files"
  done
  if [ -s "${TMP}/ace-record-files" ]; then
    while IFS= read -r rec; do
      record_snapshot="$(accepted_snapshot "${ROOT}/${rec}" "$ROOT")" || return 2
      # トークンは 2 通りに切り出す: ASCII のパス文字だけ（「（docs-template/…）」の全角括弧を
      # 含めない）と、区切り文字（空白・括弧・引用符等）まで（`docs-template/知見/PLAYBOOK.md` の
      # ような非 ASCII を含むパスを途中で切らない）。どちらかが実在するパスになり、残りは実在確認で落ちる。
      LC_ALL=C awk -v rec="${rec}" '
        function emit(re,   line, tok) {
          line = $0
          while (match(line, re)) {
            tok = substr(line, RSTART, RLENGTH)
            line = substr(line, RSTART + RLENGTH)
            if (line ~ /^[A-Za-z0-9_]/) continue   # PLAYBOOK.mdx などの途中一致は採らない
            printf "%s\t%s\n", rec, tok
          }
        }
        { emit("[A-Za-z0-9_./~-]*PLAYBOOK\\.md"); emit("[^][()<>\"`|*,; \t\047]*PLAYBOOK\\.md") }
      ' "$record_snapshot" || { printf '記録済み配置を読めません: %s\n' "${rec}" >&2; return 2; }
    done <"${TMP}/ace-record-files" >"${TMP}/ace-record-tokens"
    while IFS="${TAB}" read -r src tok; do
      base="${ROOT}/${src}"; base="${base%/*}"
      for c in "${ROOT}/${tok}" "${base}/${tok}"; do
        # 鏡写しの入口（AGENTS.md / CLAUDE.md）は同じ綴りを何度も挙げる。1 回の実行の中で
        # 判定は変わらず、2 回目は下の seen で必ず捨てるので、認可の前に飛ばす
        case "${nl}${tried}" in *"${nl}${c}${nl}"*) continue ;; esac
        tried="${tried}${c}${nl}"
        hit="$(ace_record_candidate "${c}")" || continue
        c="${hit%%"${TAB}"*}"; physical="${hit#*"${TAB}"}"
        case "${nl}${seen}" in *"${nl}${physical}${nl}"*) continue ;; esac
        seen="${seen}${physical}${nl}"
        printf '%s\t%s\t%s\n' "${src}" "${c}" "${physical}" >>"${TMP}/ace-record-hits"
        n=$((n + 1))
        if [ "${n}" -eq 1 ]; then first="${c}"; first_src="${src}"; fi
      done
    done <"${TMP}/ace-record-tokens"
  fi
  if [ "${n}" -gt 0 ] && hit="$(ace_record_candidate "${ROOT}/docs/08-knowledge/PLAYBOOK.md")"; then
    def="${hit%%"${TAB}"*}"; def_physical="${hit#*"${TAB}"}"
    src="$(FF_READ_KEY="$def_physical" LC_ALL=C awk -F '\t' '$3 == ENVIRON["FF_READ_KEY"] { print $1; exit }' "${TMP}/ace-record-hits")"
    if [ -n "${src}" ]; then
      if [ "${n}" -gt 1 ]; then
        printf '記録済み配置の候補 %s 件のうち既定パスを採りました（他の記載は採りません）:\n' "${n}" >&2
        FF_READ_KEY="$def_physical" LC_ALL=C awk -F '\t' '$3 != ENVIRON["FF_READ_KEY"] { printf "    %s（記載: %s）\n", $2, $1 }' "${TMP}/ace-record-hits" >&2
      fi
      printf 'recorded:%s\t%s\n' "${src}" "${def}"
      return 0
    fi
    printf '記録済み配置と既定パスの実体（%s）が食い違い、確定できません（記録を実配置へ揃えるか、--playbook / ACE_PLAYBOOK_PATH で指定してください）:\n' "${def}" >&2
    awk -F '\t' '{ printf "    %s（記載: %s）\n", $2, $1 }' "${TMP}/ace-record-hits" >&2
    return 3
  fi
  if [ "${n}" -eq 1 ]; then
    printf 'recorded:%s\t%s\n' "${first_src}" "${first}"
    return 0
  fi
  if [ "${n}" -gt 1 ]; then
    printf 'PLAYBOOK.md の記録済み配置が %s 件あり確定できません（記録を 1 つに揃えるか、--playbook / ACE_PLAYBOOK_PATH で指定してください）:\n' "${n}" >&2
    awk -F '\t' '{ printf "    %s（記載: %s）\n", $2, $1 }' "${TMP}/ace-record-hits" >&2
    return 3
  fi
  if c="$(resolve_store "docs/08-knowledge/PLAYBOOK.md" "PLAYBOOK.md" "")"; then
    if [ "${c}" = "${ROOT}/docs/08-knowledge/PLAYBOOK.md" ]; then src="default"; else src="search"; fi
    printf '%s\t%s\n' "${src}" "${c}"
    return 0
  else
    return $?
  fi
}
# knowledge-lookup-store-end
