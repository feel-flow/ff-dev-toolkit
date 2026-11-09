#!/usr/bin/env bash
#
# sync-dev-toolkit SKILL の手順書契約の静的検査。中核は「記録する SSOT SHA = 同期した
# 内容」（Issue `#634`）で、同じ手順書へ後から入った運用規定 — 並行セッションの実測
# （OBS-014 / OBS-138）、同期サイクルの in-flight 判定（OBS-044 / Issue `#1707`）、Release
# 反映遅れの吸収（OBS-104 / Issue `#1723`）— も同じ針型で固定する。
#
# 守っている事故: 手順 4 の commit メッセージ SHA をブランチ ref
# （`git rev-parse --short develop`）から採ると、同期実行後に並行セッションの
# マージで develop が進んだ場合に「同期していない SHA を反映済み」と記録する。
# drift 検知（check-dev-toolkit-sync-drift.sh / check-release-required.sh）は
# この SHA を同期基点に使うため、取り残しが DRIFT_COUNT=0 のまま隠れる
# （fail-open。PR #622 のマージ後同期で実測 — detached HEAD 7c805a6 で同期中に
# 並行マージで develop ref が 87da5c8 へ進み、commit メッセージだけが 87a5... 系の
# 未同期 SHA になった）。
#
# 同期元 SHA の受け渡しはシェル変数ではなくファイル（Issue #895）。同期スクリプトが
# 「実際に展開した内容の SHA」を target の git ディレクトリ配下 `ff-sync-src-sha` へ
# 書き、手順 4 がそれを読む。手順 3 と手順 4 が別プロセスでも値が生存するので、
# 「別シェルになったら手順 3 からやり直す」（＝直前の成功が残した差分に当たって
# 必ず失敗する）という詰みが消える。不変条件（記録 SHA == 同期内容）は維持する。
#
# 検査するのは次の 4 層:
#   1. 出現（手順書）: 記録の読み取り・if 連結の HEAD 突合・読んだ SHA からの採取・
#      記録不在時の中断・detached 退避・HEAD からの再導出禁止・fetch 失敗時の中断
#   2. 順序（手順書）: 同期実行 → 記録の読み取り → 突合 → commit の行番号が単調増加
#      （読み取りを同期の前へ動かす退行・突合を commit の後ろへ動かす退行の検出）
#   3. 禁止: ブランチ ref から SHA を採るコマンド置換（develop / origin/develop /
#      refs/heads/develop）が復活していない。手順 3 でシェル変数へ HEAD を控える
#      旧方式が復活していない。commit 行そのものに `develop` を含む SHA 式が無い
#   4. 出現・順序（同期スクリプト）: 同期する SHA を展開の前に固定し、記録は
#      ミラー書き込みの前に消してミラー成功の後に書く
# 順序は行番号の単調性のみで、同一フェンス内であること・実行時の競合までは
# 主張しない（実行時の防波堤は手順 4 の if 連結突合）。
#
# 「記録 SHA ≠ 同期内容」の実ミスマッチは静的検査では観測できないので、実 Git
# fixture の runtime（src-sha-runtime.sh）が記録の実挙動と手順 4 ブロックの実行を
# 受け持つ。静的検査は文面の固定、runtime は挙動の固定という分担。
#
# skip の鍵は検査対象そのものではなく**リポジトリの同一性**（sync スクリプトの
# 存在。sync-forbidden-patterns と同じ判定軸）: 公開 checkout（スクリプト不在）は
# ○ skip、SSOT なのに SKILL が無い場合は red（fail-closed — 改名・移設で唯一の
# ゲートが黙って skip 化するのを防ぐ）。FF_SYNC_SHA_SKILL で検査対象を差し替え
# られる（変異実測用）が、明示指定が不在の場合は skip ではなく fail。
#
# needle を追加・変更したら、対象行だけを削除・移動する変異を手で当てて red に
# なることを確認する（docs-gates と同じ規則）。手順書の針型検査は read-only。
# 同期元 SHA の受け渡しと footer-only 判定器だけは、一時 Git リポジトリで実挙動も
# 固定する。bash 3.2 互換。
#
# 変異検出（新設の (6) 群・15 変異すべて赤転、SURVIVED 0 件。2026-09-18 実測）:
# 変異検出: 手順 0a の「準備 PR のゲート実行中は open PR が無くマージも止まる」を削除すると (6) が赤。
# 変異検出: 手順 0a の in-flight 判定の内訳 2 材料（直近 sync commit / footer 追従 PR）の行を削除すると (6) が赤。
# 変異検出: 手順 0a の「偽陽性で毎回止まることはない」の行を削除すると (6) が赤。
# 変異検出: 手順 0a の適用範囲（痕跡が残る前は検出できない）の行を削除すると (6) が赤。
# 変異検出: 手順 0a の「材料が取れなければ値を出さず中断」の行を削除すると (6) が赤。
# 変異検出: 手順 0a の「レビュー走行（25 分規模）の開始前にも行う」を削除すると (6) が赤。
# 変異検出: 手順 0a の IN_FLIGHT=no を含む 3 行のいずれかを削除すると出現数が 3 から外れて (6) が赤。
# 変異検出: 手順 7 の「作成直後の一覧を判定に使わない」を削除すると (6) が赤。
# 変異検出: 手順 7 の「手順 6 の一覧を再利用しない」を削除すると (6) が赤。
# 変異検出: 手順 7 の bash から版違いで再取得を抜ける分岐行を削除すると (6) が赤。
# 変異検出: 手順 7 の上限到達（6 回 ≒ 30 秒）で中断する行を削除すると (6) が赤。
# 変異検出: 手順 7 の過去取りこぼしを待たずに中断する行を削除すると (6) が赤。
# 変異検出: 手順 7 の「既存の回は再取得ループへ入らない」を削除すると (6) が赤。
# 変異検出: 手順 7 の片側空で判定不能として抜ける分岐行を削除すると (6) が赤。
# 変異検出: 手順 7 の「UNVERIFIED=yes は取りこぼし無しへ倒さない」を削除すると (6) が赤。
#
# 手順 0b / 5 / 8 の本体はリリーススクリプト（scripts/release-dev-toolkit.sh。ADR-063）へ移したので、
# 実行面の針（(7)）はスクリプトに当て、SKILL には判断の根拠（散文）の針だけを残す。スクリプトの
# 振る舞い（段の順序・dry-run が書き込まない・再実行で続きから・止まるべき状態・粒度判定・同期提案
# hook の in-flight 抑止）は release-runtime.sh が一時 Git リポジトリで固定する。
# 変異検出（(7) と release-runtime。2026-09-23 実測）:
# 変異検出: スクリプトの OS 別プロファイル照合（許容表に無い部分 skip で止める行）を削除すると (7) と release-runtime が赤。
# 変異検出: gate 段の「run-all が失敗した」の stop() から第 3 引数（run-all が印字した停止文の 3 行）を外すと、release-runtime の必須 suite の skip のケース（次の一手が 1 行）が赤（2026-11-08 macOS / Bash 3.2.57 実測。218/1）。
# 変異検出: release_stop_block で停止文の lib をサブシェルの外（本体のシェル）でも読ませると、先頭で exit する lib の写しのケースが rc 0 で赤（2026-11-08 macOS / Bash 3.2.57 実測。217/1。Issue `#2712`）。
# 変異検出: スクリプトの main で stage_gate と stage_sync の行を入れ替えると (7) の順序が赤。
# 変異検出: スクリプトの limited_gate 呼び出し行を削除すると (7) が赤。
# 変異検出: スクリプトの dry-run 分岐（prepare 段の DRY_RUN 判定）を外すと release-runtime（dry-run は書き込まない）が赤。
# 変異検出: スクリプトのゲート緑記録の照合（state_get GATE_OK）を外すと release-runtime（再実行でゲートを回し直さない）が赤。
# 変異検出: hook の in-flight 判定ブロックを削除すると release-runtime（進行中は再確認を出さない）が赤。
# 変異検出（2 巡目のレビュー対応。2026-09-24 実測）:
# 変異検出: preflight の未 push sync commit の push を外すと release-runtime（公開 push の失敗から回復しない）が赤。
# 変異検出: sync 段の GATE_OK 要求を外すと release-runtime（--only sync が gate を素通り）が赤。
# 変異検出: report 段の footer 非 green で止める行を外すと release-runtime が赤。
# 変異検出: 版幅を「修正があれば patch」へ戻すと release-runtime（混在分類が minor にならない）が赤。
# 変異検出（1.0.0 の宣言 --major と 1.0.0 以降の版幅。ADR-088。2026-11-10 macOS / Bash 3.2.57 実測。release-runtime の pass/fail で、
# 無変異は 251/0）: 版幅の規則から「major 1 以上の破壊的変更 → major」を外すと release-runtime（v1.0.1 → v2.0.0）が赤（243/9）。
# major 0 の「破壊的変更」も major にすると同（major 0 は従来どおり minor）が赤（239/12）。宣言を版の基点の major によらず効かせると
# 同（準備済み・タグ前の 1.0.0 へ断片が後着した回の --major が v1.0.1）が赤（239/13）。後着断片の照合から 1.0.0 の宣言の読み取りを
# 外すと同（宣言で準備した 1.0.0 への後着断片の判別）が赤（238/14）。公開側の最新タグの major が 1 以上の --major を準備の前に止める
# 照合を外すと同が赤（249/2）。照合を公開側のタグではなく SSOT の版で行う形へ戻すと同（準備の後・タグ前の --major 付きの再実行が
# 続く）が赤（244/7）。準備の要らない回の --major の停止を stage_check の「不要」の直前から外すと同が赤（250/1）、本流の
# NEED_PREPARE=0 の分岐から外すと同（0.x の次の版を準備してタグの前に止めた状態への --major の本実行）が赤（250/2）。模擬（dry-run）の
# 版幅が --major を読まないと同が赤（250/1）。本番の準備が読まないと同が赤（234/18）。再開の案内に足す --major（major_resume_arg）を
# 常に空にすると同が赤（248/3）。承認待ちの次の一手だけ・prepare 段の次の一手だけ・release Issue の「再開:」行だけから外すと、
# どれも同が赤（250/1）。タグの実在で宣言を使い終えた印（major_tag_seen）を付けない・照合が --major を止めた回に印を付けないと、
# どちらも同（「再開:」行の関数単位の検査）が赤（250/1）。tag 段の push の後の印の呼び出しを外しても release-runtime は緑（251/0。
# タグの後で再開の案内を出す停止を fixture で作れない）なので、(7) の箇所数の針が赤にする。
# 変異検出: preflight の書きかけ巻き戻しを外すと release-runtime（bump 後 / footer 更新後の失敗から再開できない）が赤。
# 変異検出: in-flight 印の取得（writer）を外すと release-runtime（ゲート走行中に印が見えない）が赤。
# 変異検出: hook の stale 時の粒度判定ガードを外すと release-runtime（stale な drift で日次待ちに倒れる）が赤。
# 変異検出: tag 段の remote main 一致要求を外しても release-runtime は緑（preflight が先に push するため多重防御）。(7) の針が赤。
# 変異検出（3 巡目。破壊的な自動復旧をやめ fail-closed へ。2026-09-24 実測）:
# 変異検出: preflight で acquire_in_flight を復旧の後ろへ動かすと (7) の順序針と release-runtime（live 印 + dirty tree で作業ツリーに触る）が赤。
# 変異検出: 書きかけの一致判定（writing_match）を常に一致へ倒すと release-runtime（利用者の編集・公開側の未追跡を消す）が赤。
# 変異検出: try_reclaim が判定後に token を読み直す形へ戻すと (7) の lib 針が赤（判定と読み直しの割り込みは runtime で決定的に作れないので静的に固定する。release-runtime は判定後の取り直しで rename 回収が失敗することを固定する）。
# 変異検出: gate 段の週次 CI 再評価を記録の照合より後ろへ戻すと release-runtime（healthy でなくなった再実行を全件で回さない）が赤。
# （2026-11-09 に gate 段から週次 CI 再評価を撤去した。ADR-086。下の 2026-11-09 の行を参照）
# 変異検出: 完走サマリーの要求を外すと release-runtime（空出力・会計行欠落を緑と読む）が赤。
# 変異検出: ローカルタグの commit 照合を外すと release-runtime（古いローカルタグを公開する）が赤。
# 変異検出: tag 段の require_gate_ok を外すと release-runtime（--only tag が gate を素通り）が赤。
# 変異検出（リリース初回実運用の摩擦。2026-09-24 実測）:
# 変異検出: dry-run の prepare で模擬した再判定が OK でないときの停止を外すと release-runtime（dry-run が ATTRIBUTION_DRIFT を予測しない）が赤。
# 変異検出: 停止文の次の一手から --resume-with-edits を外す（旧文面へ戻す）と release-runtime（停止文が再開の設計と噛み合わない）が赤。
# 変異検出: --resume-with-edits の採用で prepare の書き込み先以外の変更を止める行を外すと release-runtime（判別できない状態を採用する）が赤。
# 変異検出: 採用の印（ADOPTED=1）を立てないと release-runtime（直した内容から再開できない）が赤。
# 変異検出: 採用した記録（adopted=1）を自動巻き戻しの対象から外す照合を消すと release-runtime（付けない再実行が直した内容を戻す）が赤。
# 変異検出: dry-run の同期差分を公開側 clone の作業ツリーとの rsync 比較へ戻すと release-runtime（origin/main 基準・内容差分だけ）が赤。
#
# 変異検出（ff-media-toolkit の既定 skip。Issue `#1904`。2026-09-25 実測）:
# 変異検出: OS 別の許可欄の取り違え、表の空・欠落・不正行は skip-line-contract が赤にする。
# 空振り検出: footer 分類器の成功状態照合を削除すると footer-reuse-runtime の empty / identical ケースが赤（2026-09-26 実測 exit 1）。内容証明なしの exit 0 は採用しない。
# 空振り検出: 呼び出し 4 ファイルから ff_skip_msys_case を消すと呼び出し針が赤（0 件を緑へ倒さない。2026-10-19 実測、4 ファイルとも赤。不在ファイルも赤）。
# 空振り検出: ヘルパの字下げした skip 行を消すと形の針が赤（2026-10-19 実測。理由文が残っていても字下げ行が無いと赤）。
# 空振り検出: FF_SYNC_SHA_SKILL へ存在しないパスを与えると (対象解決) が赤になる。明示指定の不在を skip へ倒さないため、実測は exit 1（○ skip ではない）。
# 空振り検出: FF_SYNC_SHA_RELEASE_SCRIPT へ存在しないパスを与えると (対象解決) が赤になる（実測 exit 1）。lib を残して本体だけを空ファイルへ差し替えると、本体に当たる (7) の針 56 件と release-runtime が赤（2026-10-25 実測 exit 1）。lib に当たる針（release 段の 3 件）は本体を空にしても緑のままなので、release-publish-functions.sh を空にした実測で別に押さえる（同日、その 3 件・require_gate_ok の箇所数・release-runtime が赤、exit 1）。
# 空振り検出: 差し替えた本体の隣に lib/ が無いと (対象解決) が赤（2026-10-25 実測 exit 1）。分割先 lib（release-prepare-functions.sh）へ `clean -fd` を足すと、本体 + lib を見る禁止パターンの針が赤（同日実測 exit 1）— 移した処理が文字列の針の対象外へ落ちない。
# 空振り検出: 検査対象を空ファイルへ差し替えると (1〜3 / 5 / 6 の全針) が赤になる。0 件一致を「不足なし」へ倒さないことの実測。
#
# 変異検出（(8) 承認文への dry-run 実測値の転記。OBS-018 / Issue `#1917`。2026-09-27 実測、変異 10 件と空振り 1 件すべて赤転 / SURVIVED 0 件）:
# 変異検出: 「承認の求め方」段落の bullet を 1 本消す（not-needed / 途中停止）・行末へ反対の但し書きを足す・段落を HTML コメントで包むと、全文一致が赤（exit 1）。部分一致の針では 4 件とも緑だった（レビューで実測）。
# 変異検出: 段落を手順書の末尾（Common Mistakes の後）へ移すと位置の針（手順 R と 0b の見出しの間）が赤。
# 変異検出: finish() が dry-run のとき RELEASE_VERSION= を出さないようにすると release-runtime（次の版 0.32.0 を出す）が赤。
# 変異検出: post-merge hook の提案文から dry-run 先行の文を削除すると (8)（出現と承認要求行の同居）と release-runtime の両方が赤。SessionStart hook では (8) が赤。
# 変異検出: post-merge hook の ${PROPOSAL_TAIL} の使用箇所 1 つを別の文へ差し替えると使用箇所数（2）の針が赤。
# 変異検出: SessionStart hook へ dry-run 先行を欠く言い換えの承認要求（「承認された場合のみ」）の notify を足すと承認要求行の同居の針が赤。
# 空振り検出: SessionStart hook を不在にすると (8) が赤（exit 1。不在を 0 件一致の緑・skip へ倒さない）。段落が見つからない（見出し行が消えた）ときは空文字の比較へ倒さず「段落が無い」で赤にする。
#
# 変異検出（changelog-fragment-runtime。同期提案 hook の changelog 断片の欠落通知。Issue `#2150` / OBS-099。2026-10-16 実測、変異 12 件と空振り 4 件すべて赤転 / SURVIVED 0 件。初回は CHANGELOG 本体の例外と is_bot の 2 件が SURVIVED で、ケースを足して赤転を確認）:
# 変異検出: 断片判定の関数を no-op にすると欠落・bot 案内・名指しの 6 ケースが赤。最後の同期提案の文から断片の通知を外すと同じ 6 ケースが赤。
# 変異検出: 変更ファイル取得・公開対象一覧・PR 照会の各失敗の通知から判定不能の文を外すと、それぞれの判定不能ケースが赤。
# 変異検出: changelog.d の下位ディレクトリを断片に数える・CHANGELOG 本体の例外を外す・断片の要る範囲へ同期スクリプトを含める・メタ allowlist を無視する、のいずれも対応ケースが赤。
# 変異検出: bot の判定から login の形（[bot] / app/）を外す、または author.is_bot を無視すると bot 案内のケースが赤。hook の allowlist へ 1 件足すと正本との一致が赤。
# 空振り検出: hook を不在・空ファイルにすると changelog-fragment-runtime が赤（exit 1。skip へ倒さない）。allowlist の配列名を変える・正本を空にすると「allowlist を読めない」で赤（0 件を一致へ倒さない）。
#
# 変異検出（release-runtime の gate 走行中の develop の前進と中間版の Release。Issue `#2202`。2026-10-19 実測、判定と lib を写した検査用ツリーへ 1 件ずつ注入して変異 11 件すべて赤転 / SURVIVED 0 件）:
# 変異検出: advance_scope が公開対象に触れる前進を neutral へ倒すと、--advance-check の public / 両方のケースと gate の public 前進のケースが赤。リリース機構（scripts/）に触れる前進を neutral へ倒すと --advance-check の tooling 2 ケース（同期スクリプト・lib）と gate の tooling 前進のケースが、changelog.d だけの前進を neutral へ倒すと --advance-check の changelog ケースと gate の changelog 前進のケースが赤。
# 変異検出: stale_only_suites が「failed がすべて stale」の照合を省くと mixed のケースが、not run / 必須 skip の行の照合を省くと notrun のケースが赤。gate が鮮度の赤を再検査へ回さない（従来の即停止へ戻す）と neutral の前進のケースと止め方の文言を見る 3 ケース（public / tooling / changelog）ほか計 8 ケースが赤。
# 変異検出: 再検査の完走判定から passed=n の照合を外すと、名指しの suite が suite 単位で skip した再検査のケースが赤。recover_stale_gate へ検査した HEAD ではなく読み直した HEAD を渡す（旧挙動）と、走行中に同じ checkout で公開対象のコミットが push された moved のケースが赤（変異下では検査していないコミットごと released まで進む）。
# 変異検出: Release 本文から中間版の節を落とすと中間版の本文ケースと --summary ケースが、件名の件数を新版だけに戻すと件名ケースが、件名の（vX を含む）を --summary の既定値の内側へ戻すと --summary ケースが赤。中間版の無いリリースの本文・件名の全文一致は変更前のスクリプトでも緑（回帰の針）。
# 空振り検出: run-all の鮮度行の文言が変わった（stale_only_suites の照合を別の見出しへ差し替えた）回は鮮度と読まず、gate は再検査せずに「run-all が失敗した」で止まる（neutral の前進のケースほか 8 ケースが赤 = 止める側。2026-10-19 実測）。--advance-check は解決できない HEAD で ADVANCE=unknown・exit 2（判定不能を neutral へ倒さない）。
#
# run-all-required: no — 同期スクリプトを持たない公開 checkout での skip は正当な適用外（SSOT 専用の検査）

