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
#   (7) 成果物を**書けなかった**回の fail-loud。write_output は以前、成果物を書く
#       `cat` の終了コードを戻り値へ載せていなかったため、書き込みが失敗しても
#       rc=0 を返しつつ `✅ ... saved: <path>` と名乗った（実測: 書き込み不可の
#       出力先で rc=0・ファイル不在・`✅ Review saved` が同時に出る）。塞がって
#       いなかったのは部分書き込み — 切り詰められた成果物はファイルとして残るので
#       orchestrator の `-f` 検査（`No output file`）を通過し、`✅ Done` →
#       resume キャッシュ → 統合レポートへ INCOMPLETE の印なしで連結された。
#       実機 fixture で固定する 2 形（環境依存。両方とも skip になった run は緑に
#       しない — 「環境が理由で 1 件も実走しなかった」を成功と読ませないため）:
#         (e) 書き込み不可の出力先で実走 → アダプタが 125（orchestrator 起因の
#             終了コード）で落ち、所定のパスに何も残さず、`✅` を 1 行も出さない
#         (f) RLIMIT_FSIZE で write を本当に途中で止める → write_output が rc=1 を
#             返し（診断は 0 < 実書き込み < 期待の実測値を名指しする）、切り詰められた
#             成果物が所定のパスに残らず、そこに在った完成済みの成果物も壊れない
#       実機では作り分けられない形は printf / mv / mktemp のシムで 1 検査 1 ケースへ
#       分けて実測する: (g) rc=0 なのに短い書き込み（バイト照合の単独検出）/
#       (h) 全量書けたのに書き込みが非 0（書き込み rc の単独検出）/ (i) rename の失敗 /
#       (j) rename が 0 を返したのに宛先に通常ファイルが無い / (k) 宛先が既存
#       ディレクトリ（`mv` がその中へ移して rc=0 + saved になる形）/ (l) 既存成果物の
#       置き換えが rename であること（inode の入れ替えで上書きコピーと区別）/
#       (m)(n) 一時ファイル名の予測可能性（mktemp 優先と、固定名へ落ちた回の
#       symlink 拒否）。委譲経路の書き込み失敗が出力先を名指しすること、
#       orchestrator が 125 を専用分類で報告すること（並列・逐次の両回収経路）も実走。
#       さらに 4 アダプタ全部で write_output の直後に受け止めがあることを行順で pin。
#
# 変異検出（実測。退避 → 変異 → 本 suite → 復元。検査 1 つにつき 1 変異）:
#   - write_output を旧実装へ差し戻す（rc 非搭載・直書き・常に saved）→ 8 件赤
#   - 一時ファイル + rename をやめ所定のパスへ直接書く → 1 件赤（既存の成果物を
#     壊した）。書けなかった断片の掃除は残るので、赤になるのはこの 1 件だけ
#   - 書き込み失敗時にも `✅ saved` を出す → 2 件赤（(e)(f) 両方）
#   - 書き込み失敗の終了コードを 125 → 1 にする → 1 件赤
#   - アダプタ 1 本から `|| fail_output_write` を外す → 静的 pin のその 1 件が赤
#   - 完成バイト数の照合だけを外す → 4 件赤（(g) が単独で拾う）
#   - 書き込み rc だけを捨てる → 3 件赤（(h) が単独で拾う）
#     この 2 つは (f) の中では互いの控えで、片方を外しても残る側が先に拾うため
#     長らく**どちらも緑のまま**だった。「rc=0 だが短い出力」「全量書けたのに rc が
#     非 0」を printf のシムで作り分ければ実測で再現でき（実測: 40/301 バイト・
#     status 0 / 301/301 バイト・status 3）、それぞれ単独で赤にできる。
#   - rename の失敗を握り潰す（`mv ... || true`）→ 2 件赤
#   - 宛先ディレクトリの早期検査を外す → 1 件赤（publish 後の砦が rc は拾うが、
#     失敗の理由が読み手に届かなくなる）
#   - publish 後の `-f` 検査を外す → 1 件赤
#   - 固定名フォールバックの symlink 拒否を外す → 1 件赤（指し先が truncate される）
#   - 一時ファイル名を mktemp 由来から pid 固定名のみへ戻す → 1 件赤（先置き
#     symlink を踏む）。multi-agent-timeout は緑のまま
#   - 逆に固定名フォールバックを外して mktemp のみにする → **本 suite は緑のまま**、
#     multi-agent-timeout の tmpdir ケースが赤（mktemp が使えない環境では
#     INCOMPLETE 成果物そのものが書けなくなる）。この性質はあちらが持ち場。
#   - orchestrator の 125 専用分類を汎用 `Failed` へ戻す → 2 件赤（並列・逐次）
#   - 委譲経路の書き込み失敗を専用 rc から素の 1 へ戻す → 2 件赤
#   - (e)(f) がともに skip になる環境を模した状態で合流ガードを外す → 緑（見逃し。
#     ガードを残した同じ状態では 1 件赤になることを実測済み）
#
# LLM が集約指示に従うかは stub では測れない。ここで固定するのは検出ゲートと
# 指示の存在までで、実効性は実 CLI での完走確認を Issue / PR に記録する。
# 実 CLI・ネットワーク・課金は伴わない。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

[ -f "$ADAPTER_COMMON" ] || {
  echo "✗ 対象ファイルが見つかりません: $ADAPTER_COMMON" >&2
  exit 1
}

