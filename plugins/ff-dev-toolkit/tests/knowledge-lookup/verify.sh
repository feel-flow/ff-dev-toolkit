#!/usr/bin/env bash
# 空振り検出: store 解決の lib の不在・途中切れは K36 が検索前の rc=2 を要求する。入口から完了印の照合を外した隔離コピーでは K36 の「最終行が切れた回」が赤（rc=1。2026-11-08 macOS / Bash 3.2）。
# 空振り検出: 未閉鎖フェンスの拒否、カテゴリ入口の非ディレクトリ拒否を別々に弱めた隔離コピーで、K35 相当の期待値が赤。前後対照各 5 件と、壊れた symlink を拒否する正常系を実測（2026-11-06 macOS / Bash 3.2）。
# 空振り検出: 索引省略の空判定分岐・件数の照合・壊れた見出しの検出・重複設定の拒否を個別に弱めた隔離コピーでは、各変異に対応する K34 の期待値と不一致。無変異の前後対照は各 4 件成功（2026-11-06 macOS / Bash 3.2）。
# 空振り検出: 物理identityキー・既定照合列・物理role・論理roleを各1件戻す4変異は構文0の後、別名/除外の針でrc=1。前後privacy51件、既存分を含む全体135件pass（2026-10-29実測）。
# 空振り検出: 記録候補を論理leafから実体pathnameへ戻す変異は構文0の後、配置/隣接categoryの2針が赤（rc=1）。前後対照privacy40件pass（2026-10-29実測）。
# 空振り検出: privacy対照29件pass。root包含除去・UTF-8検査no-op・上限倍増・Changelog再読・空privacy集合の5変異は、構文成功後に各対象の針でrc=1（2026-10-29、隔離コピーで前後対照を実測）。
# 空振り検出: 境界のドライブ付き判定（`[A-Za-z]:[/\\]*` の行）を消して `/` 始まりだけへ戻す変異で W15 が赤（mingw 側が cwd 連結、rc=1）、`[A-Za-z]:/*` へ狭める変異でも W15 が赤（`C:\…/…` 側が cwd 連結、rc=1）。正常対照は 146 件成功（2026-10-30 macOS 実測）。Windows の Git Bash では W15 の実機分岐が同じ「行を消す」変異で `✗ W15`（rc=2 と cwd 連結のパスを名指し、suite は打ち切らない）、正常対照は windows-acl.sh 15 件成功（2026-10-30 Windows Server 2022 実測）。
# 空振り検出: symlink を作れない Git Bash の部分 skip（Issue `#2539`）は、OS 判定を linux-gnu へ固定する変異（probe が symlink を作れないと測っても skip しない＝Linux / macOS の振る舞い）で K8・K27・K28・K31 が赤、read-boundary.sh の相対リンク作成で suite が途中終了（rc=1）。正常対照は既定の TMPDIR（AppData\Local の下）のまま 114 件成功で W8・W9・W15 の実機分岐まで走る。変更前は既定の TMPDIR で K1 以降がほぼ全件赤、TMPDIR を移しても K8 / K27 / K28 / K31 の赤と同じ途中終了（2026-10-30 Windows Server 2022・開発者モードなしの Git Bash 実測）。
#
# scripts/knowledge-lookup.sh（ACE Playbook と観測台帳の統合読み出し器）の振る舞い検査（Issue `#1778`）。
#
# 観測台帳は書き込み専用の store になっていて、実装中に引く経路も、振り返りが promoted × open を
# 突き合わせる経路も無かった。読み側を配線するスクリプトを足したが、**状態による切り分け**
# （promoted / mitigated を「未対策」として返さない）と**針が当たらない入力の既定**（store 不在・
# 読めない・見出し書式の変更・配置の曖昧さ）は、動かさないと測れない。本 suite は隔離 fixture で
# 実際に走らせ、出力のグループ分け・RECORD 行・終了コードを照合する。
#
# 検査:
#   K1.  両 store が在るとき、ACE は active / deprecated に、台帳は active / promoted / mitigated に
#        分かれて出る（見出しの下に居るエントリが状態と一致する。promoted / mitigated が
#        「未対策」グループへ混ざらない）
#   K2.  archived（台帳）と archive/（ACE）は既定で出ず、--include-archived で出る
#   K3.  RECORD 行がヒット ID を両 store ぶん列挙する（記録の契約への転記形）
#   K4.  0 件ヒットは rc=0 で RECORD に `0 件`
#   K5.  Playbook だけ不在 → rc=0 / RECORD ace=`Playbook なし`。台帳だけ不在 → rc=0 / obs=`台帳なし`
#   K6.  両 store 不在 → rc=2（「検索を実施した」と記録できる対象が無い）
#   K7.  台帳の見出し書式が変わって 1 件も認識できない → 0 件ヒットの緑にせず `読み取り失敗`
#   K8.  台帳が在るのに読めない → `読み取り失敗`（未導入へ吸収しない）。root 実行時は skip
#   K9.  既定パスに無く root 配下に 1 件だけ在る store は探索で採る。2 件在れば曖昧として採らない
#   K10. --all は AND、既定は OR
#   K11. --format tsv は 1 行 1 エントリで store / id / status / meta / title / location の 6 列
#   K12. キーワード無し → rc=1（usage）
#   K13. --promoted-open: gh の open 一覧に在る Issue を持つ promoted だけを列挙し、無いものは
#        出さない。gh が失敗した repo の参照は隠さず `未確認` として列挙する
#   K14. --promoted-open --offline: 全 promoted が `未確認` として出る（隠さない）
#   K15. --promoted-open で台帳不在 → rc=2
#   K17. コードフェンス内の記入例（テンプレートの `### OBS-XXX:` / `### ACE-XXX:`）を実エントリとして
#        返さない。テンプレート直後の空 store は 0 件 / empty、記入例だけ残して実見出しを壊した台帳は
#        rc=2（記入例で認識件数を作らない）
#   K19. 注記付きの複数 Issue は参照だけで state を引き、注記・非 Issue 参照・修飾なしを保持し、表示注記は判定に使わない
#   K18. live エントリが無い Playbook（全件 archive 済み）でも --include-archived で archive を返す
#   K20. playbook/ のサブディレクトリにあるエントリも返す（件数ゲートと同じ走査範囲。Issue `#2082`）。
#        退避先 _archive/（入れ子を含む）と . 始まりのディレクトリは既定で辿らず、退避先は --include-archived で出る
#   K16. gh が stdin を読み切ってもエントリが欠けない（read ループは fd 3・gh は `</dev/null` の
#        二重防御。片方だけ外しても欠けないため単独の変異では赤にならず、両方外すと赤になる）
#   K21. awk / tr / sed の起動回数がエントリ数に比例しない（4 件と 40 件の台帳で同じ回数。キーワード
#        検索と --promoted-open の両方）。Windows の Git Bash ではプロセス起動 1 回が 0.1 秒を超え、
#        エントリごとの起動は約 350 件の台帳の --promoted-open を 6 分超にしていた
#   K32. 読むファイル 1 件あたりの stat / mktemp / head / tr / awk の起動が Windows 7 回・Linux 8 回以下（カテゴリ 1 件と
#        5 件の差。macOS は回数がパスの深さで変わるので skip。Issue `#2477`）。同じ鎖の検査・同じ stat の繰り返しと
#        1 バイトずつの read が、Windows の Git Bash で 1 回の検索を約 70 秒にしていた
#   K22. 記録済み配置（AGENTS.md のリンク先・docs/MASTER.md の記載ファイル相対リンク）が指す
#        docs-template/08-knowledge/PLAYBOOK.md を ok として検索し、--resolve-playbook も同じ配置を返す（Issue `#2142`）
#   K23. ACE_PLAYBOOK_PATH の Playbook を採る。実在しない値は読み取り失敗（探索で上書きしない）、
#        --playbook が優先、空白だけの値は未設定と同じ
#   K24. 記録も環境変数も無い回は docs-template/ を探索で採らない。記録が plugin 同梱テンプレート
#        （.claude-plugin/plugin.json を持つ dir 直下の docs-template/）を指しても採らない
#   K25. 記録済み配置が 2 件なら曖昧（rc=2 / STATE=ambiguous）。既定パスを含むなら既定パスを採る。
#        既定パスに実体があるのに記録がそれを含まなければ、記録が 1 件でも曖昧
#   K26. /ace-curate・/ace-refine が knowledge-lookup.sh --resolve-playbook を呼び、検索と解決が同じ配置を返す
#   K27. 記録段は root の外・ファイル自体の symlink・node_modules/・絶対パスの記載を候補に数えない
#   K29. ファイル名だけの ACE_PLAYBOOK_PATH でも playbook/ のカテゴリファイルを引き、非 ASCII を含む記録パスを切らない
#   W1〜W14. 読み取り境界の Windows 経路（windows-acl.sh。Issue `#2461`）: SystemRoot の綴りに依らず ACL の検査まで
#        進む・常駐対応 shell は helper を 1 回だけ起動し、非対応 shell は要求ごとに起動する・止めた祖先と SID と TMPDIR の案内を出す・TMPDIR の祖先が
#        ACL の判定で通らなければ状態ディレクトリ配下へ移して移したことを出し、そこも通らなければ両方を名指して止める
#        （判定以外の拒否では移さない）・応答全体の期限・
#        helper が判定できなかったパスの理由・素の wait が helper を待たない・相対の綴りを止める。
#        W8〜W9 は Windows の Git Bash でだけ、実 ACL と capability SID の ACE で確かめる。
#        常駐 helper の経路でだけ成立する W6（別の要求の応答を読み飛ばす）・W7（helper の死で shell が落ちない）と
#        常駐側の W16 は suite knowledge-lookup-resident-acl へ分けた（coproc の無い shell では suite ごと skip。Issue `#2711`）
#   W15. C:/… と C:\…/… の綴りで読み込んだ境界は helper のパスを cwd へ連結しない（Issue `#2530`）。Windows の Git Bash では
#        実ドライブの綴りで helper を見つけ、他のホストでは cwd 下の C: ディレクトリで MINGW（そのまま）と他の OS（連結）を分ける
#   W16. ACL helper は 1 回きりの起動で PSModulePath を受け取らず、呼び出し元の値は変わらない（Issue `#2566`）。ここでは
#        常駐を持たない shell の 1 回きりの起動だけを測り、常駐側は knowledge-lookup-resident-acl が測る
#   W17. Windows の Git Bash で PowerShell 7 を入れた機械では、PowerShell 7 の PSModulePath を受け継いでも実 ACL の検査が判定を返す
#   G1〜G12. 読み取る対象（root かその祖先）を境界が場所を名指して止めたときの次の一手（root-stop-guide.sh。
#        Issue `#2648`）: 境界の行をそのまま通し、stderr の末尾 3 行を停止文の共通形で終える・出した
#        `git worktree add -f --detach` をそのまま実行できる・置き場に前の worktree が残る 2 回目は switch を出す・
#        同じ名前の別物は避ける・既定の置き場も通らない回と git リポジトリでない root にはコマンドを約束しない・
#        場所の名指しが無い拒否には何も足さない・通る root は従来どおり・stop-block.sh を読めない配布物でも 3 行で止まる・
#        --root 無し（cwd から解決）でも同じ（G10）・下位ディレクトリの root は worktree の中の同じ場所を指す（G11）・
#        フォルダーだけ消えて登録が残った前の worktree でも通る（G12）。
#        stub の Windows（windows-acl-fixture.sh）で実スクリプトを流すので、どの OS でも実行する
#   K47. --each（語ごとの検索。Issue `#2921`）: 渡した順に語ごとの節と `RECORD each … keyword=<語>` を返し SUMMARY は 1 行・
#        語ごとの RECORD は単独で引いた回と同じ ID・重なるヒットは和集合で数える・空白だけの語は数えず空白入りの語は行末まで・
#        --impl / --class / --all / 他モードとの併用と語なし・改行入りの語は理由を名指して rc=1・-- の後ろの語はオプションと同じ綴りでも語（K47h）・
#        台帳側の obs= と gh の照会回数（K47i）・tsv は 6 列と RECORD を保つ・保留候補と
#        未反映も語ごとに記録・/ace-curate の重複照合の手順が --each の 1 回の呼び出しを指す
#   K28. --resolve-playbook の出力契約（unreadable の PATH、相対指定の REL、root 内外は実体で判定、
#        symlink ファイルは実体が root 内のときだけ REL、キーワード拒否）
#
# 空振り検出: 参照抽出を 0 件一致へ変える／判定を表示注記へ戻す／doc: の無照会を外す各変異で K19 が赤（rc=1）、前後の正常対照は46件成功（2026-10-05実測）。参照の不検出・注記の誤読・非 Issue の誤照会を緑にしない。
# 空振り検出: knowledge-lookup.sh の find を -maxdepth 1 へ戻す変異で K20 のサブディレクトリ検出が赤、prune から _archive を外す変異で K20 の既定除外が赤（2026-10-08 実測）。
# 空振り検出: 両 store を置かない root を与えると K6 が rc=2 を要求し、台帳の見出しを `### OBS 001 …`（コロン無し）へ変えると K7 が `読み取り失敗` を要求する（2026-09-19 実測。スクリプト側の noentry 判定を `empty` へ倒す変異で K7 が赤、両不在の rc=2 を rc=0 へ倒す変異で K6 が赤）。
# 空振り検出: K21 は変更前の実装（エントリごとに meta_of の `$(printf | tr | awk)` を起動）へ戻すと 2 件赤（promoted-open 4 件 74 回 / 40 件 650 回、検索 84 回 / 660 回）、annotate_refs の空白除去だけを要素ごとの sed へ戻す変異でも 2 件赤（15 回 / 69 回）。shim が 1 回も呼ばれない回は「測れていない」として赤にする（2026-10-16 Git Bash 実測）。
# 空振り検出: K32 は Windows 11 の Git Bash で、変更前の 0.172.0 が 1 件あたり 12 回（カテゴリ 1 件 74 回 / 5 件 122 回）、変更後が 7 回（54 回 / 82 回）で、上限 7 を超える側へ倒れる。Linux（WSL）の変更後は 8 回（61 回 / 93 回）。件数を増やしても回数が増えない回は「測れていない」として赤にする（2026-10-30 実測、Issue `#2477`）。1 バイトずつの read へ戻す変異は外部プロセスを増やさない性能の後退で、K32 でも K31 の忠実度の検査でも見えない（未検査として名指す）。
# 空振り検出: promoted の closed 説明を旧「対策済みまたは再発」へ戻す／mitigated の未解消再発確認を旧説明へ戻すと各 rc=1、正常対照は38件pass（2026-09-28実測）。状態名の接頭辞だけが残っても意味の欠落を緑にしない。
# 空振り検出: resolve_playbook へ 1 件ずつ当てた 9 変異 — 記録段の削除・記録段で docs-template を一律除外・plugin 同梱テンプレートの除外を外す・曖昧時に先頭を採る・既定パス優先を外す・env 段の削除・env の空白判定を外す・旧 resolve_store へ戻す・記載ファイル相対の解決を外す — がすべて K22〜K26 のいずれかで赤（1〜12 件）、正常対照は 69 件成功（2026-10-18 実測）。
# 空振り検出: レビュー対応後の 7 変異 — 記録段の symlink 除外・root 前置照合・node_modules 除外を外す、記録 1 件で実在する既定パスを置き換える、--resolve-playbook の絶対パス実体化を外す、symlink ファイルの実体確認を外す — がそれぞれ K25 / K27 / K28 で赤（1〜2 件）、正常対照は 82 件成功（2026-10-18 実測）。awk が読める記載ファイルで失敗する分岐（読み取り失敗の rc=2）は再現手段が無く未検査。
# 空振り検出: 検索・解決の前に ACE_INDEX を実体化する処理を外すと K28 が 4 件赤、非 ASCII まで含める 2 本目のトークン抽出を外すと K29 が赤（rc=2 / absent）、正常対照は 84 件成功（2026-10-18 実測）。
# 空振り検出: windows-acl.sh は、隔離コピーへ 1 件ずつ当てた変異 — helper の場所を SystemRoot だけから求める（W1〜W8 ほか 10 件赤）・helper を常駐させない（W2 / W7 / W11）・止めた場所の名指しを外す（W3〜W6 / W8 / W11 / W12）・作業場所の代替を外す（W4 / W5 / W8）・ACL の判定以外の拒否でも代替へ移す（W12）・応答全体の期限を行ごとの 10 秒へ戻す（W10）・helper が判定できなかった理由の名指しを外す（W11 / W12）・helper を disown しない（W13 で素の wait が止まり suite が打ち切られる）・生存確認と subshell を外して死んだ helper へ直接書く（W7） — がすべて赤、正常対照は 13 件成功（2026-10-29 Windows 11 ARM64 の Git Bash 実測。W6 / W7 は Issue `#2711` で suite knowledge-lookup-resident-acl へ移したので、この行は移す前の実測）。helper を kill で止める形は MSYS では包み側のプロセスにしか届かず死を作れなかったため、stub の quit 要求で止める。相対の綴りの無限ループへ戻す変異は suite ごと止まるので当てていない（W14 は戻り値と診断で止めたことを見る）。
# 空振り検出: W16〜W17（Issue `#2566`）は、隔離コピーへ当てた 3 変異 — 常駐 helper の起動から PSModulePath を外す処理を消す・1 回きりの起動から消す・両方から消す — がすべて W16 で赤（stub が受け取った値を名指す）、常駐側を消す 2 変異は W17 も赤（read-unverifiable）。正常対照は windows-acl.sh 17 件成功（2026-11-01 Windows 11 ARM64 の Git Bash 実測。WSL の Linux でも 3 変異が W16 で赤、正常対照 14 件成功）。値は reader を source する前の環境で渡す — source が常駐 helper を起動するので、snippet の中の export では常駐側の変異が空振りする（実測）。
# 空振り検出: 起動 shell の常駐機能は reader の状態と独立に probe する。macOS Bash 3.2 の正常対照は10件成功（合成9case＋集合照合）。probe空/未知/失敗・常駐対応の偽宣言・W2/W11のone-shot起動数を1へ戻す・W6/W7の分岐逆転・W11の後続要求削除・case数0・途中return・入力空/不在・完了名だけの14変異は各rc1（2026-10-29実測）。W8〜W9の実Windows限定も維持。今回の常駐対応shellと実Windowsの再実測は未実施。W6/W7はIssue `#2711` でsuite knowledge-lookup-resident-aclへ移したので、この行は移す前の実測。
# 空振り検出: W6 / W7 と常駐側の W16 を suite knowledge-lookup-resident-acl へ分けた後（Issue `#2711`）、windows-acl.sh は bash 版で部分 skip しない。1 回きりの起動の W16 は timeout(1) が無い機械では skip せず赤にする（W1 と同じ前提。timeout(1) の無い機械では未実測）。正常対照は /bin/bash 3.2 で 164 件成功（合成 10 case、W16 は起動 2 回）、Homebrew bash 5.3 を PATH の先頭に置いて 163 件成功（合成 9 case）。部分 skip は K32 と W8〜W9 の 2 行だけ（2026-11-08 macOS 実測）。
# 空振り検出: 実 Windows 分岐（W8〜W9 / W15 / W17）の判定は windows-acl.sh で `uname` を読まず、能力層の ff_host_is_msys（scripts/lib/wsl-notice.sh。ADR-084 決定 3）へ 1 回だけ委ねる（Issue `#2711`）。隔離コピーで判定を msys 固定にすると macOS でも実機分岐へ入り suite が rc=127 で打ち切られ、wsl-notice.sh を消すと能力層を読めない旨を名指して赤（2026-11-08 macOS 実測。コピーの正常対照は配置に依存する K31 の 2 件を除き 162 件成功、実ツリーでは 164 件成功）。
# 空振り検出: --impl / --class 型付き引数と作業クラス語候補の追加経路に対し、両軸分離分岐無効化・空白語除外削除・class=未指定 付与削除・--class 未指定警告削除・候補抽出の deprecated/archived 除外削除・位置引数併用拒否削除・両軸 unreflected 再出力無効化の 7 変異を mutation-harness.sh で実測し、全 7 件 detected（SURVIVED 0 / NOT-APPLIED 0、対照 180 件成功。2026-11-21 実測）。
# 空振り検出: root-stop-guide.sh（G1〜G12。Issue `#2648`）は、fixture のリポジトリを作れない回を検査不成立の赤にし、合成 case の実行回数（11 回）が合わない・成功終端へ届かない回も赤にする。場所の名指しが無い拒否（G7）と検査を通る root（G8）を対照に置く。knowledge-lookup.sh の写しへ 1 件ずつ当てた 13 変異はすべて赤（2026-11-21 実測。WSL の Ubuntu / bash 5.2 で suite 全体を回した。写しは git の外なので変異なしでも K31・K46 が赤になり、下はそれを除いた差分）: 案内の呼び出しを消す・停止文を stdout へ出す（どちらも G1〜G6・G9〜G12）、場所の名指しが無い拒否でも足す（G7）、置き場の検査を外す（G5）、同じ名前の別物を避けない（G4）、パスを引用しない・単一引用符のエスケープを落とす（どちらも G1〜G4・G10〜G12）、前の worktree を見ない（G3・G10・G11）、stop-block-unavailable の 3 行を外す（G9）、commit を読まない（G1〜G5・G10〜G12）、--root 無しで cwd を使わない（G10）、add の -f を外す（G1・G4・G12）、下位ディレクトリを名指さない（G11）。G10〜G12 を足す前の 9 変異は Windows 11 の Git Bash でも同じ集合が赤（引用符のエスケープだけは、fixture 名に引用符を持てる WSL で測った）。
# 空振り検出: K47〜K47i（--each。Issue `#2921`）は、単独で引いた回の RECORD が空の回・台帳側にヒットが無い回・gh の stub が 1 回も呼ばれない回を「一致」と数えず赤にし、断るケースは stderr の理由文まで見る（別の理由の rc=1 を通さない）。knowledge-lookup.sh の写しへ 1 件ずつ当てた 9 変異はすべて赤（2026-11-21 実測。WSL の Ubuntu / bash 5.2 で suite 全体。写しは git の外なので変異なしでも K31・K46・K47f が赤になり、下はそれを除いた差分）: RECORD から keyword= を落とす（K47・K47b・K47c・K47e・K47h・K47i）、語ごとではなく全語を 1 つの照合へ束ねる（K47・K47b・K47e・K47h・K47i）、SUMMARY から each_keywords を落とす（K47・K47c・K47h）、--all との併用を通す・改行 / 復帰 / タブの語を通す・--impl / --class との併用の停止を外す（いずれも K47d）、空白だけの語を数える（K47c・K47d）、--each の分岐を無効にして従来の 1 回の検索へ落とす（K47・K47b・K47c・K47e・K47h・K47i）、SUMMARY の件数を和集合ではなく最後の語のものにする（K47・K47b・K47i）。未反映の経路（K47f）は写しでは成立しないので、変異ではなく本体の suite の緑で確かめた。
#
# 変異検出（2026-09-19 実測。変異は 1 件ずつ当て、前後で対照を取る）:
#           emit_obs の archived 除外を外すと 2 件赤（K2 と K11 の行数）。emit_obs の Status 抽出を
#           空へ倒す（全件 unknown）と 11 件赤（K1 の台帳 3 針・K2・K11・K13・K14・K16）。両不在の
#           exit 2 を exit 0 へ倒すと 2 件赤（K6・K7 の唯一 store）。noentry を empty へ倒すと K7 が
#           2 件赤。曖昧時に先頭候補を採る形へ変えると K9 の 2 件目が赤。RECORD 行の ID 連結を
#           落とすと 2 件赤（K3・K5）。
#           extract_entries のフェンス判定を無効化する（フェンス行を検出しない正規表現へ変える）と
#           K17 が 2 件赤（テンプレートの記入例が実エントリとして返り、実見出しを壊した台帳が rc=0 になる。
#           2026-09-19 のクロスモデルレビューで codex-cli / grok-cli が独立に再現した欠陥の回帰）。
#           2026-10-16 の再実測（annotate_refs の process substitution を無くし、gh が emit_obs の
#           read ループと同じシェルで起動されるようになった後）: gh の `</dev/null` と emit_obs の
#           fd 3 を両方外すと K16 が赤（stub がエントリ一覧の残りを読み切る）。片方だけ外す変異は
#           それぞれ緑（もう片方の防御が効く）。それ以前は stub が読むのが annotate_refs 内側の
#           process substitution だったため、両方外しても K16 は緑だった。
#
# 依存: bash・awk・find・mktemp。gh は PATH 先頭の stub で差し替える（実 gh は呼ばない）。
# 一時領域を作れない環境では suite 全体を ○ skip する。Windows の Git Bash では fixture を読み取り境界の
# ff_knowledge_job_directory で作り（既定の TMPDIR が AppData\Local の下なら状態ディレクトリ配下へ移る）、
# 移し先も境界に止められたら赤で終わる。symlink を作れない Git Bash では symlink・chmod 000・最小 PATH を
# 前提にするケースを字下げした部分 skip にする（tests/lib/msys-case.sh。Issue `#2539`）。
# run-all-required: yes — 台帳の読み側（状態切り分け・不在時の既定・promoted 突き合わせ）を見る唯一の層で、一時領域不足で skip すると「promoted を未対策として返す」退行が黙って戻る
#
# 依存の宣言（変更ベースの部分ゲートが、この suite を選ぶ変更）:
# run-all-depends: scripts/knowledge-lookup.sh scripts/lib/knowledge-read-boundary.sh scripts/lib/playbook-changelog-functions.sh scripts/lib/wsl-notice.sh
# run-all-depends: scripts/lib/knowledge-read-acl.ps1 scripts/lib/playbook-changelog-scan.awk scripts/lib/stop-block.* scripts/lib/knowledge-lookup-store.*
# run-all-depends: tests/lib/msys-case.sh tests/lib/git-fixture.sh .claude-plugin/plugin.json
# run-all-depends: docs-template/08-knowledge/OBSERVATIONS.md docs-template/08-knowledge/PLAYBOOK.md
# run-all-depends: skills/ace-curate/SKILL.md skills/ace-refine/SKILL.md skills/ace-curate/references/curate.md skills/knowledge-lookup/SKILL.md
# run-all-not-depends: scripts/mutation-harness.sh 実測手順の説明
# run-all-not-depends: /docs/MASTER.md K22 の説明（検索は fixture の root）
# run-all-not-depends: /AGENTS.md K22 の説明（検索は fixture の root）
# run-all-not-depends: /docs/08-knowledge/playbook/coding.md fixture の名前
# run-all-not-depends: docs-template/08-knowledge/playbook/coding.md fixture の名前
# run-all-not-depends: /docs/08-knowledge/playbook/archive/coding.md fixture の名前
# run-all-not-depends: /docs/08-knowledge/PLAYBOOK.md fixture の root の中のパス
# run-all-not-depends: /docs/08-knowledge/OBSERVATIONS.md fixture の root の中のパス
# run-all-not-depends: /docs/06-reference/DECISIONS.md fixture の台帳本文の参照文字列
# run-all-not-depends: /docs/08-knowledge/PENDING_CANDIDATES.md fixture の root の中のパス
# run-all-not-depends: tests/knowledge-lookup-resident-acl/verify.sh 分割先 suite の説明
# run-all-not-depends: tests/setup-ai-config/fixtures/expected/AGENTS.md fixture の root（*/AGENTS.md）の同名
# run-all-not-depends: tests/setup-ai-config/fixtures/expected/CLAUDE.md fixture の root（*/CLAUDE.md）の同名

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${PLUGIN_ROOT}/scripts/knowledge-lookup.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== knowledge-lookup: 状態切り分けと針が当たらない入力の既定 =="

