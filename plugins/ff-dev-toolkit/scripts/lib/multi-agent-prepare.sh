#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: staging・出力先の境界・ツリー変化のパス除外・diff の固定・review evidence の producer・基準スナップショット・単一タスクの実行・負荷ゲート・プランの検証。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── Staging Directory（Issue `#392`） ──
# implement タスクで生成物を置かせる実ディレクトリ。**タスク単位** = (CLI, 観点) 単位
# であることが要点。CLI 単位にすると、同じ CLI に複数の観点が乗ったプランで並列に
# 走るタスクが同一ディレクトリへ書き、同名ファイルが後勝ちで黙って消える。これは
# 例外的な構成ではない: 導入済みの CLI が 1 つしかなければ fallback で全観点がその
# CLI に集まるし、CLI が 1 つ欠けるだけでも fallback 先に 2 観点が乗る（実測）。
#
# パスを組み立てるのはここ 1 箇所で、消費点は run_single_task（作成して渡す）と
# clear_planned_outputs（前回実行の残骸を消す）。両者がずれると「消した先と書く先が
# 違う」形の stale が静かに開く。report_unplanned_staging_dirs（プラン外タスクの
# staging 残骸の名指し・Issue `#724`）も同じ `<cli>/files/<perspective>` レイアウトを
# 前提に走査するので、ここを変えたらそちらも追随させること。
# ここを変えたらレイアウトを literal で案内している次も追随させること:
#   - append_plan_sections の "**Staging:**" 行 … 実パスを出すので tests/
#     adapter-prompt-guard が照合する（追随漏れは赤になる）
#   - generate_implement_report のヘッダの `<cli>/files/<perspective>/` … 形だけの
#     案内で、**機械ゲートは無い**。ここは人が揃える
#   - skills/multi-implement/SKILL.md の表と注記 … 同上、機械ゲートは無い
#
# レポート本体（${OUTPUT_DIR}/${cli}/${persp}.md）と同じ階層に置かず専用の
# サブディレクトリへ落とすのは、write_output が CLI 完走**後**に ${persp}.md を
# 書くため — エージェントが同名のファイル（例: refactoring.md）を生成すると
# レポートに黙って上書きされる。
#
# 引数はどちらも validate_execution_plan で安全な単一セグメントと確認済み。
staging_dir_for() {
  printf '%s\n' "${OUTPUT_DIR}/${1}/files/${2}"
}

# 前回実行の staging を消す。`rm -rf` を素で撃たないのは、パスの**途中の**コンポーネント
# が symlink だと再帰削除が意図しない場所へ抜けるため。例えば <cli>/files が
# /tmp/victim を指す symlink なら、rm -rf <cli>/files/<persp> は /tmp/victim/<persp> を
# 消す。OUTPUT_DIR を pwd -P しても、文字列 prefix 判定では途中の symlink を見抜けない。
# clear_planned_outputs は「プランの対象以外はディスク上の何にも触れない」と宣言して
# いるので、その宣言を実際に成り立たせるための検査。
#
# 判定は「解決先が OUTPUT_DIR 配下か」ではなく「symlink を追わない」で行う（Issue `#1120`）。
# 配下判定だと**内向き**の symlink — 解決先が出力先の中にあるもの、例えば
# `<cli>/files -> ../codex-cli/files` — が判定を通り、別 CLI / 別観点の staging 成果が
# 丸ごと消える。指し先が出力先の内か外かは、消してよいかどうかと関係がない: どちらも
# 「このタスクの staging ではないもの」を消す。clear_quarantine_dir（`#723`）と
# clear_planned_outputs（`#722`）は既にこの方針で、内向き追従が残っていたのはここだけだった。
#
# 形は 2 つに分かれる:
#   - staging パス**自体**が symlink … リンクだけを消して続行する（clear_quarantine_dir と
#     同型。`rm -f` は指し先を追わない）。この後 run_single_task が実体を作り直す
#   - パスの**途中**が symlink … resolve_expected_dir が「解決後 == 渡したパス」を要求して
#     fail-loud（内向き・外向きのどちらも拒否する）。削除は検査した物理パスに対して行い、
#     検査したものと消すものを一致させる
clear_staging_dir() { # <dir> [label]
  local staging_dir="$1" label="${2:-the staging dir}" resolved parent

  # 親（中間コンポーネント）を leaf の存在・種別より**先に**検査する。leaf が未作成の
  # 回は -L / -d / -e がすべて偽で、そのまま素通りすると呼び出し側の `mkdir -p` が
  # リンク先へ staging を作って書き込む（実測: <cli>/files が外を指す symlink で、
  # 観点ディレクトリがまだ無い初回実行）。leaf の状態に関係なく経路を先に塞ぐ。
  parent="$(dirname "$staging_dir")"
  if [[ -e "$parent" || -L "$parent" ]]; then
    resolve_expected_dir "$parent" "the staging parent for ${label}" \
      "Deleting through it would erase another task's staging output." >/dev/null || return 1
  fi

  # symlink は**追わない**。`[[ -d ]]` は symlink→dir でも真になるので -L を先に見る。
  if [[ -L "$staging_dir" ]]; then
    if ! rm -f "$staging_dir"; then
      echo "ERROR: cannot remove the symlink at the staging path: ${staging_dir}" >&2
      return 1
    fi
    echo "  ⚠️ Removed a symlink at the staging path (its target was left untouched): ${staging_dir}" >&2
    return 0
  fi

  if [[ -d "$staging_dir" ]]; then
    resolved="$(resolve_expected_dir "$staging_dir" "$label" \
      "Deleting through it would erase another task's staging output.")" || return 1
    if ! rm -rf "$resolved"; then
      echo "ERROR: cannot clear staging dir: ${resolved}" >&2
      echo "       A previous run's files would be reported as this run's output." >&2
      return 1
    fi
    return 0
  fi

  # ディレクトリでない残骸（通常ファイル等）はそれ自体を消す。symlink は上で処理済み。
  if [[ -e "$staging_dir" ]]; then
    if ! rm -f "$staging_dir"; then
      echo "ERROR: cannot remove non-directory at staging path: ${staging_dir}" >&2
      return 1
    fi
  fi
  return 0
}

