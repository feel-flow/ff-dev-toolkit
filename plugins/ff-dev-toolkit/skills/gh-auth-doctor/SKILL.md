---
name: gh-auth-doctor
description: gh の認証が壊れている文脈（このシェル / PowerShell / WSL）を `gh api user` で 1 回で測り、壊れている文脈にだけ復旧手順を出す。このシェルの gh は device flow で、利用者にコードを提示してブラウザ承認してもらう形で直す。「gh が 401」「Bad credentials」「gh auth login を求められた」「gh の認証が切れた」と言われたとき、または gh を使う手順が HTTP 401 / 未ログインで止まったときに使用。ログアウトは案内しない。
---

# gh 認証の診断と復旧

Windows の作業機では、gh が文脈ごとに別々に認証されうる — このシェル（Claude の Bash ツール）、
利用者の PowerShell、WSL。gh はトークンを既定で keyring へ保存するので `hosts.yml` を見比べても差が
出ず、`gh auth status` の文言も当てにならない。見分ける手段は各文脈で `gh api user` を実際に呼ぶ
ことだけで、本スキルはそれを 1 コマンドにまとめる。Mac / Linux では文脈は 1 つとして測る。

<!--af3e8ebef048545b-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- grok CLIでは、Bash tool 環境の `${GROK_PLUGIN_ROOT}` があればそれを使う（skill 経路では未設定が普通なので、次項の `FF_DEV_TOOLKIT_SKILL_FILE` を渡す）
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

## 診断

必要なものは bash 3.2 以降と gh。Windows（Git Bash）では `powershell.exe`（無ければ `pwsh.exe`）と
`wsl.exe` も使う。固定した root の `scripts/gh-auth-doctor.sh` の実在を確認して実行する。

