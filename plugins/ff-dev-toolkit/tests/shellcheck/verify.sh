#!/usr/bin/env bash
#
# tests/shellcheck: tracked shell スクリプトの静的検査ゲート（Issue #530）。
#
# 注意: 行頭を `# shellcheck …` で始めないこと。散文のつもりでもディレクティブとして
# 解釈され、このファイルの静的検査が丸ごと止まる（本 suite が自分自身で実測した）。
#
# 背景: 本リポジトリの成果物は大半が bash（tests/*/verify.sh・scripts/・hooks/）だが、
# 静的検査を起動するゲートも hook も CI も無かった。そのため**抑制ディレクティブの
# 構文エラー**が誰にも気付かれず入る。`# shellcheck disable=SCxxxx -- 理由` は
# ディレクティブとして解釈されて SC1073/SC1072 になり、**そのファイルの静的検査が
# 丸ごと止まる**。見た目は「抑制コメントを書いた」正しい形なのでレビューでも読み飛ばされ、
# PR #524 では実際に 2 巡のレビューを通過した。同型は行頭が `# shellcheck …` の
# **散文コメント**でも起きる（本 PR で tests/lib/mbcs-guard.sh:19 を実測・修正）。
#
# ## 重大度の線引き（AC-3）
#
# 本ゲートが赤にするのは **error のみ**。warning 以下は「今は見ていない」。
#
#   - error（採用）: 構文エラーとディレクティブのパース不能（SC1072/SC1073）が入る。
#     これらは「検査が静かに止まる」形なので、ゲートが無いと永久に気付けない。
#     実測: 本 PR 時点の tracked shell スクリプトは 1 件（上記 mbcs-guard.sh）だけで、
#     それを直せば 0 件になる。抑制（disable）は 1 件も足していない。
#   - warning 以下（不採用・段階導入）: 上記 1 件を直したあとの対象集合で実測 59 件
#     （SC2034×29 / SC2115×12 / SC2154×10 / SC1090×5 / SC2318・SC2188・SC2155 各 1）。
#     うち SC2034「appears unused」は source 前提の共有ライブラリで**正しいコードを
#     赤にする**構造的誤検出で、[ACE-160-3] が「既定で赤いゲートは赤を無視する運用を
#     生む」として一度ゲート化を見送っている。線を error に引くのはその判断と整合する。
#     warning 以下へ広げるなら、既存 59 件の解消を先に行い、本ヘッダの数字ごと更新すること。
#
# [ACE-160-3]: docs/08-knowledge/playbook/tooling.md#ace-160-3
#
# ## 検査対象（scope）
#
#   tracked な `*.sh` ∪ tracked な**実行ビット付き**ファイルのうち先頭行が
#   sh 系 shebang のもの（symlink は除外）。実測（本 PR 時点）: 前者 144 件、後者 2 件
#   （tests/*/fixtures/gh-stub/gh）。件数は毎回実体から数え、サマリーへ出す。
#   実行ビットを見るのは、この suite の fixtures/*.bash（shebang を持つが実行しない
#   検出力 fixture・意図的に mode 644）を横断走査から外すため。fixture には**拡張子 .sh を
#   使わない**こと — `*.sh` は実行ビットを見るより先に対象集合へ入る。逆に言えば
#   **実行ビットの無い非 .sh のシェルスクリプトは対象外**で、実測 0 件。
#   fixtures が対象集合に入っていないことは case 7 が固定する。
#
# ## 抑制の不可能性（設計上の重要な性質）
#
# SC1072/SC1073 は**ファイル内から抑制できない**（`# shellcheck disable=SC1072,SC1073`
# を書いても発火する。0.11.0 で実測）。ディレクティブのパース段階のエラーだからで、
# よって「ゲートを入れたのに抑制で黙らせる」経路は存在しない。この性質があるため、
# disable 一覧に SC107x が現れないことを見張る追加ゲートは不要。
#
# ## 検出力（AC-1 / AC-5）
#
# 実ツリーが緑である限り、横断走査だけでは「何を検出できるか」が分からない。
# fixtures/bad-directive.bash（Issue の実例と同形）を毎回 shellcheck へ通し、
# **ファイル名と行番号を名指しして赤くなる**ことを常設で実測する。期待行番号は
# fixture から導出するので、fixture を編集しても期待値が腐らない。
# 対で fixtures/good-directive.bash（正しい形のディレクティブ + error 未満の指摘）を
# 置き、error では緑・warning では非空であることを固定する（[ACE-725-1]。緑が
# 「中身が無いから」ではなく「線引きどおり」であることの実証）。
# fixture 走査も横断走査も **sc_scan() 1 本**・同じ重大度定数（GATE_SEVERITY）を通す
# （[ACE-717-1]）。呼び出しを別実装へ分けると、横断走査側にだけ除外オプションを足す変異が
# 検出力 fixture をすり抜ける（sc_scan は追加引数を素通しするので、呼び出し行ごとに
# オプションを足す余地までは塞いでいない。塞いでいるのは実装と重大度の分岐）。
# 検査総数は EXPECTED_TOTAL で縛る（[ACE-542-1]。検査そのものを消す侵食を赤にする）。
#
# 対の `-selftest` suite は**置かない**。検出力 fixture は本 suite の実行のたびに走るので
# 効き目を毎回実測できる（docs-scan-mirror が golden 一致で同じ判断をしている）。加えて
# `-selftest` は `FF_RUN_ALL_FAST=1` で除外されるため、検出力をそちらへ移すと高速モードで
# 丸ごと消える。in-suite なら既定・高速のどちらでも走る。
#
# [ACE-725-1]: docs/08-knowledge/playbook/testing.md#ace-725-1
# [ACE-717-1]: docs/08-knowledge/playbook/testing.md#ace-717-1
# [ACE-542-1]: docs/08-knowledge/playbook/testing.md#ace-542-1
#
# ## 動作を確認した shellcheck
#
# **0.11.0 で全 8 件 green を実測**（本ヘッダの件数・所要時間もこの版での測定）。要求する
# 機能は `--severity` と `--format=gcc` で、これらを解さない古い版（目安として 0.6.0 未満）
# では rc が 0/1 の外に出て「検査が成立していない」として**赤**になる — 黙って緑にはならないので、
# 版番号そのものを検査する下限ガードは置いていない。
#
# 一時領域・ネットワーク・課金は不要。shellcheck が PATH に無ければ丸ごと ○ skip
# （run-all では REQUIRED_SUITES に載っているので明示許可が要る）。
# 単体で〜14 秒 / run-all 経由でも 14 秒（146 ファイル・shellcheck 0.11.0 で実測。
# 数字を更新するときは実測してから直すこと）。
#
# 本ファイルは**実行ビットを立てておくこと**（mode 100755）。run-all.sh は `[[ ! -x ]]` を
# hard gate として NOT_RUN に数え、FF_RUN_ALL_ALLOW_SKIP でも救済されずに全体が非 0 になる。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/shellcheck/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FIXTURES="$SCRIPT_DIR/fixtures"
BAD_FIXTURE="$FIXTURES/bad-directive.bash"
GOOD_FIXTURE="$FIXTURES/good-directive.bash"

