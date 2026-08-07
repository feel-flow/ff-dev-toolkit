#!/usr/bin/env bash
#
# 推奨カスタムラベルの冪等セットアップ（Issue #298）。
#
# `05-operations/deployment/github-setup.md` の「推奨ラベル構成」が定めるカスタム
# ラベル（バージョニング + 緊急度）のうち、対象リポジトリに**存在しないものだけ**を
# 作成する。既存ラベルには一切触れない（色・説明の上書きもしない）— 消費プロジェクト
# が意図的に変えた色や説明を、セットアップの再実行が黙って戻すのを防ぐため。
# `gh label create --force` を使わないのはこの理由による（--force は不在時 create と
# 既存時 update の両対応で、後者が「既存は変更しない」という本スクリプトの契約に反する）。
#
# fail-closed: ラベル一覧の照会を信用できない場合（コマンド失敗・空の一覧・取得上限
# 到達）は、**1 件も作成せず**非 0 で終了する。「存在しない」と誤断定したまま作成に
# 進むと、実在するラベルへの create 失敗や重複整備が起きる。読むだけの操作は続行して
# よいが、書き込む操作は確証がなければ止まる（起票側 verify-then-skip の fail-soft
# とは安全側の向きが逆になる。あちらは書き込まないから続行できる）。
#
# ラベル定義の正本（SSOT）は下の LABEL_DEFS ブロックで、github-setup.md の
# 「カスタムラベル（追加が必要）」表・手動セットアップ例との一致を
# `plugins/ff-dev-toolkit/tests/github-labels-setup/verify.sh` が検査する。
# 定義を変えるときは github-setup.md と同時に変えること（片方だけ直すと red になる）。
# この検査は ff-dev-toolkit リポジトリ側でのみ有効で、消費プロジェクトへの
# コピーは検査されない。コピーを直接編集せず、toolkit 側の更新を取り直すこと。
#
# bash 3.2（macOS 標準）互換: mapfile / 連想配列は使わない。配列自体も避け、
# 結果は空白区切りの文字列とカウンタで持つ（`set -u` 下の空配列展開の罠を回避）。
#
# 使い方:
#   ./scripts/setup-github-labels.sh                # カレントの gh リポジトリに適用
#   ./scripts/setup-github-labels.sh --repo OWNER/REPO
#
# 前提: GitHub CLI（gh）が認証済みであること。

set -euo pipefail

repo=""
if [ "${1:-}" = "--repo" ]; then
  repo="${2:-}"
  if [ -z "$repo" ]; then
    echo "✗ --repo にはリポジトリ名（OWNER/REPO）が必要です" >&2
    exit 1
  fi
  shift 2
fi
# 余剰引数は fail-closed で拒否する。`--dry-run` のような存在しないオプションを
# 黙って無視すると、「dry-run したつもりが本番書き込み」という本スクリプトが
# 最も避けたい事故の形になる。
if [ "$#" -gt 0 ]; then
  echo "✗ 未知の引数です: $*（使い方: $0 [--repo OWNER/REPO]）" >&2
  exit 1
fi

# 対象リポジトリを明示的に確定する。GH_REPO や cwd の暗黙値に任せたまま進めると、
# 意図しないリポジトリのラベルを増やす事故になる。以後の gh 操作すべてに --repo を付ける。
if [ -z "$repo" ]; then
  if ! repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || [ -z "$repo" ]; then
    echo "✗ 対象リポジトリを確定できませんでした。--repo OWNER/REPO を指定してください" >&2
    exit 1
  fi
fi

# ---- ラベル定義（SSOT） --------------------------------------------------------
# 形式: name|color|description（color は # なしの 6 桁 hex。name は小文字で統一）。
# github-setup.md の「カスタムラベル（追加が必要）」表と一致させること。
# LABEL_DEFS_BEGIN
LABEL_DEFS='major|D93F0B|メジャーバージョン変更（破壊的変更）
minor|FBCA04|マイナーバージョン変更（新機能追加）
patch|5FBF4A|パッチバージョン変更（バグ修正）
hotfix|E11D21|緊急修正（本番環境の重大な不具合）
urgent|FF6B00|緊急対応が必要'
# LABEL_DEFS_END