# 変異検出: in-flight の固定時計18ケースは実runtimeのblock/helperを抜き出した単体で19 pass / 0 fail、実runtime全体は115 pass / 0 fail（2026-10-22）。
# 変異検出: 負年齢の下限を0/-299/-301へ各単独変更すると4/2/2件、有効期限の上限削除/>=化で各2件、PID生存照合を除くと2件、異hostを同host扱いすると4件が赤（単体、全7変異 exit 1。構文検査は通過）。
# 空振り検出: 同じ実runtime block/helperの単体で、case helperと実libの不在・読取不能・同名空・関数名消失の8入力、およびcase集合0は各0 pass / 1 fail・exit 1（2026-10-22）。正常18件に届かない入力を緑へ倒さない。
# 空振り検出: release の環境lib不在/空、Python不在/版不明/能力不足/空成功、型検査依存不在/npm不在/赤/空成功、loader不備/空成功はprepare・suite前に停止する（2026-10-22実測）。
# 変異検出: 環境呼出/Python/media/loaderの各probe除去、loader skip無条件許可、loader context照合除去に加え、実probeのPython本体/manifest引数/loader import、npmのNode PATH、loader条件診断の破壊を既存ownerの同じfixtureへ適用し全て赤転（適用11/11、SURVIVED 0）。実Python/Nodeを含む正常対照35pass/0fail、mutation-harness rc=0（2026-10-22）。
# 2026-10-30: 社内専用の ff-agent-press を別の非公開リポジトリへ移したので、release の loader（loader-diff）の probe・部分 skip の条件付き許可・gate 記録の loader context 照合を撤去した。上 2 行の loader 部分は撤去前の実測で、残る環境 probe（Python / media）の停止は同じ fixture が引き続き赤にする。