# implement の CLI は常に REPO_ROOT から起動する。OUTPUT_DIR（= staging）も同じ
# 物理ルート配下でなければ、プロンプトが「書ける」と名指しした staging を CLI 側が
# 拒否する。警告して続けると起動してから初めて分かるので、起動前に fail-loud で止める。
#
# この検査が何を担保するかはアダプタごとに違う。一括で「4 アダプタのパス境界」と
# 書かないこと — claude-code にはパス境界そのものが無い（adapter-common.sh の
# build_prompt にも同じ注意がある）:
#
#   codex   … `codex exec -C <staging>` で書き込みルートは CWD ではなく staging 単独
#             （Issue `#896`）。この検査は境界そのものではなく、codex の git リポジトリ
#             検査（`--skip-git-repo-check` を渡さない前提）が要求する「staging が
#             リポジトリ配下」を満たす役割で、外すと implement が起動に失敗する。
#   grok    … `workspace` プロファイルの書き込みルートは CWD = REPO_ROOT。`-C` 相当の
#             絞り込みは未実測（grok-cli-adapter.sh の get_sandbox_profile 直前を参照）
#             なので、この検査が staging をその境界の内側に保つ担保。
#   copilot … 非 inline の implement には permission deny を渡さない（deny 配列は
#             inline 専用）。書き込みが CWD 由来のどこまでに閉じるかはこのリポジトリに
#             実測の記録が無いので、この検査は「staging を REPO_ROOT 配下に保つ」まで。
#   claude-code … パス境界を持たない。書き込みゲートは get_allowed_tools の
#             Write/Edit だけで、この検査はパス境界の担保にはならない（それでも
#             staging がリポジトリ外へ出る形は他の 3 つと同じく塞ぐ）。
validate_implement_output_boundary() {
  [[ "${TASK_TYPE:-review}" == "implement" ]] || return 0
  local repo_physical
  if ! repo_physical="$(cd "$REPO_ROOT" && pwd -P)"; then
    echo "ERROR: cannot resolve repository sandbox root: ${REPO_ROOT}" >&2
    return 1
  fi
  case "$OUTPUT_DIR" in
    "$repo_physical"|"$repo_physical"/*) return 0 ;;
  esac
  echo "ERROR: implement output dir is outside the CLI sandbox root — refusing to name an unwritable staging path." >&2
  echo "       output:  ${OUTPUT_DIR}" >&2
  echo "       sandbox: ${repo_physical}" >&2
  echo "       Choose --output-dir under the repository root." >&2
  return 1
}

# ── 出力ディレクトリのリポジトリ相対パス ──
#
# capture_repo_snapshot へ渡す除外パス。orchestrator は実行中ずっとこの配下へ成果物を
# 書き続けるので、作業ツリーの変化として数えると**正常な実行が毎回**「リポジトリが
# 変化した」と判定される。本リポジトリは .review-results/ を gitignore しているが、
# 利用者のリポジトリがそうしている保証はない。
#
# 含有関係を確定できないときは**何も返さない**（= 何も除外しない）。推測した接頭辞で
# 除外すると、本来監視すべき範囲を黙って監視対象から外しかねない。なお出力先が
# リポジトリ外なのは異常ではない — 配下であることを検査しているのは implement だけで
# （validate_implement_output_boundary）、review / explore は外を指定できる。
output_dir_repo_relative() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  local repo_physical parent base resolved
  repo_physical="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || return 0
  # OUTPUT_DIR はこの時点ではまだ存在しないことがある（作るのは execute_tasks）。
  # 親は存在するので、親を物理パスへ解決してから名前を足す。論理パス（$PWD 由来）と
  # 物理パス（git rev-parse --show-toplevel 由来）の綴り違いを揃える狙いも兼ねる
  # （symlink 越しのチェックアウトで同じ場所が別の綴りになる。execute_tasks が
  # OUTPUT_DIR を pwd -P で正規化しているのと同じ理由）。
  parent="$(dirname "$OUTPUT_DIR")"
  base="$(basename "$OUTPUT_DIR")"
  parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 0
  resolved="${parent%/}/${base}"
  case "$resolved" in
    "$repo_physical"/*) printf '%s\n' "${resolved#"$repo_physical"/}" ;;
    *) return 0 ;;
  esac
}

# ── ツリー変化判定のパス除外の検証・分解（Issue `#747`） ──
#
# FF_MULTI_AGENT_IGNORE_PATHS を ':' 区切りで分解し、IGNORE_EXCLUDE_PATHSPECS
#（capture_repo_snapshot へ渡す除外形）と IGNORE_MATCH_PATHSPECS（報告用の肯定形）
# を組み立てる。fail-closed の原則は merge-cleanup.sh の
# FF_MERGE_CLEANUP_IGNORE_PATHS と揃える:
#   - 空パターン（先頭・末尾・連続する ':'）は中断 — 空 pathspec は全パスに一致し、
#     ガードを黙って無効化する（fail-open）ため
#   - 前後に空白の付いたパターンは中断 — pathspec は空白も含めて照合するので
#     何にも一致せず、「設定したのに効かない」が無言で続くため
#   - 文字クラス（[...]）は中断 — クラス内の ':' が区切り文字と衝突して黙って分断され、
#     破片は「何にも一致しない」正当そうな見た目になる（fail-open。
#     FF_MERGE_CLEANUP_PROTECT_BRANCHES の先例と同じ扱い）
#   - '.' / '/' 単体は中断 — glob magic では**何にも一致しない**（git 2.50.1 実測:
#     :(exclude,glob,top). / :(exclude,glob,top)/ はどちらも除外 0 件。さらに '/' は
#     肯定形 :(glob,top)/ が rc=128 "fatal: oops in prep_exclude" で落ち、verify 時の
#     除外報告クエリごと道連れにする）。全部を除外したい意図なら '**' を明示させる
#   - 全パス一致（'**' / '**/*'。git 2.50.1 実測でともに全除外）は明示的な選択でも
#     ありうるので中断せず、ガードが事実上無効になる旨を実行ログへ出す。'*' は
#     glob magic では '/' を跨がずリポジトリ直下しか除外しないため、警告対象ではない
# タスクを 1 つも起動する前（main の冒頭）に呼ぶ — CLI に支払った後で設定不正に
# 気づく形にしない。
parse_ignore_paths() {
  local raw="${FF_MULTI_AGENT_IGNORE_PATHS:-}" rest item
  [[ -n "$raw" ]] || return 0
  # 末尾の空要素も検出したいので、終端の ':' を足してから 1 要素ずつ剥がす
  rest="${raw}:"
  while [[ -n "$rest" ]]; do
    item="${rest%%:*}"
    rest="${rest#*:}"
    if [[ -z "$item" ]]; then
      echo "ERROR: FF_MULTI_AGENT_IGNORE_PATHS contains an empty pattern: '${raw}'" >&2
      echo "       An empty pathspec matches every path, which would silently disable the" >&2
      echo "       tree-change guard (check for a leading, trailing, or doubled ':')." >&2
      echo "       ':' is the separator, so pathspec magic like ':(exclude)...' cannot be" >&2
      echo "       written here (mid-pattern it is treated as literal text and matches nothing)." >&2
      return 1
    fi
    case "$item" in
      [[:space:]]*|*[[:space:]])
        echo "ERROR: FF_MULTI_AGENT_IGNORE_PATHS pattern has leading/trailing whitespace: '${item}'" >&2
        echo "       Pathspecs match whitespace literally, so this pattern matches nothing" >&2
        echo "       (check for a space after a ':')." >&2
        return 1
        ;;
    esac
    case "$item" in
      *\[*|*\]*)
        # logs/[[:digit:]]*/** のような文字クラスは、クラス内の ':' が区切り文字と
        # 衝突して黙って分断される（エラーにならないまま除外が消える fail-open）。
        echo "ERROR: FF_MULTI_AGENT_IGNORE_PATHS pattern contains a character class ([...]): '${item}'" >&2
        echo "       A ':' inside the class collides with the ':' separator and the pattern is" >&2
        echo "       silently split into fragments that look valid but match nothing, so" >&2
        echo "       character classes are unsupported (same as FF_MERGE_CLEANUP_PROTECT_BRANCHES)." >&2
        echo "       Use a prefix glob instead (e.g. 'logs/**')." >&2
        return 1
        ;;
    esac
    case "$item" in
      '.'|'/')
        # glob magic では '.' も '/' も**何にも一致しない**（実測: 除外 0 件）。しかも
        # '/' は肯定形 :(glob,top)/ を rc=128 で落とし、verify 時の除外報告ごと壊す。
        echo "ERROR: FF_MULTI_AGENT_IGNORE_PATHS pattern '${item}' matches nothing under" >&2
        echo "       pathspec glob magic — it would sit in the configuration excluding no path" >&2
        echo "       ('/' additionally breaks the exclusion-report query outright)." >&2
        echo "       To exclude every path, write '**' explicitly." >&2
        return 1
        ;;
      '**'|'**/*')
        echo "⚠️ FF_MULTI_AGENT_IGNORE_PATHS pattern '${item}' matches every path — the" >&2
        echo "   tree-change guard is effectively disabled for the working tree." >&2
        ;;
    esac
    IGNORE_EXCLUDE_PATHSPECS+=(":(exclude,glob,top)${item}")
    IGNORE_MATCH_PATHSPECS+=(":(glob,top)${item}")
  done
  return 0
}