# ---- 実在確認（信用できない一覧では作成しない） --------------------------------
# ⚠️ `--limit` は必須。省略時の既定は 30 件で、ラベルが 30 個を超えるリポジトリでは
#    実在するラベルが「見つからない」と誤判定される。
label_limit=200
if ! available_labels="$(gh label list --repo "$repo" --limit "$label_limit" --json name --jq '.[].name')"; then
  echo "✗ ラベル一覧を取得できませんでした（$repo）。実在を確認できないため作成しません" >&2
  exit 1
fi
# 終了コード 0 でも一覧を信用できない 2 経路を「確認できなかった」へ倒す。
#   空: ラベルが 1 つも無いリポジトリと、取得が機能しなかった場合を出力から区別できない
#   上限到達: 打ち切られた可能性があり、その先にあるラベルの不在を主張できない
if [ -z "$available_labels" ]; then
  echo "✗ ラベル一覧が空でした（$repo）。取得が機能しなかった場合と区別できないため作成しません" >&2
  exit 1
fi
# 件数は先に確定し、数えられなかった場合も fail-closed に倒す。`if` の条件式に
# 直接埋め込むと、wc の失敗で空文字になったとき test がエラー（偽扱い）になり、
# 上限ガードだけが黙って素通りする（fail-open への反転）。
label_count="$(printf '%s\n' "$available_labels" | wc -l | tr -d '[:space:]')" || label_count=""
case "$label_count" in
  ''|*[!0-9]*)
    echo "✗ ラベル一覧の件数を確定できませんでした（$repo）。不在を確認できないため作成しません" >&2
    exit 1 ;;
esac
if [ "$label_count" -ge "$label_limit" ]; then
  echo "✗ ラベル一覧が取得上限（$label_limit 件）に達しました（$repo）。不在を確認できないため作成しません" >&2
  exit 1
fi

# GitHub のラベル名は大文字小文字を区別しない一意制約を持つため、照合も
# case-insensitive にする。`Major` が既存のリポジトリで `major` を作りにいくと
# already exists で毎回失敗し、冪等が破れる（SSOT のラベル名は小文字で統一）。
available_labels_lc="$(printf '%s\n' "$available_labels" | tr '[:upper:]' '[:lower:]')"

# ---- 不足分だけ作成（既存には触れない） ----------------------------------------
# 結果はヘッダ記載のとおり空白区切りの文字列とカウンタで持つ（bash 3.2 の
# `set -u` では空配列の展開・参照が落ちる形があるため。ラベル名に空白は使わない前提）。
created=""
created_count=0
skipped_existing=""
skipped_count=0
failed=""
failed_count=0
while IFS='|' read -r name color description; do
  [ -n "$name" ] || continue
  # SSOT の定義行が壊れていたら（color / description 欠け）作成に進まない。
  # 欠けたまま gh へ渡すと、引数解釈のずれ方によっては意図しないラベルが生える。
  if [ -z "$color" ] || [ -z "$description" ]; then
    echo "✗ LABEL_DEFS の定義行が不正です（name|color|description 形式）: ${name}" >&2
    exit 1
  fi
  # 完全一致（行単位）を外部プロセスなしで判定する。`grep -q` へパイプで流し込む
  # 書き方は、一致した時点で producer が SIGPIPE で落ち、`set -o pipefail` 下で
  # 「一致したのに失敗」に反転しうるため使わない。
  if [[ $'\n'"$available_labels_lc"$'\n' == *$'\n'"$name"$'\n'* ]]; then
    skipped_existing="${skipped_existing:+$skipped_existing }$name"
    skipped_count=$((skipped_count + 1))
    continue
  fi
  if gh label create "$name" --repo "$repo" --description "$description" --color "$color"; then
    created="${created:+$created }$name"
    created_count=$((created_count + 1))
  else
    failed="${failed:+$failed }$name"
    failed_count=$((failed_count + 1))
  fi
done <<EOF
$LABEL_DEFS
EOF

# ---- 報告（報告は記憶ではなくこの出力を写す） ----------------------------------
printf 'REPO=%s\n' "$repo"
printf 'CREATED=%s\n' "$created"
printf 'SKIPPED_EXISTING=%s\n' "$skipped_existing"
printf 'FAILED=%s\n' "$failed"

if [ "$failed_count" -gt 0 ]; then
  echo "✗ 作成に失敗したラベルがあります: $failed" >&2
  exit 1
fi
echo "✓ 推奨カスタムラベルの整備が完了しました（作成 ${created_count} 件 / 既存スキップ ${skipped_count} 件）"
