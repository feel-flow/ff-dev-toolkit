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
#     FILE... から MULTI_AGENT_[A-Z0-9_]+ を動的抽出し、グローバル配列
#     ISOLATE_ENV に env(1) 用の「-u VAR」列を組み立てる。第 1 引数は空白区切りの
#     センチネル列（後述）。
#   run_isolated [NAME=VALUE ...] COMMAND...
#     ISOLATE_ENV の除去を適用してコマンドを起動する。env は -u の除去を先に、
#     NAME=VALUE の代入を後に適用するため、ケース固有の env 上書きはそのまま効く。
#
# 保証の境界（ここに書いていない保護は無い）:
#   - 対象は MULTI_AGENT_* プレフィックスのみ。同じクラスの別プレフィックス
#     （FF_TIMEOUT_* などの Test seam や REVIEW_TIMEOUT）は対象外（Issue #381）。
#   - run_isolated はサブプロセス起動にしか効かない。suite がプロセス内で
#     source して関数を直接呼ぶ経路には届かない。
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
  raw="$(grep -hoE 'MULTI_AGENT_[A-Z0-9_]+' "$@")" || grep_rc=$?
  if [ "$grep_rc" -gt 1 ]; then
    echo "✗ 実装からの MULTI_AGENT_* 抽出が失敗しました（grep rc=${grep_rc}）。部分的な読み取り失敗は分離リストの黙った欠落になるため続行しない" >&2
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
      MULTI_AGENT_*) : ;;
      *)
        echo "✗ センチネル名 '${s}' が MULTI_AGENT_* の形ではありません（呼び出し側の指定ミス）" >&2
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

run_isolated() {
  env ${ISOLATE_ENV[@]+"${ISOLATE_ENV[@]}"} "$@"
}