# ── 出力ディレクトリの境界検証 ──
#
# リビジョンガードは「出力ディレクトリ配下は orchestrator 自身が書くので数えない」
# という前提で除外を掛ける。その前提が崩れる 2 つの構成をここで弾く。黙って動かすと、
# **正しい実行が毎回破棄される**か、**ガードが実質的に無効化される**。
#
#   1) 出力先がリポジトリ root … 除外は厳密な部分パスしか表せないので何も除外できず、
#      自分が書く .fixed-diff で毎回ガードに掛かる。しかも診断は「リポジトリが変化した」
#      と出るので、利用者は起きていない checkout を探すことになる。
#   2) 出力先に tracked ファイルがある … この実行はその配下を上書き・削除するため
#      tracked の内容が動き、やはり毎回破棄になる。同時にこの検査は `--output-dir src`
#      のようにソースを含むディレクトリを出力先に指定して**監視から外す**使い方も塞ぐ
#      （除外は 4 つの問い合わせすべてに効くので、弾かないと実コードの変更がガードから
#      消える）。
validate_output_dir_boundary() {
  [[ "$IN_GIT_REPO" == "true" ]] || return 0
  local repo_physical rel tracked
  repo_physical="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || return 0

  if [[ "$OUTPUT_DIR" == "$repo_physical" ]]; then
    echo "ERROR: the output dir must not be the repository root: ${OUTPUT_DIR}" >&2
    echo "       This run writes its own artifacts there, and the revision guard would read" >&2
    echo "       those writes as the repository changing under it — every run would be" >&2
    echo "       discarded, blaming a checkout that never happened." >&2
    echo "       Pass --output-dir <subdirectory> instead." >&2
    return 1
  fi

  rel="$(output_dir_repo_relative)"
  # リポジトリ外の出力先は対象外（review / explore では正当な指定）。
  [[ -n "$rel" ]] || return 0

  tracked="$(cd "$repo_physical" && git ls-files -- ":(literal)${rel}" 2>/dev/null | head -1)" || return 0
  if [[ -n "$tracked" ]]; then
    echo "ERROR: the output dir contains tracked files: ${OUTPUT_DIR}" >&2
    echo "       first match: ${tracked}" >&2
    echo "       This run overwrites and deletes files under the output dir. Tracked content" >&2
    echo "       there would register as the repository changing mid-run, so every run would" >&2
    echo "       be discarded after the CLIs had already been paid for." >&2
    echo "       Pass an --output-dir that holds no tracked files." >&2
    return 1
  fi
  return 0
}

