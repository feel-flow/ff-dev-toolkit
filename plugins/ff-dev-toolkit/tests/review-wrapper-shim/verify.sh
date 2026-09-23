#!/usr/bin/env bash
#
# 同梱レビューラッパー（シム）の契約検査（Issue #406）。
#
# 潰している事故は 2 つある。
#
# (1) **`codex exec` を同期で直接叩くラッパー**。codex は stdin が TTY でないと
#     「追加入力」として読みに行き、EOF が来るまでブロックする。stdout には何も
#     出ないので、外からはハングと区別がつかない。実測（codex-cli 0.144.5）:
#       codex exec -s read-only "..." </dev/null  → rc=0 / 9 秒で完走
#       同上・stdin を開いたまま同期実行          → 60 秒でタイムアウト。
#                                                  stderr は "Reading additional
#                                                  input from stdin..." のみ
#     実際にこれを踏み、長時間かけて「Codex 未応答」と誤診した経緯がある。
#     消費プロジェクトが自前で持っていた旧ラッパーには、今もこの形のものがある。
#
#     同梱するシムは `multi-agent.sh` へ委譲するので、CLI の起動は
#     `run_with_timeout` 経由になる。あちらは `"$@" >"$out_file" &` と**非同期**で
#     子を起動し、POSIX により非対話シェルの非同期リストの stdin は /dev/null に
#     割り当てられる（実測: 同期 15 秒ブロック / 非同期 0 秒）。つまり委譲している
#     限り罠は構造的に起きない。**だから「直接叩いていないこと」を固定する**。
#
# (2) **黙って無視されるオプション・環境変数**。シムは薄いので、既存コピーが持って
#     いた機能の大半を持たない。渡されたものを黙って捨てると、利用者は指定したつもり
#     のまま既定設定でレビューが走り、成果物からもログからも判別できない
#     （ACE-70-2 が記録した実害と同じ形）。受け取れないものは非 0 で拒否し、
#     対応する `multi-agent.sh` の経路を案内する。
#
# 検出器は静的走査（実 CLI 不要）。効くことは fixture で先に確かめる —
# 「直接叩く」形を検出できない検出器は、本体を通しても何も保証しない。
# 振る舞い（オプションの写し・拒否・skip）は stub の multi-agent.sh で実測する。
# 空振り検出: 版読み取り代入の `|| true` 4 箇所を持つ旧正本を
#   静的針へ通すと4件一致、新正本は0件。grep の実行失敗も緑にしない。
#
# **stub で測れるのは argv の形まで**。委譲先が実際にプランを出すか・何本の CLI を
# 検出するかは実体の multi-agent.sh でしか測れないので、codex 不在の --dry-run 経路は
# 実体を toolkit へ置いた fixture で固定する。この区別を怠ると「AC が fake stub に
# 対してだけ緑」になる（実測: この経路の受け入れ条件がその形で 1 版ぶん緑のまま通った）。
#
# 変異検出（2026-09-13 実測。赤転しなかった変異は無し）:
#   「--cli codex-cli を外す」処理の無効化 → 3 件赤。外す条件を「常に外す」へ広げる → 5 件赤
#   （codex が居る回・除外指定の回で固定 argv が壊れる）。`--exclude-cli codex-cli` の回でも
#   外す → 3 件赤。除外指定の解釈分岐から判定を落とす → 空白形 2 件赤 / `=` 形 1 件赤
#   （2 つの分岐を別々に測らないと、片方だけに足した実装が緑で通る）。
#   除去ループを「CLI 名を取るオプションなら全部落とす」形へ書き換える → 1 件赤
#   （利用者の除外指定まで巻き込む壊れ方）。「実行は rc=4 で止まる」の警告行を落とす → 1 件赤。
#   終了コード表から pair 主 reviewer 不在の行を削除 → 1 件赤。
#   **実体経由の配線を fake stub へ戻す → 1 件赤**（この 1 件が、本 suite が同型の
#   再発を止める唯一の針。stub は常に rc=0 を返すのでプランの有無を測れない）。
#
#   このとき**当たらなかった変異を 2 つ踏んだ**ので記録する。(1) 終了コード表の行末へ
#   文字列を足す形は、部分一致の needle を満たしたまま通る（行ごと落とす変異で測り直す）。
#   (2) 同じ要素へ `--cli` と `--exclude-cli` の両方を要求する条件は論理的に到達不能で、
#   実装を 1 行も変えていないのと同じ。変異は「当たったこと」を先に確かめる。
#
# 変異検出（2026-09-14 実測。分割後の構成に対するもの）:
#   cases ファイルへ `run_isolated bash "$PLACED"` の素起動を足す → 起動口ガード 1 件赤
#   （verify.sh だけを走査する旧実装では緑のまま）。同じ行を `run_isolated` 無しで足す →
#   adapter-env-isolation-selftest の配線検査が赤。source 順を入れ替える（toolkit-root を
#   install より前へ）→ set -u の途中死を ff_cleanup が rc=1 へ倒す。cases を 1 本消す →
#   source 失敗の途中死で rc=1。source 行を 1 本消す（ファイルは残す）→ 未 source 照合が赤
#   （素の `.` では PASS=241 rc=0 で通っていた）。cases 側の素起動に ff-shim-launch-helper
#   マーカーを添える → 起動口ガードが赤（除外は verify.sh 限定。全ファイルに効く旧実装では緑）。
#   suite 内に `zz.sh` というディレクトリを置く → readable=0 で赤（旧実装は算術エラーを吐いて ✓）。
#
# ファイル構成（`Issue #1604`。MASTER.md「1200 行超は分割必須」への対応）:
#   本ファイルは bootstrap（分離リスト・一時領域・trap・stub toolkit・run_shim 等のヘルパ・
#   起動口ガード）と summary だけを持ち、検査本体は機能別の `*-cases.sh` を**この順に**
#   source する（一覧は末尾。README.md に範囲と依存の表がある）。run-all 上は従来どおり
#   1 suite のまま。分割は同一プロセス内の source なので fixture・関数・カウンタを共有し、
#   分割直後の PASS 総数は分割前と同じ 273（実測）。その後、構成を守る検査（src_cases の
#   増分検査 + 未 source cases の照合）を 1 件足して 274。別 suite 化しなかった理由は ADR-052。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
SHIM="$PLUGIN_ROOT/scripts/templates/codex-review.sh"
# 覆い隠し告知の needle は実体（シム）から導出する。リテラルを書き写すと、文言を変えたときに
# 肯定側の針だけが赤くなり、不在側（「鳴らないこと」）の 2 本は «何も検証しない緑» へ静かに
# 退化する（ACE-734-1）。抽出できない場合は fail-closed で落とす。
MASK_NEEDLE="$(/usr/bin/grep -m1 -o 'サイドカーは使える toolkit を指していません' "$SHIM" || true)"
[ -n "$MASK_NEEDLE" ] || { echo "✗ 覆い隠し告知の needle をシムから抽出できません（不在側の検査が空振りします）" >&2; exit 1; }
SETUP="$PLUGIN_ROOT/scripts/setup-multi-agent.sh"
DIRECT_CLI_DETECTOR="$SCRIPT_DIR/direct-cli-detector.awk"
SUITE_NAME="review-wrapper-shim"

