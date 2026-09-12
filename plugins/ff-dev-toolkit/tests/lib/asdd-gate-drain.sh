#!/usr/bin/env bash
#
# ASDD ゲートの早期終了経路で stdin が drain されることを測る共有ヘルパー。
#
# PreToolUse ガードは「stdin ペイロードを bash 組み込みの read で読み切ってから
# 素通しする」契約を持つ。ところが各ガード先頭の ASDD ゲート前置きは任意 Hook が
# 無効なとき exit 0 するため、前置きが drain より前にあると「読まずに exit 0」する
# 経路ができ、書き手（ホスト）が EPIPE / SIGPIPE を受ける。ゲート自身
# （hooks/asdd-hook-gate.sh）は stdin を消費しないので、drain はガード側の責務。
#
# ゲートが早期終了する 2 経路を fixture で作り、パイプバッファ（64 KiB）より大きい
# ペイロードを書き込んで観測する。drain 漏れは hook の exit 0 ではなく**書き手の非 0
# 終了**として現れるので、suite 側は pipefail 下で rc を見る（SIGPIPE が致命の環境では
# 141、bash が SIGPIPE を無視して write error を返す環境では 1。値ではなく非 0 を見る）。
#
#   経路 1: `.asdd/config.json` があり `node` が PATH に無い（ゲートが return 1）
#   経路 2: `.asdd/config.json` が当該 feature を無効と宣言している（ゲートが 3 を返す）
#
# 公開関数:
#   ff_asdd_fixture <dir> <hooks-enabled:true|false>
#     <dir>/.asdd/config.json を書く（features.hooks を引数で切り替える）。
#   ff_asdd_big_payload <json>
#     <json> の末尾へパイプバッファ超の空白を足した文字列を返す（JSON として有効）。
#   ff_asdd_drain_probe <hook> <payload> <cwd> [NAME=VALUE ...]
#     <cwd> を作業ディレクトリにして hook を起動する。ASDD ゲートは hook プロセスの
#     PWD から設定を探すため、cwd の指定が経路の切り替えそのものになる。
#
# 公開変数（呼び出し側の同名変数を上書きする）:
#   FF_ASDD_DRAIN_RC   パイプライン全体の終了コード（141 なら drain 漏れ）
#   FF_ASDD_DRAIN_OUT  hook の stdout

FF_ASDD_DRAIN_RC=0
FF_ASDD_DRAIN_OUT=""

ff_asdd_fixture() { # <dir> <hooks-enabled:true|false>
  local dir="$1" hooks="$2"
  mkdir -p "$dir/.asdd" || return 1
  cat > "$dir/.asdd/config.json" <<JSON
{
  "schemaVersion": 1,
  "project": { "name": "guard-drain", "purpose": "ASDD gate drain probe", "owner": "tests" },
  "style": "citizen",
  "stage": "poc",
  "tools": ["claude"],
  "documents": ["MASTER"],
  "features": { "ace": false, "retrospective": false, "multiReview": false, "hooks": $hooks, "ci": false },
  "workflow": "simple",
  "decisions": [],
  "github": null
}
JSON
}

ff_asdd_big_payload() { # <json>
  printf '%s%*s' "$1" 200000 ''
}

ff_asdd_drain_probe() { # <hook> <payload> <cwd> [NAME=VALUE ...]
  local hook="$1" payload="$2" cwd="$3"
  shift 3
  FF_ASDD_DRAIN_RC=0
  # stderr は書き手（printf）の分まで捨てる。drain 漏れのとき printf 自身が
  # "write error: Broken pipe" を出すので、パイプライン全体を括って落とす。
  FF_ASDD_DRAIN_OUT="$({ cd "$cwd" && printf '%s' "$payload" | env "$@" /bin/bash "$hook"; } 2>/dev/null)" \
    || FF_ASDD_DRAIN_RC=$?
}
