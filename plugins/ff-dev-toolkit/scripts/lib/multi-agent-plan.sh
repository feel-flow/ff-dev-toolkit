#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: CLI の検出・実行プランの構築・指定された CLI / 観点の検証・プランの表示と実行前の警告・観点ファイルの解決。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── CLI Detection ──
# 検出は「PATH に在るか」だけを見る。認証・残高の状態はここでは probe しない —
# 4 CLI の実提供機能を実測したうえでの判断で、根拠と代わりに何をしているかは
# classify_cli_failure_cause のヘッダーに書いてある（Issue `#659`）。
detect_available_clis() {
  AVAILABLE_CLIS=""
  EXCLUDED_INSTALLED_CLIS=""
  local cli_name cmd exclusion
  # 除外を掛ける**前**の導入済み本数。空プランの診断で「1 本も入っていない」と
  # 「入っているが全部外した」を分けるのに要る（除外指定の有無だけで分けると、
  # CLI が 1 つも入っていない環境で除外を書いただけの回に install 案内が消える）。
  local installed_before_exclusion=0

  for cli_name in $ALL_CLIS; do
    cmd="$(get_cli_command "$cli_name")"
    local cli_installed=false
    if command -v "$cmd" &>/dev/null; then
      cli_installed=true
      installed_before_exclusion=$((installed_before_exclusion + 1))
    fi
    # 除外は**検出の段**で効かせる。プラン構築側（distributed / cross-model / pair）
    # それぞれに除外条件を配ると、片方だけ直された形でドリフトする。ここで
    # AVAILABLE_CLIS から落とせば、未インストール CLI と同じ 1 本の経路
    # （観点の fallback 再配分・pair の主不在エラー・空プラン検査）をそのまま通る。
    # sandbox probe（warn_unappliable_sandbox）は「起動できないと分かっていても
    # プランからは外さない」側の機構で、こちらはその判断を利用者が明示したときの
    # 受け皿になる。
    exclusion="$(cli_exclusion_source "$cli_name")"
    # 除外が**実際に落とした**本数を別に数える。除外指定の有無で数えると、未導入 CLI を
    # 除外しただけの回（単一 CLI 環境の project config に exclude_clis: copilot-cli 等）が
    # 「除外で 1 本になった」扱いになり、打てる手の無い縮退警告が毎回出る。
    if [[ "$cli_installed" == "true" ]] && [[ "$exclusion" == "flag" || "$exclusion" == "config" ]]; then
      EXCLUDED_INSTALLED_CLIS="${EXCLUDED_INSTALLED_CLIS:+$EXCLUDED_INSTALLED_CLIS }$cli_name"
    fi
    case "$exclusion" in
      flag)
        echo "  ⏭  ${cli_name} excluded (--exclude-cli). Its perspectives follow the not-installed fallback path." >&2
        continue ;;
      config)
        echo "  ⏭  ${cli_name} excluded (config exclude_clis — ${EXCLUDE_CLIS_CONFIG_SOURCE}). Opt back in for one run with --cli ${cli_name}." >&2
        continue ;;
      config-overridden)
        echo "  ℹ️  ${cli_name} is in config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}) but --cli named it — running it this time." >&2
        ;;
    esac
    # 委譲レーンは CLI を 1 つも起動しないので、導入の有無で可用性を決めない
    # ここで未導入扱いにすると、観点が fallback CLI へ再配分され、
    # 「CLI が使えないからホストで走らせる」という指定がちょうどそのとき無効になる。
    if task_is_delegated "$cli_name"; then
      AVAILABLE_CLIS="${AVAILABLE_CLIS:+$AVAILABLE_CLIS }$cli_name"
      if [[ "$cli_installed" == "true" ]]; then
        echo "  🤝 ${cli_name} — delegated to the host (--delegate-to-host); ${cmd} is installed but will not be started" >&2
      else
        echo "  🤝 ${cli_name} — delegated to the host (--delegate-to-host); ${cmd} is not needed on this path" >&2
      fi
    elif [[ "$cli_installed" == "true" ]]; then
      AVAILABLE_CLIS="${AVAILABLE_CLIS:+$AVAILABLE_CLIS }$cli_name"
      echo "  ✅ ${cli_name} (${cmd})" >&2
    else
      echo "  ❌ ${cli_name} (${cmd}) — not installed" >&2
    fi
  done

  if [[ -z "$AVAILABLE_CLIS" ]]; then
    # 「1 本も入っていない」と「入っているが全部外した」は利用者の次の一手が違う。
    # 除外で空になった回に install を案内しても指し先が誤っている。逆に、除外を
    # 書いただけで**元から 1 本も入っていない**回に「全部外した」と言うと、唯一
    # 打てる手（install）を隠す。判定は指定の有無ではなく実測した導入本数で行う。
    if [[ "$installed_before_exclusion" -gt 0 ]] \
      && [[ -n "$EXCLUDE_CLIS_FLAG" || -n "$EXCLUDE_CLIS_CONFIG" ]]; then
      echo "" >&2
      echo "ERROR: every installed CLI was excluded — nothing would run." >&2
      [[ -n "$EXCLUDE_CLIS_FLAG" ]] && echo "       --exclude-cli: ${EXCLUDE_CLIS_FLAG}" >&2
      [[ -n "$EXCLUDE_CLIS_CONFIG" ]] && echo "       config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}): ${EXCLUDE_CLIS_CONFIG}" >&2
      exit 1
    fi
    echo "" >&2
    echo "ERROR: No AI CLIs are installed. Install at least one:" >&2
    echo "  npm install -g @anthropic-ai/claude-code" >&2
    echo "  npm install -g @openai/codex" >&2
    echo "  npm install -g @xai-official/grok" >&2
    exit 1
  fi
}

# ── Add to Execution Plan ──
add_to_plan() {
  local cli_name="$1" perspective="$2"
  EXECUTION_PLAN="${EXECUTION_PLAN:+$EXECUTION_PLAN
}${cli_name}:${perspective}"
}

