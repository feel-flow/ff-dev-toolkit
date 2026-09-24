# /ace-refine — domain の反映経路

引数が `domain` のときだけ読む。分類（5 区分）・自動 archive からの除外・統合の制約・garden wall・反映済みの扱いは [ACE ドメイン知識契約の「refine と反映」](../../../docs-template/05-operations/deployment/ace-domain.md#refine-と反映)が正本で、ここには同契約に無い実行手順だけを置く。通常の PATTERNS 昇格（R3-d）より優先する。`--confirm-pr <PR番号>` と `--entry <ACE ID>` は両方必須で、他カテゴリでは拒否する。Helpful の閾値は適用しない。

1. **既存 PR の照合**: ACE ID と対象文書で既存 PR を**全状態**で検索し、本文・変更ファイルで同一候補か確認する（タイトルの部分一致だけで同一視しない）。open ならそのPRを提示、closed 未マージなら自動再作成せず理由を報告、merged なら手順 3 へ進む。
2. **設計書 PR の作成**: 反映文案には業務ルール・適用条件・根拠と `出典: [ACE-ID](Playbookの当該anchorへの相対リンク)` を含め、同じ節に当該 ACE ID の出典を一意に置く。反映先節には明示 anchor（`<a id="ace-domain-..."></a>` の形。既存があれば再利用）を設け、Distill-To にその `#anchor` を含める。ユーザーから実装の委任が無ければ R2 で変更案を確認する。default branch から `chore/ace-domain-<ACE ID小文字>` を**別 worktree** に作り、対象設計書と必要な version / claim だけを変更して設計書用 PR を作る。通常 refine の PLAYBOOK / PATTERNS 更新と同じ PR に混ぜず、Distilled-To を先行記録しない。
3. **反映の検証**: 設計書 PR のマージ後、または `--confirm-pr` / `--entry` で再開したとき、対象が confirmed かつ Distill-To 解決済みか再確認してからチェッカーを実行する（plugin root guard を先に実行する。引数は個別に引用し、資料本文をシェルコードへ埋め込まない）:

   ```bash
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-domain-distillation.ts" "$REPOSITORY" "$DISTILL_PR" "$ACE_ID" "$DISTILL_TARGET" "$RULE_TEXT"
   ```

   確認できない・API / 権限エラーは未確認として止める。GitHub チェックが無い場合に限り `--local-gate <記録path>` を渡せる（受理する記録の要件はチェッカー冒頭の docblock が持つ。チェックが失敗・保留なら代替できない）が、記録は同じ PR head で対象プロジェクトの全件ゲート（ff-dev-toolkit では `FF_RUN_ALL_FULL=1`）が機械生成したものに限り、**手で作らない**（チェッカーは生成元を認証しない）。チェックは構造的証明なので、ルールと Evidence の意味的一致は別途照合する。
4. **Distilled-To の記録**: チェッカー成功後に、最新 default branch で**独立した ACE 更新**として Status 行へ Distilled-To を足す（元 Status は active、同じ記録なら no-op）。その PR / commit 本文に検証 receipt（元設計書 PR・merge SHA・対象・ACE ID）を残す。採用した反映先が変わったら先に Distill-To を根拠付きで整合させ、既存マーカーだけを根拠に更新しない。
5. 最終報告は収集済み・設計書 PR 作成・設計書マージ済み・ACE への反映済み記録を区別し、未確認・矛盾・未解決の残件も報告する。
