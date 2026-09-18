#!/usr/bin/env bash

#
# 委譲先が長時間ゲートを background で起こすのを止めるガード（PreToolUse / Bash、
# 観測台帳 OBS-036 の対策）。
#
# サブエージェントが
#   (a) **任意のコマンド**を `run_in_background: true` で起こす
#   (b) 名簿の長時間ゲート（`run-all.sh` / `run-mutations.sh`）を、Bash ツールの
#       `timeout` を省いて / foreground 上限より短く指定して起こす
# と、ハーネスがそのコマンドを background へ回す。background へ回された委譲先は
# 「完了通知を待つ」と言って停止し、親がナッジするまで再開しない。親が引き取るので
# 最終成果には現れず、失うのは待ち時間だけなので観測台帳を見ないと累積が分からない。
#
# **この hook は「文言では止まらない」ことの実測を受けて作られている。** 文言による
# 対策は 3 セッション連続で効いていない。うち正本
# （`docs-template/05-operations/deployment/multi-cli-agent-orchestration.md` の
# 「委譲先に長時間コマンドを foreground で待たせる契約」節）が**存在した状態**での
# 再発は 2026-09-15 の 1 回で、その回は**委譲プロンプト自身に規定が書いてあった**
# うえに親の SendMessage による明示的な再指示の直後にも同じことを繰り返した
# （同節は 2026-09-12 に新設されたので、それ以前の 2 セッションは別の所在の文言に
# 対する実測である）。到達点を増やす方向の対策は上限に達している。
#
# ## サブエージェントの呼び出しだけに掛ける（親は対象外）
#
# 親自身が意図的に background でゲートを回す運用（PR 作成後にレビューと baseline
# ゲートを並走させる形。観測台帳 OBS-194）は正当なので壊さない。両者は hook 入力で
# 機械的に区別できる。
#
# 実測（claude 2.1.270 / 2026-09-16。親と子の Bash PreToolUse ペイロードを同一
# セッションで捕捉して比較）:
#   - 親（メインセッション）の PreToolUse: `agent_id` / `agent_type` は**キーごと不在**
#   - サブエージェントの PreToolUse:       `agent_id` / `agent_type` が**在る**
#     （`agent_type` は呼び出し元の型。例: `general-purpose`）
#   - `session_id` / `transcript_path` は親子で**完全に同一** → 判別材料にならない
#   - `tool_input.timeout` は未指定時にキーごと欠落する
# したがって発火条件に `agent_type` の非空を含めれば、親の呼び出しは構造的に対象外に
# なる（環境変数による除外運用に頼らない）。`agent_type` を載せないハーネス版では
# 判定材料が無いので**無音で通す**（fail-open。guard-review-in-flight.sh が
# `subagent_type` 不在の版に対して採っているのと同じ規律）。
#
# ## トリガは 2 つ。名簿に縛られるのは「自動 background 化」の側だけである
#
# 止める行為は 1 つ（委譲先が起こしたコマンドの完了を追わない）だが、そこへ至る経路は
# 2 つあり、**判定材料の質がまるで違う**。混ぜると片方の制約がもう片方を不必要に縛る。
#
#   (i)  委譲先が `run_in_background: true` を**明示**した … **deny の判定**は構造化
#        フィールド 1 つで決まり、コマンド本文の解析結果に依存しない。だから下で名簿を
#        狭く保っている理由（近似的なコマンド解析が生む誤検知）が掛からず、
#        **名簿に依らず止める**。
#        ただし本文をまったく見ないわけではない — ACK 前置の検出（`code_only` の先頭）と
#        記録へ載せるコマンド名の解決は本文から取る。したがって**本文処理側の fail-open
#        は (ii) と共有する**: heredoc ヘルパが読めない・`code_only` が空・jq 不在では
#        (i) も無音で通る。「解析に依らない」のは deny の判定であって、hook 全体の
#        到達性ではない
#   (ii) ハーネスが自動で background へ回した（`timeout` 未指定・foreground 上限未満）
#        … これは「このコマンドは上限を超えるか」の**予測**が要る。一般化すると
#        `timeout` を書かない短いコマンドが全部 deny になるので、**名簿で絞る**
#
# ## (ii) の名簿を一般の「長そうなコマンド」へ広げない
#
# 名簿は `run-all.sh`（全件ゲート）と `run-mutations.sh`（effort-contract の変異
# マトリクス。`run-all.sh` の既定一覧に**載せない**設計なので、回すには自分の綴りで
# 起動するしかない）の 2 件である。OBS-036 の 7 回の再発のうち `run-all` と名指し
# されているのは 3 回、`npm ci` が 1 回、7 回目が下記の変異ループ、残る 2 回は対象
# コマンドを特定できない（うち 1 回はサブエージェントですらなく親自身の待機ループ）。
#
# **依存インストール（`npm ci` 等）を名簿から外したのは実測の結果である。**
# クロスモデルレビュー 3 回転が出した誤検知（無害なコマンドの deny）は**すべて**
# 自然文へ紛れ込んだ install 名が原因だった（`git commit -m "手順; npm ci; 完了"` /
# `echo "A; npm ci; B"`）。セグメント分割はクォート状態を追跡しないため、引用符の
# 内側の区切りでも割れる。未閉鎖判定で大半は捨てられるが、区切りが偶数個のときは
# 引用符を 1 つも含まない中間セグメント（` npm ci`）が balanced として残る。
# 3 巡のあいだ、層を 1 つずつ下げて直してもクラスが一歩隣で生き残った。
#
# **「`.sh` の basename は散文に現れないから安全」とは書かない — それは誤りだった。**
# 本リポジトリの docs には `bash plugins/ff-dev-toolkit/tests/run-all.sh` が
# **コマンド行の形で**複数存在し、本 suite の fixture 自身も散文中にこの綴りを持つ。
# 名簿を絞る根拠は「綴りが散文に現れないこと」ではなく、**誤検知の実測された面が
# install 名に集中していたこと**である。止めたい 5 形（`run_in_background` /
# `timeout` 未指定 / `&&` の 2 本目 / 環境代入の前置 / 直接実行）はすべて残る。
# 散文起因の誤検知そのものは、名簿ではなく下の「引用符を含むコマンドは最初の
# セグメントだけを見る」規則が閉じる。
#
# 「ビルド検証」も入れない（機械照合できる安定した綴りが実測に無い。`npm run build`
# はプロジェクトごとに所要が大きく違い、短いものまで止めると誤警告が常態化する）。
# 別の綴りで再発したら名簿へ足す — ただし足す前に、その綴りが散文に現れうるかを
# 見ること。現れうる綴りは同じ誤検知を連れてくる。名簿の綴りは `LONG_GATE_ROSTER`
# の 1 行が正本で、前置フィルタ 3 段も判定も全部そこから作る（下の宣言のコメント参照）。
#
# **`verify.sh` は名簿へ足さない（Issue `#1719` の判断）。** 7 回目の再発（2026-09-16 /
# Epic `#1651`）で素通りしたのは、`adapter-common.sh` へ手で変異を当てながら影響 suite を
# 繰り返し回すループで、実行された綴りは `bash plugins/ff-dev-toolkit/tests/<suite>/verify.sh`
# だった（親セッションの実測: 12:47:52Z「one temporary mutation on adapter-common.sh is
# applied」。委譲先自身の transcript は worktree 回収時に掃除済みで復元できない）。
# `verify.sh` は 140 suite すべての入口で（`find plugins/ff-dev-toolkit/tests -maxdepth 2
# -name verify.sh | wc -l` = 140。`run-all.sh` の登録照合も同じ集合を数える）、大半は
# 数秒で終わる — 名簿へ足すと
# 「`timeout` を書かずに単体 suite を回す」という日常の呼び出しが全部 deny になる。
# 名簿は所要時間の**予測**なので、suite ごとに所要が違う共通入口は原理的に載せられない。
# この回は上の (i)（明示 background）側で止まる。ハーネスの自動 background 化で
# 同じことが起きる経路は開いたままで、既知の限界 A に「名簿外の綴り」として残す。
#
# ## 出力チャネル
#
# PreToolUse には「実行を許しつつ agent に警告文を見せる」チャネル
# （`additionalContext`）は無い。`systemMessage` は利用者向けの表示チャネルで
# **エージェントのコンテキストには入らない**（guard-background-cwd.sh がこの非対称を
# 実測で確認し、deny へ寄せた経緯を持つ）。行動を変えるのは委譲先エージェント自身
# なので、届く唯一のチャネルである `permissionDecision: "deny"` の
# `permissionDecisionReason` で返す。可視化だけの対策は受け入れ条件を満たさない。
#
# 抜け道は deny の本文で必ず案内する（案内の無い deny は詰まりになる）:
#   - **ゲートを実行するセグメントの先頭**に環境代入 `FF_LONG_GATE_BACKGROUND_ACK=1`
#     を付ける（文字列としてコマンド中に現れるだけでは無効。判定はセグメントごとなので、
#     `cd /repo && bash …/run-all.sh` に対しては `cd /repo &&
#     FF_LONG_GATE_BACKGROUND_ACK=1 bash …/run-all.sh` と置く。コマンドの先頭へ置いても
#     ゲートが別セグメントなら効かない）
#   - ガードごと止めるなら環境変数 `FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD=1`
#
# ## 発火の記録（親が「停止した子」を数える／区別するための台帳）
#
# 発火（deny）と抜け道通過（ack）を追記ログへ 1 行ずつ残す。これは 2 つの受け入れ
# 条件の共通の土台になる:
#   - 親が「どの子がゲートを background で起こそうとしたか」を一覧できる
#   - 「対策後の発生回数 0」を主張する根拠になる（数える手段の無い 0 は主張できない）
# 置き場は **TMPDIR 配下**でリポジトリの中ではない。リポジトリ root へ書くと
# 作業ツリーが dirty になり、レビュー用サブエージェント起動時の dirty 判定
# （guard-review-in-flight.sh の B）を誤って発火させる。ログは session_id ごとに
# 1 本で、親とサブエージェントは session_id を共有する（上の実測）ため、1 本が
# そのままそのセッションの委譲事故台帳になる。
#   ${TMPDIR:-/tmp}/ff-dev-toolkit-delegation-guard/<session_id>.log
# 書き込み失敗は握り潰す（ログはガードの副産物であって、ログのために deny を
# 落とすことはしない）。
#
# ## 既知の限界
#
# 2 つに分けて書く。「素通しする形」と「誤って deny しうる形」を 1 つの一覧へ混ぜると、
# 見出しの主張（素通し）と項目の挙動（deny）が食い違い、読み手が安全側だと誤読する。
#
# ### A. 取りこぼす形（発火すべきだが素通しする。fail-open 側）
#   ※ この一覧は網羅ではない。近似的なコマンド解析なので、ここに挙げていない綴りでも
#     素通しする。挙げてあるのは実測で確認した代表形である。
#   ※ **以下は (ii)（ハーネスの自動 background 化）の経路に限る。** 明示
#     `run_in_background: true` は名簿にも解析にも依らず止まるので、下の形はどれも
#     素通ししない（実測 2026-09-17: コマンド置換パス / サブシェル / 空白を含むパス /
#     `timeout 900` ラッパ / `xargs` / 変数展開 / 引用符付き 2 本目 の 7 形すべて deny）。
#     唯一 (i) にも掛かるのは 1 番目（`agent_type` を載せないハーネス版）と、上の (i) の
#     項が述べた本文処理側の fail-open である。
#   - `agent_type` を載せないハーネス版（判定材料が無い）
#   - **名簿外の綴りが、ハーネスの自動 background 化（`timeout` 未指定・過少）で
#     background へ回る形**。明示 `run_in_background` なら名簿に依らず止まるが、
#     自動 background 化の側は所要時間の予測が要るので名簿に縛られる。OBS-036 の
#     7 回目（変異を当てながら個別 suite を回すループ）がこのクラスで、`verify.sh` を
#     名簿へ足せない理由は上の「(ii) の名簿を…広げない」節にある
#   - 変数展開・コマンド置換の中で組み立てられるゲート名
#   - heredoc 本文に書かれたゲート名（データであって実行されるコマンドではない）。
#     走査の前に本文ごと落とす
#   - 引用符を含むコマンドの、2 本目以降のセグメント（`echo "x" && bash …/run-all.sh`）。
#     下の「引用符を含むコマンドは最初のセグメントだけを見る」規則の代償
#   - コマンド置換で組み立てられたパス（`bash "$(git rev-parse --show-toplevel)/…/run-all.sh"`）。
#     リポジトリ直下の指示文が推奨する絶対パス化イディオムが、**自動 background 化の
#     経路では**そのまま死角になるので、委譲プロンプトへ常置する文言はこの形のために
#     要る（正本テンプレートにも明記）。明示 `run_in_background` なら止まる
#   - サブシェル括弧のうち、**区切り記号を含まない形**（`( bash …/run-all.sh )`）。
#     `(` は分割・除去の対象ではないので head トークンが `(` のままになり、ラッパ判定
#     （`bash` 等）にもゲート判定にも当たらない。`( cd /repo && bash …/run-all.sh )` は
#     `&&` で割れて 2 本目の head が `bash` になるため**止まる**（2026-09-17 実測。
#     以前ここには後者を例に「basename が `run-all.sh)` になる」と書いてあったが、
#     例も機序も誤りだった）
#   - 空白を含むパス（素朴な空白トークン化で割れる）
#   - 値を取るラッパ経由の実行（`timeout 900 bash …/run-all.sh`）。ラッパ名簿へ
#     足すには引数の取り方まで持つ必要があり、名簿は観測台帳が実測した形だけで
#     作るという上の線引きに反するので入れない
#   - `xargs` / `find -exec` 経由で組み立てられる実行（トークン列に現れない）
#
# ### A'. 名簿判定の粒度（取りこぼしでも誤検知でもないが、一覧から予測できない挙動）
#   - 名簿は**スクリプト名（basename）だけ**を見て引数を見ない。したがって長時間ゲートに
#     ならない短い呼び出しも同じ扱いになる（`bash …/run-all.sh <単一 suite>` の明示引数、
#     `FF_RUN_ALL_DUMP_DECLARATIONS=1 bash …/run-all.sh` の dump-and-exit）。どちらも
#     `timeout` を明示すれば通るので詰まりにはならないが、一覧を読んだだけでは
#     予測できないのでここへ書く。引数で分岐させる案は採らない（ランナー側の引数仕様へ
#     依存し、名簿は観測台帳が実測した形だけで作るという線引きから外れる）
#
### B. 誤って deny しうる形（既知の誤検知。fail-closed 側）
#   - ハーネスが `timeout` を載せない版。省略と区別できないので timeout 側のトリガが
#     発火する。その版では ack か opt-out で抜ける
#   - ハーネスが `timeout` を載せない版だけがこの区分に入る。**シェル自身の `&`
#     による background（`bash …/run-all.sh &`）に `timeout` を付けない形も deny に
#     なるが、それは誤検知ではない** — 委譲先がゲートを background で起こして待たない
#     という、このガードが止めようとしている行為そのものだからである（`&` を判定に
#     含めないのは、ハーネスの背景化と別機構だという理由であって、見逃す意図ではない）。
#     ここへ「誤検知」として書くと、将来「誤検知だから抜く」方向の修正を誘発する
#
# クォート内のゲート名による誤 deny（`git commit -m "a; bash …/run-all.sh; b"` /
# 複数行の `--body`）は B に**含まれない** — 「引用符を含むコマンドは最初のセグメント
# だけを見る」規則で閉じてある。この規則を外すとこのクラスが戻るので、外すときは
# 同時に別の手当てが要る（クォート認識のある分割。ただしそれは同じ近似分割を共有する
# **7 本**の hook — `guard-checkout-restore` / `guard-effort-actual` /
# `guard-issue-labels` / `guard-pr-followup` / `guard-review-in-flight` /
# `guard-sub-issue-id` / 本 hook — をまとめて直すべき別の変更になる）
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、自身の不具合や解析不能な形、
#     jq 不在では黙って許可（exit 0・無出力）に倒す
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD=1  このガードを無効化する
#   FF_LONG_GATE_FOREGROUND_TIMEOUT_MS=<ミリ秒>       要求する最小 timeout
#                                                     （既定 600000 = ホストの
#                                                     foreground 上限）

