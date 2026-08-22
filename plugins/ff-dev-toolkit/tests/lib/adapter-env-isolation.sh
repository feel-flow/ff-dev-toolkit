#!/usr/bin/env bash
#
# 実行環境の MULTI_AGENT_* からのテスト分離（Issue #374 / #378）。
#
# MULTI_AGENT_MODEL_* / MULTI_AGENT_CODEX_PROFILE などは利用者が設定する正規の
# 設定つまみなので、export 済みの環境で suite を走らせると「env 未設定」前提の
# アサーションが崩れて恒常赤になる。orchestrator / アダプタの起動時に env -u で
# 明示的に取り除き、前提を仮定するのではなく作る（初出は adapter-model-args、
# PR #379）。
#
# 公開関数:
#   build_isolate_env "SENTINEL..." FILE...
#     FILE... から _?(MULTI_AGENT|FF_TIMEOUT)_[A-Z0-9_]+ を動的抽出し、グローバル配列
#     ISOLATE_ENV に env(1) 用の「-u VAR」列を組み立てる。第 1 引数は空白区切りの
#     センチネル列（後述）。
#   run_isolated [NAME=VALUE ...] COMMAND...
#     ISOLATE_ENV の除去を適用してコマンドを起動する。env は -u の除去を先に、
#     NAME=VALUE の代入を後に適用するため、ケース固有の env 上書きはそのまま効く。
#   unset_isolated_vars
#     **現在のシェル**で同じ変数を unset する。suite が `( source ... ; f )` の形で
#     関数を直接呼ぶ経路は env -u が構造的に届かないため、この入口で落とす。
#     抽出結果（ISOLATE_ENV）を再利用するので、名簿は 1 つのまま。
#
#     **呼ぶ場所は「suite の先頭で 1 回」。** subshell の内側で呼んではいけない。
#     内側から見ると、ホスト由来の値と `VAR=v f ...` というケース固有の前置代入は
#     区別がつかず、後者まで消える。そうなるとテストシームが既定値へ戻り、
#     **シーム自体が壊れても検査が通る**（実測: FF_TIMEOUT_KILL_GRACE=2 を渡した
#     ケースが既定 10 秒で走り、経過が 4 行 → 12 行へ伸びたまま pass した）。
#     先頭で 1 回落としておけば前置代入は代入として subshell へ届くので、
#     run_isolated と同じ意味論（ホストの値は除く / ケース固有の上書きは通す）になる。
#
# 保証の境界（ここに書いていない保護は無い）:
#   - **プレフィックスを持たないが呼び出し口で落としているものがある。** build_prompt を
#     サブシェルで直呼びする suite（adapter-prompt-guard / review-diff-scope）は
#     DIFF_FILE / STAGED_DIFF / INCLUDE_DIFF / CHANGED_FILES を各自の gen_prompt で unset
#     する。本 lib はそれらに関与しないので、両 suite の名簿がずれても本 lib は何も言わない。
#   - 対象は MULTI_AGENT_* と FF_TIMEOUT_* の 2 プレフィックスで、**先頭の
#     アンダースコア 1 つを含む形**（_FF_TIMEOUT_* / _MULTI_AGENT_*）まで。後者は
#     adapter-common.sh の Test seam（FF_TIMEOUT_KILL_GRACE / FF_TIMEOUT_REASON_FILE /
#     _FF_TIMEOUT_REASON_EXIT_TRAP）で、ホストが export していると timeout 判定が
#     反転する（実測: FF_TIMEOUT_KILL_GRACE=1 で multi-agent-timeout が rc=1）。Issue #381。
#
#     先頭アンダースコアを取りこぼさないこと。grep -o は左に語境界を持たないので、
#     `_?` を付けないと `_FF_TIMEOUT_REASON_EXIT_TRAP` から **実在しない**
#     `FF_TIMEOUT_REASON_EXIT_TRAP` を切り出し、名簿には載るのに実体は素通りする。
#     この取りこぼしはセンチネル検査にも掛からない（載っている名前は存在するため）。
#     実測: `_FF_TIMEOUT_REASON_EXIT_TRAP=1` を export すると、アダプタが
#     clear_timeout_reason の EXIT トラップを張らず、suite が「成功パスで reason
#     ファイルが残留（#266 の退行）」として赤くなる — env 汚染が製品退行として
#     誤報告される、本ライブラリが潰そうとしている形そのもの。
#   - **保護されるのは「渡した FILE... の中に現れる名前」だけ。** プレフィックスに
#     合致しても、抽出源に出てこない変数は名簿に載らない。呼び出し側が
#     orchestrator しか渡していなければ FF_TIMEOUT_* の分離は**空振りする**
#     （実測: multi-agent.sh に FF_TIMEOUT の出現は 0 件。したがって
#     `build_isolate_env "MULTI_AGENT_CONFIG" "$MULTI_AGENT"` だけを呼ぶ suite は
#     MULTI_AGENT_* しか分離していない）。名簿は suite ごとに非対称であり、
#     アダプタを起動する suite は抽出源にアダプタ実装も渡すこと。
#   - **FF_ 全体は対象にしない。** FF_RUN_ALL_NESTED（入れ子ガード）・
#     FF_DEV_TOOLKIT_ROOT（シムの探索先）・FF_REACHED_END（途中死センチネル）など、
#     取り除くと suite 自身の前提が壊れる変数が同じプレフィックスに同居している。
#     広げるときは「取り除いて安全か」を変数ごとに確かめること。
#   - **プレフィックスを持たない実行環境つまみは対象外。** REVIEW_TIMEOUT
#     （adapter-common.sh の `TIMEOUT="${REVIEW_TIMEOUT:-900}"`）は現存し、
#     依然として分離されていない。この節は「守られていないもの」を数える場所でも
#     あるので、対象外を消さないこと。
#   - run_isolated はサブプロセス起動にしか効かない。suite がプロセス内で
#     source して関数を直接呼ぶ経路には届かない（構造的に env -u が届かない）。
#     呼び出し側がその経路を持つなら unset_isolated_vars を使う。置く場所は
#     **suite の先頭で 1 回**であって「source の直前」ではない — 詳細は上の
#     unset_isolated_vars の項を参照。
#
# 設計メモ（PR #379 のレビュー済み設計を踏襲）:
#   - 一覧は実装から動的に抽出する — 変数が増えてもここが黙って漏れない。この
#     保証は実装が変数名をリテラルで書いている限りにおいて成立する（間接展開で
#     変数名を組むと抽出を逃れる）。コメント中の例示名も拾うが、未設定変数への
#     -u は無害なので過剰包含で安全側に倒す。
#   - grep はファイルの一部が読めなくても残りを部分出力して非 0(>1) で終わる。
#     「該当なし(rc=1)」だけを許容し、rc>=2 は分離リストの黙った欠落として
#     fail-closed で止める。
#   - 抽出後の整形は builtin のみで行い、一時ファイル・heredoc・追加プロセスを
#     使わない。bash 3.2 以前は heredoc/here-string が一時ファイルを要求するため、
#     read-only 環境で suite の skip 判定に到達する前に lib が落ちる（run-all.sh
#     の read-only friendliness 方針と同じ理由）。パイプ整形（sort 等）を挟まない
#     のも同様で、リダイレクト内のコマンド置換の失敗 rc は set -e / pipefail の
#     どちらにも伝播しない。
#   - 抽出が空振りすると分離が静かに消えて設定済み環境で恒常赤へ戻るため、
#     既知の変数名 SENTINEL の存在を fail-closed で検査する（変数名リテラルは
#     実装との突き合わせを兼ねる。実装側で改名したら呼び出し側の SENTINEL も
#     更新する）。センチネルは抽出対象のソース群ごとに 1 つずつ渡す — 複数の
#     ソースを混ぜて抽出する場合、片方のソースだけ引数から落ちても他方由来の
#     単一センチネルでは検出できない（orchestrator + アダプタを混ぜる suite は
#     orchestrator 専用変数とアダプタ変数の 2 本を渡す）。
#
# 運用注記: 本ファイルは source される前提（実行ビット不要）。呼び出し側は
# `# shellcheck source=` directive で本ファイルを指す。