<!--ebc6af8bbe8ab982-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/gh-auth-doctor.sh"
```

GitHub Enterprise は `--hostname HOST`、既定以外の WSL ディストリは `--wsl-distro NAME`、1 文脈あたりの
上限（既定 60 秒。GNU の `timeout` があるときだけ効く）は `--probe-timeout SECONDS` で渡す。
読み取りだけで、資格情報・設定には触れない。出力は文脈ごとの表と集計行で、要復旧の文脈には
`復旧（文脈）:`、判定不能の文脈には `確認（文脈）:` の行が続く。

| 文脈 | 測り方 |
| --- | --- |
| `bash` / `shell` | このシェルの `gh api user`（Windows では `bash`、Mac / Linux では `shell`） |
| `powershell` | このシェルから PowerShell を子プロセスとして起動し、その PATH の gh で `gh api user`。gh の参照先を変える環境変数（`GH_TOKEN` などのトークン・`GH_CONFIG_DIR`・`XDG_CONFIG_HOME`・`GH_HOST`）はこのシェルの値を外し、Windows に永続化された値（ユーザー → マシン）があればそれを戻して測る |
| `wsl` | `wsl.exe --exec` で既定（または `--wsl-distro`）のディストリの gh で `gh api user`。ログインプロファイルは読まないので、`~/.local/bin` を PATH へ足して探す。表にはディストリ名が出る |

<!--b3f5a7cec389f653-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

`powershell` の行は「このシェルの子の PowerShell」の結果で、利用者が開いている PowerShell ウィンドウと
環境が同じとは限らない。`bash` が要復旧・`powershell` が ok なのに利用者が「PowerShell でも通らない」と
言うときは、利用者自身の PowerShell で `gh api user --jq .login` を打ってもらって確かめる。

<!--b1482e5b5c7abaed-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

| 結果 | 意味 |
| --- | --- |
| `ok` | 認証済み（gh が rc 0 でログイン名を返した。Enterprise Managed Users の `handle_shortcode` 形を含む）。詳細はログイン名 |
| `要復旧` | gh が失敗し、HTTP 401（Bad credentials）か未ログイン（rc 4、または `gh auth login` を促す定型文）だった |
| `判定不能` | gh / PowerShell / wsl.exe の不在、WSL の起動失敗、応答なし、401 でも未ログインでもない失敗、ログイン名として読めない出力（空・`null`・複数行）。ok とは読まない |

<!--0e2e9bbe3ae80108-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

| rc（診断） | 意味 |
| --- | --- |
| 0 | 全文脈 ok |
| 3 | 要復旧の文脈がある（判定不能が混ざっていても 3） |
| 2 | 判定不能が残った（要復旧はない）。その文脈を使っていない作業機なら対象外として扱ってよいが、緑とは報告しない |
| 1 | 起動不能・不正引数・plugin root ガードの停止 |

## 復旧

壊れている文脈にだけ手を入れる。**どの文脈にもログアウトを案内しない** — keyring を共有する文脈では、
1 つのログアウトが他の文脈のトークンまで失効させる。

### このシェル（`bash` / `shell`）: device flow

利用者が PowerShell でログインし直しても、このシェルの gh には届かないことがある。このシェルで
device flow を起動し、利用者にはブラウザで承認だけしてもらう。

<!--ca87d3d6b1814c3f-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

1. **利用者と対話しているセッション**（サブエージェントではない側）から、ホストの背景実行で起動する。
   `login` は承認が済むまで終わらないので、前景で起動するとコードを利用者へ伝えられない。Claude Code
   では Bash ツールの `run_in_background`、背景実行を持たないホストでは末尾に `> <ログ> 2>&1 &` を付けて
   起動し、そのログを読む（この形では終了コードを受け取れないので、最後に出る `LOGIN_RC=<rc>` 行で読む。
   ホストがツール呼び出しの終わりにプロセスを止める場合は、その時点で gh も止まり承認は保存されない）:

<!--950bad2d6f0c841a-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

   ```bash
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/gh-auth-doctor.sh" login
   ```

2. 出力の `DEVICE_CODE=` と `DEVICE_URL=` を読み、そのまま利用者へ提示して「URL を開いてコードを入力し、
   承認してください」と頼む。コードの有効期限は約 15 分
3. 終わるのを待ち、`READBACK=ok <ログイン名>` を確かめる（rc 0。`LOGIN_RC=0`）。それ以外は下の表で読み、
   診断をもう一度回して状態を報告する

| rc（login） | 意味 |
| --- | --- |
| 0 | read-back（`gh api user`）で認証を確認した |
| 3 | read-back が ok にならない（承認されなかった・`--approve-wait` で打ち切った・別の失敗） |
| 2 | gh から one-time code を読み取れない（`--code-wait` 秒以内に出ない・gh が先に終わった）。`--log FILE` を付けて再実行すると gh の出力を読める |
| 1 | 起動不能・不正引数・このシェルに環境変数のトークンがある |
| 129 / 130 / 143 | 承認待ちの途中でホストに止められた（HUP / INT / TERM）。gh は止めてあり、承認は保存されない |

<!--211a9981334192c5-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

`--code-wait`（既定 60 秒）はコードが出るまでの上限で、超えたら gh を止めて rc 2 で終わる（read-back
しない）。`--approve-wait`（既定 960 秒）は承認を待つ上限で、超えたら gh を止めて read-back する。秒数は
1〜999999。gh は TERM で止まらなければ KILL で止め、それでも残れば警告を出す。gh の出力は既定では
一時領域に置いて終了時に消し、`--log FILE` を渡したときだけトークン様の文字列を伏せて残す
（`DEVICE_LOG=` に置き場が出る。途中で止められた回も伏せる）。本スキルはトークンを
読まない・出さない（`gh auth token` も `--show-token` も使わない）。トークン様の文字列を見つけても
転記しない。

<!--5f4a6e25d1859a6b-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

このシェルに環境変数のトークン（github.com と `*.ghe.com` では `GH_TOKEN` / `GITHUB_TOKEN`、GitHub
Enterprise Server では `GH_ENTERPRISE_TOKEN` / `GITHUB_ENTERPRISE_TOKEN`。ホスト名は小文字へ揃えて見分ける）が
あると gh はそちらを優先するので、device flow で入れ直しても直らない。`login` は起動前に止まり（rc 1）、診断の復旧行も「環境変数を外すか有効な値にする」になる。

<!--a44cd5f81666540c-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

### PowerShell（`powershell`）

利用者の PowerShell で `gh auth login -h <ホスト名> -w` を実行してもらう（ホスト名は診断の見出しのもの）。
ログアウトは頼まない。

<!--b89fcce4db413ba0-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

### WSL（`wsl`）

利用者の PowerShell から、表に出たディストリ名で次の 2 つを順に打ってもらう（WSL のプロンプトに
入らせない — 「WSL で実行して」と書くと PowerShell の gh で実行され、WSL は直らない）。ディストリ名が
空の回は `-d` を省いた形（既定のディストリ）が案内される。英数字・`.`・`_`・`-` 以外を含む名前は案内へ
埋め込まず、その文脈を判定不能にする（`--wsl-distro` で名指しして測り直す）:

<!--67d9369944b327e9-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

```powershell
wsl -d Ubuntu -- gh auth login -h github.com -w
wsl -d Ubuntu -- gh auth setup-git
```

<!--fba0406a0aa0f1ac-->
分類: CLI固有: gh / keyring をシェル・PowerShell・WSL ごとに実測する診断のため MCP 認証では代替できない。gh 不在は対象不在として停止し、MCP 成功を gh 復旧済みとしない

復旧のあとは診断をもう一度回し、直した文脈が `ok` になったことを確かめてから元の作業へ戻る。

## してはいけないこと

- 壊れていない文脈の再ログイン・ログアウトを案内しない
- トークンの値を出力・保存・Issue / PR / ログへ転記しない
- `判定不能` を ok として報告しない（rc 2 は「確かめられなかった」であって「問題なし」ではない）