# ── Build Execution Plan (distributed mode) ──
build_distributed_plan() {
  EXECUTION_PLAN=""
  local cli_name perspectives fallback_target

  for cli_name in $ALL_CLIS; do
    perspectives="$(get_cli_perspectives "$cli_name")"
    [[ -z "$perspectives" ]] && continue

    # A cost-bearing CLI must never enter any default task plan merely because it
    # is installed. The cost tier is the SSOT: future metered CLIs inherit the
    # same fail-safe without another name-specific branch. An explicit --cli is
    # the auditable opt-in for review, explore, and implement alike (Issue `#250`).
    if [[ "$(get_cli_cost_tier "$cli_name")" == "metered" && -z "$CLI_FILTER" ]]; then
      echo "  ⏭  ${cli_name} skipped (metered). Opt in with --cli ${cli_name}." >&2
      continue
    fi

    if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$cli_name"; then
      continue
    fi

    if list_contains "$AVAILABLE_CLIS" "$cli_name"; then
      # When both filters are explicit, the pair is the user's execution intent.
      # This is also the shape printed by failure advice for a substitute CLI:
      # forcing it back through the ownership registry can otherwise produce an
      # empty plan (for example codex-cli + security-analysis).
      #
      # 観点は**複数でもよい**。以前はここで `"$PERSPECTIVE_FILTER" != *" "*` を要求し、
      # 2 つ以上を指定すると下の所有権フィルタへ落ちていた。そちらは「1 つも一致
      # しなかった」ときにしか警告しないため、**一部だけ所有している場合に残りが
      # 黙って落ちる**（実測: codex-cli へ 3 観点を渡すと 1 観点だけが計画され、
      # 落ちた 2 つはどこにも名指しされなかった）。下のループは元から複数を回せる
      # 形になっており、条件だけが単数に絞っていた。CLI が 1 つに定まっていれば、
      # 「この CLI にこれらの観点をやらせる」は曖昧さのない指定なので通す。
      if [[ -n "$CLI_FILTER" && "$CLI_FILTER" != *" "* \
            && -n "$PERSPECTIVE_FILTER" ]]; then
        for p in $PERSPECTIVE_FILTER; do
          perspective_excluded "$p" && continue
          add_to_plan "$cli_name" "$p"
        done
      else
        local matched_perspective=false
        for p in $perspectives; do
          perspective_excluded "$p" && continue
          if [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p"; then
            continue
          fi
          add_to_plan "$cli_name" "$p"
          matched_perspective=true
        done

        # Availability and perspective ownership are different facts. Surface
        # the latter so an installed CLI is not mistaken for missing.
        if [[ -n "$PERSPECTIVE_FILTER" && "$matched_perspective" == "false" ]]; then
          if [[ "$PERSPECTIVE_FILTER" == *" "* ]]; then
            echo "  ⏭  ${cli_name} skipped — owns none of the requested perspectives (${PERSPECTIVE_FILTER})" >&2
          else
            echo "  ⏭  ${cli_name} skipped — owns no '${PERSPECTIVE_FILTER}' perspective" >&2
          fi
          echo "     (has: ${perspectives}). Use --mode cross-model to include it." >&2
        fi
      fi
    else
      fallback_target="$(resolve_available_fallback "$cli_name")"
      if [[ -n "$fallback_target" ]]; then
        if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$fallback_target"; then
          echo "  ⚠️  ${cli_name}: fallback ${fallback_target} excluded by --cli filter. Skipping." >&2
          continue
        fi
        # 「対応表どおりの代替」と「対応表が尽きて選び直した先」は利用者にとって
        # 別の話。後者は設定していない CLI が担当することになるので、そう読める
        # 表示にする。コスト帯も出す（最後の砦は課金先が変わりうる）。
        # 「入っていない」と「入っているが外した」は別の事実。除外で AVAILABLE_CLIS
        # から落ちた CLI にも not installed と書くと、install 済みの機械で偽の診断に
        # なる（利用者は入れ直そうとして、原因である除外へ辿り着けない）。
        local absent_reason
        case "$(cli_exclusion_source "$cli_name")" in
          flag)   absent_reason="${cli_name} excluded by --exclude-cli" ;;
          config) absent_reason="${cli_name} excluded by config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE})" ;;
          *)      absent_reason="${cli_name} not installed" ;;
        esac
        if [[ "$fallback_target" == "$(get_cli_fallback "$cli_name")" ]]; then
          echo "  ↪ ${cli_name} → ${fallback_target} (fallback — ${absent_reason})" >&2
        else
          echo "  ↪ ${cli_name} → ${fallback_target} [$(get_cli_cost_tier "$fallback_target")] (last-resort — configured chain exhausted)" >&2
        fi
        for p in $perspectives; do
          perspective_excluded "$p" && continue
          if [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p"; then
            continue
          fi
          add_to_plan "$fallback_target" "$p"
        done
      else
        # 「代替が設定されていない」と「設定はあるが連鎖の先まで全部未導入」は
        # 利用者にとって別の話（後者はインストールで直る）。区別して出す。
        echo "  ⚠️  ${cli_name}: no installed fallback (configured: $(get_cli_fallback "$cli_name")). Skipping: ${perspectives}" >&2
      fi
    fi
  done

  # Apply cost strategy: minimize_cost moves premium → the cheapest remaining
  # tier. The substitute was cursor-cli until issue `#240`, then gemini-cli
  # [free-tier] until issue `#783` removed it; grok-cli [flat-rate] now takes the
  # role (no marginal cost per task — the closest analogue to the free tier).
  # There is no tier ordering in the code (KNOWN_TIERS is an unordered set), so
  # this is a named choice, not a computed one — which is deliberate: naming the
  # substitute keeps the swap readable in the plan output, and the user sees
  # which model actually ran.
  #
  # The sequential-worker mitigation (issue `#251`) in execute_tasks is tier-keyed
  # and follows the substitute: it now serializes flat-rate CLI groups.
  if [[ "$STRATEGY" == "minimize_cost" && -z "$CLI_FILTER" ]]; then
    local new_plan=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local cli="${entry%%:*}"
      local persp="${entry#*:}"
      if [[ "$cli" == "claude-code" ]] && list_contains "$AVAILABLE_CLIS" "grok-cli"; then
        echo "  💰 minimize_cost: ${persp}: claude-code → grok-cli" >&2
        new_plan="${new_plan:+$new_plan
}grok-cli:${persp}"
      else
        new_plan="${new_plan:+$new_plan
}${entry}"
      fi
    done <<< "$EXECUTION_PLAN"
    EXECUTION_PLAN="$new_plan"
  fi
}