# ゲートが赤にする重大度。ヘッダ「重大度の線引き」と対で運用する。
GATE_SEVERITY=error

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "○ skip: shellcheck が PATH に無いため shell スクリプトの静的検査をスキップ（検査は1件も実行されていません。brew install shellcheck / apt install shellcheck で有効化）"
  exit 0
fi

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "✗ リポジトリルートを解決できません（git rev-parse 失敗）— 横断検査を実行できません" >&2
  exit 1
fi

for f in "$BAD_FIXTURE" "$GOOD_FIXTURE"; do
  [[ -s "$f" ]] || { echo "✗ 検出力 fixture が見つからないか空です: $f" >&2; exit 1; }
done

cd "$REPO_ROOT"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

SC_OUT=""
SC_RC=0

# 唯一の shellcheck 起動口。fixture 走査も横断走査もここを通す（ACE-717-1）。
# $1: 重大度 / 残り: 検査対象ファイル
sc_scan() {
  local severity="$1"
  shift
  set +e
  SC_OUT="$(shellcheck --severity="$severity" --format=gcc "$@" 2>&1)"
  SC_RC=$?
  set -e
}

# 終了コードの規約は 0=指摘なし / 1=指摘あり。2（ファイルを開けない）や
# 4（オプション不正）は「検査が成立していない」ので、緑にも赤（指摘あり）にも
# 寄せずに専用の失敗として名指しする。
sc_rc_is_valid() {
  [[ "$SC_RC" -eq 0 || "$SC_RC" -eq 1 ]]
}

