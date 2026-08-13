#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# adapter-common.sh — Multi-CLI Agent: Shared Utilities
# ────────────────────────────────────────────────────────────
# Usage: source this file from any CLI adapter
#   source "$(dirname "$0")/adapter-common.sh"
# ────────────────────────────────────────────────────────────

# Note: Do NOT set -euo pipefail here. This file is source'd by adapters
# which have their own set -euo pipefail. Setting it here would cause
# return 1 in functions to kill the sourcing process under set -e.

# ── CLI Detection ──

# Check if a CLI command is available
# Usage: cli_available "claude"
cli_available() {
  command -v "$1" &>/dev/null
}

# ── Git Helpers ──

# ── Base Branch Resolution ──
#
# 検出を 2 つの原子操作に割ってあるのは multi-agent.sh と実装を共有するため。
# orchestrator は「origin/HEAD から自動検出した」のか「origin/HEAD が無くて develop へ
# 倒した」のかを利用者へ名乗り分ける必要があり、両者を畳んだ detect_base_branch の
# 戻り値だけでは区別できない。以前はそのために orchestrator 側が同じ検出を書き写して
# おり、「keep this detection in sync」というコメントで人手同期を約束していた。

# origin/HEAD が指す既定ブランチ名。設定されていなければ**空**を返す。
# "develop" への既定化をここでやらないのは、上記のとおり呼び出し側の方針だから。
default_base_branch_name() {
  git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true
}

# `git diff <ref>...HEAD` に渡せる形へ解決する。ローカルブランチを優先し、無ければ
# remote-tracking ref へ倒す（clone 直後はローカルブランチが存在しない）。
resolve_base_branch_ref() {
  local b="$1"
  if git rev-parse --verify --quiet "refs/heads/${b}" >/dev/null; then
    echo "$b"
  elif git rev-parse --verify --quiet "refs/remotes/origin/${b}" >/dev/null; then
    echo "origin/${b}"
  else
    echo "$b"
  fi
}

# Detect the repository default branch (origin/HEAD), falling back to "develop".
# Returns a ref usable with `git diff <ref>...HEAD`.
detect_base_branch() {
  local b
  b="$(default_base_branch_name)"
  if [[ -z "$b" ]]; then b="develop"; fi
  resolve_base_branch_ref "$b"
}

# ── Repository Revision Snapshot ──
#
# 実行前後で「レビュー対象が動いていないこと」を確かめるための 1 行スナップショット。
# HEAD の SHA・ブランチ名・作業ツリー状態のハッシュを空白区切りで返す。
#
# 3 つ全部を見るのは、どれか 1 つでは取りこぼすため:
#   - SHA だけ …… 同じコミットを指す別ブランチへの切り替えが見えない
#   - ブランチ名だけ …… commit や detached での移動が見えない
#   - 作業ツリーだけ …… tracked 内容が同一なブランチ間の移動が見えない
#
# 作業ツリーは untracked も含めて見る（status を --untracked-files=no にしない）。
# ただし untracked の**内容**まで見ているのは下の ls-files 側で、status が担うのは
# 出現・消滅と状態遷移まで。
# implement タスクが staging ではなく作業ツリーへ生成物を書いた事故は**新規ファイルの出現**と
# してしか現れず、tracked だけを見ていると最も危険なケースを検出できない（実測で
# 確認済み: -uno では新規 untracked ファイルの出現がスナップショットに現れない）。
#
# 第 1 引数は「除外するリポジトリ相対パス」。orchestrator 自身が実行中に成果物を
# 書き込む出力ディレクトリを数えると、正常な実行が毎回「変化した」になる — 利用者の
# リポジトリが .review-results/ を gitignore しているとは限らない。
#
# git のコマンドは**リポジトリ root へ cd してから**実行する。走査範囲そのものは
# pathspec の ':/' が固定するので cd に依存しないが、**`:(exclude)` は CWD 相対**で、
# cd を挟まないと除外がまったく効かない（実測: repo/src から
# `git status --porcelain -- ':/' ':(exclude)b.txt'` を叩くと b.txt がそのまま出る）。
# 効かないと orchestrator 自身の出力を数えてしまい、正常な実行が毎回「変化した」で
# 落ちる — 静かに見逃すのではなく 100% 失敗する側へ倒れる。
capture_repo_snapshot() {
  local exclude_rel="${1:-}"
  local root head branch worktree worktree_hash

  if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    return 1
  fi

  # コミットが 1 つも無い状態は「失敗」ではなく「状態」— 前後で同じ値になるので比較は
  # 成立する。git 自体が答えられない場合とは symbolic-ref で切り分ける。
  if head="$(git rev-parse --verify --quiet HEAD 2>/dev/null)"; then
    :
  elif git symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    head="unborn"
  else
    return 1
  fi

  # detached HEAD では symbolic-ref が空を返す（rc=1）。どのコミットに居るかは SHA が
  # 捉えるので、ここは「ブランチに乗っていない」ことを記録できれば足りる。
  branch="$(git symbolic-ref --short --quiet HEAD 2>/dev/null)" || branch="(detached)"
  if [[ -z "$branch" ]]; then branch="(detached)"; fi

  # pathspec は必ず ':/'（リポジトリ全体）から始める。除外だけを渡すと git の解釈が
  # 版によって割れるうえ、意図も読み取りにくい。
  local pathspec
  pathspec=(':/')
  if [[ -n "$exclude_rel" ]]; then
    # `literal` を必ず付ける。付けないと git はパターンとして解釈し、`--output-dir 'a*'`
    # のような名前が無関係なパス（abc/ など）まで監視から外す（実測: ':(exclude)a*' は
    # a*/ と abc/ の両方を消し、':(exclude,literal)a*' は a*/ だけを消す）。監視範囲が
    # 黙って縮む形なので、この機構が防ごうとしている失敗と同じ種類になる。
    pathspec+=(":(exclude,literal)${exclude_rel}")
  fi

  # **`git status --porcelain` だけでは足りない。** 返るのは状態コードとパスであって
  # 内容ではないので、実行前から変更済みのファイル（` M path`）を実行中にさらに
  # 編集しても出力は同じ ` M path` のまま = 変化なしと判定される（実測で再現した）。
  # レビュー対象に未コミット変更があるのは異常系ではなく通常の使い方で、diff も
  # `git diff HEAD` を和集合に含めている以上、この取りこぼしは中心的なケースを直撃する。
  # そこで内容そのものも指紋へ入れる:
  #   - status ……… 追加・削除・rename・untracked の**出現**と状態遷移
  #   - diff HEAD … tracked の**内容**（staged / unstaged をまとめた worktree の姿）
  #   - diff --cached … index の**内容**。単なる再 stage は status の状態コードが
  #                     ` M`→`M ` と動くので status でも拾えるが、`MM` のまま index
  #                     だけが書き換わる形（git apply --cached 等）はコードが動かず、
  #                     diff HEAD も worktree 側を見るので変化しない。ここだけが拾える
  #
  #   - untracked の内容 … 既存の untracked ファイルを上書きされても状態コードは
  #                        `?? path` のまま変わらないため、内容を別に取る
  #
  # 見えないものを明示しておく（この指紋の限界）:
  #   - **gitignore 済みパスへの書き込み**は丸ごと見えない。status も
  #     ls-files --exclude-standard も無視するため、node_modules/ や dist/ へ書かれても
  #     スナップショットは動かない
  #   - 除外パス配下の変化（設計どおり）
  #   - 実行中に起きて実行前の状態へ戻された変化（前後比較の原理的な限界）
  #   - 内容を取れない untracked エントリ（symlink・読めないファイル）の中身
  #
  # 除外は 4 つの問い合わせすべてに同じものを効かせる。片方だけに効かせると、
  # 「同じリポジトリを 2 つの物差しで測る」形になり、この機構が防ごうとしている
  # 食い違いを自分で作る。除外先がソースを含む場合（`--output-dir src` 等）に監視が
  # 消える問題は、ここではなく**入口で弾く**ことで解いている（orchestrator 側の
  # validate_output_dir_boundary。出力先に tracked ファイルがあれば起動を止める）。
  # そのため「orchestrator は tracked ファイルを書き換えない」が前提として成立し、
  # 除外を diff に効かせても実コードの変更が漏れることはない。
  worktree="$(
    cd "$root" || exit 1
    git status --porcelain -- "${pathspec[@]}" || exit 1
    # unborn（コミットが 1 つも無い）で失敗するのは **git diff HEAD だけ**（rc=128）。
    # --cached は空ツリー相手に成立するので回す — git add は最初の commit より前から
    # 効くので、初回コミット前でも index には内容が入りうる。両方まとめて飛ばすと、
    # `A  path` のまま stage 内容だけを差し替える変化を取りこぼす（実測で確認）。
    if [[ "$head" != "unborn" ]]; then
      git diff HEAD -- "${pathspec[@]}" || exit 1
    fi
    git diff --cached -- "${pathspec[@]}" || exit 1
    # 内容を取るのは**通常ファイルで読めるものだけ**に絞る。git hash-object は blob に
    # できないものに当たると fatal で落ちる（実測: symlink→ディレクトリで
    # "Unable to hash dirlink"、壊れた symlink と mode 000 で "could not open ... for
    # reading"）。素通しにすると、リポジトリに untracked の symlink が 1 つあるだけで
    # スナップショット取得が失敗し、**ツール全体が起動しなくなる**。gitignore 済みは
    # --exclude-standard が既に除くので、残るのは「無視されていない untracked の
    # symlink や読めないファイル」— 未 ignore の pnpm/venv の symlink、中断した
    # ビルドが残した壊れたリンク、共有チェックアウト上の他人所有ファイルなど、
    # 普通に存在しうるものばかり。
    #
    # 内容を取れないものを落としても、守りたいものは失われない。生成物の作業ツリー
    # 流出は「新しいパスの出現」として現れ、それは上の git status が捉えている。
    # ここで足しているのは「**既にある** untracked ファイルの中身が変わった」分だけ。
    #
    # パスに改行を含む場合も同じ理由で内容対象から外す（--stdin-paths は 1 行 1 パス
    # なので分割が壊れる）。存在自体は status 側に出るので、監視から消えるわけではない。
    git ls-files --others --exclude-standard -z -- "${pathspec[@]}" \
      | while IFS= read -r -d '' untracked_path; do
          # 改行を含むパスは内容の対象から外す。case のパターンへ改行を持つ
          # コマンド置換を書くと、構文検査は通るのに実行時に落ちる（実測）ので
          # ANSI-C quoting で書く。
          if [[ "$untracked_path" == *$'\n'* ]]; then
            continue
          fi
          if [[ -f "$untracked_path" && -r "$untracked_path" ]]; then
            printf '%s\n' "$untracked_path"
          fi
        done \
      | git hash-object --stdin-paths || exit 1
  )" || return 1

  # ハッシュ化は git 自身にやらせる。md5 / sha1sum / shasum は OS ごとに名前も出力形も
  # 違うが、git は本関数が動く前提そのもの。ロケール依存の text 処理も挟まない。
  worktree_hash="$(printf '%s' "$worktree" | git hash-object --stdin 2>/dev/null)" || return 1

  printf '%s %s %s\n' "$head" "$branch" "$worktree_hash"
}

