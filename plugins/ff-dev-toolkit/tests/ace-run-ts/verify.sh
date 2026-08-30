#!/usr/bin/env bash
#
# ace-run-ts: 同梱 ACE ゲートの runner 解決層の挙動検査（Issue #879）。
#
# 背景: /ace-curate の手順 4-f は未導入プロジェクト向けに `npx --yes tsx <同梱パス>`
# を案内していたが、root package に tsx binary が無い workspace 環境では
# `tsx: command not found` で 3 ゲートとも到達不能になった（CHEQIT で実測）。
# 解決層 scripts/ace-run-ts.sh は候補を**実際に起動して**確かめながら選び、全滅なら
# fail-closed で止める。本 suite はその解決規約を固定する。
#
# tests/ace-curate-fallback-exec/ と分けてある理由（レビュー指摘）: あちらは同梱
# TypeScript ゲートを実際に走らせるため npx とネットワークに依存し、取得できない環境では
# suite 丸ごと ○ skip する。解決層の検査は **bash だけで完結する**のに同じ skip に
# 巻き込まれると、「runner が無い環境で fail-closed するか」という、まさにその環境で
# 効いてほしい検査がオフライン時に消える。検査の環境依存は、検査対象の依存に合わせる。
#
# 外部コマンド・ネットワーク不要。偽 tsx を置いた位置だけが解決結果を決まるよう、
# PATH は空ディレクトリ 1 本へ差し替える（実機に何が入っているかで結果が変わると、
# この検査は環境依存の偽の赤／偽の緑になる）。
#
# 一時領域が使えない場合だけ suite 全体を ○ skip する（部分 skip はしない）。
# 代替検査が無いので tests/run-all.sh の REQUIRED_SUITES に載せる。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/ace-run-ts/verify.sh
# ACE-86-2: here-string / heredoc を使わない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
SKILL_MD="${PLUGIN_ROOT}/skills/ace-curate/SKILL.md"

# 解決層の相対パス（SSOT）。実在検査・SKILL.md の記述照合・実行の 3 つを同じ文字列から組む。
REL_RUNNER="scripts/ace-run-ts.sh"
RUNNER_ABS="${PLUGIN_ROOT}/${REL_RUNNER}"
# 候補判定に使う probe スクリプト（Issue #932）。解決層はフラグではなくこれを渡して
# 「本番と同じ形で TypeScript が実行できたか」を測るため、隣に実在することが前提になる。
REL_PROBE="scripts/ace-run-ts-probe.ts"
PROBE_ABS="${PLUGIN_ROOT}/${REL_PROBE}"
PROBE_BASE="${REL_PROBE##*/}"

if [ ! -s "${SKILL_MD}" ]; then
  echo "✗ ace-curate/SKILL.md が存在しないか空です: ${SKILL_MD}" >&2
  exit 1
fi

if ! _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ace-run-ts.XXXXXX" 2>&1)"; then
  echo "○ skip: 一時ディレクトリを作成できないため runner 解決の検査をスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "${_ff_mktemp_out}"
  exit 0
