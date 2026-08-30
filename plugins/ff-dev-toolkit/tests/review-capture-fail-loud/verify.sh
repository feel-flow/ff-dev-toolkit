#!/usr/bin/env bash
#
# review-capture-fail-loud: レビュー本文を含まない捕捉結果の fail-loud 契約（Issue #893）。
#
# 背景: 各アダプタは CLI が stdout へ出した最終出力だけを捕捉する。サブ CLI が
# レビュー本文をセッション途中のターンへ出力すると、捕捉結果には前置き・メタ記述
# （1 段落・実測 616〜761 bytes）だけが残り、exit 0 + 非空出力なので従来の
# empty-output ガードを素通りして `Status: complete` の「実質未レビュー」成果物が
# 統合レポートに完了として並んだ（#882 のセルフレビューで claude-code に観測）。
#
# 本 suite が固定するもの:
#   (1) 判定 review_body_present の受理条件（正は adapter-common.sh の同関数ヘッダ）
#       の両方向 —
#       不合格: メタ記述のみ / 参照+件数復唱文 / 実体行の無い長文（バイト長は判定に
#       使わない）/ 見出し単独 / 参照語付きラベル行 / フェンス引用の復唱 /
#       契約前の裸散文ゼロ報告 / 全文フェンス包み / 未閉フェンス+実体なし /
#       Critical: 単独（コロン後空）/ bullet 無しのラベル+エラー文
#       合格: 件数行（`CRITICAL: 0` を含む。参照注記付きでも veto されない）/
#       ゼロ件報告行（「指摘なし」等）/ ラベル付き指摘行（bullet / ** 接頭）/
#       重大度見出し配下の bullet（comprehensive-review の指摘形）/
#       契約準拠の散文+独立ゼロ行 / 未閉フェンス+実体あり（マスク放棄フォールバック）
#   (2) claude-code アダプタの実走で、本文なし結果が非 0 終了 + INCOMPLETE 成果物
#       （`Status: incomplete` ヘッダ + バナー + 捕捉出力の保全）になること。
#       --task-type 省略時の既定（review）でも同じゲートが効くこと
#   (3) 明示ゼロ報告は従来どおり exit 0 + `Status: complete` のままであること
#   (4) ゲートは review スコープ — explore の短い出力を誤検知しないこと
#   (5) ゲートが 4 アダプタ全部に常在すること（multi-agent-timeout の empty-output
#       pin と同型の行順静的検査。behavioral ケースは claude-code しか通らないため、
#       他 3 本が片側だけ旧実装へ戻る退行は静的に留める）
#   (6) build_prompt の最終メッセージ集約指示が review に載り、explore には
#       載らないこと（AC 2 の捕捉改善。task-type ゲートの両方向）
#
# LLM が集約指示に従うかは stub では測れない。ここで固定するのは検出ゲートと
# 指示の存在までで、実効性は実 CLI での完走確認を Issue / PR に記録する。
# 実 CLI・ネットワーク・課金は伴わない。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"

[ -f "$ADAPTER_COMMON" ] || {
  echo "✗ 対象ファイルが見つかりません: $ADAPTER_COMMON" >&2
  exit 1
}

# orchestrator は起動しないので抽出源はアダプタ実装のみ（lib の契約: センチネルは
# 抽出対象のソース群ごとに 1 つ。ホストの MULTI_AGENT_MODEL_CLAUDE_CODE などが
# export されているとアダプタ実走ケースの前提が崩れる）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_MODEL_CLAUDE_CODE" "$ADAPTERS_DIR"/*.sh

# mktemp の失敗理由を捨てない（adapter-prompt-guard と同じ扱い。read-only 以外の
# 原因を「書き込み可能な環境で再実行」に誤帰属させない）。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
# 途中死を沈黙させない（rc=0 なのにサマリー未到達 = 中断として扱う）。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ review-capture-fail-loud: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  if [ "$_ff_rc" -ne 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ review-capture-fail-loud: サマリー前に中断しました (rc=${_ff_rc})" >&2
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ── fixture 本文 ──────────────────────────────────────────────

