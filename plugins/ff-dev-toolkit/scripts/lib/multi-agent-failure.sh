#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: 失敗の 1 行診断・CLI 側の失敗理由の切り分け・プロンプト超過の診断・案内の言い回し。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── One-Line Failure Diagnosis ──
# $TIMEOUT is the limit that actually applied — no CLI is capped below it any
# more (see "Timeout policy (no per-CLI caps)" in multi-agent.sh), so this function does not need to know
# which CLI failed. Re-introducing a cap means taking `cli_name` back as a
# parameter (both call sites have it) and reporting the capped number rather
# than the run-wide one: naming a deadline that never existed sends the user
# after the wrong remedy.
# 124 is run_with_timeout's timeout status (see adapters/adapter-common.sh).
# 125 は ORCHESTRATOR_ERROR_EXIT_CODE（adapters/adapter-common.sh）。CLI が返しうる
# 番号とは重ならない位置に置いてあり、意味は「壊れているのは CLI ではなくこちら側」
# （成果物の出力先が書けない・ラッパー自身が起動に失敗した）。素の
# `Failed (exit code: 125)` に丸めると、読み手は CLI のクラッシュを追い始める。
report_task_failure() {
  local task_name="$1" rc="$2"
  if [[ "$rc" -eq 124 ]]; then
    echo "  ❌ Timed out after ${TIMEOUT}s: ${task_name}" >&2
  elif [[ "$rc" -eq 125 ]]; then
    echo "  ❌ Orchestrator-side failure, not the CLI's: ${task_name} (exit code: ${rc} — see the adapter's ERROR above)" >&2
  else
    echo "  ❌ Failed: ${task_name} (exit code: ${rc})" >&2
  fi
}