# 直近の shellcheck 出力に固定文字列 $1 が現れるか。`grep -q` は使わない: マッチ時点で
# 終了して上流の printf を SIGPIPE で殺し、pipefail のもとでマッチが「不一致」へ
# 反転する。`grep -c` は入力を最後まで読むのでその反転が起きない（run-all の
# case 10 が再混入を見張っている）。
sc_out_has() {
  [[ "$(printf '%s\n' "$SC_OUT" | grep -cF -- "$1")" -gt 0 ]]
}

echo "== 検出力: 不正な抑制ディレクティブ（fixture） =="

# 期待行番号は fixture から導出する（直書きすると fixture 編集で静かに腐る）。
BAD_LINE="$(grep -n -F -- 'disable=SC2254 --' "$BAD_FIXTURE" | cut -d: -f1 | tail -n 1 || true)"
sc_scan "$GATE_SEVERITY" "$BAD_FIXTURE"

if ! sc_rc_is_valid; then
  bad "不正ディレクティブ fixture の検査が成立していない（shellcheck rc=${SC_RC}）"
  bad "出力がファイル名と行番号を名指しする（rc 異常のため判定不能）"
  bad "出力にディレクティブのパース不能（SC1073）が含まれる（rc 異常のため判定不能）"
  { printf '%s\n' "$SC_OUT" | tail -n 20 || true; } >&2
else
  if [[ "$SC_RC" -eq 1 ]]; then
    ok "不正な抑制ディレクティブ（\`-- 理由\` 形式）で赤くなる"
  else
    bad "不正な抑制ディレクティブを検出できない（rc=0 で緑になった）— ゲートが空振りしている"
  fi

  if [[ -n "$BAD_LINE" ]] && sc_out_has "bad-directive.bash:${BAD_LINE}:"; then
    ok "出力がファイルと行を名指しする（bad-directive.bash:${BAD_LINE}）"
  else
    bad "出力がファイルと行を名指ししない（期待行: ${BAD_LINE:-抽出失敗}）"
    { printf '%s\n' "$SC_OUT" | tail -n 20 || true; } >&2
  fi

  if sc_out_has '[SC1073]'; then
    ok "ディレクティブのパース不能（SC1073）として報告される"
  else
    bad "SC1073 が報告されない — 検出理由が Issue #530 の欠陥クラスと違う"
    { printf '%s\n' "$SC_OUT" | tail -n 20 || true; } >&2
  fi
fi

echo
echo "== 重大度の線引き: 正しいディレクティブ + error 未満の指摘（fixture） =="

sc_scan "$GATE_SEVERITY" "$GOOD_FIXTURE"
if sc_rc_is_valid && [[ "$SC_RC" -eq 0 && -z "$SC_OUT" ]]; then
  ok "正しい形のディレクティブ（\`# 理由\` 形式）は error 重大度で緑"
else
  bad "正しい形のディレクティブが error 重大度で赤くなる（rc=${SC_RC}）— 過剰検出"
  { printf '%s\n' "$SC_OUT" | tail -n 20 || true; } >&2
fi

sc_scan warning "$GOOD_FIXTURE"
if sc_rc_is_valid && [[ "$SC_RC" -eq 1 && -n "$SC_OUT" ]]; then
  ok "同じ fixture は warning 重大度では指摘がある（緑は線引きの結果であって空ではない）"
else
  bad "green pin の fixture が warning 重大度でも無指摘（rc=${SC_RC}）— 緑の実証にならない"
  { printf '%s\n' "$SC_OUT" | tail -n 20 || true; } >&2
fi

echo
echo "== 横断走査: tracked shell スクリプト全体 =="

