---
name: check-plugin-versions
description: Claude Code のインストール済みプラグインと Claude Desktop セッションの版を GitHub の参照版と照合する。「プラグインが最新か確認して」「古いスキルで動いていないか調べて」と言われたときに使用。更新・再インストールは実行しない。
---

# プラグインバージョン検査

GitHub・ローカル登録・Desktop スナップショットを照合して、古い実体と確認できない実体を区別する。
実行ホストが Codex でも検査対象は Claude の登録形式であり、Codex のインストール一覧は検査しない。

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスを `FF_DEV_TOOLKIT_SKILL_FILE` として固定し、そこから `../..` を解決する

このskillを実行するAI hostは、Bash tool呼び出しを組み立てるとき、skill loaderが返した実値で `FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` を実行し、同じshell script bodyでresourceを呼び出す。placeholderのまま実行したり、cache pathを推測して埋めたりしない。
plugin内ドキュメントの正本は、読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) である。consumerへコピーされた `docs/` や物理CWDを基準に解決しない。
review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を直接呼ぶhostだけが、同節のresolver + guard fence全体を読み、handoff設定・guard・resource呼び出しを同じshell script bodyで実行する。そのhostはtask workspace repository rootも `FF_DEV_TOOLKIT_PROJECT_ROOT` として同じBash tool呼び出しへ渡し、現在の物理CWDおよび `git rev-parse --show-toplevel` と一致することを実行前に確認する。review以外のresourceはこのreview専用guardを実行せず、固定したroot配下で各skillが指定するresourceだけを呼出直前に検証する。以下のBash例は、同じtool bodyで固定済みrootを使うcommand断片として扱う。

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

<!-- ff-dev-toolkit-plugin-root-guard:start -->
固定したrootが消えた状態で手順を先へ進めないため、同梱resourceを呼ぶBash tool呼び出しの本文冒頭で次のguardを実行する。手順書のguardは実行環境の `set -e` を仮定できないので、`||` の右辺で `false` を返す形ではなくifで構造的に停止する。

```bash
if [ -z "${FF_DEV_TOOLKIT_ROOT:-}" ] || [ ! -d "${FF_DEV_TOOLKIT_ROOT}" ]; then
  echo "ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが解決できません）" >&2
  exit 2
fi
```

<!-- ff-dev-toolkit-plugin-root-guard:end -->

## 実行

必要なものは bash 3.2 以降、jq、GitHub にアクセスできる gh。directory source は git origin を読む。
固定した root の `scripts/check-plugin-versions.sh` と `scripts/lib/plugin-versions.jq` の実在を確認して実行する。

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-plugin-versions.sh" --json
```

既定では `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/` の登録ファイルと
`$HOME/Library/Application Support/Claude/local-agent-mode-sessions/` を読む。
別環境を調べるときだけ `--config-dir PATH` と `--sessions-dir PATH` を渡す。
一時ファイル以外は書き換えない。更新コマンドや Desktop 操作へ自動的に進まない。

## 結果の読み方

- `outdated`（更新あり）: プラグイン名・登録 marketplace・インストール版と参照版を示す。
- `current`（最新）/ `ahead`（ローカル先行）: 参照先に対する判定。明示 ref/sha があればその値も示し、default branch の最新と混同しない。
- `unknown`（確認不可）: 権限・通信失敗、版/SHA 不足、非対応 source、名前の曖昧さなど。最新へ読み替えず理由を示す。
- Desktop の更新あり: セッションごとに報告し、「ローカル更新では解消できない。Desktop でプラグインを再登録し、新しいセッションで再検査」を案内する。保存済みセッションの走査であり、現在実行中のセッションを特定したとは言わない。

終了コード 0 は検査完了であり「全件最新」と同義ではない。2 は確認不可を含む部分結果、1 は起動不能/引数エラー。
`summary` と `results` の成功分を読み、2 のときも結果を捨てない。private repository 名・セッション ID 等の実測結果を公開 Issue/PR へ転載しない。

version 宣言がない対象は、directory の最終変更 SHA を base、installed SHA を head とする
GitHub compare の `behind_by > 0` が更新の根拠。単純な SHA の不一致や manifest.updatedAt では判断しない。

## 自己言及の限界

古い toolkit 内の検査器には新しい検査機能や修正がない。このスキルだけで自分自身の最新性を保証できない。
Desktop の乖離は、最新の検査器を使える外部の CLI セッションから保存済みスナップショットを検査して検出する。
検査器を入手する更新操作や Desktop 再登録はユーザーの明示依頼で別途行い、検査成功を更新成功とは扱わない。