# ── CLI 側の失敗理由の切り分け（Issue `#659`） ──
#
# Issue `#1148` で 3 つ目の分類 `argv` を足した。プロンプトは Issue `#712` 以降 argv に
# 乗らない（materialize_prompt_file → stdin / --prompt-file）ので、E2BIG は
# 「diff が大きいから」では起きなくなったが、起きたときの 1 行が
# 「exit code: 126」だけだと、CLI 側のクラッシュと区別が付かない。実測（公開
# feel-flow/ff-dev-toolkit#55、0.36.0 / macOS ARG_MAX 1,048,576 に 2,129,295 バイトの
# diff）では 3 CLI が同じ行で落ち、利用者は --timeout を延ばす方向へ倒れた —
# 起動前に失敗しているので時間では直らない。分類を持てば「起動できていない」と
# 名指しできる。
#
# 実測（1 セッションで 3 回の失敗 dispatch）: codex の OAuth 切れ（401、websocket
# 再接続 5 回のあと失敗）→ 再ログイン後にクレジット切れ（"Your workspace is out of
# credits"）→ grok の 402（"Grok Build usage balance exhausted"）。どれも「時間を
# 足しても直らない失敗」として同じ 1 行に丸められるため、**認証を直せば同じ CLI で
# 続けられる**のか**この CLI では今日もう何も走らない**のかが読めず、代替 CLI へ
# 切り替える判断が 3 往復ぶん遅れた。
#
# なぜ dispatch 前の preflight probe を採らなかったか（Issue `#659` の提案そのもの）。
# 4 CLI の実提供機能を実測して判断した:
#   codex-cli   … `codex login status` あり。保存済み資格情報を読んで
#                 "Logged in using ChatGPT" / "Not logged in"（rc=1）を返す
#   claude-code … `claude auth status` あり。保存済み資格情報を JSON
#                 （loggedIn / authMethod / subscriptionType）で返す
#   grok-cli    … status 系サブコマンド無し（`login` / `logout` のみ）= probe 対象外
#   copilot-cli … 同上（`login` のみ。`copilot help billing` は静的なヘルプ話題）
# 決め手は 2 つ。(1) **残高・クレジットを報告する手段がどの CLI にも無い** —
# 実測 3 件のうち 2 件（workspace out of credits / usage balance exhausted）は
# 課金される API 呼び出しをしない限り観測できず、それを preflight でやるのは
# 「レビュー 1 回ごとに余計な API 呼び出しをしない」という本 Issue の制約そのものを
# 破る。(2) 残る 1 件（OAuth 切れ）も上の 2 コマンドでは陰性になる — どちらも
# **保存されている**資格情報を読むだけで、サーバ側で失効した token を "logged in" と
# 報告する（実測 0.16s / 0.23s。ネットワーク往復を含む所要ではない）。つまり probe が
# 陽性を返せるのは「一度もログインしていない」という利用者が既に知っている状態だけで、
# 実測した 3 件のどれも捕まえられない。4 CLI 中 2 つは probe 自体が無いので、いずれに
# せよ失敗側の切り分けが必要になる。
#
# そこで preflight ではなく**失敗時の切り分け**で AC を満たす。判定材料は成果物に
# 保全済みの CLI stderr（adapter-common.sh の fail_cli_task が `### CLI stderr` 節へ
# 書く）だけで、追加のプロセスもネットワークも課金も発生しない。
#
# 走査は stderr 節に限る。ファイル全体を見ると、レビュー本文が引用した "401" や
# "credits" で誤判定する（この成果物は失敗した実行の**部分出力**を保全している）。
# **🔑 / 💳 が出ないことは「認証・課金の問題ではない」の証拠にはならない。** stderr の
# 抜粋は末尾 4KB に頭打ちされる（adapter-common.sh の tail -c）ので、再接続リトライで
# 末尾が埋まった回は先頭の 401 が抜粋外に落ちる。分類は「出たら手がかり」であって
# 「出なければ無関係」ではない — 陰性を根拠に切り分けを打ち切らないこと。
#
# 判定不能は空文字を返す = 従来どおりの案内に落ちる fail-open。誤った断定は
# 「認証を直しに行ったが実際はクラッシュだった」形の遠回りを生むので、
# 迷ったら分類しない側へ倒す。
## ── モデル側のプロンプト超過（公開 feel-flow/ff-dev-toolkit#95）──
#
# 5 つ目の分類 `prompt-too-long`。E2BIG（`argv`）が「OS が起動を拒んだ」なのに対し、
# こちらは「CLI は起動してモデルへ送ったが、モデルがリクエストごと拒否した」形で、
# 実測（公開 `#95`、`git diff origin/develop | wc -c` = 8,048,710 / 525 files）では
# 3 CLI が同時に落ちた。auth / billing / argv と違うのは**原因が CLI 側ではなく
# レビュー対象側にある**点で、同じ CLI を再実行しても代替 CLI へ振っても直らない。
#
# 出力先と文言が CLI ごとに違うので、走査面を 2 つ持つ:
#   codex-cli   … stderr。API 由来の拒否をそのまま stderr へ流す（実測: stdout が
#                 空で stderr にだけ材料が出た）。stderr 節は CLI 自身のチャネル
#                 なので、auth / billing と同じく無条件の語彙照合でよい。
#   claude-code … stdout。`API Error: 400 {"type":"error","error":
#                 {"type":"invalid_request_error","message":"Prompt is too long…"}}`
#                 の形で出て、成果物では「部分出力」として保全される（実測: 公開
#                 `#95` の 3 CLI のうち claude-code はこの形だった）。
#   grok-cli / copilot-cli … 本 Issue の時点で超過の実測を再現できていない。両者とも
#                 上流 API のエラーメッセージを素通しするので、同じ語彙表
#                 （context length / token limit / too long）で拾える見込みだが、
#                 **見込みであって実測ではない**。外れた回は空文字＝従来案内へ落ちる。
#
# **語彙だけでは判定しない。** どちらの走査面にも、その語を「話題として」書いた行が
# 混ざる — 保全されるのはレビュー本文であり（このリポジトリのソース・docs・テストは
# 現にその語を含む）、stderr にも進捗・デバッグ行が流れる。そこで語彙を 2 段に割り、
# 面ごとに要求を変える:
#
#   canonical … `prompt is too long` / `prompt too long`。モデルの拒否文そのもので、
#               他の意味で書かれることが実質ない。stderr 側では単独で採る。
#   broad     … context length / input too large / token limit 等。単独では日常語に
#               近いので、**同じ行に API エラーらしさの語**が並ぶことを要求する。
#
# `token limit` はとくに危険で、`monthly token limit`（= プラン・残高の上限）が同じ語を
# 使う。プロンプト長の話であることを示す `context` / `prompt` / `input` が同じ行に
# 並ぶことを追加で要求し、billing の材料を奪わない。
#
# 部分出力（stdout）側はさらに**行の形**でも絞る。実測の claude-code 形は
# `API Error: 400 {...}` のように行頭がエラーの体裁になっており、レビュー本文の
# 箇条書き（`- Suggestion: … prompt is too long …`）はそうならない。行頭アンカーを
# 掛けてから語彙と文脈語を見ることで、この suite 自身の fixture のような「生きた
# 誤診源」を構造で外す。閉じた側の代償は偽陰性 = 従来案内で、これは今日の挙動と同じ。
_PROMPT_TOO_LONG_CANONICAL_RE='prompt is too long|prompt too long'
_PROMPT_TOO_LONG_RE='prompt is too long|prompt too long|input is too long|input too large|request too large|too many tokens|context_length_exceeded|request_too_large|(maximum|max) context (length|window)|context (length|window) (exceeded|limit)|exceeds? the ((model|models|model.s) )?context (window|length)|(context|prompt|input).*token limit|token limit.*(context|prompt|input)'
# 「その行が API のエラーとして出た」ことの目印。canonical 以外の語彙は、これと同じ行に
# 並ぶことを要求する（stderr 側・部分出力側の共通条件）。
_PROMPT_TOO_LONG_CONTEXT_RE='api error|invalid_request_error|request_too_large|context_length_exceeded|invalid request|bad request|refused|rejected|too large|\berror\b|error[^a-z0-9]{0,4}(400|413)|(http|status|code)[^0-9]{0,10}(400|413)'
# 部分出力側でだけ掛ける行頭アンカー。CLI / API が吐いたエラー行の体裁を列挙する。
# レビュー本文の箇条書き・散文・引用（`- `, `> `, `  1. ` 等）はここで落ちる。
_PROMPT_TOO_LONG_ERRLINE_RE='^[[:space:]]{0,4}(api error|stream error|error|fatal|request failed|unhandled|\{"(type|error)"|\[error\])'

