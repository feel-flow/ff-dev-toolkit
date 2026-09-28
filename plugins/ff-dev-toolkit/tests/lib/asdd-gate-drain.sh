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
#   ff_asdd_write_payload <file> <json> <padding-bytes>
#     天井 probe 用のペイロードをファイルへ書く（数 MB を shell 変数に載せないため）。
#   ff_asdd_drain_probe_stream <hook> <payload-file> <cwd> [NAME=VALUE ...]
#     ペイロードを `cat` でパイプへ流す。天井（数 MB）の probe 用。
#   ff_asdd_drain_probe_delayed <hook> <payload-file> <delay> <cwd> [NAME=VALUE ...]
#     <delay> 秒待ってから書き始める書き手。hook の入力上限を過ぎてから書き出す
#     ホストでも書き手が死なないことを測る。
#   ff_asdd_copy_gate <plugin-dir>
#     hook を一時領域へ写す suite 向けに、ASDD ゲート一式（hooks/asdd-hook-gate.sh /
#     hooks/asdd-feature.mjs / 設定の検証本体 scripts/asdd/）を <plugin-dir> へ同じ相対配置で
#     写す。asdd-feature.mjs は `../scripts/asdd/config.mjs` を読むので、hooks/ の 2 本だけを
#     写すとコピー先の判定は常に rc=2（判定不能）になり、features.hooks=false の検査が
#     無効分岐（rc=3）ではなく判定不能の分岐を測ってしまう（Issue `#1808` の追記）。
#   ff_asdd_gate_rc <plugin-dir> <cwd> <feature>
#     <cwd> で <plugin-dir>/hooks/asdd-hook-gate.sh の asdd_hook_enabled を呼び、戻り値を
#     FF_ASDD_GATE_RC へ入れる。fixture が意図した分岐（0 / 3）へ届いていることの裏取り用。
#
# 天井を測る probe が要る理由（クロスモデルレビュー指摘）: 上の 200,000 バイトは
# bash 組み込み read の速度（2026-09-12 実測 bash 3.2.57 / macOS で約 2.9 MB/s）でも
# 入力上限 2 秒に収まるので、「上限で諦めて部分入力を捨てる」実装のままでも緑になる。
# 天井はその上限の外側（約 6 MB 以上）、遅延 producer は上限の外側（時間軸）にある。
# **6 MB ちょうどは境界そのもので probe が揺れる**（実測: 同じ 6 MB で rc=0 と rc=141 が
# 両方出る）。天井 probe は境界の数倍を使うこと。
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

ff_asdd_write_payload() { # <file> <json> <padding-bytes>
  node -e 'require("fs").writeFileSync(process.argv[1], process.argv[2] + " ".repeat(Number(process.argv[3])))' \
    "$1" "$2" "$3"
}

# 書き手は `cat`（SIGPIPE で死ぬ）にする。node を書き手にすると EPIPE が例外になって
# rc=1 で終わり、「141 が出ないこと」という観測が弱まる。
ff_asdd_drain_probe_stream() { # <hook> <payload-file> <cwd> [NAME=VALUE ...]
  local hook="$1" file="$2" cwd="$3"
  shift 3
  FF_ASDD_DRAIN_RC=0
  FF_ASDD_DRAIN_OUT="$({ cd "$cwd" && cat "$file" | env "$@" /bin/bash "$hook"; } 2>/dev/null)" \
    || FF_ASDD_DRAIN_RC=$?
}

ff_asdd_drain_probe_delayed() { # <hook> <payload-file> <delay> <cwd> [NAME=VALUE ...]
  local hook="$1" file="$2" delay="$3" cwd="$4"
  shift 4
  FF_ASDD_DRAIN_RC=0
  FF_ASDD_DRAIN_OUT="$({ cd "$cwd" && { sleep "$delay"; cat "$file"; } | env "$@" /bin/bash "$hook"; } 2>/dev/null)" \
    || FF_ASDD_DRAIN_RC=$?
}

FF_ASDD_GATE_RC=0
ff_asdd_copy_gate() { # <plugin-dir>
  local dest="$1" src
  [ -n "$dest" ] || return 1
  src="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)" || return 1
  mkdir -p "$dest/hooks" "$dest/scripts" || return 1
  cp "$src/hooks/asdd-hook-gate.sh" "$src/hooks/asdd-feature.mjs" "$dest/hooks/" || return 1
  rm -rf "$dest/scripts/asdd"
  cp -R "$src/scripts/asdd" "$dest/scripts/asdd" || return 1
}

ff_asdd_gate_rc() { # <plugin-dir> <cwd> <feature>
  FF_ASDD_GATE_RC=0
  ( cd "$2" && . "$1/hooks/asdd-hook-gate.sh" && asdd_hook_enabled "$3" ) 2>/dev/null || FF_ASDD_GATE_RC=$?
}