if [[ ! -f "${TARGET}" ]]; then
  bad "対象スクリプトが見つかりません: ${TARGET}"
  echo "✗ knowledge-lookup verify: 1 件失敗 / 0 件成功" >&2
  exit 1
fi
case "$(uname -s 2>/dev/null)" in
  MSYS*|MINGW*|CYGWIN*)
    # Issue `#2539`: fixtures must pass the reader's ACL check, or nearly every case refuses them. The reader's
    # own job-directory rule moves off a TMPDIR whose ancestors (AppData\Local) a capability SID can write.
    if ! TMP="$(bash -c '. "$1"; ff_knowledge_job_directory knowledge-lookup-suite' _ "${PLUGIN_ROOT}/scripts/lib/knowledge-read-boundary.sh")" || [[ ! -d "${TMP}" ]]; then
      bad "fixture の置き場が読み取り境界の検査を通らない（上の knowledge-read: 行が止めた場所を避ける TMPDIR を渡す）"
      echo "✗ knowledge-lookup verify: 1 件失敗 / 0 件成功" >&2
      exit 1
    fi
    kl_tmpdir_given="${TMPDIR:-/tmp}" # W8 still makes the reader move off the caller's TMPDIR itself
    export TMPDIR="${TMP%/*}" ;; # the lookups under test then need no move of their own
  *)
    if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/knowledge-lookup-suite.XXXXXX" 2>&1)" || [[ ! -d "${TMP}" ]]; then
      echo "○ skip: 一時ディレクトリを作成できないため knowledge-lookup を実行できません（検査は 1 件も実行されていません）"
      printf '  mktemp: %s\n' "${TMP}"
      exit 0
    fi ;;
esac
FINISHED=0
cleanup() {
  local rc=$?
  chmod -R u+rw "${TMP}" 2>/dev/null || true
  rm -rf "${TMP}"
  if [[ "${FINISHED}" -ne 1 ]]; then
    echo "✗ knowledge-lookup verify: suite が途中で終了しました（rc=${rc}）" >&2
    exit 1
  fi
  exit "${rc}"
}
trap cleanup EXIT
finish() { FINISHED=1; exit "$1"; }

# Windows' Git Bash without symlink rights copies `ln -s` (or fails on a missing target), and `chmod 000`
# leaves the file readable. Those cases become indented skips there only (Issue `#2539`); elsewhere a
# failed probe still runs the case, so a host that loses symlinks goes red instead of silent.
if [[ -f "${SCRIPT_DIR}/../lib/msys-case.sh" ]]; then
  # shellcheck source=../lib/msys-case.sh
  . "${SCRIPT_DIR}/../lib/msys-case.sh"
fi
kl_symlinks=1
{ ln -s missing-target "${TMP}/symlink-probe" && [[ -L "${TMP}/symlink-probe" ]]; } 2>/dev/null || kl_symlinks=0
rm -f "${TMP}/symlink-probe"
kl_skip_msys() { # <detail>
  declare -F ff_skip_msys_case >/dev/null 2>&1 && ff_skip_msys_case "${OSTYPE:-}" "$1"
}
kl_skip_no_symlink() { # <cases>
  [[ "${kl_symlinks}" -eq 0 ]] && kl_skip_msys "symlink を作れないため ${1}"
}

# ── fixture ─────────────────────────────────────────────────────────────────
# Playbook: 索引 + playbook/coding.md（active 1・deprecated 1）+ playbook/archive/coding.md（1）
# 台帳: active 1・promoted 2（open / closed）・promoted 1（別 repo・gh 失敗）・mitigated 1・archived 1
make_playbook() { # <root>
  local root="$1"
  mkdir -p "${root}/docs/08-knowledge/playbook/archive"
  cat >"${root}/docs/08-knowledge/PLAYBOOK.md" <<'EOF'
# ACE Playbook

## エントリ一覧

| ID | 主張 | Category | 場所 |
| --- | --- | --- | --- |
| ACE-10-1 | hydration race は e2e で待機を足す | coding | [playbook/coding.md#ace-10-1](./playbook/coding.md#ace-10-1) |
| ACE-10-2 | 旧: hydration は sleep で待つ | coding | [playbook/coding.md#ace-10-2](./playbook/coding.md#ace-10-2) |
EOF
  cat >"${root}/docs/08-knowledge/playbook/coding.md" <<'EOF'
# PLAYBOOK — coding

## エントリ一覧

<a id="ace-10-1"></a>

### ACE-10-1: hydration race は e2e で待機を足す

| Category | coding | Origin | PR-10 |
| Date | 2026-09-01 |
| Helpful | 4 | Harmful | 0 |
| Status | active |

client:load の Island は hydration 前にクリックが落ちる。e2e では明示の待機を足す。

---

<a id="ace-10-2"></a>

### ACE-10-2: 旧: hydration は sleep で待つ

| Category | coding | Origin | PR-10 |
| Date | 2026-08-01 |
| Helpful | 0 | Harmful | 2 |
| Status | deprecated |

固定 sleep は環境差で落ちる。ACE-10-1 に置き換えた。

---
EOF
  cat >"${root}/docs/08-knowledge/playbook/archive/coding.md" <<'EOF'
# archive

<a id="ace-3-1"></a>

### ACE-3-1: hydration の古い回避策（stale）

| Category | coding | Origin | PR-3 |
| Date | 2026-06-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

参考のみ。

---
EOF
}
make_ledger() { # <root> [相対パス]
  local root="$1" rel="${2:-docs/08-knowledge/OBSERVATIONS.md}"
  mkdir -p "${root}/$(dirname "${rel}")"
  cat >"${root}/${rel}" <<'EOF'
# 振り返り観測台帳

## エントリ形式

（省略）

## エントリ一覧

<a id="obs-001"></a>

### OBS-001: e2e が負荷で落ちる → hydration 待機を疑え

| Kind | problem | Count | 2 |
| First | 2026-09-11 | Last | 2026-09-18 |
| Status | active | Issue | なし |

同じ e2e が負荷で落ちる。hydration race を先に疑う。

- 2026-09-11: 初回
- 2026-09-18: 再発

---

<a id="obs-002"></a>

### OBS-002: allowlist の skip-review は毎回外れる → 既定へ入れよ

| Kind | problem | Count | 10 |
| First | 2026-08-01 | Last | 2026-09-18 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1846 / feel-flow/ff-dev-toolkit#1700 |

hydration とは無関係だが allowlist の話。

- 2026-09-18: 10 回目

---

<a id="obs-003"></a>

### OBS-003: 閉じた対策の再発 hydration

| Kind | problem | Count | 3 |
| First | 2026-08-01 | Last | 2026-09-01 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1500 |

対策 Issue は閉じている。

- 2026-09-01: 3 回目

---

<a id="obs-004"></a>

### OBS-004: 別 repo に昇格した hydration の観測

| Kind | problem | Count | 3 |
| First | 2026-08-01 | Last | 2026-09-01 |
| Status | promoted | Issue | feel-flow/ai-spec-driven-development#42 |

昇格先の repo は gh が失敗する。

- 2026-09-01: 3 回目

---

<a id="obs-005"></a>

### OBS-005: hydration の対策はスキルに定義済み

| Kind | keep | Count | 3 |
| First | 2026-08-01 | Last | 2026-09-01 |
| Status | mitigated | Issue | skill:multi-review / doc:docs/x.md#anchor |

対策済み。

- 2026-09-01: 3 回目

---

<a id="obs-006"></a>

### OBS-006: 休眠中の hydration 観測

| Kind | problem | Count | 1 |
| First | 2026-01-01 | Last | 2026-01-01 |
| Status | archived | Issue | なし |

休眠。

- 2026-01-01: 初回

---
EOF
}

# gh stub: `gh issue list --repo feel-flow/ff-dev-toolkit …` は open 番号 1846 / 1700 を返す。feel-flow/ai-spec-driven-development は失敗する。
# stdin を読み切る（K16: 呼び出し元の while read を壊さないことの実測）。
make_gh_stub() { # <bindir> <mode: normal|readstdin>
  local bin="$1" mode="$2"
  mkdir -p "${bin}"
  cat >"${bin}/gh" <<EOF
#!/usr/bin/env bash
mode="${mode}"
if [ "\${mode}" = "readstdin" ]; then cat >/dev/null; fi
repo=""
while [ \$# -gt 0 ]; do
  case "\$1" in --repo) repo="\$2"; shift 2 ;; *) shift ;; esac
done
case "\${repo}" in
  feel-flow/ff-dev-toolkit) printf '%s\n' 1846 1700; exit 0 ;;
  *) echo "gh: could not resolve to a Repository" >&2; exit 1 ;;