# ── 実行環境つまみからの分離（Issue #434） ──────────────────────────────────
# シムは利用者が設定する env をそのまま解釈する層なので、ホストが export したまま
# suite を回すと「env 未設定」前提のアサーションが崩れる。実測（1 変数ずつ設定）:
#   MULTI_AGENT_CODEX_PROFILE=bogus    → 4 件赤（profile 優先の分岐へ食い込む）
#   MULTI_AGENT_MODEL_CODEX_CLI=bogus  → 3 件赤
#   CODEX_REASONING_EFFORT=high        → effort 写像のケースが赤
#   SKIP_CODEX_REVIEW=1                → 53 件赤（委譲そのものが止まる）
#
# **共通ライブラリの保証境界は動かさない。** lib は対象を MULTI_AGENT_* /
# FF_TIMEOUT_* の 2 プレフィックスと明文で宣言しており、CODEX_* / SKIP_CODEX_REVIEW
# はその外。境界を広げると lib を source する他の 8 suite すべての名簿が変わるため、
# ここでは **この suite の中で**シム固有の名前を落とす（影響範囲を 1 suite に閉じる）。
#
# 一覧は手で書かず実装から抽出する — シムが新しいつまみを足したとき、手書きの
# 一覧は黙って漏れる。抽出が空振りすると分離が静かに消えるので、既知の名前を
# センチネルとして fail-closed で検査する（lib と同じ設計）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CODEX_PROFILE MULTI_AGENT_MODEL_CODEX_CLI MULTI_AGENT_CODEX_REASONING_EFFORT" "$SHIM"

