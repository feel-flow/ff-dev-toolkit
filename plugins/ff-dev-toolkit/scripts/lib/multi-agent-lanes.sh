#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: ホスト委譲のレーン・観点の除外・fallback の解決・引数の引用・モデル env の前置・レビュワー pair（main / sub / cross_review）。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── ホスト委譲の対象レーン ──
# 委譲できるのは**ホスト自身のモデルのレーン 1 本だけ**: Claude Code がホストなら claude-code
# （Agent ツール）、Codex CLI なら codex-cli（multi_agent の spawn_agent）、grok CLI なら grok-cli
# （spawn_subagent）。`--delegate-to-host=<cli>` で指定する（Issue `#2118`）。ホストと違う
# モデルのレーンを同じ経路へ流すと「複数の *違う* モデルを同じ diff に当てる」という本ツールの
# 目的が黙って消える（レポート上は観点が埋まったまま、実体はホスト 1 モデルの多重実行になる）。
# 1 実行で委譲するのは単一値。許す値は下の case に閉じ、レジストリ側へ判断を逃がさない。
# grok-cli を足した理由: `grok -p` の headless 起動は最初のターンの前置きだけが捕捉されて
# typed verdict を欠く（missing-review-body）ことが多く、grok がホストのときはセッション内の
# サブエージェント（spawn_subagent）で同じプロンプトを走らせる方が確実に本文が返る。
#
# registry の境界（入口 multi-agent.sh の「All known CLI names」〜「CLI Registry End」）の**外**に置く: 境界内は $ALL_CLIS と固定値を返す
# case lookup だけに保つ契約で、tests/lib/cli-registry-parser.sh が制限文法として
# 静的解析する（cli_sandbox_probe_supported と同じ理由）。
DELEGATION_LANE="claude-code"
delegation_lane_allowed() { # <cli> → rc0 = --delegate-to-host=<cli> で委譲してよいレーン
  case "$1" in
    claude-code | codex-cli | grok-cli) return 0 ;;
    *) return 1 ;;
  esac
}

task_is_delegated() { # <cli> → rc0 = この実行でホストへ委譲するレーン
  [[ "$DELEGATE_TO_HOST" == "true" && "$1" == "$DELEGATION_LANE" ]]
}

# 委譲の受け渡しディレクトリ。<cli>/ 直下のドット始まりなので、結果ファイルの退避
# （quarantine_cli_results は <cli>/*.md だけを見る）にも「今回の結果ではない」報告
# （report_unplanned_result_dirs はドット始まりを外す）にも掛からない。
delegate_dir_for() { # <cli>
  printf '%s\n' "${OUTPUT_DIR}/${1}/.delegated"
}

# 回収済み（= ホストが今回書いた）応答が待っている観点か。
# resume のキャッシュ再利用より**新しい応答を優先**するために要る。逆にすると、
# 古いキャッシュを書き戻して `♻️ Reused` と名乗り、ホストが今回払った実行の成果物は
# .delegated/ に置き去りのまま一度も名指しされない（stale / rejected の退避と違い、
# こちらには報告経路が無い）。
delegated_response_waiting() { # <cli> <perspective>
  task_is_delegated "$1" || return 1
  [[ -f "$(delegate_dir_for "$1")/${2}.response.md" ]]
}

# プラン時に「この環境でサンドボックスを適用できるか」を尋ねられるアダプタ。
# 対応アダプタは `--probe-sandbox <task-type>` を受け、拒否を確定できたときだけ
# SANDBOX_PROBE_REFUSED_STATUS を返す（それ以外は 0 = 黙る）。
#
# 名前で分岐するのは、これが CLI 固有の性質そのものだから — grok は起動時に
# サンドボックスを適用してから走る唯一の CLI で、codex は sandbox サブコマンドを
# 持つが起動拒否の形にはならず、claude-code / copilot-cli には --sandbox の概念が無い。
# コスト帯のような横断属性へ畳めない。probe を持つアダプタが増えたらここへ足す。
#
# registry の境界（入口 multi-agent.sh の sentinel の間）の外に置く: この関数は固定値を返す case lookup では
# なく述語で、静的解析側の制限文法に載らない。
cli_sandbox_probe_supported() {
  case "$1" in
    grok-cli) return 0 ;;
    *)        return 1 ;;
  esac
}

