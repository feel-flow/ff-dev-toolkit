#!/usr/bin/env bash
#
# アダプタが渡す sandbox 引数と、CLI が実際に受け付ける値との契約検査（Issue #403）。
#
# 潰している事故: **アダプタが、その CLI が受け付けない sandbox 値を渡すこと**。
# 実例（develop で長期間生きていた）— codex アダプタが implement に対して
# `--sandbox network-off` を渡していた。codex の `--sandbox` が取るのは
# read-only | workspace-write | danger-full-access の 3 値だけなので、
# codex は**引数解析の段階で rc=2**、CLI 本体は 1 バイトも動かない。
# codex-cli は implement の既定ラインナップで refactoring 観点を持つため、
# 素の `multi-agent.sh --task implement` は毎回その観点を丸ごと失っていた。
#
# なぜ既存 suite で緑だったか: adapter-model-args も adapter-prompt-guard も
# stub CLI が**任意の argv を受け付ける**ため、enum 違反の値が一度も評価されない。
# adapter-model-args は grok の sandbox 値をリテラルで pin しているが、それは
# 「今の値」を固定するだけで、「その値を CLI が受け付けるか」は見ていない。
#
# 検査は 2 層。層を分けるのは、片方だけでは歯が生えないため:
#
#   層 1（実 CLI 不要・常に走る）— 形と値の契約
#     stub CLI で argv を実測し、CLI ごとの「--sandbox の形」（値つき / boolean
#     単独 / そもそも渡さない）と、task-type ごとの値を固定する。さらに値つきの
#     CLI については、その値が下の宣言 enum の要素であることを検査する。
#     ※ これだけだと「宣言 enum に network-off と書けば緑」になる。だから層 2 が要る。
#
#   層 2（実 CLI があるときだけ・不在は ○ skip として出力に残す）— 宣言の腐り検出
#     照合の向きは **「宣言 enum ⊆ 実 CLI の enum」**。アダプタ値ではなく
#     *宣言側* を実 CLI に突き合わせる。これで宣言を書き換えて緑にする逃げ道が
#     塞がり、CLI 側が enum を変えた日にも気づける。
#
# 層 2 の穴を 1 つ塞いである（レビューで実測された）: **宣言 enum を空にする**と
# 空集合は自明に部分集合なので照合ループが 0 回まわり、肯定を出力してしまう。
# しかも空文字は grok の「enum 非公表」マーカーとして正当に使われているので、
# 無効化の編集が慣用的に見える。そこで「どの CLI が live 照合可能か」を
# enum_live_checkable として**別途宣言**し、可能なはずの CLI の enum が空なら
# 落とす（逆に不可能な CLI の enum が埋まっていても落とす — 実 CLI で裏を取れない
# 手書きリストで層 1 を通すのは、この suite が避けている偽の確信そのもの）。
#
# 実 CLI を起動するのは `--help`、`codex sandbox`（書き込み境界の再測。モデルを
# 呼ばずローカル完結）、`codex exec --strict-config`（設定キー名の認識確認。
# 使い捨て CODEX_HOME で走らせるので認証が無く、モデルに到達する前に終わる）だけ。
# ネットワークも課金もエージェント実行も伴わない。
#
# 宣言 enum の provenance（転記元）は下のテーブルにコメントで残す。ここは
# 「こうあってほしい値」ではなく **CLI 自身の出力の転記** であり、書き換えてよいのは
# 実 CLI の出力が変わったときだけ。層 2 がその転記を機械照合する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
PERSPECTIVE="$PLUGIN_ROOT/scripts/perspectives/review/code-review.md"
SUITE_NAME="adapter-sandbox-contract"

echo "== アダプタの sandbox 契約 =="

# perspective の不在は**環境都合ではなくリポジトリの不変条件の破れ**なので skip に
# しない。skip にすると、観点ファイルを移動しただけで本 suite と adapter-model-args が
# そろって黙って no-op へ落ち、run-all は緑のまま終わる。
if [ ! -f "$PERSPECTIVE" ]; then
  echo "✗ ${SUITE_NAME} verify: perspective ファイルが見つかりません（環境都合ではなくリポジトリ側の不整合。skip せず失敗させます）: $PERSPECTIVE" >&2
  exit 1
fi

if ! git -C "$PLUGIN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "○ skip: git リポジトリ外のため実行できません（本 suite の検査は1件も実行されていません）"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-adapter-sandbox.XXXXXX" 2>/dev/null)" || WORK=""
if [ -z "$WORK" ]; then
  echo "○ skip: 一時ディレクトリを作成できません（本 suite の検査は1件も実行されていません）"
  exit 0
fi
# 終了ステータスを**保存してから**掃除する。`trap 'rm -rf "$WORK"' EXIT` と書くと、
# トラップ最終コマンド（rm）の成功ステータスが suite の終了ステータスを上書きし、
# set -e / set -u で途中死しても **rc=0** で終わる（実測: `local a=$1 b=${a}` の
# unbound variable で死んだ実行が rc=0 を返し、run-all は passed に数えた）。
# 検証の途中で死んだ実行が「全部通った」と読まれるのは、この suite が潰している
# クラスそのものなので、ここで取りこぼさない。
#
# ステータスの保存だけでは足りない。set -u による死ではトラップに入った時点の `$?` が
# **0** になるため（実測）、`exit $?` でも 0 のまま出ていく。末尾に到達したかどうかを
# センチネルで持ち、到達していないのに 0 なら 1 へ倒す。
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
SKIP=0
LAYER2_RUN=0
LAYER2_TOTAL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
# skip は「検査しなかった」ことを出力に残すためのもので、PASS には数えない。
# 数えてしまうと「実 CLI 不在の環境で全部緑」が「検証済み」と読めてしまう。
# 行頭ではなくインデントして出すのは run-all の**suite 全体 skip** マーカー
# （行頭 ○ skip）と衝突させないため — 部分 skip で suite 全体を skip 扱いにしない。
skipped() { echo "  ○ skip: $1"; SKIP=$((SKIP + 1)); }