# fail-open のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト /
# テストの printf）が EPIPE / SIGPIPE を受ける。fail-open の「黙って許可」は「stdin を
# 読み切ったうえで」成立させる。-d '' は EOF で非 0 を返すが input には内容が入っている。
input=""
IFS= read -r -d '' input || true

# ASDD ゲートはこの drain より後に置く（ゲートの早期終了は exit 0 なので、先頭へ置くと
# stdin 未読のまま抜ける経路ができ、上の drain が守っている EPIPE / SIGPIPE が漏れる）。
# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0

# opt-out も stdin を読み切ってから抜ける。
[ "${FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD:-0}" = "1" ] && exit 0

# ---- 名簿（正本はここ 1 箇所） -------------------------------------------------
#
# 前置フィルタ 3 段（生の $input / heredoc 除去後の $code_only / セグメント単位）と
# scan_long_gate は**すべてこの一覧から作る**。綴りを段ごとに直書きすると、一部の段
# だけが広がって新しい綴りが scan_long_gate へ到達しない（=「名簿へ足したのに効かない」
# が静かに起きる）。
# 変異注入の効き方は 2 通りで違う（2026-09-17 実測）: 段を**削除**しても検査は 1 本も
# 赤くならない（段 1 は純粋な速度目的で、落とすのは通してよい入力だけ）が、綴りを段ごと
# に**直書きへ戻す**変異は名簿 2 件目が針になって赤くなる（suite ヘッダ MN2〜MN4）。
# 宣言を 1 箇所へ畳むのは、前者の測れない層を構造的に潰すためである。
LONG_GATE_ROSTER='run-all.sh run-mutations.sh'

