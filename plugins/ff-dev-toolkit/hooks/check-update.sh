#!/usr/bin/env bash
#
# ff-dev-toolkit 更新通知フック（SessionStart、Issue #165）。
#
# インストール済み plugin.json の version と、公開リポジトリ
# https://github.com/feel-flow/ff-dev-toolkit の最新 SemVer タグを比較し、
# 新版があるときだけ通知 JSON を stdout に出力する。最新版なら完全に無出力。
# 同一の新版について通知するのは一度だけ（notified ファイルに記録し、compact 等で
# SessionStart が再発火しても同じ通知を context へ再注入しない）。
#
# 設計原則:
#   - fail-open: このフックはユーザーの全セッション起動に割り込む。リポジトリ内の
#     テストゲート群（fail-closed）とは逆に、自分の不具合・ネットワーク不達で
#     ユーザーのセッションを壊さないことを最優先し、あらゆる異常は黙って通知を
#     スキップして exit 0 で終える。stdout は通知 JSON 以外に何も出さず、stderr も
#     汚さない（外部入力は算術・比較へ渡す前に必ず検証する）。
#   - TTL キャッシュ: 成功 24h / 失敗 1h の非対称 TTL。オフライン環境での
#     毎セッション再試行を 1h に抑えつつ、復帰後は 1h 以内に追従する。
#   - 悲観的 fail マーカー: ネットワークへ出る「前」に fail を記録し、成功したら
#     ok で上書きする。hooks.json の timeout がフックごと打ち切った場合（ハング
#     するネットワーク等）でも fail マーカーが残るため、「最も遅い失敗経路でだけ
#     TTL が効かず毎セッション timeout 秒を払う」逆転を防ぐ。代償として、取得中に
#     プロセスが死んだ場合も次の 1h は再試行しない（意図した取引）。
#   - ハング対策: GIT_TERMINAL_PROMPT=0 + GIT_ASKPASS 無効化 + BatchMode で
#     認証プロンプト待ちを封じる（tests/changelog-links で確立した対策と同じ）。
#     ls-remote 自体が長引く場合は hooks.json の timeout がフックごと打ち切る。
#   - 互換性: bash 3.2（stock macOS）互換。jq / timeout(1) / sort -V に依存しない。
#   - 出力の安全: タグ・キャッシュから得た version 文字列は、経路を問わず
#     ^[0-9]+\.[0-9]+\.[0-9]+$ の厳格検査を通ったものだけを JSON へ埋め込む
#     （細工されたタグ名による JSON 注入の防止）。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1  更新チェックを無効化する（ユーザー向け）
#   以下はテストシーム（tests/update-check/verify.sh が実ネットワークに触れずに
#   本スクリプトを駆動するための注入口。通常運用で設定する必要はない）:
#   FF_DEV_TOOLKIT_UPDATE_REPO_URL      参照先リポジトリ URL の上書き
#   FF_DEV_TOOLKIT_UPDATE_CACHE_DIR     キャッシュディレクトリの上書き
#   FF_DEV_TOOLKIT_UPDATE_TTL_OK        成功キャッシュ TTL 秒の上書き（既定 86400）
#   FF_DEV_TOOLKIT_UPDATE_TTL_FAIL      失敗キャッシュ TTL 秒の上書き（既定 3600）
#
# キャッシュ形式: update-check は 1 行 `<status> <latest|-> <epoch>`（status は
# ok / fail）。想定形式以外（余剰フィールド・非数値 epoch・SemVer でない latest）は
# 「キャッシュなし」として扱い、上書きして自己修復する。notified は通知済みの
# 最新版 version を 1 行で持つ独立ファイル（TTL 管理と直交させ、キャッシュの
# timestamp を保ったまま通知済みだけを記録できるようにする）。

# fail-open のため set -e は使わない。set -u も、未定義変数参照が非 0 終了で
# フックを汚すため使わない（参照はすべて ${VAR:-default} 形で行う）。

# ---- オプトアウト（キャッシュ読み書き含め一切の処理より先） -----------------
if [ "${FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK:-0}" = "1" ]; then
  exit 0
fi

# ---- 自バージョン取得 --------------------------------------------------------
# 実運用では Claude Code が CLAUDE_PLUGIN_ROOT を与える。テストや手動実行では
# スクリプト自身の位置（<plugin-root>/hooks/）から導出する。
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  plugin_root="$CLAUDE_PLUGIN_ROOT"
else
  plugin_root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || exit 0