# 変異検出: run_orch の FF_RUN_ALL_FULL 分離だけを外すと、外側は未設定でも neutral ケースの明示 FULL=1 が再検査へ漏れ、recheck 1 で赤（2026-10-23 実測、release-runtime 149 pass / 1 fail、exit 1）。健全性悪化時の全件実行は正常のまま。
# 空振り検出: FF_SYNC_SHA_RELEASE_SCRIPT の明示不在と同名空ファイルはどちらも exit 1（2026-10-23 実測）。空ファイルの全件実行コマンドは 0 件一致となり赤で、検査対象の欠落を skip・緑へ倒さない。
# 変異検出: gateのfast環境分離・部分出力拒否・鮮度分類器の部分拒否・再検査の環境分離・NESTED保持を各々除去すると実runtimeの新規ケースが赤（5/5）。正常対照は緑、外側FULL未設定/1のsuiteは各157pass（2026-10-23）。
# 2026-11-09（ADR-086）: gate 段は健全性判定を呼ばず、毎回全件（FF_RUN_ALL_FULL=1）で回す形へ変えた。上の「gate 段の週次 CI 再評価」「fast 環境分離」の 2 変異は対象の行ごと撤去し、
# 「run_orch の FF_RUN_ALL_FULL 分離」の変異は gate も再検査も全件になったので recheck の値（今は 1 が正常）では観測できなくなった（CHANGED / FAST の分離は引き続き gate-mode の各ケースが見る）。
# 上の実測件数（149 / 157 pass）は撤去前の数で、撤去後の件数は下の ADR-086 の変異検出行に書く。
# 変異検出（ADR-086。2026-11-09 macOS 実測。リリーススクリプトだけを写した検査用ツリーへ 1 件ずつ注入し、FF_SYNC_SHA_RELEASE_SCRIPT で当てた。変異と空振りの実測は PATH 先頭の Bash 5.3、正常対照は Bash 5.3 と /bin/bash 3.2.57 の両方で全 142 件 pass・release-runtime 232 pass / 0 fail。変異 3 件すべて赤転 / SURVIVED 0 件）:
# 変異検出: gate 段へ weekly_health の呼び出しを戻すと、呼び出し行の件数（2 行）と report 段の中にある順序の針が赤、release-runtime は 217 pass / 15 fail（gate-mode の全件起動 12 ケースと dry-run 2 ケース、本実行の呼び出し回数のケースが、健全性判定を呼んだことで赤）。
# 変異検出: 同じ HEAD の再利用に高速モードの記録を受け入れる条件を戻すと、再利用条件の針と gate 段の中の順序の針 2 件が赤、release-runtime は 231 pass / 1 fail（高速モードの記録を再利用しないケース）。
# 変異検出: gate 段の run-all 起動から FF_RUN_ALL_FULL=1 を外すと、全件実行コマンドの針が赤、release-runtime は 221 pass / 11 fail（健全性判定 healthy / failed の本実行 2 ケース、呼び出し元が全件を指定しない gate-mode 8 ケース、高速モードの記録を置き換えるケース。呼び出し元が FF_RUN_ALL_FULL=1 を渡す 4 ケースは外側の指定が届くので緑のまま）。
# 空振り検出: report 段の weekly_health の呼び出しを消すと、呼び出し行の件数（0 行）と順序の針（アンカー不在は fail-closed）が赤、release-runtime は 229 pass / 3 fail（同日実測、exit 1）。0 件一致を「gate 段は呼ばない」の緑へ倒さない。
# 変異検出（後着断片の再集約と承認した版の照合。Issue `#2462` / `#2482`。2026-11-04 実測、判定と lib を写した検査用ツリーへ 1 件ずつ注入して変異 4 件すべて赤転 / SURVIVED 0 件）:
# 変異検出: 後着断片の基点の版を準備前の版ではなく今の版にすると 35 件、--expect-version の無い本実行の再集約を止める行を外すと 3 件、prepare_finalize の承認版照合を外すと 2 件（承認と違う版の準備を push する）、resume_guard の呼び出しを外すと 3 件（Release の後で止まった再開が承認していない版のタグ・Release を作る）が赤。
# 変異検出（構成上の固定。独立レビューの指摘で足したケース）: RELEASE_OPEN を worktree ごとの記録へ戻すと別 worktree のケースが、
# preflight の承認待ち書きかけの採用拒否を外すと --resume-with-edits のケースが、準備が要らない回の照合（main の expect_version_guard）を
# 外すと 9.9.9 のケースが、dry-run の照合を外すと dry-run のケースが赤になる（各ケースはその 1 行だけが止める形で組んだ）。
# 変異検出: 修正前のスクリプト（develop の 20043194）へ新しいケースを当てると、後着断片の dry-run が prepare 段で「準備が途中で止まった疑い」で止まり、再開ケースは承認していない次の版のタグと Release を作って released になる（いずれも赤）。
# 2026-11-04（Issue `#2619`）: 後着断片は準備済みの版節へ畳まず、新しい版として準備する形へ変えた（準備済みの版はタグを打たない中間版として残る）。上の「基点の版を今の版にすると 35 件」は同じ版節へ再集約していた頃の実測で、今の bump の基点（stage_prepare の base）は準備済みの版（今の版）で、準備前の版（LATE_BASE）は版幅の読み直しにだけ使う。
# 変異検出（後着断片の新しい版としての準備と、昇格直後の共有 CHANGELOG の実物の判定。Issue `#2619`。2026-11-04 実測、判定と lib を写した検査用ツリーへ 1 件ずつ注入し、hook 無しの release-runtime の正常対照 165 pass / 0 fail に対して変異 5 件すべて赤転 / SURVIVED 0 件）:
# 変異検出: 修正前の release-prepare-functions.sh（同じ版節への再集約）へ戻すと 21 件が赤。準備済みの版を承認した --expect-version の本実行は、本番の v0.176.0 と同じく昇格直後の changelog-fragments（stub が呼ぶ実物の判定が direct-edit）で止まる。
# 変異検出: changelog-fragments の stub を常に緑へ戻すと、判定の記録（fragments-judgement.log）を照合する 3 件が赤。後着断片の基点を準備前の版（LATE_BASE）へ戻すと 37 件、--expect-version の無い本実行で後着断片を止める行を外すと 8 件が赤。判定 lib から release-prep の許容を外すと、最初の通常の準備が昇格直後の changelog-fragments で止まり、release-runtime が中断して赤（exit 1）。
# 変異検出（承認した dry-run の HEAD への本実行の結び付け。Issue `#2622`。2026-11-04 実測、判定と lib を写した検査用ツリーへ 1 件ずつ注入し、hook 無しの release-runtime の正常対照 182 pass / 0 fail に対して変異 13 件すべて赤転 / SURVIVED 0 件。前進を止め損ねた変異はその後のケースの起点がずれ、release-runtime が途中で中断して exit 1 になるものを含む）:
# 変異検出: main の approved_head_guard の呼び出しを外す、照合を preflight の fetch / pull より前へ移す（pull 前の HEAD と比べる）、公開対象に触れる前進を続ける側へ倒す — の 3 件は、承認後に別 clone から公開対象と同じ版幅の断片が入るケースが released まで進んで赤（版は承認した値のままなので --expect-version の照合を通る）。
# 変異検出: changelog.d だけの前進を続ける側へ倒すと同じ checkout の changelog ケースと --approved-head を渡した dry-run のケースが、分岐を続ける側へ倒すと分岐のケースが、解決できない承認 HEAD を続ける側へ倒すとそのケースが、neutral の前進でも止めると neutral のケースが赤。本実行の対での指定（--expect-version と --approved-head）を要求しないと片方だけのケースが released まで進んで赤。
# 変異検出: 自身の release コミットを件名だけで判定すると件名を名乗る他人の公開変更のケースが、自身の release コミットを除外しないと gate で止まった後の再実行の 2 ケースが、比較リンクの追従コミットを除外しないと footer の push で止まった後の再実行のケースが赤。dry-run の RELEASE_HEAD= を出さないと最初の dry-run のケースほかが、判定の途中で HEAD が動いても出すと HEAD が動いた dry-run のケースが赤。
# 変異検出（自身の release コミットの SHA の記録と、承認後のリリース機構だけの前進。Issue `#2622` のレビュー対応。2026-11-04 実測、作業ツリーを写した検査用ツリーへ 1 件ずつ注入し、hook ありの release-runtime の正常対照 191 pass / 0 fail に対して変異 2 件とも赤転）:
# 変異検出: own_release_commit の記録照合を外して件名と変えたファイルだけで判定すると、準備の件名を名乗り plugin.json の description だけを変える他人のコミットのケースが released まで進んで赤（以降のケースは起点がずれ、release-runtime が途中で中断して exit 1）。approved_head_guard で tooling を neutral と同じく続けると、リリース機構だけの前進のケースが released まで進んで赤（187 pass / 5 fail）。
# 空振り検出: gate-modeの新規case本体を空動作へ置換しても到達フラグが未設定でexit 1（実測）。環境記録や鮮度の正常会計に針が当たる肯定対照を持ち、空出力を成功根拠にしない。

# 空振り検出: 同期の展開前 tree 種別検査を除く対照は source/destination LICENSE symlink の dry/real を4件検出して rc=1、通常対照 rc=0（2026-10-28、有限の隔離 sentinel のみ）。
# 空振り検出: 非公開件名の公開 commit 転記を復元すると marker 検査だけが赤（158 pass / 1 fail、rc=1）、通常対照は159 pass / 0 fail、rc=0（2026-10-28、hook 省略の隔離 runtime）。
# 空振り検出: Darwin 専用 skip の条件付き許可（Issue `#2517`）を無条件にする・Darwin だけへ反転する・節ごと消す 3 変異は、いずれも実挙動 4 通りの照合だけが赤（169 pass / 1 fail、rc=1）、通常対照は 170 pass / 0 fail（2026-10-29 WSL 実測）。差し替えた本体の lib だけで同じ節を消すと実挙動の照合が赤、出し手の行を「○ skip: <fixture 名> — <理由文>」の語順へ変えると出し手の集合照合が赤（各 rc=1）。
# 変異検出: release-runtime.sh で、run-all の stub が作る side の clone の作者設定（fixture の helper での初期化）を外すと、release Issue のロックの commit-tree が止まり「固定リリースの公開・比較リンク・次の受付の分離」が赤。fixture の git の隔離を `GIT_CONFIG_GLOBAL=/dev/null` へ戻すと「作者情報を推測しない」の針が赤、環境変数の作者を外す行を消して GIT_AUTHOR_* / GIT_COMMITTER_* を与えると「作者情報を持たない repo の commit-tree は止まる」の針が赤（Issue `#2665`。いずれも --handoff-only の 16 件中 1 件。2026-11-06 WSL 実測。user.useConfigOnly が無いと、作者を推測できる環境では side の作者設定を外しても緑のまま — Git Bash で EMAIL を与えた実測で commit-tree が通った）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SYNC_SCRIPT="$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh"
DEFAULT_SKILL="$REPO_ROOT/.claude/skills/sync-dev-toolkit/SKILL.md"
# 同期手順からは ADR-039 で退役したが、changelog-fragments（cases/footer.sh）が
# footer-only PR の判定器として現役利用するため、スクリプトと挙動検査は残す
# （整理は epic #857 の棚卸し #873 で扱う）。
FULL_GATE_REUSE_SCRIPT="$REPO_ROOT/scripts/check-full-gate-reuse.sh"

if [[ -n "${FF_SYNC_SHA_SKILL:-}" ]]; then
  SKILL="$FF_SYNC_SHA_SKILL"
  echo "⚠ FF_SYNC_SHA_SKILL で検査対象を差し替えています: $SKILL" >&2
  if [[ ! -f "$SKILL" ]]; then
    echo "✗ FF_SYNC_SHA_SKILL に指定されたファイルがありません（明示指定の不在は skip ではなく失敗）: $SKILL" >&2
    exit 1
  fi
else
  SKILL="$DEFAULT_SKILL"
  if [[ ! -f "$SYNC_SCRIPT" ]]; then
    echo "○ skip: $SYNC_SCRIPT が無いためスキップ（SSOT 専用の検査。公開 checkout では対象外）"
    exit 0
  fi
  if [[ ! -f "$SKILL" ]]; then
    echo "✗ SSOT checkout（sync スクリプトあり）なのに SKILL がありません: $SKILL" >&2
    echo "  改名・移設した場合は本 suite のパスも更新すること（黙って skip 化させない）" >&2
    exit 1
  fi
fi

# リリーススクリプト（手順 0b / 5 / 8 の本体。ADR-063）の検査対象。FF_SYNC_SHA_RELEASE_SCRIPT で
# 差し替えられる（変異実測用）。SSOT なのに不在・明示指定の不在はいずれも失敗（skip へ倒さない）。
RELEASE_SCRIPT="${FF_SYNC_SHA_RELEASE_SCRIPT:-$REPO_ROOT/scripts/release-dev-toolkit.sh}"
if [[ -n "${FF_SYNC_SHA_RELEASE_SCRIPT:-}" ]]; then
  echo "⚠ FF_SYNC_SHA_RELEASE_SCRIPT でリリーススクリプトの検査対象を差し替えています: $RELEASE_SCRIPT" >&2
fi
if [[ ! -f "$RELEASE_SCRIPT" ]]; then
  echo "✗ 検査対象のリリーススクリプトがありません: $RELEASE_SCRIPT" >&2
  exit 1
fi
# 段の処理を分けた先の lib。文字列の針（release_contains / _exactly / _not_contains）は本体と
# これらを合わせた全体を見る — 移した処理が針の対象外になって禁止パターンが素通りしないように。行番号で
# 比べる順序の針（release_line_of / release_exact_line_of）は本体だけを見るので、そのアンカーは本体に残す。
# 下の名簿（針が当たる lib）の不在・空は skip ではなく失敗（差し替えた本体の隣にも lib/ を置く）。名簿に無い
# release-*-functions.sh も glob で加え、後から増えた lib が禁止パターンの針の対象外へ落ちないようにする。
RELEASE_SOURCES=("$RELEASE_SCRIPT")
for _release_lib in release-in-flight-functions.sh release-gate-advance-functions.sh release-environment-functions.sh \
  release-partial-write-functions.sh release-prepare-functions.sh release-publish-functions.sh; do
  _release_lib="$(dirname "$RELEASE_SCRIPT")/lib/$_release_lib"
  if [[ ! -s "$_release_lib" ]]; then
    echo "✗ リリーススクリプトの lib が無い・空: $_release_lib" >&2
    exit 1
  fi
  RELEASE_SOURCES+=("$_release_lib")