# **左境界を持たせる。** 境界なしの `(CODEX|SKIP_CODEX)_[A-Z0-9_]+` は、シムに実在する
# MULTI_AGENT_CODEX_PROFILE / MULTI_AGENT_MODEL_CODEX_CLI から **実在しない**
# CODEX_PROFILE / CODEX_CLI を切り出す（実測）。過剰包含そのものは無害（未設定変数への
# -u は no-op）だが、同じ欠陥は逆向き＝「実在する変数を別名として拾い、本体を素通り
# させる」形でも成立する。先頭アンダースコアの取りこぼしで実害が出た前例があるため、
# ここでも境界を明示する。境界文字は grep が一緒に返すので、語ごとに 1 文字剥がす。
_shim_raw=""; _shim_grep_rc=0
_shim_raw="$(grep -hoE '(^|[^A-Z0-9_])_?(CODEX|SKIP_CODEX)_[A-Z0-9_]+' "$SHIM")" || _shim_grep_rc=$?
if [ "$_shim_grep_rc" -gt 1 ]; then
  echo "✗ シムからの CODEX_* / SKIP_CODEX_* 抽出が失敗しました（grep rc=${_shim_grep_rc}）。部分的な読み取り失敗は分離リストの黙った欠落になるため続行しない" >&2
  exit 1
fi
_shim_seen=" "
for _v in $_shim_raw; do
  # 行頭一致なら境界文字は付かない。それ以外は先頭 1 文字が境界なので落とす。
  case "$_v" in
    CODEX_*|SKIP_CODEX_*|_CODEX_*|_SKIP_CODEX_*) : ;;
    *) _v="${_v#?}" ;;
  esac
  case "$_shim_seen" in *" $_v "*) continue ;; esac
  _shim_seen="${_shim_seen}${_v} "
  ISOLATE_ENV+=(-u "$_v")
done
for _s in CODEX_REASONING_EFFORT SKIP_CODEX_REVIEW CODEX_DEFAULT_REVIEWERS CODEX_MODEL; do
  case " ${ISOLATE_ENV[*]-} " in
    *" $_s "*) : ;;
    *)
      echo "✗ 分離リストにセンチネル ${_s} がありません。シムの実装で改名されたか、抽出が空振りした。実行環境からの分離を保証できないため続行しない" >&2
      exit 1 ;;
  esac
done

echo "== 同梱レビューラッパー（シム）の契約 =="

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正なパス・
# quota 超過など）まで「書き込み可能な環境で」に誤帰属し、恒常的に壊れた TMPDIR が
# suite を exit 0 で無効化し続ける。2>&1 で受けると成功時はパス・失敗時は理由が入る。
_ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-review-shim.XXXXXX" 2>&1)" || true   # 失敗時は stderr の内容が残る（空にすると理由が消える）
if [ -d "$_ff_mktemp_out" ]; then WORK="$_ff_mktemp_out"; else WORK=""; fi
if [ -z "$WORK" ]; then
  echo "○ skip: 一時ディレクトリを作成できません（本 suite の検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