# 語彙照合の本体。面によって要求を変える。
#   stderr  … canonical は単独可（CLI 自身のチャネルで、そこに拒否文がそのまま出る）。
#             それ以外の語彙は文脈語との同一行共起を要求する。
#   partial … 行頭がエラーの体裁である行だけに絞ってから、**canonical も含めて**
#             文脈語との同一行共起を要求する。保全されるのはレビュー本文なので、
#             canonical をそのまま引用した行が来うるため。
# grep を 2 段のパイプにしないのは、前段が早期終了で EPIPE を受けて pipefail 下の
# rc=141 が「不一致」に化けるため（argv / billing の項と同じ理由）。
prompt_too_long_matches() { # <text> <stderr|partial> → rc 0 で一致
  local text="$1" surface="$2" both err_lines
  both="((${_PROMPT_TOO_LONG_RE}).*(${_PROMPT_TOO_LONG_CONTEXT_RE}))|((${_PROMPT_TOO_LONG_CONTEXT_RE}).*(${_PROMPT_TOO_LONG_RE}))"
  if [[ "$surface" == "stderr" ]]; then
    grep -qiE "$_PROMPT_TOO_LONG_CANONICAL_RE" <<<"$text" && return 0
    grep -qiE "$both" <<<"$text" && return 0
    return 1
  fi
  err_lines="$(grep -iE "$_PROMPT_TOO_LONG_ERRLINE_RE" <<<"$text")" || return 1
  [[ -n "$err_lines" ]] || return 1
  grep -qiE "$both" <<<"$err_lines" && return 0
  return 1
}
# モデル非対応の語彙。行頭がエラーの体裁である行（プロンプト超過と同じ
# _PROMPT_TOO_LONG_ERRLINE_RE）に絞ってから照合する。語彙は実測の codex 形
# （`is not supported when using Codex with`）と、API が返す汎用の形（model_not_found /
# does not exist / unknown model）。
# 語彙は実測の形と、アカウントの提供範囲を言う API の定型（does not exist or you do not
# have access）だけに絞る。`unknown model` / `is not available` のような広い語は、モデル名の
# typo や一時的な容量不足（try again）まで「利用不可 = 主担当のみで完了」へ倒すので採らない。
# 一時的であることを言う行（try again / temporarily / overloaded / capacity）は除く。
_MODEL_UNSUPPORTED_RE='is not supported when using|does not exist or you do not have access'
_MODEL_UNSUPPORTED_TRANSIENT_RE='try again|temporar|overload|capacity|currently unavailable'
model_unsupported_matches() { # <stderr-text> → rc 0 で一致
  local err_lines hits
  err_lines="$(grep -iE "$_PROMPT_TOO_LONG_ERRLINE_RE" <<<"$1")" || return 1
  [[ -n "$err_lines" ]] || return 1
  hits="$(grep -iE "$_MODEL_UNSUPPORTED_RE" <<<"$err_lines")" || return 1
  grep -viqE "$_MODEL_UNSUPPORTED_TRANSIENT_RE" <<<"$hits"
}
classify_cli_failure_cause() { # <result-file> [tail] → "auth" | "billing" | "model-unsupported" | "argv" | "prompt-too-long" | ""
  # 第 2 引数 tail: stderr 節の**末尾 5 行**（空行を除く）だけで分類し、部分出力側は見ない。
  # 「利用不可 = 主担当のみで完了」の判定（collect_unavailable_cross_tasks）専用。CLI 自身の
  # 最終エラーは stderr の末尾に出る — codex は stderr へセッションの推論・ツール出力も流す
  # ので、節全体を見ると、レビュー本文が「401 unauthorized」「usage limit」に触れただけで
  # 利用不可に化け、途中失敗が 0 終了になる。案内・スキップは従来どおり節全体で分類する。
  local file="$1" mode="${2:-}" stderr_section="" partial_section="" tail_n=0
  [[ -f "$file" ]] || return 0
  [[ "$mode" == "tail" ]] && tail_n=5
  # アダプタが**末尾へ**付ける stderr 節の、コードフェンスの中身だけを取る。
  # 最初の `### CLI stderr` から EOF まで取ると、保全された部分出力がその見出しを
  # 引用している回（このリポジトリのレビュー結果は現にこの文字列を書く）に、
  # レビュー本文の "401" や "credits" を stderr と誤読して分類が化ける。
  #
  # 節の特定は**ファイル末尾の閉じフェンス**から逆に辿る。アダプタは抜粋中の最長の
  # バッククォート列より長いフェンスで囲むので、そのフェンス行と同じ行は抜粋の中に
  # 現れない — 「見出し・空行・同じフェンス行」の並びは本物の節の開始だけになる。
  # 最後の見出しを採る方式だと、codex がエコーしたプロンプト（前回のレビュー結果を
  # 引用しうる）の中の見出しを掴む。末尾がフェンスで終わらない成果物（固定 ``` の旧形式・
  # 後から注記を足したもの）は従来どおり最後の見出しから読む。
  #
  # さらに、プロンプトの終端行（build_prompt の最終行）の**最後の**出現より後ろだけを
  # 見る。codex は stderr へプロンプトをエコーし、プロンプトはレビュー対象の diff を
  # 含む — diff の "unauthorized" や "credits" を CLI 自身の失敗と読むと、利用不可の
  # 分類（= 主担当のみの完了）へ化ける。最後の出現を使うのは、diff 自体がこの行を
  # 含みうるため（本物の終端は常に diff より後ろにある）。終端行が無ければ全体を見る
  # （エコーしない CLI・抜粋が終端より後ろだけを切り取った回）。
  # LC_ALL=C: 抜粋はバイト数で切られており、不正な UTF-8 を含みうる（バッククォートと
  # 終端行の照合はバイト単位で足りる）。
  stderr_section="$(LC_ALL=C awk -v sentinel="$PROMPT_END_SENTINEL" -v tail_n="$tail_n" '
    /^### CLI stderr/ { start = NR }
    { line[NR] = $0 }
    END {
      from = 0; to = 0
      last = NR
      while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--
      if (last > 3 && line[last] ~ /^````*$/ && length(line[last]) >= 3) {
        f = line[last]
        for (i = 3; i < last; i++)
          if (line[i] == f && line[i - 1] == "" && line[i - 2] ~ /^### CLI stderr/) { from = i + 1; to = last - 1; break }
      }
      if (!from) {
        if (!start) exit 0
        fence = ""
        to = NR
        for (i = start + 1; i <= NR; i++) {
          if (fence == "") {
            if (line[i] ~ /^```+[[:space:]]*$/) { fence = line[i]; sub(/[[:space:]]+$/, "", fence); from = i + 1 }
            continue
          }
          t = line[i]; sub(/[[:space:]]+$/, "", t)
          if (t ~ /^```+$/ && length(t) >= length(fence)) { to = i - 1; break }
        }
        if (fence == "") exit 0
      }
      for (i = from; i <= to; i++) if (line[i] == sentinel) from = i + 1
      if (tail_n > 0) {
        n = 0
        for (i = to; i >= from && n < tail_n; i--) if (line[i] !~ /^[[:space:]]*$/) { n++; first = i }
        if (n == 0) exit 0
        from = first
      }
      for (i = from; i <= to; i++) print line[i]
    }' "$file" 2>/dev/null)" || return 0

  # stderr 節が無くても打ち切らない。プロンプト超過は stdout 側にだけ出る CLI 形
  # （claude-code）があり、ここで return すると実測 2 形のうち片方を構造的に拾えない。
  if [[ -n "$stderr_section" ]]; then
    # exec 段の失敗を最初に見る（Issue `#1148`）。E2BIG は CLI が**起動する前**に
    # execve が返す失敗なので、そのとき stderr にはモデルの応答が 1 バイトも無い。
    # auth / billing の語彙と競合しないが、順序で意味を固定する — 起動できなかった
    # 実行を「認証が拒否された」と読ませないため。
    # 語は execve の失敗をシェル / libc が訳したもので、ロケールで揺れる。実測した
    # 英語形（bash / zsh の "Argument list too long"）に加えて E2BIG も拾う。
    # 拾えなかった回は空文字 = 従来の案内に落ちるだけで、断定はしない。
    if grep -qiE 'argument list too long|\bE2BIG\b' <<<"$stderr_section"; then
      printf 'argv\n'
      return 0
    fi

    # プロンプト超過は残高・認証より**先**に見る。順序を決めた根拠は 3 つ:
    #   1. 語彙が重ならない。canonical は拒否文そのもので、broad 側は 400 / 413 系の
    #      文脈語を要求する。billing（402 / credits）・auth（401 / credentials）とは
    #      交わらず、`monthly token limit` は文脈語の要求で ptl 側へ落ちない。
    #   2. 狭めた語彙を**検査の効く位置**に残せる。billing を先に評価すると、語彙が
    #      緩む退行が起きても billing が先に当たって症状が隠れ、テストが緑のまま通る
    #      （実測: `token limit` を素の語へ戻す変異は、この順序でのみ赤になる）。
    #   3. 意味の順序としても「そもそも受け付けられたか」が「誰の資格で送ったか」より先。
    if prompt_too_long_matches "$stderr_section" stderr; then
      printf 'prompt-too-long\n'
      return 0
    fi

    # モデル非対応。実測: codex-cli 0.153.x を ChatGPT アカウントで
    # 最新世代の上位モデルで起動すると 400 `The '<slug>' model is not supported when using
    # Codex with a ChatGPT account.`（同じアカウントで 0.157.0 は完走）。CLI の版か
    # アカウント種別のどちらかで決まり、同じ CLI・同じモデルの残りタスクも確実に同じ
    # 理由で落ちるので auth / billing と同じ「利用不可」に数える。
    # **エラー行の体裁を要求する**。同じ実測の stderr には `warning: Model metadata for
    # `<slug>` not found` が並ぶ — 警告は失敗の理由ではなく、ここで拾うと成功した回と
    # 同じ行で分類が立つ。
    if model_unsupported_matches "$stderr_section"; then
      printf 'model-unsupported\n'
      return 0
    fi

    # 残高側を先に見る。クレジット切れの応答は認証の語（unauthorized 等）を含みうるが、
    # 逆は起きない。取り違えると「再ログインすれば直る」と案内して、実際には同じ失敗を
    # もう一度引かせることになる。
    #
    # 数値ステータスは単独では見ない（stderr 抜粋に現れる "402 files" のような無関係な
    # 数字を拾う）。HTTP 文脈の語と同じ行に並んでいるときだけ採る。
    # `spend limit` / `usage limit` / `monthly limit` は利用枠の上限（単一 CLI 基準線への整合）。実測の
    # claude-code 文言 `You've hit your individual spend limit` は credits / balance の語を
    # 含まず、分類が空（従来案内）に落ちていた。基準線が主担当 1 モデルになった今（ADR-053 決定 1）は
    # billing の分類が「その回は単一で正常完了」の判定に直結するので、上限系の語も採る。
    # `weekly limit` は claude-code の実測文言 `You've hit your weekly limit · resets 8pm (Asia/Tokyo)`。
    # 同じく credits / balance の語を含まない。
    # `token limit` は採らない — `_PROMPT_TOO_LONG_RE` の `(context|prompt|input).*token limit` と重なる（`prompt_too_long_matches` の文脈語要求参照）。
    # パイプにしないのは `set -o pipefail` 下で grep -q が先頭付近で早期終了すると
    # printf が EPIPE で死に、パイプライン rc=141 が「不一致」に化けるため（実測: 先頭に
    # unauthorized を置いた 640KB 入力が LOST）。真陽性が読み解けない形で落ちる。
    if grep -qiE \
      'out of credits|no credits|insufficient credit|credit balance|balance exhausted|insufficient_quota|payment required|spend limit|spending limit|all available credits|usage limit|monthly limit|weekly limit|(http|status|code)[^0-9]{0,10}402|402[^0-9]{0,12}(payment|http|status)' <<<"$stderr_section"; then
      printf 'billing\n'
      return 0
    fi
    if grep -qiE \
      'unauthorized|not logged in|not signed in|authentication (failed|error)|invalid api key|invalid_api_key|expired (token|credential)|token (is |has )?expired|please (log ?in|sign in)|re-?authenticate|(http|status|code)[^0-9]{0,10}401|401[^0-9]{0,12}(unauthorized|http|status)' <<<"$stderr_section"; then
      printf 'auth\n'
      return 0
    fi
  fi

  # 末尾行モードは stderr だけで決める（部分出力側のプロンプト超過は利用不可ではない）
  [[ "$mode" != "tail" ]] || return 0
  # ── 部分出力側（claude-code 形）──
  # 走査範囲は最後の `### CLI stderr` 見出しより**手前**、つまりバナーと保全された
  # 部分出力。stderr 節を含めないのは二重走査を避けるためで、そちらは既に上で見た。
  partial_section="$(awk '
    { line[NR] = $0; if ($0 ~ /^### CLI stderr/) last = NR }
    END {
      end = last ? last - 1 : NR
      for (i = 1; i <= end; i++) print line[i]
    }' "$file" 2>/dev/null)" || return 0
  [[ -n "$partial_section" ]] || return 0
  # エラー行の体裁を持つ行に絞ってから、語彙と文脈語が**同じ行**に並ぶことを要求する。
  # 語彙の位置関係は決め打ちしない（`API Error: 400 … "Prompt is too long"` も
  # `prompt is too long (invalid_request_error)` も同じ事実）。
  if prompt_too_long_matches "$partial_section" partial; then
    printf 'prompt-too-long\n'
    return 0
  fi
  # 利用枠切れの claude-code 形。`claude -p` は API エラーを stdout へ出す
  # ことがある（上のプロンプト超過と同じ形）ので、stderr 側の語彙だけでは拾えない回が
  # ある。部分出力はレビュー本文でもありうる（告知文をフェンスや引用で載せた本文に当たる
  # と、同じ CLI の残りの観点を誤ってスキップしてレビューごと失う）ので、照合するのは
  # **CLI 出力の最初の非空行**（成果物の「Partial output captured …」見出しの直後）が
  # 告知文の体裁（`You've hit your … limit`）で始まる回だけに限る。
  # この分類は案内（💳 / 🤝）と同じ CLI の残りタスクのスキップに効く。末尾行モード
  # （「主担当のみで完了」の判定）はここまで来ないので、そちらには数えない。
  local first_output_line
  first_output_line="$(LC_ALL=C awk '
      found && $0 !~ /^[[:space:]]*$/ { print; exit }
      /^Partial output captured before the CLI was stopped:$/ { found = 1 }
    ' <<<"$partial_section" 2>/dev/null)" || first_output_line=""
  if grep -qiE "^(you've|you have) hit your [[:alpha:] ]*limit" <<<"$first_output_line"; then
    printf 'billing\n'
    return 0
  fi
  return 0
}

# ── レビュー対象 diff の実測値（公開 feel-flow/ff-dev-toolkit#95）──
#
# プロンプト超過の案内に添える材料。オーケストレータは既にこの実行の diff を
# 1 ファイルへ固定している（create_fixed_diff）ので、そのバイト列を数えるのが
# **実際にプロンプトへ載ったもの**の唯一正しい実測になる。実行後に diff を
# 取り直すと、レビュー中に作業ツリーが動いた回に別の数字を報告する。
#
# **固定 diff が無い経路（--include-diff なしの explore / implement）では測らない。**
# numstat へ落ちると「送っていない diff」のファイル数を、送ったものとして名指しする
# ことになる。空文字を返し、呼び出し側の「no fixed diff for this task type」分岐へ渡す。
#
# **計測は親シェルで 1 回だけ。** 値を返す関数を `$(...)` で呼ぶと、command
# substitution は subshell なのでキャッシュが親へ残らず、失敗タスクごとに固定 diff を
# 舐め直す（実測の diff は 8,048,710 bytes）。出力側は ensure_diff_size_summary を
# 呼んでから **$DIFF_SIZE_SUMMARY を直接読む**。
DIFF_SIZE_SUMMARY=""
DIFF_SIZE_SUMMARY_COMPUTED=false
ensure_diff_size_summary() { # DIFF_SIZE_SUMMARY を "N bytes across M changed file(s)" | "" にする
  [[ "$DIFF_SIZE_SUMMARY_COMPUTED" == "true" ]] && return 0
  DIFF_SIZE_SUMMARY_COMPUTED=true
  local bytes="" files=""
  [[ -n "$FIXED_DIFF_FILE" && -r "$FIXED_DIFF_FILE" ]] || return 0
  bytes="$(wc -c < "$FIXED_DIFF_FILE" 2>/dev/null | tr -d '[:space:]')" || bytes=""
  # 読めなかった回に 0 と書くと、観測していないものを観測したことにする。
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  # 固定 diff は `BASE...HEAD` と作業ツリー分の**連結**（get_diff_content）なので、
  # 両方に現れたファイルはヘッダー行が 2 度出る。素の件数だとそれを 2 個と数え、
  # 案内が実際より大きなファイル数を名指しする。ヘッダー行はパス対ごとに一意なので、
  # 行を dedup してから数えれば distinct なファイル数になる。
  # `grep` は 0 件で rc=1 を返す（= 変更 0 件という正当な観測）ので rc は見ない。
  files="$( { grep '^diff --git ' "$FIXED_DIFF_FILE" 2>/dev/null || true; } | sort -u | wc -l | tr -d '[:space:]')" || files=""
  if [[ "$files" =~ ^[0-9]+$ ]]; then
    DIFF_SIZE_SUMMARY="${bytes} bytes across ${files} changed file(s)"
  else
    DIFF_SIZE_SUMMARY="${bytes} bytes (changed-file count not measured)"
  fi
  return 0
}
# この実行が「プロンプト超過で全滅した」と言ってよいか（公開 feel-flow/ff-dev-toolkit#95）。
#
# 全滅は個別の失敗の集合ではなく 1 つの事実 —「レビュー対象が大きすぎる」。個別の
# 再実行コマンドだけを並べると、利用者は CLI を 1 つずつ試す方向へ倒れる（実測では
# 原因に辿り着くまで 3 回分の実行を空費した）。全滅を検出できたときだけ、再実行
# コマンドより**先に**対象側を見よと言う。
#
# 条件は「全 executed task が prompt-too-long に分類された」ではない。それだと、
# 動機になった事故（codex が stdout 空 + stderr に diff 断片だけを残した回）で
# 案内が出ない — 分類器が材料不足で空文字を返した 1 タスクが、他の全タスクが
# 名指しで超過を言っていても案内を丸ごと消してしまう。そこで:
#
#   - prompt-too-long が 1 件以上（言うべき事実が実在する）
#   - **別原因**に分類された task が 0（auth / billing / argv が混ざっていれば全滅ではない）
#   - 成功 0 / skip 0（走って通った観点、走らなかった観点があれば全滅ではない）
#   - 分類不能（空文字）は阻害しない。**別原因ではない** — 材料が無いだけで、
#     それを「違う原因だった」と読むのは観測していないことの断定になる
#   - rc=124（時間切れ）の task は集計から外し、かつ全滅とは言わない。個別層は
#     124 に対して原因を断定しない（print_failure_advice は cause を空へ倒す）ので、
#     run-wide が代わりに断定してはいけない。時間切れた観点は「送る前に断られた」
#     とは限らず、途中まで走っていた可能性が残る
#
# 分母は「この実行が走らせたタスク」。前回結果を再利用したタスク（REUSED_TASKS）は
# 除く — 走っていないものの成否で全滅判定を左右させない。
prompt_too_long_run_wide() {
  [[ -n "$FAILED_TASKS" ]] || return 1
  # スキップは実行の欠落。今日はスキップの理由が auth / billing に限られるため下の
  # 別原因判定でも落ちるが、条件としては独立に持つ（スキップ可能な原因が増えたとき、
  # 「走らなかった観点があるのに全滅と言う」形が静かに開かないように）。
  [[ -z "$SKIPPED_TASKS" ]] || return 1
  [[ -n "$EXECUTION_PLAN" ]] || return 1
  local entry cli persp seen="" hits=0 cause rc
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ " $seen " == *" $entry "* ]]; then continue; fi
    seen="$seen $entry"
    cli="${entry%%:*}"
    persp="${entry#*:}"
    if list_contains "$REUSED_TASKS" "${cli}/${persp}"; then continue; fi
    # 成功したタスクが 1 つでもあれば全滅ではない
    task_left_perspective_unproven "$cli" "$persp" || return 1
    rc="$(failed_task_rc "$cli" "$persp")"
    [[ "$rc" == "124" ]] && return 1
    cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${cli}/${persp}.md")"
    case "$cause" in
      prompt-too-long) hits=$((hits + 1)) ;;
      "") : ;;   # 分類不能。別原因ではないので阻害しない
      *) return 1 ;;
    esac
  done <<< "$EXECUTION_PLAN"
  [[ "$hits" -gt 0 ]]
}