esac
EOF
  chmod +x "${bin}/gh"
}

# plugin root の handoff（FF_DEV_TOOLKIT_ROOT 等）を継承したまま作業ツリーの実体を叩くと、
# 対象スクリプトの root ガードが「handoff と実体位置の不一致」で rc=3 を返し、全ケースが赤になる
# （grok-cli のレビューで実測: 継承ありで 30 件失敗 / env -u で 35 件成功）。workflow-doctor 等の
# suite と同じく handoff を落として起動する。
# ACE_PLAYBOOK_PATH も落とす — 外の環境に設定があると、全ケースの Playbook がそれに置き換わる。
LOOKUP=(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE -u ACE_PLAYBOOK_PATH bash "${TARGET}")
run_lookup() { # <root> <args...> → OUT / RC（stdout+stderr を OUT へ）
  local root="$1"; shift
  set +e
  OUT="$("${LOOKUP[@]}" --root "${root}" "$@" 2>&1)"
  RC=$?
  set -e
}
out_has() { [[ "$(printf '%s\n' "${OUT}" | grep -cF -- "$1")" -gt 0 ]]; }
# グループ見出し `-- <label> --` の直後から次の `--` / `==` / 空行までに ID が居るか
id_under_group() { # <group label 部分文字列> <ID>
  printf '%s\n' "${OUT}" | awk -v g="$1" -v id="$2" '
    /^-- / { ingrp = (index($0, g) > 0) ; next }
    /^== / || /^$/ { ingrp = 0 }
    ingrp && index($0, id "  ") == 1 { found = 1 }
    END { exit found ? 0 : 1 }'
}

# ── K1 / K2 / K3: 両 store ───────────────────────────────────────────────────
if [[ "${FF_KNOWLEDGE_LOOKUP_PRIVACY_ONLY:-0}" == 1 ]]; then
  if [[ "${FF_RUN_ALL_NESTED:-0}" != 0 ]]; then
    bad 'privacy probe mode cannot replace the registered full suite'
    finish 1
  fi
  . "$SCRIPT_DIR/privacy.sh"
  printf 'knowledge privacy: %s passed, %s failed\n' "$PASS" "$FAIL"
  if [[ "$FAIL" -eq 0 ]]; then finish 0; else finish 1; fi
fi
ROOT1="${TMP}/both"; make_playbook "${ROOT1}"; make_ledger "${ROOT1}"
run_lookup "${ROOT1}" --offline hydration
if [[ "${RC}" -eq 0 ]]; then ok "K1: 両 store で rc=0"; else bad "K1: rc=${RC}（期待 0）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2; fi
if id_under_group "有効（active）" "ACE-10-1"; then ok "K1: ACE active が有効グループに出る"; else bad "K1: ACE-10-1 が有効グループに無い"; fi
if id_under_group "非推奨（deprecated" "ACE-10-2"; then ok "K1: ACE deprecated が非推奨グループに出る"; else bad "K1: ACE-10-2 が非推奨グループに無い"; fi
if id_under_group "未対策（active" "OBS-001"; then ok "K1: 台帳 active が未対策グループに出る"; else bad "K1: OBS-001 が未対策グループに無い"; fi
if id_under_group "対策 Issue あり（promoted。Issue 列の state を見る: open = 対応中 / closed = 完了照合前または対策後の再発（最新メモで区別））" "OBS-003"; then ok "K1: 台帳 promoted が対策 Issue ありグループに出る"; else bad "K1: OBS-003 が promoted グループに無い"; fi
if id_under_group "対策済み（mitigated。元 Issue と所在は Issue 列。最新メモの未解消再発も確認する）" "OBS-005"; then ok "K1: 台帳 mitigated が対策済みグループに出る"; else bad "K1: OBS-005 が mitigated グループに無い"; fi
if id_under_group "未対策（active" "OBS-003" || id_under_group "未対策（active" "OBS-005"; then
  bad "K1: promoted / mitigated が未対策グループへ混ざっている"
else
  ok "K1: promoted / mitigated は未対策グループへ混ざらない"
fi
if out_has "skill:multi-review / doc:docs/x.md#anchor"; then ok "K1: mitigated の対策の所在（skill: / doc:）がそのまま出る"; else bad "K1: mitigated の所在が出ない"; fi
if out_has "OBS-006"; then bad "K2: archived が既定で出ている"; else ok "K2: archived は既定で出ない"; fi
if out_has "ACE-3-1"; then bad "K2: archive/ 配下が既定で出ている"; else ok "K2: archive/ 配下は既定で出ない"; fi
if out_has "RECORD ace=ACE-10-1,ACE-10-2 obs=OBS-001,OBS-002,OBS-003,OBS-004,OBS-005"; then
  ok "K3: RECORD 行がヒット ID を両 store ぶん列挙する"
else
  bad "K3: RECORD 行が期待形でない"; printf '%s\n' "${OUT}" | grep -F 'RECORD' | sed 's/^/    | /' >&2 || true
fi

run_lookup "${ROOT1}" --offline --include-archived hydration
if id_under_group "休眠（archived" "OBS-006"; then ok "K2: --include-archived で台帳 archived が休眠グループに出る"; else bad "K2: --include-archived でも OBS-006 が出ない"; fi
if id_under_group "アーカイブ（playbook/archive" "ACE-3-1"; then ok "K2: --include-archived で archive/ がアーカイブグループに出る"; else bad "K2: --include-archived でも ACE-3-1 が出ない"; fi

# ── K4: 0 件 ─────────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --offline zzz-no-such-word
if [[ "${RC}" -eq 0 ]] && out_has "RECORD ace=0 件 obs=0 件"; then ok "K4: 0 件ヒットは rc=0 / RECORD 0 件"; else bad "K4: rc=${RC} / RECORD が 0 件でない"; fi

# ── K5 / K6: 片方不在・両方不在 ───────────────────────────────────────────────
ROOT2="${TMP}/ledger-only"; make_ledger "${ROOT2}"
run_lookup "${ROOT2}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "RECORD ace=Playbook なし obs=OBS-001"; then ok "K5: Playbook だけ不在は rc=0 / RECORD ace=Playbook なし"; else bad "K5: Playbook 不在の扱い（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -F 'RECORD' | sed 's/^/    | /' >&2 || true; fi
ROOT3="${TMP}/playbook-only"; make_playbook "${ROOT3}"
run_lookup "${ROOT3}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "obs=台帳なし"; then ok "K5: 台帳だけ不在は rc=0 / RECORD obs=台帳なし"; else bad "K5: 台帳不在の扱い（rc=${RC}）"; fi
ROOT4="${TMP}/none"; mkdir -p "${ROOT4}"
run_lookup "${ROOT4}" --offline hydration
if [[ "${RC}" -eq 2 ]] && out_has "検索不成立"; then ok "K6: 両 store 不在は rc=2（検索不成立）"; else bad "K6: 両不在で rc=${RC}（期待 2）"; fi

# ── K7: 見出し書式の変更 ──────────────────────────────────────────────────────
ROOT5="${TMP}/heading-changed"; make_playbook "${ROOT5}"; make_ledger "${ROOT5}"
sed -i.bak 's/^### OBS-\([0-9]*\): /### OBS \1 /' "${ROOT5}/docs/08-knowledge/OBSERVATIONS.md" && rm -f "${ROOT5}/docs/08-knowledge/OBSERVATIONS.md.bak"
run_lookup "${ROOT5}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "obs=読み取り失敗（エントリ見出しを認識できない"; then
  ok "K7: 見出し書式の変更は 0 件ではなく読み取り失敗"
else
  bad "K7: 見出し書式の変更が読み取り失敗にならない（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -F 'RECORD' | sed 's/^/    | /' >&2 || true
fi
# 台帳だけの root で見出しが壊れていれば、検索できる store が無いので rc=2
ROOT5b="${TMP}/heading-changed-only"; make_ledger "${ROOT5b}"
sed -i.bak 's/^### OBS-\([0-9]*\): /### OBS \1 /' "${ROOT5b}/docs/08-knowledge/OBSERVATIONS.md" && rm -f "${ROOT5b}/docs/08-knowledge/OBSERVATIONS.md.bak"
run_lookup "${ROOT5b}" --offline hydration
if [[ "${RC}" -eq 2 ]]; then ok "K7: 唯一の store の見出しが壊れていれば rc=2"; else bad "K7: 唯一の store が壊れていても rc=${RC}"; fi

# ── K8: 読めない台帳 ──────────────────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  ○ skip: K8 root 実行では読めないファイルを作れない"
else
  ROOT6="${TMP}/unreadable"; make_playbook "${ROOT6}"; make_ledger "${ROOT6}"
  chmod 000 "${ROOT6}/docs/08-knowledge/OBSERVATIONS.md"
  if [[ -r "${ROOT6}/docs/08-knowledge/OBSERVATIONS.md" ]] && kl_skip_msys "K8 は chmod 000 でも台帳が読めて成立しない"; then
    chmod 644 "${ROOT6}/docs/08-knowledge/OBSERVATIONS.md"
  else
    run_lookup "${ROOT6}" --offline hydration
    chmod 644 "${ROOT6}/docs/08-knowledge/OBSERVATIONS.md"
    if [[ "${RC}" -eq 0 ]] && out_has "obs=読み取り失敗（ファイルを読めない）"; then ok "K8: 読めない台帳は読み取り失敗（未導入へ吸収しない）"; else bad "K8: 読めない台帳の扱い（rc=${RC}）"; fi
  fi
fi

# ── K9: 実配置の探索 ──────────────────────────────────────────────────────────
ROOT7="${TMP}/nondefault"; make_ledger "${ROOT7}" "docs/playbooks/OBSERVATIONS.md"
run_lookup "${ROOT7}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "docs/playbooks/OBSERVATIONS.md#obs-001"; then ok "K9: 既定パスに無い台帳を root 配下の 1 件から採る"; else bad "K9: 非既定配置の台帳を採れない（rc=${RC}）"; fi
ROOT8="${TMP}/ambiguous"; make_ledger "${ROOT8}" "docs/a/OBSERVATIONS.md"; make_ledger "${ROOT8}" "docs/b/OBSERVATIONS.md"; make_playbook "${ROOT8}"
run_lookup "${ROOT8}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "obs=読み取り失敗（配置が曖昧" && ! out_has "docs/a/OBSERVATIONS.md#obs-001"; then
  ok "K9: 候補が 2 件なら曖昧として採らない"
else
  bad "K9: 曖昧な配置で先頭候補を採っている、または報告形が違う（rc=${RC}）"
fi

# ── K10: AND / OR ────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --offline hydration allowlist
if out_has "OBS-002" && out_has "OBS-001"; then ok "K10: 既定は OR"; else bad "K10: OR で両方出ない"; fi
run_lookup "${ROOT1}" --offline --all hydration allowlist
if out_has "OBS-002" && ! out_has "OBS-001"; then ok "K10: --all は AND"; else bad "K10: --all が AND になっていない"; fi

# ── K11: tsv ─────────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --offline --format tsv hydration
tsv_bad="$(printf '%s\n' "${OUT}" | awk -F '\t' '/^(ace|obs)\t/ { if (NF != 6) c++ } END { print c + 0 }')"
tsv_rows="$(printf '%s\n' "${OUT}" | awk -F '\t' '/^(ace|obs)\t/ { c++ } END { print c + 0 }')"
if [[ "${tsv_bad}" -eq 0 && "${tsv_rows}" -eq 7 ]]; then ok "K11: tsv は 6 列 × 7 行（ACE 2 + 台帳 5）"; else bad "K11: tsv の列数不一致 ${tsv_bad} 行 / 行数 ${tsv_rows}（期待 7）"; fi

# ── K12: usage ───────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --offline
if [[ "${RC}" -eq 1 ]]; then ok "K12: キーワード無しは rc=1"; else bad "K12: キーワード無しで rc=${RC}"; fi

# ── K13 / K16: promoted-open（gh stub） ──────────────────────────────────────
STUB_BIN="${TMP}/bin-normal"; make_gh_stub "${STUB_BIN}" normal
set +e
OUT="$(PATH="${STUB_BIN}:${PATH}" "${LOOKUP[@]}" --root "${ROOT1}" --promoted-open 2>&1)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]]; then ok "K13: --promoted-open rc=0"; else bad "K13: rc=${RC}"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2; fi
if out_has "OBS-002" && out_has "feel-flow/ff-dev-toolkit#1846(open)"; then ok "K13: open の昇格先を持つ promoted が出る"; else bad "K13: OBS-002 が出ない"; fi
if out_has "OBS-003"; then bad "K13: closed だけの promoted が出ている"; else ok "K13: closed だけの promoted は出ない"; fi
if out_has "OBS-004" && out_has "feel-flow/ai-spec-driven-development#42(未確認)"; then ok "K13: gh が失敗した repo の参照は 未確認 として隠さない"; else bad "K13: 未確認の参照が隠れた"; fi
if out_has "SUMMARY promoted=3 open_or_unresolved=2 unresolved=1"; then ok "K13: SUMMARY の件数が一致"; else bad "K13: SUMMARY 不一致"; printf '%s\n' "${OUT}" | grep -F 'SUMMARY' | sed 's/^/    | /' >&2 || true; fi
if out_has "OBS-001" || out_has "OBS-005"; then bad "K13: promoted 以外が混ざっている"; else ok "K13: promoted 以外は出ない"; fi

STUB_BIN2="${TMP}/bin-readstdin"; make_gh_stub "${STUB_BIN2}" readstdin
set +e
OUT="$(PATH="${STUB_BIN2}:${PATH}" "${LOOKUP[@]}" --root "${ROOT1}" --promoted-open 2>&1)"; RC=$?
set -e
if out_has "SUMMARY promoted=3 open_or_unresolved=2 unresolved=1" && out_has "OBS-004"; then
  ok "K16: gh が stdin を読み切ってもエントリが欠けない"
else
  bad "K16: gh の stdin 消費でエントリが欠けた"; printf '%s\n' "${OUT}" | grep -F 'SUMMARY' | sed 's/^/    | /' >&2 || true
fi

# ── K14 / K15 ────────────────────────────────────────────────────────────────
run_lookup "${ROOT1}" --promoted-open --offline
if [[ "${RC}" -eq 0 ]] && out_has "SUMMARY promoted=3 open_or_unresolved=3 unresolved=3 offline=1"; then ok "K14: --offline は全 promoted を 未確認 として出す"; else bad "K14: --offline の扱い（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -F 'SUMMARY' | sed 's/^/    | /' >&2 || true; fi
run_lookup "${ROOT3}" --promoted-open --offline
if [[ "${RC}" -eq 2 ]]; then ok "K15: 台帳不在の --promoted-open は rc=2"; else bad "K15: 台帳不在で rc=${RC}"; fi

# ── K17: フェンス内の記入例を実エントリとして返さない ─────────────────────────
# 同梱テンプレートそのもの（エントリ 0 件・「エントリ形式」節にフェンス入りの記入例）と、
# 記入例だけ残して実見出しを壊した台帳の 2 fixture。
TEMPLATE_DIR="${PLUGIN_ROOT}/docs-template/08-knowledge"
if [[ -f "${TEMPLATE_DIR}/OBSERVATIONS.md" && -f "${TEMPLATE_DIR}/PLAYBOOK.md" ]]; then
  ROOT9="${TMP}/template-only"; mkdir -p "${ROOT9}/docs/08-knowledge"
  cp "${TEMPLATE_DIR}/OBSERVATIONS.md" "${TEMPLATE_DIR}/PLAYBOOK.md" "${ROOT9}/docs/08-knowledge/"
  run_lookup "${ROOT9}" --offline タイトル 主張 problem
  if [[ "${RC}" -eq 0 ]] && ! out_has "OBS-XXX" && ! out_has "ACE-XXX" && out_has "obs_state=empty" && out_has "RECORD ace=0 件 obs=0 件"; then
    ok "K17: テンプレート直後の空 store では記入例（OBS-XXX / ACE-XXX）を返さず 0 件 / empty"
  else
    bad "K17: テンプレートのフェンス内記入例を実エントリとして返している（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -E 'XXX|RECORD|SUMMARY' | sed 's/^/    | /' >&2 || true
  fi
else
  bad "K17: 同梱テンプレート（docs-template/08-knowledge）が見つかりません"