# ── 宣言テーブル（provenance つき） ────────────────────────────────────────────
#
# sandbox_shape <cli>   — アダプタが渡す --sandbox の形
#   value    : `--sandbox <値>`（次の引数が値）
#   boolean  : `--sandbox` 単独（値を取らない）
#   none     : --sandbox を渡さない
#
# declared_enum <cli>   — その CLI が受け付ける値の集合（value 形のみ）
# enum_live_checkable <cli> — 実 CLI の出力と機械照合できるか（yes / no）
#   この 2 つは対で意味を持つ。yes なら declared_enum は非空でなければならず
#   （空集合は自明に部分集合なので層 2 が無検査で緑になる）、no なら空でなければ
#   ならない（裏を取れない手書きリストで層 1 を通さない）。両方向を下で検査する。
#
# provenance:
#   codex-cli   codex-cli 0.144.5 / `codex exec --help`:
#                 -s, --sandbox <SANDBOX_MODE>
#                     [possible values: read-only, workspace-write, danger-full-access]
#               → live 照合可能。
#   grok-cli    grok 1.0.0 / `grok --help`:
#                 --sandbox <PROFILE>  Sandbox profile for filesystem and network access
#               → `[possible values:]` を公表しない。加えて grok は
#                 ~/.grok/sandbox.toml で**任意の名前のカスタムプロファイル**を
#                 定義できる（不正名エラー自身がその書き方を案内する。実測:
#                 `grok --sandbox definitely-not-a-profile -p hi` が
#                 "Define it in ~/.grok/sandbox.toml" と "Refusing to start with
#                 its protections missing." を出して起動を拒否）。つまり閉じた
#                 集合が存在しないので、部分集合照合はそもそも適切な検査ではない。
#                 ここを空にしているのは「grok は検証済み」ではなく
#                 「grok は照合できていない」という意味。層 2 では代わりに
#                 「公表していないという前提がまだ成り立つか」を検査する。
#   gemini-cli  gemini 0.50.0 / `gemini --help`:
#                 -s, --sandbox  Run in sandbox?  [boolean]
#               → 値を取らない。enum の概念が無い。層 2 で [boolean] を再確認する。
#   claude-code / copilot-cli
#               → --sandbox という概念を持たない。claude-code の書き込みゲートは
#                 --allowed-tools（adapter-common.sh の get_allowed_tools）。
#                 層 2 で「まだ --sandbox を持たない」ことを再確認する。
sandbox_shape() {
  case "$1" in
    claude-code) echo "none" ;;
    codex-cli)   echo "value" ;;
    copilot-cli) echo "none" ;;
    gemini-cli)  echo "boolean" ;;
    grok-cli)    echo "value" ;;
    *)           echo "" ;;
  esac
}

declared_enum() {
  case "$1" in
    codex-cli) echo "read-only workspace-write danger-full-access" ;;
    grok-cli)  echo "" ;;
    *)         echo "" ;;
  esac
}

enum_live_checkable() {
  case "$1" in
    codex-cli) echo "yes" ;;
    grok-cli)  echo "no" ;;
    *)         echo "no" ;;
  esac
}

adapter_file() {
  case "$1" in
    claude-code) echo "claude-code-adapter.sh" ;;
    codex-cli)   echo "codex-cli-adapter.sh" ;;
    copilot-cli) echo "copilot-cli-adapter.sh" ;;
    gemini-cli)  echo "gemini-cli-adapter.sh" ;;
    grok-cli)    echo "grok-cli-adapter.sh" ;;
    *)           echo "" ;;
  esac
}

# 起動されるべき実行ファイル名。stub は自分の名前を記録するので、アダプタが
# 別の CLI を起動する取り違えを検出できる（PATH 先頭に stub を置く方式では、
# stub を 1 つ置き忘れると**本物の CLI** に到達しうる — その形もここで落ちる）。
cli_binary() {
  case "$1" in
    claude-code) echo "claude" ;;
    codex-cli)   echo "codex" ;;
    copilot-cli) echo "copilot" ;;
    gemini-cli)  echo "gemini" ;;
    grok-cli)    echo "grok" ;;
    *)           echo "" ;;
  esac
}

DECLARED_CLIS="claude-code codex-cli copilot-cli gemini-cli grok-cli"

# 変数名を DECLARED_CLIS にしているのは必須の回避で、好みではない。共有 parser
# （tests/lib/cli-registry-parser.sh）は **`ALL_CLIS` というグローバル名を自分で使う**
# — multi-agent.sh 側の同名変数を読み出して公開するため。こちらの一覧を `ALL_CLIS` と
# 名付けると、source した瞬間にレジストリの値で上書きされ、下の突き合わせが
# 「レジストリとレジストリ自身」の比較になって**常に一致する**（実測: 一覧から
# grok-cli を削っても ✓ のまま緑だった）。名前を分けて衝突そのものを無くす。
#
# DECLARED_CLIS はリテラルで書く（宣言テーブルとの突き合わせを兼ねる）が、**実レジストリと
# 一致していること**は機械で確かめる。ここが自由だと、CLI を 1 つ追加したときに
# この suite だけが黙って無検査のまま緑を返す — cli-registry-completeness が潰している
# 「手で維持する並行リストの片側だけが動く」クラスそのもの。
# multi-agent.sh は実行せず、共有 parser で case arm をデータ化して読む。
REGISTRY_PARSER="$SCRIPT_DIR/../lib/cli-registry-parser.sh"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
registry_check() {
  if [ ! -f "$REGISTRY_PARSER" ] || [ ! -f "$MULTI_AGENT" ]; then
    bad "レジストリ突き合わせの対象が見つからない（parser=${REGISTRY_PARSER} registry=${MULTI_AGENT}）"
    return
  fi
  # shellcheck disable=SC1090,SC1091 # runtime-checked repo-local shared helper
  . "$REGISTRY_PARSER"
  if ! cli_registry_load "$MULTI_AGENT"; then
    bad "multi-agent.sh の registry を安全に静的解析できない（DECLARED_CLIS の実レジストリ突き合わせが成立しない）"
    return
  fi
  if ! cli_registry_arms get_cli_adapter; then
    bad "registry から get_cli_adapter の arm 一覧を取得できない"
    return
  fi
  local registry_clis="$REPLY" c missing="" extra=""
  for c in $registry_clis; do in_set "$c" "$DECLARED_CLIS" || missing="${missing} ${c}"; done
  for c in $DECLARED_CLIS;      do in_set "$c" "$registry_clis" || extra="${extra} ${c}"; done
  if [ -n "$missing" ]; then
    bad "DECLARED_CLIS にレジストリの CLI が欠けている:${missing} — その CLI の sandbox 契約は一切検査されないまま緑になる"
  elif [ -n "$extra" ]; then
    bad "DECLARED_CLIS にレジストリに無い CLI がある:${extra} — 消し忘れた宣言はどこからも検証されない"
  else
    ok "DECLARED_CLIS が multi-agent.sh の registry と一致（${registry_clis}）"
  fi
}