fi

plugin_json="$plugin_root/.claude-plugin/plugin.json"
[ -f "$plugin_json" ] || exit 0

# jq 非依存の version 抽出。整形済み（1 行 1 キー）の plugin.json を前提とし、
# "version": "x.y.z" を含む最初の行から読む。minify された JSON で同一行に複数の
# version キーが並ぶ場合は BRE の貪欲マッチが後方を拾う既知の限界がある（本
# プラグインの plugin.json は本リポジトリ管理の整形済み JSON なので許容）。
current="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' "$plugin_json" 2>/dev/null | head -n 1)"
case "$current" in
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) exit 0 ;;
esac

# ---- キャッシュ確認 ----------------------------------------------------------
repo_url="${FF_DEV_TOOLKIT_UPDATE_REPO_URL:-https://github.com/feel-flow/ff-dev-toolkit.git}"
cache_dir="${FF_DEV_TOOLKIT_UPDATE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ff-dev-toolkit}"
cache_file="$cache_dir/update-check"
notified_file="$cache_dir/notified"
ttl_ok="${FF_DEV_TOOLKIT_UPDATE_TTL_OK:-86400}"
ttl_fail="${FF_DEV_TOOLKIT_UPDATE_TTL_FAIL:-3600}"

# TTL・epoch は算術式へ渡す前に「数字のみ」を強制する（[0-9]* は前方一致なので
# 使わない）。非数値の TTL は既定値へフォールバックする。
is_digits() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  # 桁数上限で bash 算術のオーバーフローも防ぐ（epoch は 10 桁で 2286 年まで足りる）
  [ "${#1}" -le 12 ]
}
is_digits "$ttl_ok" || ttl_ok=86400
is_digits "$ttl_fail" || ttl_fail=3600

now="$(date +%s 2>/dev/null)" || exit 0
is_digits "$now" || exit 0