perspective_excluded() {
  [[ -n "$EXCLUDE_PERSPECTIVES" ]] && list_contains "$EXCLUDE_PERSPECTIVES" "$1"
}

get_cli_perspectives() {
  local cli_name="$1"
  case "$TASK_TYPE" in
    review)    get_cli_perspectives_review "$cli_name" ;;
    explore)   get_cli_perspectives_explore "$cli_name" ;;
    implement) get_cli_perspectives_implement "$cli_name" ;;
    *)         get_cli_perspectives_review "$cli_name" ;;
  esac
}

# get_cli_fallback は 1 手先しか返さない。代替先も未インストールなら、そこで打ち切ると
# 担当観点がプランから黙って消える。実測（claude-code だけ導入した環境）では、
# gemini-cli → codex-cli(未導入) と grok-cli → codex-cli(未導入) が両方行き止まりになり、
# review 7 観点のうち 3 つが「No fallback available」の 1 行だけ残して落ちていた。
# 利用者の多くが単一 CLI 構成であることを踏まえると、これが既定の姿になる。
# （上記実測は gemini-cli 在籍時のもの。`#783` で gemini は削除されたが、「チェーンの
# 行き止まりで観点が黙って落ちる」という機構の教訓は CLI 構成に依らず有効）
#
# チェーンを辿って最初に導入済みの CLI を返す。表は相互参照を含む（claude-code ⇄
# codex-cli）ので訪問済みを持って循環を切る。
#
# チェーンを辿るだけでは足りない。対応表のグラフは claude-code ⇄ codex-cli が
# **終端サイクル**で、gemini-cli / grok-cli はそこへ流れ込むだけで逆向きの辺が無い。
# 実測（各 CLI を単独で導入したときに計画された review 観点 / 全 7）:
#   claude のみ 7 / codex のみ 7 / gemini のみ 3 / grok のみ 1
# つまり「1 つでも CLI が入っていれば観点は落ちない」は成り立っていなかった。
#
# そこで、チェーンが行き止まりになったら**導入済みの CLI から選び直す**。観点を
# 落とすくらいなら対応表に無い CLI で見てもらう方がよい（プラン出力に CLI 名と
# コスト帯が出るので、誰が見たかは隠れない）。
#
# 従量課金の CLI は最後の砦から除く。既定で除外している CLI（copilot-cli）へ
# 黙って落とすと、利用者が求めていない課金が発生する。それしか無い場合は空を
# 返し、既定除外のガードと空プラン検査に任せる。
resolve_available_fallback() {
  local cli="$1" seen=" $1 " next candidate
  while :; do
    next="$(get_cli_fallback "$cli")"
    [[ -n "$next" ]] || break
    case "$seen" in
      *" $next "*) break ;;   # 循環 — 設定された経路はここで尽きた
    esac
    if list_contains "$AVAILABLE_CLIS" "$next"; then
      echo "$next"
      return
    fi
    seen="${seen}${next} "
    cli="$next"
  done

  # 設定された経路が尽きた。導入済みの非従量課金 CLI へ回す（ALL_CLIS の順）。
  for candidate in $ALL_CLIS; do
    [[ "$candidate" == "$1" ]] && continue
    list_contains "$AVAILABLE_CLIS" "$candidate" || continue
    [[ "$(get_cli_cost_tier "$candidate")" == "metered" ]] && continue
    echo "$candidate"
    return
  done
  echo ""
}