fi
ROOT10="${TMP}/fenced-sample-broken"; make_ledger "${ROOT10}"
sed -i.bak 's/^### OBS-\([0-9]*\): /### OBS \1 /' "${ROOT10}/docs/08-knowledge/OBSERVATIONS.md" && rm -f "${ROOT10}/docs/08-knowledge/OBSERVATIONS.md.bak"
cat >>"${ROOT10}/docs/08-knowledge/OBSERVATIONS.md" <<'EOF'

## 記入例（テンプレートの写し）

```markdown
### OBS-XXX: [検索可能な主張 1 文のタイトル]

| Kind | problem または keep | Count | 1 |
| Status | active | Issue | なし |
```
EOF
run_lookup "${ROOT10}" --offline hydration
if [[ "${RC}" -eq 2 ]] && ! out_has "OBS-XXX"; then
  ok "K17: 記入例だけ残して実見出しを壊した台帳は、記入例で認識件数を作らず rc=2"
else
  bad "K17: フェンス内の記入例が実見出しの破損を覆い隠している（rc=${RC}）"
fi

# ── K18: live が空でも archive は引ける ─────────────────────────────────────
ROOT11="${TMP}/archive-only"; make_playbook "${ROOT11}"
: >"${ROOT11}/docs/08-knowledge/playbook/coding.md"; printf '%s\n' '# PLAYBOOK — coding' '' '## エントリ一覧' >"${ROOT11}/docs/08-knowledge/playbook/coding.md"
run_lookup "${ROOT11}" --offline --include-archived hydration
if [[ "${RC}" -eq 0 ]] && id_under_group "アーカイブ（playbook/archive" "ACE-3-1" && out_has "ace_state=empty"; then
  ok "K18: live エントリが無い Playbook でも --include-archived で archive を返す"
else
  bad "K18: live が空だと archive が出ない（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -E 'ACE-|RECORD|SUMMARY' | sed 's/^/    | /' >&2 || true
fi

# ── K19: 注記付き参照（注記を表示に残して state を引く） ─────────────────────────────────────────
ROOT12="${TMP}/annotated-refs"; mkdir -p "${ROOT12}/docs/08-knowledge"
unqualified_ref="$(printf '#%s' 7)"
note_open_ref="$(printf '#%s(open)' 2)"
note_unresolved_ref="$(printf '#%s(未確認)' 3)"
cat >"${ROOT12}/docs/08-knowledge/OBSERVATIONS.md" <<EOF
# 振り返り観測台帳

## エントリ一覧

### OBS-101: annotated references

| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1（closed）/ feel-flow/ff-dev-toolkit#2(open) / Other.Owner/re_po.name#3（説明） |

### OBS-102: non-issue references

| Status | promoted | Issue | skill:close-issue / doc:docs/06-reference/DECISIONS.md#2026-10-05 / なし |

### OBS-103: unqualified reference

| Status | promoted | Issue | ${unqualified_ref} |

### OBS-104: stale annotation

| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1(open) |

### OBS-105: state-like notes

| Status | promoted | Issue | feel-flow/ff-dev-toolkit#1（旧メモ: ${note_open_ref}、${note_unresolved_ref}） |

### OBS-106: annotated unqualified reference

| Status | promoted | Issue | ${unqualified_ref}（注記） |

### OBS-107: unqualified reference with old state

| Status | promoted | Issue | ${unqualified_ref}(open) |
EOF
STUB_BIN3="${TMP}/bin-annotated"; mkdir -p "${STUB_BIN3}"
GH_REPO_LOG="${TMP}/annotated-gh-repos"
cat >"${STUB_BIN3}/gh" <<'EOF'
#!/usr/bin/env bash
repo=""
while [ $# -gt 0 ]; do
  case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "${repo}" >>"${GH_REPO_LOG}"
case "${repo}" in
  feel-flow/ff-dev-toolkit) printf '%s\n' 2 ;;
  Other.Owner/re_po.name) printf '%s\n' 3 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${STUB_BIN3}/gh"
set +e
OUT="$(GH_REPO_LOG="${GH_REPO_LOG}" PATH="${STUB_BIN3}:${PATH}" "${LOOKUP[@]}" --root "${ROOT12}" --promoted-open 2>&1)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]] && out_has 'feel-flow/ff-dev-toolkit#1(closed)（closed）/ feel-flow/ff-dev-toolkit#2(open)(open)' && out_has 'Other.Owner/re_po.name#3(open)（説明）'; then
  ok "K19: 各参照の state を解決し、注記と区切りを保持する"
else
  bad "K19: 注記付きの複数参照を解決できない（rc=${RC}）"
fi
if [[ -f "${GH_REPO_LOG}" ]] && [[ "$(cat "${GH_REPO_LOG}")" = "$(printf '%s\n' feel-flow/ff-dev-toolkit Other.Owner/re_po.name)" ]]; then
  ok "K19: gh には抽出した repo だけを渡し、repo ごとに 1 回取得する"
else
  bad "K19: gh の repo が壊れている、余分な呼び出しがある、または呼ばれていない"
fi
if out_has 'OBS-103' && out_has "${unqualified_ref}(未確認: リポジトリ修飾なし)"; then
  ok "K19: #N だけの参照は修飾なしの未確認を保持する"
else
  bad "K19: 修飾なしの参照が隠れた、または解決された"
fi
if out_has 'OBS-104'; then bad "K19: 古い (open) 注記を現在の open state と誤認している"; else ok "K19: closed の参照に古い (open) 注記があっても列挙しない"; fi
if out_has 'OBS-105'; then bad "K19: 注記中の別番号の open / 未確認を現在の state と誤認している"; else ok "K19: 注記中の別番号の state は判定に使わない"; fi
if out_has 'OBS-106' && out_has 'OBS-107'; then ok "K19: 注記付きの修飾なし参照も未確認として列挙する"; else bad "K19: 注記付きの修飾なし参照が隠れた"; fi
if out_has 'SUMMARY promoted=7 open_or_unresolved=4 unresolved=3'; then ok "K19: SUMMARY は表示注記に左右されず取得した state を数える"; else bad "K19: SUMMARY が注記の state に左右されている"; fi
set +e
OUT="$(GH_REPO_LOG="${GH_REPO_LOG}" PATH="${STUB_BIN3}:${PATH}" "${LOOKUP[@]}" --root "${ROOT12}" --format tsv references 2>&1)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]] && out_has 'Issue=skill:close-issue / doc:docs/06-reference/DECISIONS.md#2026-10-05 / なし' && [[ "$(cat "${GH_REPO_LOG}")" = "$(printf '%s\n' feel-flow/ff-dev-toolkit Other.Owner/re_po.name feel-flow/ff-dev-toolkit Other.Owner/re_po.name)" ]]; then
  ok "K19: skill: / doc: / なしは state を付けずそのまま表示する"
else
  bad "K19: 非 Issue 参照の表示が変わった（rc=${RC}）"
fi

# ── K20: サブディレクトリのエントリと _archive/ ─────────────────────────────────
ROOT13="${TMP}/subdirs"; make_playbook "${ROOT13}"
mkdir -p "${ROOT13}/docs/08-knowledge/playbook/process/_archive" "${ROOT13}/docs/08-knowledge/playbook/_archive" "${ROOT13}/docs/08-knowledge/playbook/.obsidian"
for spec in "process/review.md:20-1:hydration のレビュー観点" "_archive/old.md:21-1:hydration の退避済み" ".obsidian/x.md:22-1:hydration の設定メモ" "process/_archive/old.md:23-1:hydration の入れ子の退避済み"; do
  rel="${spec%%:*}"; rest="${spec#*:}"; id="${rest%%:*}"; title="${rest#*:}"
  {
    echo "# sub"; echo ""; echo "### ACE-${id}: ${title}"; echo ""
    echo "| Category | process |"; echo "| Status | active |"; echo ""; echo "---"
  } >"${ROOT13}/docs/08-knowledge/playbook/${rel}"
done
run_lookup "${ROOT13}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ACE-20-1"; then
  ok "K20: playbook/ のサブディレクトリのエントリを返す"
else
  bad "K20: サブディレクトリのエントリが出ない（rc=${RC}）"
fi
if out_has "ACE-21-1" || out_has "ACE-22-1" || out_has "ACE-23-1"; then
  bad "K20: _archive/（入れ子を含む）か . 始まりのディレクトリが既定で出ている"
else
  ok "K20: _archive/（入れ子を含む）と . 始まりのディレクトリは既定で辿らない"
fi
run_lookup "${ROOT13}" --offline --include-archived hydration
if id_under_group "アーカイブ（playbook/archive" "ACE-21-1" && id_under_group "アーカイブ（playbook/archive" "ACE-23-1"; then
  ok "K20: --include-archived で _archive/ と入れ子の退避先もアーカイブグループに出る"
else
  bad "K20: --include-archived でも _archive/ の ACE-21-1 か入れ子の ACE-23-1 が出ない"
fi
if out_has "ACE-22-1"; then
  bad "K20: --include-archived で . 始まりのディレクトリまで出ている"
else
  ok "K20: --include-archived でも . 始まりのディレクトリは辿らない"
fi

# ── K21: 外部プロセスの起動回数がエントリ数に比例しない ─────────────────────────
# Windows の Git Bash（MSYS）ではプロセス起動 1 回が 0.1 秒を超え、エントリごとに awk / tr / sed を
# 起動する形は約 350 件の台帳で 6 分を超えた。awk / tr / sed を数える shim を PATH 先頭に置き、
# エントリ 4 件と 40 件の台帳で起動回数が同じであることを見る（キーワード検索と --promoted-open の両方。
# promoted / mitigated の Issue 列の解決を通すため gh も stub にする）。
make_scale_ledger() { # <root> <件数>
  local root="$1" n="$2" i=0 st=""
  mkdir -p "${root}/docs/08-knowledge"
  {
    printf '%s\n' "# 振り返り観測台帳" "" "## エントリ一覧" ""
    while [[ "${i}" -lt "${n}" ]]; do
      i=$((i + 1))
      case $((i % 4)) in 0) st="promoted" ;; 1) st="mitigated" ;; 2) st="active" ;; *) st="archived" ;; esac
      printf '### OBS-%03d: scale hydration %s\n\n| Kind | problem | Count | 1 |\n| First | 2026-09-01 | Last | 2026-09-02 |\n| Status | %s | Issue | feel-flow/ff-dev-toolkit#1846 / feel-flow/ff-dev-toolkit#%s（注記） / skill:x |\n\nbody\n\n---\n\n' "${i}" "${i}" "${st}" "${i}"
    done
  } >"${root}/docs/08-knowledge/OBSERVATIONS.md"
}
SPAWN_BIN="${TMP}/bin-spawn"; mkdir -p "${SPAWN_BIN}"
make_gh_stub "${SPAWN_BIN}" normal
for tool in awk tr sed; do
  real="$(command -v "${tool}")"
  cat >"${SPAWN_BIN}/${tool}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "${tool}" >>"\${KL_SPAWN_LOG}"
exec "${real}" "\$@"
EOF
  chmod +x "${SPAWN_BIN}/${tool}"
done
spawn_count() { # <root> <args...> → SPAWN_N（awk / tr / sed の起動回数）/ RC
  local root="$1" log="${TMP}/spawn.log"; shift
  : >"${log}"
  set +e
  OUT="$(KL_SPAWN_LOG="${log}" PATH="${SPAWN_BIN}:${PATH}" "${LOOKUP[@]}" --root "${root}" "$@" 2>&1)"; RC=$?
  set -e
  SPAWN_N="$(wc -l <"${log}" | tr -d ' ')"
}
ROOT14="${TMP}/scale-small"; make_scale_ledger "${ROOT14}" 4
ROOT15="${TMP}/scale-large"; make_scale_ledger "${ROOT15}" 40
for mode in promoted-open search; do
  if [[ "${mode}" = "promoted-open" ]]; then set -- --promoted-open; else set -- --include-archived hydration; fi
  spawn_count "${ROOT14}" "$@"; small_n="${SPAWN_N}"; small_rc="${RC}"
  spawn_count "${ROOT15}" "$@"; large_n="${SPAWN_N}"; large_rc="${RC}"
  if [[ "${small_rc}" -ne 0 || "${large_rc}" -ne 0 ]]; then
    bad "K21 (${mode}): 実行に失敗（rc=${small_rc} / ${large_rc}）"; printf '%s\n' "${OUT}" | tail -n 5 | sed 's/^/    | /' >&2
  elif [[ "${small_n}" -eq 0 ]]; then
    # shim を 1 回も通らないなら数えられていない（PATH 経由で起動していない等）。緑にしない。
    bad "K21 (${mode}): awk / tr / sed の shim が 1 回も呼ばれていない（起動回数を測れていない）"
  elif [[ "${small_n}" -eq "${large_n}" ]]; then
    ok "K21 (${mode}): awk / tr / sed の起動回数がエントリ数に比例しない（4 件 / 40 件ともに ${small_n} 回）"
  else
    bad "K21 (${mode}): 起動回数がエントリ数で変わる（4 件 ${small_n} 回 / 40 件 ${large_n} 回）"
  fi
done
set --

# ── K32: 読むファイル 1 件あたりの外部プロセスの起動回数に上限がある（Issue `#2477`） ──────────
# snapshot はファイルごとに読むので起動回数は件数に比例するが、1 件あたりの回数は小さく保つ。
# 認可・作業場所の検査・stage の私有化・読込前後の metadata を、同じ鎖の検査や同じ stat の
# 繰り返しなしで行うと stat 3・mktemp 1・head 1・tr 1・awk 1 の 7 回。Linux は stage の mode の
# 確認に stat がもう 1 回要るので 8 回（Windows は private-staging の ACL 判定が受け持つ）。
# macOS は鎖の要素ごとに ACL 検査の awk を起動し、stat も -c を試してから -f を起動するので、
# 回数がパスの深さで変わる。上限は Windows と Linux で固定し、macOS では理由付きで測らない。
# 数えるのは stat / mktemp / head / tr / awk（cygpath は Windows、ls は macOS だけが起動する）。
READ_SPAWN_BIN="${TMP}/bin-read-spawn"; mkdir -p "${READ_SPAWN_BIN}"
for tool in stat mktemp head tr awk; do
  real="$(command -v "${tool}")"
  cat >"${READ_SPAWN_BIN}/${tool}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "${tool}" >>"\${KL_SPAWN_LOG}"
exec "${real}" "\$@"
EOF
  chmod +x "${READ_SPAWN_BIN}/${tool}"
done
make_category_files() { # <root> <件数>
  local root="$1" n="$2" i=0
  while [[ "${i}" -lt "${n}" ]]; do
    i=$((i + 1))
    printf '# PLAYBOOK — extra%s\n\n## エントリ一覧\n\n### ACE-9%s-1: hydration extra %s\n\n| Status | active |\n\nbody\n' "${i}" "${i}" "${i}" \
      >"${root}/docs/08-knowledge/playbook/extra${i}.md"
  done
}
read_spawn_count() { # <root> → READ_N / RC
  local log="${TMP}/read-spawn.log"
  : >"${log}"
  set +e
  OUT="$(KL_SPAWN_LOG="${log}" PATH="${READ_SPAWN_BIN}:${PATH}" "${LOOKUP[@]}" --root "$1" --offline hydration 2>&1)"; RC=$?
  set -e
  READ_N="$(wc -l <"${log}" | tr -d ' ')"
}
case "$(uname -s)" in
  MSYS* | MINGW* | CYGWIN*) read_limit=7 ;;
  Linux) read_limit=8 ;;
  *) read_limit="" ;;
esac
if [[ -z "${read_limit}" ]]; then
  echo "  ○ skip: K32（起動回数の上限は Windows と Linux でだけ固定する検査のため未実行。$(uname -s) は ACL 検査の起動回数がパスの深さで変わる）"
else
  ROOT32A="${TMP}/read-spawn-1"; make_playbook "${ROOT32A}"; make_ledger "${ROOT32A}"; make_category_files "${ROOT32A}" 1
  ROOT32B="${TMP}/read-spawn-5"; make_playbook "${ROOT32B}"; make_ledger "${ROOT32B}"; make_category_files "${ROOT32B}" 5
  read_spawn_count "${ROOT32A}"; read_small="${READ_N}"; read_small_rc="${RC}"
  read_spawn_count "${ROOT32B}"; read_large="${READ_N}"; read_large_rc="${RC}"
  read_growth=$((read_large - read_small))
  if [[ "${read_small_rc}" -ne 0 || "${read_large_rc}" -ne 0 ]]; then
    bad "K32: 実行に失敗（rc=${read_small_rc} / ${read_large_rc}）"; printf '%s\n' "${OUT}" | tail -n 5 | sed 's/^/    | /' >&2
  elif [[ "${read_growth}" -le 0 ]]; then
    # 件数を増やしても増えないなら、追加したファイルを読んでいないか shim を通っていない。緑にしない。
    bad "K32: カテゴリ 1 件 / 5 件で起動回数が増えていない（${read_small} 回 / ${read_large} 回。測れていない）"
  elif [[ "${read_growth}" -le $((read_limit * 4)) ]]; then
    ok "K32: 読むファイル 4 件の追加で stat / mktemp / head / tr / awk の起動が ${read_growth} 回増えた（上限 1 件 ${read_limit} 回 × 4。1 件 ${read_small} 回 / 5 件 ${read_large} 回）"
  else
    bad "K32: 読むファイル 4 件の追加で起動が ${read_growth} 回増えた（上限 1 件 ${read_limit} 回 × 4。1 件 ${read_small} 回 / 5 件 ${read_large} 回）"
  fi
fi