# 名簿の綴りは**メタ文字を含められない**。下のループは語分割と同時にパス名展開も
# 受けるため、`run-*.sh` のような綴りを 1 件足すと委譲先の cwd 次第で名簿が別物へ
# 展開され、検査は全緑のまま防御だけが消える。`set -f` で展開を止めたうえで、
# 綴りの制約をここに書いておく（宣言が無いと、次に足す人が踏む）。
has_roster_spelling() { # <text>
  local _g _glob=0
  case "$-" in *f*) _glob=1 ;; esac
  set -f
  for _g in $LONG_GATE_ROSTER; do
    case "$1" in *"$_g"*) [ "$_glob" -eq 1 ] || set +f; return 0 ;; esac
  done
  [ "$_glob" -eq 1 ] || set +f
  return 1
}

# 安価な前置フィルタ: Bash 以外は即終了。
case "$input" in
  *'"Bash"'*) : ;;
  *) exit 0 ;;
esac
# 親（agent_type 不在）は構造的に対象外。キーそのものが無い入力をここで落とす。
case "$input" in
  *agent_type*) : ;;
  *) exit 0 ;;
esac
# 名簿の綴りも `run_in_background` も無い入力は、どちらのトリガも発火しえない。
# 後者はコマンド本文ではなく**構造化フィールドのキー名**なので、この段が広がっても
# 散文由来の誤検知面は 1 つも増えない。
if ! has_roster_spelling "$input"; then
  case "$input" in
    *run_in_background*) : ;;
    *) exit 0 ;;
  esac