# ── Locale-Independent Shell Quoting ──
#
# 貼り付け用コマンドの引用に `printf '%q'` は使わない。%q は**現在のロケールで
# 文字境界を解釈する**ため、非 UTF-8 ロケール（Windows / Git Bash のコンソール
# codepage 932、LANG 未設定の C ロケールなど）では UTF-8 の日本語がバイト単位に
# 分解され、しかも一部のバイトだけが $'\NNN' へ、残りは生バイトのまま出力される。
# 実測（LC_ALL=C）:
#
#     printf '%q' 'なし'   →   <e3> $'\201' <aa> <e3> $'\201' $'\227'
#
# 生の 0xE3 の直後に ASCII の `$` が続くので、**出力全体が不正な UTF-8 になる**
# （iconv -f UTF-8 -t UTF-8 が Illegal byte sequence で落ちることを実測）。この
# 文字列は失敗時の再実行案内や統合レポートへ載り、それを次回実行の --description
# （prior review evidence）として渡すと prompt 全体が不正な UTF-8 になる。codex-cli
# は "input is not valid UTF-8" で prompt 全体を拒否するため、全観点が incomplete
# で終わる（Windows の既定環境からの導入先報告として実測されている）。
#
# 単引用エスケープはバイト透過なので、入力が valid UTF-8 なら出力も valid UTF-8 で、
# ロケールに依存しない。素で貼っても安全な語はそのまま返す（%q と同じ見た目を保つ）。
# 許可集合は ASCII の英数字と記号だけを意図している。多バイト文字がロケールの照合
# 順で範囲に入って裸のまま返っても、シェルのメタ文字はこの集合に入らないため引用
# としての安全性は変わらない（生バイトのまま = valid UTF-8 のまま）。
shell_quote() {
  local s="$1"
  if [[ -n "$s" && "$s" != *[!A-Za-z0-9._/:=@%+-]* ]]; then
    printf '%s' "$s"
    return
  fi
  # 置換文字列は変数に置く。`${s//\'/...}` のリテラル記法はバックスラッシュの
  # 解釈が bash 3.2（macOS 既定）と 5.x で食い違い、3.2 では壊れた引用を出す（実測）。
  local sq="'" esc="'\\''"
  printf "'%s'" "${s//$sq/$esc}"
}

# ── Model-Selection Env Passthrough ──
# モデル選択の env は「インラインで前置して 1 回だけ効かせる」形（multi-review の
# references/model-selection.md の例もそれ）なので、元コマンドが終わると消える。再実行コマンドをそのまま
# 出すと、貼り付けた人は既定のモデル / プロファイルで走ることになり、失敗した構成の
# 再現にならない。
#
# 前置は**その行の CLI に効くものだけ**にする。全部まとめて前置すると、代替 CLI を
# 案内する行にも無関係な env が乗り、実際には使われない設定を使うかのように読める。
# get_cli_model_env_vars 自体は入口 multi-agent.sh の副作用なしレジストリ定義域に置く。

# 設定されている env だけを `VAR=値 ` の形で連結して返す（無ければ空文字）。
# codex でモデルとプロファイルが両方設定されている場合はアダプタが実行前に拒否するが、
# ここでは両方そのまま前置する — 再実行は「失敗した構成の忠実な再現」であるべきで、
# 片方を黙って落とすと、直したはずの「上書きが静かに消える」問題に戻る。利用者が
# どちらを残すべきかはアダプタのエラーメッセージが明示している。
model_env_prefix() {
  local cli="$1" var prefix=""
  for var in $(get_cli_model_env_vars "$cli"); do
    if [[ -n "${!var:-}" ]]; then
      prefix="${prefix}${var}=$(shell_quote "${!var}") "
    fi
  done
  printf '%s' "$prefix"
}

# ── Reviewer Pair (main + sub) ──
#
# 分散モードは「全 CLI が入っている」前提の設計だった。実際の利用者はほとんどが
# 単一 CLI で、未導入 CLI の観点は fallback で回されるため「誰が何を見たか」が
# 導入状況で毎回変わる。主（メインで使っている CLI）に review 観点すべてを任せ、
# 副がいれば総合レビューを 1 本だけ足す、という形にする。
#
# 保存するのは **CLI 名だけ**。モデルは各 CLI 自身の設定へ委譲する（issue `#239` の
# 不変条件）。設定ファイル経由でモデル slug を保存できてしまうと、.sh しか走査
# しない tests/no-hardcoded-model をすり抜けて ACE-70-2 が再発する。
readonly COMPREHENSIVE_PERSPECTIVE="comprehensive-review"