done
for _release_lib in "$(dirname "$RELEASE_SCRIPT")"/lib/release-*-functions.sh; do
  [[ -f "$_release_lib" ]] || continue
  case " ${RELEASE_SOURCES[*]} " in *" $_release_lib "*) ;; *) RELEASE_SOURCES+=("$_release_lib") ;; esac
done
POST_MERGE_HOOK="$REPO_ROOT/.claude/hooks/post-merge-dev-toolkit-sync.sh"
SESSION_START_HOOK="$REPO_ROOT/.claude/hooks/session-start-sync-drift.sh"

# 同期スクリプト側の検査対象。既定は上で解決した実体と同じで、FF_SYNC_SHA_SCRIPT で
# 差し替えられる（変異実測用）。SKILL 側と同じく、明示指定の不在は skip ではなく失敗。
SYNC_SCRIPT_UNDER_TEST="${FF_SYNC_SHA_SCRIPT:-$SYNC_SCRIPT}"
if [[ -n "${FF_SYNC_SHA_SCRIPT:-}" ]]; then
  echo "⚠ FF_SYNC_SHA_SCRIPT で同期スクリプトの検査対象を差し替えています: $SYNC_SCRIPT_UNDER_TEST" >&2
fi
if [[ ! -f "$SYNC_SCRIPT_UNDER_TEST" ]]; then
  echo "✗ 検査対象の同期スクリプトがありません: $SYNC_SCRIPT_UNDER_TEST" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "$SKILL" || rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "${label}（不足: ${needle}）" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}

# 出現「回数」まで固定する。同じ文字列が複数の分岐に現れる針は、片方が消えても
# もう片方に一致して緑のままになり、識別力を失う（Issue #830 レビュー）。
contains_exactly() {
  local needle="$1" want="$2" label="$3" got
  got="$(grep -cF -- "$needle" "$SKILL" || true)"
  if [[ "$got" == "$want" ]]; then
    ok "$label"
  else
    bad "${label}（期待 ${want} 箇所 / 実際 ${got} 箇所: ${needle}）"
  fi
}

not_contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "$SKILL" || rc=$?
  case "$rc" in
    0) bad "${label}（禁止パターンが存在: ${needle}）" ;;
    1) ok "$label" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}

# needle を含む最初の行番号を返す（無ければ空）。awk はファイルを直接読むので
# head 経由の SIGPIPE 反転が起きない。
line_of() {
  awk -v pat="$1" 'index($0, pat) { print NR; exit }' "$SKILL"
}

# 同期スクリプト側の針。SKILL 用の contains / line_of と同型で、対象だけが違う。
script_contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "$SYNC_SCRIPT_UNDER_TEST" || rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "${label}（不足: ${needle}）" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}

script_line_of() {
  awk -v pat="$1" 'index($0, pat) { print NR; exit }' "$SYNC_SCRIPT_UNDER_TEST"
}

# リリーススクリプト側の針。対象だけが違う同型の helper（文字列の針は本体 + lib の全体を見る）。
release_contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "${RELEASE_SOURCES[@]}" || rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "${label}（不足: ${needle}）" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}
release_contains_exactly() {
  local needle="$1" want="$2" label="$3" got
  got="$(cat "${RELEASE_SOURCES[@]}" | grep -cF -- "$needle" || true)"
  if [[ "$got" == "$want" ]]; then
    ok "$label"
  else
    bad "${label}（期待 ${want} 箇所 / 実際 ${got} 箇所: ${needle}）"
  fi
}
release_not_contains() {
  local needle="$1" label="$2" rc=0
  grep -qF -- "$needle" "${RELEASE_SOURCES[@]}" || rc=$?
  case "$rc" in
    0) bad "${label}（禁止パターンが存在: ${needle}）" ;;
    1) ok "$label" ;;
    *) bad "${label}（grep が失敗 rc=${rc}）" ;;
  esac
}
release_line_of() {
  awk -v pat="$1" 'index($0, pat) { print NR; exit }' "$RELEASE_SCRIPT"
}
# 行全体の完全一致（段の呼び出し行のように、部分一致だと定義や説明に吸われる針に使う）
release_exact_line_of() {
  awk -v pat="$1" '$0 == pat { print NR; exit }' "$RELEASE_SCRIPT"
}

# 行番号の単調性を 1 件の検査として報告する。アンカーが引けない場合は fail-closed。
assert_order() {
  local before="$1" after="$2" ok_msg="$3" bad_msg="$4"
  if [[ -z "$before" || -z "$after" ]]; then
    bad "順序検査のアンカーが欠落（before=${before:-<不在>} after=${after:-<不在>}）— 空振りは fail-closed: ${ok_msg}"
  elif [[ "$before" -lt "$after" ]]; then
    ok "${ok_msg}（${before} < ${after}）"
  else
    bad "${bad_msg}（${before} >= ${after}）"
  fi
}

echo "== sync-dev-toolkit SHA 記録契約 =="

# ── 1. 出現 ──────────────────────────────────────────────────────────────────
contains '`ff-sync-src-sha` へ書き出す' \
  "手順 3 が、同期スクリプトの記録先（公開側 clone の .git 配下）を明示している"
contains 'SYNC_SRC_SHA=$(cat "$(git -C "$PUBLIC" rev-parse --absolute-git-dir)/ff-sync-src-sha" 2>/dev/null || true)' \
  "手順 4 が同期元 SHA を記録ファイルから読む（シェル変数を跨がせない）"
contains '記録の不在を「一致」と扱わない' \
  "記録が無いときに中断することが明記されている（不在を一致にしない）"
contains 'if [ -n "${SYNC_SRC_SHA:-}" ] && [ "$(git rev-parse HEAD)" = "$SYNC_SRC_SHA" ]; then' \
  "手順 4 が HEAD の不動と SYNC_SRC_SHA の存在を if 連結で突合する（set -e 非依存）"
contains 'git rev-parse --short "$SYNC_SRC_SHA"' \
  "手順 4 の commit メッセージが控えた SHA から採られる"
contains 'git checkout --detach origin/develop' \
  "他 worktree が develop を保持する場合の退避手順がある"
contains 'ref から SHA を採ると「同期していない SHA を反映済み」と記録し' \
  "退避時に HEAD 基準の記録が必須になる理由が明記されている"
contains 'HEAD から再導出してはならない' \
  "記録が無いときに HEAD から再導出することが禁じられている"
contains 'stale な origin/develop で続行しない' \
  "退避経路の fetch 失敗時に中断することが明記されている"

# 定期実行点ゲート（要求内容は ADR-039 が ADR-034 決定 2 の「全件ゲート充足」を置換し、
# ADR-086 がその前提（非公開側の週次 CI の定期実行）を外して「HEAD への全件 run-all が緑」へ
# 置き換えた。位置は ADR-042 が 1 点目を「タグ / Release の作成前」へ縮小）。対を持つ
# selftest（REQUIRED_SUITES 掲載を含む）は全件実行でしか走らないので、gate 段は週次 CI の
# 状態を見ずに毎回 FF_RUN_ALL_FULL=1 で回す。手順から全件の指定が消えると、selftest を
# 回さないまま（または HEAD を一度も検査しないまま）不可逆な公開同期へ接続する。手順から
# 消えたら赤くする（機械強制ではなく手順の固定が、静的検査の上限。NG 文言と exit の対までは
# 単行 grep で固定できない — 「NG を出して続行する」変異は静的検査の上限の外。健全性判定を
# 呼ばないこと・モードが健全性に左右されないことは release-runtime / release-gate-mode-runtime
# が実行で測る）。
# 針はコマンド形の行全体に固定する — 裸のスクリプト名だと、散文の言及が 1 行増えた
# 時点で contains も line_of の順序アンカーも散文側に吸われて空振りする（レビュー W2）。
# 実行面（コード行）はリリーススクリプトの gate 段が持つ（ADR-063）。SKILL は段を名指しで呼ぶ。
contains 'scripts/release-dev-toolkit.sh --only gate' \
  "手順 0b がリリーススクリプトの gate 段を名指しで呼ぶ（本体の所在）"
contains '要求は「HEAD への全件 run-all が緑」' \
  "手順 0b の要求が毎回の全件 run-all である（週次 CI の成功実績に依存しない。ADR-086）"
release_contains_exactly '  gate_mode=full' 1 \
  "gate 段のモードは全件に固定されている（週次 CI の状態から導出しない。ADR-086）"
release_not_contains 'gate_mode=fast' \
  "gate 段に高速モードへ倒す分岐が無い"
release_contains_exactly 'FF_RUN_ALL_FULL=1 bash "$RUN_ALL" >"$gate_out" 2>&1 || gate_rc=$?' 1 \
  "gate 段の全件実行コマンドが 1 箇所にある"
release_contains_exactly 'bash "$RUN_ALL" >"$gate_out" 2>&1 || gate_rc=$?' 1 \
  "gate 段が run-all を起動する行は全件実行の 1 行だけ（別のモードの起動行が無い）"
release_contains 'run-all が失敗した — 同期しない' \
  "run-all が非 0 のとき同期しないことが明記されている"
contains '非 0 なら**同期しない**' \
  "ゲートが非 0 のとき同期しないことが明記されている"
# 公開側の週次 CI の健全性判定は report 段だけが情報として呼ぶ（止めない。ADR-086）。
# 健全性判定の呼び出し行（字下げ 2 の行全体）は report 段の 1 行だけで、gate 段には無い。
release_contains 'capture bash "$HEALTH_SCRIPT"' \
  "report 段が公開側の週次 CI の状態確認を踏む（gh 経路）"
release_contains 'case "$CURRENT_STAGE" in report) ;; *) unavailable' \
  "file 入力の健全性判定は report 段の呼び出しだけを受け付ける"
_health_calls="$(awk '$0 == "  weekly_health" { n++ } END { print n + 0 }' "${RELEASE_SOURCES[@]}")"
if [[ "$_health_calls" == 1 ]]; then
  ok "健全性判定の呼び出し行は 1 行だけ（gate 段は呼ばない）"
else
  bad "健全性判定の呼び出し行が 1 行ではない（${_health_calls} 行。gate 段が健全性判定を呼ぶ退行か、report 段の呼び出しが消えた）"
fi
assert_order "$(release_exact_line_of 'stage_report() {')" "$(release_exact_line_of '  weekly_health')" \
  "健全性判定の呼び出しは report 段の中にある" \
  "健全性判定の呼び出しが report 段より前（gate 段など）にある"
# healthy でない回と CRON_NOTE= を報告する規約。ここが消えると、判定を据え置いた分の
# 可視性が消費側で失われ、実害（20 行に埋もれて 2 週間気づかれない）が戻る。
contains 'が出ていれば、同期は止めずに公開側の週次 CI の異常としてユーザーへ報告する' \
  "report 段の healthy 以外と CRON_NOTE= を、同期を止めずにユーザーへ報告することが明記されている"
contains '比較リンクの反映には全件ゲートと公開配置検査の再実行が要らない' \
  "固定版の比較リンク反映は限定ゲートだけで進む"
release_contains '検査した tree と HEAD の tree が一致しない' \
  "dirty なまま得た green を「HEAD を検査済み」と扱わない"

# 手順 0b の部分 skip 許容条件。散文が `checks-skipped` 非 0 を「未実行の検査がある」と
# 書くだけで**続行するのか中断するのか**を規定せず、判定コード片は GATE_RC しか見て
# いなかった。その状態では散文は実行面で空文になり、実測 3 回とも内訳を個別 suite の
# 再実行で調べ直したうえで「既存実績と同じ内訳」と判断して続行していた（判断の再演）。
# かつ全 suite が対象の 0b では adapter-sandbox-contract の grok enum 非公表が恒久的に
# 残るため `checks-skipped: total=0` は達成不能で、手順 8（対象 2 suite。total=0 が現に
# 成立する）の基準をそのまま持ち込むことはできない。許容表・表で判定する分岐・環境 skip
# を許さない旨の 3 つを固定する（どれが消えても「非 0 を内訳なしで通す」へ戻る）。
# 判定コード片は `bash -e <<'EOF' … EOF` で渡す規約（git-workflow.md）に従って set -e 下で
# 走る。`cmd` の直後に `GATE_RC=$?` と書くと run-all が非 0 で終わった時点でシェルごと落ち、
# 下の中断理由と次の一手が表示されない（緑と赤で出力の質が変わる）。捕捉形を固定する。
# 針はコード行そのものを指す。`|| GATE_RC=$?` だけだと、同じ綴りを含む直上の説明コメントで
# 満たされてしまい、コード側を元の `GATE_RC=$?` へ戻しても緑のまま通る（実測）。
release_contains 'bash "$RUN_ALL" >"$gate_out" 2>&1 || gate_rc=$?' \
  "gate 段が run-all の終了コードを落ちない形（|| gate_rc=\$?）で捕捉する"