# 失敗として記録された rc（FAILED_TASKS は `<cli>/<persp>:<rc>` 形）。記録が無ければ空。
failed_task_rc() { # <cli> <perspective>
  local entry prefix="${1}/${2}:"
  for entry in $FAILED_TASKS; do
    if [[ "$entry" == "$prefix"* ]]; then
      printf '%s\n' "${entry##*:}"
      return 0
    fi
  done
  return 0
}
# 全滅時の案内本文。stdout（stderr ストリーム）と統合レポートの両方が同じ文面を使う
# — 片方だけに置くと、レポート経由で結果を読む消費者か、端末を見ている利用者の
# どちらかがこの 1 事実を受け取り損ねる。
prompt_too_long_advice_lines() {
  # 呼び出し側（親シェル）が ensure_diff_size_summary を済ませている前提。この関数は
  # process substitution 越しに呼ばれるので、ここで計測してもキャッシュが親へ残らない。
  local size="$DIFF_SIZE_SUMMARY"
  echo "Every task in this run was refused by the model for the same reason: the prompt"
  echo "was too long. Look at the reviewed diff first — re-running a CLI, giving it more"
  echo "time, or switching to the substitute CLI does not change what is being sent."
  if [[ -n "$size" ]]; then
    echo "Reviewed diff: ${size}."
  else
    echo "Reviewed diff: size could not be measured (no fixed diff for this task type)."
  fi
  echo "A diff that size is usually an accident rather than a change set: check whether"
  echo "large untracked files or build artifacts were swept into it — an earlier run's"
  echo "archived results under ${OUTPUT_DIR}/.prev-<timestamp>/ are a known source — and"
  echo "that .gitignore covers them. Shrink what is reviewed (or pass a different"
  echo "--base), then re-run."
}