fi

command -v jq >/dev/null 2>&1 || exit 0

nl='
'

# 必要な 7 フィールドを 1 回の jq で取り出す。PreToolUse は全 Bash 呼び出しに乗るため
# jq の多重起動はそのまま体感コストになる。改行を含み得る `command` を最後に置いて
# 「残り全部」として拾う。
meta="$(printf '%s' "$input" | jq -r '
  (.tool_name // ""),
  (.agent_type // ""),
  (.agent_id // ""),
  (if (.tool_input.run_in_background // false) == true then "true" else "" end),
  (if (.tool_input.timeout | type) == "number" then (.tool_input.timeout | tostring) else "" end),
  (.session_id // ""),
  (.tool_input.command // "")' 2>/dev/null)" || exit 0

meta_rest="$meta"
FIELD=""
pop_field() {
  case "$meta_rest" in
    *"$nl"*)
      FIELD="${meta_rest%%"$nl"*}"
      meta_rest="${meta_rest#*"$nl"}"
      ;;
    *)
      FIELD="$meta_rest"
      meta_rest=""
      ;;
  esac
}

pop_field; tool="$FIELD"
[ "$tool" = "Bash" ] || exit 0

# 呼び出し元がサブエージェントであることの判定材料。空（= 親、または載せないハーネス版）
# なら無音で通す。
pop_field; agent_type="$FIELD"
[ -n "$agent_type" ] || exit 0

pop_field; agent_id="$FIELD"
pop_field; bg="$FIELD"
pop_field; timeout_ms="$FIELD"
pop_field; session_id="$FIELD"

cmd="$meta_rest"
[ -n "$cmd" ] || exit 0

# ---- 名簿判定 -----------------------------------------------------------------

strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

basename_of() { # <path>
  local s="$1"
  printf '%s' "${s##*/}"
}


SEG_TOKS=()
SEG_ACK=0
SEG_HEAD_I=0

# 環境代入・`bash` 等のラッパを読み飛ばして「実際に走るコマンド」の位置を決める。
# `bash <path>/run-all.sh` を名簿に当てるため、ラッパは読み飛ばすだけで捨てない。
skip_command_prefixes() {
  local n=${#SEG_TOKS[@]} t
  SEG_HEAD_I=0
  SEG_ACK=0
  while [ "$SEG_HEAD_I" -lt "$n" ]; do
    t="$(strip_quotes "${SEG_TOKS[$SEG_HEAD_I]}")"
    case "$t" in
      FF_LONG_GATE_BACKGROUND_ACK=1) SEG_ACK=1; SEG_HEAD_I=$((SEG_HEAD_I + 1)) ;;
      [A-Za-z_]*=*|if|while|until|do|then|else|elif|'{'|'!'|time) SEG_HEAD_I=$((SEG_HEAD_I + 1)) ;;
      env|command|sudo|nohup)
        SEG_HEAD_I=$((SEG_HEAD_I + 1))
        while [ "$SEG_HEAD_I" -lt "$n" ]; do
          case "${SEG_TOKS[$SEG_HEAD_I]}" in -*) SEG_HEAD_I=$((SEG_HEAD_I + 1)) ;; *) break ;; esac
        done
        ;;
      *) break ;;
    esac
  done
}