fi
# TMPDIR が末尾スラッシュを持つ環境では `//` が残る。解決層は cd 済みの $PWD から
# 辿るため正規化された形を出力し、照合が「別の理由で」外れる（実測: /T//x と /T/x）。
SANDBOX="$(cd "${_ff_mktemp_out}" && pwd)"
cleanup() {
  local rc=$?
  rm -rf "${SANDBOX}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== 解決層の実在と SKILL.md の案内 =="
if [ -r "${RUNNER_ABS}" ] && [ -s "${RUNNER_ABS}" ]; then
  ok "解決層がプラグインルート配下に実在し読み取れる"
else
  bad "解決層を読み取れないか空です（${RUNNER_ABS}）"
fi
if grep -Fq -- "\"\${FF_DEV_TOOLKIT_ROOT}/${REL_RUNNER}\"" "${SKILL_MD}"; then
  ok "SKILL.md が同じ相対パスを案内している"
else
  bad "SKILL.md の案内パスが実体と一致しません（${REL_RUNNER}）"
fi
# 案内と実装の経路が割れる退行（同梱テンプレートを npx で直叩きへ戻す）を赤くする。
if grep -Fq -- 'npx --yes tsx "${FF_DEV_TOOLKIT_ROOT}' "${SKILL_MD}"; then
  bad "SKILL.md の同梱テンプレート経路が npx 直書きへ戻っています（Issue #879 の退行）"
else
  ok "SKILL.md の同梱テンプレート経路に npx 直書きが残っていない"
fi

# --- 候補判定の材料（probe スクリプト）------------------------------------------
if [ -r "${PROBE_ABS}" ] && [ -s "${PROBE_ABS}" ]; then
  ok "probe スクリプトが解決層の隣に実在し読み取れる"
else
  bad "probe スクリプトを読み取れないか空です（${PROBE_ABS}）"
fi
# sentinel は解決層と probe の 2 か所にある。片側だけ変えた drift は候補が全滅する
# （= すべての環境で「runner が見つかりません」になる）形で効くので、静的に固定する。
PROBE_SENTINEL="$(awk -F'"' '/^PROBE_SENTINEL=/ {print $2; exit}' "${RUNNER_ABS}")"
if [ -n "${PROBE_SENTINEL}" ] && grep -Fq -- "${PROBE_SENTINEL}" "${PROBE_ABS}"; then
  ok "sentinel が解決層と probe で一致する（${PROBE_SENTINEL}）"
else
  bad "sentinel が解決層と probe で一致しません（解決層側=${PROBE_SENTINEL:-取得失敗}）"
fi
# フラグ probe への退行を静的にも塞ぐ。偽 shim 側は実行証明を要求する形で同じ退行を
# 動的に赤くするが、静的な針も置いて「なぜ戻してはいけないか」を実装の隣に残す。
# **コメント行に一致させない**（行頭が `#` の行は除く）。解決層の冒頭は「なぜフラグを
# 使わないか」を旧コードの形を引用しながら説明しているので、素朴な固定文字列一致だと
# その解説そのものが検査を赤くする。
if grep -Eq -- '^[[:space:]]*[^#[:space:]].*"\$@"[[:space:]]+--version' "${RUNNER_ABS}"; then
  bad "候補判定がフラグ probe へ戻っています（外側のラッパーがフラグを消費して偽陽性になります。Issue #932）"
else
  ok "候補判定にフラグ probe（\"\$@\" --version）がコード行として残っていない"
fi
# probe の中身も固定する。判定の本体はトークンだが、probe が同梱ゲートと同じ土台
# （型注釈 + node 互換の実行系）を要求していることが、「probe は通ってもゲート本体で
# 初めて失敗する候補」を probe の時点で落とす条件になっている。ここが静的に守られて
# いないと、注釈や実行系の確認を「不要な記述の整理」で落とした瞬間に、どのゲートも
# 赤くならないまま条件が消える。
# 型の綴りを列挙しない（ERE のブラケット内はバックスラッシュがエスケープにならないため、
# 文字クラスで型を書き並べると `\]` の扱いでクラスが途中で閉じる。実測でこの罠を踏んだ）。
# 「`const <名前>:` が `=` の前に型注釈を持つ」ことだけを見る。
if grep -Eq -- '^const [A-Za-z_][A-Za-z0-9_]*:[^=]+=' "${PROBE_ABS}" \
  && grep -Fq -- 'versions?.node' "${PROBE_ABS}"; then
  ok "probe が型注釈と node 互換実行系の確認を保っている（ゲートと同じ土台を要求する）"
else
  bad "probe から型注釈または node 実行系の確認が失われています（変換系・node 組み込みを持たない実行系を probe で落とせなくなります。Issue #932）"
fi
# sentinel は probe のソースに平文で含まれるため、それだけを探す判定では「渡された
# ファイルの内容を表示するだけ」の候補も通る。probe が実行時にトークンを読むこと
# （= ソースに無い値を出せること）が偽陽性を弾く仕組みの本体なので、静的にも固定する。
if grep -Fq -- 'ACE_RUN_TS_PROBE_TOKEN' "${PROBE_ABS}" \
  && grep -Fq -- 'ACE_RUN_TS_PROBE_TOKEN' "${RUNNER_ABS}"; then
  ok "probe が使い捨てトークンを実行時に読み、解決層がそれを渡している"
else
  bad "使い捨てトークンの受け渡しが失われています（sentinel の平文一致だけでは内容表示だけの候補が通ります。Issue #932）"
fi

echo
echo "== runner 解決の挙動 =="

# PATH を空にすると `bash` 自身も引けなくなる（実測: rc=127 で 7 件が「別の理由で赤」に
# なった）。PATH を差し替える**前**に絶対パスへ解決しておく。
BASH_ABS="$(command -v bash || true)"
if [ ! -x "${BASH_ABS}" ]; then
  bad "bash の絶対パスを解決できません（runner 解決の検査が成立しません）"
  BASH_ABS="/bin/bash"
fi

EMPTY_BIN="${SANDBOX}/emptybin"
mkdir -p "${EMPTY_BIN}"
SHIM_LOG="${SANDBOX}/shim.log"

# 偽 runner は **argc と 1 引数ずつ**を出す。`$*` の連結だけだと、`"$TS_SCRIPT"` の
# 引用が外れて空白パスが 2 引数へ割れても同じ文字列になり、引用の退行を判別できない
# （レビュー指摘。連結出力のままでは偽陽性）。shebang に env を使わない — PATH を
# 空にすると env が bash を引けない。
_write_shim() { # <出力パス> <ラベル> [先頭で捨てる語数]
  local out="$1" label="$2" strip="${3:-0}"
  {
    printf '#!/bin/bash\n'
    printf 'printf "CALLED %s %%s\\n" "$*" >> "%s"\n' "$label" "${SHIM_LOG}"
    if [ "${strip}" -gt 0 ]; then
      printf 'shift %s 2>/dev/null || true\n' "${strip}"
    fi
    # 解決層は候補を「本番と同じ `<候補> <script.ts>` の形で probe を走らせ、渡した
    # 使い捨てトークンが独立した 1 行で返るか」で判定する（Issue #932）。偽 runner は
    # probe を渡されたら**環境変数のトークンを読んで sentinel 行を出し** exit 0 する —
    # 実 tsx が probe を実行した結果に相当する。**内容をそのまま出す形にしてはならない**:
    # それは「実行せずに通る」候補の模擬になり、下の陰性対照（内容表示だけの候補を
    # 拒否する）と矛盾する。
    # probe はどの引数位置にも現れうる（`FF_ACE_TS_RUNNER="tsx --filter*"` のように前置語が
    # ある形）ので全引数を見る。FAKE_TSX_RC は「ゲート本体の終了コード」の模擬なので
    # probe には適用しない。フラグ probe（`--version`）へ戻す退行では probe が渡されず
    # トークン行が出ないため、解決順の検査群がまとめて赤くなる。
    printf 'for _p in "$@"; do case "${_p##*/}" in %s) printf "%%s\\n" "%s:${ACE_RUN_TS_PROBE_TOKEN:-}"; exit 0 ;; esac; done\n' "${PROBE_BASE}" "${PROBE_SENTINEL}"
    printf 'printf "RAN %s argc=%%s\\n" "$#"\n' "$label"
    printf 'for _a in "$@"; do printf "ARG[%%s]\\n" "$_a"; done\n'
    printf 'exit "${FAKE_TSX_RC:-0}"\n'
  } > "${out}"
  chmod +x "${out}"
}

# workspace 側にだけある tsx（上位ディレクトリ探索の対象）
FAKE_WS="${SANDBOX}/ws root"
mkdir -p "${FAKE_WS}/node_modules/.bin" "${FAKE_WS}/packages/docs"
_write_shim "${FAKE_WS}/node_modules/.bin/tsx" tsx
printf 'export {};\n' > "${FAKE_WS}/stub gate.ts"
STUB_TS="${FAKE_WS}/stub gate.ts"

# PATH 候補の shim 置き場。使いたい候補だけを都度リンクする。
SHIM_SRC="${SANDBOX}/shimsrc"
mkdir -p "${SHIM_SRC}"
_write_shim "${SHIM_SRC}/tsx" tsx
_write_shim "${SHIM_SRC}/pnpm" pnpm 2   # `pnpm exec tsx …` の先頭 2 語を捨てる
_write_shim "${SHIM_SRC}/yarn" yarn 2   # `yarn exec tsx …`
_write_shim "${SHIM_SRC}/npx"  npx  2   # `npx --yes tsx …`

# <cwd> <PATH> <名前=値...> -- <resolver 引数...> を受け、RES_OUT / RES_RC に入れる。
_bin_with() { # <置きたい shim 名...> -> PATH に使うディレクトリ
  # `bin.$$.$RANDOM` では 1 run 内で `$$` が固定、`$RANDOM` は 0–32767 なので衝突しうる。
  # 衝突すると**既に populate されたディレクトリを再利用する** — 本 suite は
  # `_bin_with npx` で得たディレクトリへ eater yarn / printer を書き込むため、衝突した
  # 後続ケースへそれが漏れて再現しない赤を作る。mktemp に任せる。
  local dir
  dir="$(mktemp -d "${SANDBOX}/bin.XXXXXX")" || { echo "✗ shim ディレクトリを作成できません" >&2; exit 1; }
  local n
  for n in "$@"; do cp "${SHIM_SRC}/${n}" "${dir}/${n}"; done
  printf '%s' "${dir}"
}
# 環境変数は `env` を使わず前置代入で渡す（差し替えた PATH に env は無い。実測: rc=127）。
# 汎用の「NAME=VALUE 文字列」を eval する形も採らない — 値に空白を含む
# FF_ACE_TS_RUNNER が語分割され、検査したい値と別物になる。
RUN_RUNNER=""
RUN_FAKE_RC=0
_run() { # <cwd> <PATH> <resolver 引数...>
  local cwd="$1" path="$2"
  shift 2
  : > "${SHIM_LOG}"
  RES_RC=0
  RES_OUT="$(cd "${cwd}" && PATH="${path}" FF_ACE_TS_RUNNER="${RUN_RUNNER}" \
    FAKE_TSX_RC="${RUN_FAKE_RC}" "${BASH_ABS}" "${RUNNER_ABS}" "$@" 2>&1)" || RES_RC=$?
  RUN_RUNNER=""
  RUN_FAKE_RC=0
}

# --- 引数境界（引用の退行を判別できる形で測る）-------------------------------
_run "${FAKE_WS}/packages/docs" "$(_bin_with pnpm yarn npx)" "${STUB_TS}" "arg with space" plain
case "${RES_OUT}" in
  *"runner=${FAKE_WS}/node_modules/.bin/tsx"*)
    ok "workspace 側の node_modules/.bin/tsx を上位ディレクトリから解決する" ;;
  *)
    bad "workspace 側の tsx を解決できません（出力: ${RES_OUT}）" ;;