# ── この実行の diff を 1 度だけ固定する ──
#
# 以前は各アダプタが**自分の起動時に** git から diff を取っていた。並列タスクの起動
# 時刻はばらけるので、実行中に checkout / commit / stash が入るとタスクごとに別の
# 瞬間の diff をレビューし、しかも全員が正常終了する。ここで 1 度だけ取ってファイルへ
# 固定し、全タスクへ同じバイト列を配る。
#
# 置き場所が出力ディレクトリなのは、スナップショットの除外対象と同じ場所だから
# （作業ツリーを汚さない）。同じ出力先の同時実行は acquire_output_lock が既に排他して
# いるので、固定名で衝突しない。実行後もそのまま残すので、レポートと並べて
# 「実際に何をレビューしたのか」を後から確認できる。
create_fixed_diff() {
  [[ "$IN_GIT_REPO" == "true" ]] || return 0
  # diff をプロンプトへ載せないタスクでは何も固定しない。載せないものを固定しても
  # 意味が無いうえ、diff を持たないリポジトリ状態での失敗を持ち込むだけになる。
  if [[ "$TASK_TYPE" != "review" && "$INCLUDE_DIFF" != "true" ]]; then
    return 0
  fi
  local target="${OUTPUT_DIR}/.fixed-diff"
  # get_diff_content は STAGED_DIFF を見て --staged 実行を切り替える（adapter-common）。
  # 同じプロセス内の変数なので、ここでの呼び出しにもそのまま効く。
  if ! get_diff_content "$BASE_BRANCH" >"$target"; then
    echo "ERROR: cannot capture this run's diff: ${target}" >&2
    echo "       Every task must review the same bytes; refusing to let each adapter" >&2
    echo "       compute its own diff instead." >&2
    rm -f "$target" || echo "WARNING: could not remove the partial fixed diff: ${target}" >&2
    return 1
  fi
  FIXED_DIFF_FILE="$target"
  return 0
}