# セグメントの「実際に走るコマンド」の basename。`bash <script>` はラッパではなく
# スクリプト側を返す（`any:bash` では何を background へ回したのか分からず、観測台帳で
# 再発をクラス別に数えられない）。**表示とログのためだけ**の関数で、何も止めない —
# だから scan_long_gate の `-n`（実行しない呼び出しの除外）は持たない。持たせると
# 「止める判定」と「名乗らせる判定」が 1 つの関数へ混ざる。
CMD_LABEL=""
resolve_segment_label() {
  local n=${#SEG_TOKS[@]} head sub j
  CMD_LABEL=""
  [ "$SEG_HEAD_I" -lt "$n" ] || return 1
  head="$(basename_of "$(strip_quotes "${SEG_TOKS[$SEG_HEAD_I]}")")"
  CMD_LABEL="$head"
  case "$head" in
    bash|sh|zsh|ksh|dash)
      j=$((SEG_HEAD_I + 1))
      while [ "$j" -lt "$n" ]; do
        sub="$(strip_quotes "${SEG_TOKS[$j]}")"
        case "$sub" in -*) j=$((j + 1)); continue ;; esac
        break
      done
      [ "$j" -lt "$n" ] && CMD_LABEL="$(basename_of "$(strip_quotes "${SEG_TOKS[$j]}")")"
      ;;
  esac
  return 0
}

# 名簿の綴りと basename が一致するか。当たれば MATCH_LABEL にその綴りを入れる。
MATCH_LABEL=""
roster_match() { # <basename>
  local _g _glob=0
  case "$-" in *f*) _glob=1 ;; esac
  set -f
  for _g in $LONG_GATE_ROSTER; do
    if [ "$1" = "$_g" ]; then
      MATCH_LABEL="$_g"; [ "$_glob" -eq 1 ] || set +f; return 0
    fi
  done
  [ "$_glob" -eq 1 ] || set +f
  return 1
}

# セグメントが名簿の長時間ゲートかどうか。当たれば MATCH_LABEL に綴りを入れる。
scan_long_gate() {
  MATCH_LABEL=""
  local n=${#SEG_TOKS[@]} head sub j noexec
  [ "$SEG_HEAD_I" -lt "$n" ] || return 1
  head="$(basename_of "$(strip_quotes "${SEG_TOKS[$SEG_HEAD_I]}")")"
  # 無害な先頭語（`echo` / `grep` 等）の allowlist は持たない。名簿を**位置**で絞った
  # 時点で、先頭語がゲート自身でもシェルでもないセグメントは下の判定が落とすため、
  # allowlist は 1 件も追加で落とさない死にコードになる（変異注入で実測: allowlist を
  # 外しても検査は全緑のまま = 誰も守っていない）。allowlist を足して回る方向は
  # 「止めたいのは実行だけ」という線引きの代わりにならない。

  # 1) 全件ゲート: `run-all.sh` が**実行される位置**に在るときだけ名簿に当てる。
  #    セグメント内の全トークンを走査すると、ゲートを「実行」せず「引数として触る」
  #    だけの日常コマンドまで止まる（`git add …/run-all.sh` / `git diff -- …/run-all.sh`
  #    / `chmod +x …/run-all.sh`）。allowlist を足して回る方向では追いつかない
  #    （止めたいのは実行だけなので、名簿は位置で絞るのが正しい）。
  if roster_match "$head"; then return 0; fi
  case "$head" in
    bash|sh|zsh|ksh|dash)
      # シェル経由（`bash <path>/run-all.sh`）は最初の非フラグオペランドだけを見る。
      # `-n`（構文検査。リポジトリの標準イディオム）を含むフラグが付く呼び出しは
      # スクリプトを実行しないので対象外にする。`--norc` 等も n を含むため対象外へ
      # 倒れるが、これは取りこぼし側（fail-open）で誤って止める側ではない。
      j=$((SEG_HEAD_I + 1))
      noexec=0
      while [ "$j" -lt "$n" ]; do
        sub="$(strip_quotes "${SEG_TOKS[$j]}")"
        case "$sub" in
          -*) case "$sub" in *n*) noexec=1 ;; esac; j=$((j + 1)); continue ;;
        esac
        break
      done
      [ "$noexec" -eq 1 ] && return 1
      [ "$j" -lt "$n" ] || return 1
      if roster_match "$(basename_of "$(strip_quotes "${SEG_TOKS[$j]}")")"; then
        return 0
      fi
      ;;
  esac

  return 1
}

# ---- heredoc 本文を走査対象から落とす ------------------------------------------
# heredoc 本文は実行されるコマンドではなくデータなので、`gh pr comment --body "$(cat <<EOF
# … bash …/run-all.sh … EOF)"` のような引用で停止すると、PR へ手順を書く操作が
# ゲートに引っかかる。判定は共有ヘルパ `tests/lib/heredoc-strip.sh`（正本はヘルパの
# ヘッダ。独自の構文解析を足さない）。ヘルパが読めない・awk が失敗したら素通しへ倒す
# （fail-open）。未終端（rc 3）はヘルパが生コマンドを返すので、行を捨てずに走査する。
HEREDOC_HELPER="${BASH_SOURCE[0]%/*}/../tests/lib/heredoc-strip.sh"
# shellcheck source=../tests/lib/heredoc-strip.sh
. "$HEREDOC_HELPER" 2>/dev/null || exit 0
code_only="$(ff_heredoc_strip "$cmd")"
case $? in
  0 | 3) : ;;
  *) exit 0 ;;
esac
[ -n "$code_only" ] || exit 0
# 段 2。明示 background は名簿に依らない一般トリガを持つので、ここでは落とさない。
if [ "$bg" != "true" ] && ! has_roster_spelling "$code_only"; then exit 0; fi