# Get the diff content for review
# Usage: get_diff_content "develop"
get_diff_content() {
  local base_branch="${1:-$(detect_base_branch)}"
  if [[ "${STAGED_DIFF:-false}" == "true" ]]; then
    if git diff --cached 2>/dev/null; then
      return 0
    fi
    echo "ERROR: Failed to get staged diff content." >&2
    return 1
  fi
  # main のレビュー対象ガードは「ブランチ差分または作業ツリー差分があれば実行」と
  # 判定する。ここも同じ和集合をプロンプトへ載せる。ブランチ差分だけを返すと、
  # BASE...HEAD が空で staged / unstaged 変更だけがある pre-commit 経路で、ガードは
  # 通るのに 0 byte の diff をレビューして成功する。
  if ! git diff "${base_branch}...HEAD" 2>/dev/null; then
    echo "WARNING: Could not diff against '${base_branch}', falling back to HEAD diff." >&2
    if git diff HEAD 2>/dev/null; then
      return 0
    fi
    echo "ERROR: Failed to get diff content. Are you in a git repository with commits?" >&2
    return 1
  fi
  if git diff HEAD 2>/dev/null; then
    return 0
  fi
  echo "ERROR: Failed to get working-tree diff content." >&2
  return 1
}

# プロンプトへ載せる diff を返す。
#
# DIFF_FILE（orchestrator が --diff-file で渡す）があればその中身をそのまま使い、
# 無ければ従来どおり自分で git から取る — アダプタ直叩きの後方互換。
#
# なぜ orchestrator が固定するのか: 以前は各アダプタが**自分の起動時に**
# get_diff_content を呼んでいた。並列タスクの起動時刻はばらけるので、実行中に
# checkout / commit / stash が入ると**タスクごとに別の瞬間の diff** をレビューし、
# しかも全員が正常終了する。
#
# **存在しない / 読めない DIFF_FILE では従来取得へ落ちない。** 落とすと、固定した
# はずの diff が失われたまま各タスクがそれぞれ別の diff を読む状態へ静かに戻る —
# この固定機構が塞いでいる不整合そのものを、警告なしで再現することになる。
#
# 空の DIFF_FILE はエラーにしない。review は orchestrator 側の事前ガードが空 diff を
# 止めるが、implement --include-diff にその保証は無く、「まだ変更が無い」という
# 正常な状態をハードエラーへ変えてしまう。
prompt_diff_content() {
  local base_branch="${1:-}"
  if [[ -n "${DIFF_FILE:-}" ]]; then
    if [[ ! -f "$DIFF_FILE" || ! -r "$DIFF_FILE" ]]; then
      echo "ERROR: --diff-file is missing or unreadable: ${DIFF_FILE}" >&2
      echo "       Refusing to recompute the diff: the orchestrator fixed it so that every" >&2
      echo "       task in this run reviews the same bytes." >&2
      return 1
    fi
    # cat の rc を捨てない。捨てると、-r 検査の後にファイルが消えた / I/O エラーに
    # なった場合に、空または途中までの内容で rc=0 を返す — 上で「静かに戻さない」と
    # 宣言した退行の、より弱い形を自分で作ることになる。
    if ! cat "$DIFF_FILE"; then
      echo "ERROR: could not read the fixed diff: ${DIFF_FILE}" >&2
      return 1
    fi
    return 0
  fi
  get_diff_content "$base_branch"
}