esac
case "${RES_OUT}" in
  *"RAN tsx argc=3"*) ok "引数は 3 個のまま渡る（空白を含むパス・引数が語分割されない）" ;;
  *)                  bad "argc が 3 でありません（引用の退行。出力: ${RES_OUT}）" ;;
esac
case "${RES_OUT}" in
  *"ARG[${STUB_TS}]"*) ok "スクリプトパスが単一引数として届く" ;;
  *)                   bad "スクリプトパスが単一引数で届いていません（出力: ${RES_OUT}）" ;;
esac
case "${RES_OUT}" in
  *"ARG[arg with space]"*) ok "空白を含む後続引数も単一引数として届く" ;;
  *)                       bad "後続引数が語分割されています（出力: ${RES_OUT}）" ;;
esac
# 上位 .bin が見つかったら package manager 候補は起動しない（解決順）
# 解決に使われた .bin/tsx 自身も log を書くので、package manager だけを見る。
case "$(cat "${SHIM_LOG}")" in
  *"CALLED pnpm"*|*"CALLED yarn"*|*"CALLED npx"*)
    bad "上位 .bin で解決できたのに package manager 候補が起動しました（$(cat "${SHIM_LOG}")）" ;;
  *)
    ok "上位 .bin で解決できたら pnpm / yarn / npx は起動しない（解決順）" ;;