# セグメント分割はクォート状態を解釈しない（完全なシェル構文解析は持ち込まない）。
# そのぶん `git commit -m "手順を直す; bash tests/run-all.sh が要る"` のようにクォートの内側にある
# 区切り記号でもセグメントが割れ、文字列の一部が実コマンドに見える。割れたセグメントは
# 「クォートが閉じていない」という形で判別できるので、その場合は deny 側の誤検知を
# 避けてセグメントごと捨てる（fail-open）。**guard-effort-actual.sh からの複製**。
quotes_balanced() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    BEGIN { q = sprintf("%c", 39); bad = 0 }
    {
      st = 0 # 0=クォートの外 1=シングル 2=ダブル
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (st == 0) {
          if (c == "\\") { i++ }
          else if (c == q) { st = 1 }
          else if (c == "\"") { st = 2 }
        } else if (st == 1) {
          if (c == q) { st = 0 }
        } else {
          if (c == "\\") { i++ }
          else if (c == "\"") { st = 0 }
        }
      }
      if (st != 0) bad = 1
    }
    END { exit (bad ? 1 : 0) }
  ' 2>/dev/null
}

# 行末 `\` 継続を結合してから `&&` / `||` / `;` / `|` / `$(` / backtick で分割する
# （兄弟ガードと同形。ループ本体・コマンド置換・`&&` の 2 本目を取りこぼさない）。
joined="$(printf '%s\n' "$code_only" | awk '
  {
    if (sub(/[[:space:]]*\\$/, "")) { buf = buf $0; next }
    print buf $0
    buf = ""
  }
  END { if (buf != "") print buf }
')"
segments="$(printf '%s\n' "$joined" | awk '{ gsub(/&&|\|\||;|\||\$\(|`/, "\n"); print }')"

# **引用符を 1 つでも含むコマンドは、最初のセグメント（コマンド位置）だけを見る。**
#
# セグメント分割も未閉鎖判定も行単位で動くため、複数行のクォート引数の中間行は
# 「区切り記号を含まない・引用符を 1 文字も含まない」ので balanced と判定されて
# 残り、そのままゲートの実行に見える。実測（2026-09-16）:
#   gh pr comment N --body "検証結果:⏎⏎bash tests/run-all.sh → green⏎⏎以上"
# サブエージェントが検証報告を PR / Issue 本文へ書く操作そのもので、誤検知として
# 最も踏みやすい形だった。`sed -i 's|bash …/run-all.sh|…|'` も同じ機構で止まる。
#
# 引用符があるときだけ「後続セグメントは引用の内側かもしれない」が成り立つので、
# そこを発火の線にする。新しい構文解析器を足さない（近似パーサを層ごとに直す形は
# 4 巡連続で同じクラスの誤検知を出したので採らない）。代償は A の 4 番目
# （引用符付きコマンドの 2 本目以降の取りこぼし）で、fail-open 側に倒れる。
# 判定の入力は heredoc 除去**後**の `code_only`。除去前の `$cmd` を見ると、heredoc
# 本文（= データであって実行されない）に引用符が 1 文字あるだけで規則が起動し、
# 終端行の後ろにある実際のゲート実行を取りこぼす。A の 3 番目が「heredoc 本文は
# 走査の前に落とす」と宣言している以上、判定にも影響させない（実測 2026-09-16:
# 本文が `"メモ"` なら素通し、`メモ` なら deny と、実行されるコマンド列が同じまま
# 反転していた）。heredoc 除去はこれで 3 箇所に効く。
QUOTED=0
case "$code_only" in *\"*|*\'*) QUOTED=1 ;; esac

FIRE_LABEL=""
ACKED=0
# ACK が成立した時点の綴りを**その場で**確保する。`MATCH_LABEL` は scan_long_gate が
# 呼ばれるたびに冒頭でリセットされるグローバルで、ACK 成立後もループは後続セグメントを
# 回るため、後続が当たらないと空へ潰れる。潰れると下の `[ -n "$FIRE_LABEL" ]` で
# ack の記録に到達せず、「抜け道通過も記録する」契約が静かに破れる（実測 2026-09-16:
# `FF_LONG_GATE_BACKGROUND_ACK=1 bash …/run-all.sh && git add …` でログ 0 行）。
ACK_LABEL=""
# 一般トリガ（明示 background）側の ack と、ログへ載せる綴り。名簿に当たらない回は
# `MATCH_LABEL` が空のままなので、先頭セグメントのコマンド名を別に確保する。
# **一般トリガの ACK は、セグメント分割にも `quotes_balanced` にも依存させない。**
# 一般トリガの deny はコマンド本文に依存せず `bg = true` だけで成立するのに、抜け道
# （ACK）の検出だけを近似パーサに預けると、パーサが落ちた回は deny が残って ack だけが
# 消える — 案内した唯一の復帰手段が無音で効かなくなる（実測 2026-09-17:
# `FF_LONG_GATE_BACKGROUND_ACK=1 python3 -c 'import x; print(1)'` は、先頭セグメントが
# 未閉鎖クォートになるため `SEG_ACK` が一度も計算されず deny のままだった）。
# ヘッダの「案内の無い deny は詰まりになる」は、**案内はあるが no-op** という形でも破れる。
#
# 判定は deny 本文の案内（「**先頭セグメントの先頭**へ付ける」）と同じ位置に限る。
# roster 側の「ゲートを実行するセグメントの先頭」とは規則が違うが、一般トリガには
# 「ゲートのセグメント」に相当するものが無いので、狭いほうへ揃えて案内と一致させる。
ANY_ACK=0
case "$code_only" in
  FF_LONG_GATE_BACKGROUND_ACK=1[[:space:]]*) ANY_ACK=1 ;;