# 途中死を rc=0 で終わらせない（ACE-404-2）。trap 最終コマンドの成功ステータスが
# suite の終了ステータスを上書きし、set -u の死では突入時点の $? が既に 0 になる。
FF_REACHED_END=0
ff_cleanup() {
  ff_rc=$?
  rm -rf "$WORK"
  if [ "$FF_REACHED_END" != "1" ] && [ "$ff_rc" -eq 0 ]; then
    echo "✗ ${SUITE_NAME} verify: 末尾に到達せず終了した（set -e / set -u による途中死。残りのアサーションは 1 件も実行されていない）" >&2
    ff_rc=1
  fi
  exit "$ff_rc"
}
trap ff_cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# stub の multi-agent.sh: 受け取った argv を 1 引数 1 行で記録する。
PROJ="$WORK/proj"
TOOLKIT="$PROJ/toolkit"
mkdir -p "$PROJ/scripts" "$TOOLKIT/scripts/templates" "$TOOLKIT/scripts/adapters" "$TOOLKIT/.claude-plugin"
# シムは diff サイズの計測基準を委譲先と同じ実装（resolve_base_branch_ref）で解決する。
# stub 側にも**実体**を置く（写しを書くと、本体が変わっても stub だけ古いまま緑になる）。
cp "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" "$TOOLKIT/scripts/adapters/adapter-common.sh"
cp "$SHIM" "$PROJ/scripts/codex-review.sh"
cp "$SHIM" "$TOOLKIT/scripts/templates/codex-review.sh"
chmod +x "$PROJ/scripts/codex-review.sh"
cat > "$TOOLKIT/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "ff-dev-toolkit",
  "version": "0.38.0"
}
JSON
cat > "$TOOLKIT/scripts/agent-config.yaml" <<'YAML'
version: "2.0"
toolkit_version: "0.38.0"
YAML
# stub にもオーケストレータの印（--task / implement）を持たせる。シムは候補が
# 本当に multi-agent.sh かを検査するので、印の無い stub は正しく拒否される。
cat > "$TOOLKIT/scripts/multi-agent.sh" <<'SH'
#!/usr/bin/env bash
# stub orchestrator: --task review|explore|implement を受け付ける体裁
: > "$ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_LOG"; done
# env の写像を検査するため、委譲先から見えた値を記録する。argv だけを見ていると
# 「写したつもりで export していない」実装を素通しする（シムが exec で置き換わる
# 以上、env は argv と同じく委譲の一部）。
: > "$ENV_LOG"
for v in MULTI_AGENT_MODEL_CODEX_CLI MULTI_AGENT_CODEX_PROFILE MULTI_AGENT_CODEX_REASONING_EFFORT CODEX_MODEL; do
  eval "_val=\${$v:-}"
  [ -n "$_val" ] && printf '%s=%s\n' "$v" "$_val" >> "$ENV_LOG"
done
echo "stub orchestrator ran"
SH
chmod +x "$TOOLKIT/scripts/multi-agent.sh"