# ── Perspective Loading ──

# Read a perspective file and return its content
# Usage: load_perspective "scripts/perspectives/code-review.md"
load_perspective() {
  local perspective_file="$1"
  if [[ ! -f "$perspective_file" ]]; then
    echo "ERROR: Perspective file not found: $perspective_file" >&2
    return 1
  fi
  cat "$perspective_file"
}

# ── Prompt Builder ──

# Build a prompt from perspective + context (task-type aware)
# Usage: build_prompt "scripts/perspectives/code-review.md" "develop" "file1.ts file2.ts"
# Task-type is read from TASK_TYPE variable (default: review)
# Description is read from DESCRIPTION variable (for explore/implement)
# Staging dir is read from STAGING_DIR variable (implement only; see Issue #392)
build_prompt() {
  local perspective_file="$1"
  local base_branch="${2:-$(detect_base_branch)}"
  local changed_files="${3:-}"
  local task_type="${TASK_TYPE:-review}"
  local description="${DESCRIPTION:-}"
  # implement のみ意味を持つ。review / explore は read-only なので、値が入って
  # いても無視する（下の file_boundary が task_type で分岐する）。
  local staging_dir="${STAGING_DIR:-}"
  local inline_output="${INLINE_OUTPUT:-false}"

  # 「staging を渡し忘れた」と「意図的な直叩き」は、STAGING_DIR が空という
  # 一点で区別がつかない。区別できないままだと前者が静かに退避モード（インライン
  # 出力）へ落ちる — しかも成果物ファイル ${persp}.md は inline 内容を含んで
  # 正常に書かれるので、「出力ファイルが無い」バックストップにも掛からず、
  # exit 0・生成ファイル 0 個・警告なしで終わる。
  # 分岐条件が multi-agent.sh（TASK_TYPE == implement で --staging-dir を付ける）と
  # ここの 2 ファイルに二重化されている以上、片方だけが変わる事故は起こりうる。
  # そこで退避モードを明示的なオプトインにし、渡し忘れは大声のエラーにする。
  # 出力モードは排他。両方渡されたとき片方を黙って優先すると、呼び出し側は
  # 「inline を頼んだのにファイルが書かれた」形の食い違いを警告なしで受け取る。
  if [[ -n "$staging_dir" && "$inline_output" == "true" ]]; then
    echo "ERROR: --staging-dir and --inline-output are mutually exclusive." >&2
    echo "       Pick one output mode: write under the staging dir, or report inline." >&2
    return 1
  fi

  if [[ "$task_type" == "implement" && -z "$staging_dir" && "$inline_output" != "true" ]]; then
    echo "ERROR: implement task has no --staging-dir." >&2
    echo "       Pass --staging-dir <dir>, or --inline-output to have the CLI report" >&2
    echo "       generated file contents inline instead of writing them." >&2
    return 1
  fi

  # 下の file_boundary は staging について 3 つのことを断言する — 絶対パスである、
  # 実在する、書き込める。断言する層で検証しておかないと、直叩き実行が渡した
  # 相対パス・不在パス・read-only パスに対しても同じ断言が出る。
  # 相対パスが特に危険: 「これは絶対パスだ」と言われたエージェントは自分の CWD
  # 基準で解決するので、書き込み先が作業ツリーになる。
  if [[ "$task_type" == "implement" && -n "$staging_dir" ]]; then
    case "$staging_dir" in
      /*) ;;
      *)
        echo "ERROR: --staging-dir must be an absolute path (the prompt says so): ${staging_dir}" >&2
        return 1
        ;;
    esac
    if [[ ! -d "$staging_dir" ]]; then
      echo "ERROR: --staging-dir does not exist: ${staging_dir}" >&2
      return 1
    fi
    # ディレクトリにエントリを作るには write と search(x) の両方が要る。
    # -w だけだと mode 0222 が検査を通ってしまう。必要条件であって十分条件では
    # ない点は変わらない（ACL・read-only マウントはここでは分からない）。
    if [[ ! -w "$staging_dir" || ! -x "$staging_dir" ]]; then
      echo "ERROR: --staging-dir is not writable: ${staging_dir}" >&2
      return 1
    fi
  fi

  local perspective_content
  if ! perspective_content="$(load_perspective "$perspective_file")"; then
    return 1
  fi

  # Task-type specific preamble and context
  local preamble=""
  local context_section=""

  case "$task_type" in
    review)
      preamble="You are a code review agent. Follow the perspective instructions below to analyze the code changes."

      local diff_content
      if ! diff_content="$(prompt_diff_content "$base_branch")"; then
        echo "ERROR: aborting prompt build — no diff content available." >&2
        return 1
      fi

      local files_section=""
      if [[ -n "$changed_files" ]]; then
        files_section="
## Changed Files
${changed_files}
"
      fi

      context_section="${files_section}
## Code Changes (git diff)

${diff_content}"
      ;;

    explore)
      preamble="You are a codebase exploration agent. Follow the perspective instructions below to analyze the codebase. Do NOT modify any files — this is a read-only exploration task."

      if [[ -n "$description" ]]; then
        context_section="
## Exploration Target

${description}"
      fi
      ;;

    implement)
      # preamble と下の file_boundary は同じ分岐で揃える。片方だけが
      # 「staging へ書け」と言い、もう片方が「書くな」と言う状態にすると、
      # エージェントは矛盾を自分で解消して working tree へ書きに行く。
      if [[ -n "$staging_dir" ]]; then
        preamble="You are an implementation agent. Follow the perspective instructions below to generate code. Write all generated files under the staging directory named in the execution boundary below — do NOT write directly to the working tree."
      else
        preamble="You are an implementation agent. Follow the perspective instructions below to generate code. No staging directory is available in this run, so report the generated files inline — do NOT write to the working tree."
      fi

      if [[ -n "$description" ]]; then
        context_section="
## Task Description

${description}"
      fi

      # Optionally include diff for implement tasks
      if [[ "${INCLUDE_DIFF:-false}" == "true" ]]; then
        local diff_content
        # rc を検査する。捨てると、diff を取れなかった実行が「## Current Changes」の
        # 見出しだけを持つプロンプトとして通り、エージェントには「変更が無い」と
        # 読める — 取得失敗と「変更なし」は別の事実で、後者だけが正常。
        if ! diff_content="$(prompt_diff_content "$base_branch")"; then
          echo "ERROR: aborting prompt build — --include-diff was requested but no diff content is available." >&2
          return 1
        fi
        context_section="${context_section}

## Current Changes (git diff)

${diff_content}"
      fi
      ;;

    *)
      preamble="You are an AI agent. Follow the perspective instructions below."
      ;;
  esac

  # ── Execution boundary（Issue #263） ──
  # サブプロセスの CLI がレビュー対象プロジェクトの AGENTS.md / CLAUDE.md /
  # レビュー用スキルを読み込み、プロジェクト規約に従って**別のレビューラッパーや
  # AI CLI を再帰起動**して、結果を返さないままタイムアウトする事故が実際に起きた
  # （ai-books の実レビューで再現）。この境界宣言は perspective より**前**に置く —
  # プロジェクト側の指示文より先に読ませる意図の設計判断で、前置と後置の効果差は
  # 未測定（tests/adapter-prompt-guard が固定するのは位置の一貫性まで）。
  # review / explore は read-only、implement は staging への出力を許すため、
  # ファイル操作の行だけ task-type で切り替える。
  # 注意: **プロンプトとファイル操作権限の整合について**、新しい task-type を足す
  # ときは (1) 上の preamble の case、(2) 各アダプタの task-type 分岐、(3) staging
  # パスを渡すかどうか（multi-agent.sh の run_single_task）を同時に揃えること。
  # (2) の関数名はアダプタごとに違う: codex は get_sandbox_mode、grok は
  # get_sandbox_profile、gemini は get_gemini_sandbox_flag、**claude-code は
  # get_allowed_tools**（Write/Edit を許すかどうかが唯一の書き込みゲート。"sandbox"
  # で grep すると取りこぼす）、copilot は permission deny 配列。どれか 1 つを忘れると
  # 「サンドボックスは書けるのにプロンプトが read-only を命じる」「staging へ書けと
  # 命じるのにパスを渡していない」といった矛盾になる。
  # なお task-type 追加そのものに必要な同期先（perspective の割り当て、既定の
  # output_dir / timeout / strategy、レポート生成）は multi-agent.sh 側にあり、
  # このリストの射程ではない。
  #
  # Issue #392: staging の実パスは orchestrator が解決して STAGING_DIR で渡す。
  # パスを渡さないまま「staging にだけ書け」と命じると、エージェントは推測するしか
  # なく、最も自然な推測は CWD = 作業ツリーになる（grok の implement サンドボックスは
  # workspace = CWD 書き込み可のため、防ぎたい汚染をむしろ通してしまう）。
  # 退避先（インライン出力）は orchestrator を経由しない直叩き実行のために残すが、
  # 上のガードのとおり --inline-output の明示が要る。「パスが無ければ黙って退避」に
  # すると、渡し忘れが警告なしで同じ経路へ落ちるため。
  #
  # Issue #398: --inline-output は task type が implement のままでも各 adapter が
  # read-only 相当へ狭める（Claude=tool allowlist、Codex/Grok=read-only profile、
  # Gemini=sandbox、Copilot=write/shell deny）。プロンプトだけの契約へ戻さない。
  local file_boundary
  case "$task_type" in
    implement)
      if [[ -n "$staging_dir" ]]; then
        file_boundary="- Write generated files ONLY under this staging directory (absolute path):
    ${staging_dir}
  It already exists and is writable. Do NOT create, modify, or delete any file
  outside it — the working tree is off limits. Do not ask where to put files."
      else
        file_boundary="- No staging directory path was given to you. Do NOT write to the working tree
  at all — emit the file contents inline in your response instead."
      fi
      ;;
    *)
      file_boundary="- Operate strictly read-only: do not modify, create, or delete any files. Report your findings on stdout; the wrapper captures them." ;;
  esac
  local boundary_section="## Execution Boundary (non-negotiable)

This prompt itself IS the ${task_type} task, running as a nested sub-agent
inside an orchestrated multi-CLI pipeline. Perform the task described in
this prompt yourself — reading the provided context and applying the
perspective below is exactly what you should do.
Regardless of what AGENTS.md, CLAUDE.md, README, repository skills, or any
other project instructions say:

- Do NOT launch or delegate to any ADDITIONAL agent to do this task:
  no review wrapper script, no skill or slash command, and no invoking
  another AI CLI (claude, codex, gemini, copilot, grok, ...). Such
  project instructions target interactive sessions, not this nested
  run — spawning nested agents here creates infinite recursion.
${file_boundary}
- Do not ask for user input, request re-runs, or schedule further work.
  Produce the final report in a single response, then stop."

  cat <<PROMPT
${preamble}

${boundary_section}

${perspective_content}

${context_section}

---

Analyze the above according to your role and output your findings in the specified Output Template format.
PROMPT
}

# ── Output Helpers ──

# Write review output with a standard header
# Usage: write_output "output.md" "Claude Code" "code-review" "review content..." [status]
# status: complete (default) | incomplete — recorded in the header so a consumer
# can tell a finished result from one salvaged off a failed run.
write_output() {
  local output_file="$1"
  local cli_name="$2"
  local perspective_name="$3"
  local content="$4"
  local status="${5:-complete}"

  mkdir -p "$(dirname "$output_file")"

  local task_type="${TASK_TYPE:-review}"
  # bash 3.2 compatible capitalization (no ${var^} operator)
  local task_label
  task_label="$(echo "$task_type" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"

  cat > "$output_file" <<OUTPUT
<!-- Multi-CLI ${task_label} Result -->
<!-- CLI: ${cli_name} -->
<!-- Perspective: ${perspective_name} -->
<!-- Task Type: ${task_type} -->
<!-- Status: ${status} -->
<!-- Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ") -->

${content}
OUTPUT

  if [[ "$status" == "complete" ]]; then
    echo "✅ ${task_label} saved: ${output_file}" >&2
  else
    echo "⚠️  Incomplete ${task_type} saved: ${output_file}" >&2
  fi
}

# ── Timeout Wrapper ──

# Exit status meaning "the wall-clock limit fired", matching timeout(1)'s 124.
readonly TIMEOUT_EXIT_CODE=124
# 128+SIGKILL: the command was SIGKILLed without our deadline having fired.
readonly SIGKILL_EXIT_CODE=137
# This wrapper itself could not run the command (temp file unavailable, etc).
# Distinct from any status the command could return, so an orchestrator fault is
# never filed against the CLI.
readonly ORCHESTRATOR_ERROR_EXIT_CODE=125
# Seconds between the deadline's SIGTERM and the SIGKILL that follows it.
# Overridable so the regression suite can exercise the escalation quickly.
TIMEOUT_KILL_GRACE="${FF_TIMEOUT_KILL_GRACE:-10}"
readonly TIMEOUT_KILL_GRACE

# ── Out-of-band Failure Reason ──
# An exit status is a single channel, and 124/125 are only *conventionally* free:
# a CLI that exits 124 or 125 on its own would be filed as "the deadline fired" or
# "the orchestrator broke" and handed the matching wrong remedy. run_with_timeout
# knows which it was (it holds the marker), so it records the reason here and
# callers read it instead of inferring from the number.
#
# Why a file and not a variable: run_with_timeout runs inside `result=$(...)`, and
# anything it assigns dies with that subshell. `$$` stays the invoking shell's pid
# in a subshell, so both sides derive the same path with no argument to thread
# through — and separate adapter processes get separate files.
timeout_reason_file() {
  # Test seam (Issue #266): pin the marker path so write-failure / residue tests
  # do not depend on TMPDIR layout. Production callers leave this unset.
  if [[ -n "${FF_TIMEOUT_REASON_FILE:-}" ]]; then
    printf '%s\n' "$FF_TIMEOUT_REASON_FILE"
    return 0
  fi
  printf '%s\n' "${TMPDIR:-/tmp}/ff-run-with-timeout-reason.$$"
}

# run_with_timeout 自身が書くのは timeout | orchestrator-error | command の 3 値。
# アダプタが上書きで書く値（sandbox-refused | empty-output）もここを通る。
record_timeout_reason() {
  local reason="$1" f
  f="$(timeout_reason_file)"
  # 書けなくても呼び出し側の失敗処理は続ける（従来どおり）。ただし黙ると
  # empty-output が status 1 へ化けたり stale な timeout 案内の種になるので、
  # 失敗時は stderr へ 1 行だけ警告する（Issue #266）。
  if ! printf '%s' "$reason" >"$f" 2>/dev/null; then
    echo "WARNING: could not record timeout reason '${reason}' at ${f}; failure classification may fall back to the exit status only." >&2
  fi
}

# Echoes the recorded reason, or "" when it could not be recorded (a broken TMPDIR
# takes the file with it). An empty reason means "fall back to reading the status".
read_timeout_reason() {
  local f
  f="$(timeout_reason_file)"
  [[ -f "$f" ]] || return 0
  cat "$f" 2>/dev/null || true
}

clear_timeout_reason() {
  rm -f "$(timeout_reason_file)" 2>/dev/null || true
}

# 成功パスでは fail_cli_task が呼ばれないため、run_with_timeout が書いた
# "command" マーカーが ${TMPDIR}/ff-run-with-timeout-reason.$$ に残る（Issue #266）。
# プロセス終了時に必ず掃除し、stale 読み取りの種を残さない。fail_cli_task 内の
# clear と二重になっても rm -f なので害はない。アダプタが source するたびに
# trap を積み重ねないよう一度だけ仕掛ける。
if [[ -z "${_FF_TIMEOUT_REASON_EXIT_TRAP:-}" ]]; then
  _FF_TIMEOUT_REASON_EXIT_TRAP=1
  trap 'clear_timeout_reason' EXIT
fi

# Run a command under a wall-clock limit and echo whatever it wrote to stdout.
# Usage: run_with_timeout 900 some_command arg1 arg2
#
# Returns the command's own exit status, $TIMEOUT_EXIT_CODE (124) when the limit
# fired, or $ORCHESTRATOR_ERROR_EXIT_CODE (125) when this wrapper could not run
# the command at all. Output produced before a kill is still echoed, so a caller
# can salvage partial work instead of discarding it.
#
# Why this supervises the child itself instead of delegating to timeout(1):
# timeout(1)'s exit status cannot say *why* the child died. Measured on GNU
# coreutils 9.7, `timeout -k` returns 124 when the child dies on SIGTERM inside
# the grace period but 137 when it had to escalate to SIGKILL — and a bare 137
# also means "something else SIGKILLed the child" (the OS under memory pressure,
# say). One status, two causes, opposite remedies: "allow more time" fixes the
# first and buries the second. The marker file below removes the ambiguity, so
# 124 always means the deadline and 137 always means an external kill. Running
# one implementation everywhere also means the regression suite covers the code
# that actually runs, on every host.
#
# Three independent guards live here. None substitutes for another:
#
#   1. **The child's stdout goes to a temp file**, never the inherited fd, so the
#      child cannot hold the caller's `$(...)` capture pipe open.
#   2. **The watchdog runs in its own process group and is killed as a group.**
#      This is the guard that makes an early-finishing command return early.
#      Killing only the watchdog subshell leaves its in-flight `sleep` alive as an
#      orphan; an orphan that had inherited the capture pipe keeps `$(...)` from
#      closing, so `result=$(run_with_timeout 900 fast_cmd)` blocked for the full
#      900s even though the command answered in 2s — measured, and exactly what
#      the old implementation did on hosts without timeout(1) (stock macOS; hosts
#      that had timeout(1) never stalled). The /dev/null redirect below is a
#      second line of defence on the same failure: verified that with guard 1 in
#      place but the redirect removed, a 2s command under a 12s limit still
#      blocked the full 12s.
#   3. **The child is a process-group leader and signals go to the group.**
#      Signalling only the direct child leaves the CLI's own workers running —
#      and, for a metered CLI, still billing — past the deadline.
#
# For the record, none of the three caused issue #152's *empty* review. That was
# the adapters' failure path discarding already-captured stdout (see
# fail_cli_task). Guard 2's absence is what made raising the default timeout
# unaffordable, and the old bare `1` return is what made targeted advice
# impossible.
#
# Test seam: FF_TIMEOUT_KILL_GRACE shortens the SIGTERM→SIGKILL grace period.
#
# The *reason* for a non-zero status travels out of band, via timeout_reason_file
# below — an exit status is one channel and would otherwise carry two meanings.
run_with_timeout() {
  local timeout_seconds="$1"
  shift

  record_timeout_reason command

  local out_file marker
  if ! out_file="$(mktemp)"; then
    echo "ERROR: run_with_timeout: cannot create a temp file for command output." >&2
    record_timeout_reason orchestrator-error
    return "$ORCHESTRATOR_ERROR_EXIT_CODE"
  fi
  if ! marker="$(mktemp)"; then
    echo "ERROR: run_with_timeout: cannot create a temp file for the timeout marker." >&2
    rm -f "$out_file"
    record_timeout_reason orchestrator-error
    return "$ORCHESTRATOR_ERROR_EXIT_CODE"
  fi

  # Job control makes each background job a process-group leader (pgid == pid),
  # which both guard 2 and guard 3 rely on.
  set -m
  # stdin is closed explicitly. It is NOT enough to rely on "async lists get
  # /dev/null": POSIX grants that only when job control is **inactive**, and the
  # `set -m` immediately above turns it on. Measured on bash 3.2 and 5, caller
  # stdin = a held-open pipe:
  #     `cat &` with job control off  -> fd 0 = /dev/null, returns at once
  #     `cat &` after `set -m`        -> fd 0 = the pipe, blocks until EOF
  # Today every adapter calls this as `result=$(run_with_timeout ...)`, and bash
  # forces job control off inside a command-substitution subshell — so the hazard
  # is masked. Measured: the same call outside a substitution blocks for the full
  # lifetime of the caller's stdin. That is one ordinary refactor away
  # (`run_with_timeout ... > file` instead of `$(...)`), and the failure it
  # resurrects is the worst kind: `codex exec` reads stdin when it is not a TTY,
  # prints nothing to stdout, and waits — indistinguishable from a hang, for the
  # full timeout (Issue #406, where it cost 50 minutes and a wrong diagnosis).
  # None of the five CLIs takes input on stdin; the prompt is always argv.
  "$@" >"$out_file" </dev/null &
  local cmd_pid=$!
  (
    sleep "$timeout_seconds"
    # Record the fired deadline BEFORE signalling. Written after the kill, the
    # parent could reap the child and cancel this watchdog before the write
    # landed, and a genuine timeout would be reported as a crash — measured at
    # ~3% of runs (8/240) under CPU contention, returning 143 instead of 124.
    printf 'timeout' >"$marker"
    # Negative pid = process group. Fall back to the lone pid if the child never
    # became a group leader, so a host without job control still gets a timeout
    # rather than none at all.
    kill -TERM -- -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
    sleep "$TIMEOUT_KILL_GRACE"
    kill -KILL -- -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  local watchdog_pid=$!
  set +m

  local rc=0
  wait "$cmd_pid" || rc=$?

  # Kill the watchdog *as a group* so its in-flight `sleep` goes with it (guard 2)
  # instead of idling for the rest of the limit — at a 900s default that is a
  # stray `sleep 900` per task.
  kill -- -"$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  # Trust the marker only when the command actually failed. The marker means "the
  # deadline elapsed", which can also happen a hair after a command finished on
  # its own; reclassifying a successful run as a timeout would be worse than the
  # race it fixes. Residual window: a command that fails on its own within
  # milliseconds of the deadline is reported as a timeout — it was about to be
  # killed anyway.
  if [[ "$rc" -ne 0 && -s "$marker" ]]; then
    rc="$TIMEOUT_EXIT_CODE"
    record_timeout_reason timeout
    # `wait` returned as soon as the *direct* child died, and killing the watchdog
    # above cancelled its pending group SIGKILL. A group member that ignores
    # SIGTERM would otherwise outlive the deadline indefinitely, so finish the
    # escalation here: wait out a bounded grace so a well-behaved worker can still
    # flush, then SIGKILL whatever is left. Done in the foreground rather than
    # left to an orphaned watchdog, which would signal a possibly-recycled pgid
    # seconds later. Costs nothing when the group is already empty.
    local waited=0
    while [[ "$waited" -lt "$TIMEOUT_KILL_GRACE" ]] && kill -0 -- -"$cmd_pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    kill -KILL -- -"$cmd_pid" 2>/dev/null || true
  fi
  rm -f "$marker"

  cat "$out_file"
  rm -f "$out_file"
  return "$rc"
}

# ── Failure Reporting ──

# Describe a non-zero CLI exit status in one phrase.
# Usage: describe_cli_failure <rc> <timeout_seconds> [reason]
#
# `reason` is run_with_timeout's out-of-band verdict (see timeout_reason_file):
# "timeout", "orchestrator-error", "command", or "" when it could not be recorded.
# An adapter may also record a reason itself when the CLI succeeded but the result
# is unusable: "sandbox-refused" (a safety precondition did not hold) or
# "empty-output" (exit 0 with nothing on stdout).
# It is consulted first because the status alone is ambiguous — a CLI is free to
# exit 124 or 125 itself, and only the reason separates that from our own verdict.
describe_cli_failure() {
  local rc="$1" timeout_seconds="$2" reason="${3:-}"

  case "$reason" in
    timeout)
      echo "timed out after ${timeout_seconds}s"
      return
      ;;
    orchestrator-error)
      echo "could not be started by this orchestrator (see the error above)"
      return
      ;;
    sandbox-refused)
      # The CLI ran to completion and exited 0; this adapter is the one that
      # refused the result, because the sandbox it asked for was not in effect.
      # Saying "the CLI exited 1" here would send the reader after a crash that
      # never happened, while the actual thing to fix is the sandbox.
      echo "ran without the sandbox this adapter requires — its result was refused"
      return
      ;;
    empty-output)
      # Exited 0 and was never stopped, but wrote nothing to stdout. The cause is
      # in the CLI's stderr (rate limits, auth), which the artifact carries below.
      echo "exited successfully but produced no output"
      return
      ;;
  esac

  # reason == "command" (the CLI decided its own fate) or "" (unrecordable, so fall
  # back to the status). Only reserved-by-convention codes are interpreted here.
  case "$rc" in
    "$SIGKILL_EXIT_CODE")
      # A fired deadline is reported with reason=timeout above, so reaching here
      # with 137 means something *outside* this wrapper SIGKILLed the CLI, most
      # often the OS under memory pressure. Calling that a timeout would tell the
      # user to allow more time, which cannot help and buries the real cause.
      echo "was killed by SIGKILL — not by the time limit (e.g. the OS under memory pressure)"
      ;;
    "$TIMEOUT_EXIT_CODE"|"$ORCHESTRATOR_ERROR_EXIT_CODE")
      if [[ -z "$reason" ]]; then
        # No reason recorded: the number is all there is, so read it the
        # conventional way rather than pretending the CLI chose it.
        if [[ "$rc" -eq "$TIMEOUT_EXIT_CODE" ]]; then
          echo "timed out after ${timeout_seconds}s"
        else
          echo "could not be started by this orchestrator (see the error above)"
        fi
      else
        echo "exited with status ${rc} (the CLI's own status, not a timeout)"
      fi
      ;;
    *)
      echo "exited with status ${rc}"
      ;;
  esac
}

# Maximum bytes of CLI stderr copied into the result file. Enough for a stack
# trace or an auth error, small enough that a chatty CLI cannot bury the report.
readonly STDERR_EXCERPT_BYTES=4000

# Record a failed task as an explicitly INCOMPLETE result, then exit non-zero.
# Usage: fail_cli_task <exit_code> <stderr_log> <perspective_name> <partial_output>
# Reads: CLI_NAME, OUTPUT_FILE, TIMEOUT, TASK_TYPE. Does not return.
#
# Writing a file here rather than leaving none keeps whatever the CLI produced
# before it was stopped — issue #152 threw away a full 300s Codex run because the
# failure path discarded already-captured stdout, leaving a report that only said
# the section was missing. This stays fail-loud: the banner marks the result
# incomplete, the header carries `Status: incomplete`, and the non-zero exit keeps
# the orchestrator counting the task as failed.
#
# The stderr excerpt goes into the file too. For a crash the cause is usually
# *only* on stderr ("auth error: token expired"), and echoing it to the
# orchestrator's stream is not enough: in parallel mode that stream is several
# adapters interleaved, and nothing persists it. Salvaging stdout while dropping
# the one channel that says why would miss the point of the salvage.
#
# No runtime fallback is attempted here, by design. See the "Fallback semantics"
# section of scripts/multi-agent.sh for the reasoning.
fail_cli_task() {
  local rc="$1" stderr_log="$2" perspective_name="$3" partial="$4"

  local kind reason
  kind="$(read_timeout_reason)"
  clear_timeout_reason
  reason="$(describe_cli_failure "$rc" "$TIMEOUT" "$kind")"

  # Normalise the status at the process boundary. The orchestrator only sees this
  # number, so a CLI that exited 124/125 by its own choice must not arrive looking
  # like our timeout or our own breakage.
  local exit_rc="$rc"
  case "$kind" in
    timeout)            exit_rc="$TIMEOUT_EXIT_CODE" ;;
    orchestrator-error) exit_rc="$ORCHESTRATOR_ERROR_EXIT_CODE" ;;
    command)
      if [[ "$rc" -eq "$TIMEOUT_EXIT_CODE" || "$rc" -eq "$ORCHESTRATOR_ERROR_EXIT_CODE" ]]; then
        exit_rc=1
      fi
      ;;
  esac

  echo "ERROR: ${CLI_NAME} ${reason}." >&2
  if [[ "$exit_rc" -eq "$TIMEOUT_EXIT_CODE" ]]; then
    echo "       Give it more room with: --timeout $((TIMEOUT * 2))" >&2
  fi

  local stderr_excerpt=""
  if [[ -s "$stderr_log" ]]; then
    echo "--- CLI stderr ---" >&2
    cat "$stderr_log" >&2
    echo "--- end stderr ---" >&2
    stderr_excerpt="$(tail -c "$STDERR_EXCERPT_BYTES" "$stderr_log")"
  fi
  # Guard the empty operand: fail_orchestrator_error calls in with "" (there is no
  # stderr file when creating it is what failed). `rm -f ""` is a no-op on BSD, but
  # rather than depend on every rm(1) agreeing, skip it — if some rm did error here,
  # `set -e` would kill the adapter before it writes the artifact, i.e. exactly the
  # empty-handed failure this function exists to prevent.
  if [[ -n "$stderr_log" ]]; then
    rm -f "$stderr_log"
  fi

  local body
  if [[ -n "$partial" ]]; then
    body="Partial output captured before the CLI was stopped:

${partial}"
  else
    if [[ "$kind" == "empty-output" ]]; then
      body="The CLI exited 0 without writing any output."
    else
      body="No output was captured before the CLI was stopped."
    fi
  fi

  if [[ -n "$stderr_excerpt" ]]; then
    body="${body}

### CLI stderr (last $((STDERR_EXCERPT_BYTES / 1000))KB)

\`\`\`
${stderr_excerpt}
\`\`\`"
  fi

  # The "never reached its conclusion" clause is false for a result we refused
  # after the CLI finished, and a banner that misstates what happened sends the
  # reader to the wrong place. Keep the INCOMPLETE contract, change the reason.
  local banner_detail="the CLI never reached its conclusion, so anything it had not gotten to is simply absent — read the gaps as unknown, not as clean"
  case "$kind" in
    sandbox-refused)
      banner_detail="the CLI did finish, but it ran outside the sandbox this adapter requires, so its findings are unverified and it may have modified the working tree — read this as unknown, not as clean"
      ;;
    empty-output)
      # "below" must point at something that exists. When the CLI wrote nothing to
      # stderr either, the excerpt section is absent (the -s guard above), and the
      # most-diagnosis-needed artifact would send its reader hunting for a section
      # that is not there.
      if [[ -n "$stderr_excerpt" ]]; then
        banner_detail="the CLI exited successfully but wrote nothing, so nothing was reviewed at all — the reason is in the stderr excerpt below, not in a crash"
      else
        banner_detail="the CLI exited successfully but wrote nothing to stdout or stderr, so no cause was captured — check the CLI's own logs or its auth/rate-limit state directly"
      fi
      ;;
  esac

  write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" \
    "> ⚠️ **INCOMPLETE — ${CLI_NAME} ${reason}.** This is not a finished ${TASK_TYPE:-review}: ${banner_detail}.

${body}" \
    "incomplete"

  exit "$exit_rc"
}

# Abort as an orchestrator-side failure, still leaving an INCOMPLETE artifact.
# Usage: fail_orchestrator_error <perspective_name> <what went wrong>
# Reads: CLI_NAME, OUTPUT_FILE, TIMEOUT, TASK_TYPE. Does not return.
#
# Needed for the setup that happens BEFORE run_with_timeout — creating the stderr
# temp file. Under the adapters' `set -e` a failed `mktemp` there killed the
# process with a bare 1, so a broken TMPDIR was filed as "the CLI exited 1" and no
# artifact was written at all: the 125 handling inside run_with_timeout could never
# be reached on the most likely path to it.
fail_orchestrator_error() {
  local perspective_name="$1" what="$2"
  echo "ERROR: ${what}" >&2
  record_timeout_reason orchestrator-error
  fail_cli_task "$ORCHESTRATOR_ERROR_EXIT_CODE" "" "$perspective_name" ""
}

# ── Model Selection ──
#
# ラッパーはモデルを選ばない。どのモデルを使うかは各 CLI 自身の設定
# （~/.codex/config.toml、Claude Code のモデル設定など）へ委譲し、env が
# 設定されているときだけフラグを組み立てる。未設定ならフラグ自体を渡さない。
#
# 既定値としてモデル slug を持たせると、その値の SSOT がユーザーの CLI 設定と
# ラッパーの 2 箇所に分裂してラッパー側が必ず古くなる。しかも無条件にフラグを
# 渡す実装だと、ユーザー設定を黙って上書きするうえ同じ設定ファイル内の関連項目
# （reasoning effort など）は上書きされないため、「古いモデル + 新しい付随設定」
# という誰も意図していない組み合わせで動く。実害の記録は
# 実害の記録は ACE-70-2（本リポジトリの ACE Playbook）を参照。
#
# 第 3 引数の既定値に書いてよいのは「ベンダー中立で世代交代しない語」だけ。
# 現状これを使っているアダプタは無い。唯一の利用者だった cursor-agent の `auto`
# は issue #240 の cursor-cli 削除で消えた（copilot も値として auto を受け付ける
# が、それは利用者が env に指定する値であってラッパーが持つ既定値ではない）。
# 具体的なモデル slug は既定値としてもフォールバックとしても持たないこと —
# tests/no-hardcoded-model/verify.sh がこれを機械的に検査している。
#
# 代入ではなく追記にしているのは、codex が -m（モデル）と -p（プロファイル）の
# 2 フラグを同時に取りうるため。代入式だと後の呼び出しが前の結果を黙って捨てる。

MODEL_ARGS=()

# Usage: reset_model_args
reset_model_args() {
  MODEL_ARGS=()
}

# Usage: add_model_arg <flag> <ENV_VAR_NAME> [vendor_neutral_default]
# 値は間接展開で読む（bash 3.2 には declare -n が無い）。
#
# 引数の不正は「呼び出し側のバグ」なので沈黙せず非 0 で返す。env 変数名を打ち
# 間違えた呼び出し（例: MULTI_AGENT_MODEL_GEMINI_CL1）は、黙って無視すると
# 利用者が設定した値が永久に届かない「効かないつまみ」になり、しかも実行結果
# からは区別できない。素の呼び出しなら set -e が拾って落ちる。
add_model_arg() {
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "add_model_arg: 引数は 2〜3 個です（受領: $#）" >&2
    return 2
  fi
  local flag="$1" var="$2" fallback="${3:-}" value
  if [[ ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "add_model_arg: 第 2 引数は環境変数名でなければなりません（受領: '$var'）" >&2
    return 2
  fi
  value="${!var:-}"
  [[ -z "$value" ]] && value="$fallback"
  [[ -n "$value" ]] && MODEL_ARGS+=("$flag" "$value")
  return 0
}

# 解決したモデル引数を起動バナーに出す。
#
# 委譲した以上「実際にどのモデルが使われたか」はラッパーには断定できないので、
# ここで報告するのは**渡した引数**だけにし、実使用モデルを名乗らない。それでも
# 出す価値があるのは、env 名の打ち間違いや未 export が「(なし)」として即座に
# 見えるため — 設定したつもりで効いていない事故は、これが無いと成果物からも
# ログからも判別できない。
# Usage: echo_model_args
echo_model_args() {
  if [[ ${#MODEL_ARGS[@]} -gt 0 ]]; then
    echo "   Model args: ${MODEL_ARGS[*]} (env 由来。実使用モデルは CLI 側の解決結果に従う)" >&2
  else
    echo "   Model args: (なし — CLI 自身の設定へ委譲)" >&2
  fi
}

# ── Argument Parsing Helper ──

# Parse common adapter arguments
# Sets: PERSPECTIVE_FILE, OUTPUT_FILE, CHANGED_FILES, BASE_BRANCH, STAGED_DIFF, TIMEOUT,
#       TASK_TYPE, DESCRIPTION, INCLUDE_DIFF, STAGING_DIR, INLINE_OUTPUT, DIFF_FILE
# Usage: parse_adapter_args "$@"
parse_adapter_args() {
  PERSPECTIVE_FILE=""
  OUTPUT_FILE=""
  CHANGED_FILES=""
  BASE_BRANCH="$(detect_base_branch)"
  BASE_BRANCH_EXPLICIT="false"
  STAGED_DIFF="false"
  # Standalone default for a direct adapter invocation. Kept in step with
  # multi-agent.sh's DEFAULT_TIMEOUT_REVIEW — an adapter run by hand should not
  # inherit the 300s that issue #152 identified as too short. The orchestrator
  # always passes --timeout explicitly, so this value only applies to direct runs.
  # tests/multi-agent-timeout/verify.sh gates it against that constant.
  TIMEOUT="${REVIEW_TIMEOUT:-900}"
  TASK_TYPE="review"
  DESCRIPTION=""
  INCLUDE_DIFF="false"
  # 直叩き実行では空のまま。orchestrator 経由のときだけ実パスが入る（Issue #392）。
  STAGING_DIR=""
  # staging 無しの implement を許す明示的オプトイン。無指定で staging も無ければ
  # build_prompt が fail-loud に落ちる（渡し忘れを黙って退避モードにしないため）。
  INLINE_OUTPUT="false"
  # orchestrator が固定した diff のパス。直叩き実行では空のままで、その場合は
  # 従来どおりアダプタ自身が git から取る（prompt_diff_content を参照）。
  DIFF_FILE=""

  while [[ $# -gt 0 ]]; do
    # 値付きフラグを末尾に置いた場合、各 arm でいきなり "$2" を読むと set -u が
    # 発火する。macOS 既定の Bash 3.2 ではこの死が呼び出し側から rc=0 に見えることが
    # あり、「成功・成果物なし」へ反転する。値付きフラグの集合をここで一括して守り、
    # どれか1つだけ直して残りが同じ silent exit を持ち続ける形を作らない。
    case "$1" in
      --changed-files|--base|--timeout|--task-type|--description|--staging-dir|--diff-file)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: ${1} requires a value." >&2
          return 2
        fi
        # 次の既知フラグを値として吸収しない。末尾だけを見ると
        # `--description --inline-output` が description の値として通り、利用者が指定した
        # inline-output は黙って消える。未知の `--foo` まで一律拒否はしない（説明文等の
        # 実値であり得るため）。このパーサー自身が知るフラグだけを欠落の証拠にする。
        case "$2" in
          --changed-files|--base|--timeout|--task-type|--description|--include-diff|--staged|--staging-dir|--inline-output|--diff-file)
            echo "ERROR: ${1} requires a value; got option '${2}'." >&2
            return 2
            ;;
        esac
        ;;
    esac
    case "$1" in
      --changed-files)
        CHANGED_FILES="$2"
        shift 2
        ;;
      --base)
        BASE_BRANCH="$2"
        BASE_BRANCH_EXPLICIT="true"
        shift 2
        ;;
      --staged)
        STAGED_DIFF="true"
        shift
        ;;
      --timeout)
        TIMEOUT="$2"
        shift 2
        ;;
      --task-type)
        TASK_TYPE="$2"
        shift 2
        ;;
      --description)
        DESCRIPTION="$2"
        shift 2
        ;;
      --include-diff)
        INCLUDE_DIFF="true"
        shift
        ;;
      --staging-dir)
        STAGING_DIR="$2"
        shift 2
        ;;
      --diff-file)
        DIFF_FILE="$2"
        shift 2
        ;;
      --inline-output)
        INLINE_OUTPUT="true"
        shift
        ;;
      *)
        if [[ -z "$PERSPECTIVE_FILE" ]]; then
          PERSPECTIVE_FILE="$1"
        elif [[ -z "$OUTPUT_FILE" ]]; then
          OUTPUT_FILE="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ "$STAGED_DIFF" == "true" && "$BASE_BRANCH_EXPLICIT" == "true" ]]; then
    echo "ERROR: --staged and --base are mutually exclusive." >&2
    return 2
  fi
  if [[ "$STAGED_DIFF" == "true" && "$TASK_TYPE" != "review" ]]; then
    echo "ERROR: --staged is only valid for review tasks." >&2
    return 2
  fi

  if [[ -z "$PERSPECTIVE_FILE" || -z "$OUTPUT_FILE" ]]; then
    echo "Usage: $(basename "$0") <perspective-file> <output-file> [--changed-files <files>] [--base <branch> | --staged] [--diff-file <path>] [--timeout <seconds>] [--task-type <review|explore|implement>] [--description <text>] [--staging-dir <dir>] [--inline-output]" >&2
    return 1
  fi
}