# 観測された空振り（メタ記述 1 段落、構造マーカーなし）の再現。
META_ONLY="本レスポンスは read-only レビュー sub-agent の報告であり、レビュー対象の変更そのものはこのセッションでは行っていません。
レビュー報告は上記で完了しています。追加の対応が必要な場合は、指摘への修正を別セッションで実施したうえで再実行してください。
なお、本エージェントは提供された diff のみを対象としており、作業ツリーへの書き込みは行っていません。"

# 参照 + 件数復唱型: 重大度語と数値を**散文中に**含むが、レビュー本文（見出し行・
# 行頭サマリ行）は無い。旧・語彙部分一致の判定はこれを素通しした。
REF_ECHO="上記のレビューで Critical 1 件と Warning 2 件を報告済みです。詳細は前述のとおりで、本メッセージは完了報告のみです。Critical の報告は前のターンです。"

# 明示ゼロ報告（error-handler-hunt が根拠付き 0 件を返す正常系）。complete のまま。
ZERO_REPORT="## Error Handling Analysis Results

### CRITICAL Issues
- なし

### WARNING Issues
- なし

### Summary
- CRITICAL: 0
- WARNING: 0
- SUGGESTION: 0
- 根拠: 変更された catch 節・fallback は diff に存在しない"

# 見出しを持たない件数サマリ行だけの短い実指摘（行頭アンカーの合格側）。
SHORT_FINDING="Warning: 1

- stderr の破棄が早すぎる（scripts/foo.sh:12）: 失敗理由が成果物に残らない。"

# 日本語ゼロ件報告（見出しに重大度語なし・行頭のゼロ件報告行だけが合格根拠）。
JA_ZERO="## レビュー結果

指摘なし（diff 全 3 hunk を読解した。変更は fixture 追加のみで、実行経路への影響は無い）。"

# 実体行を 1 行も含まない長文（バイト長が判定を救わないこと = 旧・2000B
# 短絡の撤去を固定する）。
LONG_NO_MARKER="$(awk 'BEGIN { for (i = 0; i < 60; i++) printf "本文の検討行 %03d: 差分の読解メモをここに書き連ねる。実体行判定に掛からない中立な記述である。\n", i }')"

# 重大度見出し配下の指摘 bullet を持つ長文（長さと無関係に合格する側）。
LONG_WITH_MARKER="### Critical

$(awk 'BEGIN { for (i = 0; i < 60; i++) printf "- 指摘 %03d の詳細説明をここに書き連ねる。\n", i }')"

# comprehensive-review の Output Template どおりの指摘形（重大度ラベルの無い
# bullet が重大度見出しの配下に来る）。見出し単独拒否の巻き添えでこの正常系を
# 落とさないことを固定する。
COMPREHENSIVE_FINDING="### Critical

- **停止条件が欠けている**（\`scripts/foo.sh:10\`）
  ループの終了条件が diff の変更で失われている。

### Warning

- なし"

# 契約準拠の散文ゼロ報告（comprehensive-review へ追記した出力契約の形:
# 散文 + 独立行の件数ゼロ）。
PROSE_ZERO_CONTRACT="観点間の隙間と相互作用を中心に diff 全体を読解したが、報告すべき問題は見つからなかった。変更は fixture 追加のみで、既存の不変条件への影響は無い。

Critical: 0 / Warning: 0 / Suggestion: 0"

# 契約前の裸散文ゼロ報告（独立ゼロ行なし）— 出力契約に反する形で、受理しない。
PROSE_ZERO_BARE="観点間の隙間と相互作用を中心に diff 全体を読解したが、報告すべき問題は見つからなかった。変更は fixture 追加のみで、既存の不変条件への影響は無い。"

# 見出し単独（実体行なし）。
HEADING_ONLY="### CRITICAL Issues"

# 参照語付きラベル行（行頭は重大度ラベルの形だが、実体は前ターンへの参照）。
REF_LABEL="Critical: 詳細は前のターンです"

# フェンス引用の復唱: テンプレートの見出し・指摘をコードフェンス内に引用しただけで、
# フェンス外に実体行が無い。地の文は中立にする — 不受理の根拠が「実体行が無い」
# ことだけになり、フェンス規則の mutation（引用 bullet が実体行に化ける）を
# この fixture が確実に検出する。
FENCED_ECHO='レビューの形式は以下のとおりです。

```markdown
### Critical

