#!/usr/bin/env bash
#
# record-gate-head.sh — ゲートが「どのコミットを実測したか」を記録する
#
# 使い方:
# --- usage:start ---
#   record-gate-head.sh --gate <ラベル> [--status pass|fail] [--mode <文字列>]
#                       [--result <文字列>] [--expect-head <SHA40>] [--record <パス>]
#   record-gate-head.sh --print-path
#
#   --expect-head  ゲート開始時の HEAD。現在の HEAD と違えば**記録しない**。
#                  長時間のゲートは実行中に HEAD が動きうる（別セッションの commit、
#                  自分の commit）。終了時の HEAD をそのまま書くと、suite が一度も
#                  読んでいないツリーが「実測済み」として記録され、照合はリモート先端と
#                  一致して静かに緑になる — この検査が塞ごうとしている false green と
#                  同じ形が、記録側から入り込む。呼び出し側は開始時の HEAD を控えて渡す。
#
# 何のための記録か:
#   ローカルで回した検証スイートの結果は、**その時点の特定コミットに対する実測**である。
#   マージ直前にリモート先端がその実測対象と一致していなければ、squash merge は
#   未実測のコミットまで畳み込む。照合する側（check-merge-freshness.sh）が
#   「何を実測したのか」を知るための片割れが本スクリプトで、ゲート側から呼ぶ。
#
#   自己申告（エージェントが「commit X で測った」と述べる）と違い、記録は
#   **ゲートが通った瞬間に機械が書く**。呼び出し側は「通ったときにだけ呼ぶ」ことだけを
#   守ればよい。
#
# 記録先:
#   --record > FF_GATE_RECORD_FILE > `git rev-parse --absolute-git-dir`/ff-dev-toolkit/gate-record
#   git dir 配下に置くのでコミット対象にならず、worktree ごとに独立する
#   （`--absolute-git-dir` は worktree では .git/worktrees/<名> を返す。worktree ごとに
#   HEAD が違う以上、記録も共有してはいけない）。
#
#   記録は 1 スロットで、後の実行が前の実行を上書きする。履歴を持たないのは、
#   **上書きが安全側にしか倒れない**ため — 古い記録が新しい記録に置き換わっても
#   生じるのは「不一致」か「判定不能」であって、偽の一致は作れない。
#
#   ただし**上書きしないこと**は安全側ではない。同じコミットでゲートが赤くなった回に
#   何も書かないと、前回の緑の記録がそのまま残り、照合は無出力の exit 0 を返す
#   （「一度通ったコミット」が「いま通るコミット」に化ける）。赤い回は
#   `--status fail` で記録を**無効化**すること。照合側は `STATUS=pass` だけを通す。
#
# 作業ツリーが汚れている場合:
#   記録は書くが `DIRTY=yes` を立てる。汚れた木で測った結果は**どのコミットに対する
#   実測でもない**ので、照合側はこれを一致と扱わない（判定不能として報告する）。
#   記録を書かない選択もあり得るが、それだと「一度も測っていない」と区別が付かない。
#
# 終了コード:
#   0 = 記録した
#   2 = 記録できない（git work tree の外・HEAD 未解決・書き込み不可・使い方の誤り）
#
#   **呼び出し側は本スクリプトの失敗で自分の終了コードを変えないこと。** 記録の失敗は
#   検証結果の失敗ではない。記録が無ければ照合側が「判定不能」として報告する。
#
# 出力:
#   成功時は無出力（ゲートの出力へノイズを足さない）
#   失敗時は stderr へ理由を出す（git の出力を引用する場合は複数行になりうる）
#
# 実装上の制約:
#   - macOS 標準の bash 3.2 で動くこと（連想配列・`${var,,}` を使わない）
#   - date の書式は `date -u +%Y-%m-%dT%H:%M:%SZ`（GNU/BSD 双方で同じ結果）

set -euo pipefail

# --help はヘッダの usage マーカー範囲を出す（自分自身のパス）。
SELF="${BASH_SOURCE[0]}"

GATE=""
STATUS="pass"
MODE=""
RESULT=""
EXPECT_HEAD=""
RECORD_PATH=""
PRINT_PATH=0

RECORD_VERSION=1