# ── K22〜K25: ACE Playbook の配置解決（resolve_playbook。Issue `#2142`） ────────────────
# 優先順 --playbook → ACE_PLAYBOOK_PATH → 記録済み配置 → 既定パス → 探索。テンプレ配布リポジトリ
# （実体が docs-template/08-knowledge/ に在る）で「Playbook なし」と報告していた欠陥の回帰を見る。
make_template_playbook() { # <root> — Playbook の実体を docs-template/08-knowledge/ へ置く
  local root="$1"
  make_playbook "${root}"
  mkdir -p "${root}/docs-template"
  mv "${root}/docs/08-knowledge" "${root}/docs-template/08-knowledge"
}
run_resolve() { # <root> [args...] → OUT / RC（stdout だけ。KEY=VALUE の 4 行）
  local root="$1"; shift
  set +e
  OUT="$("${LOOKUP[@]}" --root "${root}" --resolve-playbook "$@" 2>/dev/null)"
  RC=$?
  set -e
}
run_with_env() { # <ACE_PLAYBOOK_PATH> <root> <args...> → OUT / RC
  local envp="$1" root="$2"; shift 2
  set +e
  OUT="$(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE ACE_PLAYBOOK_PATH="${envp}" bash "${TARGET}" --root "${root}" "$@" 2>&1)"
  RC=$?
  set -e
}
kv() { printf '%s\n' "${OUT}" | awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'; }

# K22: 記録済み配置（AGENTS.md のリンク先）から docs-template/ 配下の実体を採る（AC1）
ROOT22="${TMP}/template-recorded"; make_template_playbook "${ROOT22}"; make_ledger "${ROOT22}"
printf '%s\n' '採番ルールの SSOT は [PLAYBOOK.md §エントリID規則](docs-template/08-knowledge/PLAYBOOK.md#エントリid規則)。' >"${ROOT22}/AGENTS.md"
run_lookup "${ROOT22}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "== ACE Playbook（docs-template/08-knowledge/PLAYBOOK.md） ==" && out_has "ace_state=ok" \
  && out_has "ACE-10-1" && ! out_has "Playbook なし"; then
  ok "K22: 記録済み配置の docs-template/08-knowledge/PLAYBOOK.md を ok として検索する"
else
  bad "K22: 記録済み配置の Playbook を引けない（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -E '^(== ACE|RECORD|SUMMARY)' | sed 's/^/    | /' >&2 || true
fi
run_resolve "${ROOT22}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "ok" ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "recorded:AGENTS.md" ]] \
  && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/08-knowledge/PLAYBOOK.md" ]]; then
  ok "K22: --resolve-playbook は recorded:AGENTS.md と root 相対パスを返す"
else
  bad "K22: --resolve-playbook の出力が違う（rc=${RC}）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
fi
# 記録は記載ファイルのディレクトリ相対でも解く（docs/MASTER.md の `./…`）
ROOT22m="${TMP}/template-recorded-master"; make_template_playbook "${ROOT22m}"; mkdir -p "${ROOT22m}/docs"
printf '%s\n' '- [PLAYBOOK.md](../docs-template/08-knowledge/PLAYBOOK.md) - ACE 知見' >"${ROOT22m}/docs/MASTER.md"
run_resolve "${ROOT22m}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "recorded:docs/MASTER.md" ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/08-knowledge/PLAYBOOK.md" ]]; then
  ok "K22: docs/MASTER.md の記載ファイル相対リンクを解く"
else
  bad "K22: 記載ファイル相対の記録を解けない（rc=${RC}）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
fi

# K23: ACE_PLAYBOOK_PATH（AC1 の環境変数側）と、明示の優先・読めない指定の扱い
ROOT23="${TMP}/template-env"; make_template_playbook "${ROOT23}"; make_ledger "${ROOT23}"
run_with_env "${ROOT23}/docs-template/08-knowledge/PLAYBOOK.md" "${ROOT23}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ace_state=ok" && out_has "ACE-10-1"; then ok "K23: ACE_PLAYBOOK_PATH の Playbook を ok として検索する"; else bad "K23: ACE_PLAYBOOK_PATH が効かない（rc=${RC}）"; fi
run_with_env "${ROOT23}/docs-template/08-knowledge/PLAYBOOK.md" "${ROOT23}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "env" ]]; then ok "K23: --resolve-playbook は SOURCE=env"; else bad "K23: env の SOURCE が違う（rc=${RC}）"; fi
run_with_env "${ROOT23}/no-such/PLAYBOOK.md" "${ROOT23}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ace=読み取り失敗（ファイルを読めない）"; then ok "K23: 実在しない ACE_PLAYBOOK_PATH は読み取り失敗（探索で上書きしない）"; else bad "K23: 実在しない ACE_PLAYBOOK_PATH の扱い（rc=${RC}）"; fi
run_with_env "${ROOT23}/no-such/PLAYBOOK.md" "${ROOT23}" --resolve-playbook --playbook "${ROOT23}/docs-template/08-knowledge/PLAYBOOK.md"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "explicit" ]]; then ok "K23: --playbook は ACE_PLAYBOOK_PATH より優先"; else bad "K23: --playbook が優先されない（rc=${RC}）"; fi
run_with_env "   " "${ROOT22}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "recorded:AGENTS.md" ]]; then ok "K23: 空白だけの ACE_PLAYBOOK_PATH は未設定と同じ"; else bad "K23: 空白だけの ACE_PLAYBOOK_PATH を値として扱った（rc=${RC}）"; fi

# K24: 記録も環境変数も無い回は従来どおり探索し、docs-template/ の配布テンプレートを採らない（AC2）
ROOT24="${TMP}/template-unrecorded"; make_template_playbook "${ROOT24}"; make_ledger "${ROOT24}"
run_lookup "${ROOT24}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ace=Playbook なし" && ! out_has "ACE-10-1"; then ok "K24: 記録なしの docs-template/ 配下は探索で採らない"; else bad "K24: 記録なしで docs-template/ を採った（rc=${RC}）"; fi
# plugin 同梱の配布テンプレート（.claude-plugin/plugin.json を持つ dir 直下の docs-template/）は記録されていても採らない
ROOT24p="${TMP}/bundled-template"; make_playbook "${ROOT24p}"; make_ledger "${ROOT24p}"
make_template_playbook "${TMP}/bundled-src"; mkdir -p "${ROOT24p}/plugins/kit/.claude-plugin"
printf '{"name":"kit"}\n' >"${ROOT24p}/plugins/kit/.claude-plugin/plugin.json"
mv "${TMP}/bundled-src/docs-template" "${ROOT24p}/plugins/kit/docs-template"
printf '%s\n' '雛形は `plugins/kit/docs-template/08-knowledge/PLAYBOOK.md`。' >"${ROOT24p}/AGENTS.md"
run_resolve "${ROOT24p}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "default" ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs/08-knowledge/PLAYBOOK.md" ]]; then
  ok "K24: 記録が plugin 同梱テンプレートを指しても既定パスの実体を採る"
else
  bad "K24: plugin 同梱テンプレートを記録として採った（rc=${RC}）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
fi

# K25: 記録の矛盾は曖昧（推測で選ばない）。既定パスが候補に含まれるなら既定パスを採る
ROOT25="${TMP}/recorded-conflict"; make_template_playbook "${ROOT25}"; make_ledger "${ROOT25}"
mkdir -p "${ROOT25}/docs/old"; cp "${ROOT25}/docs-template/08-knowledge/PLAYBOOK.md" "${ROOT25}/docs/old/PLAYBOOK.md"
printf '%s\n' '`docs-template/08-knowledge/PLAYBOOK.md`' >"${ROOT25}/AGENTS.md"
printf '%s\n' '`docs/old/PLAYBOOK.md`' >"${ROOT25}/CLAUDE.md"
run_lookup "${ROOT25}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "ace=読み取り失敗（配置が曖昧" && ! out_has "ACE-10-1"; then ok "K25: 記録済み配置が 2 件なら曖昧として採らない"; else bad "K25: 矛盾した記録から 1 つを選んだ（rc=${RC}）"; fi
run_resolve "${ROOT25}"
if [[ "${RC}" -eq 2 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "ambiguous" ]] && [[ -z "$(kv ACE_PLAYBOOK)" ]]; then ok "K25: --resolve-playbook は rc=2 / STATE=ambiguous"; else bad "K25: 曖昧時の --resolve-playbook（rc=${RC}）"; fi
ROOT25d="${TMP}/recorded-default-and-stub"; make_playbook "${ROOT25d}"; make_ledger "${ROOT25d}"
printf '%s\n' '# moved' >"${ROOT25d}/docs/PLAYBOOK.md"
printf '%s\n' '- [PLAYBOOK.md](./08-knowledge/PLAYBOOK.md)（旧 `docs/PLAYBOOK.md` はリダイレクト）' >"${ROOT25d}/docs/MASTER.md"
run_resolve "${ROOT25d}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs/08-knowledge/PLAYBOOK.md" ]]; then ok "K25: 既定パスを含む複数の記録は既定パスを採る（旧配置の注記で退行しない）"; else bad "K25: 既定パスを含む記録で既定を採らない（rc=${RC}）"; fi

# 既定パスに実体があるのに記録がそれを含まない → 記録が 1 件でも 2 件でも曖昧（既定パスを黙って置き換えない）
ROOT25e="${TMP}/recorded-conflict-with-default"; make_template_playbook "${ROOT25e}"; make_playbook "${ROOT25e}"; make_ledger "${ROOT25e}"
mkdir -p "${ROOT25e}/docs/old"; printf '%s\n' '# moved' >"${ROOT25e}/docs/old/PLAYBOOK.md"
printf '%s\n' '`docs-template/08-knowledge/PLAYBOOK.md`' >"${ROOT25e}/AGENTS.md"
printf '%s\n' '`docs/old/PLAYBOOK.md`' >"${ROOT25e}/CLAUDE.md"
run_resolve "${ROOT25e}"
if [[ "${RC}" -eq 2 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "ambiguous" ]]; then ok "K25: 既定パスが実在し記録 2 件がそれを含まなければ曖昧"; else bad "K25: 既定パスが実在する記録の矛盾で 1 つを選んだ（rc=${RC}）"; fi
rm -f "${ROOT25e}/AGENTS.md"
run_resolve "${ROOT25e}"
if [[ "${RC}" -eq 2 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "ambiguous" ]]; then ok "K25: 既定パスが実在し記録 1 件がスタブを指すなら曖昧（スタブへ切り替えない）"; else bad "K25: 1 件の記録で実在する既定パスを置き換えた（rc=${RC} / $(kv ACE_PLAYBOOK_REL)）"; fi

# K27: 記録段の除外（root の外・ファイル自体の symlink・node_modules/・絶対パス）
ROOT27="${TMP}/recorded-excluded"; make_ledger "${ROOT27}"
make_template_playbook "${TMP}/outside-src"; mkdir -p "${TMP}/outside"; cp "${TMP}/outside-src/docs-template/08-knowledge/PLAYBOOK.md" "${TMP}/outside/PLAYBOOK.md"
mkdir -p "${ROOT27}/docs/kb" "${ROOT27}/node_modules/x" "${ROOT27}/docs/abs"
cp "${TMP}/outside/PLAYBOOK.md" "${ROOT27}/docs/abs/PLAYBOOK.md"
k27_links=1
if kl_skip_no_symlink 'K27 のファイル自体の symlink の記録と K28 の symlink の引数 3 件'; then k27_links=0
else ln -s "${TMP}/outside/PLAYBOOK.md" "${ROOT27}/docs/kb/PLAYBOOK.md"
fi
cp "${TMP}/outside/PLAYBOOK.md" "${ROOT27}/node_modules/x/PLAYBOOK.md"
for rec in '../outside/PLAYBOOK.md' 'docs/kb/PLAYBOOK.md' 'node_modules/x/PLAYBOOK.md' "${ROOT27}/docs/abs/PLAYBOOK.md"; do
  [[ "${k27_links}" -eq 1 || "${rec}" != docs/kb/PLAYBOOK.md ]] || continue
  printf '`%s`\n' "${rec}" >"${ROOT27}/AGENTS.md"
  run_resolve "${ROOT27}"
  # 記録として採らないことを見る（docs/abs/ の実体は探索段が拾ってよい）
  case "$(kv ACE_PLAYBOOK_SOURCE)" in
    recorded:*) bad "K27: 記録 ${rec} を採った（rc=${RC} / $(kv ACE_PLAYBOOK_SOURCE)）" ;;
    *) ok "K27: 記録 ${rec##*/../} は候補に数えない（SOURCE=$(kv ACE_PLAYBOOK_SOURCE)）" ;;
  esac
done

# K28: --resolve-playbook の出力契約（unreadable の PATH・相対指定の REL・root 内外の判定・symlink・キーワード拒否）
run_with_env "${ROOT23}/no-such/PLAYBOOK.md" "${ROOT23}" --resolve-playbook
if [[ "${RC}" -eq 2 ]] && [[ "$(kv ACE_PLAYBOOK_STATE)" = "unreadable" ]] && [[ "$(kv ACE_PLAYBOOK)" = "${ROOT23}/no-such/PLAYBOOK.md" ]] && [[ -z "$(kv ACE_PLAYBOOK_REL)" ]]; then
  ok "K28: 読めない指定は rc=2 / STATE=unreadable で、名指しされたパスを出し REL は空"
else
  bad "K28: unreadable の出力契約（rc=${RC}）"; printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
fi
set +e
OUT="$(cd "${ROOT23}" && "${LOOKUP[@]}" --root "${ROOT23}" --resolve-playbook --playbook docs-template/08-knowledge/PLAYBOOK.md 2>/dev/null)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/08-knowledge/PLAYBOOK.md" ]]; then ok "K28: cwd 相対の --playbook も root 相対の REL を返す"; else bad "K28: 相対指定の REL（rc=${RC} / $(kv ACE_PLAYBOOK_REL)）"; fi
run_with_env "${ROOT27}/../outside/PLAYBOOK.md" "${ROOT27}" --resolve-playbook
if [[ "${RC}" -eq 0 ]] && [[ -z "$(kv ACE_PLAYBOOK_REL)" ]]; then ok "K28: root/../ 経由で外へ出る絶対パスは REL を出さない"; else bad "K28: root の外を REL として返した（$(kv ACE_PLAYBOOK_REL)）"; fi
if [[ "${k27_links}" -eq 1 ]]; then # the skip line above names these three
  run_with_env "${ROOT27}/docs/kb/PLAYBOOK.md" "${ROOT27}" --resolve-playbook
  if [[ "${RC}" -eq 2 && "$(kv ACE_PLAYBOOK_STATE)" = unreadable ]] && [[ -z "$(kv ACE_PLAYBOOK_REL)" ]]; then ok "K28: root 内の引数から外部リンクへ許可を広げず REL も出さない"; else bad "K28: root 内の引数で外部リンクを認可した（rc=${RC}）"; fi
  mkdir -p "${ROOT27}/docs/real"; cp "${TMP}/outside/PLAYBOOK.md" "${ROOT27}/docs/real/PLAYBOOK.md"; ln -s ../real/PLAYBOOK.md "${ROOT27}/docs/kb/IN.md"
  run_with_env "${ROOT27}/docs/kb/IN.md" "${ROOT27}" --resolve-playbook
  if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs/kb/IN.md" ]]; then ok "K28: root 内を指す symlink ファイルは REL を出す"; else bad "K28: root 内の symlink の REL（$(kv ACE_PLAYBOOK_REL)）"; fi
  ln -s "${ROOT23}" "${TMP}/alias-root"
  run_with_env "${TMP}/alias-root/docs-template/08-knowledge/PLAYBOOK.md" "${ROOT23}" --resolve-playbook
  if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/08-knowledge/PLAYBOOK.md" ]]; then ok "K28: symlink 経由の表記でも root 内の絶対パスは REL を出す"; else bad "K28: 表記差で root 内を外扱いした（$(kv ACE_PLAYBOOK_REL)）"; fi
fi
run_lookup "${ROOT1}" --resolve-playbook hydration
if [[ "${RC}" -eq 1 ]]; then ok "K28: --resolve-playbook はキーワードを取らない（rc=1）"; else bad "K28: --resolve-playbook がキーワードを受け付けた（rc=${RC}）"; fi

# K29: ファイル名だけの指定でもカテゴリファイルを引く／非 ASCII を含む記録パスを途中で切らない
set +e
OUT="$(cd "${ROOT23}/docs-template/08-knowledge" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE ACE_PLAYBOOK_PATH=PLAYBOOK.md bash "${TARGET}" --root "${ROOT23}" --offline hydration 2>&1)"; RC=$?
set -e
if [[ "${RC}" -eq 0 ]] && out_has "ACE-10-1" && out_has "== ACE Playbook（docs-template/08-knowledge/PLAYBOOK.md） =="; then
  ok "K29: ACE_PLAYBOOK_PATH=PLAYBOOK.md（ファイル名だけ）でも playbook/ のエントリを引く"
else
  bad "K29: ファイル名だけの指定でカテゴリファイルを引けない（rc=${RC}）"; printf '%s\n' "${OUT}" | grep -E '^(== ACE|RECORD)' | sed 's/^/    | /' >&2 || true