- **[問題の要約]**（`path/to/file.ext:123`）
```

レビューの形式は以上のとおりです。'

check_body() { # $1: 本文 / rc: review_body_present の rc
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    review_body_present "$1"
  )
}

echo "== 行単位構造検証（review_body_present）: 不合格側 =="

if check_body "$META_ONLY"; then
  bad "メタ記述だけの捕捉結果を本文ありと判定した（#882 の空振りを素通しする退行）"
else
  ok "メタ記述だけの捕捉結果を本文なしと判定する"
fi

if check_body "$REF_ECHO"; then
  bad "参照+件数復唱文（散文中の Critical 1 件）を本文ありと誤判定した（語彙部分一致への退行）"
else
  ok "参照+件数復唱文は本文なし（散文中の重大度語・数値では合格しない）"
fi

LONG_BYTES="$(printf '%s' "$LONG_NO_MARKER" | wc -c | tr -d ' ')"
if [ "$LONG_BYTES" -lt 2000 ]; then
  bad "fixture 不備: 長文 fixture が 2000B 未満（${LONG_BYTES}B）で「長さでは救われない」検査が成立しない"
elif check_body "$LONG_NO_MARKER"; then
  bad "実体行の無い長文（${LONG_BYTES}B）を本文ありと判定した（バイト長短絡への退行）"
else
  ok "実体行の無い長文（${LONG_BYTES}B）も本文なし（バイト長は判定を救わない）"
fi

if check_body "$PROSE_ZERO_BARE"; then
  bad "独立ゼロ行の無い裸散文ゼロ報告を受理した（出力契約とゲートの契約一本化が破れている）"
else
  ok "独立ゼロ行の無い裸散文ゼロ報告は不受理（出力契約側が独立行を義務付ける）"
fi

if check_body "$HEADING_ONLY"; then
  bad "重大度見出し 1 行だけの出力を受理した（見出し単独の回避を塞げていない）"
else
  ok "重大度見出し単独は不受理（見出しはスコープを開くだけで実体行ではない）"
fi

if check_body "$REF_LABEL"; then
  bad "参照語付きラベル行（Critical: 詳細は前のターンです）を受理した（構造化参照の回避を塞げていない）"
else
  ok "参照語付きラベル行は不受理（参照行は実体行に数えない）"
fi

# ラベル行の中身検証: コロン後が空のラベル単独と、bullet も ** も持たない
# ラベル + 散文（CLI エラー文の典型形）は実体行ではない。
if check_body "Critical:"; then
  bad "コロン後が空の Critical: 単独行を受理した（中身の無いラベルが実体行に化ける）"
else
  ok "Critical: 単独（コロン後空）は不受理"
fi

if check_body "Warning: authentication expired"; then
  bad "bullet 無しの Warning: エラー文を受理した（CLI エラー行が実体行に化ける）"
else
  ok "bullet 無しの Warning: エラー文は不受理（指摘行は bullet / ** 接頭 + 非空本文が必要）"
fi

# 件数行の数値境界: 数値の直後が行末 / 空白+行末 / `/` 区切り / 「件」のときだけ
# 件数と認める。境界が無いと HTTP ステータスや 0-day のような数字入りエラー文・
# 散文が件数サマリとして受理される。
if check_body "Warning: 401 authentication expired"; then
  bad "Warning: 401 <エラー文> を件数行として受理した（数値境界の欠落）"
else
  ok "Warning: 401 <エラー文> は件数行ではない（数値の直後に本文が続く行を件数と認めない）"
fi

if check_body "Critical: 0-day exploit の兆候が依存追加に含まれている"; then
  bad "Critical: 0-day <散文> を件数行として受理した（数値境界の欠落）"
else
  ok "Critical: 0-day <散文> は件数行ではない（bullet 無しのラベル+散文として不受理）"
fi

if check_body "Critical: 3 件"; then
  ok "Critical: 3 件（数値 + 「件」）は件数行として受理"
else
  bad "Critical: 3 件 を件数行と認めない（「件」境界の欠落）"
fi

# 件数・ゼロ行は値を行内に持つ自己完結行なので、**行単位**の参照語 veto の対象外 —
# 契約準拠のゼロ報告に弱参照語の注記が付いても落とさない（3 巡目 Critical 3 の自己矛盾）。
if check_body "Critical: 0 / Warning: 0 / Suggestion: 0（前述の観点はすべて確認済み）"; then
  ok "契約準拠ゼロ行 + 弱参照語の注記は受理（件数行は行単位 veto の対象外）"
else
  bad "契約準拠ゼロ行に弱参照語の注記が付くと不受理になる（veto がゼロ報告契約と自己矛盾）"
fi

# 完了主張の散文 + 契約準拠ゼロ行は**受理される**（既知の限界）。メッセージ単位の
# 完了主張 veto は 5 巡目で導入し 6 巡目で撤回した — プロンプト契約に無い語彙で
# 正当なレビュー（対象コードの説明に「上記で完了」を含む等）を全損させ、検出力も
# 完全一致 3 パターンに留まるため。参照語 veto は行単位（s3/s4 のみ）が最終仕様で、
# このケースはその境界を固定する（veto をメッセージ単位へ広げる変更はここで赤になる）。
STRONG_ECHO="レビュー本文は上記で完了しています。

Critical: 0 / Warning: 0 / Suggestion: 0"
if check_body "$STRONG_ECHO"; then
  ok "完了主張の散文 + 契約準拠ゼロ行は受理（veto は行単位のみ — メッセージ単位 veto は撤回済み）"
else
  bad "完了主張の散文 + 契約準拠ゼロ行が不受理（撤回したはずのメッセージ単位 veto が復活している）"
fi

if check_body "$FENCED_ECHO"; then
  bad "コードフェンス内のテンプレート引用 + 参照文を受理した（フェンス引用の回避を塞げていない）"
else
  ok "フェンス引用の復唱は不受理（フェンス内は実体行に数えない）"
fi

# 未閉フェンス: フェンスマスクを放棄し「全文のどこかに自己完結行（s1/s2/s3）が
# あれば受理・無ければ不受理」。集約側の CRITICAL 判定が未閉フェンス（rc=2）を
# 「素通りさせない側」へ倒すのと同じ向きで、実体の証拠なしに受理はしない。
# 実体行ありの形は multi-agent-critical-marker ケース 7 / 16 の stub 出力そのもの
# （フェンス内に `- Critical: 1`）— ここを不受理にすると同 suite の orchestrator
# 実走が赤くなり、受理側の無条件 exit 0 にすると実体なしの引用が素通りする。
UNCLOSED_WITH_BODY='途中経過の引用:

```text
（この引用は閉じられないまま本文が続いてしまった）

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1'
if check_body "$UNCLOSED_WITH_BODY"; then
  ok "未閉フェンス + 実体行あり（フェンス内 - Critical: 1）は受理（マスク放棄フォールバック）"