esac

# --- 終了コードの伝播 --------------------------------------------------------
RUN_FAKE_RC=7
_run "${FAKE_WS}/packages/docs" "${EMPTY_BIN}" "${STUB_TS}"
if [ "${RES_RC}" -eq 7 ]; then
  ok "検証スクリプトの非ゼロ終了をそのまま伝播する（rc=7）"
else
  bad "非ゼロ終了が伝播していません（rc=${RES_RC} / 期待 7）"
fi

# --- 解決順（PATH / pnpm / yarn / npx）---------------------------------------
# 上位 .bin を持たない cwd を使う。SANDBOX 直下なら node_modules は無い。
NOBIN="${SANDBOX}/nobin"
mkdir -p "${NOBIN}"

_run "${NOBIN}" "$(_bin_with tsx pnpm yarn npx)" "${STUB_TS}"
case "${RES_OUT}" in
  *"runner=tsx"*) ok "PATH 上の tsx が package manager より先に選ばれる" ;;
  *)              bad "PATH の tsx が選ばれていません（出力: ${RES_OUT}）" ;;
esac

_run "${NOBIN}" "$(_bin_with pnpm yarn npx)" "${STUB_TS}"
case "${RES_OUT}" in
  *"runner=pnpm exec tsx"*) ok "tsx 不在なら pnpm exec tsx（workspace 経路。本 Issue の実測ケース）" ;;
  *)                        bad "pnpm exec tsx が選ばれていません（出力: ${RES_OUT}）" ;;