esac
BG_LABEL=""
BG_LABEL_N=0
SEG_N=0
while IFS= read -r seg; do
  SEG_N=$((SEG_N + 1))
  [ "$QUOTED" -eq 1 ] && [ "$SEG_N" -gt 1 ] && continue
  [ -n "$seg" ] || continue
  # 段 3。名簿の綴りが無いセグメントも、明示 background の回だけは走査する
  # （ack の検出と、記録へ載せるコマンド名の確保に要る）。
  if [ "$bg" != "true" ] && ! has_roster_spelling "$seg"; then continue; fi
  quotes_balanced "$seg" || continue
  # 注意（名簿を拡張するとき）: 名簿の綴りで絞る前置フィルタは **3 段**ある —
  #   1. 生の `$input`（jq より前のコストフィルタ）
  #   2. heredoc 除去後の `$code_only`
  #   3. この**セグメント単位**の 1 行
  # 3 段とも `has_roster_spelling` を通すので、綴りの追加は `LONG_GATE_ROSTER` の
  # 1 行だけで全段に効く。段を直書きへ戻すと、一部だけ広がって新しい綴りが
  # `scan_long_gate` へ到達しない状態が静かに戻る（変異 MN2〜MN4 が針）。
  # **1 段目を削除しても検査は 1 本も赤くならない**（純粋な速度目的で、落とすのは通して
  # よい入力だけ）— 削除方向は変異注入で測れない層なので、ここに数として明記しておく。
  set -f
  # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
  SEG_TOKS=($seg)
  set +f
  skip_command_prefixes
  # ---- F2: ラベルは先着で確定させない ------------------------------------------
  # `resolve_segment_label` の存在理由は「観測台帳で再発をクラス別に数える」ことなので、
  # `cd /repo && bash …/verify.sh` で `any:cd` になっては目的を外す（実測 2026-09-17）。
  # 無害な先頭語の allowlist は作らない（同じ理由で 1 度削った経緯がヘッダ M6 に在る）。
  # 走査したセグメントの名前を順に、重複を除いて最大 3 件まで連ねる。
  if [ "$BG_LABEL_N" -lt 3 ] && resolve_segment_label && [ -n "$CMD_LABEL" ]; then
    case "|${BG_LABEL}|" in
      *"|${CMD_LABEL}|"*) : ;;
      *) BG_LABEL="${BG_LABEL:+$BG_LABEL|}${CMD_LABEL}"; BG_LABEL_N=$((BG_LABEL_N + 1)) ;;
    esac
  fi
  has_roster_spelling "$seg" || continue
  if scan_long_gate; then
    if [ "$SEG_ACK" -eq 1 ]; then ACKED=1; ACK_LABEL="$MATCH_LABEL"; else FIRE_LABEL="$MATCH_LABEL"; break; fi
  fi
done <<EOF
$segments
EOF

# ---- 発火判定 -----------------------------------------------------------------