RUN_RC=0
# run_shim [VAR=VALUE ...] [-- <シムへの引数> ...]
# 先頭の VAR=VALUE 群は env 代入として扱い、残りをシムの引数として渡す。
# 両者を混ぜて env へ丸投げすると `--base` が env 代入として解釈され rc=127 になる。
run_shim() {
  : > "$WORK/argv.log"
  RUN_RC=0
  local -a envs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Z_]*=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  : > "$WORK/env.log"
  local run_cwd="${RUN_SHIM_CWD:-$PWD}"
  # 既定は完全な stub toolkit。adapter が欠けている toolkit を測るケースだけが
  # RUN_SHIM_TOOLKIT で別の root を指す（既定を書き換えないので他ケースに波及しない）。
  local run_toolkit="${RUN_SHIM_TOOLKIT:-$TOOLKIT}"
  # 既定は FF_DEV_TOOLKIT_ROOT で解決させる。RUN_SHIM_NO_ROOT を立てたケースだけは明示指定を
  # 落とし、cache も空へ向けて「toolkit がどこにも無い」経路（解決 rc=1）を測る。既定指定が
  # 残っていると rc=2（明示指定が在るのに使えない）にしかならず、rc ごとの案内を分けられない。
  local -a root_unset=() root_env=(FF_DEV_TOOLKIT_ROOT="$run_toolkit")
  if [ -n "${RUN_SHIM_NO_ROOT:-}" ]; then
    root_unset=(-u FF_DEV_TOOLKIT_ROOT)
    root_env=(CODEX_HOME="$WORK/no-codex-home" CLAUDE_CONFIG_DIR="$WORK/no-claude-home")
  fi
  # 利用者設定（${XDG_CONFIG_HOME:-$HOME/.config}/ff-dev-toolkit/reviewers）をホストから
  # 切り離す。run_isolated の名簿は MULTI_AGENT_* 等の env を落とすが、この設定ファイルは
  # HOME 経由で届くので名簿では止まらない。漏れると実オーケストレータ経由のケースが
  # 「開発者のホストでは pair の主 reviewer が設定済み → rc=1、設定の無い CI では分散
  # プランへ縮退 → rc=0」と環境で割れる（Issue 1599: 週次 CI でだけ赤）。既定は空の
  # 設定領域（= reviewers 未設定）。設定済みを測るケースは XDG_CONFIG_HOME を上書きする
  # （ケース固有の env は後ろに並ぶので、この既定より優先される）。
  # 主 reviewer の出所は 3 つ（env MULTI_AGENT_REVIEW_MAIN > プロジェクト設定
  # <cwd の git root>/.claude/agent-config.yaml の review.main > この利用者設定）。env は
  # run_isolated の名簿が落とし、利用者設定はここで隔離する。プロジェクト設定は cwd
  # 依存なので run_shim では固定せず、実オーケストレータ経由のケースが RUN_SHIM_CWD を
  # `.claude/` の無い git fixture repo へ向ける（このリポジトリに .claude/agent-config.yaml
  # が置かれた日に同じ形で割れないため）。
  mkdir -p "$WORK/xdg-config-empty"
  root_env+=(XDG_CONFIG_HOME="$WORK/xdg-config-empty")
  # stdout と stderr を**分けて**記録する。合流させてから grep すると、通知が
  # stdout へ移っても検査が通ってしまう（pre-commit 等で stdout だけ捨てる構成では
  # 通知が消える）。既存の検査のために合流版も残す。
  # run_isolated を先頭に付けて実行環境のつまみを落とす。env は -u の除去を先に、
  # NAME=VALUE の代入を後に適用するので、ケース固有の指定（下の ${envs}）はそのまま効く
  # — 「ホストの値は除く / ケースの上書きは通す」という順序契約に乗っている。
  # codex の実体は stub を既定にする（CODEX_REVIEW_CODEX_BIN シーム）。ホストに codex が
  # 無くても既定用法のケースが「codex 不在の降格」へ落ちないようにし、降格経路は
  # 不在を名指しするケースだけが実測する。ケース固有の env 指定が後ろに来るので上書きできる。
  ( cd "$run_cwd" && \
    run_isolated_shim ${root_unset[@]+"${root_unset[@]}"} "${root_env[@]}" \
      ARGV_LOG="$WORK/argv.log" ENV_LOG="$WORK/env.log" \
      ${envs[@]+"${envs[@]}"} \
      bash "$PROJ/scripts/codex-review.sh" "$@" \
      >"$WORK/stdout.log" 2>"$WORK/err.log" </dev/null ) || RUN_RC=$?
  cat "$WORK/stdout.log" "$WORK/err.log" > "$WORK/out.log"
}
# codex の stub 実体。シムは `command -v` で存在だけを見る（起動はしない — 起動するなら
# 直接起動禁止の検出器が赤にする）。
STUB_CODEX="$WORK/stub-codex/codex"
mkdir -p "$WORK/stub-codex"
printf '%s\n' '#!/usr/bin/env bash' 'echo "stub codex must not be invoked by the shim" >&2' 'exit 99' > "$STUB_CODEX"
chmod +x "$STUB_CODEX"
# シムを起動するケースの共通入口。シムは委譲の直前で codex の実体を確認し、無ければ降格を
# 名指しして exit 4 で終わる（Issue #1393）。toolkit root の解決経路（sidecar / cache / env）
# を測るケースは委譲まで到達しないと判定できないので、codex の実体をホストから切り離して
# stub に固定する。
#
# ここで **export は使えない**。上の抽出はシム本体に現れる CODEX_* を機械的に分離リストへ
# 入れるため、ISOLATE_ENV には -u CODEX_REVIEW_CODEX_BIN が必ず含まれ、export した値は
# run_isolated の時点で落ちる（実測）。env の代入は -u より後に適用されるので、run_isolated
# の**後ろ**で渡す。これを怠ると、codex の無いホスト（クラウド）で 13 件が rc=4 で落ちる
# （Issue #1427 で実測）。codex 不在そのものを測るケースは、この後ろに自分の代入を置いて
# 上書きする（env は後の代入が勝つ）。
#
# 引数は env と同じ形（-u NAME … / NAME=VALUE … / コマンド）。env はオプションを代入より
# 先に要求するため、先頭の -u 群だけを取り分けて stub 代入の前へ戻す。
run_isolated_shim() {
  local -a _opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -u)
        # 値の無い -u を env へ渡すと、次に来る代入をオプション名として食う。黙って
        # 進めると rc=127 になり、負の判定しか持たないケースでは ✓ に化ける。
        if [ "$#" -lt 2 ]; then
          echo "✗ run_isolated_shim: -u に値がありません（呼び出し側の指定ミス）" >&2
          exit 1
        fi
        _opts+=(-u "$2"); shift 2 ;;
      *) break ;;
    esac
  done
  # 代入より後ろの -u も env は解釈しない（同じく rc=127）。先頭へまとめるよう名指しする。
  local _arg
  for _arg in "$@"; do
    if [ "$_arg" = "-u" ]; then
      echo "✗ run_isolated_shim: -u は先頭にまとめて渡してください（代入の後ろでは env が解釈しません）" >&2
      exit 1
    fi
  done
  run_isolated env ${_opts[@]+"${_opts[@]}"} CODEX_REVIEW_CODEX_BIN="$STUB_CODEX" "$@" # ff-shim-launch-helper
}