# 対象集合: tracked *.sh ∪ tracked かつ実行ビット付きで sh 系 shebang を持つファイル。
# symlink（mode 120000）は実体を別途走査するので除外する。
TAB="$(printf '\t')"
SHEBANG_RE='^#!.*[/ ](sh|bash|dash|ksh)( |$)'
TARGETS=()
# git の失敗は先に単独で判定する。`… || LIST_OK=0` をプロセス置換の中に書くと
# 代入がサブシェルへ閉じ込められ、失敗が呼び出し側へ伝わらない。
LIST_OK=1
if ! git -C "$REPO_ROOT" ls-files -s -z >/dev/null 2>&1; then LIST_OK=0; fi
while IFS= read -r -d '' entry; do
  mode="${entry%% *}"
  path="${entry#*"$TAB"}"
  if [[ "$mode" == "120000" ]]; then continue; fi
  case "$path" in
    *.sh) TARGETS+=("$path"); continue ;;
  esac
  if [[ "$mode" != "100755" ]]; then continue; fi
  if [[ ! -f "$path" ]]; then continue; fi
  first=""
  IFS= read -r first < "$path" || true
  if [[ "$first" =~ $SHEBANG_RE ]]; then TARGETS+=("$path"); fi
done < <(git -C "$REPO_ROOT" ls-files -s -z 2>/dev/null || true)

if [[ "$LIST_OK" -eq 1 && "${#TARGETS[@]}" -gt 0 ]]; then
  ok "検査対象の tracked shell スクリプトが ${#TARGETS[@]} 件（0 件なら「指摘なし」は主張できない）"
else
  bad "検査対象の一覧を取得できない（git ls-files 失敗 or 0 件）— 0 件の主張はできない"
fi

# 検出力 fixture が横断走査へ紛れ込むと、この suite 自身が恒常的に赤くなる。
# fixtures を実行ビット無しに保つ設計が効いていることを固定する。
FIXTURE_REL="${FIXTURES#"$REPO_ROOT"/}"
fixture_in_targets=0
if [[ "${#TARGETS[@]}" -gt 0 ]]; then
  for path in "${TARGETS[@]}"; do
    case "$path" in
      "$FIXTURE_REL"/*) fixture_in_targets=1 ;;
    esac
  done
fi
if [[ "$FIXTURE_REL" == /* ]]; then
  bad "検出力 fixture がリポジトリ外にある（${FIXTURES}）— 対象外であることを確かめられない"
elif [[ "$fixture_in_targets" -eq 0 ]]; then
  ok "検出力 fixture は横断走査の対象外（拡張子 .sh を使わず、実行ビットも立てないこと）"
else
  bad "検出力 fixture が横断走査の対象に入っている（${FIXTURE_REL}/ 配下は拡張子 .sh を使わず、実行ビットも立てないこと。\`*.sh\` は実行ビット判定より先に対象へ入る）"
fi

if [[ "${#TARGETS[@]}" -gt 0 ]]; then
  sc_scan "$GATE_SEVERITY" "${TARGETS[@]}"
  if ! sc_rc_is_valid; then
    bad "横断走査が成立していない（shellcheck rc=${SC_RC}）— 対象ファイルを開けない等"
    { printf '%s\n' "$SC_OUT" | tail -n 20 || true; } >&2
  elif [[ "$SC_RC" -eq 0 && -z "$SC_OUT" ]]; then
    ok "tracked shell スクリプト ${#TARGETS[@]} 件に ${GATE_SEVERITY} 重大度の指摘なし"
  else
    bad "${GATE_SEVERITY} 重大度の指摘がある（下に全件。抑制で潰さず原因を直すこと）"
    { printf '%s\n' "$SC_OUT" || true; } >&2
  fi
else
  bad "対象が 0 件のため横断走査を実行できない"
fi

echo
# 検査総数の固定。検査そのものが削除される侵食（消えた検査は変異させても赤くならない）を
# 赤くする。検査の増減時は EXPECTED_TOTAL も同時に更新すること。
EXPECTED_TOTAL=8
TOTAL=$((PASS + FAIL))
if [[ "$TOTAL" -eq "$EXPECTED_TOTAL" ]]; then
  echo "  ✓ 検査総数が ${EXPECTED_TOTAL} 件（増減時は EXPECTED_TOTAL も更新すること）"
else
  echo "  ✗ 検査総数が想定と異なります（実測: ${TOTAL} / 期待: ${EXPECTED_TOTAL}）" >&2
  FAIL=$((FAIL + 1))
fi

echo
echo "結果: PASS=${PASS} FAIL=${FAIL} / $(shellcheck --version | grep '^version:' || true)"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "✅ shellcheck: 全 ${TOTAL} 件 pass"