# ── review evidence の producer を開始時に固定する ──
#
# evidence の begin（タスク起動前）と finish（全 CLI の完走後）は同じ review-evidence.py を
# 使う。ファイルをパスで 2 回開く形だと、レビュー中の plugin 更新で開始時の root（版ごとの
# cache）が消えたとき、完走した結果があるのに finish だけが「ファイルが無い」で落ち、
# 全観点の再実行になる（導入先で 3 回実測）。完走後に plugin の root から必ず読む
# ファイルはこれ 1 本だけなので、開始時に固定 root から 1 回だけ読み、begin と finish の
# 両方をそのバイト列から実行する。
#
# ADR-036 との関係: 読むのは開始時に固定した root の実体そのもの。別の場所へのコピー・
# 他の版の探索・sidecar への切替は作らず、バイト列はこのプロセスのメモリにだけ持つ
# （ADR-073）。読めなければ CLI を 1 つも起動する前に、root 消失と同じ文言で止める。
# バイト列は argv（`-c`）ではなく標準入力（`python3 -I -`）で渡す。argv は Windows の
# CreateProcess 上限（約 32 KB）・MSYS の引数変換・ロケールでの復号を受ける。Python は
# 標準入力のプログラムを読み切ってから実行するので、子の git が標準入力を待つことはない。
# `-I`（隔離モード）は必須: `-` でも sys.path の先頭へ cwd（レビュー対象のリポジトリ）が
# 入り、対象に json.py などがあると標準ライブラリの import を乗っ取られる（ファイル実行
# では先頭が scripts/ なので起きなかった）。
pin_review_evidence_producer() {
  local helper="${SCRIPT_DIR}/review-evidence.py" content="" sha reason=""
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: --evidence requires python3, which is not on PATH." >&2
    return 1
  fi
  # 末尾の改行まで保つため番兵を足して読む（$(...) は末尾の改行を落とす）。`&&` なので
  # cat が失敗すれば番兵は付かず、置換の終了コードは cat のものになる。symlink と空ファイルは
  # resource guard と同じく拒否する（空の producer は begin / finish が何もせず 0 で返る）。
  if [[ -L "$helper" ]]; then
    reason="symlink です"
  elif [[ ! -f "$helper" ]]; then
    reason="ありません"
  elif [[ ! -s "$helper" ]]; then
    reason="0 バイトです"
  elif ! content="$(cat -- "$helper" && printf x)" || [[ "$content" != *x ]]; then
    reason="読み取れません"
  fi
  if [[ -n "$reason" ]]; then
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（review evidence の producer が${reason}）"
      echo "   対象のファイル: ${helper}"
      echo "   cache を手で直さず、plugin を更新・再導入してから skill を呼び直してください。"
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   CLI はまだ 1 つも起動していません。"
    } >&2
    return 2
  fi
  content="${content%x}"
  if ! sha="$(printf '%s' "$content" | python3 -I -c 'import hashlib, sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" \
    || [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: cannot compute the digest of the review evidence producer: ${helper}" >&2
    return 1
  fi
  REVIEW_EVIDENCE_PRODUCER_PATH="$helper"
  REVIEW_EVIDENCE_PRODUCER="$content"
  REVIEW_EVIDENCE_PRODUCER_SHA256="$sha"
}

# 固定したバイト列で review-evidence.py を実行する。begin はその digest を記録し、finish は
# 同じ digest を示さないと拒否される（begin と finish が同じ producer だったことの照合）。
run_review_evidence() { # <action> <引数...>
  if [[ -z "$REVIEW_EVIDENCE_PRODUCER_SHA256" ]]; then
    echo "ERROR: the review evidence producer was not pinned at start (orchestrator bug)." >&2
    return 1
  fi
  printf '%s' "$REVIEW_EVIDENCE_PRODUCER" | python3 -I - "$@" --producer-sha256 "$REVIEW_EVIDENCE_PRODUCER_SHA256"
}

# 開始時の plugin root が実行中に変わったら名指しする。見張るのは `multi-agent.sh` の存在と、
# `review-evidence.py` の存在・内容の 2 点だけで、ほかのファイルの変化は検知しない。CLI の
# 完走後の工程は（この診断の読み取りを除いて）この root から何も読まないので、レポートと
# evidence は開始時に読んだものだけで仕上がる。案内するのは次のコマンドの前に skill を
# 呼び直すことだけで、他の版は探さない（ADR-036）。
report_plugin_root_change() {
  local changed="" current
  if [[ ! -f "${SCRIPT_DIR}/multi-agent.sh" ]]; then
    changed="${SCRIPT_DIR}/multi-agent.sh is gone"
  fi
  if [[ -n "$REVIEW_EVIDENCE_PRODUCER_PATH" ]]; then
    if [[ ! -f "$REVIEW_EVIDENCE_PRODUCER_PATH" ]]; then
      changed="${changed:+${changed}; }${REVIEW_EVIDENCE_PRODUCER_PATH} is gone"
    elif ! current="$(cat -- "$REVIEW_EVIDENCE_PRODUCER_PATH" 2>/dev/null && printf x)" \
      || [[ "${current%x}" != "$REVIEW_EVIDENCE_PRODUCER" ]]; then
      changed="${changed:+${changed}; }${REVIEW_EVIDENCE_PRODUCER_PATH} no longer reads back as the bytes read at start"
    fi
  fi
  [[ -n "$changed" ]] || return 0
  echo "" >&2
  echo "ℹ️  The plugin root this run started from changed while it ran: ${changed}." >&2
  if [[ -n "$REVIEW_EVIDENCE_PRODUCER_PATH" ]]; then
    echo "   The evidence will be finished by the review-evidence.py read at start (sha256 ${REVIEW_EVIDENCE_PRODUCER_SHA256}); no other installed version is used." >&2
  else
    echo "   The report was built only from what this run read at start; no other installed version is used." >&2
  fi
  echo "   Before the next command, re-invoke the skill so the host resolves the plugin root again (ff-dev-toolkit更新後にこのskillを再呼び出してください)." >&2
}