# ── stub CLI ────────────────────────────────────────────────────────────────────
# argv は **1 引数 = 1 ファイル** で記録する。区切り文字で連結する方式（既存の
# adapter-model-args は <arg> 形式）は部分文字列の有無を見るには十分だが、本 suite は
# 「--sandbox の**次の**引数」を正確に切り出す必要がある。プロンプトには `<`, `>`,
# 改行が任意に含まれるため、どんな区切り文字を選んでも曖昧さが残る。ファイル境界
# ならエスケープの問題が原理的に発生しない。
#
# 起動回数と自分の名前も記録する。回数を見ないと、アダプタが 2 回起動する形
# （プリフライト + 本番など）で**最後の 1 回だけ**が採点され、1 回目の argv が
# 検査を素通りする。
mkdir -p "$WORK/bin"
for cli in claude codex gemini copilot grok; do
  {
    echo '#!/usr/bin/env bash'
    echo 'd="$ARGV_DIR"'
    echo 'n=$(cat "$d/launches" 2>/dev/null || echo 0)'
    echo 'printf "%s" "$((n + 1))" > "$d/launches"'
    echo 'printf "%s" "$(basename "$0")" > "$d/binary"'
    echo 'rm -f "$d"/arg.* 2>/dev/null'
    echo 'i=0'
    echo 'for a in "$@"; do printf "%s" "$a" > "$d/arg.$i"; i=$((i + 1)); done'
    echo 'printf "%s" "$i" > "$d/count"'
    echo 'echo "stub output"'
  } > "$WORK/bin/$cli"
  chmod +x "$WORK/bin/$cli"
done

# ── 実行環境からの分離（Issue #374 / #378） ──────────────────────────────────────
# 利用者が export している MULTI_AGENT_* で前提が崩れないよう、アダプタ起動時に
# env -u で取り除く。センチネルは抽出対象のソース群ごとに 1 本。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env MULTI_AGENT_MODEL_CLAUDE_CODE "$ADAPTERS_DIR"/*.sh

mkdir -p "$WORK/argv" "$WORK/grok-home-empty" "$WORK/staging" "$WORK/codex"

# run_adapter <cli> <task-type>
# argv を "$WORK/argv" 以下に記録する。アダプタの終了コードは見ない — grok は
# stub 実行ではサンドボックス適用の肯定確認に失敗して非 0 で終わるが、argv は
# 起動時に記録済みであり、本 suite が見たいのは「何を渡したか」だけ。
# 起動そのものの成立は ARGC / launches / binary の 3 点で別途固定する。
ARGC=0
LAUNCHES=0
BINARY=""
run_adapter() {
  local cli="$1" task="$2" adapter raw
  adapter="$(adapter_file "$cli")"
  rm -f "$WORK/argv"/arg.* "$WORK/argv/count" "$WORK/argv/launches" \
        "$WORK/argv/binary" 2>/dev/null || true
  run_isolated \
    PATH="$WORK/bin:$PATH" ARGV_DIR="$WORK/argv" CODEX_HOME="$WORK/codex" \
    GROK_HOME="$WORK/grok-home-empty" \
    bash "$ADAPTERS_DIR/$adapter" "$PERSPECTIVE" "$WORK/out.md" \
    --base HEAD --timeout 30 --task-type "$task" \
    --staging-dir "$WORK/staging" \
    --description "stub task" >"$WORK/stdout.log" 2>"$WORK/stderr.log" || true

  # ここを `[ -f X ] && ARGC=...` の形で書くと、ファイル不在時に**関数が rc=1 を
  # 返し**、set -e が呼び出し側で suite 全体を殺す。殺されるのは「CLI が起動して
  # いない」= まさに Issue #403 のクラスを診断すべき場面で、下の診断ブランチが
  # 到達不能な死んだコードになる（レビューで実測）。代入は非致命にする。
  ARGC=0; LAUNCHES=0; BINARY=""
  # count / launches は数値として使う。空・非数値のまま `[ "$i" -lt "$ARGC" ]` へ
  # 渡すと bash 3.2 は "integer expression expected" を出して**偽**に倒れ、
  # 「argv を 1 つも観測していないのに --sandbox を渡していない」という緑になる。
  # 判定不能は 0 として扱い、下の起動検査で落とす。
  if [ -f "$WORK/argv/count" ]; then
    raw="$(cat "$WORK/argv/count" 2>/dev/null || true)"
    case "$raw" in (''|*[!0-9]*) raw=0 ;; esac
    ARGC="$raw"
  fi
  if [ -f "$WORK/argv/launches" ]; then
    raw="$(cat "$WORK/argv/launches" 2>/dev/null || true)"
    case "$raw" in (''|*[!0-9]*) raw=0 ;; esac
    LAUNCHES="$raw"
  fi
  [ -f "$WORK/argv/binary" ] && BINARY="$(cat "$WORK/argv/binary" 2>/dev/null || true)"
  return 0
}

arg_at() { cat "$WORK/argv/arg.$1" 2>/dev/null || true; }