else
  bad "未閉フェンス + 実体行ありを不受理にした（multi-agent-critical-marker ケース 7/16 が赤くなる退行）"
fi

UNCLOSED_NO_BODY='途中経過の引用:

```text
（この引用は閉じられないまま本文が終わり、レビューの実体行はどこにも無い）
このレビューはまだ書きかけです。'
if check_body "$UNCLOSED_NO_BODY"; then
  bad "未閉フェンス + 実体行なしを受理した（判定不能の無条件受理への退行）"
else
  ok "未閉フェンス + 実体行なしは不受理（実体の証拠なしに受理しない）"
fi

# フェンスの種別・長さ追跡（CommonMark 準拠）: バッククォートフェンス内の ~~~ や
# 4 連フェンス内の 3 連を「閉じ」と誤認しないこと。単純な反転トグルだと、引用中の
# テンプレート bullet がフェンス外として実体行に化ける。
# 地の文は中立 — FENCED_ECHO と同じ理由で、フェンス規則の mutation 検出力を
# 他の不受理根拠に覆い隠させない。
FENCE_MIXED='テンプレートの引用:

```text
~~~
- Critical: 1
```

以上はテンプレートの引用です。'
if check_body "$FENCE_MIXED"; then
  bad "バッククォートフェンス内の ~~~ を閉じと誤認し、引用 bullet を実体行に数えた"
else
  ok "バッククォートフェンス内の ~~~ では閉じない（引用 bullet を実体行に数えない）"
fi

FENCE_LONG='````
```
- Critical: 1
```
````

以上はフェンスの引用例です。'
if check_body "$FENCE_LONG"; then
  bad "4 連フェンス内の 3 連を閉じと誤認し、引用 bullet を実体行に数えた"
else
  ok "4 連フェンス内の 3 連では閉じない（同種かつ同長以上でのみ閉じる）"
fi

# 閉じフェンスの後続検証: フェンス文字列の後に空白以外が続く行（info string 付き）
# は閉じではない（CommonMark）。後続検証が無いと ```not-a-closing-fence が閉じ扱いに
# なり、以降の引用 bullet が実体行として受理される。地の文は中立にする（実体行を
# 一切持たないことが不受理の根拠であり続けるように）。
FENCE_FAKE_CLOSE='引用:

```text
```not-a-closing-fence
- Critical: 1
```

以上は引用です。'
if check_body "$FENCE_FAKE_CLOSE"; then
  bad "info string 付きのフェンス様の行を閉じと誤認し、引用 bullet を実体行に数えた"
else
  ok "フェンス文字列の後が空白のみの行だけを閉じと認める（info string 付きでは閉じない）"
fi

# 開始フェンスのインデント検査（閉じ側と対称）: インデント 4 以上のフェンス様の行は
# indented code の一部でありフェンスを開かない（CommonMark）。開始側を無検査にすると、
# レビュー本文中のインデント付きコード例がフェンスを「開き」、以降の実指摘
# （s4 = 見出し配下の bullet。found_any に入らない）が引用扱いで消えて不受理になる。
INDENTED_FENCE='### Critical

    ```
- **停止条件が欠けている**（scripts/foo.sh:10）'
if check_body "$INDENTED_FENCE"; then
  ok "インデント 4 のフェンス様の行はフェンスを開かない（後続の実指摘を引用扱いにしない）"
else
  bad "インデント 4 のフェンス様の行がフェンスを開き、実指摘が引用扱いで不受理になった"
fi

# レポート全文を閉じたフェンスで包んだ出力は不受理（Execution Boundary が包むこと
# を禁止しており、フェンス内は引用として数えない）。
FULL_WRAP='```markdown
## 総合レビュー

### Critical

- **停止条件が欠けている**（`scripts/foo.sh:10`）