# ── Build Execution Plan (pair mode: main + sub) ──
#
# 主 = review 観点すべて / 副 = 総合レビュー 1 本。副が居なければ主だけに縮退する。
# 縮退はすべて続行（exit 0）で、止めるのは「主が未インストール」のときだけ。
build_pair_plan() {
  EXECUTION_PLAN=""
  PAIR_SUB_DROPPED=false
  PAIR_REVIEWERS_NOTE=""
  local p sub_effective=""

  if ! list_contains "$AVAILABLE_CLIS" "$REVIEW_MAIN"; then
    # 主が居ない理由は「未導入」と「除外した」の 2 つあり、次の一手が違う。
    # 除外した回に「Install it」と言うと、install 済みの機械で偽の診断になる。
    # pair モードでは --cli による一回限りの復帰が使えない（--mode pair の明示と
    # 併用すれば非 0、暗黙なら distributed へ落ちてそもそも pair ではなくなる）ので、
    # 解除は「除外を外す」か「別の主を選ぶ」の 2 つだけだと名乗る。
    case "$(cli_exclusion_source "$REVIEW_MAIN")" in
      flag)
        echo "ERROR: main reviewer '${REVIEW_MAIN}' was excluded by --exclude-cli." >&2
        echo "       Drop '${REVIEW_MAIN}' from --exclude-cli, or pick another main with" >&2
        echo "       --set-reviewers main=<cli> / MULTI_AGENT_REVIEW_MAIN=<cli>." >&2
        echo "       (--cli does not opt it back in here: it is a distributed-mode filter" >&2
        echo "        and cannot be combined with --mode pair.)" >&2 ;;
      config)
        echo "ERROR: main reviewer '${REVIEW_MAIN}' was excluded by config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE})." >&2
        echo "       Remove '${REVIEW_MAIN}' from exclude_clis, or pick another main with" >&2
        echo "       --set-reviewers main=<cli> / MULTI_AGENT_REVIEW_MAIN=<cli>." >&2
        echo "       (--cli does not opt it back in here: it is a distributed-mode filter" >&2
        echo "        and cannot be combined with --mode pair.)" >&2 ;;
      *)
        echo "ERROR: main reviewer '${REVIEW_MAIN}' is not installed." >&2
        echo "       Install it, or pick another with --set-reviewers." >&2 ;;
    esac
    return 1
  fi

  # --strategy minimize_cost は分散プランの振替（premium 観点 → 最安 tier の CLI、
  # build_distributed_plan 末尾）で、pair には対応する概念が無い（Issue `#691`）。
  # 従来はここで黙って何も起きなかった（効かないつまみ）。`#255` の --cli は
  # 「分散モード用のフィルタ」だから分散へ落とすことで指定の意図を守れたが、
  # minimize_cost を同じ形で分散へ落とすと、コストのつまみ一つで設定済みの
  # 主・副（= 誰がレビューしたか）ごと入れ替わる。主を振替先へ差し替える案も
  # 同じ理由で採らない（振替先が副と同一 CLI ならクロスモデル性も消える）。
  # pair のコストは主・副の選定そのもので決まるので、「ここでは効かない」を
  # 名乗り、効かせる場所（--set-reviewers / --mode distributed）を指す。
  # balanced / maximize_quality はプランを変えない既定ラベルなので黙る
  # （毎回の常時表示は雑音で、既定実行の出力を変えない、という契約も守る）。
  if [[ "$STRATEGY" == "minimize_cost" ]]; then
    echo "  ℹ️  cost strategy 'minimize_cost' (from ${STRATEGY_SOURCE}) does not apply in pair mode — reviewers are the configured main/sub pair, not tier-substituted." >&2
    echo "     To lower cost: pick cheaper reviewers (--set-reviewers main=NAME,sub=NAME) or use --mode distributed, where minimize_cost applies." >&2
  fi

  # 副の縮退判定。どれも「主のみで続行」で、理由だけを変えて伝える。
  # 縮退した事実は stderr だけでなく統合レポートにも残す（Issue `#699`）。stderr は
  # 実行を見ていた人しか読まないが、レポートは後から読まれる — `Mode: pair` だけが
  # 残っていると、単一 CLI で走ったものをクロスモデル済みと誤読する。
  if [[ -z "$REVIEW_SUB" ]]; then
    echo "  ℹ️  No sub reviewer set — running single-reviewer. Set one for cross-model coverage." >&2
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} (single — no sub reviewer set)"
  elif [[ "$REVIEW_SUB" == "$REVIEW_MAIN" ]]; then
    echo "  ⏭  sub reviewer is the same CLI as main (${REVIEW_MAIN}) — skipping the duplicate." >&2
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} (single — sub '${REVIEW_SUB}' is the same CLI as main)"
  elif cli_excluded "$REVIEW_SUB"; then
    # 除外は未導入と別の事実。ここを not-installed の枝へ落とすと、install 済みの
    # 機械に「not installed」と記録され（レポートへも残る）、しかも
    # PAIR_SUB_DROPPED が立たないので単一 CLI 縮退の警告まで消える。
    # 除外はクロスモデルにできたのに単一へ落ちた経路なので、--perspective で副が
    # 落ちた場合と同じくフラグを立てる（--exclude-perspective の「その観点を走らせ
    # るな」とは違い、外したのは CLI であって総合観点の要否ではない）。
    local sub_excl_desc
    if [[ "$(cli_exclusion_source "$REVIEW_SUB")" == "flag" ]]; then
      sub_excl_desc="--exclude-cli"
    else
      sub_excl_desc="config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE})"
    fi
    PAIR_SUB_DROPPED=true
    echo "  ⚠️  sub reviewer '${REVIEW_SUB}' excluded by ${sub_excl_desc} — running single-reviewer." >&2
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} (single — sub '${REVIEW_SUB}' excluded by ${sub_excl_desc})"
  elif ! list_contains "$AVAILABLE_CLIS" "$REVIEW_SUB"; then
    # 未導入は情報行（ℹ️）で、警告（⚠️）にしない（単一 CLI 基準線への整合）。基準線は主担当 1 モデル
    # （ADR-053 決定 1。同 決定 6 の「警告は据え置き」は本変更で改訂）なので、副が入っていない環境で単一に落ちた回は正常であり、打てる手も
    # install 以外に無い。⚠️ のままだと「単一は正常」と言う文書と「機械は毎回警告する」
    # が食い違う。除外（上の枝）と --perspective 落ち（下）は「副を立てられたのに落ちた」
    # 経路なので ⚠️ のまま。PAIR_SUB_DROPPED も立てず、単一 CLI 縮退警告は出さない。
    echo "  ℹ️  sub reviewer '${REVIEW_SUB}' is not installed — running single-reviewer (the baseline; install it to add a cross-model review)." >&2
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} (single — sub '${REVIEW_SUB}' not installed)"
  else
    sub_effective="$REVIEW_SUB"
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} + ${sub_effective}"
  fi

  for p in $(get_cli_perspectives_review "$REVIEW_MAIN"); do
    perspective_excluded "$p" && continue
    [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p" && continue
    add_to_plan "$REVIEW_MAIN" "$p"
  done
  # 主は「review 観点すべて」を担当する。所有レジストリは分散モード用の割当なので、
  # 主が所有していない観点もここでは主に回す（それが pair モードの定義）。
  for p in $(all_review_perspectives); do
    list_contains "$(get_cli_perspectives_review "$REVIEW_MAIN")" "$p" && continue
    # 総合観点は副の担当なので、既定では主に載せない。ただし --perspective で
    # 明示指定されていて副が居ない場合は主へ回す。ここを飛ばすと空プランになり、
    # 「副が居なければ主のみで続行」という縮退契約に反して exit 1 で止まる。
    if [[ "$p" == "$COMPREHENSIVE_PERSPECTIVE" ]]; then
      if [[ -n "$sub_effective" ]] \
        || [[ -z "$PERSPECTIVE_FILTER" ]] \
        || ! list_contains "$PERSPECTIVE_FILTER" "$COMPREHENSIVE_PERSPECTIVE"; then
        # 副が居ない既定構成（--perspective 無指定）では、総合観点は誰にも割り当て
        # られないままプランが 1 件少なくなる。既定で主へ回さないのは、主が既に
        # 全観点を担当していて同一モデルの二重レビューになるため（pair の設計意図は
        # 別モデルによる総合観点）。ただし「走らない」ことは名乗る — 出力に何も
        # 出ないと、プランの件数が 1 少ない理由が実行ログから復元できない（Issue `#699`）。
        if [[ -z "$sub_effective" && -z "$PERSPECTIVE_FILTER" ]] \
          && ! perspective_excluded "$COMPREHENSIVE_PERSPECTIVE"; then
          echo "  ⏭  ${COMPREHENSIVE_PERSPECTIVE} — no reviewer; not covered in this run." >&2
        fi
        continue
      fi
      # 除外判定は宣言より前に行う。逆順だと「主に回した」と宣言した直後に捨てる
      # 矛盾出力になる（--perspective X --exclude-perspective X・副なしで再現。Issue `#699`）。
      perspective_excluded "$p" && continue
      echo "  ↪ ${COMPREHENSIVE_PERSPECTIVE} → ${REVIEW_MAIN} (no sub reviewer available)" >&2
    fi
    perspective_excluded "$p" && continue
    [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p" && continue
    add_to_plan "$REVIEW_MAIN" "$p"
  done

  if [[ -n "$sub_effective" ]]; then
    if ! perspective_excluded "$COMPREHENSIVE_PERSPECTIVE" \
      && { [[ -z "$PERSPECTIVE_FILTER" ]] || list_contains "$PERSPECTIVE_FILTER" "$COMPREHENSIVE_PERSPECTIVE"; }; then
      # 副に従量課金 CLI を選ぶのは明示的な指定なので opt-in とみなす。ただし
      # コスト帯はプラン表示に出るので、黙って課金されることはない。
      add_to_plan "$sub_effective" "$COMPREHENSIVE_PERSPECTIVE"
    elif perspective_excluded "$COMPREHENSIVE_PERSPECTIVE"; then
      # --exclude-perspective で副の唯一の担当を外したケース。理由は名乗るが、
      # 単一 CLI 縮退警告（下の PAIR_SUB_DROPPED）は立てない。「その観点を走らせ
      # るな」という明示指定は `#183` の --cli と同じく意図的な単一モデルなので、
      # 黙る側に倒す。
      echo "  ⏭  sub reviewer '${sub_effective}' runs only '${COMPREHENSIVE_PERSPECTIVE}', excluded by --exclude-perspective — running single-reviewer." >&2
    else
      # --perspective が総合観点を含まないケース（Issue `#597`）。他 3 経路（副が
      # 未設定 / 主と同一 / 未導入）は全部理由を出しているのに、ここだけ else が
      # 無く無言で落ちていた。書式を揃える。
      #
      # 「クロスモデルにできたのに単一になった」経路は本経路と除外（上の
      # cli_excluded の枝）の 2 つで、単一 CLI 縮退警告のフラグを立てるのもこの 2 つだけ。
      # 残る 3 経路（副未設定 / 主と同一 / 未導入）は主しか使えない状況をそれぞれの
      # 1 行で説明済みで、そこへ「--mode cross-model にせよ」と足しても
      # 副が居ない事実は変わらない。逆に --perspective comprehensive-review は
      # 副だけが残って単一 CLI になるが、それは要求どおりなので警告しない
      # （プラン CLI 数だけを見る一般化された gate では、この差が潰れる）。
      PAIR_SUB_DROPPED=true
      echo "  ⏭  sub reviewer '${sub_effective}' runs only '${COMPREHENSIVE_PERSPECTIVE}', not in --perspective (${PERSPECTIVE_FILTER}) — running single-reviewer." >&2
    fi
  fi

  # Reviewers 行は**組んだプラン**から導出する（Issue `#699`）。副の導入可否だけで
  # 決めると、--perspective / --exclude-perspective で副が計画から落ちた回に
  # 「main + sub」と記録され、単一 CLI で走ったものをクロスモデル済みと誤読させる
  # — レポートへ事実を残すという当の目的を裏切る。上の 4 分岐が入れた縮退理由は、
  # プランが実際に単一 CLI のときだけ活かす。
  local planned_clis
  planned_clis="$(printf '%s\n' "$EXECUTION_PLAN" | awk -F: 'NF { print $1 }' | sort -u | tr '\n' ' ')"
  planned_clis="${planned_clis% }"
  case "$planned_clis" in
    "") PAIR_REVIEWERS_NOTE="" ;;                      # 空プラン。後段の gate が止める
    *" "*) PAIR_REVIEWERS_NOTE="${planned_clis// / + }" ;;  # 実際に 2 CLI 以上
    *)
      # 単一 CLI。縮退理由が既にあるならそれを使い、無ければプラン側の事実だけ書く
      # （--perspective で副だけが残った回など、縮退ではなく指定どおりのケース）。
      if [[ "$PAIR_REVIEWERS_NOTE" == "${planned_clis} ("* ]]; then
        : # 4 分岐が入れた理由つきの記録をそのまま使う
      else
        PAIR_REVIEWERS_NOTE="${planned_clis} (single — only this CLI is in the plan)"
      fi ;;
  esac
  return 0
}