# 失敗した観点の**成果物**へ実測値を書き足す（公開 feel-flow/ff-dev-toolkit#95 の AC）。
#
# アダプタは自分が拒否された理由（プロンプト超過）を保全するが、**何バイト送ったのか**
# は知らない — diff を固定したのはオーケストレータ側だから。成果物を単体で開いた
# 読み手（レポートではなく `.review-results/<cli>/<persp>.md` を見る側）が、そこで
# `git diff | wc -c` を手で打たずに済むように、持っている実測値をここで添える。
#
# 追記位置は末尾。ヘッダーの `Status: incomplete` 判定は空行までの窓しか見ないので
# 影響せず、保全された部分出力と CLI stderr 節も書き換えない（観測の改変はしない）。
# 書けなかった場合は警告して続行する — 案内が 1 行減るだけで、stdout とレポートの
# 同じ材料は残る。
annotate_result_prompt_too_long() { # <result-file>
  local file="$1" size
  [[ -f "$file" && -w "$file" ]] || return 0
  # 二重追記を避ける（同じ実行内で 2 回呼ばれることは無い想定だが、追記は冪等に）。
  grep -qF -- '<!-- prompt-too-long-diagnosis -->' "$file" && return 0
  ensure_diff_size_summary
  size="$DIFF_SIZE_SUMMARY"
  [[ -n "$size" ]] || return 0
  {
    echo ""
    echo "<!-- prompt-too-long-diagnosis -->"
    echo "### Why this failed: the prompt was too long"
    echo ""
    echo "The model refused the request itself, so nothing was looked at. The size of what"
    echo "this run sent for review, measured from the diff this run fixed for every task:"
    echo ""
    echo "- reviewed diff: ${size}"
    echo ""
    echo "Re-running this CLI, giving it more time, or switching to the substitute CLI"
    echo "sends the same bytes. Shrink what is under review instead."
  } >> "$file" || echo "WARNING: could not annotate the result file with the diff size: ${file}" >&2
  return 0
}

