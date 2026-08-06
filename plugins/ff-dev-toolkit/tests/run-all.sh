#!/usr/bin/env bash
#
# ff-dev-toolkit prompt fixture regression test runner.
#
# 全 suite を必ず実行し、結果を集約して報告する（Issue #146）。最初の失敗で停止する
# fail-fast だと、1 件のゲート違反が無関係な後続 suite の検出力をまとめて 0 にする。
# 実際に PR #144 の changelog-version red が 2 日間、後続 4 suite（破壊的操作を扱う
# merge-cleanup を含む）の実行を止め、その隙間で別の回帰が隠れていた。fail-fast は
# 「red は即座に直される」前提でのみ成立し、放置された瞬間に fail-silent へ反転する。
#
# suite との契約:
#   - 成功なら exit 0、失敗なら非 0 を返す
#   - 環境の都合で**検証本体をまるごと実行できなかった**場合は exit 0 を返しつつ、
#     行頭が `○ skip` の行を出力する（read-only 環境の merge-cleanup など）。ランナーは
#     これを pass ではなく skip として数え、サマリーで名指しする。マーカー文言は
#     tests/run-all/verify.sh が実在を検査するので、変えると red になる。
#     一部の検査だけを飛ばす「部分 skip」でこのマーカーを出さないこと（1 行でも
#     あると suite 全体が skip 扱いになり、実際に走った検査が報告から消える）
#   - 終了コード: 失敗 or 未実行が 1 件でもあれば 1、それ以外は 0。ただし passed が
#     0 で skipped だけの場合も 1（検証が 1 件も成立していない状態を緑にしない）
#
# 引数に suite のパスを渡すと、既定の一覧ではなくその一覧だけを実行する。
# tests/run-all/verify.sh が疑似 suite を渡して本ランナー自身の挙動を検証するための
# 口で、自己テストは常に明示引数で呼ぶため既定の一覧に自身が居ても再帰しない。
# サマリーの suite 識別子は親ディレクトリ名なので、渡す suite は親ディレクトリ名が
# 互いに一意であること（同名だとどちらが失敗したのか報告から読めない）。
#
# 実行方式のトレードオフ: 各 suite の出力は skip マーカー判定のため command
# substitution で丸ごと受けてから出力する。そのため suite 実行中のリアルタイム進捗は
# 出ず（merge-cleanup は実 git 操作を伴うので体感差がある）、途中で kill された場合は
# 実行中 suite の出力が残らない。stdout/stderr も 1 本に合流する。skip を pass から
# 区別するために意図して受け入れているトレードオフ。
#
# Keep this read-only friendly: do not create temporary files and avoid here-doc / here-string.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 入れ子で既定 suite 一覧を走らせると、自己テスト → 本ランナー → 自己テスト … と
# 無限再帰する（merge-cleanup の一時 git リポジトリ生成まで巻き込んで暴走する）。
# 明示引数付きの入れ子だけを許し、引数なしの入れ子は fail-closed で止める。
if [[ "${FF_RUN_ALL_NESTED:-0}" != "0" && $# -eq 0 ]]; then
  echo "✗ run-all.sh を入れ子で引数なし実行しようとしました（既定 suite 一覧は無限再帰します）" >&2
  echo "  入れ子からは検証したい suite のパスを明示引数で渡してください" >&2
  exit 1
fi
export FF_RUN_ALL_NESTED=1

if [[ $# -gt 0 ]]; then
  SCRIPTS=("$@")
else
  SCRIPTS=(
    # 一時ディレクトリも外部コマンドも要らない静的検査を先に置く（安価な順。
    # 全 suite を実行するので、並び順は結果ではなく報告の読みやすさの問題）。
    "$SCRIPT_DIR/skill-frontmatter/verify.sh"
    "$SCRIPT_DIR/skill-bash-blocks/verify.sh"
    "$SCRIPT_DIR/no-hardcoded-model/verify.sh"
    "$SCRIPT_DIR/cli-registry-completeness/verify.sh"
    # agent-config.yaml が multi-agent.sh の case 文のミラーとして正しいか
    # （command / cost_tier / perspectives / fallback の値を横断照合）。
    # 上の「外部コマンド不要」の例外で、yq に依存する。読み取り専用の静的検査なので
    # 関連する cli-registry-completeness の直後に置く（yq 不在なら丸ごと ○ skip）。
    "$SCRIPT_DIR/agent-config-mirror/verify.sh"
    # 上の gate の検出力を隔離コピーへの mutation で実測する。yq / perl / mktemp -d を
    # 使い単体で〜15 秒かかる（数字を更新するときは実測してから直すこと）。検査対象の
    # 直後に置くことを優先し、安価な順の例外として扱う。
    # yq / perl 不在、または一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/agent-config-mirror-selftest/verify.sh"
    "$SCRIPT_DIR/ace-curate-commit/verify.sh"
    "$SCRIPT_DIR/ace-refine/verify.sh"
    "$SCRIPT_DIR/changelog-public-references/verify.sh"
    "$SCRIPT_DIR/changelog-version/verify.sh"
    "$SCRIPT_DIR/docs-gates/verify.sh"
    "$SCRIPT_DIR/out-of-scope-routing/verify.sh"
    "$SCRIPT_DIR/setup-ai-config/verify.sh"
    "$SCRIPT_DIR/assess-impact/verify.sh"
    "$SCRIPT_DIR/validate-docs/verify.sh"
    # docs-template の実行可能フェンスを抽出して fixture 実行する動的検査。
    # 一時作業領域を使うため静的検査の後、ネットワーク検査の前に置く。
    "$SCRIPT_DIR/docs-gates-runtime/verify.sh"
    # アダプタが CLI へ渡す argv の実測。一時ディレクトリと stub CLI を使うが
    # 実 CLI・ネットワーク・課金は伴わない（〜2 秒）。静的検査の後、ネットワーク
    # 検査の前に置く。
    "$SCRIPT_DIR/adapter-model-args/verify.sh"
    # 主+副レビュワーの解決・保存・縮退。一時ディレクトリと git リポジトリを使うが
    # 実 CLI・ネットワーク・課金は伴わない。設定の保存先は XDG_CONFIG_HOME を
    # 一時ディレクトリへ向けて隔離するので、利用者の実設定には触れない。
    "$SCRIPT_DIR/reviewer-pair/verify.sh"
    # 公開リポジトリへの実ネットワーク到達を試みる suite（接続不可のみ丸ごと
    # ○ skip、それ以外は fail）。静的検査より後、破壊的操作を伴う
    # merge-cleanup より前に置く。他の suite を network-dependent 化する場合も
    # この位置関係（静的 → ネットワーク → 破壊的操作 → 低速）を保つこと。
    "$SCRIPT_DIR/changelog-links/verify.sh"
    # changelog-links の回帰検証（ローカル bare リポジトリ fixture のみ使用、
    # 実ネットワークには触らない）。本体の直後に置く。
    "$SCRIPT_DIR/changelog-links-selftest/verify.sh"
    # 更新通知フック（hooks/check-update.sh）の回帰検証。ローカル bare リポジトリ
    # fixture のみ使用し、実ネットワークには触らない。
    "$SCRIPT_DIR/update-check/verify.sh"
    "$SCRIPT_DIR/merge-cleanup/verify.sh"
    # perspective フィルタの dry-run 契約。stub CLI の存在確認だけで完結し、
    # 実 CLI・ネットワーク・課金を伴わない。
    "$SCRIPT_DIR/multi-agent-plan/verify.sh"
    # 同梱 MCP サーバーの検査 2 本。node_modules が無い環境では ○ skip。
    # dist-gate（フレッシュビルド比較 + stdio-only 不変条件、〜1 秒）を先に、
    # vitest（実プロセス起動を含む全テスト、〜5 秒）を後に置く — dist が stale
    # なら先に dist-gate が名指しし、vitest の「stale な dist で green」を防ぐ。
    "$SCRIPT_DIR/mcp-dist-gate/verify.sh"
    "$SCRIPT_DIR/mcp-vitest/verify.sh"
    # docs-template/scripts/ace の vitest（Playbook 集計スクリプト群 + refine 候補算出）。
    # vitest 本体は mcp/node_modules を再利用するため mcp 系 suite の直後に置く。
    "$SCRIPT_DIR/ace-scripts-vitest/verify.sh"
    # 一時 git リポジトリ + stub CLI を使い、打ち切りや猶予期間の実測待ちを含むので
    # 後ろに置く（単体で〜35 秒。数字を更新するときは実測してから直すこと）
    "$SCRIPT_DIR/multi-agent-timeout/verify.sh"
    "$SCRIPT_DIR/run-all/verify.sh"
  )
fi

PASSED=()
FAILED=()
SKIPPED=()
NOT_RUN=()

for script in "${SCRIPTS[@]}"; do
  name="$(basename "$(dirname "$script")")"
  echo "== $name =="

  # 起動できない suite は「未実行」として記録し、ループは継続する（ここで exit すると
  # 裏口から fail-fast が戻る）。最後に非 0 終了へ寄与させることで fail-closed を保つ。
  if [[ ! -f "$script" ]]; then
    echo "✗ verify script is missing: $script" >&2
    NOT_RUN+=("$name (missing)")
    echo
    continue
  fi
  if [[ ! -x "$script" ]]; then
    echo "✗ verify script is not executable: $script" >&2
    NOT_RUN+=("$name (not executable)")
    echo
    continue
  fi

  # 出力を変数へ受けるのは skip マーカーを判定するため。command substitution は
  # パイプで完結し一時ファイルを作らないので read-only 環境でも動く。判定後に
  # そのまま全量を出力するので、診断情報は失敗時も成功時も欠けない。
  if output="$(bash "$script" 2>&1)"; then
    printf '%s\n' "$output"
    # 判定はシェル内の文字列マッチで行い、パイプを使わない。`printf | grep -q` だと
    # grep がマッチ時点で終了して上流の printf が SIGPIPE (141) で死に、pipefail の
    # もとでパイプライン全体が失敗扱いになる = マッチが「不一致」へ反転する。出力が
    # パイプ容量（64KB 程度）を超える suite で skip が pass に化ける fail-silent で、
    # 本 Issue が潰そうとしている masking と同じ種類の事故になる。
    # 左辺に改行を前置するのは、1 行目の `○ skip` も行頭マッチさせるため。
    if [[ $'\n'"$output" == *$'\n○ skip'* ]]; then
      SKIPPED+=("$name")
    else
      PASSED+=("$name")
    fi
  else
    printf '%s\n' "$output"
    FAILED+=("$name")
  fi
  echo
done

# ---- サマリー --------------------------------------------------------------
# 「実行した suite 数」と「失敗/スキップ/未実行の suite 名」を必ず出す。総数と
# 実行数が食い違ったまま success を名乗らないことが、本 Issue の masking 対策の本体。
RUN=$(( ${#PASSED[@]} + ${#FAILED[@]} + ${#SKIPPED[@]} ))

echo "== summary =="
echo "suites: total=${#SCRIPTS[@]} run=$RUN passed=${#PASSED[@]} failed=${#FAILED[@]} skipped=${#SKIPPED[@]} not-run=${#NOT_RUN[@]}"

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "○ skipped (環境都合で検証本体が未実行): ${SKIPPED[*]}"
fi
if [[ ${#NOT_RUN[@]} -gt 0 ]]; then
  echo "✗ not run (suite を起動できなかった): ${NOT_RUN[*]}" >&2
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "✗ failed: ${FAILED[*]}" >&2
fi

if [[ ${#FAILED[@]} -gt 0 || ${#NOT_RUN[@]} -gt 0 ]]; then
  exit 1
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  # skip だけで pass が 0 = 検証が 1 件も成立していない。文言だけ出して 0 で終わると、
  # 終了コードしか見ない CI では「全部通った」と区別が付かないので非 0 で落とす。
  if [[ ${#PASSED[@]} -eq 0 ]]; then
    echo "✗ 検証できた suite がありません（全 ${#SKIPPED[@]} suite が環境都合でスキップ）。書き込み可能な環境で再実行してください" >&2
    exit 1
  fi
  echo "実行した ${#PASSED[@]} suite は全て通過（${#SKIPPED[@]} suite は環境都合でスキップ。全 suite の検証は書き込み可能な環境で行うこと）"
  exit 0
fi

echo "All ff-dev-toolkit fixture checks passed."
exit 0