# ホストの MULTI_AGENT_MODEL_CLAUDE_CODE などが export されているとアダプタ実走
# ケースの前提が崩れる。125 の分類ケースは orchestrator も起動する（MULTI_AGENT_CONFIG
# 等を読む）ので、抽出源は multi-agent.sh とアダプタ実装の両方。センチネルは
# orchestrator 専用変数とアダプタ変数の 2 本（lib の契約: 抽出対象のソース群ごとに
# 1 つ — 片方のソースだけ引数から落ちる形を単一センチネルでは検出できない）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_MODEL_CLAUDE_CODE" \
  "$PLUGIN_ROOT/scripts/multi-agent.sh" "$ADAPTERS_DIR"/*.sh

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

# 共有パーサー（Issue #908）の見出しスコープはレベル追跡: 重大度見出し配下の
# サブ見出し（より深い見出し）を跨いだ bullet もスコープ内 = 実体行。集約側の
# Critical 検出と同一のスコープ規則（サブ見出しごとにスコープが切れる旧・受理側
# 実装へ戻ると、ここが赤になり両側の分類が再び割れる）。
if check_body "### Critical

#### 詳細

- 停止条件が欠けている（scripts/foo.sh:10）"; then
  ok "重大度見出し配下のサブ見出しを跨いだ bullet は本文あり（レベル追跡スコープ）"
else
  bad "サブ見出しでスコープが切れている（集約側と異なるスコープ規則への退行）"
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
ff_git_fixture_init "$REPO" "review-capture-fail-loud-test" "test@example.com"
cd "$REPO"
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

# プレフィックスを持たない build_prompt の入力（DIFF_FILE 等）は lib の
# unset_prompt_env_vars で落とす（名簿は lib の 1 箇所だけ。Issue #769）。
gen_prompt() { # $1: task_type / stdout: プロンプト
  (
    unset_prompt_env_vars
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

echo "== 成果物を書けなかった回の fail-loud（write_output の rc） =="

# 失敗診断の `(wrote N of M bytes, status S)` から 3 つの数値を取り出す。
# 「非 0 で落ちた」だけを合格条件にすると、関数未定義の 127 や書き込みへ到達する前の
# 別エラーでもケース全体が通る（測る対象がすり替わる）ので、実測値まで見る。
wrote_numbers() { # $1: ログ / stdout: "N M S"（診断行が無ければ空）
  grep -o '(wrote [0-9]* of [0-9]* bytes, status [0-9]*)' "$1" 2>/dev/null \
    | tail -1 | tr -d '()' | awk '{print $2, $4, $7}'
}

# 環境都合で skip した形を数える。(e) と (f) は AC が必須とした 2 形なので、
# **両方とも実行できなかった** run は緑にしない（下の合流判定）。個別の skip は
# 従来どおり run-all の `checks-skipped` へ計上されるだけに留める。
RAN_UNWRITABLE=0
RAN_PARTIAL=0

# (e) 書き込み不可の出力先で実走 — アダプタは 125（orchestrator 起因）で落ち、
#     `✅ saved` を出さず、所定のパスに何も残さない。
#     旧実装は rc=0 のまま `✅ Review saved` を出し、orchestrator 側の
#     `No output file`（成果物が 1 件も無い場合だけ効く検査）に拾わせていた。
RO_OUT="$TMP/readonly-out"
mkdir -p "$RO_OUT"
chmod 500 "$RO_OUT" 2>/dev/null || true
# root 実行や書き込み制限の効かない filesystem では検査が成立しない。緑を装わず
# その 1 件だけ理由付きで落とす（chmod の有無を実測してから走らせる）。
if ( : > "$RO_OUT/.probe" ) 2>/dev/null; then
  rm -f "$RO_OUT/.probe"
  echo "  ○ skip: 出力先を書き込み不可にできない環境のため (e) を実行していません"
else
  RAN_UNWRITABLE=1
  set +e
  run_adapter "$TMP/payload-zero.txt" "$RO_OUT/p.md" --task-type review \
    >"$TMP/adapter-unwritable.log" 2>&1
  RO_RC=$?
  set -e
  if [ "$RO_RC" -eq 125 ]; then
    ok "書き込み不可の出力先でアダプタが 125（orchestrator 起因）で落ちる"
  else
    bad "書き込み不可の出力先で rc=${RO_RC}（0 なら「saved」と名乗って成功扱い、1 なら CLI のクラッシュと同じ番号）"
    tail -12 "$TMP/adapter-unwritable.log" | sed 's/^/    | /' >&2
  fi
  if [ ! -e "$RO_OUT/p.md" ]; then
    ok "所定のパスに成果物を残さない"
  else
    bad "書けていないのに所定のパスにファイルが残っている（$(wc -c < "$RO_OUT/p.md" | tr -d ' ')B）"
  fi
  if grep -qF '✅' "$TMP/adapter-unwritable.log"; then
    bad "書き込み失敗の実行が ✅ を出している（失敗したログが「書けたのに消えた」調査へ誘導する）"
    grep -F '✅' "$TMP/adapter-unwritable.log" | head -2 | sed 's/^/    | /' >&2
  else
    ok "失敗した実行に ✅ の行が 1 つも出ない"
  fi
  if grep -qF "$RO_OUT/p.md" "$TMP/adapter-unwritable.log" \
     && grep -qF 'No artifact was left there' "$TMP/adapter-unwritable.log"; then
    ok "ERROR が書けなかったパスと「成果物は残っていない」ことを名指しする"
  else
    bad "ERROR が書けなかったパス / 成果物不在を名指ししない（CLI 側の失敗と読み分けられない）"
    tail -12 "$TMP/adapter-unwritable.log" | sed 's/^/    | /' >&2
  fi
fi
chmod 700 "$RO_OUT" 2>/dev/null || true

# (f) 部分書き込み — RLIMIT_FSIZE で write を**本当に途中で止める**。
#     ここは write_output 単体で走らせる。アダプタ全体に同じ上限を掛けると、
#     先にプロンプト一時ファイルと CLI stdout の一時ファイルが同じ上限へ当たり、
#     成果物へ到達する前に別の理由で落ちる（測る対象がすり替わる）。
#     固定するのは 2 点。(1)「切り詰められた成果物が所定のパスに残らない」— 残ると
#     orchestrator の `-f` 検査を通過し、`✅ Done` → resume キャッシュ →
#     統合レポートへ INCOMPLETE の印なしで連結される。(2)「そこに在った完成済みの
#     成果物を壊さない」— 所定のパスへ直接書く実装は書き始めた時点で既存を truncate
#     するので、再実行や resume で前回の結果まで道連れになる。
PARTIAL_DIR="$TMP/partial-out"
mkdir -p "$PARTIAL_DIR"
BIG_BODY="$(awk 'BEGIN {
  print "- Critical: 0"
  for (i = 0; i < 800; i++) printf "- Suggestion: 指摘 %03d の本文を埋める行。書き込み途中で切れることを実測する。\n", i
}')"
# 既に完成した成果物が在る場所（上書きに失敗しても壊れてはいけない）。
KEEP_FILE="$PARTIAL_DIR/keep.md"
printf '%s\n' \
  '<!-- Multi-CLI Review Result -->' \
  '<!-- CLI: Claude Code -->' \
  '<!-- Perspective: code-review -->' \
  '<!-- Task Type: review -->' \
  '<!-- Status: complete -->' \
  '<!-- Generated: 2026-01-01T00:00:00Z -->' \
  '' \
  '- Critical: 0' \
  '- 前回の完成した成果物 KEEPMARK' > "$KEEP_FILE"
KEEP_BYTES_BEFORE="$(wc -c < "$KEEP_FILE" | tr -d '[:space:]')"
set +e
(
  # SIGXFSZ を無視すると、上限に当たった write は EFBIG を返すだけになる
  # （プロセスは死なない）= ENOSPC と同じ形の「途中まで書けて失敗」になる。
  trap '' XFSZ
  ulimit -f 1 2>/dev/null || exit 90
  # 失敗した printf が呼び出し元の stdout バッファへ残す断片を、下の計測へ
  # 漏らさない（write_output 側と同じ理由。捨て先を subshell ごと固定する）。
  ( printf '%s\n' "$BIG_BODY" > "$PARTIAL_DIR/.probe" ) >/dev/null 2>&1
  probe_bytes="$(wc -c < "$PARTIAL_DIR/.probe" 2>/dev/null | tr -d '[:space:]')"
  body_bytes="$(printf '%s\n' "$BIG_BODY" | wc -c | tr -d '[:space:]')"
  printf '%s/%s\n' "${probe_bytes:-0}" "$body_bytes" > "$PARTIAL_DIR/.measured"
  rm -f "$PARTIAL_DIR/.probe"
  # 上限が効かない（= 全量書けた / 1 バイトも書けない）環境では、部分書き込みを
  # 作れていないので検査が成立しない。
  [ "${probe_bytes:-0}" -gt 0 ] && [ "${probe_bytes:-0}" -lt "$body_bytes" ] || exit 91
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  write_rc=0
  write_output "$PARTIAL_DIR/p.md" "Claude Code" "code-review" "$BIG_BODY" || write_rc=$?
  # 既存の完成成果物へ同じ書き込みを仕掛ける（失敗しても壊してはいけない）。
  write_output "$KEEP_FILE" "Claude Code" "code-review" "$BIG_BODY" || true
  exit "$write_rc"
) >"$TMP/partial-write.log" 2>&1
PARTIAL_RC=$?
set -e
MEASURED="$(cat "$PARTIAL_DIR/.measured" 2>/dev/null || echo '不明')"
rm -f "$PARTIAL_DIR/.measured"
if [ "$PARTIAL_RC" -eq 90 ] || [ "$PARTIAL_RC" -eq 91 ]; then
  echo "  ○ skip: 途中で止まる書き込みを作れない環境のため (f) を実行していません（実測 ${MEASURED} バイト）"
else
  RAN_PARTIAL=1
  if [ "$PARTIAL_RC" -eq 1 ]; then
    ok "部分書き込みを write_output が rc=1 で報告する（実測 ${MEASURED} バイトで切れた）"
  else
    bad "部分書き込みの rc が 1 でない (rc=${PARTIAL_RC}。0 なら切り詰めの見逃し、127 等なら成果物の書き込みへ到達する前に別の理由で落ちている)"
    tail -6 "$TMP/partial-write.log" | sed 's/^/    | /' >&2
  fi
  P_N=""; P_M=""; P_S=""
  read -r P_N P_M P_S <<<"$(wrote_numbers "$TMP/partial-write.log")" || true
  if [ -n "$P_N" ] && [ -n "$P_M" ] && [ "$P_N" -gt 0 ] 2>/dev/null && [ "$P_N" -lt "$P_M" ] 2>/dev/null; then
    ok "診断が部分書き込みの実測値を名指しする（wrote ${P_N} of ${P_M} bytes, status ${P_S}）"
  else
    bad "部分書き込みの診断行が無いか 0 < N < M を満たさない（取得: '${P_N:-なし} ${P_M:-なし} ${P_S:-なし}'。任意の非 0 を合格にすると別の失敗がこのケースを素通りする）"
  fi
  if [ ! -e "$PARTIAL_DIR/p.md" ]; then
    ok "切り詰められた成果物が所定のパスに残らない（-f 検査を素通りしない）"
  else
    bad "切り詰められた成果物が所定のパスに残った（$(wc -c < "$PARTIAL_DIR/p.md" | tr -d ' ')B — 完成した結果として統合レポートへ載る）"
  fi
  if grep -qF '✅' "$TMP/partial-write.log"; then
    bad "部分書き込みの実行が ✅ を出している"
  else
    ok "部分書き込みの実行に ✅ の行が出ない"
  fi
  # 中断した書き込みの断片は成果物の glob（<cli>/*.md）に載らない位置へ置く。
  # 載ると stale 成果物の退避と統合レポートの走査が断片を拾う。
  LEFTOVER="$(find "$PARTIAL_DIR" -maxdepth 1 -name '*.md' ! -name 'keep.md' 2>/dev/null | head -1)"
  if [ -z "$LEFTOVER" ]; then
    ok "*.md に一致する取り残しが無い"
  else
    bad "書き込み途中の断片が *.md として残っている: ${LEFTOVER}"
  fi
  KEEP_BYTES_AFTER="$(wc -c < "$KEEP_FILE" 2>/dev/null | tr -d '[:space:]')" || KEEP_BYTES_AFTER=""
  if grep -qF 'KEEPMARK' "$KEEP_FILE" 2>/dev/null \
     && [ "$KEEP_BYTES_AFTER" = "$KEEP_BYTES_BEFORE" ]; then
    ok "その場所に在った完成済みの成果物を、上書きに失敗しても壊さない"
  else
    bad "上書きに失敗した回が既存の成果物を壊した（${KEEP_BYTES_BEFORE}B → ${KEEP_BYTES_AFTER:-消失}B。再実行・resume で前回の結果が道連れになる）"
  fi
fi

# (e) と (f) は AC が必須とした 2 形。片方が環境都合で skip されるのは許容するが、
# **両方とも実行されなかった** run を緑で返すと「環境が理由で 1 件も実走していない」
# ことが報告から消える（fail-open）。個別 skip の `checks-skipped` 計上はそのままに、
# 合流だけを非 0 にする。
if [ "$RAN_UNWRITABLE" -eq 0 ] && [ "$RAN_PARTIAL" -eq 0 ]; then
  bad "書き込み失敗の behavioral ケースが 1 つも実走していない（(e) 書き込み不可 / (f) 部分書き込みがともに skip。この環境では write_output の fail-loud が全く測れていない）"
fi

echo "== 書き込み失敗の各検査を単独で測る（printf / mv のシム） =="

# 以下 4 ケースは、実機の RLIMIT_FSIZE fixture では作り分けられない失敗の形を
# シムで注入する。(f) は「rc 非 0 かつ短い出力」を同時に起こすため、バイト照合と
# 書き込み rc のどちらか片方を外しても残る側が拾ってしまい、**どちらの検査も
# 単独では測れていなかった**（前任の実測: 変異どちらも緑のまま）。ここで
# 「rc=0 だが短い」「全量書けたが rc 非 0」を別々に作って 1 検査 1 ケースへ分ける。

SHIM_DIR="$TMP/shim-out"
mkdir -p "$SHIM_DIR"

# (g) rc=0 なのに本文が途中までしか届かない（バイト照合だけが拾える形）。
#     printf を「stdout が通常ファイルのときだけ短く書いて 0 を返す」関数で覆う。
#     期待バイト数の計測はパイプ越しなので覆われない = 計測側は汚さない。
set +e
(
  set +e +o pipefail
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  printf() {
    if [ -f /dev/stdout ]; then
      command printf "$@" | head -c 40
      return 0
    fi
    command printf "$@"
  }
  w=0
  write_output "$SHIM_DIR/short.md" "Claude Code" "code-review" "$SHORT_FINDING" || w=$?
  exit "$w"
) >"$TMP/shim-short.log" 2>&1
SHORT_RC=$?
set -e
if [ "$SHORT_RC" -eq 1 ]; then
  ok "rc=0 のまま切り詰められた書き込みを write_output が rc=1 で落とす（バイト照合の単独検出）"
else
  bad "rc=0 + 短い出力が rc=${SHORT_RC} で通った（完成バイト数の照合が効いていない = Issue が名指しした「rc=0 なのに本文が切れている」形が素通りする）"
  tail -6 "$TMP/shim-short.log" | sed 's/^/    | /' >&2
fi
G_N=""; G_M=""; G_S=""
read -r G_N G_M G_S <<<"$(wrote_numbers "$TMP/shim-short.log")" || true
if [ "${G_S:-}" = "0" ] && [ -n "$G_N" ] && [ -n "$G_M" ] && [ "$G_N" -gt 0 ] 2>/dev/null && [ "$G_N" -lt "$G_M" ] 2>/dev/null; then
  ok "診断が「status 0 なのに ${G_N}/${G_M} バイト」と実測値で言う（rc では気付けない形だと分かる）"
else
  bad "rc=0 の切り詰めの診断が status 0 + 0 < N < M になっていない（取得: '${G_N:-なし} ${G_M:-なし} ${G_S:-なし}'）"
fi
if [ ! -e "$SHIM_DIR/short.md" ]; then
  ok "切り詰められた成果物を所定のパスへ出さない（rc=0 の書き込みでも）"
else
  bad "rc=0 の切り詰めで成果物が所定のパスに残った（$(wc -c < "$SHIM_DIR/short.md" | tr -d ' ')B）"
fi
if grep -qF '✅' "$TMP/shim-short.log"; then
  bad "rc=0 の切り詰めで ✅ が出ている"
else
  ok "rc=0 の切り詰めで ✅ の行が出ない"
fi

# (h) 全量書けたのに書き込みが非 0 を返す（書き込み rc だけが拾える形）。
set +e
(
  set +e +o pipefail
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  printf() {
    if [ -f /dev/stdout ]; then
      command printf "$@"
      return 3
    fi
    command printf "$@"
  }
  w=0
  write_output "$SHIM_DIR/rc.md" "Claude Code" "code-review" "$SHORT_FINDING" || w=$?
  exit "$w"
) >"$TMP/shim-rc.log" 2>&1
WRC_RC=$?
set -e
if [ "$WRC_RC" -eq 1 ]; then
  ok "全量書けても書き込みが非 0 を返した回を write_output が rc=1 で落とす（書き込み rc の単独検出）"
else
  bad "全量書けた + 書き込み rc=3 が rc=${WRC_RC} で通った（書き込みの終了コードを捨てている）"
  tail -6 "$TMP/shim-rc.log" | sed 's/^/    | /' >&2
fi
H_N=""; H_M=""; H_S=""
read -r H_N H_M H_S <<<"$(wrote_numbers "$TMP/shim-rc.log")" || true
if [ "${H_S:-}" = "3" ] && [ -n "$H_N" ] && [ "$H_N" = "${H_M:-}" ]; then
  ok "診断が「${H_N}/${H_M} バイト書けて status 3」と言う（バイト照合では気付けない形だと分かる）"
else
  bad "非 0 rc の診断が status 3 + N == M になっていない（取得: '${H_N:-なし} ${H_M:-なし} ${H_S:-なし}'）"
fi
if [ ! -e "$SHIM_DIR/rc.md" ]; then
  ok "書き込みが非 0 を返した回の成果物を所定のパスへ出さない"
else
  bad "書き込み rc=3 なのに成果物が所定のパスに残った"
fi

# (i) publish の rename 自体が失敗する形。PR は「tmp 書き込み・バイト照合・rename の
#     3 つを rc へ載せた」と主張しているが、rename の失敗だけは実機 fixture を持たず
#     未測定だった（`mv ... || true` へ差し替えても全件 pass する状態）。
set +e
(
  set +e +o pipefail
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  mv() { echo "mv: stubbed failure" >&2; return 1; }
  w=0
  write_output "$SHIM_DIR/mvfail.md" "Claude Code" "code-review" "$SHORT_FINDING" || w=$?
  exit "$w"
) >"$TMP/shim-mv.log" 2>&1
MVFAIL_RC=$?
set -e
if [ "$MVFAIL_RC" -eq 1 ]; then
  ok "rename の失敗を write_output が rc=1 で落とす"
else
  bad "rename が失敗したのに rc=${MVFAIL_RC}（publish できていないのに成功と名乗る）"
  tail -6 "$TMP/shim-mv.log" | sed 's/^/    | /' >&2
fi
if grep -qF 'could not be moved into place' "$TMP/shim-mv.log"; then
  ok "rename 失敗の診断が publish 段の失敗だと名指しする"
else
  bad "rename 失敗の診断が無い（書き込み段の失敗と読み分けられない）"
fi
if [ ! -e "$SHIM_DIR/mvfail.md" ] \
   && [ -z "$(find "$SHIM_DIR" -maxdepth 1 -name '.mvfail.md.partial.*' 2>/dev/null | head -1)" ]; then
  ok "rename 失敗の回は成果物も一時ファイルの取り残しも残さない"
else
  bad "rename 失敗の回に成果物 or 一時ファイルが残った"
fi
if grep -qF '✅' "$TMP/shim-mv.log"; then
  bad "rename 失敗の回が ✅ を出している"
else
  ok "rename 失敗の回に ✅ の行が出ない"
fi

# (j) rename が 0 を返したのに所定のパスへ通常ファイルが無い形（publish 後の砦）。
#     早期の宛先ディレクトリ検査（下の (k)）を素通りする形が将来生えても、
#     成功と名乗る前にここで rc へ載ることを固定する。
set +e
(
  set +e +o pipefail
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  mv() { rm -f "$1"; return 0; }   # 0 を返すが宛先には何も置かない
  w=0
  write_output "$SHIM_DIR/lied.md" "Claude Code" "code-review" "$SHORT_FINDING" || w=$?
  exit "$w"
) >"$TMP/shim-lied.log" 2>&1
LIED_RC=$?
set -e
if [ "$LIED_RC" -eq 1 ] && [ ! -e "$SHIM_DIR/lied.md" ] && ! grep -qF '✅' "$TMP/shim-lied.log"; then
  ok "publish が 0 を返しても所定のパスに通常ファイルが無ければ rc=1（成功と名乗らない）"
else
  bad "publish 後の存在確認が効いていない (rc=${LIED_RC} 成果物=$([ -e "$SHIM_DIR/lied.md" ] && echo あり || echo なし) ✅=$(grep -qF '✅' "$TMP/shim-lied.log" && echo あり || echo なし))"
  tail -6 "$TMP/shim-lied.log" | sed 's/^/    | /' >&2
fi

# (k) 宛先が既存ディレクトリ — Issue が名指しした主症状（rc=0 +「saved」+ 所定の
#     パスに成果物なし）が残っていた唯一の経路。`mv` は一時ファイルを**その中へ**
#     移して 0 を返すため、検査が無いと旧実装と同じ結果になる。
DIRDEST="$TMP/dirdest-out"
mkdir -p "$DIRDEST/p.md"
set +e
(
  set +e +o pipefail
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  w=0
  write_output "$DIRDEST/p.md" "Claude Code" "code-review" "$SHORT_FINDING" || w=$?
  exit "$w"
) >"$TMP/shim-dirdest.log" 2>&1
DIRDEST_RC=$?
set -e
if [ "$DIRDEST_RC" -eq 1 ]; then
  ok "宛先がディレクトリなら write_output が rc=1 で落ちる"
else
  bad "宛先がディレクトリでも rc=${DIRDEST_RC}（旧実装と同じ「rc=0 + saved + 成果物なし」が残っている）"
  tail -6 "$TMP/shim-dirdest.log" | sed 's/^/    | /' >&2
fi
if grep -qF 'a directory already occupies that path' "$TMP/shim-dirdest.log"; then
  ok "診断が「そのパスをディレクトリが占めている」と名指しする（早期検査）"
else
  bad "宛先ディレクトリの早期検査が無い（publish 後の砦だけに頼ると、失敗の理由が読み手に届かない）"
fi
if [ -z "$(find "$DIRDEST/p.md" -maxdepth 1 -type f 2>/dev/null | head -1)" ]; then
  ok "宛先ディレクトリの中に一時ファイルを置き去りにしない"
else
  bad "一時ファイルが宛先ディレクトリの中へ移されて残っている"
fi
if grep -qF '✅' "$TMP/shim-dirdest.log"; then
  bad "宛先がディレクトリの回が ✅ を出している"
else
  ok "宛先がディレクトリの回に ✅ の行が出ない"
fi

# (l) publish は rename であって上書きコピーではないこと。コピーへ変えると、宛先の
#     既存成果物が書き終わる前に truncate され、同時に読む側（統合レポート生成・
#     resume）が**部分状態の成果物**を観測しうる。rename は宛先の dirent を差し替える
#     ので、成功後の inode は一時ファイル側のものに入れ替わる = 既存 inode の
#     その場書き換え（cp / `cat >`）と区別できる。
ATOMIC_DIR="$TMP/atomic-out"
mkdir -p "$ATOMIC_DIR"
printf '%s\n' '<!-- Multi-CLI Review Result -->' '' '- Critical: 0' > "$ATOMIC_DIR/p.md"
ATOMIC_INODE_BEFORE="$(ls -i "$ATOMIC_DIR/p.md" | awk '{print $1}')"
set +e
(
  set +e +o pipefail
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  w=0
  write_output "$ATOMIC_DIR/p.md" "Claude Code" "code-review" "$SHORT_FINDING" || w=$?
  exit "$w"
) >"$TMP/shim-atomic.log" 2>&1
ATOMIC_RC=$?
set -e
ATOMIC_INODE_AFTER="$(ls -i "$ATOMIC_DIR/p.md" 2>/dev/null | awk '{print $1}')" || ATOMIC_INODE_AFTER=""
if [ "$ATOMIC_RC" -eq 0 ] && [ -n "$ATOMIC_INODE_AFTER" ] \
   && [ "$ATOMIC_INODE_AFTER" != "$ATOMIC_INODE_BEFORE" ]; then
  ok "既存成果物の置き換えが rename（inode 入れ替え。部分状態が観測される上書きコピーではない）"
else
  bad "既存成果物が rename ではなくその場上書きで置き換えられている (rc=${ATOMIC_RC} inode ${ATOMIC_INODE_BEFORE} → ${ATOMIC_INODE_AFTER:-消失})"
  tail -6 "$TMP/shim-atomic.log" | sed 's/^/    | /' >&2
fi

# (m)(n) 一時ファイル名の予測可能性。pid 由来の固定名は先置きの symlink を `>` に
#     追跡させ、**指し先を truncate** できる（atomic publish の前提もそこで崩れる）。
#     mktemp が使えるならそれで作り、使えない環境へ落ちた回は書く前に塞ぐ、の 2 段を
#     それぞれ実測する。`$$` は subshell でも呼び出し元シェルの pid のままなので、
#     固定名フォールバックが選ぶ名前をテスト側から名指しできる。
SYM_DIR="$TMP/symlink-out"
mkdir -p "$SYM_DIR"
SYM_VICTIM="$TMP/symlink-victim.txt"

# (m) mktemp が使えない環境（固定名フォールバック）で、先置き symlink を踏まない。
printf 'VICTIM-INTACT\n' > "$SYM_VICTIM"
ln -s "$SYM_VICTIM" "$SYM_DIR/.fallback.md.partial.$$"
set +e
(
  set +e +o pipefail
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  mktemp() { return 1; }   # mktemp の無い環境を作る（固定名フォールバックへ落とす）
  w=0
  write_output "$SYM_DIR/fallback.md" "Claude Code" "code-review" "$SHORT_FINDING" || w=$?
  exit "$w"
) >"$TMP/shim-symlink.log" 2>&1
SYM_RC=$?
set -e
if [ "$SYM_RC" -eq 1 ] && grep -qF 'VICTIM-INTACT' "$SYM_VICTIM" \
   && [ ! -e "$SYM_DIR/fallback.md" ]; then
  ok "固定名フォールバックは先置き symlink を踏まず rc=1（指し先を truncate しない）"
else
  bad "固定名の一時ファイルが先置き symlink を追跡した (rc=${SYM_RC} 指し先=$(cat "$SYM_VICTIM" 2>/dev/null | head -1 | tr -d '\n') 成果物=$([ -e "$SYM_DIR/fallback.md" ] && echo あり || echo なし))"
  tail -6 "$TMP/shim-symlink.log" | sed 's/^/    | /' >&2
fi
rm -f "$SYM_DIR/.fallback.md.partial.$$"

# (n) mktemp が使える環境では、そもそも予測可能な名前を使わない。同じ先置き symlink
#     があっても素通りして publish まで届く（= 固定名へ戻す退行がここで赤くなる）。
printf 'VICTIM-INTACT\n' > "$SYM_VICTIM"
ln -s "$SYM_VICTIM" "$SYM_DIR/.mktemp.md.partial.$$"
set +e
(
  set +e +o pipefail
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  w=0
  write_output "$SYM_DIR/mktemp.md" "Claude Code" "code-review" "$SHORT_FINDING" || w=$?
  exit "$w"
) >"$TMP/shim-mktemp.log" 2>&1
MKT_RC=$?
set -e
if [ "$MKT_RC" -eq 0 ] && [ -f "$SYM_DIR/mktemp.md" ] && grep -qF 'VICTIM-INTACT' "$SYM_VICTIM"; then
  ok "mktemp が使える環境では予測可能な固定名を使わない（先置き symlink と無関係に publish できる）"
else
  bad "一時ファイル名が予測可能な固定名に戻っている (rc=${MKT_RC} 成果物=$([ -f "$SYM_DIR/mktemp.md" ] && echo あり || echo なし) 指し先=$(head -1 "$SYM_VICTIM" 2>/dev/null | tr -d '\n'))"
  tail -6 "$TMP/shim-mktemp.log" | sed 's/^/    | /' >&2
fi
rm -f "$SYM_DIR/.mktemp.md.partial.$$"

echo "== 委譲経路の書き込み失敗（壊れている対象を名指しする） =="

# 委譲経路で成果物を書けなかった回は、失敗の理由が「ホストへ渡せなかった」ではなく
# 「出力先が書けない」。汎用の orchestrator エラーへ流すと (1) 壊れている対象を
# 名指しせず (2) fail_cli_task 経由で write_output を踏み直す（書けない先へ
# INCOMPLETE 成果物を書きに行く）。ホストの実結果は response ファイルに在るのに、
# 誤った理由の成果物が統合レポートへ載る形になる。
DELEG_DIR="$TMP/delegate"
DELEG_OUT="$TMP/delegate-out"
mkdir -p "$DELEG_OUT"
set +e
run_adapter "$TMP/payload-zero.txt" "$DELEG_OUT/d.md" --task-type review \
  --delegate-dir "$DELEG_DIR" >"$TMP/deleg-handoff.log" 2>&1
DELEG_HANDOFF_RC=$?
set -e
if [ "$DELEG_HANDOFF_RC" -eq 123 ] && [ -f "$DELEG_DIR/perspective.request" ]; then
  ok "委譲: handoff が出る（rc=123 / request ファイルあり）"
else
  bad "委譲の handoff 前提が崩れている (rc=${DELEG_HANDOFF_RC} request=$([ -f "$DELEG_DIR/perspective.request" ] && echo あり || echo なし))"
  tail -8 "$TMP/deleg-handoff.log" | sed 's/^/    | /' >&2
fi
# ホストの応答を置き、同じ入力で再実行する。書けない出力先は「ディレクトリが占有」で
# 作る（chmod に依らないので root でも成立する）。
printf '%s\n' "$ZERO_REPORT" > "$DELEG_DIR/perspective.response.md"
rm -f "$DELEG_OUT/d.md"
mkdir -p "$DELEG_OUT/d.md"
set +e
run_adapter "$TMP/payload-zero.txt" "$DELEG_OUT/d.md" --task-type review \
  --delegate-dir "$DELEG_DIR" >"$TMP/deleg-write.log" 2>&1
DELEG_WRITE_RC=$?
set -e
if [ "$DELEG_WRITE_RC" -eq 125 ]; then
  ok "委譲: 成果物を書けない回は 125（orchestrator 起因）で落ちる"
else
  bad "委譲: 書き込み失敗の rc が 125 でない (rc=${DELEG_WRITE_RC})"
  tail -10 "$TMP/deleg-write.log" | sed 's/^/    | /' >&2
fi
if grep -qF "$DELEG_OUT/d.md" "$TMP/deleg-write.log" \
   && grep -qF 'No artifact was left there' "$TMP/deleg-write.log"; then
  ok "委譲: 壊れている対象（成果物の出力先）を名指しする"
else
  bad "委譲: 書き込み失敗が出力先を名指ししない（fail_output_write へ分岐していない）"
  tail -10 "$TMP/deleg-write.log" | sed 's/^/    | /' >&2
fi
if grep -qF 'cannot hand the' "$TMP/deleg-write.log"; then
  bad "委譲: 書き込み失敗が「ホストへ渡せなかった」という誤った理由で報告されている"
else
  ok "委譲: 「ホストへ渡せなかった」という誤った理由を名乗らない"
fi
if [ -f "$DELEG_DIR/perspective.response.md" ]; then
  ok "委譲: 書き込みに失敗してもホストの応答を消さない（払った実行を捨てない）"
else
  bad "委譲: 書き込みに失敗した回がホストの応答を消した"
fi
rm -rf "$DELEG_OUT/d.md"

echo "== orchestrator 側の 125 分類（並列・逐次の両回収経路） =="

# 125 は「壊れているのは CLI ではなくこちら側（出力先・ラッパー）」の意味で、素の
# `Failed (exit code: 125)` に丸めると読み手は存在しない CLI クラッシュを追い始める。
# 分類は 1 箇所（report_task_failure）だが、回収経路は並列・逐次の 2 つある。
# 125 を実際に起こすのは mktemp の失敗（アダプタが CLI 起動前に落ちる経路）。
# ここは orchestrator 側の読み替えを見る場所なので、125 の出どころは問わない。
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
ORCH_STUB="$TMP/orch-bin"
mkdir -p "$ORCH_STUB"
cat > "$ORCH_STUB/mktemp" <<'SH'
#!/usr/bin/env bash
echo "mktemp: stubbed failure" >&2
exit 1
SH
chmod +x "$ORCH_STUB/mktemp"
cat > "$ORCH_STUB/claude" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "- Critical: 0"
SH
chmod +x "$ORCH_STUB/claude"

run_orchestrator_125() { # $1: ログ名 / $2: 追加フラグ（任意） / stdout: rc
  local tag="$1" extra="${2:-}" rc=0
  rm -rf "$TMP/orch-out"
  mkdir -p "$TMP/orch-out"
  set +e
  # shellcheck disable=SC2086 # $extra は単一フラグ。分割させたい
  ( cd "$REPO" && run_isolated PATH="$ORCH_STUB:$PATH" bash "$MULTI_AGENT" \
      --task review --cli claude-code --perspective code-review \
      --base develop --timeout 30 --output-dir "$TMP/orch-out" $extra ) \
      >"$TMP/orch-${tag}.log" 2>&1
  rc=$?
  set -e
  echo "$rc"
}

for mode in parallel sequential; do
  case "$mode" in
    parallel)   ORCH_RC="$(run_orchestrator_125 "$mode" "")" ;;
    sequential) ORCH_RC="$(run_orchestrator_125 "$mode" "--sequential")" ;;
  esac
  if [ "$ORCH_RC" -ne 0 ]; then
    ok "${mode}: orchestrator が非 0 終了する (rc=${ORCH_RC})"
  else
    bad "${mode}: アダプタが 125 で落ちたのに orchestrator が 0 で終わった"
    tail -12 "$TMP/orch-${mode}.log" | sed 's/^/    | /' >&2
  fi
  if grep -qF 'Orchestrator-side failure, not the CLI' "$TMP/orch-${mode}.log"; then
    ok "${mode}: 125 を専用の分類で報告する（CLI のクラッシュ調査へ送らない）"
  else
    bad "${mode}: 125 が汎用の Failed に丸められている（読み手が存在しない CLI クラッシュを追う）"
    tail -12 "$TMP/orch-${mode}.log" | sed 's/^/    | /' >&2
  fi
  if grep -qF 'No output file' "$TMP/orch-${mode}.log"; then
    bad "${mode}: 125 の失敗が「No output file」としても報告されている（成果物は書けている）"
  else
    ok "${mode}: 「No output file」は出ない（rc=0 なのに成果物が無い形のための砦を汚さない）"
  fi
done
rm -rf "$TMP/orch-out"

echo "== 4 アダプタの書き込み失敗の受け止め（静的 pin） =="

# behavioral ケース (e) は claude-code しか通らない。他 3 本が `write_output` の rc を
# 捨てる旧形へ戻る退行は、呼び出しの直後に受け止めがあることを行順で固定して留める。
for adapter in claude-code codex-cli copilot-cli grok-cli; do
  f="$ADAPTERS_DIR/${adapter}-adapter.sh"
  w_line=""
  w_line="$(grep -n '^write_output "\$OUTPUT_FILE" "\$CLI_NAME" "\$perspective_name" "\$result"' "$f" 2>/dev/null | tail -1 | cut -d: -f1)" || true
  g_line=""
  g_line="$(grep -n '|| fail_output_write "\$perspective_name" "\$OUTPUT_FILE"' "$f" 2>/dev/null | tail -1 | cut -d: -f1)" || true
  if [ -n "$w_line" ] && [ -n "$g_line" ] && [ "$g_line" -eq $((w_line + 1)) ]; then
    ok "${adapter}: write_output の直後で書き込み失敗を受け止めている"
  else
    bad "${adapter}: 書き込み失敗の受け止めが無いか並びが崩れている (write_output=${w_line:-なし} 受け止め=${g_line:-なし})"
  fi
done

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ review-capture-fail-loud verify: $FAIL 件失敗" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ review-capture-fail-loud verify: 全 $PASS 件 pass"
FF_REACHED_END=1
