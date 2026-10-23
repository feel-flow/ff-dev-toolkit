# 自動発火の hook 判定規則（/retrospective）

`/retrospective` の SKILL.md「自動発火（事前注入 + Stop fallback）」を hook がどう判定しているか。振り返りを実行するだけなら SKILL.md の判定リストで足りる。hook を変更するとき・自動発火の挙動を確かめるとき・入れ子の非対話起動を組むときに読む。

## 判定規則

1. `hooks/retrospective-stop.sh` は Claude Code 互換入力でだけ実行漏れの fallback として働く。セッションの transcript からそのターンの実行痕跡（`Skill` による `/ace-curate` `/merge-cleanup`、**コマンド位置の** `gh pr merge`、利用者の明示指定）を読み、チェーン末尾に到達していなければ無音で停止を許可する。到達している場合は、最終応答に振り返り結果があれば無音で停止を許可し、無ければ継続プロンプトを 1 回返す。**判定できない場合（transcript を読めない・ターン境界が読み取れない）は継続側へ倒す**（fail-closed。偽陽性は継続 1 回で済むが、偽陰性は必要だった振り返りが黙って消える）
2. Codex の Stop 入力（`model` フィールドあり）は常に無音で停止を許可し、UserPromptSubmit の事前注入だけに委ねる。Claude Code の fallback 継続中は、ホストの `stop_hook_active` または最終応答の振り返り結果により再停止を許可する
3. Codex の非対話の単発実行（UserPromptSubmit 入力に `model` があり `permission_mode` が `bypassPermissions` — codex exec は headless で承認を尋ねられないためこの組になる）には事前注入しない。レビュー等のツール的起動の stdout を振り返り出力が奪わないための抑止で、判別できない入力へは従来どおり注入する（fail-open。Claude Code の入力は `model` を含まないため、permission mode に関わらず常に注入側）
4. 入れ子で起動された非対話の `claude -p` は **hook 側では判別できない**（UserPromptSubmit の入力は `session_id` / `transcript_path` / `cwd` / `prompt_id` / `permission_mode` / `hook_event_name` / `prompt` だけで、print・headless・`output_format` に相当するフィールドが無い。`permission_mode` は `--permission-mode` の写しなので対話セッションと区別できない）。したがって fail-open のまま注入される。**stdout が成果物になる入れ子起動は、起動側が子プロセスの環境へ `RETROSPECTIVE_MODE=off` を載せて抑止する**のが正本（例: `RETROSPECTIVE_MODE=off claude -p "..." --output-format text`）。ping の exact-一致判定を持つレビューラッパーはこの前置きが無いと、振り返り行が stdout に混ざって判定に落ちる
5. **subagent へ委譲したチェーン末尾** — 判定は、そのターンの範囲に現れた `tool_use` を subagent のものも含めて数える（境界は利用者の prompt だけ、証拠はそのターンに起きた作業すべて、という非対称は意図的）。ただし subagent の記録を**別ファイルへ分ける**ホストでは、本体の transcript に `Agent` の呼び出ししか残らないため見えない。呼び出しのプロンプト文に該当語が含まれることを根拠にする方向は採らない — レビューエージェントの起動はプロンプトでこれらのコマンド名を説明するので、**すべてチェーン末尾になる**。通常は委譲後に本体が `/ace-curate` を実行するのでそこで検出され、検出できなかった場合は事前注入の契約だけが残る
6. **事前注入はチェーン末尾を判定できない** — hook が走るのは応答生成の前で、そのターンの tool 実行履歴はまだ transcript に無い（UserPromptSubmit 時点の transcript は 1 つ前のターンで終わっている）。したがって事前注入が渡すのは「チェーン末尾なら実施し、そうでなければ何も書かない」という条件付きの契約だけで、判定の正本は Stop 側にある。例外は background task の完了通知で、prompt が `<task-notification>` / `[SYSTEM NOTIFICATION` で**始まる**ことから前置一致で判別できるため、そのターンには注入しない（部分一致にすると、通知の扱いを尋ねている prompt を通知と誤認する）

<!--cd88ab827ff822b0-->
分類: 非操作: 実行痕跡による発火条件の説明で、ここで merge を実行する指示ではない。MCP 経路で完了した回も利用者の明示 /retrospective で同じ振り返りへ進む

## ホスト別の補足

- 判定を実行痕跡に置くのは、「作業が完了したように見えるか」をターンごとのモデル判断にすると、質問・確認待ち・background task の完了通知のたびに定型 1 行が出るため（OBS-187）
- Grok Build の Stop（実測 2026-10-18、grok 0.2.93）は Claude Code 互換の入力で走る（`hook_event_name` が `Stop`、`stop_hook_active` は boolean、`model` は無い）。`transcript_path` は Claude JSONL ではなく `updates.jsonl`（ACP の `session/update`。境界は `user_message_chunk`、実行痕跡は `tool_call` の `rawInput`）か `chat_history.jsonl`（`content` / `tool_calls`。`arguments` は JSON 文字列）で、どちらも同じチェーン末尾判定へ正規化する。末尾でないターンは無音で停止を許可する。`tool_call_update` の出力と、`synthetic_reason` が空でない行は、境界にも痕跡にもしない。Grok には Skill tool が無いので、`read_file` / `Read` が `skills/{ace-curate,merge-cleanup,retrospective}/SKILL.md` ちょうどを読んだことをスキル実行の痕跡にする。Codex の `model` による無音短絡は残す（`model` が無いことは Grok の識別子にしない。Claude Code も `model` を付けない）。隣接する `user_message_chunk` は、新しい方が古い方で始まる完全な prompt なら新しい方を境界にする（436 セッション中の隣接 2 件は prefix snapshot）。新しい方が断片で、連結結果が末尾コマンドか、そのコマンドの途中までの接頭辞である間だけ連結する。`agent_message_chunk` は隣接しなかったので連結しない。古い grok CLI で plugin hook が discovery のみだった計測は README のプラットフォーム表に残り、この箇条書きはその計測を取り消さない
- Codex では Stop hook の `decision:block` を返さないため、事前注入を取りこぼしても継続理由が利用者向け Feedback として露出しない。Claude Code では取りこぼし時の fallback を維持する
- 改善提案の起票は `RETROSPECTIVE_FILING` の規定（既定は自動起票。[filing.md](filing.md)「承認と起票」）に従い、hook の注入文はその規定を指すだけで承認境界を独自に定めない