fi
ROOT29="${TMP}/recorded-non-ascii"; make_playbook "${TMP}/non-ascii-src"; mkdir -p "${ROOT29}/docs-template"
mv "${TMP}/non-ascii-src/docs/08-knowledge" "${ROOT29}/docs-template/知見"
printf '%s\n' 'SSOT は [PLAYBOOK](docs-template/知見/PLAYBOOK.md#id)（`docs-template/知見/PLAYBOOK.md`）。' >"${ROOT29}/AGENTS.md"
run_resolve "${ROOT29}"
if [[ "${RC}" -eq 0 ]] && [[ "$(kv ACE_PLAYBOOK_REL)" = "docs-template/知見/PLAYBOOK.md" ]] && [[ "$(kv ACE_PLAYBOOK_SOURCE)" = "recorded:AGENTS.md" ]]; then
  ok "K29: 非 ASCII を含む記録パスを途中で切らずに採る"
else
  bad "K29: 非 ASCII を含む記録パスを採れない（rc=${RC} / $(kv ACE_PLAYBOOK_STATE) / $(kv ACE_PLAYBOOK_REL)）"
fi

# K26: /ace-curate・/ace-refine が同じ resolver を呼び、検索と解決が同じ配置を返す（AC3）
for f in skills/ace-curate/SKILL.md skills/ace-refine/SKILL.md; do
  if grep -qF -- 'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --resolve-playbook --with-index-mode' "${PLUGIN_ROOT}/${f}"; then
    ok "K26: ${f} は共通 resolver で配置と索引方式を解決する"
  else
    bad "K26: ${f} が共通 resolver（knowledge-lookup.sh --resolve-playbook）を呼んでいない"
  fi
done
if grep -qF -- '--resolve-playbook' "${PLUGIN_ROOT}/skills/ace-curate/references/curate.md"; then ok "K26: curate.md「配置先の解決」は共通 resolver を正本にする"; else bad "K26: curate.md が共通 resolver を参照していない"; fi
same_n=0
for r in "${ROOT22}" "${ROOT22m}" "${ROOT24p}" "${ROOT25d}" "${ROOT1}"; do
  run_resolve "${r}"; rel="$(kv ACE_PLAYBOOK_REL)"
  run_lookup "${r}" --offline zzz-no-such-word
  if [[ -n "${rel}" ]] && out_has "== ACE Playbook（${rel}） =="; then same_n=$((same_n + 1)); else bad "K26: ${r##*/} で検索と --resolve-playbook の配置が食い違う（resolve=${rel:-空}）"; fi
done
if [[ "${same_n}" -eq 5 ]]; then ok "K26: 5 fixture すべてで検索と --resolve-playbook が同じ配置を返す"; fi

# K33: 未宣言は従来の inline、索引を省略した知見は独自配置でも本文から検索できる。
run_lookup "${ROOT1}" --resolve-playbook --with-index-mode
if [[ "${RC}" -eq 0 && "$(kv ACE_INDEX_MODE)" = inline ]]; then
  ok "K33: 未宣言は inline"
else
  bad "K33: 未宣言が inline にならない（rc=${RC} / $(kv ACE_INDEX_MODE)）"
fi
ROOT_INDEX="${TMP}/index-mode"
index_rel="docs/custom/PLAYBOOK.md"
index_fixture="${ROOT_INDEX}/${index_rel}"
index_live="${index_fixture%/*}/playbook/coding.md"
mkdir -p "${index_live%/*}"
printf '%s\n' '---' 'ace_index_mode: omit' 'ace_entry_count: 1' '---' '# Playbook' >"${index_fixture}"
printf '%s\n' '# Coding' '### ACE-2131-1: hydration without an index' >"${index_live}"
run_lookup "${ROOT_INDEX}" --resolve-playbook --with-index-mode --playbook "${index_fixture}"
if [[ "${RC}" -eq 0 && "$(kv ACE_INDEX_MODE)" = omit && "$(kv ACE_PLAYBOOK_REL)" = "${index_rel}" ]]; then
  ok "K33: 独自配置の省略宣言を解決"
else
  bad "K33: 独自配置で省略を解決できない（rc=${RC}）"; printf '%s\n' "${OUT}" >&2
fi
run_lookup "${ROOT_INDEX}" --resolve-playbook --playbook "${index_fixture}"
if [[ "${RC}" -eq 0 ]] && ! out_has 'ACE_INDEX_MODE='; then
  ok "K33: 既存 resolver の出力にモードを足さない"
else
  bad "K33: 既存 resolver の出力が変わった（rc=${RC}）"; printf '%s\n' "${OUT}" >&2
fi
run_lookup "${ROOT_INDEX}" --playbook "${index_fixture}" --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has "RECORD ace=ACE-2131-1"; then
  ok "K33: 索引なしでもカテゴリ本文がヒット"
else
  bad "K33: 索引なしの本文が検索できない（rc=${RC}）"; printf '%s\n' "${OUT}" >&2
fi

# K34: 0 件の宣言だけでは破損を隠せない。省略宣言の誤記・重複も従来扱いに戻さない。
printf '%s\n' '---' 'ace_index_mode: omit' 'ace_entry_count: 0' '---' '# Playbook' >"${index_fixture}"
printf '%s\n' '# Coding' '```markdown' '### ACE-000-1: example' '```' >"${index_live}"
run_lookup "${ROOT_INDEX}" --offline example
if [[ "${RC}" -eq 0 ]] && out_has 'ace_state=empty' && out_has 'RECORD ace=0 件'; then
  ok "K34: 索引なしで宣言どおりの空は正常"
else
  bad "K34: 宣言済みの空を認識できない（rc=${RC}）"
fi
printf '%s\n' '# Coding' '### ACE 2131 broken' >"${index_live}"
run_lookup "${ROOT_INDEX}" --offline broken
if [[ "${RC}" -eq 2 ]] && out_has 'ACE Playbook=noentry'; then
  ok "K34: 索引節の外にある壊れた見出しは空にしない"
else
  bad "K34: 壊れた見出しを空と判定した（rc=${RC}）"
fi
printf '%s\n' '# Coding' >"${index_live}"
printf '%s\n' '---' 'ace_index_mode: omit' 'ace_entry_count: 1' '---' '# Playbook' >"${index_fixture}"
run_lookup "${ROOT_INDEX}" --offline missing
if [[ "${RC}" -eq 2 ]] && out_has 'ACE Playbook=noentry'; then
  ok "K34: 実体の無い非ゼロ件数は空にしない"
else
  bad "K34: 非ゼロ宣言を空と判定した（rc=${RC}）"
fi
for invalid_mode in 'ace_index_mode: split' 'ace_index_mode: omit'; do
  printf '%s\n' '---' 'ace_index_mode: omit' "$invalid_mode" '---' '# Playbook' >"${index_fixture}"
  run_lookup "${ROOT_INDEX}" --resolve-playbook --with-index-mode
  if [[ "${RC}" -eq 2 && "$(kv ACE_PLAYBOOK_STATE)" = index-invalid && -z "$(kv ACE_INDEX_MODE)" ]]; then
    ok "K34: 重複・競合する宣言で停止（${invalid_mode}）"
  else
    bad "K34: 重複・競合する宣言を採用した（${invalid_mode}, rc=${RC}）"
  fi
done
printf '%s\n' '# Playbook' 'ace_index_mode: omit' 'ace_entry_count: 0' >"${index_fixture}"
run_lookup "${ROOT_INDEX}" --offline missing
if [[ "${RC}" -eq 2 ]] && out_has 'ACE Playbook=noentry'; then
  ok "K34: 本文の宣言例で未宣言の索引欠落を正常にしない"
else
  bad "K34: 本文の宣言例を設定として扱った（rc=${RC}）"
fi

# K35: 壊れた入力を正常空にしない。退避済みの知見だけは明示検索できる。
printf '%s\n' '---' 'ace_index_mode: omit' 'ace_entry_count: 0' '---' '# Playbook' >"${index_fixture}"
printf '%s\n' '# Coding' '```markdown' '### ACE-2131-1: hydration' '~~~' >"${index_live}"
run_lookup "${ROOT_INDEX}" --offline hydration
if [[ "${RC}" -eq 2 ]] && out_has 'ACE Playbook=noentry'; then
  ok "K35: 閉じていないフェンスの内側に知見が隠れた回を空としない"
else
  bad "K35: 異なる種類のフェンスを閉じとして扱った（rc=${RC}）"
fi
printf '%s\n' '# Coding' >"${index_live}"
mkdir -p "${index_live%/*}/archive"
printf '%s\n' '### ACE-2131-1: hydration after archive' >"${index_live%/*}/archive/coding.md"
run_lookup "${ROOT_INDEX}" --include-archived --offline hydration
if [[ "${RC}" -eq 0 ]] && out_has 'ace_state=empty' && id_under_group 'アーカイブ（playbook/archive' 'ACE-2131-1'; then
  ok "K35: live が空で退避済みの知見は明示検索できる"
else
  bad "K35: アーカイブのみの省略配置を検索できない（rc=${RC}）"
fi
mv "${index_live%/*}" "${ROOT_INDEX}/saved-playbook"
if [[ "${kl_symlinks}" -eq 1 ]]; then
  ln -s missing-playbook "${index_live%/*}"
else
  : >"${index_live%/*}"
fi
run_lookup "${ROOT_INDEX}" --offline hydration
if [[ "${RC}" -eq 2 ]] && out_has 'ACE Playbook=unreadable'; then
  ok "K35: 壊れたカテゴリパスを空としない"
else
  bad "K35: 壊れたカテゴリパスを空と判定した（rc=${RC}）"
fi
run_lookup "${ROOT_INDEX}" --resolve-playbook --with-index-mode
if [[ "${RC}" -eq 2 && "$(kv ACE_PLAYBOOK_STATE)" = unreadable && -z "$(kv ACE_INDEX_MODE)" ]]; then
  ok "K35: 書き手の resolver も壊れたカテゴリパスで停止"
else
  bad "K35: resolver が壊れたカテゴリパスを許可した（rc=${RC}）"
fi