env_log_has() {
  grep -qxF "$1" "$WORK/env.log"
}
argv_has() {
  grep -qxF -- "$1" "$WORK/argv.log"
}
argv_has_seq() {
  # 連続する 2 行（フラグと値）が argv に現れるか
  awk -v a="$1" -v b="$2" 'prev == a && $0 == b { found = 1 } { prev = $0 } END { exit(found ? 0 : 1) }' \
    "$WORK/argv.log"
}

# 起動口の単一化を機械で守る（Issue #1427）。run_isolated を素で使ってシムを起動すると、
# 分離リストが CODEX_REVIEW_CODEX_BIN を -u で落とし、そのケースだけホストの codex 有無で
# 結果が変わる。ローカル（codex あり）では緑のまま、クラウド（codex なし）で 13 件が rc=4 で
# 落ちる形の環境依存で、実測するまで見えなかった。
#
# 対象は `run_isolated` に `env` / `bash` が続く形すべて（継続行で改行していても
# `run_isolated env` は同じ行に残る）。以前は「直後が -u か NAME=」に絞っていたが、
# それだと行末が `\` の形・空白 2 個・`run_isolated env bash …`・`run_isolated bash …` が
# 素通りする（レビューで実測）。ヘルパ本体の 1 行は行末マーカーで除外する。
#
# fail-open にしない: 対象が読めない / 改名された回に grep が rc=2 を返し、それを `|| true`
# で空にすると「違反ゼロ」と同じ緑になる。読めることと、ヘルパ経由の呼び出しが現に存在する
# ことを先に確かめてから空判定する。
#
# 対象は本ファイルだけでなく、この suite ディレクトリの **全 `*.sh`**（source される
# `*-cases.sh` を含む。`Issue #1604` で分割）。verify.sh 1 本に絞ったままだと、検査本体を
# 抱える cases ファイルの素起動が誰にも見られない。
_guard_uses=0
_guard_scan=""
_guard_ok=1
_guard_files=0
_guard_cases=0
for _guard_file in "$SCRIPT_DIR"/*.sh; do
  # 通常ファイルで読めること。ディレクトリ・FIFO・glob 空振りの literal は grep が rc=2 を
  # 返し、それを空扱いすると「違反ゼロ」の緑へ倒れる（レビュー実測: suite 内に zz.sh という
  # ディレクトリを置くと算術エラーを吐きながら ✓ が出た）。
  if [ ! -f "$_guard_file" ] || [ ! -r "$_guard_file" ]; then _guard_ok=0; break; fi
  _guard_files=$((_guard_files + 1))
  case "$_guard_file" in *-cases.sh) _guard_cases=$((_guard_cases + 1)) ;; esac
  # grep の rc は 0/1 だけを結果として受ける。2 以上は走査不能なので fail-closed。
  _guard_rc=0
  _guard_cnt="$(grep -cE '(^|[^_[:alnum:]])run_isolated_shim[[:space:]]' "$_guard_file")" || _guard_rc=$?
  [ "$_guard_rc" -le 1 ] || { _guard_ok=0; break; }
  _guard_uses=$((_guard_uses + _guard_cnt))
  _guard_rc=0
  _guard_raw="$(grep -nE '(^|[^_[:alnum:]])run_isolated[[:space:]]+(env|bash)([[:space:]]|$)' "$_guard_file")" || _guard_rc=$?
  [ "$_guard_rc" -le 1 ] || { _guard_ok=0; break; }
  # 行末マーカー（ff-shim-launch-helper）で除外できるのは、ヘルパ本体を持つ verify.sh だけ。
  # 全ファイルに効かせると、cases 側の素起動にマーカーを添えるだけで緑になる（レビュー実測）。
  if [ "${_guard_file##*/}" = "verify.sh" ]; then _guard_skip='ff-shim-launch-helper'; else _guard_skip='<<no-marker-exemption>>'; fi
  _guard_hit="$(printf '%s\n' "$_guard_raw" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vF "$_guard_skip" | sed '/^$/d' || true)"
  [ -z "$_guard_hit" ] || _guard_scan="${_guard_scan}${_guard_scan:+
}$(printf '%s\n' "$_guard_hit" | sed "s|^|${_guard_file##*/}:|")"
done
# verify.sh + cases が揃っていること（glob が空振り / 分割が消えた回を「違反ゼロ」にしない）
[ "$_guard_files" -ge 2 ] && [ "$_guard_cases" -ge 1 ] || _guard_ok=0
if [ "$_guard_ok" -eq 0 ] || [ "$_guard_uses" -eq 0 ]; then
  bad "起動口検査が対象を読めない、または run_isolated_shim の呼び出しを 1 件も見つけられない（検査が空振りしている）: readable=${_guard_ok} files=${_guard_files} cases=${_guard_cases} uses=${_guard_uses}"