### Summary
- Critical: 1
```'
if check_body "$FULL_WRAP"; then
  bad "全文をフェンスで包んだ出力を受理した（フェンス内を引用扱いする規則が破れている）"
else
  ok "全文フェンス包みは不受理（閉じたフェンス内は引用として数えない）"
fi

echo "== 行単位構造検証（review_body_present）: 合格側 =="

if check_body "$ZERO_REPORT"; then
  ok "明示ゼロ報告（CRITICAL: 0 の件数サマリ行）は本文あり"
else
  bad "明示ゼロ報告を本文なしと誤検知した（根拠付き 0 件の正常系が INCOMPLETE に化ける）"
fi

if check_body "$SHORT_FINDING"; then
  ok "行頭の件数サマリ行（Warning: 1）を持つ短い実指摘は本文あり"
else
  bad "行頭の件数サマリ行を持つ実指摘を本文なしと誤検知した"
fi

# 見出しも件数も持たず、指摘行（重大度ラベル + コロン）だけの出力。実レビューが
# テンプレートの節構造を省いて bullet だけを返す形と、他 suite の stub CLI
# （`- Suggestion: stub review` 等）の両方がこの形に依存する。
if check_body "- **Warning**: stderr の破棄が早すぎる（scripts/foo.sh:12）"; then
  ok "行頭の重大度ラベル指摘行（- **Warning**: …）は本文あり"
else
  bad "行頭の重大度ラベル指摘行を本文なしと誤検知した"
fi

if check_body "$JA_ZERO"; then
  ok "日本語ゼロ件報告（行頭の「指摘なし」）は本文あり"
else
  bad "日本語ゼロ件報告を本文なしと誤検知した"
fi

if check_body "### 重大度別サマリ
- 指摘 0 件"; then
  ok "「重大度」見出し + ゼロ件行の日本語テンプレート形は本文あり"
else
  bad "「重大度」見出し + ゼロ件行の日本語テンプレート形を本文なしと誤検知した"
fi

if check_body "$LONG_WITH_MARKER"; then
  ok "重大度見出し配下の指摘 bullet を持つ長文は本文あり（実体行は長さと独立に効く）"
else
  bad "重大度見出し配下の指摘 bullet を持つ長文を本文なしと誤検知した"
fi

if check_body "$COMPREHENSIVE_FINDING"; then
  ok "comprehensive-review の指摘形（見出し配下のラベル無し bullet）は本文あり"
else
  bad "comprehensive-review の指摘形を本文なしと誤検知した（見出し単独拒否の巻き添え）"
fi

if check_body "$PROSE_ZERO_CONTRACT"; then
  ok "契約準拠の散文ゼロ報告（散文 + 独立行 Critical: 0 / Warning: 0 / Suggestion: 0）は本文あり"
else
  bad "契約準拠の散文ゼロ報告を本文なしと誤検知した（出力契約どおりの出力が落ちる）"
fi

echo "== 4 アダプタへのゲート常在（静的 pin） =="

# behavioral ケース（下の実走）は claude-code しか通らない。multi-agent-timeout の
# empty-output pin と同型で、(a) record_timeout_reason missing-review-body の存在と
# (b) それが stderr_log の最終破棄（最後の rm -f）より前にあること、の 2 点**だけ**を
# 行順で固定する。検出できるのはゲート行の消失と、最後の rm -f より後ろへの移動で、
# ゲートの分岐条件・fail_cli_task への引数・review_body_present 呼び出しの有無までは
# この静的検査では見ない（そちらは claude-code の behavioral ケースが受け持つ）。
for adapter in claude-code codex-cli copilot-cli grok-cli; do
  f="$ADAPTERS_DIR/${adapter}-adapter.sh"
  gate_line=""
  gate_line="$(grep -n 'record_timeout_reason missing-review-body' "$f" 2>/dev/null | head -1 | cut -d: -f1)" || true
  rm_line=""
  rm_line="$(grep -n 'rm -f "\$stderr_log"' "$f" 2>/dev/null | tail -1 | cut -d: -f1)" || true
  if [ -n "$gate_line" ] && [ -n "$rm_line" ] && [ "$gate_line" -lt "$rm_line" ]; then
    ok "${adapter}: review 本文ゲートが stderr_log 破棄より前に常在する"
  else
    bad "${adapter}: review 本文ゲートが無いか並びが崩れている (gate=${gate_line:-なし} rm=${rm_line:-なし})"
  fi
done

echo "== AC 2: 最終メッセージ集約指示（build_prompt、review 限定） =="

# ── diff を持つ一時リポジトリ（review の build_prompt は diff 必須） ──
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "review-capture-fail-loud-test"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > app.txt
git add app.txt
git commit -qm "change"

PERSPECTIVE="$TMP/perspective.md"
printf '%s\n' '# Fixture Perspective' 'PERSPECTIVE-CONTENT-MARKER' > "$PERSPECTIVE"

gen_prompt() { # $1: task_type / stdout: プロンプト
  (
    unset DIFF_FILE STAGED_DIFF INCLUDE_DIFF CHANGED_FILES
    TASK_TYPE="$1"
    DESCRIPTION="fixture task"
    export TASK_TYPE DESCRIPTION
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    build_prompt "$PERSPECTIVE" develop
  )
}

if ! REVIEW_PROMPT="$(gen_prompt review)"; then
  bad "review プロンプトの生成自体が失敗した"
  REVIEW_PROMPT=""
fi
case "$REVIEW_PROMPT" in
  *"Only your FINAL message is captured"*) ok "review: 最終メッセージだけが捕捉されることを CLI へ明示する" ;;
  *) bad "review: 集約指示が無い（途中ターンへ本文を出した CLI が捕捉全損になる）" ;;
esac
case "$REVIEW_PROMPT" in
  *"never a summary of or a reference to earlier output"*) ok "review: 参照・要約での代替を禁止する（「上記で完了」型の空振りを名指し）" ;;
  *) bad "review: 参照・要約の禁止文言が無い" ;;
esac
# ゲートの受理条件そのものがプロンプトに明記されていること（契約の一本化 —
# 指示なしにゲートだけで落とさない）。
case "$REVIEW_PROMPT" in
  *"The wrapper only accepts a"*) ok "review: 受理条件（実体行の要求）を CLI へ明示する" ;;
  *) bad "review: 受理条件の明記が無い（指示は無いのにゲートだけ落とす形に戻っている）" ;;
esac
case "$REVIEW_PROMPT" in
  *"Critical: 0 / Warning: 0 / Suggestion: 0"*) ok "review: ゼロ件時の出力形（Critical: 0 / …）を例示する" ;;
  *) bad "review: ゼロ件時の出力形の例示が無い" ;;
esac
case "$REVIEW_PROMPT" in
  *"Do NOT wrap the report"*) ok "review: 全文フェンス包みの禁止を明記する（不受理規則と対）" ;;
  *) bad "review: 全文フェンス包みの禁止文言が無い（規則だけあって指示が無い形）" ;;
esac

if ! EXPLORE_PROMPT="$(gen_prompt explore)"; then
  bad "explore プロンプトの生成自体が失敗した"
  EXPLORE_PROMPT=""
fi
case "$EXPLORE_PROMPT" in
  *"Only your FINAL message is captured"*) bad "explore: review 限定のはずの集約指示が載っている（task-type ゲートの退行）" ;;
  "") : ;; # 生成失敗は上で報告済み
  *) ok "explore: 集約指示は載らない（review 限定）" ;;
esac

# perspective 側の出力契約（契約一本化のもう一端）: 件数サマリ節を持たない唯一の
# 観点 comprehensive-review が、ゼロ件時の独立行出力（= ゲートの受理条件を満たす形）
# を義務付けていること。この記述が消えると、指示どおりの散文ゼロ報告がゲートに
# 落とされる恒常赤へ戻る。
if grep -qF 'Critical: 0 / Warning: 0 / Suggestion: 0' \
     "$PLUGIN_ROOT/scripts/perspectives/review/comprehensive-review.md"; then
  ok "comprehensive-review がゼロ件時の独立行出力を義務付ける（出力契約とゲートの一本化）"
else
  bad "comprehensive-review にゼロ件時の独立行契約が無い（散文ゼロ報告がゲートで恒常赤になる）"
fi

echo "== claude-code アダプタの実走（stub CLI） =="

STUB="$TMP/bin"
OUT="$TMP/out"
mkdir -p "$STUB" "$OUT"

# stub claude: stdin（プロンプト）を読み切り、シナリオ指定の本文を最終出力として返す。
printf '%s' "$META_ONLY"   > "$TMP/payload-meta.txt"
printf '%s' "$ZERO_REPORT" > "$TMP/payload-zero.txt"
cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
cat >/dev/null
cat "\$FF_TEST_STUB_PAYLOAD"
SH
chmod +x "$STUB/claude"

run_adapter() { # $1: payload file / $2: output file / $3...: 追加引数
  local payload="$1" outfile="$2"
  shift 2
  ( cd "$REPO" && run_isolated PATH="$STUB:$PATH" FF_TEST_STUB_PAYLOAD="$payload" \
      bash "$ADAPTERS_DIR/claude-code-adapter.sh" "$PERSPECTIVE" "$outfile" \
      --base develop --timeout 30 "$@" )
}

header_status() { # $1: 成果物 / stdout: ヘッダ内の Status 値（本文の引用は見ない）
  awk '/^$/ { exit } /^<!-- Status: / { gsub(/^<!-- Status: | -->$/, ""); print; exit }' "$1"
}

# (a) メタ記述だけの捕捉結果 → 非 0 + INCOMPLETE 成果物
set +e
run_adapter "$TMP/payload-meta.txt" "$OUT/meta.md" --task-type review \
  >"$TMP/adapter-meta.log" 2>&1
META_RC=$?
set -e
if [ "$META_RC" -ne 0 ]; then
  ok "本文なし結果でアダプタが非 0 終了する (rc=${META_RC})"
else
  bad "本文なし結果がアダプタを 0 で通過した（Status: complete の空振りが復活）"
  tail -10 "$TMP/adapter-meta.log" | sed 's/^/    | /' >&2
fi
if [ ! -f "$OUT/meta.md" ]; then
  bad "本文なし結果の INCOMPLETE 成果物が書かれていない（手ぶらの失敗は Issue #152 の退行）"
else
  if [ "$(header_status "$OUT/meta.md")" = "incomplete" ]; then
    ok "成果物ヘッダが Status: incomplete（統合レポートの未確認バナーが発火する契約）"
  else
    bad "成果物ヘッダが incomplete でない: $(header_status "$OUT/meta.md")"
  fi
  if grep -qF "INCOMPLETE" "$OUT/meta.md"; then
    ok "成果物バナーが INCOMPLETE を名乗る"
  else
    bad "成果物に INCOMPLETE バナーが無い"
  fi
  if grep -qF "レビュー報告は上記で完了しています" "$OUT/meta.md"; then
    ok "捕捉できた出力を成果物へ保全する（診断材料を捨てない）"
  else
    bad "捕捉済みの出力が成果物から消えている"
  fi
  # 拒否理由の主張は実際の検査条件（構造マーカー不在）だけを述べること。
  if grep -qF "no severity count/zero line, no severity-labeled finding line, and no finding bullet under a severity heading" "$OUT/meta.md"; then
    ok "拒否理由が受理条件の正規形（実体行 3 種の不在）を名指しする"
  else
    bad "成果物が拒否理由を受理条件の正規形で名指ししない（クラッシュ・タイムアウトと区別できない）"
  fi
fi

# (b) --task-type 省略（既定 = review）でも同じゲートが効く
set +e
run_adapter "$TMP/payload-meta.txt" "$OUT/default.md" \
  >"$TMP/adapter-default.log" 2>&1
DEFAULT_RC=$?
set -e
if [ "$DEFAULT_RC" -ne 0 ] && [ -f "$OUT/default.md" ] \
   && [ "$(header_status "$OUT/default.md")" = "incomplete" ]; then
  ok "--task-type 省略時（既定 review）もゲートが効く (rc=${DEFAULT_RC})"
else
  bad "--task-type 省略時にゲートが効かない (rc=${DEFAULT_RC} status=$(header_status "$OUT/default.md" 2>/dev/null || echo 'ファイルなし'))"
fi

# (c) 明示ゼロ報告 → 従来どおり 0 + complete
set +e
run_adapter "$TMP/payload-zero.txt" "$OUT/zero.md" --task-type review \
  >"$TMP/adapter-zero.log" 2>&1
ZERO_RC=$?
set -e
if [ "$ZERO_RC" -eq 0 ]; then
  ok "明示ゼロ報告でアダプタが 0 で完走する"
else
  bad "明示ゼロ報告がアダプタを非 0 にした (rc=${ZERO_RC}。根拠付き 0 件の正常系を壊した)"
  tail -10 "$TMP/adapter-zero.log" | sed 's/^/    | /' >&2
fi
if [ -f "$OUT/zero.md" ] && [ "$(header_status "$OUT/zero.md")" = "complete" ]; then
  ok "明示ゼロ報告の成果物は Status: complete のまま"
else
  bad "明示ゼロ報告の成果物が complete でない: $(header_status "$OUT/zero.md" 2>/dev/null || echo 'ファイルなし')"
fi

# (d) explore はゲート対象外 — 短い自由書式の出力を誤検知しない
set +e
run_adapter "$TMP/payload-meta.txt" "$OUT/explore.md" \
  --task-type explore --description "fixture explore" \
  >"$TMP/adapter-explore.log" 2>&1
EXPLORE_RC=$?
set -e
if [ "$EXPLORE_RC" -eq 0 ]; then
  ok "explore の短い出力はゲートに掛からない（review スコープの確認）"
else
  bad "explore の短い出力が本文なし扱いで落ちた (rc=${EXPLORE_RC})"
  tail -10 "$TMP/adapter-explore.log" | sed 's/^/    | /' >&2
fi
if [ -f "$OUT/explore.md" ] && [ "$(header_status "$OUT/explore.md")" = "complete" ]; then
  ok "explore の成果物は Status: complete のまま"
else
  bad "explore の成果物が complete でない: $(header_status "$OUT/explore.md" 2>/dev/null || echo 'ファイルなし')"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ review-capture-fail-loud verify: $FAIL 件失敗" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ review-capture-fail-loud verify: 全 $PASS 件 pass"
FF_REACHED_END=1
