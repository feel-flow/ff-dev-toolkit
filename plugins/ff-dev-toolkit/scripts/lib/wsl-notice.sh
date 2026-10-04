#!/usr/bin/env bash
# Windows の Git Bash（MSYS / Cygwin）上で動いていることを判定し、WSL での利用・検証をすすめる
# 案内を組み立てる（Issue `#2030`）。SessionStart の更新通知 hook（hooks/check-update.sh）と
# 全件ゲート（tests/run-all.sh）が共有する。
#
# 判定は引数で受け取る。bash は起動時に OSTYPE を自分で設定し直すので、環境変数で渡しても
# 上書きできない。関数は値を引数で受け、hook ごと msys の経路を通す検査は、OSTYPE の初期化より後に
# 読まれる BASH_ENV のファイルで OSTYPE を代入して行う（tests/update-check）。
# どの関数も外部コマンドを起動しない（hook は Linux / macOS を含む全セッションに割り込むため）。

# <ostype> が Git Bash（msys*）か Cygwin（cygwin*）なら 0。WSL の中は linux-gnu なので当たらない。
ff_host_is_msys() {
  case "${1:-}" in
    msys* | cygwin*) return 0 ;;
  esac
  return 1
}

# 前回の案内から <ttl> 秒以上たっていれば 0（案内する）。記録が無い・読めない・形式外・未来の
# 時刻（時計のずれ）は「案内する」側へ倒す — 形式外のまま黙ると、壊れた記録 1 つで案内が二度と
# 出なくなる。値は算術へ渡す前に数字だけであること・桁数を確かめる（10# は先頭ゼロの八進数解釈を防ぐ）。
ff_wsl_notice_due() { # <記録ファイル> <現在の epoch 秒> <ttl 秒>
  local file="${1:-}" now="${2:-}" ttl="${3:-}" last="" rest=""
  case "$now" in '' | *[!0-9]*) return 0 ;; esac
  case "$ttl" in '' | *[!0-9]*) return 0 ;; esac
  [ "${#now}" -le 12 ] && [ "${#ttl}" -le 12 ] || return 0
  [ -f "$file" ] || return 0
  IFS=' ' read -r last rest 2>/dev/null < "$file" || [ -n "$last" ] || return 0
  [ -z "$rest" ] || return 0
  case "$last" in '' | *[!0-9]*) return 0 ;; esac
  [ "${#last}" -le 12 ] || return 0
  [ "$((10#$now - 10#$last))" -ge 0 ] || return 0
  [ "$((10#$now - 10#$last))" -ge "$((10#$ttl))" ]
}

# SessionStart の systemMessage（利用者へそのまま表示する）。JSON の文字列へそのまま埋め込むので、
# " と \ と制御文字を含めない（suite が検査する）。
ff_wsl_notice_system_message() {
  printf '%s' 'ℹ️ ff-dev-toolkit: このセッションは Windows の Git Bash 上で動いています。Git Bash ではプロセスの起動が遅く hook の所要時間が長くなり、symlink やパス表記の違いで一部の検査が成立しません。WSL の中で claude を起動して使うことをおすすめします（この案内は 1 日 1 回）。WSL では Windows 側の PATH が混ざって判定が揺れることがあり、/etc/wsl.conf の [interop] に appendWindowsPath=false を書くと外せます。止めるには環境変数 FF_DEV_TOOLKIT_SKIP_WSL_NOTICE=1 を設定してください。'
}

# SessionStart の additionalContext（Claude への注入）。同じく " と \ と制御文字を含めない。
ff_wsl_notice_context() {
  printf '%s' 'このセッションは Windows の Git Bash（MSYS）上で動いている。ff-dev-toolkit の hook はプロセス起動の遅さで所要時間が延び、symlink やパス表記（C:/… と /c/…）の違いで一部の検査が成立しない。利用者が WSL への切り替えを望んだら次を案内すること: (1) WSL（Ubuntu など）を導入する (2) リポジトリを WSL のファイルシステム（ホームディレクトリ配下）へ clone し直す。/mnt/c 配下のまま使うとファイル操作が遅い (3) WSL の中に Node.js と Claude Code を入れ、その中で claude を起動する。WSL の PATH には既定で Windows 側の PATH が足されるため、Windows 版の CLI（codex など）が見えて判定が揺れることがある。外すには /etc/wsl.conf の [interop] に appendWindowsPath=false を書いて WSL を再起動する。案内を止めたい場合は環境変数 FF_DEV_TOOLKIT_SKIP_WSL_NOTICE=1 を設定する。'
}

# 全件ゲートの冒頭案内。<ostype> が msys / cygwin のときだけ stderr へ出し、実行は止めない。
# <plugin 相対パス> はリポジトリのルートから見た plugin の位置（例: plugins/ff-dev-toolkit/）で、
# 案内のコマンドをそのまま貼れる形にするために受け取る（呼び出し側が git から実行時に求める）。
ff_run_all_msys_notice() { # <ostype> [<plugin 相対パス>]
  ff_host_is_msys "${1:-}" || return 0
  local rel="${2:-}"
  printf '%s\n' \
    'ℹ️  このホスト（Windows の Git Bash）では全件ゲートが完走しないことがあります。' \
    '    プロセスの起動が遅く、symlink やパス表記の違いで成立しない検査もあります（2 時間で完走しなかった実測がある）。' \
    '    Linux と同じ条件で流すには WSL を使ってください:' \
    '      1. WSL のファイルシステム（ホームディレクトリ配下）へリポジトリを clone する（/mnt/c 配下は遅い）' \
    "      2. npm ci --prefix ${rel}mcp" \
    "      3. bash ${rel}tests/run-all.sh" \
    '    WSL の PATH に Windows 側の CLI が混ざると一部の suite が揺れます（/etc/wsl.conf の [interop] に appendWindowsPath=false で外せる）。' \
    '    このまま続行します。' >&2
}