# 分類値を英文へ差し込む名詞句。分類値をそのまま埋めると "a auth problem" /
# "a argv problem" になる。分類を足すたびに文面が壊れるのを避けるため、語形は
# ここに 1 箇所だけ置く。未知の値でも文として成立する既定を返す（分類の追加漏れが
# 案内行の消失や壊れた英文にならないように）。
cause_phrase() { # <cause> → 英文へ差し込む名詞句
  case "$1" in
    auth)    echo "an authentication problem" ;;
    billing) echo "a credits / usage balance problem" ;;
    model-unsupported)
             echo "a model-not-supported rejection (the selected model is not available to this CLI version or account)" ;;
    argv)    echo "an argument-list-too-long (E2BIG) failure, i.e. the CLI never started" ;;
    prompt-too-long)
             echo "a prompt-too-long rejection from the model, i.e. the request was refused before any ${TASK_TYPE:-review} happened" ;;
    *)       echo "a problem it names itself" ;;
  esac
}

# 再ログインの入口は CLI ごとに違う（実測: codex / grok / copilot は `<cmd> login`、
# claude は `claude auth login`）。レジストリ（ALL_CLIS の lockstep lookup）には置かない
# — 全 CLI が答えを持つ表ではなく、既定の空文字は「案内行を 1 本出さない」という
# 無害な縮退だから。書き漏らしても診断そのものは出る。
cli_login_command() { # <cli>
  case "$1" in
    claude-code) echo "claude auth login" ;;
    codex-cli)   echo "codex login" ;;
    copilot-cli) echo "copilot login" ;;
    grok-cli)    echo "grok login" ;;
    *) echo "" ;;
  esac
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-failure.sh"