release_contains 'release_skip_check "$gate_out"' \
  "gate 段が通常経路で OS 別プロファイルを照合する"
release_contains 'release_skip_check "$recheck_out"' \
  "鮮度だけの再検査でも同じ OS 別プロファイルを照合する"
release_contains 'OS 別プロファイルで部分 skip を許可できない' \
  "分類できない部分 skip がある場合は同期前に停止する"
contains 'bash plugins/ff-dev-toolkit/tests/lib/release-skip-profile.sh --table' \
  "手順 0b は実行時判定と同じ表を表示する"
for _pair in \
  "render-smoke|FF_MEDIA_RENDER=1 が未設定のため実レンダリングを行いません" \
  "typecheck|node_modules が無いため型検査を行いません"; do
  _src="$REPO_ROOT/plugins/ff-media-toolkit/tests/${_pair%%|*}/verify.sh"
  if grep -qF -- "${_pair#*|}" "$_src"; then
    ok "ff-media-toolkit/tests/${_pair%%|*} が表の理由文を出す"
  else
    bad "ff-media-toolkit/tests/${_pair%%|*} の実出力に表の理由文が無い"
  fi
done
contains '**環境 skip は許容しない**' \
  "環境 skip を許可しないことが明記されている"
contains '`total=0` を要求しない理由（手順 8 との非対称は意図）' \
  "手順 8 は skip 0 件の要求を維持する"
release_contains 'ff_release_temp_preflight && ff_release_python_preflight && ff_release_media_preflight' \
  "環境確認は一時領域を先に作り、作れない回は Python と ff-media の確認へ進まない"
_temp_pin='一時領域を作れない、または結果がディレクトリでない回は prepare と suite の前に止まる'
contains "$_temp_pin" \
  "手順書が、一時領域を作れない回は prepare と suite の前に止まると書いている"
if grep -qF -- "$_temp_pin" "$REPO_ROOT/docs/04-quality/TESTING.md"; then
  ok "TESTING.md が、一時領域を作れない回は prepare と suite の前に止まると書いている"
else
  bad "TESTING.md に一時領域の停止条件が無い"
fi
_msys_reason='MSYS では成立しない検査のため未実行'
_msys_helper="$REPO_ROOT/plugins/ff-dev-toolkit/tests/lib/msys-case.sh"
if [[ -f "$_msys_helper" ]] && grep -qF -- "$_msys_reason" "$_msys_helper" && grep -qF -- '  ○ skip:' "$_msys_helper"; then
  ok "MSYS 部分 skip の理由文と字下げがヘルパにある"
else
  bad "MSYS 部分 skip のヘルパが無い、理由文が違う、または字下げした skip 行が無い"
fi
for _msys_site in \
  plugins/ff-dev-toolkit/tests/sync-forbidden-patterns/verify.sh \
  plugins/ff-dev-toolkit/tests/host-route-parity/verify.sh \
  plugins/ff-dev-toolkit/tests/sync-sha-contract/footer-reuse-runtime.sh \
  plugins/ff-dev-toolkit/tests/claude-hooks-path/verify.sh \
  plugins/ff-dev-toolkit/tests/knowledge-lookup/verify.sh
do
  if [[ -f "$REPO_ROOT/$_msys_site" ]] && grep -qF -- 'ff_skip_msys_case' "$REPO_ROOT/$_msys_site"; then
    ok "ff_skip_msys_case の呼び出しがある: ${_msys_site}"
  else
    bad "ff_skip_msys_case の呼び出しが無い（0 件を緑へ倒さない）: ${_msys_site}"
  fi
done
# 旧方式（ADR-034 決定 2 + Issue #830 の green 再利用機構）の復活禁止。針は散文を
# 誤検出しない最小限の広さにする — 現 SKILL の散文言及は backtick 内の `FULL_GATE_SHA`
# （代入の `=` を含まない）だけで、check-full-gate-reuse への言及は無い（実測）。
not_contains 'FULL_GATE_SHA=' \
  "全件 green SHA をシェル変数へ控える旧方式が復活していない"
not_contains 'check-full-gate-reuse' \
  "廃止した green 再利用判定の呼び出しが復活していない"

# 手順 8 の限定ゲート（2 suite / 4 観点。旧 changelog-links + changelog-attribution は
# changelog-public-tags へ、版の一致と公開参照の境界は changelog-contract へ統合済み）は、footer の release
# コミットを develop へ直 push する**前**に footer 段が回す（ADR-063 で footer PR を廃止）。2 suite の
# 呼び出しが 1 箇所にあり、suite 全体の skip も部分 skip も成功と読まないことを固定する。
release_contains_exactly 'for t in "$PUBLIC_TAGS_VERIFY" "$CONTRACT_VERIFY"; do' 1 \
  "限定ゲートの 2 suite（changelog-public-tags / changelog-contract）が footer 段の 1 箇所にある"
release_contains "'○ skip' \"\$CAP_FILE\"; then" \
  "限定ゲートは skip / 部分 skip / 非 0 を成功と読まない（checks-skipped: total=0 と同じ基準）"
contains '**commit の前に限定ゲートを通す**' \
  "手順 8 が限定ゲートを footer の commit 前に置くと明記している"
contains 'update-dev-toolkit-changelog-footer.sh --public-checkout' \
  "手順 8 の footer writer が実行可能 helper へ一本化されている"
release_contains 'bash "$FOOTER_SCRIPT" --public-checkout "$PUBLIC"' \
  "footer 段が footer helper を呼ぶ（footer を手で書き換えない）"
# 準備と footer 追従は定型 PR を作らず release: の単独コミットを直 push する（ADR-063）。
release_contains 'RELEASE_PREFIX="release: "' \
  "リリーススクリプトの直 push は release: prefix の単独コミットに限る"
release_not_contains 'gh pr create' \
  "リリーススクリプトは PR を作らない"
release_not_contains 'push -f' \
  "リリーススクリプトは force push しない"
release_not_contains 'push --force' \
  "リリーススクリプトは --force で push しない"
contains '）は作らず、`release: CHANGELOG 比較リンクを vX.Y.Z へ追従` の単独コミット' \
  "手順 8 が footer PR を作らないと明記している"

# ── 2. 順序（行番号の単調増加） ──────────────────────────────────────────────
L_READ="$(line_of 'SYNC_SRC_SHA=$(cat "$(git -C "$PUBLIC" rev-parse --absolute-git-dir)/ff-sync-src-sha"')"
L_SYNC="$(awk '$0 == "scripts/sync-dev-toolkit-to-public.sh --target \"$PUBLIC\"" { print NR; exit }' "$SKILL")"
L_GUARD="$(line_of 'if [ -n "${SYNC_SRC_SHA:-}" ] && [ "$(git rev-parse HEAD)" = "$SYNC_SRC_SHA" ]; then')"
L_COMMIT="$(line_of 'git -C "$PUBLIC" commit -m "sync: ')"
# SKILL 側のゲートのアンカーは手順 0b の段呼び出し（行頭一致。手順 R の散文中の言及に吸われない）
L_GATE="$(awk 'index($0, "scripts/release-dev-toolkit.sh --only gate") == 1 { print NR; exit }' "$SKILL")"

# 記録の読み取りが同期実行より前にあると、前回の同期が残した記録を掴む（今回の
# 同期内容とは無関係な SHA を「反映済み」と記録する退行）。
assert_order "${L_SYNC}" "${L_READ}" \
  "順序: 記録の読み取りが同期実行より後" \
  "順序: 記録の読み取りが同期実行より前にある — 前回の記録を掴む退行"
assert_order "${L_READ}" "${L_GUARD}" \
  "順序: HEAD 突合が記録の読み取りより後" \
  "順序: HEAD 突合が記録の読み取りより前にある — 読む前に判定する退行"
assert_order "${L_GUARD}" "${L_COMMIT}" \
  "順序: HEAD 突合が commit より前" \
  "順序: HEAD 突合が commit より後ろにある — 突合前に記録が確定する退行"
# 定期実行点ゲートは同期実行より前になければ意味がない（同期後に回しても不可逆操作は
# 済んでいる）。手動手順の文書順（手順 0b の段呼び出し < 手順 3 の同期）と、スクリプトの
# 実行順（下の (7)）の両方で固定する。
assert_order "${L_GATE}" "${L_SYNC}" \
  "順序: 定期実行点ゲート（手順 0b）が同期実行（手順 3）より前" \
  "順序: 定期実行点ゲートが同期実行より後ろにある — 不可逆操作の後で検査する退行"
# リリース準備（手順 R）の判定は定期実行点ゲート（手順 0b）の**前**に置く（ADR-042）。
# R の判定材料は手順 0a が揃えた作業ツリーと公開側 clone の履歴 / タグで、**ゲート結果には
# 依存しない**。後ろに置くと RELEASE_REQUIRED の回だけ「捨てられる 1 回目」が生まれる
# （OBS-015 で 5 回実測）。ADR-042 は定期実行点「リリース準備の前」の範囲を bump / 版節
# 昇格から外し、タグ / Release の前へ縮小した。
# このアサートが守るのは「R が 0b より前」だけで、後ろへ戻る退行は削った 1 回を復活させる。
# 縮小後の 1 点目そのもの（タグ = 手順 5 / Release = 手順 6 が 0b より後）に**アンカーは
# 無い** — 上の L_GATE < L_SYNC が固定するのは同期実行（手順 3）までで、タグ / Release が
# 0b より後にあることは現状では文書順序の帰結にすぎない。この穴は本アサートの反転が作った
# ものではなく（反転前の L_GATE < L_RELEASE も固定していない）、埋めるかどうかは epic #857
# の「検査の新設・拡張は原則行わない」との衝突判断を要する。この判断は Issue #1102 で
# **見送りを決定済み**（棚卸しで closed / not planned）— #857 の再開基準は確率ではなく
# 実発生を見る設計で、タグ節 / Release 節がゲートより前へ移動した退行は一度も起きて
# いないため。再開基準は「タグ節または Release 節が手順 0b より前へ移動する変更が
# 実際に発生したとき」で、そのとき本アンカーを足す。
# 針は行全体のコマンド形に固定し、出現 1 回を件数でも縛る — line_of は先頭一致なので、
# 反転後は「前方の散文へアンカーが吸われる」空振りが fail-open 側（R が前に見える）へ倒れる
# 向きになった（反転前は fail-closed 側だった）。
contains_exactly 'scripts/check-release-required.sh --public "$PUBLIC" --fetch' 1 \
  "手順 R の判定コマンドが 1 箇所だけにある（順序アンカーの一意性。反転で空振りが fail-open 側へ倒れるため）"
L_RELEASE="$(line_of 'scripts/check-release-required.sh --public "$PUBLIC" --fetch')"
assert_order "${L_RELEASE}" "${L_GATE}" \
  "順序: リリース準備の判定（手順 R）が定期実行点ゲートより前（ADR-042）" \
  "順序: リリース準備の判定がゲートより後ろにある — リリースが必要な回に全件ゲートを 2 回払う退行"
# 反転前は「R がゲートより後」で、ゲートが手順 0（0a の直後）にあったため「R が develop
# 最新化より後」が**推移的に**固定されていた。反転でその辺が誰にも固定されなくなるので、
# 明示アンカーで戻す（ADR-042 決定 2 が「前提は 0a が単独で満たす」を load-bearing にした）。
# 針は完全一致にする — `git pull --ff-only origin develop` は手順 R のコメント内にも散文で
# 出るため、部分一致だと 0a のコマンド行が消えた回にアンカーが R 自身の中へ吸われて無言で
# 非識別になる（L_SYNC と同じ形）。
L_DEVELOP_SYNC="$(awk '$0 == "git pull --ff-only origin develop" { print NR; exit }' "$SKILL")"
assert_order "${L_DEVELOP_SYNC}" "${L_RELEASE}" \
  "順序: リリース準備の判定（手順 R）が develop 最新化（手順 0a）より後" \
  "順序: 手順 R が develop 最新化より前にある — 判定材料（HEAD = develop 最新・clean）の前提が崩れる退行"