reviewers_config_file() {
  printf '%s/ff-dev-toolkit/reviewers' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# 値が CLI 名として妥当かを見る。ここが「モデル slug を保存できない」ことの
# 構造的な担保になるので、enum 一致だけを許して他はすべて落とす。
validate_reviewer_value() { # <役割> <値>
  local role="$1" value="$2"
  [[ -z "$value" ]] && return 0
  if ! is_safe_token "$value"; then
    echo "ERROR: unsafe ${role} reviewer name: '${value}'" >&2
    return 1
  fi
  if ! list_contains "$ALL_CLIS" "$value"; then
    echo "ERROR: unknown ${role} reviewer: '${value}'" >&2
    echo "       Reviewers are CLI names, not model names. Known CLIs: ${ALL_CLIS}" >&2
    echo "       Which model each CLI uses is delegated to that CLI's own config." >&2
    return 1
  fi
  return 0
}

# cross_review — 別 CLI が在るときにスキル層がクロスレビューを 1 本
# 加えるか（auto）／常に主担当のみか（off）の**オプトイン設定**。値は auto（既定）| off。ここで扱うのは読み取り・検証・表示
# だけで、プラン構築・縮退警告・レポート行・実行の挙動は一切変えない（分岐はスキル
# 層が --print-reviewers の `cross_review=` 行を見て行う）。
# 値は CLI 名ではないので validate_reviewer_value（ALL_CLIS 照合）は使わない。
# 空文字は「未設定」として素通しし、呼び出し側で auto / unset に落とす。
readonly CROSS_REVIEW_VALUES="auto off"

validate_cross_review_value() { # <出所> <値>
  local origin="$1" value="$2"
  [[ -z "$value" ]] && return 0
  if ! list_contains "$CROSS_REVIEW_VALUES" "$value"; then
    echo "ERROR: unknown cross_review value: '${value}' (from ${origin})" >&2
    echo "       Expected one of: auto, off" >&2
    # 手編集で壊れた保存値は、main= の再保存も止める（引き継ぎ値も検証するため）。
    # 直し方を添えないと、利用者は「何を打てば抜けられるか」をコードから探すことになる。
    case "$origin" in
      "user config"*) echo "       Repair it with: --set-reviewers cross_review=auto (or edit the file named above)" >&2 ;;
    esac
    return 1
  fi
  return 0
}

# ユーザーグローバルの保存ファイルを読む（`main=...` / `sub=...` の 2 行 +
# 任意の `cross_review=...` 1 行。旧形式＝3 行目が無いファイルは
# cross_review 未設定として読む）。
# ユーザーグローバルの保存ファイルを読み、指定された変数名へ入れる。
# グローバルを直接書かないのは、フィールド単位の優先順位判定を呼び出し側に
# 一元化するため（ここで書き戻すと「誰が入れた値か」が追えなくなる）。
read_reviewers_file_into() { # <main を入れる変数名> <sub を入れる変数名> [cross_review を入れる変数名]
  local f key value
  f="$(reviewers_config_file)"
  [[ -f "$f" ]] || return 0
  # `|| [[ -n "$key" ]]` が要る。read は末尾改行の無い最終行で非 0 を返すため、
  # 素の while だとその行が黙って捨てられる。この設定は ~/.config の平文で説明
  # コメント付きなので手編集を誘うし、落ちる形が「副が黙って消える」——まさに
  # この機能が可視化しようとしている縮退そのもの。
  # 未知のキー・重複キーは黙って捨てない。この文書は手編集を誘う
  # （self-review.md がパスを名指しする）ので、`cross-review=off` のような typo が
  # 「未設定 = auto」に化けると、利用者が切ったつもりのクロスレビューが走る。
  # 読み取りは止めない（main / sub の旧互換）が、行を名指しして警告する。
  local seen=""
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      ""|\#*) continue ;;
      main|sub|cross_review)
        if list_contains "$seen" "$key"; then
          echo "⚠️  ${f}: duplicate key '${key}' — the last value wins" >&2
        fi
        seen="${seen} ${key}"
        ;;
      *)
        echo "⚠️  ${f}: ignoring unknown key '${key}' (expected main=, sub=, cross_review=)" >&2
        continue
        ;;
    esac
    case "$key" in
      main) eval "$1=\"\$value\"" ;;
      sub)  eval "$2=\"\$value\"" ;;
      # 第 3 引数を渡さない旧来の呼び出しは cross_review を読み飛ばす（互換）
      cross_review) [[ -n "${3:-}" ]] && eval "$3=\"\$value\"" ;;
    esac
  done < "$f"
  return 0
}