# finish が証跡を書けなかったとき、理由（直前の ERROR 行）に続けて、残したもの・再実行の範囲を
# 示す。残したファイルは診断用で、手で receipt に組み立てない（verify は署名の無いローカルの
# 出自記録を照合するだけで、手で組み立てた receipt を見分けられない）。
print_evidence_finish_failure() { # <results file> <report sha256>
  local task
  {
    echo ""
    echo "❌ Review evidence was not issued for this run; no review-evidence.json was written (reason: the ERROR line above)."
    echo "   Kept as they were, for inspection only:"
    echo "     start record (subject and plan): ${REVIEW_EVIDENCE_START}"
    echo "     task results: $1"
    echo "     report: ${OUTPUT_DIR}/integrated-report.md (sha256 $2)"
    echo "   Do not edit or assemble these into a receipt — a receipt must come from finish (verify checks local"
    echo "   provenance only and cannot tell a hand-assembled one apart)."
    echo "   Re-run scope: run the same command again. With plain --evidence (no --require-prior-review /"
    echo "   --continue-review) you may drop --fresh and add --resume: finished tasks are reused only while"
    echo "   HEAD, base, the diff, --description, the plan and models, and the toolkit files are all unchanged."
    echo "   Otherwise every planned task runs again:"
    while IFS= read -r task; do
      if [[ -n "$task" ]]; then
        echo "     ${task}"
      fi
    done <<< "${FULL_EXECUTION_PLAN:-$EXECUTION_PLAN}"
  } >&2
}

# ── 基準スナップショットの取得と diff 固定（この 2 つは隣接させる） ──
#
# 基準を先に離れた場所で取ると、基準取得から diff 固定までのあいだに「動いて元へ戻る」
# 変化が入りうる。前後のスナップショットは一致するのに、固定 diff だけが途中の状態を
# 写した内容になり、**この修正が防ごうとしている食い違いを自分で作る**。
# そこで固定の直前と直後で 2 回取り、一致しなければ開始前に止める。一致した方を基準に
# 採用するので、基準と固定 diff が同じ瞬間のリポジトリを写していることを、
# **スナップショットが見える範囲で**確かめたことになる（見えない範囲は
# capture_repo_snapshot の「見えないものを明示しておく」の項を参照）。
#
# --dry-run はここへ到達しない（main が手前で exit する）ので、実際にタスクを起動する
# 実行だけが対象になる。review だけでなく explore / implement も対象: どのタスクでも
# CLI エージェントは作業ツリーのファイルを読み、implement はそこへ書きうるので、
# 対象が動けば結果の意味が変わるのは同じ。
capture_baseline_and_fix_diff() {
  if [[ "$REVIEW_EVIDENCE" == true && ( "$IN_GIT_REPO" != true || "$TASK_TYPE" != review || "$STAGED_DIFF" == true ) ]]; then
    echo "ERROR: --evidence requires a Git branch review" >&2; return 1
  fi
  [[ "$IN_GIT_REPO" == "true" ]] || return 0

  local exclude before after
  exclude="$(output_dir_repo_relative)"

  if ! before="$(capture_repo_snapshot "$exclude" "${IGNORE_EXCLUDE_PATHSPECS[@]}")"; then
    echo "ERROR: cannot read the repository state — refusing to start." >&2
    echo "       Without a baseline there is no way to tell afterwards whether the" >&2
    echo "       reviewed revision stayed put, and the result could not be trusted." >&2
    return 1
  fi

  create_fixed_diff || return 1

  if ! after="$(capture_repo_snapshot "$exclude" "${IGNORE_EXCLUDE_PATHSPECS[@]}")"; then
    echo "ERROR: cannot re-read the repository state while fixing this run's diff." >&2
    return 1
  fi
  if [[ "$before" != "$after" ]]; then
    echo "ERROR: the repository changed while this run's diff was being captured." >&2
    echo "       The captured diff would describe a state that no longer holds." >&2
    echo "       Re-run once the repository is settled." >&2
    return 1
  fi

  REPO_SNAPSHOT_BEFORE="$after"
  if [[ "$REVIEW_EVIDENCE" == true ]]; then
    REVIEW_EVIDENCE_START="${OUTPUT_DIR}/.evidence-start.$$.json"
    local evidence_args=(begin --file "$REVIEW_EVIDENCE_START" --output "$OUTPUT_DIR"
      --base "$BASE_BRANCH" --plan "${FULL_EXECUTION_PLAN:-$EXECUTION_PLAN}" --main "${REVIEW_MAIN:-}")
    [[ -z "$REVIEW_EVIDENCE_PRIOR" ]] || evidence_args+=(--prior "$REVIEW_EVIDENCE_PRIOR")
    [[ -z "$REVIEW_EVIDENCE_PARENT" ]] || evidence_args+=(--parent "$REVIEW_EVIDENCE_PARENT")
    run_review_evidence "${evidence_args[@]}" || return 1
    # Once this run begins successfully, discard the previous ready receipt.
    # A begin failure keeps the old receipt, which still only proves its own subject.
    rm -f "${OUTPUT_DIR}/review-evidence.json" || return 1
  fi
  return 0
}