# scan_sandbox — argv 中の sandbox フラグを**全件**走査する。
#
# 「`--sandbox` と完全一致する引数」だけを探すのでは足りない。取りこぼす形が 3 つ
# あり、いずれも実害がある:
#   --sandbox=<値>  等号形。codex は受け付ける（実測）。none 宣言の CLI に
#                   これが付いても「渡していない」と緑になる
#   -s <値>         codex / gemini とも `-s, --sandbox` の短縮形（--help で確認）
#   重複            codex は `--sandbox` の重複を拒否する
#                   （実測: "the argument '--sandbox <SANDBOX_MODE>' cannot be
#                   used multiple times"）。値が両方とも妥当でも起動前に死ぬので、
#                   #403 と同じクラスの事故になる
SB_COUNT=0
SB_FORM=""
SB_VALUE=""
SB_VALUE_PRESENT=0
scan_sandbox() {
  SB_COUNT=0; SB_FORM=""; SB_VALUE=""; SB_VALUE_PRESENT=0
  local i=0 a
  while [ "$i" -lt "$ARGC" ]; do
    a="$(arg_at "$i")"
    case "$a" in
      # 短縮形に値が**密着**した形。codex は `-sbogus` を sandbox の値として解釈する
      # （実測: `codex exec -sbogus --help` → invalid value 'bogus' for '--sandbox'）。
      # ここを見落とすと `--sandbox X -sread-only` のような重複が SB_COUNT=1 に見え、
      # 実行は "cannot be used multiple times" で起動前に死ぬのに緑になる。
      # `-s` 単独は上の腕が拾うので、ここは必ず 1 文字以上続く形だけを取る
      # （`-silent` のような別フラグを飲み込まないよう、他の短縮フラグを増やすときは
      #  この腕の影響範囲を確認すること）。
      -s?*)
        SB_COUNT=$((SB_COUNT + 1))
        if [ "$SB_COUNT" -eq 1 ]; then
          SB_FORM="attached"; SB_VALUE="${a#-s}"; SB_VALUE_PRESENT=1
        fi
        ;;
      --sandbox|-s)
        SB_COUNT=$((SB_COUNT + 1))
        if [ "$SB_COUNT" -eq 1 ]; then
          SB_FORM="separate"
          if [ "$((i + 1))" -lt "$ARGC" ]; then
            SB_VALUE="$(arg_at "$((i + 1))")"; SB_VALUE_PRESENT=1
          fi
        fi
        ;;
      --sandbox=*)
        SB_COUNT=$((SB_COUNT + 1))
        if [ "$SB_COUNT" -eq 1 ]; then
          SB_FORM="inline"; SB_VALUE="${a#--sandbox=}"; SB_VALUE_PRESENT=1
        fi
        ;;
    esac
    i=$((i + 1))
  done
}

dump_argv() {
  local i=0
  while [ "$i" -lt "$ARGC" ]; do
    printf '    | [%s] %s\n' "$i" "$(arg_at "$i" | tr '\n' '/' | cut -c1-90)" >&2
    i=$((i + 1))
  done
}

# in_set <値> <空白区切りの集合>
in_set() {
  local needle="$1" item
  for item in $2; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# ── 宣言テーブル自身の整合（実 CLI 不要・無条件） ───────────────────────────────
# 層 2 を無効化する編集（宣言 enum を空にする）を、実 CLI の有無に関わらず落とす。
echo "-- 宣言テーブルの自己整合 --"
registry_check
for cli in $DECLARED_CLIS; do
  shape="$(sandbox_shape "$cli")"
  enum="$(declared_enum "$cli")"
  checkable="$(enum_live_checkable "$cli")"
  case "$shape" in
    value)
      if [ "$checkable" = "yes" ] && [ -z "$enum" ]; then
        bad "${cli}: live 照合可能と宣言しているのに declared_enum が空 — 空集合は自明に部分集合なので、層 2 の照合が 1 件も比較せずに緑になる"
      elif [ "$checkable" = "no" ] && [ -n "$enum" ]; then
        bad "${cli}: live 照合不可と宣言しているのに declared_enum が埋まっている — 実 CLI で裏を取れない手書きリストで層 1 を通すことになる"
      else
        ok "${cli}: declared_enum と enum_live_checkable が整合（checkable=${checkable}）"
      fi
      ;;
    none|boolean)
      if [ -n "$enum" ]; then
        bad "${cli}: shape=${shape} なのに declared_enum が埋まっている（値を取らない CLI に enum は無い）"
      else
        ok "${cli}: shape=${shape} に enum の宣言は無い"
      fi
      ;;
    *)
      bad "${cli}: sandbox_shape の宣言が無い（レジストリへの CLI 追加時はここも書くこと）"
      ;;
  esac
done