elif [ -z "$_guard_scan" ]; then
  ok "シムの起動が run_isolated_shim に一本化されている（codex 実体の stub がホスト非依存で届く。${_guard_files} ファイル・ヘルパ経由 ${_guard_uses} 箇所）"
else
  bad "run_isolated を素で使ってシムを起動している行がある（stub が -u で落ち、ホストの codex 有無で結果が変わる）"
  printf '%s\n' "$_guard_scan" | sed 's/^/    | /' >&2
fi

# ── 検査本体（機能別 cases ファイル。`Issue #1604` で分割） ─────────────────────
#
# 各ファイルは同一プロセスで source され、上の fixture・関数・PASS/FAIL を共有する。
# **この一覧の順序が契約**: install-cases.sh が作る $FAKE / $PLACED / $SIDECAR を
# toolkit-root-resolution-cases.sh と legacy-compat-help-cases.sh が参照し、
# base-ref-diff-guard-cases.sh が作る $DIFF_REPO を perspective-list-diff-threshold-cases.sh が、
# recovery-mode-cases.sh が作る $WORK/review-context.txt を toolkit-root-resolution-cases.sh が
# 参照する。順序を変えると set -u の途中死（ff_cleanup が rc=1 へ倒す）か、fixture 不在の
# 偽赤になる。1 ファイルだけを実行する入口は置かない — 分離リスト・stub toolkit・trap を
# 持たずに検査本体だけ走らせると、ホスト env の汚染を測らない緑になる。
# ファイルごとの範囲と依存は各ファイルの先頭コメントと README.md を参照。
#
# source は src_cases を通す。素の `.` だと (1) source 行を 1 本消しても残りの FAIL=0 で緑、
# (2) 空ファイル・途中 return・関数に包んだまま未呼び出しの cases も緑、になる（レビュー実測:
# perspective-list の source 行を消すと PASS=241 rc=0 で通った）。src_cases は source 前後の
# PASS+FAIL の増分と二重 source を見て、末尾でディレクトリの *-cases.sh と source 済み一覧を
# 突き合わせる。
_cases_sourced=" "
src_cases() { # <cases ファイル名>
  local _name="$1" _before=$((PASS + FAIL))
  case "$_cases_sourced" in
    *" $_name "*) bad "cases ファイルが二重に source されている: $_name"; return 0 ;;
  esac
  _cases_sourced="${_cases_sourced}${_name} "
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/$_name"
  if [ $((PASS + FAIL)) -le "$_before" ]; then
    bad "$_name がアサーションを 1 件も実行しなかった（空ファイル・途中 return・関数に包んだまま未呼び出し）"
  fi
}
src_cases direct-cli-detector-cases.sh
src_cases delegation-basics-cases.sh
src_cases codex-absent-real-orchestrator-cases.sh
src_cases recovery-mode-cases.sh
src_cases base-ref-diff-guard-cases.sh
src_cases option-env-mapping-cases.sh
src_cases install-cases.sh
src_cases toolkit-root-resolution-cases.sh
src_cases legacy-compat-help-cases.sh
src_cases perspective-list-diff-threshold-cases.sh

_cases_orphan=""
_cases_total=0
for _cases_file in "$SCRIPT_DIR"/*-cases.sh; do
  [ -f "$_cases_file" ] || continue
  _cases_total=$((_cases_total + 1))
  case "$_cases_sourced" in
    *" ${_cases_file##*/} "*) : ;;
    *) _cases_orphan="${_cases_orphan} ${_cases_file##*/}" ;;
  esac
done
if [ "$_cases_total" -eq 0 ]; then
  bad "cases ファイルが 1 本も見つからない（glob が空振り / 分割が消えた）"
elif [ -n "$_cases_orphan" ]; then
  bad "source 一覧に載っていない cases ファイルがある（その検査は 1 件も走っていない）:${_cases_orphan}"
else
  ok "cases ファイル ${_cases_total} 本すべてが 1 回ずつ source され、各 1 件以上のアサーションを出した"
fi

echo
echo "  PASS=${PASS} FAIL=${FAIL}"
FF_REACHED_END=1
if [ "$FAIL" -eq 0 ]; then
  echo "✓ ${SUITE_NAME} verify: 全 ${PASS} 件 pass"
else
  echo "✗ ${SUITE_NAME} verify: ${FAIL} 件失敗" >&2
  exit 1
fi