esac

_run "${NOBIN}" "$(_bin_with yarn npx)" "${STUB_TS}"
case "${RES_OUT}" in
  *"runner=yarn exec tsx"*) ok "pnpm 不在なら yarn exec tsx へ進む" ;;
  *)                        bad "yarn exec tsx が選ばれていません（出力: ${RES_OUT}）" ;;
esac

_run "${NOBIN}" "$(_bin_with npx)" "${STUB_TS}"
case "${RES_OUT}" in
  *"runner=npx --yes tsx"*) ok "ローカル候補が全滅したときだけ npx --yes tsx へ落ちる" ;;
  *)                        bad "npx --yes tsx が選ばれていません（出力: ${RES_OUT}）" ;;
esac

# --- ラッパーがフラグを消費する候補を採用しない（Issue #932）------------------
# yarn 1.x を模した shim。`--version` を**自分で消費して** exit 0 を返すが、実際の
# `exec` では binary を解決できない。フラグ probe だとこれが「使える候補」に見え、
# 選ばれた後に必ず失敗する（実測: `yarn exec tsx --version` → yarn 自身の version を
# 出して成功 / `yarn exec tsx <script>` → binary 不在で失敗。ACE の必須 3 ゲートが
# まとめて到達不能になった）。
EATER_BIN="$(_bin_with npx)"
{
  printf '#!/bin/bash\n'
  printf 'printf "CALLED yarn %%s\\n" "$*" >> "%s"\n' "${SHIM_LOG}"
  printf 'case "$*" in\n'
  printf '  *--version*) echo "1.22.22"; exit 0 ;;\n'
  printf 'esac\n'
  printf 'echo "error: cannot find the binary tsx" >&2\n'
  printf 'exit 1\n'
} > "${EATER_BIN}/yarn"
chmod +x "${EATER_BIN}/yarn"

_run "${NOBIN}" "${EATER_BIN}" "${STUB_TS}"
case "${RES_OUT}" in
  *"runner=yarn exec tsx"*)
    bad "フラグを消費するだけの yarn が候補として採用されました（Issue #932 の退行）" ;;
  *"runner=npx --yes tsx"*)
    ok "フラグを消費するだけの候補は採用せず、実際に走る候補へ進む（Issue #932）" ;;
  *)
    bad "解決に失敗しました（rc=${RES_RC} / 出力: ${RES_OUT}）" ;;
esac
case "$(cat "${SHIM_LOG}")" in
  *"CALLED yarn"*) ok "yarn 候補も実際に起動して確かめている（存在だけで飛ばしていない）" ;;
  *)               bad "yarn 候補が起動されていません（探索順が変わった可能性。ログ: $(cat "${SHIM_LOG}")）" ;;
esac
case "${RES_RC}:${RES_OUT}" in
  "0:"*"RAN npx argc=1"*) ok "採用した候補で同梱スクリプトが実際に走る（rc=0）" ;;
  *)                      bad "採用後の実行が成立していません（rc=${RES_RC} / 出力: ${RES_OUT}）" ;;