# review の観点ファイル一覧（総合レビューを含む、ディスク上の実体）。
# タスク種別に対応する観点の一覧。観点の実体は perspectives/<task>/*.md なので、
# 一覧も除外の検証もここから導出する。別に配列を持つと、ファイルを足したときに
# 片方だけ古くなる。
all_task_perspectives() {
  local f
  for f in "${SCRIPT_DIR}/perspectives/${TASK_TYPE}"/*.md; do
    [[ -f "$f" ]] || continue
    basename "$f" .md
  done
}

all_review_perspectives() {
  local f
  for f in "${SCRIPT_DIR}/perspectives/review"/*.md; do
    [[ -f "$f" ]] || continue
    basename "$f" .md
  done
}

# ── Build Execution Plan (cross-model mode) ──
build_cross_model_plan() {
  EXECUTION_PLAN=""
  local perspective="${PERSPECTIVE_FILTER:-code-review}"
  perspective="${perspective%% *}"

  echo "  🔄 Cross-model mode: all CLIs run '${perspective}'" >&2

  for cli_name in $AVAILABLE_CLIS; do
    if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$cli_name"; then
      continue
    fi
    # Copilot CLI is metered — include only when explicitly requested via --cli
    if [[ "$cli_name" == "copilot-cli" && -z "$CLI_FILTER" ]]; then
      echo "  ⏭  copilot-cli skipped (metered). Opt in with --cli copilot-cli." >&2
      continue
    fi
    perspective_excluded "$perspective" && continue
    add_to_plan "$cli_name" "$perspective"
  done
}

# ── Validate Requested CLIs ──
# An unknown --cli used to fail late and vaguely: the name matched nothing in the
# ownership registry, every CLI was filtered out, and the empty-plan guard then
# reported "no CLI/perspective matched the given filters" without ever naming the
# CLI that does not exist — leaving the user to guess whether the fault was the
# --cli, the --perspective, or the --mode. A retired name (cursor-cli, removed in
# issue `#240`) is the case that makes that guessing expensive, because the name
# looks valid. Reject it here instead: before the plan is built, naming the
# offending value and the CLIs that do exist.
# 存在しない観点名の除外を黙って受けると、typo が「除外したつもり」で素通りし、
# 意図せず課金される観点が走る。名前は観点ファイルの実体と照合する。
validate_excluded_perspectives() {
  [[ -n "$EXCLUDE_PERSPECTIVES" ]] || return 0
  local known ex
  known="$(all_task_perspectives | tr '\n' ' ')"
  for ex in $EXCLUDE_PERSPECTIVES; do
    if ! list_contains "$known" "$ex"; then
      echo "ERROR: --exclude-perspective に存在しない観点が指定されました: ${ex}" >&2
      echo "       task '${TASK_TYPE}' で使える観点: ${known}" >&2
      exit 2
    fi
  done
}

validate_requested_clis() {
  local cli_name
  for cli_name in $CLI_FILTER; do
    if ! is_safe_token "$cli_name"; then
      echo "ERROR: unsafe CLI name: '${cli_name}'" >&2
      return 1
    fi
    if ! list_contains "$ALL_CLIS" "$cli_name"; then
      echo "ERROR: unknown CLI: '${cli_name}'" >&2
      echo "       Known CLIs: ${ALL_CLIS}" >&2
      return 1
    fi
  done
}

# ── Excluded CLIs ──
# 除外の出所を返す。引数と設定の両方に載っている CLI は引数側を名乗る — 利用者が
# その実行で明示した意図が上位だから。
#   flag              --exclude-cli による除外
#   config            設定ファイルの exclude_clis による除外
#   config-overridden 設定は外しているが、その実行で --cli が明示的に選んだ
#                     （環境の既定より、その 1 回の明示指定を上に置く。設定を書き換え
#                      なくても「今日は動くか試す」ができる形にしておく）
#   空文字列          除外されていない
cli_exclusion_source() {
  if [[ -n "$EXCLUDE_CLIS_FLAG" ]] && list_contains "$EXCLUDE_CLIS_FLAG" "$1"; then
    echo "flag"
  elif [[ -n "$EXCLUDE_CLIS_CONFIG" ]] && list_contains "$EXCLUDE_CLIS_CONFIG" "$1"; then
    if [[ -n "$CLI_FILTER" ]] && list_contains "$CLI_FILTER" "$1"; then
      echo "config-overridden"
    else
      echo "config"
    fi
  else
    echo ""
  fi
}

cli_excluded() {
  local origin
  origin="$(cli_exclusion_source "$1")"
  [[ "$origin" == "flag" || "$origin" == "config" ]]
}

# 存在しない CLI 名の除外を黙って受けると、typo が「外したつもり」で素通りし、
# 起動できないと分かっている CLI が毎回プランに載り続ける（この機能が消そうとして
# いる状態そのもの）。--cli と同じく、プランを組む前に名指しで拒否する。設定由来の
# 名前も同じ扱い — 設定側だけ緩めると、typo が一度書かれたきり誰にも気づかれない。
#
# --cli X と --exclude-cli X の同時指定も拒否する。片方を優先する規則を置くと、
# 「選んだのに走らない」か「外したのに走る」のどちらかが黙って起きる。
#
# 未知名の扱いは出所で分ける（PR `#1410` レビュー項目 12）。
#   引数由来: 非 0 で拒否。その 1 回のためにいま打った指定なので、typo は即座に
#             直せるし、直さないと「外したつもり」の CLI が走る。
#   設定由来: WARNING を出して**その名前だけ**落とし、実行は続ける。設定は複数の
#             機械・複数のリポジトリで共有され、CLI が retire されると（cursor-cli /
#             gemini-cli の前例がある）過去に妥当だった設定が全実行を落とす。
#             「レビューが 1 本も走らない」は「除外が 1 つ効かない」より重い故障で、
#             しかも設定を書いた人と踏む人が違いうる。名前は警告で名指しするので
#             黙って消えることはない。
# 不正トークン（is_safe_token 不一致）は出所に依らず非 0 のまま — こちらは typo で
# はなく注入の形で、警告して読み飛ばす対象ではない。
validate_excluded_clis() {
  local cli_name
  for cli_name in $EXCLUDE_CLIS_FLAG $EXCLUDE_CLIS_CONFIG; do
    if ! is_safe_token "$cli_name"; then
      echo "ERROR: unsafe CLI name in exclusion: '${cli_name}'" >&2
      return 1
    fi
  done
  for cli_name in $EXCLUDE_CLIS_FLAG; do
    if ! list_contains "$ALL_CLIS" "$cli_name"; then
      echo "ERROR: unknown CLI in --exclude-cli: '${cli_name}'" >&2
      echo "       Known CLIs: ${ALL_CLIS}" >&2
      return 1
    fi
  done
  local kept_config=""
  for cli_name in $EXCLUDE_CLIS_CONFIG; do
    if ! list_contains "$ALL_CLIS" "$cli_name"; then
      echo "⚠️  unknown CLI in config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}): '${cli_name}' — ignoring it." >&2
      echo "    Known CLIs: ${ALL_CLIS}. Remove the stale name from the config." >&2
      continue
    fi
    kept_config="${kept_config:+$kept_config }$cli_name"
  done
  EXCLUDE_CLIS_CONFIG="$kept_config"
  [[ -z "$EXCLUDE_CLIS_CONFIG" ]] && EXCLUDE_CLIS_CONFIG_SOURCE=""
  for cli_name in $CLI_FILTER; do
    if [[ -n "$EXCLUDE_CLIS_FLAG" ]] && list_contains "$EXCLUDE_CLIS_FLAG" "$cli_name"; then
      echo "ERROR: --cli and --exclude-cli both name '${cli_name}'." >&2
      echo "       Drop one: --cli selects what runs, --exclude-cli removes it." >&2
      return 1
    fi
  done
  return 0
}

# ── Validate Requested Perspectives ──
# A dry-run is a plan validation boundary, not only a pretty-printer. Reject an
# unsafe, unknown, or other-task perspective before showing a successful plan;
# otherwise the same command fails only after a real CLI dispatch is attempted.
validate_requested_perspectives() {
  local perspective perspective_file
  for perspective in $PERSPECTIVE_FILTER; do
    if ! is_safe_token "$perspective"; then
      echo "ERROR: unsafe perspective name: '${perspective}'" >&2
      return 1
    fi
    perspective_file="$(resolve_perspective_file "$perspective")"
    if [[ -z "$perspective_file" ]]; then
      echo "ERROR: perspective '${perspective}' does not exist for task '${TASK_TYPE}'." >&2
      return 1
    fi
  done
}

# ── Show Execution Plan ──
# --base（または env / 自動検出）が**ローカル** branch を指し、それが origin より
# 後退している場合に、プラン構築前へ警告を 1 行群で出す（Issue `#759`）。
#
# 背景（消費側 ACE-209-1 の実測）: ブランチは origin/develop から切ったのに
# --base develop はローカル develop（2 コミット古い）を指し、レビュー diff に他人の
# マージ済みコミット 7 ファイルが混入 — Critical 指摘 2 件が全部「自分の差分に無い
# ファイル」の話になった。逆にローカル base が新しい（rebase 済み等）と自分の差分の
# 一部がレビューされない偽陰性にもなる。
#
# 設計:
#   - **中断ではなく警告**。意図的にローカル base を使う運用（オフライン・ローカル
#     統合ブランチ等）を壊さない
#   - **fail-open**: origin/<branch> が無い・rev-list が失敗・数値が取れない場合は
#     黙って従来どおり。判定できないことを警告にすると常時ノイズになる
#   - **--staged は対象外**（base を使わない）。`origin/...` 形式や SHA 指定も対象外
#     （refs/heads に解決されない = ローカル branch を指していない）
#   - **ローカルが進んでいる（ahead）だけの場合も対象外**。未 push のローカル
#     コミットを base にするのは「ローカルで積んだ統合ブランチ」という別の意図的
#     運用で、警告すると常設ノイズになる。混入事故の向き（behind）だけを見る
#   - 判定は behind の**数ではなく merge-base の比較**で行う。diff は三点比較
#     （BASE...HEAD = merge-base(BASE, HEAD) から HEAD）なので、ブランチを**古い
#     ローカル base から**切った場合は、ローカルがいくら behind でも diff は
#     origin 比較と同一で混入は起きない — behind>0 を述語にすると、この最も普通の
#     「pull していないだけ」の形で毎回誤警告する（セルフレビューで実測反証）。
#     混入が起きるのは merge-base(local, HEAD) と merge-base(origin, HEAD) が
#     食い違うときで、その差分コミット数がまさに混入する件数になる
#
# 現在は base 解決（resolve_base_branch_ref）が「ローカルが origin の真の祖先」の場合に
# origin/<base> を採るため、その形はここへ到達する前に origin/* へ倒れて早期 return する。
# ここに残る実効ケースは**分岐**（双方に固有コミット）で、解決側が保守的にローカルを
# 維持する形。混入は起こりうるが自動で差し替えると未 push のコミットが差分から落ちるため、
# 警告に留めるという役割分担にしてある。
warn_if_stale_local_base() {
  [[ "$STAGED_DIFF" == "true" ]] && return 0
  [[ "$IN_GIT_REPO" == "true" ]] || return 0
  local base="$BASE_BRANCH" mb_local mb_origin leaked base_q origin_q
  # origin/ 前置は「remote 側を明示した」意図なので、たとえローカルに同名 branch
  # （refs/heads/origin/develop）が併存していても対象外にする（Codex レビュー指摘）
  case "$base" in origin/*) return 0 ;; esac
  # 裸名だと同名 tag が branch より先に解決されて比較がずれるため、完全修飾で固定する
  git rev-parse --verify --quiet "refs/heads/${base}" >/dev/null 2>&1 || return 0
  git rev-parse --verify --quiet "refs/remotes/origin/${base}" >/dev/null 2>&1 || return 0
  mb_local="$(git merge-base "refs/heads/${base}" HEAD 2>/dev/null)" || return 0
  mb_origin="$(git merge-base "refs/remotes/origin/${base}" HEAD 2>/dev/null)" || return 0
  [[ -n "$mb_local" && -n "$mb_origin" ]] || return 0
  [[ "$mb_local" == "$mb_origin" ]] && return 0
  leaked="$(git rev-list --count "${mb_local}..${mb_origin}" 2>/dev/null)" || return 0
  [[ "$leaked" =~ ^[0-9]+$ ]] || return 0
  if [[ "$leaked" -gt 0 ]]; then
    # 貼り付け実行される案内コマンドに branch 名を素で埋めない（; や $( ) を含む
    # branch 名は git 的に合法で、shell_quote ならシェル安全な引用になる。通常名は素のまま）
    base_q="$(shell_quote "$base")"
    origin_q="$(shell_quote "origin/${base}")"
    echo "" >&2
    echo "⚠️  base '${base}' はローカル ref で、このブランチの分岐点（origin/${base} 基準）より古い状態です。" >&2
    echo "    他ブランチのマージ済みコミット ${leaked} 件が diff に混入します。" >&2
    echo "    最新化（git fetch && git switch ${base_q} && git pull --ff-only）または" >&2
    echo "    --base ${origin_q} を検討してください。" >&2
  fi
  return 0
}

# ── Sandbox applicability warning（プラン時 probe） ──
#
# 潰す事故: **プランには載るのに一度も走らない CLI**。grok はサンドボックスを
# 適用できない環境でモデルを呼ぶ前に起動を拒否する（観測台帳の実測: macOS で
# /var/run/docker.sock が symlink の環境。runtime-socket の deny path を解決できず
# status 1）。実行時の検出（アダプタの refuse → 結果 INCOMPLETE）は既にあるが、
# それが分かるのはタスクを丸ごと失ったあとで、dry-run は毎回「載る」としか言わない。
# 「3 本のクロスモデル」のつもりが常に 2 本で走る、という形が見えないまま続く。
#
# 認証・残高を probe しないという方針（detect_available_clis のヘッダー、および
# classify_cli_failure_cause の「なぜ preflight probe を採らなかったか」）は
# **そのまま維持する**。あちらを退けた理由は「残高・認証は課金される API 呼び出しを
# しないと分からない」で、ここで見るのは性質が違う:
#   - 環境固有（このマシンでは毎回失敗する）
#   - 決定的（同じ環境なら同じ答え）
#   - モデルを呼ぶ前に確定する（= 課金されない手段で観測できる）
# probe の実体はアダプタ側（grok-cli-adapter.sh の run_sandbox_probe）にあり、
# 課金されないことの実測根拠もそこに書いてある。
#
# プランからは**外さない**。実行時の失敗を別モデルへ振り替えない方針（Runtime
# fallback: none）と同じ理由で、走らせる対象を勝手に間引くと「頼んだ CLI が黙って
# 消えた」形になる。表示を足すだけにして、外す判断は利用者へ残す。
#
# 黙るのは、probe が sandbox の適用記録（ProfileApplied）の増加を見た場合と、
# sandbox と無関係な失敗（アダプタが無い・CLI が別の理由で非 0・timeout）の場合だけ。
# 「この環境では動く」と断定はしないので、警告が出ないことは成功の保証ではない。
# 逆に、拒否の目印が何も出ないまま適用記録も増えない**不活性**（inert。Windows 実測
# = https://github.com/feel-flow/ff-dev-toolkit/issues/111）と、その増分を**測れなかった**場合
# （undetermined）は黙らない — どちらも黙ると「毎回 INCOMPLETE」が起動前に見えなくなる。
readonly SANDBOX_PROBE_REFUSED_STATUS=3

# 表示位置は**その CLI の項目の直下**（プラン一覧の後ろへまとめない）。CLI が 3 つ
# 並ぶプランで末尾にまとめると、どの行の話かを読み手が数え直すことになる。呼び出し側
# （show_plan のループ）は 1 CLI 分を出し終えた時点でこれを呼ぶ。
warn_unappliable_sandbox() {
  # dry-run のときだけ probe する。実行時は数秒後に本物の dispatch が同じことを
  # 確かめるので、そこへ CLI プロセスをもう 1 つ足す価値が無い（起動回数を数えている
  # 検査もある）。本スキルの手順は dry-run でプランを確認してから実行する形なので、
  # 「起動前に分かる」という目的はこちらだけで満たせる。
  [[ "$DRY_RUN" == "true" ]] || return 0
  local cli="$1" adapter probe_out probe_rc kind reason
  cli_sandbox_probe_supported "$cli" || return 0
  adapter="$(get_cli_adapter "$cli")"
  [[ -n "$adapter" && -f "$adapter" ]] || return 0
  probe_rc=0
  probe_out="$(bash "$adapter" --probe-sandbox "$TASK_TYPE" 2>/dev/null)" || probe_rc=$?
  [[ "$probe_rc" -eq "$SANDBOX_PROBE_REFUSED_STATUS" ]] || return 0
  # アダプタの出力契約: 1 行目 = 種別、2 行目 = CLI 自身が出した理由。
  kind="$(printf '%s\n' "$probe_out" | sed -n '1p')"
  reason="$(printf '%s\n' "$probe_out" | sed -n '2p')"
  # 見出しも種別で分ける。undetermined は「適用できない」と分かったわけではないので、
  # 同じ見出しを出すと測れなかっただけの環境を欠陥として断定することになる。
  if [[ "$kind" == "undetermined" ]]; then
    echo "     ⚠️  ${cli}: この環境で sandbox が効くかを起動前に判定できませんでした。" >&2
  else
    echo "     ⚠️  ${cli}: この環境では sandbox を適用できません（起動前に判明）。" >&2
  fi
  if [[ -n "$reason" ]]; then
    echo "         ${reason}" >&2
  fi
  # 帰結は種別で分ける。「起動を拒否する」と「sandbox 無しで起動する」は、利用者が
  # 見るログの形も、疑うべき箇所も違う（後者は CLI が正常終了したように見える）。
  if [[ "$kind" == "inert" ]]; then
    echo "         CLI は sandbox の指定をエラーも警告も出さずに受け流し、適用の記録（ProfileApplied）を" >&2
    echo "         残しません（このプラットフォームでは sandbox の仕組みが働いていない。例: Windows）。" >&2
    echo "         実行時のゲートは適用の記録が無い結果を採用しないので、プランに載っていても" >&2
    echo "         成果は得られず、毎回 INCOMPLETE として報告されます。" >&2
  elif [[ "$kind" == "undetermined" ]]; then
    echo "         判定に使う sandbox のイベントログを数えられませんでした（上の理由）。実行時のゲートも" >&2
    echo "         同じログで適用を確認するため、そのままでは結果が INCOMPLETE になる可能性があります。" >&2
  elif [[ "$kind" == "unsandboxed-start" ]]; then
    echo "         CLI は sandbox 無しで起動するため、このアダプタが要求した保護が" >&2
    echo "         効かないまま走ります。実行時のゲートがその結果を採用しないので、" >&2
    echo "         プランには載っていても成果は得られず、INCOMPLETE として報告されます。" >&2
  else
    echo "         プランには載りますが CLI が起動を拒否するため未実行になり、" >&2
    echo "         結果は INCOMPLETE として報告されます。" >&2
  fi
  echo "         プランからは外しません（実行時の失敗を別モデルへ振り替えない方針のため）。" >&2
  # 外す手段は「今回だけ」と「恒久」の 2 択を**ここで**示す。--cli の明示だけを案内すると、
  # probe が「時間で復帰しない」と判定した失敗に対して毎回同じ手動除外を要求することになり、
  # 既存の恒久策（config の exclude_clis）に利用者が到達できない。--exclude-cli はその 1 回の
  # 引数なので「今回だけ」側（--cli と --exclude-cli の同時指定は拒否されるため、設定由来の
  # 除外だけが --cli で 1 回だけ戻せる）。設定行は CLI 名を埋めた形で印字し、コピーで済ませる。
  # exclude_clis は 1 文字列 1 キーなので、既にある場合は「行を足す」ではなく「値へ足す」。
  # 外す以外の道（docker.sock symlink 対応）。理由が runtime-socket の deny path（docker.sock の
  # symlink）なら、read-only 相当を保ったまま起動できるカスタムプロファイルがある。
  # 除外はカバレッジを 1 本減らすので、外す 2 択より**先に**「動かす」道を示す。
  if [[ "$cli" == "grok-cli" && "$reason" == *runtime-socket* ]]; then
    echo "         外さずに動かす（推奨）: この拒否は restrict_network の deny が symlink を解決できないもので、" >&2
    echo "                     macOS では restrict_network 自体が no-op です。~/.grok/sandbox.toml に" >&2
    echo "                       [profiles.ff-review-ro]" >&2
    echo "                       extends = \"read-only\"" >&2
    echo "                       restrict_network = false" >&2
    echo "                     を置き、MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro で起動すると review / explore が" >&2
    echo "                     read-only の書き込み境界のまま走ります（アダプタが実行後に read_write_paths を検証）。" >&2
    echo "                     失うのはコンテナランタイムのソケット遮断（docker.sock へ接続できる。実測）。" >&2
    echo "                     Linux では restrict_network が子プロセスの遮断を実際に担うので、この差し替えを既定にしない。" >&2
    echo "                     詳細: docs-template/05-operations/deployment/grok-cli-reviewer.md" >&2
  fi
  # undetermined は「この機械では毎回ダメ」と分かったわけではない（測れなかっただけで、
  # 原因を直せば走る）。恒久除外を案内すると、直せば使える CLI を設定で永久に落とさせる。
  # 今回だけの外し方だけを出す。
  if [[ "$kind" == "undetermined" ]]; then
    echo "         この実行から外すなら: 走らせたい CLI を --cli で明示するか、外す方を --exclude-cli ${cli} で名指しする" >&2
    echo "                     （その 1 回の引数。判定不能の原因を直せば次回は警告が消えます）" >&2
    echo "         検査対象は sandbox の適用可否だけです（認証・残高は probe しません）。" >&2
    return 0
  fi
  echo "         この実行から外すなら 2 択です:" >&2
  echo "           今回だけ: 走らせたい CLI を --cli で明示するか、外す方を --exclude-cli ${cli} で名指しする" >&2
  echo "                     （どちらもその 1 回の引数。次回省けば同じ警告が出ます）" >&2
  echo "           恒久:     この機械で毎回同じなら、上の Config: に表示された設定ファイル" >&2
  echo "                     （通常はプロジェクトの .claude/agent-config.yaml。plugin default と出ているなら" >&2
  echo "                     同梱の agent-config.yaml は写さず、次の 1 行だけでそこに新しく作る。読み取りに yq が必要）に" >&2
  echo "                     次の 1 行を置く（以後の実行すべてから外れる。--cli ${cli} で 1 回だけ戻せる）:" >&2
  echo "                       exclude_clis: \"${cli}\"" >&2
  echo "                     既に exclude_clis があるならキーを増やさず、同じ 1 文字列へ空白区切りで足す" >&2
  echo "                     （例: exclude_clis: \"codex-cli ${cli}\"）。リポジトリへ commit すると" >&2
  echo "                     プロジェクト全員に効くので、この機械だけなら MULTI_AGENT_CONFIG で別ファイルを指す。" >&2
  echo "         検査対象は sandbox の適用可否だけです（認証・残高は probe しません）。" >&2
  return 0
}

show_plan() {
  local effort_cli
  while IFS= read -r effort_cli; do
    [[ -n "$effort_cli" ]] || continue
    validate_effort_env "$effort_cli" || return 1
  done < <(printf '%s\n' "$EXECUTION_PLAN" | cut -d: -f1 | sort -u)
  local emoji
  emoji="$(get_task_emoji "$TASK_TYPE")"

  echo "" >&2
  echo "📋 Execution Plan:" >&2
  echo "   Task: ${TASK_TYPE} ${emoji}" >&2
  echo "   Mode: ${MODE}" >&2
  echo "   Strategy: ${STRATEGY}" >&2
  echo "   Parallel: ${PARALLEL}" >&2
  echo "   Output: ${OUTPUT_DIR}" >&2
  if [[ "$STAGED_DIFF" == "true" ]]; then
    echo "   Diff source: staged index (git diff --cached)" >&2
  else
    echo "   Base branch: ${BASE_BRANCH} (${BASE_BRANCH_SOURCE})" >&2
  fi
  echo "   Config: ${CONFIG_FILE} (${CONFIG_SOURCE})" >&2
  # 除外はプラン本体にも 1 行出す。検出ブロックの ⏭ 行は CLI 検出の文脈にあり、
  # あとから成果物と一緒に読み返されるのはこちらのヘッダー（Mode / Strategy と
  # 同じ段）。出所（引数由来 / 設定由来）まで書かないと「設定に書いた覚えのない
  # CLI が消えている」を追えない。
  # 名簿の生値ではなく**実際に効いた除外**を出す。--cli が設定の除外を上書きした
  # CLI を「除外した」と書くと、走った CLI が除外済みに見える（実測でそうなった）。
  local excl_cli excl_by_flag="" excl_by_config=""
  for excl_cli in $ALL_CLIS; do
    case "$(cli_exclusion_source "$excl_cli")" in
      flag)   excl_by_flag="${excl_by_flag:+$excl_by_flag }$excl_cli" ;;
      config) excl_by_config="${excl_by_config:+$excl_by_config }$excl_cli" ;;
    esac
  done
  if [[ -n "$excl_by_flag" ]]; then
    echo "   Excluded CLIs: ${excl_by_flag} (--exclude-cli)" >&2
  fi
  if [[ -n "$excl_by_config" ]]; then
    echo "   Excluded CLIs: ${excl_by_config} (config exclude_clis — ${EXCLUDE_CLIS_CONFIG_SOURCE})" >&2
  fi
  echo "   Timeout: ${TIMEOUT}s per CLI" >&2
  echo "   Resume: ${RESUME}" >&2
  echo "   Runtime fallback: none — a CLI that fails or times out is reported as" >&2
  echo "                     failed, never retried on another model (see --help)" >&2
  if [[ -n "$DESCRIPTION" ]]; then
    echo "   Description: ${DESCRIPTION}" >&2
  fi
  echo "" >&2

  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "   ⚠️  No CLIs/perspectives to execute." >&2
    return
  fi

  local current_cli=""
  local planned_clis=""
  local planned_cli_count=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local cli="${entry%%:*}"
    local persp="${entry#*:}"
    if ! list_contains "$planned_clis" "$cli"; then
      planned_clis="${planned_clis:+$planned_clis }$cli"
      planned_cli_count=$((planned_cli_count + 1))
    fi
    if [[ "$cli" != "$current_cli" ]]; then
      # 直前の CLI の項目を閉じる位置で、その CLI 宛の sandbox 警告を出す。
      if [[ -n "$current_cli" ]]; then
        warn_unappliable_sandbox "$current_cli"
      fi
      current_cli="$cli"
      local tier
      tier="$(get_cli_cost_tier "$cli")"
      echo "   ${cli} [${tier}]:" >&2
      if task_is_delegated "$cli"; then
        echo "     🤝 delegated to the host — no CLI is started; prompts are handed back and" >&2
        echo "        this run reports these perspectives as pending (exit 3) until the host" >&2
        echo "        writes each result and the same command is re-run" >&2
      fi
      echo_effort_setting "$cli"
    fi
    echo "     - ${persp}" >&2
  done <<< "$EXECUTION_PLAN"
  if [[ -n "$current_cli" ]]; then
    warn_unappliable_sandbox "$current_cli"
  fi

  # 同一 CLI への観点集中の可視化（Issue `#251`）。minimize_cost の振替で、振替先の
  # CLI（cursor → gemini [free-tier] → issue `#783` 以降は grok [flat-rate]）に複数
  # 観点が集まる形が典型。実行側は同一 CLI 内を逐次化済みだが、逐次でも連続
  # リクエストで throttle されうるため、プランの時点でリスクを名指しする（実行時
  # fallback は無い = throttle された観点のカバレッジはゼロになる、という帰結まで
  # 書く）。対象 tier は minimize_cost の振替先（flat-rate）。
  # --sequential でも残存リスク（連続リクエストの throttle）は同じなので、警告は
  # 実行モードに関係なく出し、実行形の説明だけ切り替える。
  local warn_cli warn_count warn_tier warn_shape
  if [[ "$PARALLEL" == "true" ]]; then
    warn_shape="Its tasks are serialized (no burst)"
  else
    warn_shape="The run is already sequential"
  fi
  for warn_cli in $planned_clis; do
    warn_count="$(printf '%s\n' "$EXECUTION_PLAN" | LC_ALL=C sort -u | grep -c "^${warn_cli}:")" || warn_count=0
    warn_tier="$(get_cli_cost_tier "$warn_cli")"
    # 逐次化と対の警告なので発火条件も揃える: minimize_cost の振替で集中した場合
    # だけ。balanced では grok が自前の 2 観点を持つのが常態で、そこへ毎回警告を
    # 出すと「balanced へ分散せよ」という対処文が自己矛盾する（レビュー指摘）。
    if [[ "$STRATEGY" == "minimize_cost" && "$warn_count" -ge 2 && "$warn_tier" == "flat-rate" ]]; then
      echo "" >&2
      echo "   ⚠️  ${warn_cli} [${warn_tier}] runs ${warn_count} perspectives. ${warn_shape}," >&2
      echo "       but consecutive requests can still hit the provider rate limit — and there" >&2
      echo "       is no runtime fallback, so a throttled perspective yields zero coverage." >&2
      echo "       Serialization also means this CLI can take up to ${warn_count} × ${TIMEOUT}s" >&2
      echo "       wall-clock in the worst case. Consider spreading perspectives across CLIs" >&2
      echo "       (--strategy balanced)." >&2
    fi
  done

  # An explicit --cli is intentionally single-model and should stay quiet.
  # Cross-model mode is already the remedy, so this warning only applies when a
  # review resolved *implicitly* to one CLI.
  #
  # pair モードも対象に含める（Issue `#597`）。`#183` でこの警告を入れた時点では
  # review の既定が distributed だったが、`#255` で pair が既定になり、いちばん
  # 踏みやすい構成でだけ警告が出ない状態になっていた。ただし pair は「プランの
  # CLI が 1 つ」だけでは判定できない — --perspective comprehensive-review は
  # 副だけの単一 CLI プランになるが、それは要求どおりで警告は雑音になる。
  # 「副を立てられたのに落ちた」= PAIR_SUB_DROPPED を条件にする。
  #
  # 非対称なのは承知のうえ: distributed 側は利用者の意図を見ずに、--exclude-perspective
  # で 1 CLI へ絞った場合でも警告する。あちらは観点と CLI の対応がレジストリ次第で、
  # 「1 つに絞った」のか「絞った結果たまたま 1 つになった」のかを区別できないため。
  # pair は副の担当が comprehensive-review 固定なので、その区別がつく。
  #
  # cross-model も対象に含める（本 Issue）。このモードは「同じ観点を複数モデルに
  # 見せる」ことだけが存在理由なので、除外の結果 1 本になった回はクロスモデルが
  # 成立していない — --mode の表示だけが残ると、単一モデルの結果をクロスモデル済みと
  # 誤読する（pair の PAIR_REVIEWERS_NOTE と同じ失敗の形）。発火条件は
  # 「除外があった」ことに限る: 除外なしで 1 本なら CLI が 1 つしか入っていない環境で、
  # そこへ毎回出しても打てる手が無い（インストール以外に無く、検出一覧が既に言っている）。
  # 明示 `--cli` は意図的な単一モデルなので黙る（隣の単一 CLI ゲートと
  # 同じ条件）。--cli で 1 本に絞った回にまで「クロスモデルではない」と言うのは、
  # 利用者が自分で書いたことを読み上げているだけで、打てる手も無い。
  if [[ "$MODE" == "cross-model" && "$planned_cli_count" -eq 1 && -z "$CLI_FILTER" ]] \
     && [[ -n "$excl_by_flag" || -n "$excl_by_config" ]]; then
    echo "" >&2
    echo "   ⚠️  Cross-model plan resolved to a single CLI (${planned_clis}) after exclusion —" >&2
    echo "       this run is NOT cross-model. A failure or timeout here means zero coverage;" >&2
    echo "       runtime fallback is deliberately absent." >&2
    [[ -n "$excl_by_flag" ]] && echo "       Excluded by --exclude-cli: ${excl_by_flag}" >&2
    [[ -n "$excl_by_config" ]] && echo "       Excluded by config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}): ${excl_by_config}" >&2
    echo "       Drop an exclusion, or install another CLI, to compare models." >&2
  fi

  # 分散モードで「入っている CLI が 1 本だけ、除外が導入済み CLI を落としていない」回は
  # 情報行に落とす
  # （単一 CLI 基準線への整合）。この形は単一 CLI 利用者が --set-reviewers 無しで毎回通る既定経路で、
  # 基準線が主担当 1 モデルになった今（ADR-053 決定 1。決定 6 の据え置きは本変更で改訂）は正常。「ゼロカバレッジ」と警告し
  # --mode cross-model を勧めても、比べる相手が入っていないので打てる手が無い（cross-model
  # ゲートが「除外なしで 1 本なら黙る」のと同じ理由）。除外で 1 本になった回・--perspective
  # で副が落ちた pair の回は、クロスモデルにできたのに単一になった経路なので警告のまま。
  # 本数は除外適用後の AVAILABLE_CLIS で数える（除外は検出の段で落ちている。委譲レーンも
  # ここに入るので「導入済み」ではなく「利用可能」の本数）。除外の判定は excl_by_* ではなく
  # EXCLUDED_INSTALLED_CLIS — excl_by_* は未導入 CLI の除外も含み、それは何も落としていない。
  local available_cli_count
  available_cli_count="$(wc -w <<<"$AVAILABLE_CLIS" | tr -d '[:space:]')"
  if [[ "$TASK_TYPE" == "review" && -z "$CLI_FILTER" && "$planned_cli_count" -eq 1 ]] \
     && [[ "$MODE" == "distributed" && "$available_cli_count" -eq 1 ]] \
     && [[ -z "$EXCLUDED_INSTALLED_CLIS" ]]; then
    echo "" >&2
    # 「installed」とは言わない — --delegate-to-host で委譲した CLI は PATH に無くても
    # AVAILABLE_CLIS に入る（委譲レーンは CLI を起動しない）。数えているのは実行可能または
    # 委譲された本数なので、文言もそれに合わせる。
    echo "   ℹ️  Plan runs on a single CLI (${planned_clis}) — no other AI CLI is available (installed or delegated to the host)." >&2
    echo "       A single-reviewer run is the baseline; install another CLI to add a cross-model review." >&2
  elif [[ "$TASK_TYPE" == "review" && -z "$CLI_FILTER" && "$planned_cli_count" -eq 1 ]] \
     && { [[ "$MODE" == "distributed" ]] \
          || [[ "$MODE" == "pair" && "$PAIR_SUB_DROPPED" == "true" ]]; }; then
    echo "" >&2
    echo "   ⚠️  Plan resolved to a single CLI (${planned_clis}). A failure or timeout here" >&2
    echo "       means zero review coverage — runtime fallback is deliberately absent." >&2
    if [[ "$PERSPECTIVE_FILTER" == *" "* ]]; then
      echo "       For cross-model coverage, run each perspective separately:" >&2
      local requested_perspective
      for requested_perspective in $PERSPECTIVE_FILTER; do
        echo "         --mode cross-model --perspective ${requested_perspective}" >&2
      done
    else
      echo "       For cross-model coverage: --mode cross-model --perspective ${PERSPECTIVE_FILTER:-code-review}" >&2
    fi
  fi
  echo "" >&2
}

# ── Resolve perspective file path (task-type aware) ──
resolve_perspective_file() {
  local perspective="$1"

  # Try task-type subdirectory first
  local subdir_file="${SCRIPT_DIR}/perspectives/${TASK_TYPE}/${perspective}.md"
  if [[ -f "$subdir_file" ]]; then
    echo "$subdir_file"
    return
  fi

  # Fall back to root perspectives (backward compat)
  local root_file="${SCRIPT_DIR}/perspectives/${perspective}.md"
  if [[ -f "$root_file" ]]; then
    echo "$root_file"
    return
  fi

  echo ""
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-plan.sh"