build_isolate_env() {
  local sentinels="$1"; shift
  local IFS=$' \t\n'
  local raw var s seen grep_rc=0
  raw="$(grep -hoE '_?(MULTI_AGENT|FF_TIMEOUT)_[A-Z0-9_]+' "$@")" || grep_rc=$?
  if [ "$grep_rc" -gt 1 ]; then
    echo "✗ 実装からの MULTI_AGENT_* / FF_TIMEOUT_* 抽出が失敗しました（grep rc=${grep_rc}）。部分的な読み取り失敗は分離リストの黙った欠落になるため続行しない" >&2
    exit 1
  fi
  # 重複除去は builtin のみで行う（設計メモ参照）。$raw の値は抽出パターン上
  # [A-Z0-9_]+ に限られるため、無クォート展開でも語分割・glob の危険はない。
  ISOLATE_ENV=()
  seen=" "
  for var in $raw; do
    case "$seen" in *" $var "*) continue ;; esac
    seen="${seen}${var} "
    ISOLATE_ENV+=(-u "$var")
  done
  for s in $sentinels; do
    # センチネル名自体の検査: 抽出パターン外の名前（typo・glob メタ文字）は
    # 原理的に一致しえず、case パターンでの無クォート展開も安全でなくなる。
    case "$s" in
      MULTI_AGENT_*|FF_TIMEOUT_*|_MULTI_AGENT_*|_FF_TIMEOUT_*) : ;;
      *)
        echo "✗ センチネル名 '${s}' が MULTI_AGENT_* / FF_TIMEOUT_*（先頭 _ 可）の形ではありません（呼び出し側の指定ミス）" >&2
        exit 1 ;;
    esac
    case "$s" in
      *[!A-Z0-9_]*)
        echo "✗ センチネル名 '${s}' に変数名として不正な文字が含まれています（呼び出し側の指定ミス）" >&2
        exit 1 ;;
    esac
    case " ${ISOLATE_ENV[*]-} " in
      *" $s "*) : ;;
      *)
        echo "✗ 分離リストにセンチネル ${s} がありません。抽出対象のソース指定が欠けたか、抽出が空振りしたか、実装側でこの変数名が改名された（改名時は呼び出し側のセンチネル参照も更新する）。いずれでも実行環境からの分離を保証できないため続行しない" >&2
        exit 1 ;;
    esac
  done
}