# ── 層 1: 形と値の契約 ───────────────────────────────────────────────────────────
#
# expect_sandbox <cli> <task-type> <期待>
#   <期待> は "none" | "boolean" | 値そのもの（value 形の CLI のとき）
COVERED=""
expect_sandbox() {
  local cli="$1" task="$2" want="$3" label="${1}/${2}" enum want_binary

  # 検査した (CLI, task-type) の組を記録する。expect_sandbox の呼び出しは
  # DECLARED_CLIS で回さずリテラルで並べている（期待値が CLI ごとに違い、リテラルの
  # 並び自体が契約の一覧として読めるため）。その代わり、**全組が網羅されたか**を
  # 末尾で照合する — でないと CLI を 1 つ追加したとき、宣言テーブルには載っていても
  # 層 1 の呼び出しを書き忘れたまま緑になる。
  COVERED="${COVERED} ${cli}/${task}"

  run_adapter "$cli" "$task"

  # argv が空 = CLI が起動していない。lacks 系の判定は真空 PASS するので、
  # 「--sandbox を渡さない」ケースでも起動の成立を先に固定する。
  if [ "$ARGC" -eq 0 ]; then
    bad "${label}: CLI が起動していない（argv 記録が空。以降の判定はすべて真空になるため打ち切り）"
    sed 's/^/    | /' "$WORK/stderr.log" >&2 2>/dev/null || true
    return
  fi

  want_binary="$(cli_binary "$cli")"
  if [ "$BINARY" != "$want_binary" ]; then
    bad "${label}: 起動された実行ファイルが '${BINARY}'（期待: ${want_binary}）— 別 CLI を起動している、または stub を経由していない"
    return
  fi
  if [ "$LAUNCHES" != "1" ]; then
    bad "${label}: CLI の起動回数が ${LAUNCHES} 回（期待: 1 回）— 記録されるのは最後の 1 回だけなので、他の起動の argv は未検査のまま素通りする"
    return
  fi

  scan_sandbox

  if [ "$want" = "none" ]; then
    if [ "$SB_COUNT" -eq 0 ]; then
      ok "${label}: --sandbox を渡さない"
    else
      bad "${label}: --sandbox を渡さないはずが ${SB_COUNT} 個渡している（form=${SB_FORM} value=${SB_VALUE}）"
      dump_argv
    fi
    return
  fi

  if [ "$SB_COUNT" -eq 0 ]; then
    bad "${label}: --sandbox が argv に無い（期待: ${want}）"
    dump_argv
    return
  fi
  if [ "$SB_COUNT" -gt 1 ]; then
    bad "${label}: --sandbox を ${SB_COUNT} 回渡している — 値が妥当でも codex は重複を拒否して起動前に死ぬ"
    dump_argv
    return
  fi

  if [ "$want" = "boolean" ]; then
    # boolean 単独。等号形は「値を取った」ことの直接の証拠。次の引数が値に見える
    # （`-` 始まりでない）場合も同じ。末尾なら次が無いので、代わりに argv 末尾が
    # そこで切れていないこと（後続フラグの存在）で真空 PASS を防ぐ。
    if [ "$SB_FORM" = "inline" ]; then
      bad "${label}: --sandbox=${SB_VALUE} の等号形で値を取っている（この CLI の --sandbox は boolean）"
      dump_argv
    elif [ "$SB_VALUE_PRESENT" -eq 0 ]; then
      bad "${label}: --sandbox が argv の末尾にある — この CLI は --sandbox の後に必ず別の引数を渡すはずで、末尾は起動行が途中で切れた形"
      dump_argv
    elif [ "${SB_VALUE#-}" != "$SB_VALUE" ]; then
      ok "${label}: --sandbox は値を取らない（次は別フラグ ${SB_VALUE}）"
    else
      bad "${label}: --sandbox が値 '${SB_VALUE}' を取っている（この CLI の --sandbox は boolean）"
      dump_argv
    fi
    return
  fi

  # value 形: 値そのものを固定する。
  if [ "$SB_VALUE_PRESENT" -eq 0 ]; then
    bad "${label}: --sandbox に値が続いていない（期待: ${want}）"
    dump_argv
  elif [ "$SB_VALUE" = "$want" ]; then
    ok "${label}: --sandbox ${want}"
  else
    bad "${label}: --sandbox の値が '${SB_VALUE}'（期待: ${want}）"
    dump_argv
  fi

  # 値が期待と違っても enum 照合は**続ける**。ここで return すると、診断が
  # 「期待のリテラルと違う」で止まり、「そもそもこの CLI はその値を受け付けず
  # 起動前に落ちる」という本質が出力に現れない。2 つは別の失敗で、後者の方が重い。
  enum="$(declared_enum "$cli")"
  if [ -z "$enum" ]; then
    skipped "${label}: enum 照合は対象外（${cli} は受け付ける値の集合を公表していない）"
  elif in_set "$SB_VALUE" "$enum"; then
    ok "${label}: '${SB_VALUE}' は ${cli} の宣言 enum の要素"
  else
    bad "${label}: '${SB_VALUE}' は ${cli} の宣言 enum {${enum}} に無い — この CLI は起動前に引数解析で落ちる"
  fi
}

echo "-- 層 1: アダプタが渡す argv の実測 --"

# claude-code / copilot-cli は --sandbox という概念を持たない。
for t in review explore implement; do
  expect_sandbox claude-code "$t" none
  expect_sandbox copilot-cli "$t" none
done

# codex: review/explore は read-only、implement は書き込みが要るので workspace-write。
# workspace-write を選ぶのは「CWD 内に閉じる」ためであって、ネットワークを開けるため
# ではない。codex 0.144.5 の実測では read-only / workspace-write はどちらも既定で
# ネットワーク遮断、danger-full-access だけが開放。つまり implement を
# danger-full-access へ寄せる退行は書き込み境界とネットワークの両方を同時に失う。
expect_sandbox codex-cli review    read-only
expect_sandbox codex-cli explore   read-only
expect_sandbox codex-cli implement workspace-write

# grok: 同じ思想のプロファイル名（workspace が CWD 書き込みを許す側）。
#
# この 3 行は tests/adapter-model-args/verify.sh の「grok: タスク種別ごとの sandbox
# プロファイル」節と**同じ契約を二重に持っている**。承知で残しているのは、向こうが
# 「argv 組み立ての一部としての sandbox」を、こちらが「CLI が受け付ける値かどうか」を
# 見ており、赤くなる理由が違うため。**プロファイル名を変えるときは両方を直すこと**
# — 片側だけ動くと、もう片側が古い契約を主張し続ける。向こうにも相互参照がある。
expect_sandbox grok-cli review    read-only
expect_sandbox grok-cli explore   read-only
expect_sandbox grok-cli implement workspace

# gemini: --sandbox は boolean。implement は成果物生成のため付けない。
expect_sandbox gemini-cli review    boolean
expect_sandbox gemini-cli explore   boolean
expect_sandbox gemini-cli implement none

# codex: implement がネットワーク遮断を明示的に pin していること。
#
# 層 2 が検査しているのは**キー名が実 CLI に認識されるか**であって、そのキーが
# 実際に argv へ載っているかではない。pin は配列で組み立てているので、組み立てが
# 黙って空になる形（heredoc の取りこぼし、set -u 下の空配列展開の書き損じ）だと
# 保護が消えたまま全検査が緑になる。argv 側からも押さえる。
#
# review/explore に載っていないことも見る。載っていたら、モード非依存の pin へ
# 変質したということ — このキーは workspace-write にしか効かないので、read-only に
# 付いていれば「効いているつもり」の設定が増えたことになる。
CODEX_NET_PIN_FLAG="-c"
CODEX_NET_PIN_VALUE="sandbox_workspace_write.network_access=false"
expect_net_pin() {
  # bash 3.2 は同一の `local` 文の中で先に代入した変数を後続の展開から見られない
  # （`local a="$1" b="${a}"` が set -u で unbound variable になる）。文を分ける。
  local task="$1" want="$2" i=0 found=0
  local label="codex-cli/${task}"
  run_adapter codex-cli "$task"
  if [ "$ARGC" -eq 0 ]; then
    bad "${label}: CLI が起動していない（network pin の判定不能）"
    return
  fi
  while [ "$i" -lt "$ARGC" ]; do
    if [ "$(arg_at "$i")" = "$CODEX_NET_PIN_FLAG" ] \
       && [ "$(arg_at "$((i + 1))")" = "$CODEX_NET_PIN_VALUE" ]; then
      found=1; break
    fi
    i=$((i + 1))
  done
  if [ "$want" = "yes" ] && [ "$found" -eq 1 ]; then
    ok "${label}: ネットワーク遮断を ${CODEX_NET_PIN_FLAG} ${CODEX_NET_PIN_VALUE} で明示している"
  elif [ "$want" = "yes" ]; then
    bad "${label}: ネットワーク遮断の pin が argv に無い — 利用者の config が network_access=true なら、何の signal も無しにネット接続された implement 実行になる"
    dump_argv
  elif [ "$found" -eq 1 ]; then
    bad "${label}: workspace-write 専用の pin が ${task} にも付いている（このキーは read-only には効かない）"
    dump_argv
  else
    ok "${label}: ネットワーク pin は付けない（workspace-write 専用のため）"
  fi
}

