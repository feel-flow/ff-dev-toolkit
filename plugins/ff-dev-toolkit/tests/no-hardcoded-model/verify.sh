#!/usr/bin/env bash
#
# ラッパースクリプトが「具体的なモデル slug」を持ち込んでいないことの横断検査（Issue #239）。
#
# 不変条件:
#   ラッパーが持ってよいモデル値は「ベンダー中立で世代交代しない語」だけ（現状は
#   `auto` のみ）。具体的なモデル slug は既定値としてもフォールバックとしても持たず、
#   未指定ならフラグ自体を渡さない。
#
# 理由: ラッパーがモデル slug の既定値を持つと、その値の SSOT がユーザーの CLI 設定
# （~/.codex/config.toml 等）とラッパーの 2 箇所に分裂し、ラッパー側が必ず古くなる。
# しかもフラグを無条件に渡す実装だとユーザー設定を黙って上書きするうえ、同じ設定
# ファイル内の関連項目（reasoning effort など）は上書きされないため「古いモデル +
# 新しい付随設定」という誰も意図していない組み合わせで動く。実害の記録は
# 実害の記録は ACE-70-2（本リポジトリの ACE Playbook）を参照。
#
# 検査は 3 本立て:
#   1. モデル slug の denylist + `--model` へのベタ書きリテラル — 配布される全
#      シェルスクリプト（scripts/**/*.sh, hooks/**/*.sh, docs-template/**/*.sh）が
#      対象。docs-template を含めるのは、そこが他リポジトリへコピーされて腐敗の
#      種になる場所だから。denylist は既知の命名だけを見る「保険」で、命名体系に
#      依存しない本命はリテラル検査のほう。
#   2. アダプタの配線検査 — scripts/adapters/*-adapter.sh が reset_model_args /
#      add_model_arg を呼び、bash 3.2 で空配列でも落ちない展開形を使い、かつ
#      add_model_arg を経由しないモデルフラグの直書きが無いこと。行継続（`\`）で
#      逃がせないよう論理行に結合してから検査する。
#   3. ヘルパー定義の検査 — adapters/adapter-common.sh の add_model_arg 定義が
#      既定値を持たないこと。定義側に既定値が入ると呼び出し側は無傷のまま全
#      アダプタが一斉に固定モデルを持つので、呼び出し側とは別に見張る。
#
# 検査範囲の分担:
#   - .md は対象外。ACE Playbook（ACE-70-2）や
#     PLAYBOOK は事例として実在の slug を正当に引用しており、含めると初日から赤くなる
#   - tests/ 配下（本 suite の fixture を含む）も対象外。fixture は意図的に slug を持つ
#
# 既知の限界（保守側に倒す・変更時はこの一覧と fixture を更新すること）:
#   - denylist は既知のベンダー命名規則のみを見る。新しい命名体系のモデルが出たら
#     パターンの追加が要る。ただし `--model <literal>` の形はリテラル検査が命名に
#     依存せず捕まえるので、素通りするのは「変数名や文字列にだけ slug が現れる」形
#   - CLI 識別子がベンダー slug と語幹を共有する場合、識別子を退避してから走査する
#     （現状 `grok-cli`）。退避は二段で、識別子に数字が続く形（`grok-cli-4`）は
#     ベンダー slug の形へ畳んでから残りを退避するので検出力は落ちない。ただし
#     **将来 CLI を足すたびにこの退避リストの更新が要る**。退避漏れは誤検出（赤）
#     として現れるので静かには壊れないが、退避しすぎると穴になる。追加時は
#     violation fixture に「識別子を接頭辞に持つ実 slug」のケースも足すこと
#   - `-m <literal>` のリテラル検査はアダプタ限定。広域では `git commit -m` と
#     区別できないため（アダプタには git 呼び出しが無いことを前提にしている）
#   - コメント行の slug も検出する（誤検出側）。禁止例を .sh に書く必要が出たら
#     fixture 側に置くこと。ただし配線検査はコメント行を無視する（説明文に関数名が
#     出ても検出結果を動かさない）
#   - 配線検査は「3 要素がファイル内に在ること」を見るので、順序の入れ替え（reset を
#     add の後に置くなど）は検出しない。実 argv の検証は tests/adapter-model-args/
#     が stub CLI で担当する
#
# 検出力は fixtures/ の変異 fixture で毎回実測する（違反 fixture が期待どおり赤く
# ならなければ、横断検査へ進まず fail-closed で落とす）。
#
# 一時ディレクトリも jq / yq などの追加ツールも要らない（find / awk / sed のみ）純粋な
# ファイル検査なので、書き込み不可の環境でも完走する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 2 レイアウト対応: SSOT モノレポでは plugins/ff-dev-toolkit、公開 checkout では
# リポジトリ root がそのまま PLUGIN_ROOT になる（どちらも tests/<suite>/ の 2 つ上）。
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 空配列でも set -u 下で落ちない安全な展開形。bash 3.2（macOS 既定）では
# "${arr[@]}" が空配列のとき unbound variable になるため、この形を必須にする。
SAFE_EXPANSION='${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}'
# 長さの取得は空配列でも安全なので、展開形の検査では違反にしない。
LEN_EXPANSION='${#MODEL_ARGS[@]}'