# SemVer 3 要素（数字のみ）か。JSON へ埋め込んでよいのはこれを通った文字列だけ。
is_semver() {
  printf '%s' "${1:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

latest=""
if [ -f "$cache_file" ]; then
  # 余剰フィールドは c_junk が吸収し「想定形式以外」として検出する。読み取り
  # 失敗（権限等）のエラーは 2>/dev/null を「先に」置いて入力リダイレクトの
  # 失敗メッセージごと封じる（リダイレクトは左から右に処理されるため）。
  IFS=' ' read -r c_status c_latest c_ts c_junk 2>/dev/null < "$cache_file" || c_status=""
  if [ -z "${c_junk:-}" ] && is_digits "${c_ts:-}"; then
    # 10# の基数指定は先頭ゼロ（"08" 等）の八進数解釈エラーを防ぐ
    age=$((now - 10#$c_ts))
    if [ "${c_status:-}" = "ok" ] && is_semver "${c_latest:-}" \
      && [ "$age" -ge 0 ] && [ "$age" -lt "$ttl_ok" ]; then
      latest="$c_latest"
    elif [ "${c_status:-}" = "fail" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$ttl_fail" ]; then
      # 直近の取得失敗から間もない。再試行せず静かに終える
      exit 0
    fi
    # ok なのに latest が SemVer でない（例: "ok - <ts>"）場合はここに落ち、
    # キャッシュなし扱いでネットワーク経路へ進んで上書き自己修復する
  fi
fi

# ---- 最新タグ取得（キャッシュ未ヒット時のみネットワークへ） -------------------
write_cache() {
  # 引数: <status> <latest|->。書き込み失敗も fail-open（次回また試すだけ）。
  # cache_file がディレクトリ化した病的状態は除去して自己修復する。
  mkdir -p "$cache_dir" 2>/dev/null || return 0
  [ -d "$cache_file" ] && rm -rf "$cache_file" 2>/dev/null
  # 並行セッション対策: 自分より新しい結果は上書きしない（遅延した古い取得が
  # 新しい成功結果を巻き戻すのを防ぐ）。同時刻の ok を fail で潰すのも避ける。
  if [ -f "$cache_file" ]; then
    IFS=' ' read -r e_status _e_latest e_ts _e_junk 2>/dev/null < "$cache_file" || e_status=""
    if is_digits "${e_ts:-}"; then
      if [ "$((10#$e_ts))" -gt "$now" ]; then
        return 0
      fi
      if [ "$((10#$e_ts))" -eq "$now" ] && [ "${e_status:-}" = "ok" ] && [ "$1" = "fail" ]; then
        return 0
      fi
    fi
  fi
  # timeout kill で孤児化した過去の一時ファイルを掃除してから書く（PID が変わる
  # ため自前の rm では回収できない。他セッションの書き込み中 tmp を消しても、
  # その mv が失敗して fail-open で流れるだけで実害はない）
  rm -f "$cache_file".* 2>/dev/null
  tmp="$cache_file.$$"
  printf '%s %s %s\n' "$1" "$2" "$now" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache_file" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

if [ -z "$latest" ]; then
  # 悲観的 fail マーカー（ヘッダー「設計原則」参照): ここでフックが timeout に
  # kill されても fail が残り、次セッションは 1h スキップされる
  write_cache fail -

  # 認証プロンプト封じ: 対象は public リポジトリなので、認証を求められる状況は
  # すべて異常系。プロンプトで固まるくらいなら即失敗させる。
  tags="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false \
    GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
    git ls-remote --tags "$repo_url" 2>/dev/null)" || tags=""

  [ -z "$tags" ] && exit 0

  # peeled ref（^{} 付き）は $ アンカーで除外。SemVer 3 要素の v タグのみ採用し、
  # ゼロ埋め比較キーで最大値を選ぶ（BSD sort に -V が無いため）。%012d は最小幅
  # 指定なので 13 桁以上の要素は辞書順が壊れるが、実用上の version 要素は
  # 12 桁に収まる前提を置く（awk の数値精度の上限もほぼ同じ桁数）。
  latest="$(printf '%s\n' "$tags" \
    | sed -n 's|.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
    | awk -F. '{ printf "%012d.%012d.%012d %s\n", $1, $2, $3, $0 }' \
    | sort | tail -n 1 | awk '{ print $2 }')"

  # 到達はできたが SemVer タグが読めない場合も通知しない（fail マーカーは
  # 悲観書き込み済みなのでそのまま残る）
  is_semver "$latest" || exit 0
  write_cache ok "$latest"
fi

# キャッシュ経由・ネットワーク経由のどちらでも、JSON へ埋め込む前の最終ゲート
is_semver "$latest" || exit 0

# ---- SemVer 比較 -------------------------------------------------------------
# $1 > $2 なら真。数値比較なので 0.9.9 < 0.10.0 を正しく扱う。
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit 1
  }'
}

version_gt "$latest" "$current" || exit 0

# ---- 通知済みチェック（同一バージョンは一度だけ） ----------------------------
notified="$(head -n 1 2>/dev/null < "$notified_file")" || notified=""
[ "$notified" = "$latest" ] && exit 0

# ---- 通知出力 ----------------------------------------------------------------
# systemMessage: ユーザーへ直接表示。additionalContext: Claude へ更新手順を注入し、
# 「更新して」と言われたときに正しいコマンドを案内できるようにする。
# marketplace 名はユーザーのローカル登録名に依存するため固定しない
# （引数なしの `claude plugin marketplace update` は全 marketplace を更新する）。
printf '{"systemMessage":"📦 ff-dev-toolkit v%s が利用可能です（現在 v%s）。更新: claude plugin marketplace update && claude plugin update ff-dev-toolkit","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ff-dev-toolkit の新バージョン v%s が公開されています（インストール済みは v%s）。ユーザーが更新を希望したら次の手順を案内すること: (1) claude plugin marketplace update （引数なし。marketplace 名はユーザーの登録名に依存するため） (2) claude plugin update ff-dev-toolkit (3) 適用には Claude Code の再起動が必要。変更点は https://github.com/feel-flow/ff-dev-toolkit/blob/main/CHANGELOG.md を参照。この通知を止めたい場合は環境変数 FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1 を設定する。"}}\n' \
  "$latest" "$current" "$latest" "$current"

# 通知済みを記録（書き込み失敗は fail-open: 次セッションで再通知されるだけ）
mkdir -p "$cache_dir" 2>/dev/null \
  && printf '%s\n' "$latest" > "$notified_file.$$" 2>/dev/null \
  && mv -f "$notified_file.$$" "$notified_file" 2>/dev/null
rm -f "$notified_file.$$" 2>/dev/null

exit 0