# K36: store 解決の lib が無い・途中で切れた回は検索を始めない（Issue `#2694`）。
# 関数の境界で切れたファイルは構文として通るので、source の前に最終行の完了印を照合する。
K36_ROOT="${TMP}/k36-plugin"
K36_LIB="${K36_ROOT}/scripts/lib/knowledge-lookup-store.sh"
mkdir -p "${K36_ROOT}/.claude-plugin"
cp "${PLUGIN_ROOT}/.claude-plugin/plugin.json" "${K36_ROOT}/.claude-plugin/plugin.json"
cp -R "${PLUGIN_ROOT}/scripts" "${K36_ROOT}/scripts"
k36_run() {
  set +e
  OUT="$("${LOOKUP[@]:0:${#LOOKUP[@]}-1}" "${K36_ROOT}/scripts/knowledge-lookup.sh" --root "${ROOT_INDEX}" --offline hydration 2>&1)"
  RC=$?
  set -e
}
k36_expect_refused() { # <label>
  k36_run
  if [[ "${RC}" -eq 2 ]] && out_has 'store 解決の関数を読めません' && ! out_has 'ACE Playbook='; then
    ok "K36: ${1}回は検索を始めず rc=2 で止まる"
  else
    bad "K36: ${1}回の停止が違う（rc=${RC}）"
  fi
}
k36_run
if [[ "${RC}" -eq 2 ]] && out_has 'ACE Playbook=unreadable'; then
  ok "K36: 完全な lib の写しは K35 と同じ判定へ進む（対照）"
else
  bad "K36: 完全な lib の写しが対照どおりに動かない（rc=${RC}）"
fi
sed '$d' "${K36_LIB}" >"${K36_LIB}.cut"
mv "${K36_LIB}.cut" "${K36_LIB}"
k36_expect_refused '最終行が切れた'
rm -f "${K36_LIB}"
k36_expect_refused 'lib が無い'

# ── K37〜K46: --impl / --class 型付き引数と作業クラス語候補 ───────────────────
ROOT_TYPED="${TMP}/typed-args"
mkdir -p "${ROOT_TYPED}/docs/08-knowledge/playbook"
cat >"${ROOT_TYPED}/docs/08-knowledge/PLAYBOOK.md" <<'EOF'
# PLAYBOOK

## エントリ一覧

| ID | 概要 | カテゴリ | 場所 |
| --- | --- | --- | --- |
| ACE-200-1 | サブプロセス起動のキャッシュを実装する | coding | [coding.md#ace-200-1](./playbook/coding.md#ace-200-1) |
| ACE-200-2 | テンプレートの置き換えでは全ファイルを確認する | coding | [coding.md#ace-200-2](./playbook/coding.md#ace-200-2) |
| ACE-200-3 | 決定の反映を別担当へ回すときは境界を書く | coding | [coding.md#ace-200-3](./playbook/coding.md#ace-200-3) |
| ACE-200-4 | 廃用専用の特殊候補文字列を混ぜない | coding | [coding.md#ace-200-4](./playbook/coding.md#ace-200-4) |
EOF
cat >"${ROOT_TYPED}/docs/08-knowledge/playbook/coding.md" <<'EOF'
# PLAYBOOK — coding

## エントリ一覧

<a id="ace-200-1"></a>

### ACE-200-1: サブプロセス起動のキャッシュを実装する

| Category | coding | Origin | PR-200 |
| Date | 2026-10-01 |
| Helpful | 1 | Harmful | 0 |
| Status | active |

terminology 整理時のサブプロセス最適化。

---

<a id="ace-200-2"></a>

### ACE-200-2: テンプレートの置き換えでは全ファイルを確認する

| Category | coding | Origin | PR-200 |
| Date | 2026-10-02 |
| Helpful | 2 | Harmful | 0 |
| Status | active |

用語集の一括更新とは別に作業クラスが「置き換え」に該当する。

---

<a id="ace-200-3"></a>

### ACE-200-3: 決定の反映を別担当へ回すときは境界を書く

| Category | coding | Origin | PR-200 |
| Date | 2026-10-03 |
| Helpful | 1 | Harmful | 0 |
| Status | active |

表記の統一と一緒に決着先を残す。

---

<a id="ace-200-4"></a>

### ACE-200-4: 廃用専用の特殊候補文字列を混ぜない

| Category | coding | Origin | PR-200 |
| Date | 2026-10-04 |
| Helpful | 0 | Harmful | 1 |
| Status | deprecated |

deprecated 専用の文言。

---
EOF
make_ledger "${ROOT_TYPED}"

run_lookup_split() {
  local root="$1"; shift
  set +e
  "${LOOKUP[@]}" --root "${root}" "$@" >"${TMP}/split.out" 2>"${TMP}/split.err"
  RC=$?
  set -e
  SPLIT_STDOUT="$(cat "${TMP}/split.out")"
  SPLIT_STDERR="$(cat "${TMP}/split.err")"
}

# K37: --impl のみ -> stderr 警告 + RECORD に class=未指定 + SUMMARY 拡張 + 候補見出し
run_lookup_split "${ROOT_TYPED}" --offline --impl terminology
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- '作業クラス語（--class）が未指定' "${TMP}/split.err" \
   && grep -qF -- 'RECORD ace=ACE-200-1' "${TMP}/split.out" \
   && grep -qF -- 'class=未指定' "${TMP}/split.out" \
   && grep -qF -- 'impl_keywords=1 class_keywords=0' "${TMP}/split.out" \
   && grep -qF -- '== 作業クラス語の候補（Playbook タイトル由来） ==' "${TMP}/split.out"; then
  ok "K37: --impl のみで呼ぶと警告・class=未指定・SUMMARY・作業クラス語候補が出る"
else
  bad "K37: --impl のみの出力が期待と違う rc=${RC} err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi

# K38: --class のみ -> stderr 警告 + RECORD に impl=未指定 + SUMMARY 拡張
run_lookup_split "${ROOT_TYPED}" --offline --class 置き換え
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- '実装語（--impl）が未指定' "${TMP}/split.err" \
   && grep -qF -- 'RECORD ace=ACE-200-2' "${TMP}/split.out" \
   && grep -qF -- 'impl=未指定' "${TMP}/split.out" \
   && ! grep -qF -- 'class=未指定' "${TMP}/split.out" \
   && grep -qF -- 'impl_keywords=0 class_keywords=1' "${TMP}/split.out"; then
  ok "K38: --class のみで呼ぶと警告・impl=未指定・SUMMARY が出る"
else
  bad "K38: --class のみの出力が期待と違う rc=${RC} err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi

# K39: --impl と --class の両方指定 -> 欠落警告なし・系統別分離出力・RECORD impl / RECORD class
run_lookup_split "${ROOT_TYPED}" --offline --impl terminology --class 置き換え
if [[ "${RC}" -eq 0 ]] \
   && ! grep -qF -- '未指定' "${TMP}/split.err" \
   && ! grep -qF -- '警告:' "${TMP}/split.err" \
   && ! grep -qF -- '未指定' "${TMP}/split.out" \
   && grep -qF -- '=== 系統: 実装語（--impl） ===' "${TMP}/split.out" \
   && grep -qF -- '=== 系統: 作業クラス語（--class） ===' "${TMP}/split.out" \
   && grep -qF -- 'RECORD impl ace=ACE-200-1 obs=0 件' "${TMP}/split.out" \
   && grep -qF -- 'RECORD class ace=ACE-200-2 obs=0 件' "${TMP}/split.out" \
   && grep -qF -- 'impl_keywords=1 class_keywords=1 impl_ace=1 impl_obs=0 class_ace=1 class_obs=0' "${TMP}/split.out"; then
  ok "K39: --impl と --class の両方を渡すと欠落警告なしで系統別に RECORD impl / RECORD class が出る"
else
  bad "K39: 両軸指定の出力が期待と違う rc=${RC} err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi
run_lookup_split "${ROOT_TYPED}" --offline --impl nonexistent_word --class 置き換え
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- 'RECORD impl ace=0 件 obs=0 件' "${TMP}/split.out" \
   && grep -qF -- 'RECORD class ace=ACE-200-2 obs=0 件' "${TMP}/split.out" \
   && grep -qF -- 'SUMMARY ace=1 obs=0 ' "${TMP}/split.out" \
   && grep -qF -- 'impl_ace=0 impl_obs=0 class_ace=1 class_obs=0' "${TMP}/split.out"; then
  ok "K39b: 両軸指定で片方が 0 件でも RECORD impl / RECORD class を独立に記録できる"
else
  bad "K39b: 片側 0 件の両軸指定が期待と違う rc=${RC} out=[${SPLIT_STDOUT}]"
fi
run_lookup_split "${ROOT_TYPED}" --offline --impl coding --class 置き換え
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- 'SUMMARY ace=4 obs=0 ' "${TMP}/split.out" \
   && grep -qF -- 'impl_ace=4 impl_obs=0 class_ace=1 class_obs=0' "${TMP}/split.out"; then
  ok "K39c: 両軸重複ヒット時は SUMMARY ace に和集合件数（4）を出しつつ系統別件数を保持する"
else
  bad "K39c: 両軸重複ヒット集計が期待と違う rc=${RC} out=[${SPLIT_STDOUT}]"
fi

# K40: 候補はすべて active Playbook タイトルの部分文字列で、deprecated や入力済み語を含まない
run_lookup_split "${ROOT_TYPED}" --offline --impl テンプレートの置き換え
cand_line="$(awk '/^== 作業クラス語の候補（Playbook タイトル由来） ==$/{getline; gsub(/^[[:space:]]+/, ""); print; exit}' "${TMP}/split.out")"
if [[ -n "${cand_line}" ]] \
   && ! grep -qF -- '特殊候補' <<<"${cand_line}" \
   && ! grep -qF -- '廃用専用' <<<"${cand_line}"; then
  k40_ok=1
  active_titles=$'サブプロセス起動のキャッシュを実装する\nテンプレートの置き換えでは全ファイルを確認する\n決定の反映を別担当へ回すときは境界を書く'
  old_ifs="$IFS"
  IFS='/'
  for c in $cand_line; do
    c_trim="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$c")"
    [ -n "$c_trim" ] || continue
    if [ "$c_trim" = "テンプレートの置き換え" ]; then
      k40_ok=0; bad "K40: 既入力キーワード ${c_trim} が候補から除かれていない"
    fi
    if ! grep -qF -- "$c_trim" <<<"$active_titles"; then
      k40_ok=0; bad "K40: 候補 [${c_trim}] が active な Playbook タイトルの部分文字列でない"
    fi
  done
  IFS="$old_ifs"
  if [ "$k40_ok" -eq 1 ]; then
    ok "K40: 作業クラス語候補は active タイトル由来のみで deprecated・既入力語を含まない"
  fi
else
  bad "K40: 候補行の検証に失敗 cand=[${cand_line}]"
fi

# K41: --format tsv でも RECORD と未指定印/系統別出力が保たれ、見出しや候補見出しが TSV に混入しない
run_lookup_split "${ROOT_TYPED}" --offline --format tsv --impl terminology
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- '作業クラス語（--class）が未指定' "${TMP}/split.err" \
   && grep -qF -- 'class=未指定' "${TMP}/split.out" \
   && ! grep -qF -- '== 作業クラス語の候補' "${TMP}/split.out"; then
  ok "K41: --format tsv（単軸）では class=未指定 を保ちつつ候補見出しを混入しない"
else
  bad "K41: tsv 出力が期待と違う rc=${RC} out=[${SPLIT_STDOUT}]"
fi
run_lookup_split "${ROOT_TYPED}" --offline --format tsv --impl terminology --class 置き換え
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- 'RECORD impl ace=ACE-200-1 obs=0 件' "${TMP}/split.out" \
   && grep -qF -- 'RECORD class ace=ACE-200-2 obs=0 件' "${TMP}/split.out" \
   && ! grep -qF -- '=== 系統:' "${TMP}/split.out" \
   && ! grep -qF -- '== 作業クラス語の候補' "${TMP}/split.out"; then
  ok "K41b: --format tsv（両軸）では 6 列 TSV + RECORD impl / RECORD class を保ち見出しを混入しない"
else
  bad "K41b: 両軸 tsv 出力が期待と違う rc=${RC} out=[${SPLIT_STDOUT}]"
fi

# K42: エラー系（値なし・位置引数混在・モード併用）はすべて rc=1 で止まる
k42_err_ok=1
for bad_args in "--impl" "--class" "--impl --class x" "--impl a -- b" "--impl a --promoted-open"; do
  set -f
  # shellcheck disable=SC2086
  run_lookup_split "${ROOT_TYPED}" --offline $bad_args
  set +f
  if [[ "${RC}" -ne 1 ]]; then
    k42_err_ok=0
    bad "K42: 不正引数 [${bad_args}] が rc=${RC}（期待 1）"
  fi
done
if [ "$k42_err_ok" -eq 1 ]; then
  ok "K42: 不正引数（値なし・位置引数混在・モード併用）はすべて rc=1 で止まる"
fi

# K43: 従来の位置引数形式では型付き拡張出力を一切出さない
run_lookup_split "${ROOT_TYPED}" --offline terminology
if [[ "${RC}" -eq 0 ]] \
   && ! grep -qF -- '警告:' "${TMP}/split.err" \
   && ! grep -qF -- '未指定' "${TMP}/split.err" \
   && ! grep -qF -- '未指定' "${TMP}/split.out" \
   && ! grep -qF -- 'impl_keywords=' "${TMP}/split.out" \
   && ! grep -qF -- '== 作業クラス語の候補' "${TMP}/split.out"; then
  ok "K43: 従来の位置引数は完全後方互換で余計な出力を足さない"
else
  bad "K43: 従来位置引数に副作用がある err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi

# K44: 空文字引数・--impl 複数回指定・--all 併用境界
run_lookup_split "${ROOT_TYPED}" --offline --impl terminology --class ""
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- '作業クラス語（--class）が未指定' "${TMP}/split.err" \
   && grep -qF -- 'class=未指定' "${TMP}/split.out" \
   && grep -qF -- 'impl_keywords=1 class_keywords=0' "${TMP}/split.out"; then
  ok "K44: --class に空文字を渡しても指定済みと数えず警告・class=未指定・class_keywords=0 になる"
else
  bad "K44: --class 空文字の扱いが期待と違う rc=${RC} err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi
run_lookup_split "${ROOT_TYPED}" --offline --impl ""
if [[ "${RC}" -eq 1 ]]; then
  ok "K44b: --impl に空文字だけを渡した場合はキーワード無しとして rc=1 になる"
else
  bad "K44b: --impl 空文字が rc=1 でない（rc=${RC}）"
fi
run_lookup_split "${ROOT_TYPED}" --offline --impl terminology --class 置き換え --impl 境界
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- 'impl_keywords=2 class_keywords=1' "${TMP}/split.out" \
   && grep -qF -- 'RECORD impl ace=ACE-200-1,ACE-200-3 obs=0 件' "${TMP}/split.out"; then
  ok "K44c: --impl を複数回分けて渡すと全語が実装語側へ蓄積する"
else
  bad "K44c: 複数 --impl の蓄積が期待と違う rc=${RC} out=[${SPLIT_STDOUT}]"
fi
run_lookup_split "${ROOT_TYPED}" --offline --all --impl terminology nonexistent_word
if [[ "${RC}" -eq 0 ]] && grep -qF -- 'RECORD ace=0 件 obs=0 件' "${TMP}/split.out"; then
  ok "K44d: --all と型付き引数を併用すると AND で絞られる"
else
  bad "K44d: --all 併用が期待と違う rc=${RC} out=[${SPLIT_STDOUT}]"
fi

# K45: 両軸指定時の PENDING_CANDIDATES.md 系統別集計と SUMMARY 和集合
ROOT_TYPED_PENDING="${TMP}/typed-pending"
mkdir -p "${ROOT_TYPED_PENDING}/docs/08-knowledge"
cp -R "${ROOT_TYPED}/docs/08-knowledge/." "${ROOT_TYPED_PENDING}/docs/08-knowledge/"
cat >"${ROOT_TYPED_PENDING}/docs/08-knowledge/PENDING_CANDIDATES.md" <<'EOF'
<!-- ff-ace-pending:v1 -->
# ACE 保留候補

## エントリ一覧

### PENDING-PR-201-1: impl 専用の保留候補
| Category | coding |
| Origin | PR 201 |
| Status | pending |

> alpha_pending_only の保留本文。

---

### PENDING-PR-201-2: 共有クラス語の保留候補
| Category | coding |
| Origin | PR 201 |
| Status | pending |

> alpha_pending_only と beta_pending_class の両方に該当する保留本文。

---
EOF
run_lookup_split "${ROOT_TYPED_PENDING}" --offline --impl alpha_pending_only --class beta_pending_class
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- 'RECORD impl ace=0 件 obs=0 件 pending=PENDING-PR-201-1,PENDING-PR-201-2' "${TMP}/split.out" \
   && grep -qF -- 'RECORD class ace=0 件 obs=0 件 pending=PENDING-PR-201-2' "${TMP}/split.out" \
   && grep -qF -- 'pending=2 pending_state=ok' "${TMP}/split.out"; then
  ok "K45: 両軸指定で pending を系統別に記録しつつ SUMMARY pending に和集合件数（2）を出す"
else
  bad "K45: 両軸 pending 集計が期待と違う rc=${RC} err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi

# K46: 両軸指定時の batch モード unreflected 2 回目パス再出力（RECORD impl=0 件 / RECORD class=ヒット）
# shellcheck source=../lib/git-fixture.sh
. "${PLUGIN_ROOT}/tests/lib/git-fixture.sh"
K46_WORLD="${TMP}/k46-batch"
mkdir -p "${K46_WORLD}"
git init -q --bare "${K46_WORLD}/origin.git"
ff_git_fixture_init "${K46_WORLD}/repo" "K46 Runner" "k46@example.com" >/dev/null
(
  cd "${K46_WORLD}/repo" || exit 1
  git switch -q -c develop
  mkdir -p docs/08-knowledge/playbook
  printf '# PLAYBOOK\n\n## エントリ一覧\n' >docs/08-knowledge/PLAYBOOK.md
  printf '# coding\n\n## エントリ一覧\n' >docs/08-knowledge/playbook/coding.md
  printf '# 観測台帳\n\n## エントリ一覧\n' >docs/08-knowledge/OBSERVATIONS.md
  printf 'mode=batch\n' >docs/08-knowledge/knowledge-delivery.conf
  git add -A
  git commit -qm "chore: k46 seed"
  git remote add origin "${K46_WORLD}/origin.git"
  git push -q origin develop
  git switch -q -c knowledge/staging
  cat >>docs/08-knowledge/playbook/coding.md <<'ACEEOF'

<a id="ace-202-1"></a>

### ACE-202-1: 未反映のクラス専用エントリ

| Category | coding | Origin | PR-202 |
| Date | 2026-10-05 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

unreflect_class_needle のみを含む未反映知見。

---
ACEEOF
  cat >docs/08-knowledge/PLAYBOOK.md <<'PBEOF'
# PLAYBOOK

## エントリ一覧

| ID | 概要 | カテゴリ | 場所 |
| --- | --- | --- | --- |
| ACE-202-1 | 未反映のクラス専用エントリ | coding | [coding.md#ace-202-1](./playbook/coding.md#ace-202-1) |
PBEOF
  git add -A
  git commit -qm "knowledge: unreflected ACE-202-1"
  git push -q origin knowledge/staging
  git switch -q develop
  git fetch -q origin
)
git -C "${K46_WORLD}/origin.git" symbolic-ref HEAD refs/heads/develop
git -C "${K46_WORLD}/repo" remote set-head origin develop >/dev/null
run_lookup_split "${K46_WORLD}/repo" --offline --impl unreflect_impl_miss --class unreflect_class_needle
if [[ "${RC}" -eq 0 ]] \
   && grep -qF -- 'RECORD impl ace=0 件 obs=0 件 unreflected=0 件' "${TMP}/split.out" \
   && grep -qF -- 'RECORD class ace=0 件 obs=0 件 unreflected=ACE-202-1' "${TMP}/split.out" \
   && grep -qF -- 'unreflected=1 unreflected_commits=1 unreflected_state=unverified' "${TMP}/split.out"; then
  ok "K46: 両軸指定時の 2 回目パスでも unreflected を再出力・系統別記録する"
else
  bad "K46: 両軸 batch unreflected が期待と違う rc=${RC} err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi

# ── K47: --each（語ごとの検索。1 回の起動で語の数だけ RECORD を返す。Issue `#2921`） ──────────
run_lookup_split "${ROOT_TYPED}" --offline --each terminology 置き換え nonexistent_word
k47_records="$(grep -- '^RECORD ' "${TMP}/split.out" || true)"
if [[ "${RC}" -eq 0 && "${SPLIT_STDERR}" != *'警告:'* && "${SPLIT_STDERR}" != *'未指定'* \
   && "${k47_records}" == $'RECORD each ace=ACE-200-1 obs=0 件 keyword=terminology\nRECORD each ace=ACE-200-2 obs=0 件 keyword=置き換え\nRECORD each ace=0 件 obs=0 件 keyword=nonexistent_word' \
   && "$(grep -- '^=== 語: ' "${TMP}/split.out")" == $'=== 語: terminology ===\n=== 語: 置き換え ===\n=== 語: nonexistent_word ===' \
   && "$(grep -c -- '^SUMMARY ' "${TMP}/split.out")" -eq 1 ]] \
   && grep -qF -- 'SUMMARY ace=2 obs=0 keywords=3 match=any ' "${TMP}/split.out" \
   && [[ "$(tail -n 1 "${TMP}/split.out")" == *' each_keywords=3' ]] \
   && ! grep -qF -- 'impl_keywords=' "${TMP}/split.out"; then
  ok "K47: --each は渡した順に語ごとの節と RECORD each … keyword=<語> を出し、SUMMARY は 1 行で重複なしの件数と each_keywords を持つ"
else
  bad "K47: --each の語ごとの出力が期待と違う rc=${RC} err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi
# 語ごとの RECORD は、その語だけを単独で引いた回の RECORD と同じ ID を返す（束ねた照合へ落ちていない）
k47_same=1
for k47_kw in terminology 置き換え coding nonexistent_word; do
  run_lookup_split "${ROOT_TYPED}" --offline "${k47_kw}"
  k47_single="$(grep -- '^RECORD ' "${TMP}/split.out" || true)"
  run_lookup_split "${ROOT_TYPED}" --offline --each coding "${k47_kw}"
  k47_each="$(grep -- "^RECORD each .* keyword=${k47_kw}\$" "${TMP}/split.out" | tail -n 1 || true)"
  [[ -n "${k47_single}" && "RECORD each ${k47_single#RECORD } keyword=${k47_kw}" == "${k47_each}" ]] || k47_same=0
done
run_lookup_split "${ROOT_TYPED}" --offline --each coding 置き換え
if [[ "${k47_same}" -eq 1 && "${RC}" -eq 0 ]] && grep -qF -- 'SUMMARY ace=4 obs=0 keywords=2 ' "${TMP}/split.out"; then
  ok "K47b: 語ごとの RECORD は単独で引いた回と同じ ID を返し、語をまたいで重なるヒットは SUMMARY で 1 回だけ数える（和集合 4）"
else
  bad "K47b: 語ごとの結果が単独検索と食い違う、または和集合の件数が違う same=${k47_same} rc=${RC} out=[${SPLIT_STDOUT}]"
fi
run_lookup_split "${ROOT_TYPED}" --offline --each "   " "no such phrase" ""
if [[ "${RC}" -eq 0 && "$(grep -c -- '^RECORD ' "${TMP}/split.out")" -eq 1 ]] \
   && grep -qxF -- 'RECORD each ace=0 件 obs=0 件 keyword=no such phrase' "${TMP}/split.out" \
   && [[ "$(tail -n 1 "${TMP}/split.out")" == *' keywords=1 '*' each_keywords=1' ]]; then
  ok "K47c: 空白だけの語は数えず、空白を含む語は keyword= から行末までにそのまま載る"
else
  bad "K47c: 空白だけの語・空白を含む語の扱いが期待と違う rc=${RC} out=[${SPLIT_STDOUT}]"
fi
# 断る理由ごとに stderr の文面まで見る（別の理由の rc=1 と取り違えない）
k47_reject=""
k47_refuse() { # <ラベル> <stderr に要る文> <引数...>
  local label="$1" needle="$2"; shift 2
  run_lookup_split "${ROOT_TYPED}" --offline "$@"
  [[ "${RC}" -eq 1 && -z "${SPLIT_STDOUT}" && "${SPLIT_STDERR}" == *"${needle}"* ]] || k47_reject="${k47_reject} ${label}(rc=${RC})"
}
k47_refuse impl '--each は --impl / --class と併用できません' --each --impl 境界
k47_refuse class '--each は --impl / --class と併用できません' --each --class 置き換え
k47_refuse all '--each は --all と併用できません' --all --each terminology 境界
k47_refuse promoted-open '--promoted-open は --each と併用できません' --each --promoted-open
k47_refuse none 'キーワードが 1 つも指定されていません' --each
k47_refuse blank 'キーワードが 1 つも指定されていません' --each "  " ""
k47_refuse newline '--each の語に改行・復帰・タブは使えません' --each terminology $'境界\nRECORD each ace=ACE-999-9'
k47_refuse tab '--each の語に改行・復帰・タブは使えません' --each $'a\tb'
k47_refuse cr '--each の語に改行・復帰・タブは使えません' --each $'terminology\r'
if [[ -z "${k47_reject}" ]]; then
  ok "K47d: --each は --impl / --class / --all / 他のモードとの併用・語なし・空白だけ・改行 / タブ / 復帰入りの語を、理由を名指して rc=1 で断り、stdout へ何も出さない"
else
  bad "K47d: --each の併用・不正な語を、名指した理由で断らない:${k47_reject}"
fi
# 語は -- の後ろへ置く: オプションと同じ綴り・- 始まりの語も語として引く（オプションとして読まない）
run_lookup_split "${ROOT_TYPED}" --offline --each -- --offline -x terminology --all
if [[ "${RC}" -eq 0 ]] \
   && [[ "$(grep -- '^RECORD ' "${TMP}/split.out")" == $'RECORD each ace=0 件 obs=0 件 keyword=--offline\nRECORD each ace=0 件 obs=0 件 keyword=-x\nRECORD each ace=ACE-200-1 obs=0 件 keyword=terminology\nRECORD each ace=0 件 obs=0 件 keyword=--all' ]] \
   && [[ "$(tail -n 1 "${TMP}/split.out")" == *' each_keywords=4' ]]; then
  ok "K47h: -- の後ろの語は、オプションと同じ綴り・- 始まりでも語として 1 語ずつ引く"
else
  bad "K47h: -- の後ろの語をオプションとして読んだ rc=${RC} err=[${SPLIT_STDERR}] out=[${SPLIT_STDOUT}]"
fi
# 台帳側: 語ごとの obs= は単独で引いた回と同じで、Issue state の照会（gh）は語の数だけ増えない
k47_obs_same=1
for k47_kw in hydration allowlist; do
  run_lookup_split "${ROOT1}" --offline "${k47_kw}"
  k47_single="$(grep -- '^RECORD ' "${TMP}/split.out" || true)"
  run_lookup_split "${ROOT1}" --offline --each -- hydration allowlist
  k47_each="$(grep -- "^RECORD each .* keyword=${k47_kw}\$" "${TMP}/split.out" || true)"
  [[ "${k47_single}" == *'obs=OBS-'* && "RECORD each ${k47_single#RECORD } keyword=${k47_kw}" == "${k47_each}" ]] || k47_obs_same=0
done
k47_obs_summary="$(tail -n 1 "${TMP}/split.out")"
: >"${GH_REPO_LOG}"
set +e
GH_REPO_LOG="${GH_REPO_LOG}" PATH="${STUB_BIN3}:${PATH}" "${LOOKUP[@]}" --root "${ROOT12}" references >/dev/null 2>&1; k47_rc1=$?
set -e
k47_gh_single="$(awk 'END { print NR }' "${GH_REPO_LOG}")"
: >"${GH_REPO_LOG}"
set +e
GH_REPO_LOG="${GH_REPO_LOG}" PATH="${STUB_BIN3}:${PATH}" "${LOOKUP[@]}" --root "${ROOT12}" --each -- references references references >"${TMP}/split.out" 2>/dev/null; k47_rc3=$?
set -e
k47_gh_each="$(awk 'END { print NR }' "${GH_REPO_LOG}")"
if [[ "${k47_obs_same}" -eq 1 && "${k47_obs_summary}" == 'SUMMARY ace=2 obs=5 keywords=2 '* \
   && "${k47_rc1}" -eq 0 && "${k47_rc3}" -eq 0 && "${k47_gh_single}" -ge 1 && "${k47_gh_each}" -eq "${k47_gh_single}" \
   && "$(grep -c -- '^RECORD each .*(open)\|^RECORD each ' "${TMP}/split.out")" -eq 3 ]]; then
  ok "K47i: 台帳にヒットがある語も語ごとの obs= が単独検索と一致し、和集合で数え、gh の照会は 3 語でも単独の回と同じ ${k47_gh_single} 回"
else
  bad "K47i: 台帳側の語ごとの記録・和集合・gh の照会回数が期待と違う same=${k47_obs_same} summary=[${k47_obs_summary}] gh=${k47_gh_single}/${k47_gh_each} rc=${k47_rc1}/${k47_rc3}"
fi
run_lookup_split "${ROOT_TYPED}" --offline --format tsv --each terminology 置き換え
k47_tsv_bad="$(awk -F '\t' '/^(ace|obs)\t/ { if (NF != 6) c++ } END { print c + 0 }' "${TMP}/split.out")"
if [[ "${RC}" -eq 0 && "${k47_tsv_bad}" -eq 0 && "$(grep -c -- '^ace	' "${TMP}/split.out")" -eq 2 ]] \
   && [[ "$(grep -- '^RECORD ' "${TMP}/split.out")" == $'RECORD each ace=ACE-200-1 obs=0 件 keyword=terminology\nRECORD each ace=ACE-200-2 obs=0 件 keyword=置き換え' ]] \
   && ! grep -qF -- '=== 語:' "${TMP}/split.out"; then
  ok "K47e: --format tsv の --each は 6 列の行を語の順に並べ、語ごとの RECORD を保ち、見出しを混ぜない"
else
  bad "K47e: tsv の --each が期待と違う rc=${RC} out=[${SPLIT_STDOUT}]"
fi
run_lookup_split "${ROOT_TYPED_PENDING}" --offline --each alpha_pending_only beta_pending_class
k47_pending="$(grep -- '^RECORD ' "${TMP}/split.out" || true)"
run_lookup_split "${K46_WORLD}/repo" --offline --each unreflect_impl_miss unreflect_class_needle
if [[ "${k47_pending}" == $'RECORD each ace=0 件 obs=0 件 pending=PENDING-PR-201-1,PENDING-PR-201-2 keyword=alpha_pending_only\nRECORD each ace=0 件 obs=0 件 pending=PENDING-PR-201-2 keyword=beta_pending_class' \
   && "${RC}" -eq 0 && "$(grep -c -- '^RECORD ' "${TMP}/split.out")" -eq 2 \
   && "$(sed -n '/^RECORD /p' "${TMP}/split.out" | sed -n 1p)" == 'RECORD each ace=0 件 obs=0 件 unreflected=0 件'*' keyword=unreflect_impl_miss' \
   && "$(sed -n '/^RECORD /p' "${TMP}/split.out" | sed -n 2p)" == 'RECORD each ace=0 件 obs=0 件 unreflected=ACE-202-1'*' keyword=unreflect_class_needle' ]] \
   && grep -qF -- 'unreflected=1 unreflected_commits=1 unreflected_state=unverified each_keywords=2' "${TMP}/split.out"; then
  ok "K47f: 保留候補と未反映（まとめるモード）も語ごとに記録し、2 語目以降のパスでも未反映を出し直す"
else
  bad "K47f: 保留候補・未反映の語ごとの記録が期待と違う rc=${RC} pending=[${k47_pending}] out=[${SPLIT_STDOUT}]"
fi
# 使う側の手順: 重複照合は語ごとにループで呼ばず --each の 1 回へまとめる（AC 2）
k47_curate="${PLUGIN_ROOT}/skills/ace-curate/references/curate.md"
k47_skill="${PLUGIN_ROOT}/skills/knowledge-lookup/SKILL.md"
if [[ -r "${k47_curate}" && -r "${k47_skill}" ]] \
   && grep -qF -- '候補語の検索は語ごとにループで呼ばず、`--each` の 1 回の呼び出しへまとめる' "${k47_curate}" \
   && grep -qF -- 'scripts/knowledge-lookup.sh" --each -- ' "${k47_curate}" \
   && grep -qF -- '`RECORD each ace=… obs=… keyword=<語>`' "${k47_skill}"; then
  ok "K47g: /ace-curate の重複照合の手順が --each の 1 回の呼び出しを指し、/knowledge-lookup の正本が語ごとの RECORD の形を書いている"
else
  bad "K47g: curate.md の重複照合の手順、または knowledge-lookup の SKILL.md に --each の記載が無い（読めない回も赤）"
fi

# ── K48: GraphQL 403 時の REST API フォールバック（PR 除外・複数ページ・上限打ち切り・--github-input 案内）──
ROOT_K48="${TMP}/root-k48"
mkdir -p "${ROOT_K48}/docs/08-knowledge"
cat >"${ROOT_K48}/docs/08-knowledge/OBSERVATIONS.md" <<'MD'
# 振り返り観測台帳

## エントリ一覧

<a id="obs-480"></a>

### OBS-480: REST open issue

| Kind | problem | Count | 3 |
| First | 2026-11-01 | Last | 2026-11-20 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#101 |

restfallbackneedle open issue

---

<a id="obs-481"></a>

### OBS-481: REST open PR (pull_request key must be excluded)

| Kind | problem | Count | 3 |
| First | 2026-11-01 | Last | 2026-11-20 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#102 |

restfallbackneedle pr excluded

---

<a id="obs-482"></a>

### OBS-482: REST page 2 open issue

| Kind | problem | Count | 3 |
| First | 2026-11-01 | Last | 2026-11-20 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#103 |

restfallbackneedle page2 open issue

---

<a id="obs-483"></a>

### OBS-483: REST closed issue

| Kind | problem | Count | 3 |
| First | 2026-11-01 | Last | 2026-11-20 |
| Status | promoted | Issue | feel-flow/ff-dev-toolkit#104 |

restfallbackneedle closed issue
MD

STUB_BIN_K48="${TMP}/stub-bin-k48"
mkdir -p "${STUB_BIN_K48}"
K48_LOG="${TMP}/k48-gh.log"
cat >"${STUB_BIN_K48}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${K48_GH_LOG:?}"
if [ "${1:-}" = "api" ]; then
  if [ "${K48_REST_FAIL:-0}" = "1" ]; then
    echo "gh: HTTP 500: rest unavailable" >&2
    exit 1
  fi
  shift 1
  ep=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --hostname) shift 2; continue ;;
      -*) shift; continue ;;
      *) [ -n "$ep" ] || ep="$1"; shift ;;
    esac
  done
  if [ "${K48_REST_OVER_LIMIT:-0}" = "1" ]; then
    # 1 ページあたり 100 件の通常 Issue を返し続けて 1000 件上限へ到達させる
    p="${ep##*&page=}"
    p="${p%%&*}"
    jq -nc --argjson base "$(( (p - 1) * 100 + 1 ))" '[range(0; 100) | {number: ($base + .)}]'
    exit 0
  fi
  case "$ep" in
    *"&page=1")
      # 101 は通常 Issue、102 は PR（pull_request キー付き → 除外必須）、残り 98 件も PR として計 100 件にする
      jq -nc '[{number: 101}, {number: 102, pull_request: {url: "https://api.github.com/repos/feel-flow/ff-dev-toolkit/pulls/102"}}] + [range(0; 98) | {number: (500 + .), pull_request: {url: "https://api.github.com/repos/feel-flow/ff-dev-toolkit/pulls/500"}}]'
      exit 0
      ;;
    *"&page=2")
      jq -nc '[{number: 103}]'
      exit 0
      ;;
    *)
      echo '[]'
      exit 0
      ;;
  esac