expect_net_pin implement yes
expect_net_pin review    no
expect_net_pin explore   no

# 未知の task-type（アダプタ直叩きで到達しうる。parse_adapter_args も
# multi-agent.sh も --task-type を allowlist で検証していない）。case の `*)`
# 既定枝は死んだコードではないので、安全側の値に落ちることを固定する。
expect_sandbox codex-cli no-such-task-type read-only
expect_sandbox grok-cli  no-such-task-type read-only

# 層 1 の網羅確認。DECLARED_CLIS × 実 task-type の全組が検査されたか。
uncovered=""
for cli in $DECLARED_CLIS; do
  for t in review explore implement; do
    in_set "${cli}/${t}" "$COVERED" || uncovered="${uncovered} ${cli}/${t}"
  done
done
if [ -z "$uncovered" ]; then
  ok "層 1: DECLARED_CLIS × 全 task-type を網羅している"
else
  bad "層 1: 未検査の組がある:${uncovered} — 宣言テーブルに載っていても expect_sandbox の呼び出しが無ければ何も検証されない"
fi

# ── 層 2: 宣言 enum ⊆ 実 CLI の enum ────────────────────────────────────────────
echo "-- 層 2: 宣言と実 CLI の突き合わせ --"

# ヘルプ出力は**一度ファイルへ受けてから**処理する。CLI から awk / grep へ直接
# パイプすると、早期 exit した下流のせいで上流の CLI が SIGPIPE で死に、pipefail 下では
# その 141 がパイプライン全体の rc になる — 「一致しなかった」と区別がつかない偽陰性で、
# しかもこの suite ではそれが「照合したうえで問題なし」に見える。
# tests/run-all/verify.sh の case 10 がパイプ入力への `grep -q*` を同じ理由で禁じている。
# ファイル経由ならパイプが無い。
#
# rc は捨てずに CAPTURE_RC へ残す。捨てると「ヘルプ書式が変わった」と
# 「CLI が壊れていて何も出せなかった」が同じ診断になり、読み手を出ていない出力の
# 比較へ送ることになる。
CAPTURE_RC=0
capture_help() {
  local out="$1"; shift
  : > "$out"
  if "$@" >"$out" 2>"${out}.err"; then CAPTURE_RC=0; else CAPTURE_RC=$?; fi
}

# help_unusable <ラベル> <出力ファイル> — 使えないヘルプなら診断を出して 0 を返す。
help_unusable() {
  local label="$1" out="$2"
  if [ "$CAPTURE_RC" -ne 0 ]; then
    bad "${label}: --help が rc=${CAPTURE_RC} で終了した（ヘルプ書式の問題ではなく CLI 側の異常。宣言を照合できないまま通さない）"
    sed 's/^/    | /' "${out}.err" >&2 2>/dev/null || true
    return 0
  fi
  if [ ! -s "$out" ]; then
    bad "${label}: --help が空を返した（照合できないまま通さない）"
    return 0
  fi
  return 1
}