# ---- スキャナ 1: モデル slug の denylist + リテラル --model ---------------------
# 出力は「行番号:行」。ヒットが無ければ何も出力しない。
#
# 境界に `-` を含めない（[^A-Za-z0-9_]）のは、`${VAR:-gpt-5.5}` のようにハイフン
# 直後へ slug が来る既定値パターンを取り逃さないため。逆に語の途中で vendor 名が
# 始まる識別子（preclaude-opus-helper）は英数字が前にあるので一致しない。
scan_model_slugs() {
  awk '
    # `--model <リテラル>` の直書きを命名に依存せず検出する。変数展開（$VAR /
    # "${VAR}"）は既定値を持たないので違反ではない。add_model_arg 経由の呼び出しも
    # 対象外（第3引数の妥当性は配線検査が別に見る）。
    # 散文（コメント行）で禁止例に言及するのは違反ではないので除外する — slug を
    # 含むコメントは上の denylist が別途拾うので、抜け道にはならない。
    function literal_model_flag(s,   t, rest, op) {
      t = s
      sub(/^[[:space:]]+/, "", t)
      if (t ~ /^#/) return 0
      if (t ~ /^add_model_arg([[:space:]]|$)/) return 0
      # フラグの書き方の揺れを 1 つの形へ寄せてから値を見る。`--model=値` は
      # 空白が続かないので素の照合では素通りし、`"--model"` のようにフラグ側を
      # クォートした形も一致しない。
      gsub(/["\047]--model["\047]/, "--model", t)
      gsub(/--model=/, "--model ", t)
      if (!match(t, /(^|[[:space:]])--model[[:space:]]+/)) return 0
      rest = substr(t, RSTART + RLENGTH)
      if (rest == "") return 0
      op = substr(rest, 1, 1)
      if (op == "$") return 0
      if (op == "\"" && substr(rest, 2, 1) == "$") return 0
      return 1
    }
    # CLI 識別子とモデル slug が同じ語幹を持つ場合の退避。`grok-cli` は
    # ALL_CLIS のメンバー名（かつコマンド名）であってモデル名ではないが、
    # ベンダー slug の検査 `(grok|...)[-0-9]` は `grok-cli` にも一致してしまう。
    # ここで先に潰しておかないと、CLI を追加した瞬間にファイル名・コメント・
    # インストール URL のすべてが「モデル slug 直書き」として誤検出される。
    # `[-0-9]` を `-?[0-9]` へ緩めて回避しない — それでは `deepseek-v3` 形式の
    # 実在の slug を取り逃す。
    #
    # 退避は二段。無条件に潰すと `grok-cli-4` のような「識別子を接頭辞に持つ実 slug」
    # まで不可視になり、退避が抜け道になる。数字が続く形を先にベンダー slug の形へ
    # 畳んでから、残りの識別子だけを退避する。
    { gsub(/grok-cli-[0-9]/, "grok-0"); gsub(/grok-cli/, "GROKCLIIDENT") }
    /(^|[^A-Za-z0-9_])gpt-?[0-9]/                                   { print FNR ":" $0; next }
    /(^|[^A-Za-z0-9_])claude-(opus|sonnet|haiku|fable|[0-9])/       { print FNR ":" $0; next }
    /(^|[^A-Za-z0-9_])gemini-[0-9]/                                 { print FNR ":" $0; next }
    /(^|[^A-Za-z0-9_])sonnet-[0-9]/                                 { print FNR ":" $0; next }
    /(^|[^A-Za-z0-9_])(grok|llama|mistral|deepseek|qwen|composer)[-0-9]/ { print FNR ":" $0; next }
    /(^|[^A-Za-z0-9_])o[0-9]-(mini|preview|pro)/                    { print FNR ":" $0; next }
    /[0-9]-(sol|luna|terra)([^A-Za-z0-9_]|$)/                       { print FNR ":" $0; next }
    literal_model_flag($0)                                          { print FNR ":" $0; next }
  ' "$1"
}

# ---- スキャナ 2: アダプタの配線検査 --------------------------------------------
# 出力は違反コード（1 行 1 件）。違反が無ければ何も出力しない。
#   NO_RESET / NO_ADD / NO_SAFE_EXPANSION / UNSAFE_EXPANSION:<行> /
#   BAD_DEFAULT_LITERAL:<行> / LITERAL_MODEL_FLAG:<行>
#
# 行継続（`\`）で次行へ逃がした引数を取り逃さないよう、論理行へ結合してから
# 検査する（tests/skill-bash-blocks/verify.sh と同じ扱い）。行番号は論理行の
# 開始行を報告する。
scan_adapter_wiring() {
  awk -v safe="$SAFE_EXPANSION" -v lenexp="$LEN_EXPANSION" '
    function count_lit(s, lit,   n, p) {
      n = 0
      while ((p = index(s, lit)) > 0) { n++; s = substr(s, p + length(lit)) }
      return n
    }
    # `-m <リテラル>` の直書き。広域では git commit -m と区別できないので
    # アダプタ限定でこちらに置く。--model 側はスキャナ 1 が命名非依存で見る。
    function literal_m_flag(s,   t, rest, op) {
      t = s
      sub(/^[[:space:]]+/, "", t)
      if (t ~ /^add_model_arg([[:space:]]|$)/) return 0
      # `--model` 側と同じくフラグの書き方の揺れを寄せる（scan_model_slugs の
      # literal_model_flag と対になる処理）。
      gsub(/["\047]-m["\047]/, "-m", t)
      gsub(/-m=/, "-m ", t)
      if (!match(t, /(^|[[:space:]])-m[[:space:]]+/)) return 0
      rest = substr(t, RSTART + RLENGTH)
      if (rest == "") return 0
      op = substr(rest, 1, 1)
      if (op == "$") return 0
      if (op == "\"" && substr(rest, 2, 1) == "$") return 0
      return 1
    }
    # 関数名が「実際に呼ばれている」位置にあるかを見る。行内のどこかに現れるだけで
    # 立ててしまうと、文字列リテラル（エラーメッセージ等）に名前を書いただけで検査を
    # 満たせてしまう — 実際、アダプタのエラーメッセージが add_model_arg に言及した
    # だけで NO_ADD が出なくなる回帰が起きた。
    function cmd_pos(s, name,   t) {
      t = s
      sub(/^[[:space:]]+/, "", t)
      if (t ~ ("^" name "([[:space:]]|$)")) return 1
      if (t ~ ("(\\|\\||&&|;|\\{|[[:space:]](then|do|else))[[:space:]]+" name "([[:space:]]|$)")) return 1
      return 0
    }
    function check_logical(line, start,   body, nf, f, n_safe, n_len, n_tok, dflt) {
      # コメント行は配線の実体ではないので無視する（説明文に関数名や展開形が
      # 出てきても検出結果を動かさない）
      if (line ~ /^[[:space:]]*#/) return

      if (cmd_pos(line, "reset_model_args")) has_reset = 1
      if (cmd_pos(line, "add_model_arg")) has_add = 1

      # 安全形はトークンをちょうど 2 回、長さ取得は 1 回含む。総数がその内訳と
      # 一致しない行には、空配列で落ちる展開が混ざっている。
      n_safe = count_lit(line, safe)
      n_len  = count_lit(line, lenexp)
      n_tok  = count_lit(line, "MODEL_ARGS[@]")
      if (n_safe > 0) has_safe = 1
      if (n_tok != n_safe * 2 + n_len) print "UNSAFE_EXPANSION:" start

      if (literal_m_flag(line)) print "LITERAL_MODEL_FLAG:" start

      # add_model_arg <flag> <ENV_VAR> [既定値]
      # 第 3 引数に書いてよいのはベンダー中立で世代交代しない語だけ。
      body = line
      sub(/^[[:space:]]+/, "", body)
      sub(/[[:space:]]+#.*$/, "", body)
      # 論理行に結合したあとは `|| fail_orchestrator_error ...` のような後続節が
      # 同じ行に並ぶ。フィールド分割の前に落とさないと `||` が第 3 引数に見える。
      sub(/[[:space:]]+(\|\||&&|;).*$/, "", body)
      if (body ~ /^add_model_arg[[:space:]]/) {
        nf = split(body, f, /[[:space:]]+/)
        if (nf >= 4) {
          dflt = f[4]
          gsub(/^["]|["]$/, "", dflt)
          if (dflt != "auto") print "BAD_DEFAULT_LITERAL:" start
        }
      }
    }
    {
      cur = $0
      sub(/\r$/, "", cur)
      if (cont == 0) { logical = cur; start_line = FNR } else { logical = logical " " cur }
      if (cur ~ /\\[[:space:]]*$/) {
        sub(/\\[[:space:]]*$/, " ", logical)
        cont = 1
        next
      }
      cont = 0
      check_logical(logical, start_line)
    }
    END {
      if (cont == 1) check_logical(logical, start_line)
      if (!has_reset) print "NO_RESET"
      if (!has_add) print "NO_ADD"
      if (!has_safe) print "NO_SAFE_EXPANSION"
    }
  ' "$1"
}

# ---- スキャナ 3: ヘルパー定義の既定値検査 --------------------------------------
# 出力は「HELPER_DEFAULT:<行>」。`${3:-X}` / `${!var:-X}` の X が空でなければ違反。
# 呼び出し側が第3引数を渡していなくても、定義側の既定値は全アダプタに効く。
scan_helper_default() {
  awk '
    /\$\{3:-[^}]/                                   { print "HELPER_DEFAULT:" FNR; next }
    /\$\{![A-Za-z_][A-Za-z0-9_]*:-[^}]/             { print "HELPER_DEFAULT:" FNR; next }
  ' "$1"
}

echo "== ラッパーのモデル slug 固定検査 =="

# ---- 自己検証（変異試験の恒久化） ----------------------------------------------
# 違反 fixture が期待どおり赤くならない = 検出器が壊れている。その状態で
# 「違反ゼロ」という負の主張を通さないため、横断検査より先に検出力を実測する。
for f in violation.sh clean.sh adapter-ok.sh adapter-violations.sh adapter-no-add.sh \
         helper-default-violation.sh helper-default-ok.sh; do
  [ -f "$FIXTURES_DIR/$f" ] || { echo "✗ fixture がありません: $FIXTURES_DIR/$f" >&2; exit 1; }
done

EXPECTED_SLUG_LINES="9 10 11 12 13 14 15 16 17 18 19 20 22 23 24 25 26 27 28 31 32 34 35 36"
actual_slug_lines="$(scan_model_slugs "$FIXTURES_DIR/violation.sh" | awk -F: '{ print $1 }' | paste -sd' ' -)" \
  || { echo "✗ 自己検証の scan パイプラインが失敗しました（violation.sh）" >&2; exit 1; }
if [ "$actual_slug_lines" = "$EXPECTED_SLUG_LINES" ]; then
  ok "違反 fixture の全 slug / リテラル直書きを期待行で検出（${EXPECTED_SLUG_LINES}）"
else
  bad "違反 fixture の検出結果が期待と不一致（expected: '${EXPECTED_SLUG_LINES}' / actual: '${actual_slug_lines}'）"
fi

clean_hits="$(scan_model_slugs "$FIXTURES_DIR/clean.sh")" \
  || { echo "✗ 自己検証の scan が失敗しました（clean.sh）" >&2; exit 1; }
if [ -z "$clean_hits" ]; then
  ok "非検出 fixture（env 指定・変数展開・auto・git commit -m・語中の vendor 名）を誤検出しない"
else
  bad "非検出 fixture を誤検出した:"
  printf '%s\n' "$clean_hits" | sed 's/^/    | /' >&2
fi

EXPECTED_WIRING_CODES="BAD_DEFAULT_LITERAL:18 BAD_DEFAULT_LITERAL:20 UNSAFE_EXPANSION:23 LITERAL_MODEL_FLAG:23 NO_RESET NO_SAFE_EXPANSION"
actual_wiring_codes="$(scan_adapter_wiring "$FIXTURES_DIR/adapter-violations.sh" | paste -sd' ' -)" \
  || { echo "✗ 自己検証の配線 scan が失敗しました（adapter-violations.sh）" >&2; exit 1; }
if [ "$actual_wiring_codes" = "$EXPECTED_WIRING_CODES" ]; then
  ok "配線違反 fixture の全違反を期待どおり検出（${EXPECTED_WIRING_CODES}）"
else
  bad "配線違反 fixture の検出結果が期待と不一致（expected: '${EXPECTED_WIRING_CODES}' / actual: '${actual_wiring_codes}'）"
fi

# NO_ADD は add_model_arg を含む fixture では発火しないので、専用 fixture で固定する。
actual_no_add="$(scan_adapter_wiring "$FIXTURES_DIR/adapter-no-add.sh" | paste -sd' ' -)" \
  || { echo "✗ 自己検証の配線 scan が失敗しました（adapter-no-add.sh）" >&2; exit 1; }
if [ "$actual_no_add" = "NO_ADD" ]; then
  ok "add_model_arg を 1 つも呼ばない fixture で NO_ADD を検出"
else
  bad "NO_ADD の検出結果が期待と不一致（expected: 'NO_ADD' / actual: '${actual_no_add}'）"
fi

ok_wiring_hits="$(scan_adapter_wiring "$FIXTURES_DIR/adapter-ok.sh")" \
  || { echo "✗ 自己検証の配線 scan が失敗しました（adapter-ok.sh）" >&2; exit 1; }
if [ -z "$ok_wiring_hits" ]; then
  ok "正しい配線の fixture（インデント・クォート付き既定値・配列長取得を含む）を誤検出しない"
else
  bad "正しい配線の fixture を誤検出した:"
  printf '%s\n' "$ok_wiring_hits" | sed 's/^/    | /' >&2
fi

EXPECTED_HELPER_CODES="HELPER_DEFAULT:15 HELPER_DEFAULT:16"
actual_helper_codes="$(scan_helper_default "$FIXTURES_DIR/helper-default-violation.sh" | paste -sd' ' -)" \
  || { echo "✗ 自己検証のヘルパー定義 scan が失敗しました（helper-default-violation.sh）" >&2; exit 1; }
if [ "$actual_helper_codes" = "$EXPECTED_HELPER_CODES" ]; then
  ok "ヘルパー定義の既定値を期待どおり検出（${EXPECTED_HELPER_CODES}）"
else
  bad "ヘルパー定義の検出結果が期待と不一致（expected: '${EXPECTED_HELPER_CODES}' / actual: '${actual_helper_codes}'）"
fi

helper_ok_hits="$(scan_helper_default "$FIXTURES_DIR/helper-default-ok.sh")" \
  || { echo "✗ 自己検証のヘルパー定義 scan が失敗しました（helper-default-ok.sh）" >&2; exit 1; }
if [ -z "$helper_ok_hits" ]; then
  ok "既定値を持たないヘルパー定義を誤検出しない"
else
  bad "既定値を持たないヘルパー定義を誤検出した:"
  printf '%s\n' "$helper_ok_hits" | sed 's/^/    | /' >&2
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ no-hardcoded-model verify: 検出器の自己検証に失敗（横断検査は実行しない）" >&2
  exit 1
fi

# ---- 横断検査 1: 配布される全シェルスクリプト -----------------------------------
# 走査の起点は先に存在を主張する。起点が 1 つ消えても残りが見つかれば find は
# 成功してしまい、「対象が静かに縮んだのに緑」という、この suite が防ぐと宣言した
# 事故そのものが起きる。起点ごとに control を足す方式では、起点を増やしたときに
# 同じ穴が再発するので、リスト自体を検証する。
SCAN_ROOTS=(
  "$PLUGIN_ROOT/scripts"
  "$PLUGIN_ROOT/hooks"
  "$PLUGIN_ROOT/docs-template"
)
for root in "${SCAN_ROOTS[@]}"; do
  if [ ! -d "$root" ]; then
    echo "✗ 検査対象ディレクトリがありません: $root" >&2
    echo "  移動・改名したなら SCAN_ROOTS を更新してください（黙って検査対象を減らさない）" >&2
    exit 1
  fi
done

SHELL_FILES=()
while IFS= read -r file; do
  SHELL_FILES+=("$file")
done < <(find "${SCAN_ROOTS[@]}" -name '*.sh' -type f | LC_ALL=C sort)

if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
  echo "✗ 検査対象の .sh が 1 件も見つかりません（対象ゼロは異常）: ${SCAN_ROOTS[*]}" >&2
  exit 1
fi

# 正の主張: 起点ごとに最低 1 件は拾えている。ディレクトリは在るのに中身が
# 空／読めない場合を検出する。
for root in "${SCAN_ROOTS[@]}"; do
  found=0
  for file in "${SHELL_FILES[@]}"; do
    case "$file" in "$root"/*) found=1; break ;; esac
  done
  if [ "$found" -eq 1 ]; then
    ok "検査対象に ${root#"$PLUGIN_ROOT"/}/ 配下の .sh を含む"
  else
    bad "${root#"$PLUGIN_ROOT"/}/ 配下の .sh が 1 件も拾えていません（走査が空振りしている可能性）"
  fi
done

slug_violation_files=0
for file in "${SHELL_FILES[@]}"; do
  hits="$(scan_model_slugs "$file")" \
    || { echo "✗ scanner 自体が失敗しました: $file" >&2; exit 1; }
  if [ -n "$hits" ]; then
    slug_violation_files=$((slug_violation_files + 1))
    bad "${file#"$PLUGIN_ROOT"/} にモデル slug の直書きがある:"
    printf '%s\n' "$hits" | sed 's/^/    | /' >&2
    echo "    既定値を持たず、env が設定されたときだけフラグを組み立ててください（ACE-70-2）" >&2
  fi
done

if [ "$slug_violation_files" -eq 0 ]; then
  ok "全 ${#SHELL_FILES[@]} 件の .sh に既知パターンのモデル slug と --model へのリテラル直書きが無い"
fi

# ---- 横断検査 2: アダプタの配線 -------------------------------------------------
# adapter-common.sh はヘルパーの**定義**なので、呼び出し側の配線検査ではなく
# 横断検査 3 が別ルールで見る（*-adapter.sh のグロブにも一致しない）。
ADAPTER_FILES=()
while IFS= read -r file; do
  ADAPTER_FILES+=("$file")
done < <(find "$PLUGIN_ROOT/scripts/adapters" -name '*-adapter.sh' -type f | LC_ALL=C sort)

# アダプタは CLI ごとに 1 本。数が減ったら検査が静かに縮むので下限を主張する。
# CLI を増減したらこの数字も更新すること。
EXPECTED_ADAPTER_COUNT=5
if [ "${#ADAPTER_FILES[@]}" -eq "$EXPECTED_ADAPTER_COUNT" ]; then
  ok "アダプタ ${EXPECTED_ADAPTER_COUNT} 本すべてを配線検査の対象にしている"
else
  bad "アダプタの本数が期待と違う（expected: ${EXPECTED_ADAPTER_COUNT} / actual: ${#ADAPTER_FILES[@]}）。CLI を増減したなら EXPECTED_ADAPTER_COUNT を更新してください"
fi

wiring_violation_files=0
for file in "${ADAPTER_FILES[@]}"; do
  codes="$(scan_adapter_wiring "$file")" \
    || { echo "✗ 配線 scanner 自体が失敗しました: $file" >&2; exit 1; }
  if [ -n "$codes" ]; then
    wiring_violation_files=$((wiring_violation_files + 1))
    bad "${file#"$PLUGIN_ROOT"/} のモデル選択の配線に違反がある:"
    printf '%s\n' "$codes" | sed 's/^/    | /' >&2
    echo "    reset_model_args → add_model_arg → ${SAFE_EXPANSION} の順で配線し、" >&2
    echo "    モデルフラグは add_model_arg 経由でのみ組み立ててください" >&2
  fi
done

if [ "$wiring_violation_files" -eq 0 ]; then
  ok "全 ${#ADAPTER_FILES[@]} 本のアダプタが add_model_arg 経由で組み立て、安全な展開形を使っている"
fi

# ---- 横断検査 3: ヘルパー定義の既定値 -------------------------------------------
HELPER_FILE="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
if [ ! -f "$HELPER_FILE" ]; then
  bad "ヘルパー定義が見つかりません: ${HELPER_FILE#"$PLUGIN_ROOT"/}（改名したなら HELPER_FILE を更新すること）"
else
  helper_codes="$(scan_helper_default "$HELPER_FILE")" \
    || { echo "✗ ヘルパー定義 scanner 自体が失敗しました: $HELPER_FILE" >&2; exit 1; }
  if [ -z "$helper_codes" ]; then
    ok "ヘルパー定義（add_model_arg）が既定値を持たない"
  else
    bad "${HELPER_FILE#"$PLUGIN_ROOT"/} のヘルパー定義が既定値を持っている:"
    printf '%s\n' "$helper_codes" | sed 's/^/    | /' >&2
    echo "    定義側の既定値は呼び出し側が無傷でも全アダプタに効きます（ACE-70-2）" >&2
  fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ no-hardcoded-model verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ no-hardcoded-model verify: 全 $PASS 件 pass"