# ── 3. 禁止（ブランチ ref からの採取の復活） ────────────────────────────────
# コマンド置換の形に限定する（散文の説明や Common Mistakes 表への記載を誤検出
# しないため。復活が実害になるのはコマンド例の中だけ）。
not_contains '$(git rev-parse --short develop)' \
  "ブランチ ref（develop）から SHA を採るコマンド置換が無い"
not_contains '$(git rev-parse --short origin/develop)' \
  "ブランチ ref（origin/develop）から SHA を採るコマンド置換が無い"
not_contains 'refs/heads/develop' \
  "refs/heads/develop 経由の採取が無い"
# 旧方式（手順 3 でシェル変数へ HEAD を控える）の復活。値がシェルを跨いで生存
# しないため、手順が別プロセスへ割れた瞬間に「記録あり」の経路ごと消える。
not_contains 'SYNC_SRC_SHA=$(git rev-parse HEAD)' \
  "同期元 SHA をシェル変数へ HEAD から控える旧方式が復活していない"

# ── 4. 同期スクリプト側（記録の生成契約） ────────────────────────────────────
# 記録するのは「実際に展開した内容の SHA」。HEAD は同期中にも動きうるので、
# 展開を HEAD で行って記録を後から rev-parse すると両者がずれる（#634 の再発）。
script_contains 'SRC_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"' \
  "同期スクリプトが同期対象の SHA を一度だけ固定する"
script_contains 'rm -f "$SRC_SHA_RECORD"' \
  "ミラー書き込みの前に古い記録を消す（中断した同期の記録を残さない）"
script_contains 'printf '"'"'%s\n'"'"' "$SRC_SHA" > "$SRC_SHA_RECORD"' \
  "ミラー成功後に同期元 SHA を記録する"

L_SRC_CAPTURE="$(script_line_of 'SRC_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"')"
L_ARCHIVE="$(script_line_of 'git -C "$ROOT" archive "$SRC_SHA"')"
L_RM="$(script_line_of 'rm -f "$SRC_SHA_RECORD"')"
L_RSYNC="$(script_line_of 'run_rsync "${RSYNC_FLAGS[@]}" --itemize-changes')"
# アンカーに `\n` を含めないこと — awk の -v 代入はエスケープを解釈するため、
# `'%s\n'` を含む needle は実改行へ化けて必ず空振りする（この suite で実測）。
L_WRITE="$(script_line_of '"$SRC_SHA" > "$SRC_SHA_RECORD"')"

assert_order "${L_SRC_CAPTURE}" "${L_ARCHIVE}" \
  "順序: 同期スクリプトが SHA を固定してから staging を展開する" \
  "順序: staging の展開が SHA の固定より前にある — 記録 SHA と同期内容がずれる退行"
assert_order "${L_RM}" "${L_RSYNC}" \
  "順序: 古い記録の削除がミラー書き込みより前" \
  "順序: 古い記録の削除がミラー書き込みより後ろにある — 中断時に古い記録が残る退行"
assert_order "${L_RSYNC}" "${L_WRITE}" \
  "順序: 記録の書き込みがミラー成功より後" \
  "順序: 記録の書き込みがミラー成功より前にある — 失敗した同期を「同期済み」にする退行"

# runtime の終了コードと stderr から「環境都合の未検証」と「退行」を決める規則。本番経路と
# 下の検査が同じ関数を通るようにする — rsync のあるホストでは本番経路が skip 分岐を通らない
# ため、関数を分けると「rc=3 を通常の失敗へ落とす」退行を誰も検出できない。
# stdout: 部分 skip の理由（空なら skip ではない）/ 戻り値: 0=想定内, 1=退行として扱う
classify_src_sha_result() { # $1: runtime の rc / $2: stderr のファイル
  local rc="$1" err="$2"
  [[ "$rc" -eq 0 ]] && return 0
  # rc だけで skip に振り分けない: runtime は set -euo pipefail + trap で内側の rc を
  # そのまま返すので、将来別の検査が 3 で落ちたときに緑の skip へ化ける。
  if [[ "$rc" -eq 3 ]] && grep -q 'rsync がありません' "$err"; then
    printf '%s\n' 'rsync が無いため同期の実挙動（記録と手順 4 の実行）を検証していない — apt 等で rsync を導入して再実行する'
    return 0
  fi
  return 1
}

_src_sha_rc=0
_src_sha_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-err.XXXXXX")"
bash "$SCRIPT_DIR/src-sha-runtime.sh" "$SYNC_SCRIPT_UNDER_TEST" "$SKILL" 2>"$_src_sha_err" || _src_sha_rc=$?
_src_sha_skip=""
_src_sha_cls=0
_src_sha_skip="$(classify_src_sha_result "$_src_sha_rc" "$_src_sha_err")" || _src_sha_cls=$?
if [[ "$_src_sha_cls" -ne 0 ]]; then
  bad "同期元 SHA の受け渡しの実行契約が壊れている (rc=${_src_sha_rc})"
  sed 's/^/    | /' "$_src_sha_err" >&2
elif [[ -n "$_src_sha_skip" ]]; then
  # インデント付きの ○ skip は run-all が checks-skipped へ別勘定する印。suite 全体の
  # skip とは別で、何を測っていないかが summary に名前で残る（Issue #1427）。
  echo "  ○ skip: rsync の同期検査: ${_src_sha_skip}"
else
  ok "同期元 SHA の記録と手順 4 の実行が、別プロセス・HEAD 移動・記録不在を区別する"
fi
rm -f "$_src_sha_err"

# 振り分けの規則そのものを固定する。rsync のあるホストでは本番経路が skip 分岐を通らない
# ので、ここが無いと「rc=3 を通常の失敗へ落とす」「理由を問わず skip にする」のどちらの
# 退行も検出されないまま緑になる。
_cls_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-cls.XXXXXX")"
printf 'rsync がありません（同期の実挙動を検証できない）\n' >"$_cls_err"
_cls_out=""; _cls_rc=0
_cls_out="$(classify_src_sha_result 3 "$_cls_err")" || _cls_rc=$?
if [[ "$_cls_rc" -eq 0 && "$_cls_out" == *"rsync が無いため"* ]]; then
  ok "振り分け: 理由が rsync 不在の rc=3 は部分 skip の理由を返す（呼び出し元が ○ skip を出せる）"
else
  bad "振り分け: rsync 不在の rc=3 が部分 skip にならない (rc=${_cls_rc} out=${_cls_out})"
fi
printf '記録された SHA が同期内容と一致しない（退行）\n' >"$_cls_err"
_cls_rc=0
classify_src_sha_result 3 "$_cls_err" >/dev/null || _cls_rc=$?
if [[ "$_cls_rc" -ne 0 ]]; then
  ok "振り分け: 理由の一致しない rc=3 は退行として扱う（環境都合の skip に化けない）"
else
  bad "振り分け: 理由を問わず rc=3 を skip にしている（退行が緑で通る）"
fi
_cls_rc=0
_cls_out="$(classify_src_sha_result 0 "$_cls_err")" || _cls_rc=$?
if [[ "$_cls_rc" -eq 0 && -z "$_cls_out" ]]; then
  ok "振り分け: rc=0 は skip でも失敗でもない"
else
  bad "振り分け: 成功が skip / 失敗に化けている (rc=${_cls_rc} out=${_cls_out})"
fi
rm -f "$_cls_err"

# 環境都合（rsync 不在）と退行を runtime が終了コードで区別し続けること。ここが 1 に
# 戻ると、rsync の無いホストで「実装が壊れている」と読める赤が出る。不在は PATH を
# 絞らずシーム（SYNC_SHA_RSYNC_BIN）で作る — PATH を絞る形は fixture が要る実体の
# 取りこぼしが rsync 不在と区別できない別の失敗に化け、検査が不安定になる。
_no_rsync_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-norsync.XXXXXX")"
_no_rsync_rc=0
SYNC_SHA_RSYNC_BIN=/nonexistent/ff-rsync-absent \
  bash "$SCRIPT_DIR/src-sha-runtime.sh" "$SYNC_SCRIPT_UNDER_TEST" "$SKILL" \
  >/dev/null 2>"$_no_rsync_err" || _no_rsync_rc=$?
if [[ "$_no_rsync_rc" -eq 3 ]] && grep -q 'rsync がありません' "$_no_rsync_err"; then
  ok "rsync 不在を専用の終了コード 3 と理由の名指しで返す（退行の非 0 と区別でき、部分 skip へ振り分けられる）"
else
  bad "rsync 不在が終了コード 3 + 理由で返らない (rc=${_no_rsync_rc}) — 環境都合と退行が同じ赤に潰れる"
  sed 's/^/    | /' "$_no_rsync_err" >&2
fi
rm -f "$_no_rsync_err"

if bash "$SCRIPT_DIR/reuse-runtime.sh" "$FULL_GATE_REUSE_SCRIPT"; then
  ok "footer-only 判定器（changelog-fragments が使用）が同一 tree / footer-only / fail-closed を区別する"
else
  bad "footer-only 判定器の実行契約が壊れている"
fi

# commit 行そのものに develop を含む SHA 式が無いこと（変数化などの迂回の検出）。
if [[ -n "${L_COMMIT}" ]]; then
  COMMIT_LINE="$(awk -v n="${L_COMMIT}" 'NR == n { print; exit }' "$SKILL")"
  case "$COMMIT_LINE" in
    *develop*) bad "commit 行に develop を含む式が混入している: $COMMIT_LINE" ;;
    *'"$SYNC_SRC_SHA"'*) ok "commit 行の SHA 式が \$SYNC_SRC_SHA のみ" ;;
    *) bad "commit 行に \$SYNC_SRC_SHA が見当たらない: $COMMIT_LINE" ;;
  esac
fi

# ── 5. 並行セッションの実測（ソースリポジトリの観測台帳 OBS-014 の昇格 / OBS-138）─
# 手順 0a の静止確認は `gh pr list` の open PR とマージ間隔しか見ず、同じ作業ツリーで
# 動く別セッション（untracked ファイル・別ブランチへの checkout）を検出しない
# （OBS-014）。検出の判定基準（期待値との照合）とフェーズ境界での再測・破棄・中断が
# 骨抜きにされていないかも併せて検出する。手順 4 の統合ブランチ直 push は `-q` を
# 付けると `Everything up-to-date` の無音成功を見逃す（OBS-138）。いずれも文言の
# 消失を検出する針。
contains 'git worktree list --porcelain' \
  "手順 0a が並行セッション実測に git worktree list --porcelain を使う"
contains '期待値は `git branch --show-current` が `develop`、`git worktree list --porcelain` の本ツリー行の `branch` フィールドが develop ブランチを指している、`git status --porcelain --untracked-files=all` が空の 3 点で、いずれかが異なれば検出とみなす' \
  "手順 0a が検出の判定基準（期待値との照合）を明記している"
contains '手順 0b / R / 1〜6 の各手順に入る直前にも `git branch --show-current` と `git worktree list` を再測し、ブランチ・worktree・status のいずれかが着手時と変わっていたら、そのフェーズの結果を破棄して中断し' \
  "手順 0a がフェーズ境界での再測と破棄・中断の対応を明記している"
contains '統合ブランチ（公開側 `main`）への直 push は `-q` を付けず、出力の `-> main` を実測してから次へ進む' \
  "手順 4 の統合ブランチ直 push が -q 不使用と -> main の実測を明記している"
contains 'push 出力に `-> main` が無く `Everything up-to-date` のみのときは、`git rev-parse HEAD` と `git ls-remote origin main` の SHA を照合し' \
  "手順 4 の Everything up-to-date 分岐が SHA 照合による不一致判定を明記している"

# ── 6. 同期サイクルの in-flight 判定（OBS-044 / `#1707`）と Release 反映遅れ（OBS-104 / `#1723`）─
# 手順 0a の静止確認は open PR と直近マージ間隔しか見ないため、別セッションが準備 PR の
# ゲートを回している「もっとも衝突しやすい時間帯」を静止と読む。手順 7 は逆に、手順 6 が
# 作成した直後の Release 一覧を判定に使うと GitHub API の反映遅れで偽の取りこぼしを出す。
# どちらも「手順はあるが前提にしている状態が書かれていない」型で、文言の消失を検出する針。
echo "-- 手順 0a: 同期サイクル in-flight の判定 --"
contains_exactly '準備 PR のゲート実行中は open PR が無くマージも止まる' 1 \
  "手順 0a が open PR / マージ間隔だけでは検出できない時間帯を明記している"