# env > プロジェクト設定 > ユーザーグローバル。既存の CONFIG_FILE 解決と同じ形。
# 優先順位は **フィールド単位**（main と sub をそれぞれ独立に env > project > global で
# 解決する）。ペア単位にすると「今回だけ副を変えたい」ができず、片側だけ指定した
# ときに上位層の main と下位層の sub が非対称に混ざる（どちらの規則としても
# 一貫しない状態になる）。フィールド単位なら片側指定の全組合せが説明できる。
#
# 副に空文字を明示指定する（MULTI_AGENT_REVIEW_SUB=）のは「今回は副なし」の意思
# 表示なので、下位層で埋め戻さない。env が設定されているかどうかで判定する。
resolve_reviewer_pair() {
  local v
  REVIEW_MAIN=""
  REVIEW_SUB=""
  local main_src="" sub_src="" cross_src=""
  REVIEWERS_MAIN_SOURCE=""
  REVIEWERS_SUB_SOURCE=""
  # cross_review も同じ 3 層・同じ出所語彙で解決する。副と違い
  # 空文字に意味を持たせない（空 = 未設定 → 既定 auto）。不正値は入口ごとに出所
  # 付きで拒否し、下位層へ黙って落とさない。
  CROSS_REVIEW=""
  CROSS_REVIEW_SOURCE=""

  if [[ -n "${MULTI_AGENT_REVIEW_MAIN:-}" ]]; then
    REVIEW_MAIN="$MULTI_AGENT_REVIEW_MAIN"; main_src="env"
  fi
  # 空文字での明示指定も「決まった」とみなす（副なしの意思表示）
  if [[ "${MULTI_AGENT_REVIEW_SUB+set}" == "set" ]]; then
    REVIEW_SUB="$MULTI_AGENT_REVIEW_SUB"; sub_src="env"
  fi
  if [[ -n "${MULTI_AGENT_CROSS_REVIEW:-}" ]]; then
    validate_cross_review_value "env MULTI_AGENT_CROSS_REVIEW" "$MULTI_AGENT_CROSS_REVIEW" || return 1
    CROSS_REVIEW="$MULTI_AGENT_CROSS_REVIEW"; cross_src="env"
  fi

  if [[ -f "$CONFIG_FILE" ]] && ! command -v yq &>/dev/null && grep -q '^review:' "$CONFIG_FILE" 2>/dev/null; then
    # yq が無いと project config の review.* は読めない。load_config の汎用案内だけでは
    # 「単一固定を書いたのに効かない」が cross_review に帰属できないので名指しする。
    echo "ℹ️  yq not found — review.main / review.sub / review.cross_review in ${CONFIG_FILE} are not read." >&2
  fi
  if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
    if [[ -z "$main_src" ]]; then
      v="$(yq -r '.review.main // ""' "$CONFIG_FILE" 2>/dev/null || true)"
      [[ -n "$v" ]] && { REVIEW_MAIN="$v"; main_src="project config"; }
    fi
    if [[ -z "$sub_src" ]]; then
      v="$(yq -r '.review.sub // ""' "$CONFIG_FILE" 2>/dev/null || true)"
      [[ -n "$v" ]] && { REVIEW_SUB="$v"; sub_src="project config"; }
    fi
    if [[ -z "$cross_src" ]]; then
      # `// ""` は使わない — yq の `//` は false を「無い」扱いにするので、YAML の
      # 自然な書き方 `cross_review: false` が黙って未設定（auto）へ化ける。null だけを
      # 空にし、false / true / 0 は文字列として validate へ届けて名指しで拒否する。
      v="$(yq -r '.review.cross_review | select(. != null) | tostring' "$CONFIG_FILE" 2>/dev/null || true)"
      if [[ -n "$v" ]]; then
        validate_cross_review_value "project config review.cross_review (${CONFIG_FILE})" "$v" || return 1
        CROSS_REVIEW="$v"; cross_src="project config"
      fi
    fi
  fi

  # 保存ファイルは常に読み、cross_review の値は上位層が勝っていても検証する。上位層が
  # 在るあいだ壊れた保存値を見逃すと、上位層を外した瞬間に「突然の exit 1」になり、
  # 原因の帰属が難しい（検証は列挙値の照合 1 回で、コストは無い）。
  local file_main="" file_sub="" file_cross=""
  read_reviewers_file_into file_main file_sub file_cross
  if [[ -n "$file_cross" ]]; then
    validate_cross_review_value "user config $(reviewers_config_file)" "$file_cross" || return 1
  fi
  if [[ -z "$main_src" && -n "$file_main" ]]; then REVIEW_MAIN="$file_main"; main_src="user config"; fi
  if [[ -z "$sub_src"  && -n "$file_sub"  ]]; then REVIEW_SUB="$file_sub";  sub_src="user config"; fi
  if [[ -z "$cross_src" && -n "$file_cross" ]]; then CROSS_REVIEW="$file_cross"; cross_src="user config"; fi

  # 未設定は既定 auto。出所 unset は「利用者が選んでいない」ことの表示で、
  # 明示 auto（user config 等）と区別できるようにする。
  CROSS_REVIEW="${CROSS_REVIEW:-auto}"
  CROSS_REVIEW_SOURCE="${cross_src:-unset}"

  # 出所は main / sub が同じなら 1 つ、違えば両方を出す（どこを直せばよいか分かる形）
  if [[ -z "$main_src" && -z "$sub_src" ]]; then
    REVIEWERS_SOURCE=""
  elif [[ "$main_src" == "$sub_src" ]]; then
    REVIEWERS_SOURCE="$main_src"
  else
    REVIEWERS_SOURCE="main:${main_src:-unset} sub:${sub_src:-unset}"
  fi

  REVIEWERS_MAIN_SOURCE="${main_src:-unset}"
  REVIEWERS_SUB_SOURCE="${sub_src:-unset}"

  validate_reviewer_value main "$REVIEW_MAIN" || return 1
  validate_reviewer_value sub  "$REVIEW_SUB"  || return 1
  return 0
}