esac

# --- 実行せずに sentinel を出す候補を採用しない（Issue #932 / クロスモデルレビュー指摘）---
# sentinel は probe の**ソースに平文で含まれる**。したがって「渡されたファイルの内容を
# 表示するだけ」の候補は、実行していないのに sentinel を出せる。その候補は続く本番実行でも
# ゲートを実行せず内容を表示して exit 0 するため、**ゲートが走らないまま緑**になる。
# 使い捨てトークンはソースのどこにも無いので、実行しない候補には出せない。
PRINTER_BIN="$(_bin_with npx)"
{
  printf '#!/bin/bash\n'
  printf 'printf "CALLED printer %%s\\n" "$*" >> "%s"\n' "${SHIM_LOG}"
  printf 'for _p in "$@"; do if [ -f "$_p" ]; then printf "%%s\\n" "$(<"$_p")"; fi; done\n'
  printf 'exit 0\n'
} > "${PRINTER_BIN}/printer"
chmod +x "${PRINTER_BIN}/printer"
# 正しいトークン行を **stderr** へ出す候補（診断文へ紛れ込ませる形）。判定が stdout だけを
# 見ていることを測る — stderr を混ぜると、エラー文に sentinel を含む候補が通ってしまう。
{
  printf '#!/bin/bash\n'
  printf 'printf "CALLED errtoken %%s\\n" "$*" >> "%s"\n' "${SHIM_LOG}"
  printf 'printf "%%s\\n" "%s:${ACE_RUN_TS_PROBE_TOKEN:-}" >&2\n' "${PROBE_SENTINEL}"
  printf 'exit 0\n'
} > "${PRINTER_BIN}/errtoken"
chmod +x "${PRINTER_BIN}/errtoken"

RUN_RUNNER="printer"
_run "${NOBIN}" "${PRINTER_BIN}" "${STUB_TS}"
if [ "${RES_RC}" -eq 3 ]; then
  ok "probe のソースを表示するだけの候補は採用しない（実行していないので使い捨てトークンを出せない）"
else
  bad "内容表示だけの候補が採用されました — ゲートを実行しないまま緑になります（rc=${RES_RC} / 出力: ${RES_OUT}）"
fi

RUN_RUNNER="errtoken"
_run "${NOBIN}" "${PRINTER_BIN}" "${STUB_TS}"
if [ "${RES_RC}" -eq 3 ]; then
  ok "トークン行を stderr へ出すだけの候補は採用しない（判定は stdout のみ）"
else
  bad "stderr のトークンが実行証明として数えられました（rc=${RES_RC} / 出力: ${RES_OUT}）"
fi

# 拒否した候補で止まらず、次の候補へ進んで実際にゲートが走ること（fail-closed へ倒しすぎない）。
FALLBACK_BIN="$(_bin_with npx)"
cp "${PRINTER_BIN}/printer" "${FALLBACK_BIN}/tsx"
_run "${NOBIN}" "${FALLBACK_BIN}" "${STUB_TS}"
case "${RES_OUT}" in
  *"runner=tsx"*)
    bad "内容表示だけの tsx が採用されました（Issue #932 の別経路）" ;;
  *"runner=npx --yes tsx"*)
    ok "実行証明に失敗した候補を捨てて次の候補へ進む" ;;
  *)
    bad "解決に失敗しました（rc=${RES_RC} / 出力: ${RES_OUT}）" ;;
esac
case "${RES_RC}:${RES_OUT}" in
  "0:"*"RAN npx argc=1"*) ok "フォールバック先で同梱スクリプトが実際に走る（rc=0）" ;;
  *)                      bad "フォールバック後の実行が成立していません（rc=${RES_RC} / 出力: ${RES_OUT}）" ;;
esac

# --- 明示指定（FF_ACE_TS_RUNNER）--------------------------------------------
# 複数語指定が argv として正しく届き、PATH の tsx より優先されること。
RUN_RUNNER="pnpm exec tsx"
_run "${NOBIN}" "$(_bin_with tsx pnpm)" "${STUB_TS}"
case "${RES_OUT}" in
  *"runner=pnpm exec tsx"*) ok "明示指定は PATH の tsx より優先される" ;;
  *)                        bad "明示指定が優先されていません（出力: ${RES_OUT}）" ;;