contains_exactly '(a) 公開側の直近 sync commit が `WINDOW_MIN` 以内、(b) footer 追従 PR（`chore/#163-*`）が直近 sync commit より後にマージされている（収束ラウンドが未実施）' 1 \
  "手順 0a の in-flight 判定が直近 sync commit と footer 追従 PR の 2 材料を持つ"
contains_exactly '誰も同期していない状態では直近 sync が `WINDOW_MIN` より古く footer も sync より前になるので、**偽陽性で毎回止まることはない**' 1 \
  "手順 0a の in-flight 判定が偽陽性で毎回止まらないことを明記している"
contains_exactly '別セッションが初回の準備 PR ゲートを回している段階（sync commit も footer PR もまだ無い）は材料が存在せず検出できない' 1 \
  "手順 0a が in-flight 判定の適用範囲（痕跡が残る前は検出できない）を明記している"
contains_exactly '判定材料が 1 つでも取れなければ `NG` を出して中断する。**値を出さないことが契約の実装**' 1 \
  "手順 0a が材料欠落時に値を出さず中断すると明記している（fail-open の閉塞）"
contains_exactly 'IN_FLIGHT=no' 3 \
  "手順 0a の in-flight 判定が機械可読な IN_FLIGHT 値で出る（初期化・出力・判定の 3 箇所）"
contains_exactly 'レビュー走行（クロスモデルレビューは 25 分規模）を始める前にも行う' 1 \
  "手順 0a の静止確認がレビュー走行の開始前にも適用されると明記している"

echo "-- 手順 7: Release 反映遅れの吸収 --"
contains_exactly '**作成直後の一覧を判定に使わない**' 1 \
  "手順 7 が作成直後の Release 一覧を判定に使わないと明記している"
contains_exactly '`$RELS` は手順 6 で取得済みの一覧を**再利用しない**' 1 \
  "手順 7 が手順 6 の一覧を再利用しないと明記している"
contains_exactly 'if [ "$MISSING" != "v$VER" ]; then break; fi' 1 \
  "手順 7 が今回の版以外の混入で再取得ループを抜ける分岐を持つ"
contains_exactly '`$MISSING` が `v$VER` だけのまま上限（6 回 ≒ 30 秒）に達した = **中断してユーザーに報告する**' 1 \
  "手順 7 が再取得の上限到達で中断すると明記している"
contains_exactly '`$MISSING` に今回の版以外が含まれる = 過去の取りこぼし。再取得の収束を待たずに**中断してユーザーに報告する**' 1 \
  "手順 7 が過去の取りこぼしを待たずに中断すると明記している"
contains_exactly '手順 6 が「既存（何もしない）」だった回は `v$VER` が既に一覧へ載っているため `$MISSING` に現れず、再取得ループには入らない' 1 \
  "手順 7 が収束 sync（既存）の回に再取得ループへ入らないと明記している"
contains_exactly 'if [ -z "$TAGS" ] || [ -z "$RELS" ]; then UNVERIFIED=yes; break; fi' 1 \
  "手順 7 が片側空のまま再取得を繰り返さず判定不能として抜ける"
contains_exactly '`UNVERIFIED=yes` で抜けた = 判定不能。取りこぼしの有無を主張せず**中断してユーザーに報告する**' 1 \
  "手順 7 が判定不能を取りこぼし無しへ倒さないと明記している"

# ── 8. 承認文は dry-run の実測値を転記して作る（OBS-018 / Issue `#1917`）───────
# 公開同期の承認文へ段数・版番号を推定で書くと、適用段の実測と食い違って承認後に範囲の
# 作り直しや訂正が出る（OBS-018 の 2026-09-02 / 09-04）。機構（--dry-run の PLAN: /
# RELEASE_VERSION=）は在るので、手順 R の「承認の求め方」段落を丸ごと固定し、承認を促す
# hook 2 本の提案文が dry-run 先行を求めることを固定する。hook は要旨（dry-run 先行・転記・
# 推定禁止）だけを持ち、止まったときの扱いなど詳細は手順 R を指す。
# 段落は部分一致ではなく全文一致で比べる — 同じ行へ反対の但し書きを足す・行を HTML コメントで
# 包む・bullet を 1 本消すといった骨抜きは部分一致の針をすり抜ける（レビューで実測）。
# 本節は (7) より前に置く（(7) の末尾で release-runtime を走らせるので、静的な針を先に出す）。
echo "-- (8) 承認文への dry-run 実測値の転記 --"
APPROVAL_BLOCK_EXPECTED="$(cat <<'APPROVAL_BLOCK_EOF'
**承認の求め方（承認文は dry-run の実測値を転記して作る。OBS-018 / Issue `#1917`）**: ユーザーへ承認を求める**前に** `scripts/release-dev-toolkit.sh --dry-run`（`--only` を付けない全段の dry-run）を stdout と stderr の両方を受けて実行し、承認文にはその出力の `PLAN:` 行（実行予定コマンド。外向き操作を含む）と `RELEASE_VERSION=`（次の版番号）・`RELEASE_HEAD=`（dry-run が判定した HEAD の SHA）を**そのまま転記する**。段数・版番号を自分で推定して書かない — 承認時点で確定できる値を未確定のまま書くと、適用段の実測と食い違って承認後に範囲の作り直しや訂正が出る。

