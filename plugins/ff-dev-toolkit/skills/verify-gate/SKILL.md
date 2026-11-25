---
name: verify-gate
description: プロジェクトで「品質ゲートを回して」「pnpm verify:gate を実行して」と頼まれたときに使う。読み込んだ ff-dev-toolkit の実体を検証コマンドへ渡し、ゲートの結果と保存された HEAD 記録を確認する。
---

# プロジェクトの品質ゲートを実行する

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- grok CLIでは、Bash tool 環境の `${GROK_PLUGIN_ROOT}` があればそれを使う（skill 経路では未設定が普通なので、次項の `FF_DEV_TOOLKIT_SKILL_FILE` を渡す）
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスを `FF_DEV_TOOLKIT_SKILL_FILE` として固定し、`skills` が symlink でも物理パス（`cd -P` / `pwd -P`）で `../..` を解決する

このskillを実行するAI hostは、Bash tool呼び出しを組み立てるとき、skill loaderが返した実値で `FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` を実行し、同じshell script bodyでresourceを呼び出す。placeholderのまま実行したり、cache pathを推測して埋めたりしない。
plugin内ドキュメントの正本は、読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) である。consumerへコピーされた `docs/` や物理CWDを基準に解決しない。
review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を直接呼ぶhostだけが、同節のresolver + guard fence全体を読み、handoff設定・guard・resource呼び出しを同じshell script bodyで実行する。そのhostはtask workspace repository rootも `FF_DEV_TOOLKIT_PROJECT_ROOT` として同じBash tool呼び出しへ渡し、現在の物理CWDおよび `git rev-parse --show-toplevel` と一致することを実行前に確認する。review以外のresourceはこのreview専用guardを実行せず、固定したroot配下で各skillが指定するresourceだけを呼出直前に検証する。以下のBash例は、同じtool bodyで固定済みrootを使うcommand断片として扱う。

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

pnpm と toolkit の標準依存である Perl が使えるシェルで、対象プロジェクトの `package.json` に `verify:gate` スクリプトがあることを確認する。そのパッケージのディレクトリを作業ディレクトリに指定する。Codex では、今回読み込んだ **この** `SKILL.md` の絶対パスを使う。スキルと同じディレクトリの [実行スクリプト](scripts/run.sh) に、同じ呼び出しでそのパスを渡す。パスには読み込み元の実値を入れる。

```bash
FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>" bash "<このSKILL.mdのディレクトリ>/scripts/run.sh"
```

ホストが `CLAUDE_PLUGIN_ROOT` または `GROK_PLUGIN_ROOT` を渡す場合は、その配下の `skills/verify-gate/scripts/run.sh` を使える。

既定はプロジェクトの `pnpm verify:gate`。依頼に `--scope workspace` や `--suite diff` などの指定があれば、同じ引数を実行スクリプトの末尾へ渡す。実行スクリプトは一時 Git リポジトリで記録器の書き込みと書式を検査し、そのリポジトリを片付けてからゲートを起動する。実行スクリプト自体が見つからない場合は、toolkit を更新してスキルを再呼び出すよう案内する。

終了コードと実行した範囲を確認する。実行スクリプトが標準エラーに出す `GATE_RECORD_PATH` のファイルを読む。`record_path` にその出力の実値を入れ、次の出力を `GATE_RECORD_BEFORE` と照合する。ファイルの変更時刻には秒未満の値も含まれる。

導入先で `FF_GATE_RECORD_FILE` を設定している場合は、ゲートの記録先と照合にもその指定を使う。

```bash
record_metadata="$(LC_ALL=C TZ=UTC stat -c '%i %y %z' -- "$record_path" 2>/dev/null ||
                   LC_ALL=C TZ=UTC stat -f '%i %.9Fm %.9Fc' -- "$record_path" 2>/dev/null)" &&
  record_checksum="$(cksum < "$record_path")" &&
  printf '%s | %s\n' "$record_metadata" "$record_checksum"
```

終了コードが0で、`GATE_RECORD_START_DIRTY=no`、記録の `COMMIT` が `GATE_HEAD` と一致し、`DIRTY=no` かつ `STATUS` が `partial` または `pass` であることを確認する。`GATE_DIRTY_AT_START`、`GATE_STATUS`、`GATE_SUITES` が出る場合はそれらとも照合する。実行前は記録がなかった（`missing`）か、前後とも照合値を取得できて値が変わっていれば、検証後に同じ HEAD と範囲の記録を確認できたと報告する。共有の記録先では、前後差があっても書き込み元は特定できない。

同じ HEAD の既存記録が保持された場合は、今回の検証結果と記録が保持されたことを伝える。それ以外で変更を確認できなければ、記録の更新を確認できなかったと伝える。開始時の変更、`DIRTY=yes`、記録の読み取りや書き込みの失敗などがあれば、検証結果と確認できた記録の状態を伝える。