fi
if [ "${K48_MODE:-gql403}" = "gql403" ]; then
  echo "HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...)" >&2
  exit 1
elif [ "${K48_MODE}" = "gql_ok" ]; then
  printf '101\n103\n'
  exit 0
else
  echo "error connecting to api.github.com" >&2
  exit 1
fi
STUB
chmod +x "${STUB_BIN_K48}/gh"

: >"${K48_LOG}"
set +e
K48_GQL_OUT="$(K48_GH_LOG="${K48_LOG}" K48_MODE=gql_ok PATH="${STUB_BIN_K48}:${PATH}" "${LOOKUP[@]}" --root "${ROOT_K48}" --promoted-open 2>"${TMP}/k48-gql.err")"; k48_gql_rc=$?
: >"${K48_LOG}"
K48_REST_OUT="$(K48_GH_LOG="${K48_LOG}" K48_MODE=gql403 PATH="${STUB_BIN_K48}:${PATH}" "${LOOKUP[@]}" --root "${ROOT_K48}" --promoted-open 2>"${TMP}/k48-rest.err")"; k48_rest_rc=$?
K48_SEARCH_OUT="$(K48_GH_LOG="${K48_LOG}" K48_MODE=gql403 PATH="${STUB_BIN_K48}:${PATH}" "${LOOKUP[@]}" --root "${ROOT_K48}" restfallbackneedle 2>"${TMP}/k48-search.err")"; k48_search_rc=$?
set -e
if [[ "${k48_gql_rc}" -eq 0 && "${k48_rest_rc}" -eq 0 && "${k48_search_rc}" -eq 0 \
   && "${K48_REST_OUT}" == "${K48_GQL_OUT}" \
   && "${K48_REST_OUT}" == *'OBS-480'* && "${K48_REST_OUT}" == *'OBS-482'* \
   && "${K48_REST_OUT}" != *'OBS-481'* && "${K48_REST_OUT}" != *'OBS-483'* \
   && "${K48_SEARCH_OUT}" == *'feel-flow/ff-dev-toolkit#101(open)'* \
   && "${K48_SEARCH_OUT}" == *'feel-flow/ff-dev-toolkit#102(closed)'* \
   && "${K48_SEARCH_OUT}" == *'feel-flow/ff-dev-toolkit#103(open)'* \
   && "${K48_SEARCH_OUT}" == *'feel-flow/ff-dev-toolkit#104(closed)'* ]] \
   && grep -q 'repos/feel-flow/ff-dev-toolkit/issues?state=open&per_page=100&page=1' "${K48_LOG}" \
   && grep -q 'repos/feel-flow/ff-dev-toolkit/issues?state=open&per_page=100&page=2' "${K48_LOG}"; then
  ok "K48: GraphQL 403 時に REST API へフォールバックし、PR を除外・複数ページを結合して GraphQL と同一の open/closed 判定を返す"
else
  bad "K48: GraphQL 403 の REST フォールバックが期待と違う rc=${k48_gql_rc}/${k48_rest_rc}/${k48_search_rc} out=[${K48_REST_OUT}] search=[${K48_SEARCH_OUT}] err=[$(cat "${TMP}/k48-rest.err")]"
fi

set +e
K48_LIMIT_OUT="$(K48_GH_LOG="${K48_LOG}" K48_MODE=gql403 K48_REST_OVER_LIMIT=1 PATH="${STUB_BIN_K48}:${PATH}" "${LOOKUP[@]}" --root "${ROOT_K48}" --promoted-open 2>"${TMP}/k48-limit.err")"; k48_limit_rc=$?
set -e
if [[ "${k48_limit_rc}" -eq 0 && "${K48_LIMIT_OUT}" == *'未確認'* ]] \
   && grep -q '上限 1000 件に達しました' "${TMP}/k48-limit.err"; then
  ok "K48b: REST 経路でも open Issue が上限 1000 件に達したら fail-closed で 未確認 にする"
else
  bad "K48b: REST 上限打ち切りの fail-closed が違う rc=${k48_limit_rc} out=[${K48_LIMIT_OUT}] err=[$(cat "${TMP}/k48-limit.err")]"
fi

set +e
K48_FAIL_OUT="$(K48_GH_LOG="${K48_LOG}" K48_MODE=gql403 K48_REST_FAIL=1 PATH="${STUB_BIN_K48}:${PATH}" "${LOOKUP[@]}" --root "${ROOT_K48}" --promoted-open 2>"${TMP}/k48-fail.err")"; k48_fail_rc=$?
set -e
if [[ "${k48_fail_rc}" -eq 0 && "${K48_FAIL_OUT}" == *'未確認'* ]] \
   && grep -qF -- '--github-input' "${TMP}/k48-fail.err" \
   && grep -qF '"operation":"lookup.open-set"' "${TMP}/k48-fail.err"; then
  ok "K48c: REST も失敗時は --github-input と lookup.open-set の最小 index JSON 手順を stderr へ添えて 未確認 にする"
else
  bad "K48c: REST 失敗時の --github-input 案内が不足 rc=${k48_fail_rc} err=[$(cat "${TMP}/k48-fail.err")]"
fi

: >"${K48_LOG}"
set +e
K48_OTHER_OUT="$(K48_GH_LOG="${K48_LOG}" K48_MODE=other_err PATH="${STUB_BIN_K48}:${PATH}" "${LOOKUP[@]}" --root "${ROOT_K48}" --promoted-open 2>"${TMP}/k48-other.err")"; k48_other_rc=$?
set -e
if [[ "${k48_other_rc}" -eq 0 && "${K48_OTHER_OUT}" == *'未確認'* ]] \
   && ! grep -q '^api ' "${K48_LOG}"; then
  ok "K48d: 非回帰: 通常の gh 通信失敗（非 GraphQL 403）では REST API へフォールバックしない"
else
  bad "K48d: 通常エラーで不要に REST API を呼んでいる rc=${k48_other_rc}"
fi

echo ""
# Default metadata cannot grant an external read. Synthetic inputs only.
. "$SCRIPT_DIR/privacy.sh"

echo ""
win_checks_finished=0
win_runs=0
. "$SCRIPT_DIR/windows-acl.sh"
if [[ "$win_checks_finished" -ne 1 || "$win_runs" -lt 9 ]]; then
  bad 'Windows ACL: cases が空・欠落、または成功終端へ到達していない'
fi

echo ""
guide_checks_finished=0
. "$SCRIPT_DIR/root-stop-guide.sh"
if [[ "$guide_checks_finished" -ne 1 ]]; then
  bad '停止時の案内（G1〜G12）: cases が空・欠落、または成功終端へ到達していない'
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "✓ knowledge-lookup verify: ${PASS} 件成功"
  finish 0
fi
echo "✗ knowledge-lookup verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
finish 1