# ── Execute Single Task ──
run_single_task() {
  local cli_name="$1"
  local perspective="$2"

  local adapter
  adapter="$(get_cli_adapter "$cli_name")"

  local perspective_file
  perspective_file="$(resolve_perspective_file "$perspective")"
  local output_file="${OUTPUT_DIR}/${cli_name}/${perspective}.md"

  if [[ -z "$perspective_file" ]]; then
    echo "  ⚠️  Perspective file not found: ${TASK_TYPE}/${perspective}.md" >&2
    return 1
  fi

  if [[ ! -f "$adapter" ]]; then
    echo "  ⚠️  Adapter not found: ${adapter}" >&2
    return 1
  fi

  local extra_args=()
  extra_args+=(--task-type "$TASK_TYPE")
  if [[ -n "$DESCRIPTION" ]]; then
    extra_args+=(--description "$DESCRIPTION")
  fi
  # 固定した diff を全タスクへ配る。渡さなかった場合はアダプタが自分で git から取る
  # （直叩き互換）ので、ここを落とすと不整合が黙って戻る。
  if [[ -n "$FIXED_DIFF_FILE" ]]; then
    extra_args+=(--diff-file "$FIXED_DIFF_FILE")
  fi
  if [[ "$INCLUDE_DIFF" == "true" ]]; then
    extra_args+=(--include-diff)
  fi
  # 委譲レーンはここでだけ経路が分かれる。プロンプト構築・diff の固定・
  # タイムアウトの受け渡しは他レーンと同一のまま、アダプタが CLI を起動しなくなる。
  if task_is_delegated "$cli_name"; then
    extra_args+=(--delegate-dir "$(delegate_dir_for "$cli_name")")
  fi
  if [[ "$TASK_TYPE" == "implement" ]]; then
    local staging_dir
    staging_dir="$(staging_dir_for "$cli_name" "$perspective")"
    # エージェント側で mkdir させない。staging が CWD の外に出る構成（--output-dir で
    # 別の場所を指した場合など）ではサンドボックス下の親ディレクトリ作成が拒まれ、
    # そこで詰まったエージェントは書ける場所を探し始める。既定の staging は CWD 配下
    # なので拒まれないが、その 1 ケースのために毎回エージェント任せにはしない。
    if ! mkdir -p "$staging_dir"; then
      echo "  ❌ Cannot create staging dir: ${staging_dir}" >&2
      echo "     Check the permissions of --output-dir; re-running as-is will fail again." >&2
      return 1
    fi
    # mkdir -p は**既存ディレクトリなら権限に関係なく rc=0** を返す。この検査が
    # 無いと、書き込めない staging に対してプロンプトが "It already exists and is
    # writable" と断言することになる。書けると保証されたエージェントが書き込みを
    # 拒まれると、拒否を報告するより「自分の理解が違う」と解釈して別の場所を
    # 探す方向へ倒れる — プロンプトに書く断定は、コードが検証した分だけにする。
    #
    # -w だけでは足りない。ディレクトリにエントリを作るには write と search(x) の
    # 両方が要るので、mode 0222 は -w を通っても書けない。
    # なお -w -x は必要条件であって十分条件ではない（ACL・read-only マウント・
    # 容量不足はここでは分からない）。build_prompt 側でも同じ検査をしている。
    if [[ ! -w "$staging_dir" || ! -x "$staging_dir" ]]; then
      echo "  ❌ Staging dir is not writable: ${staging_dir}" >&2
      echo "     Check the permissions of --output-dir; re-running as-is will fail again." >&2
      return 1
    fi
    extra_args+=(--staging-dir "$staging_dir")
  fi

  # 全 adapter を対象リポジトリの物理 root から起動する。サブディレクトリから
  # orchestrator を呼んでも CLI の CWD（sandbox root）を狭めないためで、diff の
  # repository-relative path 解決も同じ基準へ固定される。
  ( cd "$REPO_ROOT" && \
    if [[ "$STAGED_DIFF" == "true" ]]; then
      bash "$adapter" "$perspective_file" "$output_file" \
        --staged --timeout "$TIMEOUT" "${extra_args[@]}"
    else
      bash "$adapter" "$perspective_file" "$output_file" \
        --base "$BASE_BRANCH" --timeout "$TIMEOUT" "${extra_args[@]}"
    fi )
}

# ── Host Load Gate（レーン起動前の load average 実測） ──
# 同一ホストの負荷が高い状態で並列レーンを起こすと、子の CLI / サブエージェントが
# 無進捗のまま stall して失敗し、再起動 1 回分の時間とトークンを失う。負荷源は自分の
# 全件ゲートに限らず、同じホストで動く並行セッションでも同じ形で起きる。そこで並列
# 起動の直前に 1 分平均の load average を実測し、コア数 × 係数を超えていれば今回の
# 実行を逐次（--sequential 相当）へ倒す。閾値以下なら何も出さずに従来どおり並列。
# 係数の既定 10 と根拠（load 295 / 16 コアで stall、150 / 16 コアで stall 0、1 コア
# あたり 10 超で stall）の正本は docs-template/05-operations/deployment/
# multi-cli-review-orchestration.md の「レーン起動前の負荷判定」節。
# FF_MULTI_AGENT_LOAD_PER_CORE: 係数（6 桁までの非負整数）。0 で判定を無効化する。
# FF_MULTI_AGENT_LOAD_SAMPLE: 内部（テストの注入口）。実測の代わりに使う値。
LOAD_GATE_DEFAULT_PER_CORE=10

# 係数の書式検査。main がプラン構築前（dry-run・--sequential・1 タスクでも）に 1 回だけ
# 呼ぶ — execute_tasks の中で初めて弾くと、前回結果の削除・退避が済んだ後で止まる。
# 6 桁上限は算術展開の桁あふれ（閾値が負になり常に逐次へ倒れる）を防ぐため。
validate_load_gate_config() {
  local per_core="${FF_MULTI_AGENT_LOAD_PER_CORE:-$LOAD_GATE_DEFAULT_PER_CORE}"
  if [[ ! "$per_core" =~ ^[0-9]{1,6}$ ]]; then
    echo "ERROR: FF_MULTI_AGENT_LOAD_PER_CORE は 6 桁までの非負整数で指定してください（0 で負荷判定を無効化）: '${per_core}'" >&2
    return 2
  fi
}