fail() {
  echo "record-gate-head: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gate)   [[ $# -ge 2 ]] || fail "--gate に値がありません"; GATE="$2"; shift 2 ;;
    --mode)   [[ $# -ge 2 ]] || fail "--mode に値がありません"; MODE="$2"; shift 2 ;;
    --status)
      [[ $# -ge 2 ]] || fail "--status に値がありません"
      case "$2" in
        pass|fail) STATUS="$2" ;;
        *) fail "--status は pass / fail のいずれかです（受領: $2）" ;;
      esac
      shift 2
      ;;
    --result) [[ $# -ge 2 ]] || fail "--result に値がありません"; RESULT="$2"; shift 2 ;;
    --expect-head) [[ $# -ge 2 ]] || fail "--expect-head に値がありません"; EXPECT_HEAD="$2"; shift 2 ;;
    --record) [[ $# -ge 2 ]] || fail "--record に値がありません"; RECORD_PATH="$2"; shift 2 ;;
    --print-path) PRINT_PATH=1; shift ;;
    -h|--help)
      # 行番号で切ると、ヘッダを 1 行足しただけで別の範囲が出る。マーカーで囲む。
      sed -n '/^# --- usage:start/,/^# --- usage:end/p' "$SELF"
      exit 0
      ;;
    *) fail "不明な引数: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || fail "git が見つかりません"

resolve_record_path() {
  local git_dir
  if [[ -n "$RECORD_PATH" ]]; then
    printf '%s\n' "$RECORD_PATH"
    return 0
  fi
  if [[ -n "${FF_GATE_RECORD_FILE:-}" ]]; then
    printf '%s\n' "$FF_GATE_RECORD_FILE"
    return 0
  fi
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s\n' "${git_dir}/ff-dev-toolkit/gate-record"
}

TARGET="$(resolve_record_path)" || fail "git リポジトリの外では記録先を決められません"
[[ -n "$TARGET" ]] || fail "記録先を解決できません"

if [[ "$PRINT_PATH" -eq 1 ]]; then
  printf '%s\n' "$TARGET"
  exit 0
fi

[[ -n "$GATE" ]] || fail "--gate は必須です（何を実測したかのラベル）"

COMMIT="$(git rev-parse HEAD 2>/dev/null)" \
  || fail "HEAD を解決できません（コミットが 1 つも無いか、git work tree の外です）"

# ゲート実行中に HEAD が動いていたら記録しない。終了時の HEAD を書くと、
# 実際には読まれていないツリーが実測対象として記録される。
if [[ "$STATUS" == "pass" && -n "$EXPECT_HEAD" && "$EXPECT_HEAD" != "$COMMIT" ]]; then
  fail "ゲート実行中に HEAD が変わりました（開始 ${EXPECT_HEAD} / 現在 ${COMMIT}）。実行したのは開始時のツリーなので記録しません"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -n "$BRANCH" ]] || BRANCH="(unknown)"

# 未追跡ファイルも汚れとして数える。新規 suite ディレクトリのように、追跡されて
# いなくてもゲートの実行対象になるものがあるため（`git status --porcelain` の既定）。
#
# **status の失敗を空出力と区別する**。`$(git status ... 2>/dev/null)` の空文字は
# 「clean」と「status が失敗した」の両方を意味するので、区別せずに書くと
# 「木の状態を確認できていないのに DIRTY=no」という偽の clean 記録ができる。
# 確認できなかった回は記録せずに止める（直前の記録は残るが、それは実在したコミットに
# 対する実測であって、偽の clean ではない）。
# 判定は **stdout だけ**で行う。stderr を畳み込むと、clean な木でも git が警告を出した
# 回（submodule の rmdir 警告・CRLF 変換警告・fsmonitor 警告など。いずれも exit 0）が
# DIRTY=yes になり、「コミットするものが何も無い木に対して『コミットを確定させてから
# 再実行しろ』」というもっともらしい誤診断でゲートが恒久的に止まる。
STATUS_RC=0
STATUS_OUT="$(git status --porcelain 2>/dev/null)" || STATUS_RC=$?
if [[ "$STATUS_RC" -ne 0 ]]; then
  # 失敗した回だけ、理由を取りにもう一度呼ぶ（成功経路に余計な実行を足さない）
  STATUS_ERR="$(git status --porcelain 2>&1 >/dev/null || true)"
  fail "作業ツリーの状態を確認できません（${STATUS_ERR}）。clean と断定せずに記録を中止します"
fi
if [[ -n "$STATUS_OUT" ]]; then
  DIRTY="yes"
else
  DIRTY="no"
fi

RECORDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TARGET_DIR="$(dirname "$TARGET")"
mkdir -p "$TARGET_DIR" 2>/dev/null || fail "記録先ディレクトリを作成できません: ${TARGET_DIR}"

# 一時ファイル経由で置き換える。書き込み途中で落ちた記録を照合側が読むと、
# 「判定不能」ではなく壊れた値での比較になりかねない。
TMP="${TARGET}.tmp.$$"
{
  printf 'RECORD_VERSION=%s\n' "$RECORD_VERSION"
  printf 'STATUS=%s\n' "$STATUS"
  printf 'COMMIT=%s\n' "$COMMIT"
  printf 'BRANCH=%s\n' "$BRANCH"
  printf 'DIRTY=%s\n' "$DIRTY"
  printf 'GATE=%s\n' "$GATE"
  printf 'MODE=%s\n' "$MODE"
  printf 'RESULT=%s\n' "$RESULT"
  printf 'RECORDED_AT=%s\n' "$RECORDED_AT"
} > "$TMP" 2>/dev/null || { rm -f "$TMP" 2>/dev/null || true; fail "記録を書き込めません: ${TARGET}"; }

mv -f "$TMP" "$TARGET" 2>/dev/null || { rm -f "$TMP" 2>/dev/null || true; fail "記録を確定できません: ${TARGET}"; }

exit 0