# 記録は deny のときだけでなく ack で素通ししたときも残す（「対策後 0 件」を数える
# 母集団から、抜け道で通った回が静かに落ちないようにする）。
record() { # <verdict> <detail>
  local dir file ts
  dir="${TMPDIR:-/tmp}"
  # TMPDIR は末尾スラッシュ付きで来る環境がある（macOS の既定）。二重スラッシュの
  # パスを deny 本文へ載せると、利用者が手で開くときに紛れるので落とす。
  while [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done
  [ -n "$dir" ] || dir="/tmp"
  dir="$dir/ff-dev-toolkit-delegation-guard"
  mkdir -p "$dir" 2>/dev/null || return 0
  case "$session_id" in
    ""|*/*|*..*) file="$dir/unknown-session.log" ;;
    *) file="$dir/${session_id}.log" ;;
  esac
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || ts="?"
  # 追記に**成功したときだけ** LOG_PATH を立てる。失敗しても deny 本文が
  # 「発火の記録: <path>」と言い切ると、存在しないファイルを案内することになる。
  printf '%s\t%s\tagent_type=%s\tagent_id=%s\t%s\n' \
    "$ts" "$1" "$agent_type" "$agent_id" "$2" >> "$file" 2>/dev/null && LOG_PATH="$file"
}
LOG_PATH=""

# ack の記録はトリガ判定の後ろで行う（下）。ここで記録すると、発火条件を 1 つも
# 満たしていない完全適合の呼び出し（foreground かつ timeout 適合）まで `ack` に
# 計上され、「対策後の発生回数」を数える母集団が汚れる。
ACK_ONLY=0
if [ "$ACKED" -eq 1 ] && [ -z "$FIRE_LABEL" ]; then
  ACK_ONLY=1
  # 名簿は 2 件（`run-all.sh` / `run-mutations.sh`）なので、ここを直書きにすると ack 側の
  # 記録だけが綴りの追随から漏れる。判定が入れた綴りをそのまま使う。
  # ただし読むのはループ中に確保した `ACK_LABEL` で、走査が終わった後の
  # `MATCH_LABEL` ではない（上の理由）。
  FIRE_LABEL="$ACK_LABEL"
fi

# ---- 一般トリガ: 明示 background は名簿に依らず止める --------------------------
#
# 名簿は「そのコマンドが foreground 上限を超えるか」の**予測**である。予測できない
# 綴り（`verify.sh` のように suite ごとに所要が違う共通入口）は名簿へ載せられない。
# だが `run_in_background: true` は予測ではなく、委譲先が**明示的に**「待たない」を
# 選んだという事実そのもので、判定材料はコマンド本文ではなく構造化フィールド 1 つ
# しかない。したがってこのトリガには、名簿を狭く保っている理由（コマンド本文の
# 近似解析が生む誤検知）が 1 つも掛からない。
#
# ハーネスの**自動** background 化（`timeout` 未指定・過少）は依然として名簿に縛られる。
# そちらは所要時間の予測が要り、一般化すると `timeout` を書かない短いコマンドが
# すべて deny になるため（既知の限界 A に記載）。
GENERAL=0
if [ -z "$FIRE_LABEL" ] && [ "$bg" = "true" ]; then
  GENERAL=1
  FIRE_LABEL="any:${BG_LABEL:-command}"
  [ "$ANY_ACK" -eq 1 ] && ACK_ONLY=1
fi
[ -n "$FIRE_LABEL" ] || exit 0

REQUIRED_MS="${FF_LONG_GATE_FOREGROUND_TIMEOUT_MS:-600000}"
case "$REQUIRED_MS" in
  ''|*[!0-9]*) REQUIRED_MS=600000 ;;
esac

TRIGGER=""
if [ "$bg" = "true" ]; then
  TRIGGER="run_in_background"
elif [ -z "$timeout_ms" ]; then
  TRIGGER="timeout-absent"
else
  case "$timeout_ms" in
    ''|*[!0-9]*) TRIGGER="" ;;
    *) [ "$timeout_ms" -lt "$REQUIRED_MS" ] && TRIGGER="timeout-too-short" ;;
  esac
fi
[ -n "$TRIGGER" ] || exit 0

if [ "$ACK_ONLY" -eq 1 ]; then
  # 抜け道で通った回。**発火条件を満たしていたときだけ**記録する（上の理由）。
  record "ack" "trigger=${TRIGGER} gate=${FIRE_LABEL} timeout=${timeout_ms:-none}"
  # 記録できなかったときだけ警告する。deny は本文がエージェントへ届くので気づけるが、
  # ack は素通しなので、書けなければ**どこにも痕跡が残らないまま許可**される。
  # 「数える手段の無い 0 は主張できない」が、失敗時に無言で崩れるのを止める。
  [ -n "$LOG_PATH" ] || \
    echo 'ff-dev-toolkit: delegation-guard log unavailable; the ACK bypass was NOT recorded' >&2
  exit 0
fi

record "deny" "trigger=${TRIGGER} gate=${FIRE_LABEL} timeout=${timeout_ms:-none}"

case "$TRIGGER" in
  run_in_background)
    why="\`run_in_background: true\` で起動しようとしています" ;;
  timeout-absent)
    why="Bash ツールの \`timeout\` が未指定です（ハーネスの既定は foreground 上限より短く、超えたコマンドは自動で background へ回されます）" ;;
  *)
    why="Bash ツールの \`timeout\` が ${timeout_ms} ms で、要求値 ${REQUIRED_MS} ms より短いです（超えた分は自動で background へ回されます）" ;;
esac

if [ "$GENERAL" -eq 1 ]; then
  reason="⚠️ ff-dev-toolkit guard（委譲先は自分で起こしたコマンドを foreground で待つ）: \`${BG_LABEL:-このコマンド}\` を ${why}。
background へ回された委譲先は「完了通知を待つ」と言って停止し、親がナッジするまで再開しません（観測台帳 OBS-036。7 回再発）。7 回目は名簿の綴り（全件ゲート）ではなく、変異を当てながら個別 suite を繰り返し回すループでした — 所要時間はコマンド名から予測できないので、\`run_in_background: true\` という**明示の意思表示**の側で止めます。
次のいずれかで再実行してください:
  1) foreground で待つ（推奨）: Bash ツールの \`run_in_background\` を外し、\`timeout\` に \`${REQUIRED_MS}\` を明示する
  2) foreground 上限に収まる粒度へ分割する（変更した suite を単体で緑にしてから全件ゲートは 1 回だけ）
  3) それでも background で起こす必要がある場合は、監視機構を armed してから停止し完了通知で再開する運用に切り替えたうえで、**先頭セグメントの先頭**へ環境代入 FF_LONG_GATE_BACKGROUND_ACK=1 を付けて再実行する
このガードは委譲先（サブエージェント）の呼び出しだけに掛かります。親（メインセッション）の意図的な background 運用は構造的に対象外です。ガードごと止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD=1 を設定します。"
else
  reason="⚠️ ff-dev-toolkit guard（委譲先は長時間ゲートを foreground で待つ）: 長時間ゲート \`${FIRE_LABEL}\` を ${why}。
background へ回された委譲先は「完了通知を待つ」と言って停止し、親がナッジするまで再開しません（観測台帳 OBS-036。7 回再発）。同時に複数の子が同じ全件ゲートを background で起こすと CPU 競合で他の子まで巻き込みます。
次のいずれかで再実行してください:
  1) foreground で待つ（推奨）: Bash ツールの \`run_in_background\` を外し、\`timeout\` に \`${REQUIRED_MS}\` を明示する
  2) ゲートを foreground 上限に収まる粒度へ分割する（変更した suite を単体で緑にしてから全件ゲートは 1 回だけ）
  3) それでも background で起こす必要がある場合は、監視機構を armed してから停止し完了通知で再開する運用に切り替えたうえで、**ゲートを実行するセグメントの先頭**へ環境代入 FF_LONG_GATE_BACKGROUND_ACK=1 を付けて再実行する（判定はセグメントごとなので、\`cd /repo && bash …/run-all.sh\` なら \`cd /repo && FF_LONG_GATE_BACKGROUND_ACK=1 bash …/run-all.sh\` のように**ゲート側**へ置く。コマンド 1 本だけなら先頭がそのままゲートのセグメントになる）
このガードは委譲先（サブエージェント）の呼び出しだけに掛かります。ガードごと止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD=1 を設定します。"
fi

if [ -n "$LOG_PATH" ]; then
  reason="${reason}
発火の記録: ${LOG_PATH}"
fi

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null

exit 0