# codex の `--sandbox` ブロックから [possible values: ...] を切り出す。
# 値行に到達する前に**次のオプション行**が来たらヘルプの書式が変わったということ。
# その場合は空を返し、呼び出し側が fail する（照合できないまま緑にしない）。
codex_live_enum() {
  awk '
    /^[[:space:]]*-s, --sandbox </ { inblock = 1; next }
    inblock && /\[possible values:/ {
      sub(/^.*\[possible values:[[:space:]]*/, "")
      sub(/\].*$/, "")
      gsub(/,/, " ")
      print
      exit
    }
    inblock && /^[[:space:]]*-[A-Za-z-]/ { exit }
  ' "$1"
}

LAYER2_TOTAL=$((LAYER2_TOTAL + 1))
if command -v codex >/dev/null 2>&1; then
  capture_help "$WORK/codex-help.txt" codex exec --help
  if help_unusable "codex-cli" "$WORK/codex-help.txt"; then
    :
  else
    LAYER2_RUN=$((LAYER2_RUN + 1))
    live_enum="$(codex_live_enum "$WORK/codex-help.txt" || true)"
    if [ -z "$live_enum" ]; then
      bad "codex-cli: --sandbox の [possible values:] をヘルプから抽出できない（ヘルプは取得できているので書式変更。宣言を照合できないまま通さない）"
    # 実 CLI が enum を公表しているなら、宣言側は「照合可能」でなければならない。
    #
    # これが無いと層 0 を回避できる: enum_live_checkable を no にして declared_enum を
    # 空にすると、grok の正当な形（公表しない CLI）と区別がつかず、層 0 は整合と判定し、
    # 層 2 は空集合を自明に部分集合として通す。両方の宣言はテストを書く人が触れる側
    # なので、**実 CLI の出力**という外部の権威で checkable の側を固定する。
    # grok 側は逆向き（公表し始めたら赤）を既に見ているので、これで両方向が閉じる。
    elif [ "$(enum_live_checkable codex-cli)" != "yes" ]; then
      bad "codex-cli: 実 CLI は [possible values:] を公表している（実測: ${live_enum}）のに enum_live_checkable が 'no' — この宣言だと declared_enum が空でも層 0・層 2 の両方を通ってしまう"
    # 空の宣言に対して肯定を出さない。空集合は自明に部分集合なので下のループは
    # 0 回まわり、「実測: <live_enum>」を添えた ✓ が**比較していない**まま出る。
    # 層 0 が空宣言を落とすので通常は到達しないが、肯定の文面が実際に行った比較を
    # 超えて主張する形はここに残さない。
    elif [ -z "$(declared_enum codex-cli)" ]; then
      bad "codex-cli: declared_enum が空のまま層 2 に到達した（比較対象が無いので照合は成立していない）"
    else
      missing=""
      for v in $(declared_enum codex-cli); do
        in_set "$v" "$live_enum" || missing="${missing} ${v}"
      done
      if [ -z "$missing" ]; then
        ok "codex-cli: 宣言 enum が実 CLI の [possible values:] に含まれる（実測: ${live_enum}）"
      else
        bad "codex-cli: 宣言 enum のうち${missing} が実 CLI に無い（実測: ${live_enum}）— 宣言側が腐っている"
      fi
    fi
  fi
else
  skipped "codex-cli: codex が PATH に無いため実 enum と照合していない（宣言の腐りは検出できていない）"
fi

# grok: enum を公表しないという前提そのものを検査する。公表され始めたら
# declared_enum / enum_live_checkable を見直す合図。
#
# 否定の主張なので**肯定のアンカーが要る**。「見つからなかった」を根拠に緑を出す
# 検査は、ヘルプが取れなかった・ブロックの書式が変わった・短縮フラグ形
# （`-s, --sandbox <PROFILE>`）になった、のいずれでも黙って緑になる（レビューで
# 4 通り実測）。まず `--sandbox` ブロックを**見つけられたこと**を確認し、
# 見つけられなければ失敗させる。
LAYER2_TOTAL=$((LAYER2_TOTAL + 1))
if command -v grok >/dev/null 2>&1; then
  capture_help "$WORK/grok-help.txt" grok --help
  if help_unusable "grok-cli" "$WORK/grok-help.txt"; then
    :
  else
    grok_probe="$(awk '
      /^[[:space:]]*(-[A-Za-z], )?--sandbox[ =<]/ { inblock = 1; block = 1 }
      inblock && /\[possible values:/ { values = 1; exit }
      inblock && seen && /^[[:space:]]*-[A-Za-z-]/ { exit }
      inblock { seen = 1 }
      END { printf "%d %d\n", block, values }
    ' "$WORK/grok-help.txt")"
    LAYER2_RUN=$((LAYER2_RUN + 1))
    case "$grok_probe" in
      "0 0")
        bad "grok-cli: --help に --sandbox のブロックが見つからない（フラグ名かヘルプ書式が変わった。前提を再確認できないまま通さない）" ;;
      "1 0")
        ok "grok-cli: --help の --sandbox ブロックは見つかるが受け付ける値の集合は公表していない（照合不能という前提は今も成立）" ;;
      *)
        bad "grok-cli: --help が [possible values:] を公表し始めた — declared_enum / enum_live_checkable を見直して enum 照合を有効化すること" ;;
    esac
  fi
else
  skipped "grok-cli: grok が PATH に無いため前提（enum 非公表）を再確認していない"
fi

# gemini: --sandbox が boolean のままであること。値を取るようになったら層 1 の
# 形の宣言ごと見直しが要る。
LAYER2_TOTAL=$((LAYER2_TOTAL + 1))
if command -v gemini >/dev/null 2>&1; then
  capture_help "$WORK/gemini-help.txt" gemini --help
  if help_unusable "gemini-cli" "$WORK/gemini-help.txt"; then
    :
  else
    LAYER2_RUN=$((LAYER2_RUN + 1))
    if awk '/--sandbox/ && /\[boolean\]/ { found = 1 } END { exit(found ? 0 : 1) }' \
         "$WORK/gemini-help.txt"; then
      ok "gemini-cli: --sandbox は実 CLI でも boolean"
    else
      bad "gemini-cli: --help の --sandbox が [boolean] ではなくなった — sandbox_shape の宣言を見直すこと"
    fi
  fi
else
  skipped "gemini-cli: gemini が PATH に無いため --sandbox の形を再確認していない"
fi

# claude-code / copilot-cli: 「--sandbox という概念を持たない」という前提の再確認。
# grok の前提を検査しておきながらこちらを見ないのは非対称で、どちらかが
# --sandbox を持った日に層 1 が古い契約（渡さないのが正しい）を主張し続ける。
for pair in "claude-code claude" "copilot-cli copilot"; do
  set -- $pair
  cli="$1"; bin="$2"
  LAYER2_TOTAL=$((LAYER2_TOTAL + 1))
  if command -v "$bin" >/dev/null 2>&1; then
    capture_help "$WORK/${bin}-help.txt" "$bin" --help
    if help_unusable "$cli" "$WORK/${bin}-help.txt"; then
      continue
    fi
    LAYER2_RUN=$((LAYER2_RUN + 1))
    if awk '/--sandbox/ { found = 1 } END { exit(found ? 0 : 1) }' "$WORK/${bin}-help.txt"; then
      bad "${cli}: --help に --sandbox が現れた — sandbox_shape の none 宣言を見直すこと"
    else
      ok "${cli}: --help に --sandbox は無い（none 宣言の前提は今も成立）"
    fi
  else
    skipped "${cli}: ${bin} が PATH に無いため none 宣言の前提を再確認していない"
  fi
done

# codex: アダプタが pin する設定キーが今も認識されるか。
#
# `-c` の未知キーは既定では黙って無視される（実測）ので、キー名がリネームされても
# pin は静かに効かなくなる。`codex exec --strict-config` はそれを rc=1 と
# "unknown configuration field ... in -c/--config override" で拒否するので、
# ここでキー名の生存を検査する。本番のアダプタが --strict-config を使わないのは、
# 利用者自身の config.toml の未知フィールドまで hard error にしてしまうため。
#
# 使い捨ての CODEX_HOME で走らせる: 利用者の config.toml を読ませない（読ませると
# 利用者側の未知フィールドで赤くなる）ことと、認証情報が無いのでモデルに到達する
# 前に終わることの両方が要る。判定は rc ではなくエラー文字列で行う（認証やディレクトリ
# 信頼の都合でどちらの経路も非 0 になるため）。stdin は塞ぐ（塞がないと codex が
# 標準入力を読みに行って止まる）。
LAYER2_TOTAL=$((LAYER2_TOTAL + 1))
CODEX_PIN_KEY="sandbox_workspace_write.network_access"
if ! command -v codex >/dev/null 2>&1; then
  skipped "codex-cli: codex が PATH に無いため設定キー ${CODEX_PIN_KEY} の認識を確認していない"