# 書き込みは hooks/check-update.sh の write_cache と同じアトミック置換。
# 部分的に書けたファイルを残すと、次回の読み出しが壊れた設定を拾う。
write_reviewers_file() { # <main> <sub> [cross_review]
  local f dir tmp cross_line=""
  f="$(reviewers_config_file)"
  # cross_review は選ばれたときだけ 3 行目に書く。未設定でも
  # `cross_review=auto` を書いてしまうと、次回の読み出しで出所が「user config」に
  # 化け、「利用者が選んでいない（unset）」という事実が消える。
  [[ -n "${3:-}" ]] && cross_line="cross_review=$3"
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || {
    echo "ERROR: cannot create ${dir}" >&2
    return 1
  }
  # hooks/check-update.sh の write_cache は同じ位置で `rm -rf` して自己修復するが、
  # あちらは**キャッシュ**なので捨ててよい。ここは利用者の設定なので、想定外の
  # 形をしていたら消さずに止める（消してよいかを判断できるのは利用者だけ）。
  if [[ -d "$f" ]]; then
    echo "ERROR: ${f} is a directory, not a config file." >&2
    echo "       Refusing to remove it. Move it aside and retry." >&2
    return 1
  fi
  # kill された過去の実行が残した一時ファイルを掃除する（所有 PID が消えている
  # ので自前の rm では回収できない）。check-update.sh の write_cache と同じ理由。
  rm -f "$f".[0-9]* 2>/dev/null
  tmp="$f.$$"
  # 1 回の printf で書く。複数の printf を { } で束ねると、ブロックの終了状態は
  # **最後の 1 つ**のものになり、途中の書き込み失敗を検出できない（切り詰められた
  # ファイルがそのまま install される）。
  # cross_line が空のときは末尾の空行を作らない（旧形式と byte 一致を保つ）。
  if ! printf '%s\n' \
    "# ff-dev-toolkit review reviewers (CLI names only — models are each CLI's own setting)" \
    "main=$1" \
    "sub=$2" \
    ${cross_line:+"$cross_line"} > "$tmp"; then
    rm -f "$tmp" 2>/dev/null
    echo "ERROR: cannot write ${tmp}" >&2
    return 1
  fi
  # mv の stderr は捨てない。EACCES / ENOSPC / read-only fs で次の一手が違う。
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp" 2>/dev/null
    echo "ERROR: cannot install ${f}" >&2
    return 1
  fi
  return 0
}