# 名簿が無い状態を fail-open で通さない。`env ${ISOLATE_ENV[@]+...}` と書くと
# 未設定時に -u が 1 つも渡らず、**分離が静かに消えたまま rc=0 で成功する**（実測:
# build_isolate_env を呼ばずに run_isolated すると MULTI_AGENT_CONFIG が素通りし、
# 診断も出ない）。これは呼び出し側から build_isolate_env の 1 行を消す変異が
# クリーンな環境で生存することを意味する。unset_isolated_vars 側は同じ状態を
# fail-closed で弾いており、その非対称がちょうど検出力の穴になっていた。
#
# 空を先に弾いてから素の "${ISOLATE_ENV[@]}" を展開する。bash 3.2 は **空配列**でも
# `ISOLATE_ENV[@]: unbound variable` で落ちるため素の展開は単体では使えないが、
# 空を除外した後なら安全（実測）。
run_isolated() {
  if [ -z "${ISOLATE_ENV[*]+x}" ]; then
    echo "✗ run_isolated: 分離リストが空です（build_isolate_env を呼んでいない、または抽出結果が空）" >&2
    exit 1
  fi
  env "${ISOLATE_ENV[@]}" "$@"
}

# env -u が届かない経路（プロセス内 source）向け。ISOLATE_ENV は `-u NAME` の並びなので
# `-u` を読み飛ばして名前だけ unset する。build_isolate_env より前に呼ぶと何も外れない
# ので、抽出が済んでいない状態を fail-closed で弾く。
#
# 空判定に `${#ISOLATE_ENV[@]-0}` を使わないこと。bash 3.2（macOS の /bin/bash、この
# suite の実行シェル）では **未設定の配列**に対して `set -u` が先に発火し、意図した
# 診断ではなく `ISOLATE_ENV: unbound variable` で落ちる（実測）。rc は 1 なので
# fail-closed 自体は保たれるが、呼び出し順序の誤りという原因が操作者に届かない。
# `${ISOLATE_ENV[*]+x}` は未設定・空・有値の 3 状態すべてで set -u 安全（実測）。
unset_isolated_vars() {
  if [ -z "${ISOLATE_ENV[*]+x}" ]; then
    echo "✗ unset_isolated_vars: 分離リストが空です（build_isolate_env を呼んでいない、または抽出結果が空）" >&2
    exit 1
  fi
  local i=0
  while [ "$i" -lt "${#ISOLATE_ENV[@]}" ]; do
    if [ "${ISOLATE_ENV[$i]}" = "-u" ]; then
      i=$((i + 1))
      unset "${ISOLATE_ENV[$i]}"
    fi
    i=$((i + 1))
  done
}