esac
case "${RES_OUT}" in
  *"RAN pnpm argc=1"*) ok "明示指定の複数語が argv として正しく届く（先頭 2 語を除いた残り 1 引数）" ;;
  *)                   bad "明示指定の argv が壊れています（出力: ${RES_OUT}）" ;;
esac

# 明示指定が起動できないとき、他候補へ**フォールバックしない**（PATH に動く tsx がある）。
RUN_RUNNER="definitely-not-a-runner"
_run "${NOBIN}" "$(_bin_with tsx pnpm npx)" "${STUB_TS}"
if [ "${RES_RC}" -eq 3 ]; then
  ok "明示指定が起動できなければ他候補へ倒れず fail-closed（exit 3）"
else
  bad "明示指定の失敗が他候補へフォールバックしました（rc=${RES_RC} / 出力: ${RES_OUT}）"
fi

# ワイルドカードを cwd のファイル名へ展開しない（`pnpm --filter '@scope/*'` 対策）。
GLOB_DIR="${SANDBOX}/globprobe"
mkdir -p "${GLOB_DIR}"
: > "${GLOB_DIR}/--filter-expanded"
RUN_RUNNER="tsx --filter*"
_run "${GLOB_DIR}" "$(_bin_with tsx)" "${STUB_TS}"
case "${RES_OUT}" in
  *"ARG[--filter-expanded]"*)
    bad "FF_ACE_TS_RUNNER のワイルドカードが cwd のファイル名へ展開されました（出力: ${RES_OUT}）" ;;
  *'ARG[--filter*]'*)
    ok "FF_ACE_TS_RUNNER のワイルドカードは展開されずリテラルのまま渡る" ;;
  *)
    bad "明示 runner が起動していません（rc=${RES_RC} / 出力: ${RES_OUT}）" ;;
esac

# 実行ファイルパスに空白があると語分割で壊れる。黙って別 runner へ倒れず、理由を出して止まる。
RUN_RUNNER="${FAKE_WS}/node_modules/.bin/tsx"
_run "${NOBIN}" "$(_bin_with tsx)" "${STUB_TS}"
case "${RES_RC}:${RES_OUT}" in
  "3:"*"空白で語分割されます"*)
    ok "空白を含む runner パスの明示指定は理由つきで fail-closed（exit 3）" ;;
  *)
    bad "空白を含む runner 指定が exit 3 + 語分割の説明になっていません（rc=${RES_RC} / 出力: ${RES_OUT}）" ;;
esac

# --- runner 不在 / 入力検証 --------------------------------------------------
_run "${NOBIN}" "${EMPTY_BIN}" "${STUB_TS}"
if [ "${RES_RC}" -eq 3 ]; then
  ok "runner 不在は fail-closed で停止する（exit 3）"
else
  bad "runner 不在の終了コードが ${RES_RC}（期待 3）— ゲートを飛ばして先へ進む経路になります"
fi
case "${RES_OUT}" in
  *"手作業での照合や、別 version の plugin へのフォールバックで代替しない"*)
    ok "runner 不在の案内が手作業照合・別 version fallback を明示的に禁じている" ;;
  *)
    bad "runner 不在の案内に禁止事項がありません（出力: ${RES_OUT}）" ;;
esac

# 入力の誤りは runner 探索より**前**に止める（誤って npx のネットワーク取得へ進まない）。
_run "${NOBIN}" "$(_bin_with tsx)"
if [ "${RES_RC}" -eq 2 ]; then
  ok "引数なしは usage を出して exit 2（runner 探索前に止まる）"
else
  bad "引数なしの終了コードが ${RES_RC}（期待 2）"
fi
_run "${NOBIN}" "$(_bin_with tsx)" "${SANDBOX}/does-not-exist.ts"
case "${RES_RC}:${RES_OUT}" in
  "2:"*"同梱スクリプトを読み取れません"*)
    ok "読み取れないスクリプトパスは案内つきで exit 2" ;;
  *)
    bad "不在スクリプトの扱いが exit 2 + 案内になっていません（rc=${RES_RC} / 出力: ${RES_OUT}）" ;;