- 承認を求めてよいのは、dry-run が `RELEASE_RESULT=dry-run`（exit 0）で終わり、`RELEASE_VERSION=` と `RELEASE_HEAD=` の行が出ていて、`dry-run はここで止める` の NOTE 行が無い回（全段を完走した回）だけ
- preflight が書きかけの段を見つけた回は `RELEASE_RESULT=dry-run`（exit 0）でも途中で止まっており `RELEASE_VERSION=` と `RELEASE_HEAD=` が出ない。この回は承認を求めず、巻き戻しの `PLAN:` 行を報告し、巻き戻し後に dry-run を回し直して完走してから承認を求める
- dry-run が `RELEASE_RESULT=stopped`（exit 1）または `RELEASE_RESULT=unavailable`（exit 2）で終わったら**承認を求めない**。stderr の `NG:` 行の停止理由と次の一手をユーザーへ報告して止まる
- dry-run が `RELEASE_RESULT=not-needed` なら承認は不要（リリースするものが無い）。その旨だけを報告する
- 承認後に本実行するまでに develop が進んだ（`git rev-parse HEAD` が承認した `RELEASE_HEAD=` と違う）ときは、`scripts/release-dev-toolkit.sh --advance-check <承認した RELEASE_HEAD>` で前進を分類し、dry-run を回し直す。次の 3 条件をすべて満たせば**再承認なしで本実行へ進んでよい**（承認した外向き操作の中身が変わらないため。v0.157.0 で一度だけ出した条件付き承認を恒常化した。Issue `#2202`）: (a) `ADVANCE=neutral`（新しいコミットが公開対象 = `--list-targets` の prefix・リリース機構 = 後段が実行する `scripts/` 配下・`changelog.d` を 1 ファイルも変えない） (b) 回し直した dry-run の `RELEASE_VERSION=` が承認時と同じ (c) `PLAN:` 行が、同期 commit の件名に入る SSOT の SHA 以外は承認時と同一。どれか 1 つでも外れたら（`ADVANCE=public` / `tooling` / `changelog` / `diverged`・版が変わった・SHA 以外の PLAN 行が変わった）従来どおり転記値を差し替えてから承認を取り直す。(a) と (b) は本実行のスクリプトも照合する（次項）ので、確かめ損ねても外れた前進は公開されない
- 本実行には `--executor` と、ユーザーから直接承認された `--expect-version` / `--approved-head` を渡す。Issue の値は担当と承認照合値の記録に使う。prepare 前の `ADVANCE=` の分類は従来どおりで、neutral 以外の前進・分岐・不明は `stopped-needs-approval` で止まる。固定済みの再開では、この clone に prepare の作成記録があるときだけ準備前の入力と承認済み HEAD を照合する。作成記録がない別 clone で引き継ぐときは、clean な worktree を固定 SHA に detach して dry-run を行い、その SHA の承認を直接得る。
- prepare が develop に push したコミットを `RELEASE_FIXED_HEAD=` として Issue に記録する。gate / sync / tag / release はこの対象で続け、後着の公開対象変更は次の受付へ回す。鮮度を判定する `changelog-fragments` と `shared-version-convergence` も同じ SHA を使う。リリースのゲートでは HEAD を進める `GATE_STALE_RECHECK` を使わない。
APPROVAL_BLOCK_EOF
)"
APPROVAL_BLOCK_ACTUAL="$(awk 'index($0, "**承認の求め方（承認文は dry-run の実測値を転記して作る。") == 1 {f=1} f && index($0, "- 段は `preflight → check") == 1 {exit} f' "$SKILL")"
# 末尾の空行は $(...) が落とすので、比較は両側とも末尾改行なしの文字列で行う
if [[ -z "$APPROVAL_BLOCK_ACTUAL" ]]; then
  bad "手順 R に「承認の求め方」段落が無い（dry-run 先行と PLAN: / RELEASE_VERSION= の転記の規定が消えた）"
elif [[ "$APPROVAL_BLOCK_ACTUAL" == "$APPROVAL_BLOCK_EXPECTED" ]]; then
  ok "手順 R の「承認の求め方」段落が全文一致（dry-run 先行・RELEASE_HEAD= を含む転記・完走の条件・途中停止・stopped / unavailable・not-needed・develop 前進と再承認不要の 3 条件・--expect-version と --approved-head の対と stopped-needs-approval・gate 走行中の前進）"
else
  bad "手順 R の「承認の求め方」段落が期待と違う（改訂したら本 suite の期待文も同じ PR で更新する）"
  diff <(printf '%s\n' "$APPROVAL_BLOCK_EXPECTED") <(printf '%s\n' "$APPROVAL_BLOCK_ACTUAL") | sed 's/^/    | /' >&2 || true
fi
contains_exactly '**承認の求め方（承認文は dry-run の実測値を転記して作る。' 1 \
  "「承認の求め方」段落が手順書に 1 箇所だけある"
# 位置: 手順 R の見出しと次の手順（0b）の見出しの間。段落ごと別の節へ移す退行を止める
_r_head="$(line_of '### R. リリース')"
_approval="$(line_of '**承認の求め方（承認文は dry-run の実測値を転記して作る。')"
_next_head="$(line_of '### 0b. 定期実行点ゲート')"
if [[ -n "$_r_head" && -n "$_approval" && -n "$_next_head" && "$_r_head" -lt "$_approval" && "$_approval" -lt "$_next_head" ]]; then
  ok "「承認の求め方」段落が手順 R の中にある"
else
  bad "「承認の求め方」段落が手順 R の中に無い（R=${_r_head:-なし} / 段落=${_approval:-なし} / 0b=${_next_head:-なし}）"
fi
for _hook in "$POST_MERGE_HOOK" "$SESSION_START_HOOK"; do
  _hook_name="${_hook##*/}"
  if [[ -s "$_hook" ]] && grep -Fq 'release_hook_update "$' "$_hook" &&
    ! grep -Eq 'リリース（同期）しますか|承認された場合のみ' "$_hook"; then
    ok "${_hook_name} は受付を更新し、リリース承認を求めない"
  else
    bad "${_hook_name} に受付更新の入口が無い、または承認を求めている"
  fi
done

# ── 7. リリーススクリプト（手順 0b / 5 / 8 の本体。ADR-063）───────────────────
echo "-- (7) リリーススクリプトの段の順序と同期元 SHA の契約 --"
# 段の実行順（main の呼び出し行）。check → prepare → gate → sync → tag → release → footer → report。
# ゲートより前に同期・タグ・Release が来る並べ替えは、不可逆操作の後で検査する退行になる。
R_CHECK="$(release_exact_line_of '  stage_check')"
R_PREPARE="$(release_exact_line_of '  stage_prepare')"
R_GATE="$(release_exact_line_of '  stage_gate')"
R_SYNC="$(release_exact_line_of '  stage_sync')"
R_TAG="$(release_exact_line_of '  stage_tag')"
R_REL="$(release_exact_line_of '  stage_release')"
R_FOOTER="$(release_exact_line_of '  stage_footer')"
R_REPORT="$(release_exact_line_of 'stage_report')"
R_PREFLIGHT="$(release_exact_line_of 'stage_preflight')"
R_APPROVED="$(release_exact_line_of 'issue_check_approval')"
# 承認した dry-run の HEAD との照合（Issue `#2622`）は preflight の fetch / pull の後・check 段の前。pull より前だと取り込んだ前進を
# 分類から落とし、check 段より後だと準備・同期へ進む回が照合の前に出る
assert_order "$R_PREFLIGHT" "$R_APPROVED" "順序(7): 承認した HEAD との照合が preflight（fetch / pull）より後" "順序(7): 承認した HEAD との照合が preflight より前 — 取り込んだ前進を分類しない退行"
assert_order "$R_APPROVED" "$R_CHECK" "順序(7): 承認した HEAD との照合がリリース要否の判定・準備より前" "順序(7): 承認した HEAD との照合が判定より後ろ — 照合の前に準備へ進む退行"
assert_order "$R_CHECK" "$R_PREPARE" "順序(7): リリース要否の判定が準備より前" "順序(7): 準備が判定より前にある"
assert_order "$R_PREPARE" "$R_GATE" "順序(7): 準備が定期実行点ゲートより前（ゲートは release コミットを含む HEAD を検査する。ADR-042）" "順序(7): ゲートが準備より前にある — 準備後の HEAD を検査しない退行"
assert_order "$R_GATE" "$R_SYNC" "順序(7): 定期実行点ゲートが同期より前" "順序(7): ゲートが同期より後ろにある — 不可逆操作の後で検査する退行"
assert_order "$R_SYNC" "$R_TAG" "順序(7): 同期がタグより前" "順序(7): タグが同期より前にある"
assert_order "$R_TAG" "$R_REL" "順序(7): タグが Release より前" "順序(7): Release がタグより前にある"
assert_order "$R_REL" "$R_FOOTER" "順序(7): Release が footer 追従より前" "順序(7): footer がタグ / Release より前にある"
assert_order "$R_FOOTER" "$R_REPORT" "順序(7): 健全性判定と footer 検査の報告が最後" "順序(7): report が footer より前にある"
# gate 段の中の順序: 全件のモード確定 → 同じ HEAD の記録の照合 → run-all → 部分 skip の許容判定 → 緑の記録。
RG_MODE="$(release_exact_line_of '  gate_mode=full')"
RG_REUSE="$(release_line_of 'if [[ "${rec%%:*}" == "$head" && "${rec#*:}" == full ]]; then')"
RG_RUNALL="$(release_line_of 'bash "$RUN_ALL" >"$gate_out" 2>&1 || gate_rc=$?')"
RG_SKIP="$(release_line_of 'release_skip_check "$gate_out"')"
RG_RECORD="$(release_line_of 'state_set GATE_OK "$head:$gate_mode"')"
assert_order "$RG_MODE" "$RG_REUSE" "順序(7): 全件のモード確定が記録の照合より前" "順序(7): モード確定が記録の照合より後ろ — 記録へ書くモードが未確定の退行"
assert_order "$RG_REUSE" "$RG_RUNALL" "順序(7): 同じ HEAD の記録の照合が run-all より前" "順序(7): 記録の照合が run-all より後ろ — 緑の記録があっても全件を回し直す退行"
assert_order "$RG_RUNALL" "$RG_SKIP" "順序(7): 部分 skip の許容判定が run-all より後" "順序(7): 許容判定が run-all より前 — 判定材料が無い"
assert_order "$RG_SKIP" "$RG_RECORD" "順序(7): 緑の記録が許容判定より後" "順序(7): 許容判定の前に緑を記録する退行"
release_contains_exactly 'require_gate_ok "' 3 \
  "不可逆段（sync / tag / release）は同じ HEAD で定期実行点ゲートが緑だった記録を要求する（--only で素通りさせない）"
release_contains "summary=\"\$(awk '/^suites: total=[1-9][0-9]* run=[1-9][0-9]* passed=[0-9]+ failed=0( |\$)/'" \
  "gate 段は run-all の完走サマリー（total > 0・failed=0）を要求する（空出力・途中の exit 0 を緑と読まない）"
release_contains '  acquire_in_flight
  resume_partial_write ssot' \
  "preflight は in-flight 印を取ってから書きかけの復旧へ進む（二重起動のプロセスが作業ツリーへ触らない）"
release_contains '[[ -n "$remote_main" && "$remote_main" == "$(git -C "$PUBLIC" rev-parse HEAD)" ]] \' \
  "tag 段は公開側 remote の main がローカル HEAD と一致するときだけタグを打つ（未 push の sync commit へ打たない）"
release_contains '  resume_partial_write public' \
  "preflight が公開側 clone への書きかけ（sync 段）を記録と照合してから進む"
release_not_contains 'reset --hard &&' \
  "公開側 clone を reset --hard で自動復旧しない"
release_not_contains 'clean -fd' \
  "公開側 clone を clean -fd で自動復旧しない"
release_contains 'ff_release_marker_release "$MARKER_DIR" "$MARKER_TOKEN"' \
  "in-flight 印の解放は自分の token と一致するときだけ行う（他の取得者の印を消さない）"
IN_FLIGHT_LIB="$(dirname "$RELEASE_SCRIPT")/lib/release-in-flight-functions.sh"
if [[ -f "$IN_FLIGHT_LIB" ]] && grep -qF -- 'token="$(_ff_marker_info_field "$info" token)"' "$IN_FLIGHT_LIB" \
  && grep -qF -- '[ "$(ff_release_marker_state "$dir" "$info")" = stale ] || return 1' "$IN_FLIGHT_LIB"; then
  ok "in-flight 印の回収 helper は 1 回読んだ info で残骸を判定し、同じ info の token で回収する（読み直さない）"
else
  bad "in-flight 印の回収 helper が判定と回収で info を読み直している、または lib が無い: $IN_FLIGHT_LIB"
fi
release_contains 'ff_release_marker_try_reclaim "$MARKER_DIR"' \
  "残骸の in-flight 印は、判定に使った token で rename（CAS 相当）回収する 1 つの helper を通す"
release_contains 'pub_ahead="$(git -C "$PUBLIC" rev-list --count origin/main..main)"' \
  "preflight が公開側の未 push の commit（前回の push 失敗の残り）を見る"
release_contains_exactly 'if [[ "${rec%%:*}" == "$head" && "${rec#*:}" == full ]]; then' 1 \
  "gate 段は同じ HEAD の全件の成功記録だけを再利用する（高速モードの記録は再利用しない。footer child は別の内容証明を要求）"
release_contains 'if footer_gate_reusable "$rec" "$head"; then' \
  "public-layout の再利用には footer の内容証明関数を通す"
release_contains "has_line \"\$proof\" 'FULL_GATE_REUSE=CHANGELOG_FOOTER_ONLY' || return 1" \
  "空出力・異なる状態・分類不能を public-layout の再利用へ倒さない"
# sync 段: 同期元 SHA は同期スクリプトの記録から読み、HEAD と突合してから commit する（手順 4 と同じ契約）。
RS_SYNC="$(release_line_of 'bash "$SYNC_SCRIPT" --target "$PUBLIC" || stop')"
RS_READ="$(release_line_of 'src_sha="$(cat "$(git -C "$PUBLIC" rev-parse --absolute-git-dir)/ff-sync-src-sha" 2>/dev/null || true)"')"
RS_GUARD="$(release_line_of 'if [[ -z "$src_sha" || "$(git rev-parse HEAD)" != "$src_sha" ]]; then')"
RS_COMMIT="$(release_line_of 'git -C "$PUBLIC" commit -q -m "sync: ${SSOT_NAME} $(git rev-parse --short "$src_sha") を反映"')"
assert_order "$RS_SYNC" "$RS_READ" "順序(7): 記録の読み取りが本同期より後" "順序(7): 記録を本同期より前に読む — 前回の記録を掴む退行"
assert_order "$RS_READ" "$RS_GUARD" "順序(7): HEAD 突合が記録の読み取りより後" "順序(7): 読む前に判定する退行"
assert_order "$RS_GUARD" "$RS_COMMIT" "順序(7): HEAD 突合が公開側 commit より前" "順序(7): 突合前に記録が確定する退行"
release_contains '[[ "$dry_text" == *"禁止パターン検査: クリア"* ]]' \
  "sync 段は dry-run の成功文字列を要求する（終了コードだけで通さない）"
# tag 段: リモートの実在（ls-remote の exit code）で分岐し、張り直さない。
release_contains 'git -C "$PUBLIC" ls-remote --exit-code --tags origin "refs/tags/v$1"' \
  "tag 段はリモートの実在を ls-remote の exit code で判定する"
release_contains 'is_semver3 "$VER" || stop' \
  "tag 段は vX.Y.Z の完全一致を確かめてからタグを打つ"
# 1.0.0 の宣言（--major。ADR-088）: 公開側に版のタグの実在を確かめた後の停止は、再開の案内に --major を載せない（再実行の
# --major は公開側のタグの照合が止める）。タグの後で再開の案内を出す停止は fixture で作れないので、印を付ける箇所を静的に固定する
release_contains_exactly 'major_tag_seen "$VER"' 3 \
  "tag 段はタグの実在を確かめた 3 箇所（dry-run の実在・本実行の実在・push の後）で --major の宣言を使い終えた印を付ける"
# footer 段: 限定ゲートを commit より前に通し、commit の後に push する。
RF_GATE="$(release_line_of 'limited_gate || stop')"
RF_COMMIT="$(release_line_of 'CHANGELOG 比較リンクを v${VER} へ追従" \\')"
assert_order "$RF_GATE" "$RF_COMMIT" "順序(7): footer の限定ゲートが release コミットより前" "順序(7): 限定ゲートの前に commit する退行"
# release 段（手順 7 と同じ吸収）: 今回の版だけが欠けている間は待ち、片側空は判定不能。
release_contains_exactly 'if [[ "$missing" != "v$VER" ]]; then break; fi' 1 \
  "release 段が今回の版以外の混入で再取得ループを抜ける"
release_contains_exactly 'if [[ -z "$tags" || -z "$rels" ]]; then unverified=yes; break; fi' 1 \
  "release 段が片側空のまま再取得を繰り返さず判定不能として抜ける"
release_contains '[[ "$latest" == "v$VER" ]] || stop' \
  "release 段が Latest の位置を直接検証する"

# shellcheck source=../lib/relay-skip-lines.sh
. "$SCRIPT_DIR/../lib/relay-skip-lines.sh"
_release_rt_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-release.XXXXXX")"
_release_rt_rc=0
bash "$SCRIPT_DIR/release-runtime.sh" "$RELEASE_SCRIPT" "$POST_MERGE_HOOK" >"$_release_rt_err" 2>&1 || _release_rt_rc=$?
if [[ "$_release_rt_rc" -eq 0 ]]; then
  ff_relay_captured_skips "$_release_rt_err" || bad "skip 行を中継できない（release-runtime）"
  ok "リリーススクリプトの振る舞い（段の順序・dry-run・冪等な再開・止まるべき状態・粒度・hook の in-flight 抑止）: $(tail -n 1 "$_release_rt_err")"
else
  bad "リリーススクリプトの振る舞いが壊れている (rc=${_release_rt_rc})"
  sed 's/^/    | /' "$_release_rt_err" >&2
fi
rm -f "$_release_rt_err"

# 同期提案 hook の changelog 断片の欠落通知（Issue `#2150` / OBS-099）。hook の不在は skip ではなく赤
# （本 suite は SSOT 専用で、SSOT には hook が在るはず）。
_cf_rt_err="$(mktemp "${TMPDIR:-/tmp}/sync-sha-changelog-fragment.XXXXXX")"
_cf_rt_rc=0
bash "$SCRIPT_DIR/changelog-fragment-runtime.sh" "$POST_MERGE_HOOK" "$REPO_ROOT/scripts/check-release-required.sh" >"$_cf_rt_err" 2>&1 || _cf_rt_rc=$?
if [[ "$_cf_rt_rc" -eq 0 ]]; then
  ff_relay_captured_skips "$_cf_rt_err" || bad "skip 行を中継できない（changelog-fragment-runtime）"
  ok "同期提案 hook の changelog 断片の欠落通知（欠落・揃い・公開対象外・判定不能・allowlist の一致）: $(tail -n 1 "$_cf_rt_err")"
else
  bad "同期提案 hook の changelog 断片の欠落通知が壊れている (rc=${_cf_rt_rc})"
  sed 's/^/    | /' "$_cf_rt_err" >&2
fi
rm -f "$_cf_rt_err"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ sync-sha-contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ sync-sha-contract verify: 全 $PASS 件 pass"