# 機械可読の状態出力。スキル層はこの exit code で分岐する（マーカー行を
# grep -q で拾う形にしない — SIGPIPE + pipefail で判定が反転する。Issue `#234`）。
#   0 = 主が決まっている / 3 = 未設定
print_reviewers_state() {
  # 状態は検出より**先に**出す。detect_available_clis は CLI が 1 つも無いと
  # インストール案内を出して `exit 1` する（関数の return ではないので `|| true`
  # では捕まえられない）。検出を先に置くと、その環境では 1 バイトも出力されない
  # まま終わる — しかもこれは /multi-review の最初のコマンドで、プラグインを
  # 入れてから CLI を入れる人が最初に踏む経路になる。
  printf 'main=%s\n' "$REVIEW_MAIN"
  printf 'sub=%s\n' "$REVIEW_SUB"
  printf 'main_source=%s\n' "${REVIEWERS_MAIN_SOURCE:-unset}"
  printf 'sub_source=%s\n' "${REVIEWERS_SUB_SOURCE:-unset}"
  printf 'source=%s\n' "${REVIEWERS_SOURCE:-unset}"
  # cross_review は既存行の**後ろ**に足す。消費側は `^main=` 等の
  # キーで grep する契約なので、既存行の並びと綴りを変えない。
  printf 'cross_review=%s\n' "${CROSS_REVIEW:-auto}"
  printf 'cross_review_source=%s\n' "${CROSS_REVIEW_SOURCE:-unset}"
  # stderr は握りつぶさない。CLI 未導入時の唯一の手がかり（インストール案内）が
  # そこにしか無い。stdout の ✅/❌ だけを捨てる。
  detect_available_clis >/dev/null
  printf 'available=%s\n' "$AVAILABLE_CLIS"
  printf 'known=%s\n' "$ALL_CLIS"
  [[ -n "$REVIEW_MAIN" ]] && return 0
  return 3
}