elif ! command -v perl >/dev/null 2>&1; then
  # 実行時間の上限が要る（codex が待ちに入る形を suite が抱え込まない）。
  # この repo は macOS を主対象にしており timeout(1) が無いので perl の alarm を使う。
  skipped "codex-cli: perl が無く実行時間を上限できないため設定キーの認識を確認していない"
else
  UNKNOWN_FIELD_RE='unknown configuration field'
  strict_probe() {
    CODEX_HOME="$WORK/codex-clean" perl -e 'alarm shift; exec @ARGV' 30 \
      codex exec --strict-config -c "$1" -s read-only "x" \
      </dev/null >"$WORK/strict.out" 2>"$WORK/strict.err" || true
    awk -v re="$UNKNOWN_FIELD_RE" 'index($0, re) { f = 1 } END { exit(f ? 0 : 1) }' \
      "$WORK/strict.err"
  }
  mkdir -p "$WORK/codex-clean"
  # 陽性対照: 存在しないキーは拒否されなければならない。これが落ちるなら probe 自体が
  # 効いていない（--strict-config が検証をやめた等）ので、下の陰性判定は意味を持たない。
  if strict_probe "sandbox_workspace_write.ff_probe_no_such_key=false"; then
    LAYER2_RUN=$((LAYER2_RUN + 1))
    if strict_probe "${CODEX_PIN_KEY}=false"; then
      bad "codex-cli: アダプタが pin する ${CODEX_PIN_KEY} が未知キーとして拒否された — キー名がリネームされ、pin は黙って効かなくなっている"
    else
      ok "codex-cli: 設定キー ${CODEX_PIN_KEY} は実 CLI に認識される（pin が黙って無効化されていない）"
    fi
  else
    bad "codex-cli: --strict-config が存在しないキーを拒否しなかった（陽性対照の失敗）— この probe ではキー名の生存を判定できない"
  fi
fi

# codex: 書き込み境界の実測を再現する。
#
# アダプタのコメントが載せている write×network の表のうち、**write 軸だけ**は
# `codex sandbox` でローカルかつ無料（モデルを呼ばない）に再測できる。ここが
# 動かないと「implement に workspace-write を選んだ理由」自体が根拠を失う。
# network 軸は外向きリクエストが要り、run-all の並び（静的 → ネットワーク →
# 破壊的 → 低速）における本 suite の位置と衝突するのでここでは測らない
# — そちらは実測の記録として残すに留める（アダプタのコメント参照）。
LAYER2_TOTAL=$((LAYER2_TOTAL + 1))
if ! command -v perl >/dev/null 2>&1; then
  skipped "codex-cli: perl が無く実行時間を上限できないため書き込み境界の表を再測していない"
elif command -v codex >/dev/null 2>&1; then
  SBX="$WORK/sandbox-probe"
  mkdir -p "$SBX" "$WORK/codex-clean"
  # サンドボックスの書き込みルートは CLI が継承する CWD なので、`cd` してから
  # 起動する。`-C/--cd` は使えない — codex sandbox の -C は --permission-profile を
  # 同時に要求し、指定しないと usage エラーで終わる（実測）。
  # 実行時間の上限を必ず掛ける。掛けないと、止まった codex sandbox で suite ごと
  # 抱え込む（実測で 90 秒超えて外から kill する形になった）。この repo は macOS を
  # 主対象にしており timeout(1) が無いので、strict_probe と同じ perl の alarm を使う。
  probe_write() {
    rm -f "$SBX/probe.txt" 2>/dev/null || true
    ( cd "$SBX" && CODEX_HOME="$WORK/codex-clean" \
        perl -e 'alarm shift; exec @ARGV' 30 \
        codex sandbox -c "sandbox_mode=$1" -- /bin/sh -c 'echo x > ./probe.txt' \
    ) </dev/null >/dev/null 2>&1 || true
    [ -f "$SBX/probe.txt" ]
  }
  LAYER2_RUN=$((LAYER2_RUN + 1))
  # 陽性対照を先に取る。「書けなかった」は境界が締まったのか probe が起動すら
  # していないのかを区別できず、対照が無いと後者を「境界が変わった」と誤診する
  # （実際に -C の usage エラーでその誤診が出た）。danger-full-access で書けなければ
  # 判定材料が無いので、境界の主張はせず probe 側の異常として報告する。
  if ! probe_write danger-full-access; then
    bad "codex-cli: 書き込み境界 probe が起動していない（danger-full-access でも書けなかった）— codex sandbox の呼び出し形が変わった可能性。境界の判定はできていない"
  else
    ro_wrote=no; ww_wrote=no
    probe_write read-only       && ro_wrote=yes
    probe_write workspace-write && ww_wrote=yes
    if [ "$ro_wrote" = "no" ] && [ "$ww_wrote" = "yes" ]; then
      ok "codex-cli: 書き込み境界の実測が今も成立（read-only=拒否 / workspace-write=許可）"
    else
      bad "codex-cli: 書き込み境界が変わった（read-only で書けた=${ro_wrote} / workspace-write で書けた=${ww_wrote}）— implement に workspace-write を選んだ根拠が崩れている"
    fi
  fi
else
  skipped "codex-cli: codex が PATH に無いため書き込み境界の表を再測していない"
fi

echo
echo "  PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}  層2: ${LAYER2_RUN}/${LAYER2_TOTAL} 照合実行"
if [ "$LAYER2_RUN" -eq 0 ]; then
  echo "  ※ 層 2 が 1 件も走っていません。この実行で担保できているのは層 1（形と値、"
  echo "     および宣言との整合）だけで、宣言そのものが実 CLI と一致しているかは未検査です。"
fi
FF_REACHED_END=1
if [ "$FAIL" -eq 0 ]; then
  echo "✓ ${SUITE_NAME} verify: 全 ${PASS} 件 pass"
else
  echo "✗ ${SUITE_NAME} verify: ${FAIL} 件失敗" >&2
  exit 1
fi