# sysctl は macOS では /usr/sbin にあり、PATH を絞った起動（CI・hook）では見えないことがある。
load_gate_sysctl() {
  if command -v sysctl >/dev/null 2>&1; then
    LC_ALL=C sysctl "$@"
  elif [[ -x /usr/sbin/sysctl ]]; then
    LC_ALL=C /usr/sbin/sysctl "$@"
  else
    return 127
  fi
}

# 1 分平均の load average を stdout へ 1 語で出す。取れなければ rc=1（何も出さない）。
measure_load_average() {
  local sample=""
  if [[ -n "${FF_MULTI_AGENT_LOAD_SAMPLE:-}" ]]; then
    sample="$FF_MULTI_AGENT_LOAD_SAMPLE"
  elif [[ -r /proc/loadavg ]]; then
    sample="$(awk '{print $1; exit}' /proc/loadavg 2>/dev/null)" || sample=""
  else
    # macOS: "{ 3.74 4.48 14.04 }"
    sample="$(load_gate_sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1; exit}')" || sample=""
  fi
  [[ "$sample" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  printf '%s\n' "$sample"
}

# 論理コア数を stdout へ出す。取れなければ rc=1。
measure_cpu_cores() {
  local cores=""
  if command -v getconf >/dev/null 2>&1; then
    cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || cores=""
  fi
  if [[ ! "$cores" =~ ^[1-9][0-9]*$ ]] && command -v nproc >/dev/null 2>&1; then
    cores="$(nproc 2>/dev/null)" || cores=""
  fi
  if [[ ! "$cores" =~ ^[1-9][0-9]*$ ]]; then
    cores="$(load_gate_sysctl -n hw.ncpu 2>/dev/null)" || cores=""
  fi
  [[ "$cores" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$cores"
}

# 並列実行の直前に 1 回だけ呼ぶ。係数の書式は validate_load_gate_config が検査済み。
apply_load_gate() {
  [[ "$PARALLEL" == "true" ]] || return 0
  local task_count
  task_count="$(printf '%s\n' "$EXECUTION_PLAN" | awk 'NF && !seen[$0]++' | wc -l | tr -d ' ')"
  [[ "$task_count" -gt 1 ]] || return 0
  local per_core="${FF_MULTI_AGENT_LOAD_PER_CORE:-$LOAD_GATE_DEFAULT_PER_CORE}"
  per_core=$((10#$per_core))
  [[ "$per_core" -gt 0 ]] || return 0
  local load cores threshold
  if ! load="$(measure_load_average)"; then
    if [[ -n "${FF_MULTI_AGENT_LOAD_SAMPLE:-}" ]]; then
      echo "ℹ️  負荷判定: FF_MULTI_AGENT_LOAD_SAMPLE が数値ではないため（'${FF_MULTI_AGENT_LOAD_SAMPLE}'）、並列のまま起動します。" >&2
    else
      echo "ℹ️  負荷判定: load average を実測できないため、並列のまま起動します。" >&2
    fi
    return 0
  fi
  if ! cores="$(measure_cpu_cores)"; then
    echo "ℹ️  負荷判定: コア数を実測できないため、並列のまま起動します。" >&2
    return 0
  fi
  threshold=$((cores * per_core))
  if awk -v l="$load" -v t="$threshold" 'BEGIN { exit !(l > t) }'; then
    PARALLEL=false
    echo "⚠️  負荷判定: load average ${load} > 閾値 ${threshold}（${cores} コア × ${per_core}）— ${task_count} タスクを並列にせず逐次で実行します（FF_MULTI_AGENT_LOAD_PER_CORE で係数を変更、0 で無効）。" >&2
  fi
  return 0
}

# ── Path-Segment Safety ──
# A CLI / perspective name is used as a single path segment under OUTPUT_DIR.
# Reject anything that is not a plain identifier so a crafted --cli/--perspective
# value (e.g. "../../secret") cannot escape OUTPUT_DIR when we build result paths.
is_safe_token() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

# ── Validate Execution Plan ──
# Fail loud (never a silent skip) if any plan entry carries a cli/perspective
# token that is not a safe single path segment. Called once at each consumption
# entry point (execute_tasks, generate_report) BEFORE the plan is used, so a
# crafted --cli/--perspective value cannot reach the execute (write), cleanup, or
# report (read) paths and escape OUTPUT_DIR — and a malformed plan surfaces as an
# error instead of silently collapsing to "(No results found.)".
validate_execution_plan() {
  local entry cli_name persp_name bad=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Require the exact "cli:perspective" shape. Without a ':', ${entry%%:*} and
    # ${entry#*:} both collapse to the whole string, so a malformed entry would
    # otherwise pass and drive read/delete/write at the wrong path.
    if [[ "$entry" != *:* ]]; then
      echo "ERROR: malformed execution plan entry (expected 'cli:perspective'): '${entry}'" >&2
      bad=1
      continue
    fi
    cli_name="${entry%%:*}"
    persp_name="${entry#*:}"
    if ! is_safe_token "$cli_name" || ! is_safe_token "$persp_name"; then
      echo "ERROR: unsafe token in execution plan entry: '${entry}'" >&2
      bad=1
    fi
  done <<< "$EXECUTION_PLAN"
  [[ "$bad" -eq 0 ]]
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-prepare.sh"