# `main=<cli>,sub=<cli>,cross_review=<auto|off>` を検証して保存する。検証はここ
# 1 箇所に閉じ込め、スキル層にはプロンプト以外の判断をさせない。
set_reviewers_from_spec() { # <spec>
  local spec="$1" part key value main="" sub="" sub_given=false cross="" cross_given=false
  # IFS の変更はカンマ分割のあいだだけに閉じる。関数の残り（validate_reviewer_value →
  # list_contains）は `for i in $list` の単語分割に依存しているので、IFS=',' のまま
  # 進むと既知の CLI 名すら「未知」と判定される（実際に踏んだ）。
  local saved_ifs="$IFS"
  IFS=','
  for part in $spec; do
    key="${part%%=*}"
    value="${part#*=}"
    case "$key" in
      main) main="$value" ;;
      sub)  sub="$value"; sub_given=true ;;
      cross_review) cross="$value"; cross_given=true ;;
      *)
        echo "ERROR: unknown reviewer key: '${key}' (expected main=, sub= or cross_review=)" >&2
        return 1
        ;;
    esac
  done

  IFS="$saved_ifs"

  # 既存の保存値は 1 回だけ読む。部分更新（main だけ / cross_review だけ）で
  # 渡されなかったキーはここから引き継ぐ。
  local existing_main="" existing_sub="" existing_cross=""
  read_reviewers_file_into existing_main existing_sub existing_cross

  # `cross_review=` 単独も許す — 主・副は保存済みのものを引き継ぐ。
  # 引き継ぐ主が無くても保存する（main= の有無を問わない、が AC）: 単一固定は
  # 「主担当 = 実装中のホスト」を前提にしていて、pair の主を選ぶ手順と独立に決めたい
  # 初回利用者が最初に触る設定になる。main が空の保存ファイルは、主未設定（exit 3）+
  # cross_review だけが決まった状態として読み戻される。
  # 明示した空値（`cross_review=`）は「解除」ではなく拒否する — 契約は auto | off の
  # 2 値で、解除は `cross_review=auto` と書く（空値で黙って未設定へ戻る経路を作ると、
  # 誤って値を落とした指定が成功して見える）。
  if [[ "$cross_given" == "true" && -z "$cross" ]]; then
    echo "ERROR: cross_review= needs a value: auto | off (use cross_review=auto to turn the fixed single-model setting off)." >&2
    return 1
  fi
  if [[ -z "$main" && "$cross_given" == "true" && -n "$existing_main" ]]; then
    main="$existing_main"
    echo "ℹ️  main は既存の設定（${main}）を引き継ぎます。" >&2
  fi
  if [[ -z "$main" && "$cross_given" != "true" ]]; then
    echo "ERROR: --set-reviewers requires main=<cli> (sub=<cli> and cross_review=auto|off are optional)." >&2
    return 1
  fi
  # `main=X` だけを渡したときに副を黙って消さない。部分更新に見える指定が
  # 全置換として振る舞うのは事故のもと。消したいときは `sub=` を明示する。
  if [[ "$sub_given" != "true" ]]; then
    sub="$existing_sub"
    [[ -n "$sub" ]] && echo "ℹ️  sub は既存の設定（${sub}）を引き継ぎます。消すには sub= を明示してください。" >&2
  fi
  # cross_review も同じ部分更新の作法。`main=X` で保存済みの off が黙って
  # 消えると、次回の単独レビューが「クロスレビューへ回してよい」に化ける。
  if [[ "$cross_given" != "true" ]]; then
    cross="$existing_cross"
  fi
  # 値は CLI 名ではない — 出所を名乗って auto | off だけを通す。引き継いだ値も
  # 検証する（手編集で壊れた 3 行目を保存し直す経路を塞ぐ）。
  if [[ "$cross_given" == "true" ]]; then
    validate_cross_review_value "--set-reviewers" "$cross" || return 1
  else
    validate_cross_review_value "user config $(reviewers_config_file)" "$cross" || return 1
  fi

  validate_reviewer_value main "$main" || return 1
  validate_reviewer_value sub  "$sub"  || return 1
  if [[ -n "$sub" && "$sub" == "$main" ]]; then
    echo "ERROR: sub reviewer must differ from main (both '${main}')." >&2
    return 1
  fi

  # 従量課金の CLI は分散モードでは毎回 --cli 明示のオプトインを要求している。
  # 保存はその一度きりの選択を「毎回のレビューで課金」へ変えるので、保存の時点で
  # 言う（プラン表示の [metered] は最後の砦であって、気づく最初の機会ではない）。
  local role value
  for role in main sub; do
    [[ "$role" == "main" ]] && value="$main" || value="$sub"
    [[ -z "$value" ]] && continue
    if [[ "$(get_cli_cost_tier "$value")" == "metered" ]]; then
      echo "⚠️  ${value} は従量課金です。${role} に保存すると、変更するまで毎回のレビューで課金されます。" >&2
    fi
  done

  write_reviewers_file "$main" "$sub" "$cross" || return 1
  echo "✅ Saved reviewers: main=${main} sub=${sub:-（なし）} cross_review=${cross:-auto}" >&2
  echo "   $(reviewers_config_file)" >&2
  return 0
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-lanes.sh"
