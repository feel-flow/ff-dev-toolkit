# worktreeセッションのcleanup経路


PR headを保持する**自分の**worktreeから続ける場合は、PR番号・head/base・state=MERGEDを実測し、`git status --porcelain` が空であること、未pushコミットとknowledge保留が無いことを確かめる。`git fetch origin "+refs/heads/<base>:refs/remotes/origin/<base>"` の成功後、`git switch -c chore/post-<PR番号>-<セッション固有名> origin/<base>` で既存名を上書きしない一意の使い捨てブランチへ移る。失敗したら停止し、`reset --hard`・`switch -C`・他セッションのcheckout変更で押し切らない。

PR headでもbaseでもないブランチになったことを確認し、**PR番号を明示して** `/merge-cleanup <PR番号>` を実行する。これで上のswitchなし掃除モードへ入り、baseを保持する他worktreeへ触れずに進む。自分の現在のworktree自体は残る。リモートhead削除・ローカルhead削除・base最新化・残したworktreeをサマリーで個別に確認し、base復帰の見送りは見送りとして報告する。

その後の `/ace-curate <PR番号>` と `/retrospective` は、知見を書き始める**前**に同じ自分のworktreeを最新の `origin/<default-branch>` へdetachする（[ace-curateのworktree手順](../../ace-curate/references/curate.md#worktreeセッションからの知見記録)）。cleanupのbaseとrepositoryのdefaultを同一視しない。knowledgeのadd保留・未コミット変更がある状態で切り替えない。使い捨てブランチと現在のworktreeを残した事実も報告し、使用中のworktreeを削除しない。

## 取り残しブランチ

`worktree-agent-*` はworktree未使用・baseの祖先または同じbaseへマージ済みsame-repo PRのhead OID完全一致・origin同名refなしを全て実測してから削除する。保持中worktreeはunlock/removeせず、不明なら理由付きで残す。dry-runも同じ条件で候補を表示する。
