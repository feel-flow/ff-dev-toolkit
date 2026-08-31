#!/usr/bin/env bash
# auto-update-marketplace.sh — 登録済みマーケットプレイスの自動更新（Issue #856）
#
# サードパーティマーケットプレイスのプラグインは、クライアント既定では自動更新
# されない（既定 autoUpdate 有効は公式マーケットプレイスのみ）。
# 実測として導入メンバーの環境で約 6 週間古いまま放置された事例があるため、
# プラグイン自身に SessionStart hook を同梱し、セッション起動時にマーケット
# プレイスの更新（+ 本体更新の best-effort）を自動実行する。一度この版へ更新
# すれば、以降は各ユーザーの autoUpdate 設定に依存せず最新へ追従する。
#
# 設計:
#   - fail-silent 全体: claude CLI 不在・オフライン・権限異常でもセッション起動を
#     一切妨げない（すべての失敗を握って exit 0。安全ゲートではなく利便 hook）
#   - hooks.json 側で async 実行（起動をブロックしない）。反映は次回セッション
#     起動時（Claude Code の仕様。restart required）
#   - マーケットプレイス更新は**引数なし**＝利用者が登録している全マーケット
#     プレイスを更新する。登録名が導入経路で異なるうえ、名前のハードコードは
#     配布物に開発元の識別子を埋め込むことになるため、名前には依存しない
#     （本プラグイン以外の登録マーケットプレイスも更新される副作用を含む —
#     README に明記）
#   - 本体更新（claude plugin update）: 登録 ID と scope は
#     `claude plugin list --json` から解決する（jq 不在時は plain 出力から ID
#     のみ拾い、既定 scope=user へ fallback — user 以外の導入は jq がある環境で
#     のみ追従できる既知の限界）。非 TTY では `-y` が必須（無いと常に失敗する
#     — CLI ヘルプで実測）
#   - 頻度制御 + 並行排他: 日付付きゲートファイルを noclobber の atomic create
#     で取り、取れなければ（同日実行済み / 並行セッションが先行 / 書き込み
#     不能）黙って exit 0。check-then-act の非アトミック競合と、書き込み不能
#     環境での毎セッション再試行の両方を 1 つのゲートで防ぐ
#
# 無効化: 環境変数 FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE=1
# ゲートの上書き（テスト用）: FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP=<base path>

[ -n "${FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE:-}" ] && exit 0
command -v claude >/dev/null 2>&1 || exit 0

stamp="${FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP:-$HOME/.claude/.ff-dev-toolkit-auto-update-stamp}"
today="$(date +%Y-%m-%d 2>/dev/null)" || exit 0
gate="${stamp}.${today}"
mkdir -p "$(dirname "$gate")" 2>/dev/null || exit 0
# atomic create（noclobber）。既存 = 同日実行済み or 並行セッションが先行。
# リダイレクト失敗の診断はシェルが出すため、ブロックごと stderr を捨てる
{ ( set -o noclobber; : > "$gate" ) ; } 2>/dev/null || exit 0
# 前日以前のゲートを掃除（best-effort。glob 不一致は nullglob 無しでも -e で弾く）
for old in "${stamp}".*; do
  [ -e "$old" ] || continue
  [ "$old" = "$gate" ] || rm -f "$old" 2>/dev/null || true
done

claude plugin marketplace update </dev/null >/dev/null 2>&1 || true

updated_any=0
if command -v jq >/dev/null 2>&1; then
  pairs="$(claude plugin list --json </dev/null 2>/dev/null \
    | jq -r '.[] | select(.id | startswith("ff-dev-toolkit@")) | "\(.id) \(.scope // "user")"' 2>/dev/null)" || pairs=""
  if [ -n "$pairs" ]; then
    while read -r id scope; do
      [ -n "$id" ] || continue
      claude plugin update -y --scope "${scope:-user}" "$id" </dev/null >/dev/null 2>&1 || true
      updated_any=1
    done <<FF_PAIRS
$pairs
FF_PAIRS
  fi
fi
if [ "$updated_any" -eq 0 ]; then
  # jq 不在 or JSON 解決不能の fallback: plain 出力から ID を拾う（scope は既定 user）
  ids="$(claude plugin list </dev/null 2>/dev/null | grep -oE 'ff-dev-toolkit@[A-Za-z0-9._-]+' | sort -u)" || ids=""
  for id in $ids; do
    claude plugin update -y "$id" </dev/null >/dev/null 2>&1 || true
  done
fi

exit 0