esac

# --- 空白を含む plugin path から起動しても壊れない ---------------------------
SPACED_PLUGIN="${SANDBOX}/plugin with space/scripts"
mkdir -p "${SPACED_PLUGIN}"
cp "${RUNNER_ABS}" "${SPACED_PLUGIN}/ace-run-ts.sh"
# probe も隣へ置く。解決層は自身の隣から probe を引くので、片方だけ配布された
# インストールでは（runner 不在ではなく）破損として止まる（Issue #932）。
cp "${PROBE_ABS}" "${SPACED_PLUGIN}/${PROBE_BASE}"
SP_RC=0
SP_OUT="$(cd "${FAKE_WS}/packages/docs" && PATH="${EMPTY_BIN}" \
  "${BASH_ABS}" "${SPACED_PLUGIN}/ace-run-ts.sh" "${STUB_TS}" 2>&1)" || SP_RC=$?
case "${SP_OUT}:${SP_RC}" in
  *"RAN tsx argc=1"*":0") ok "空白を含む plugin path から起動しても解決・実行できる" ;;
  *) bad "空白を含む plugin path で失敗（rc=${SP_RC} / 出力: ${SP_OUT}）" ;;
esac

# probe が隣に無いインストールは「runner 不在」ではなく**破損**として止まる（Issue #932）。
# PATH には動く tsx を置く — 破損の判定が候補探索より前に効くことを、成功しうる状況で測る。
BROKEN_PLUGIN="${SANDBOX}/broken plugin/scripts"
mkdir -p "${BROKEN_PLUGIN}"
cp "${RUNNER_ABS}" "${BROKEN_PLUGIN}/ace-run-ts.sh"
BR_RC=0
BR_OUT="$(cd "${NOBIN}" && PATH="$(_bin_with tsx)" \
  "${BASH_ABS}" "${BROKEN_PLUGIN}/ace-run-ts.sh" "${STUB_TS}" 2>&1)" || BR_RC=$?
case "${BR_RC}:${BR_OUT}" in
  "2:"*"probe スクリプトを読み取れません"*)
    ok "probe が隣に無いインストールは破損として exit 2（runner 不在と混同しない）" ;;
  *)
    bad "probe 不在の扱いが exit 2 + 破損の案内になっていません（rc=${BR_RC} / 出力: ${BR_OUT}）" ;;
esac

# 0 バイトの probe も破損として扱う（レビュー指摘）。部分同期・中断したダウンロードで
# 起きる形で、読み取り可能性（-r）だけを見ていると通過し、何も出力しないまま全候補が
# 落ちて「runner が見つかりません / tsx を入れてください」になる — まさに上の exit 2 が
# 防ぐために作られた誤診へ戻る。PATH には動く tsx を置いて測る（成功しうる状況で
# 破損判定が候補探索より前に効くことを確かめる）。
EMPTYPROBE_PLUGIN="${SANDBOX}/emptyprobe plugin/scripts"
mkdir -p "${EMPTYPROBE_PLUGIN}"
cp "${RUNNER_ABS}" "${EMPTYPROBE_PLUGIN}/ace-run-ts.sh"
: > "${EMPTYPROBE_PLUGIN}/${PROBE_BASE}"
EP_RC=0
EP_OUT="$(cd "${NOBIN}" && PATH="$(_bin_with tsx)" \
  "${BASH_ABS}" "${EMPTYPROBE_PLUGIN}/ace-run-ts.sh" "${STUB_TS}" 2>&1)" || EP_RC=$?
case "${EP_RC}:${EP_OUT}" in
  "2:"*"probe スクリプトを読み取れません"*)
    ok "空の probe も破損として exit 2（tsx 導入案内の誤診へ倒れない）" ;;
  *)
    bad "空の probe が破損扱いになっていません（rc=${EP_RC} / 出力: ${EP_OUT}）" ;;
esac

echo
if [ "${FAIL}" -gt 0 ]; then
  echo "✗ ace-run-ts verify: ${FAIL} 件失敗" >&2
  exit 1
fi
echo "✓ ace-run-ts verify: 全 ${PASS} 件 pass"
