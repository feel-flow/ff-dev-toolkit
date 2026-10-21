#!/usr/bin/env bash
# adapter-common.sh の構成ファイル: 検証要約・重大度パーサ・本文の受理・typed verdict。
#
# scripts/adapters/adapter-common.sh が source されたときに 1 回だけ source する
# （直接実行しない）。読み込む順・読めないときの停止は入口の
# ADAPTER_COMMON_PARTS が正本。本文は分割前の adapter-common.sh の連続した行そのままで、
# トップレベルの初期化（readonly・trap）も分割前と同じ順に走る。
# ここへ set / trap / source を足さない（本文に元からある trap は分割前のまま）。
# 末尾の _ac_part_loaded の行は読み込み完了の印。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: 呼び出し元の adapter が set -euo pipefail の下で adapter-common.sh を source する

# ── Output Helpers ──

# Verification is independent of review completion and finding severity.
# Missing, malformed and unreadable records never imply successful checks.
review_verification_summary() {
  local state
  if [[ ! -f "$1" || ! -r "$1" ]] || ! state="$(_ff_severity_scan verification "$1")"; then
    state=unknown
  fi
  case "$state" in
    passed) echo '**検証: 記録されたコマンドは実行済み・成功**' ;;
    failed) echo '**検証: 実行済みの失敗あり** — 成功とは扱わない。' ;;
    failed-skipped) echo '**検証: 実行済みの失敗あり・一部未実施** — 下記の verification 行を確認し、親担当が裏取りする。' ;;
    skipped) echo '**検証: 一部未実施** — 未実施項目と失敗の有無は下記の verification 行を確認し、親担当が裏取りする。' ;;
    none) echo '**検証: 未実施** — 実行記録なし。指摘なしを検証成功とは扱わない。' ;;
    *) echo '**検証: 未確認** — 記録なし・書式不正・読み取り不能。検証成功とは扱わない。' ;;
  esac
}

# ── Review-body fail-loud gate（Issue `#893`）──
# 各アダプタが捕捉するのは CLI が stdout へ出した最終出力だけで、サブ CLI が
# レビュー本文をセッション途中のターンに出力すると、捕捉結果には前置き・メタ記述
# （「本レスポンスは read-only レビュー sub-agent の報告であり…」の 1 段落）だけが
# 残る。exit 0 + 非空出力なので empty-output ガードを素通りし、`Status: complete`
# の「実質未レビュー」成果物が統合レポートに完了として並ぶ（`#882` のセルフレビューで
# claude-code の実測 616〜761 bytes の空振りを観測。捕捉経路は 4 アダプタ共通の
# `result=$(run_with_timeout ...)` なので、ゲートも 4 アダプタ共通に掛ける）。
#
# ■ 受理条件（正）— ここが唯一の定義。4 アダプタのゲートコメント・tests/run-all.sh の
# 登録コメント・診断文（describe_cli_failure / fail_cli_task のバナーと body・各アダプタ
# の ERROR 行）・公開 CHANGELOG は、この列挙への参照または同一列挙で書くこと（初版から
# 2 度、記述ごとに条件がズレた）。診断文の英語正規形は下の定数
# REVIEW_BODY_REFUSAL_PHRASE の 1 箇所だけに置き、describe_cli_failure / fail_cli_task /
# 4 アダプタの ERROR 行 / 委譲経路の退避理由はこの定数を展開する（文面を複製しない）。
#
# **受理は型付き判定行だけ**（ADR-065 で導入し、ADR-066 で散文経路を受理と Critical
# 判定から外した）。コードフェンス外に有効な (t) 行が 1 行でもあれば受理（rc=0）、
# 1 行も無ければ不受理（rc=1）。散文の重大度行（下の (s1)〜(s4)）は、どれだけ
# あっても受理の根拠にならない。bullet は `-` / `*` / `+` の 3 種を等価に扱う:
#   (t) 型付き判定行 — コードフェンス外の bullet 行
#       `- verdict: severity=<critical|warning|suggestion|info> failure_scenario=<yes|no>
#        confidence=<0〜100 の整数> [file=<パス>] [line=<1 以上の整数>]`
#       （キーは順不同・各 1 回・小文字。行はこの key=value の並びだけで構成する）、
#       または指摘ゼロを型付きで宣言する `- verdict: none`。
#   (t) が 1 行も無い本文は不受理（アダプタは missing-review-body の INCOMPLETE 成果物へ
#   落とし、委譲経路は応答を退避する）。散文の重大度行だけの本文（下の散文の分類が
#   実体行を見つけた本文）を拒否した回は、診断として
#   `typed-verdict: prose-only review refused (no valid verdict line)` を stderr へ
#   1 行出す（review_body_present の第 2 引数でラベルを渡すと
#   `typed-verdict: <ラベル>: prose-only review refused (no valid verdict line)` の形に
#   なる。アダプタは `<CLI 表示名>/<観点>`、ホスト委譲は `<レーン>/<観点>` を渡す。空
#   ラベルはラベル部ごと省く）。rc は不受理のまま — 散文の分類は「レビュアーが型付き
#   契約を無視して散文で書いた」ことを前置きだけの本文と区別して名指しする診断にだけ
#   使い、受理を決めない（ADR-066。旧版の散文フォールバック警告はこの診断に置き換えた）。
#   受理した回・散文の実体行も無い本文の不受理・Critical 検出・抽出のモードでは出さない。
#   `verdict` を名乗る候補行 — 行頭（引用 `>`・bullet・番号付き `1.` / `1)`・無印の
#   いずれか）の後に強調やバッククォートを挟んで `verdict` 語が来て、かつ行が `=` か
#   `none` 語を含む行 — のうち文法を満たさないもの（必須キーの欠落・値域外・未知キー・
#   重複キー・key=value でない語・強調や大文字の `verdict`・コロン欠落・番号付きや
#   引用の中の行）は型付きとして採らず、`typed-verdict: line N: rejected (<理由コード>)`
#   を stderr へ出す（黙って散文扱いにしない）。その行は散文の行分類（診断用）へは
#   そのまま流れる。ただし不採用行が `severity=critical`（大小無視）を含むときは、
#   Critical 検出だけは他の型付き行の判定より先に Critical ありへ倒す（fail-safe。
#   診断に `counted as critical (fail-safe)` を添える）。受理判定と抽出は変えない。
#   `=` も `none` も含まない行（`- **Verdict:** Approve` 等の散文）は候補にしない。
#   フェンス内の (t) 行は引用として無視する（診断も出さない）。
#
# 以下は散文の行分類。ADR-066 以降は**診断だけ**に使う — 受理も Critical の有無も
# 決めない。使い道は 3 つの診断: (1) 散文だけの本文を拒否した回の
# `prose-only review refused`、(2) 有効な (t) 行が散文の Critical を覆した回の
# `prose Critical finding overridden …`、(3) (t) 行の無い本文に散文の Critical が
# あった回の `prose Critical finding in a body without typed verdict lines …`。
# 分類の網羅は tests/severity-parser-intersection が診断の有無として固定する。
# 下の記述の「受理」「発火」は旧版の意味のまま残してある — 診断が「散文の実体行
# あり」「散文の Critical あり」と読む条件のこと:
#
# **強調の許容（s1 / s2 / s3 / s4 / c3 に共通。BEGIN ブロックの emph が唯一の実装）**:
# 件数**値**とゼロ語は markdown 強調で囲まれていてもよい（`- Critical: **0**` /
# `- Critical: **なし**` / `- **指摘なし**` / `- **なし**` / `- **指摘 0 件**` /
# 行全体を囲む `- **Critical: 0**`）。**コロンの前後**も強調を跨げる — ラベルと
# コロンをまとめて囲む `- **Critical:** 0` / `- **Critical:** なし` /
# `- *Critical:* 0`（全角コロン `- **Critical：** 0` も同じ）。この形は `**` が
# `:` の後ろへ来るためラベル側の `[*]*` でも値側の emph でも吸収できず、s1 では
# なく s3 へ落ちて偽の CRITICAL_BLOCK を立てていた。コロン形は s1 / s3 が
# 共有するので、受理と検出の両モード・全ラベルへ同時に効く。
# レビュー本文は LLM 出力で強調の有無が実行ごとに揺れるため、書式差でゲートの
# 通過可否が変わらないようにしている。
# 実装は `[*_]*` の前後付けなので、**不均衡・種類不一致の強調**（`**0` / `_0*` /
# `0__` / `- **Critical**_: 0`）も受ける。値・ゼロ語側だけに掛けていた間は
# 「ゼロ判定を緩める方向にしか効かない」と言えたが、**コロン形に入って以降は
# 行の分類そのものを広げる**ので非ゼロ件数・実指摘の発火も増える（`- Critical_: 5`
# は不受理・不発火から受理・発火へ変わる）。向きは fail-safe = 検出漏れを作らない
# 側なので、強調の厳密な対応付けはしていない:
#   (s1) 件数行 — 行頭（任意の bullet / `**` 強調可）が critical / warning /
#        suggestion（大文字小文字・複数形不問、Issues / Vulnerabilities / Gaps 修飾可）
#        + コロン + **数値またはゼロ語（なし / none / n/a / zero / ゼロ）**の行
#        （`- CRITICAL: 3` / `Critical: 0` — error-handler-hunt が根拠付き 0 件を
#        返す正常系を含む）。**数値は直後が行末 / 空白+行末 / `/` 区切り / 「件」/
#        全角開き括弧のときだけ件数と認める**（`Warning: 401 authentication
#        expired` や `Critical: 0-day exploit` を件数と誤認しない。ゼロ語も直後が
#        行末 / `/` / 「。」/ 全角開き括弧のときのみ）。値を行内に持つ自己完結行
#        なので、行単位の参照語 veto の対象外（`Critical: 0 / Warning: 0 /
#        Suggestion: 0（前述の観点はすべて確認済み）` のような契約準拠ゼロ報告 +
#        参照注記を落とさない）
#   (s2) ゼロ件報告行 — 行頭（任意の bullet 可）が「指摘なし」「該当なし」
#        「指摘事項なし」で始まる行、または「指摘 … 0 件」の行（上の**強調の
#        許容**のとおり `- **指摘なし**` / `- **指摘 0 件**` も含む）。(s1) と
#        同じく自己完結行として参照語 veto の対象外
#   (s3) ラベル付き指摘行 — bullet または行頭 `**` 強調の重大度ラベル + コロン +
#        **非空の本文**（`- Suggestion: 〜を単純化できる` / `**Warning**: …`）。
#        参照語 veto の対象（`- Critical: 詳細は前のターンです` は不受理）
#   (s4) 重大度見出し配下の bullet 行 — critical / warning / suggestion / 重大度 を
#        含む Markdown 見出しのスコープ内（次の見出しまで）の bullet 行。指摘
#        （comprehensive-review の `### Critical` + `- **要約**（file:line）` 形）と
#        `- なし` / `- **なし**` 等の空所見（上の**強調の許容**）の別を問わない。
#        参照語 veto の対象
# 除外規則（実体行に数えない）:
#   - 参照語の行単位 veto — 「前のターン」「前述」「報告済み」「上記で報告/完了」
#     earlier/previous turn・reported above/earlier・see above を含む行は (s3)(s4)
#     として数えない（`Critical: 詳細は前のターンです` 型の復唱・参照を塞ぐ。
#     (s1)(s2) は値を行内に持つため行単位 veto はしない — 「前述の観点はすべて
#     確認済み」のような注記付きゼロ報告は受理される）。veto は**行単位のみ** —
#     メッセージ単位の完了主張 veto（「上記で完了」等で全体を落とす）は 5 巡目で
#     導入したが 6 巡目で撤回した: プロンプト契約に存在しない語彙で正当なレビュー
#     （対象コードの説明に同語を含む等）を全損させ、検出力も完全一致 3 パターンに
#     留まるため。したがって「完了主張の散文 + 契約準拠ゼロ行」は受理される
#     （既知の限界。塞ぐなら受理契約側ではなくプロンプト契約とセットの別対応）
#   - コロン後が空のラベル（`Critical:` 単独）と、bullet も `**` も持たない
#     ラベル + 散文（`Warning: authentication expired` 型の CLI エラー文）は
#     (s1)(s3) のどちらにも該当しない = 不受理。**ただしラベルとコロンを強調で
#     囲んだ `- **Critical:**`（コロン後が本文として空）は例外で、コロン直後の
#     `*` が (s3) の非空本文に当たるため受理・発火する（既知の限界。強調を
#     跨がせる前からの挙動で、ここを塞ぐと `- **Critical:** 0` 側の分類が壊れる）
#   - コードフェンス内の行 — テンプレートを引用しただけの出力を受理しない。
#     フェンスは CommonMark 準拠で追跡する: 開始行（``` / ~~~、3 文字以上）の
#     文字種と長さを記録し、**同種・同長以上・フェンス文字列の後が空白のみ・
#     インデント 3 以下**の行でのみ閉じる（バッククォートフェンス内の ~~~、
#     4 連フェンス内の 3 連、```info-string 付きの行では閉じない）。レポート
#     全文を閉じたフェンスで包んだ出力も不受理（Execution Boundary が包むことを
#     禁止）
#   - 見出し行そのもの — (s4) のスコープを開くだけで、見出し単独の出力は不受理
# 未閉フェンス（フェンスが閉じないまま本文が終わる）の扱い: どこからが引用か確定
# できないため、フェンスマスクを放棄し、**全文のどこかに自己完結行（s1/s2/s3）が
# あれば受理・無ければ不受理**とする。統合レポートの CRITICAL 判定（multi-agent.sh）
# が未閉フェンス（rc=2）を「素通りさせない側 = Critical あり」へ倒すのと同じ向きで、
# 実体の証拠なしに受理はしない（tests/multi-agent-critical-marker のケース 7 / 16 は
# フェンス内に `- Critical: 1` を持つため、このフォールバックで従来どおり通る）。
# どの実体行も無ければ rc=1 = 本文なし。散文中の重大度語（「上記のレビューで
# Critical 1 件…詳細は前述のとおり」等）は行頭アンカーと参照行 veto で落ちる。
# バイト長は判定に使わない — 実体行を持たない出力は、長くても出力契約（各 perspective
# の Output Template。件数サマリ節を持つ 8 観点 + comprehensive-review のゼロ件時
# 独立行契約）に反する未検証結果として不合格にする（長さは診断に併記する）。
# なお perspective の Output Template と Execution Boundary の集約指示は、この受理
# 条件を満たす形を CLI へ明示している（契約の一本化 — 指示なしにゲートだけで落とさない）。
#
# 既知の判別限界（語彙では判別不能なもの）:
#   - bullet 付きのエラー文（`- Warning: rate limit exceeded` 等）は (s3) の形と
#     区別できず受理される（エラー文と指摘文の語彙判別は行わない）
#   - bullet 無しの `CRITICAL: 説明` マーカー形は、同形の CLI エラー文と区別できない
#     ため**受理しない**（集約側の CRITICAL 検出はこの形を引き続き検出する —
#     受理と検出は別契約）
#
# 不受理の診断文の英語正規形（上の受理条件ヘッダの冒頭を参照）。describe_cli_failure /
# fail_cli_task / 4 アダプタの ERROR 行 / 委譲経路の退避理由がこの 1 箇所を展開する。
# 文面を変えるときはここだけを変える（tests/review-capture-fail-loud が成果物・アダプタの
# ERROR 行・委譲経路の退避理由で照合する）
REVIEW_BODY_REFUSAL_PHRASE='no valid typed verdict line (neither a `- verdict: severity=... failure_scenario=... confidence=...` line nor `- verdict: none`)'

# ── 共有重大度行パーサー（Issue `#908`）──
# 受理判定（review_body_present）と統合レポートの Critical 検出
# （critical_findings_present — multi-agent.sh の CRITICAL_BLOCK 判定が呼ぶ）は、
# 下の _ff_severity_scan が持つ**同一の行分類**（CommonMark フェンス追跡・
# 重大度行文法 s1〜s4・数値ゼロ / ゼロ語のゼロ件文法・参照語 veto）を参照する。
# 両者が独立実装だった間は、片側へ語彙・境界を足すたびにズレて fail-open /
# 偽 BLOCK の両方向の非対称が再発した（Issue `#893` の 7 巡レビューで実測）。
# 語彙・境界の追加箇所は awk プログラムの BEGIN ブロック（正規表現の合成）だけ —
# 判定側（accept / critical の方針分岐）は合成済みの分類フラグしか見ない。
# 文法をここへ足すときは、受理と検出の両方へ同時に効くことを
# tests/severity-parser-intersection（同じ入力表を両モードへ流す積集合テーブル）
# が固定する。
#
# モードと終了コード:
#   accept   — rc0: 有効な (t) 行あり / rc1: なし（散文の実体行だけの本文を含む）。
#              (t) 行はフェンス外で読んだものだけを数える（未閉フェンスの内側では
#              数えない）。散文の分類は拒否時の診断にだけ使う（未閉フェンスの本文は
#              旧版のマスク放棄フォールバックの条件で「散文の実体行あり」と読む）
#   critical — rc0: Critical あり（(t) 行の severity=critical、または不採用行の
#              fail-safe）/ rc1: なし（(t) 行はあるが critical 0 件）/ rc20: 未閉
#              フェンスで判定不能 / rc21: 有効な (t) 行が無く判定の根拠が無い
#              （ドメイン専用値 — awk 自身の異常終了 rc=2 と衝突させない。公開 rc への
#              写像は critical_findings_present が行う）
#   verdicts — 有効な (t) 行をレコードとして stdout へ出す（typed_verdicts_extract
#              の本体。書式は同関数のヘッダ）。rc0: 有効な (t) 行あり / rc1: なし /
#              rc20: 未閉フェンス
# 型付き判定行（(t)）の検出は 3 モードで同じフェンス追跡・同じ文法（BEGIN の vd_*）を
# 使う。有効な (t) 行は散文の行分類へ流さない（`### Critical` 配下の
# `- verdict: none` を c3 の実所見に数えない）。
# critical モードの最優先は**不採用行の fail-safe**: 不採用にした候補行が
# severity=critical を含む回は、他の判定を見ずに Critical あり（rc0）とする。
# 次に**型付き**: 有効な (t) 行が 1 行でもあれば、Critical の有無は
# (t) 行の severity=critical の件数だけで決める（`verdict: none` は 0 件）。
# failure_scenario=no による降格はまだ掛けない（集約側の段で入れる）。散文側が
# Critical を検出していたのに (t) 行が Critical 0 件だった回は、覆したことを
# stderr へ 1 行出す（黙って消さない。verdicts モードでも同じ条件で出す）。
# **(t) 行が無い本文は判定しない**（rc21 = 根拠なし。ADR-066）。散文の Critical を
# 数えて決めることはしない — 受理が (t) 行を要求するので、ここへ来るのは拒否・失敗
# した回の INCOMPLETE 成果物か、旧版で受理された結果だけ。扱いは呼び出し側が決める
# （multi-agent.sh は未完了の観点なら本文から判定せず、完了扱いの結果なら安全側 =
# Critical ありへ倒す）。散文の (c1)〜(c4) が Critical を見つけていた回は
# `typed-verdict: prose Critical finding in a body without typed verdict lines (not counted)`
# を stderr へ 1 行出す（verdicts モードでも同じ条件で出す）。
# 散文の Critical の分類条件（診断用。行分類は accept と共有し、方針だけが異なる）:
#   (c1) s1 件数行のうち、ラベルが critical で件数が 1 以上のもの（bullet 3 種・
#        `**` 強調・先頭空白・全角コロン・Issues / Vulnerabilities / Gaps 修飾を
#        受理側と同一に認める。明示ゼロ = 数値 0 とゼロ語 5 種は s1 と同じ境界で除外）
#   (c2) s3 ラベル付き指摘行のうちラベルが critical のもの（参照語 veto の対象 —
#        受理されない参照行は検出でも実所見に数えない）
#   (c3) critical を含む見出し（no critical / non-critical を除く）のスコープ配下の
#        bullet 行。ただし行分類の**ゼロ判定が優先** — s1/s2 に分類された明示ゼロ・
#        ゼロ件報告行（`- Critical: none` / `- Critical: 0` / `- 指摘なし（注記
#        つき）`）はスコープ内でも実所見に数えない。空所見語彙の裸 bullet
#        （なし / 該当なし / 特になし / 指摘なし / 指摘事項なし / none / n/a /
#        no issues）と参照語 veto 行も不算入。
#        さらに**ゼロ宣言の後ろは抑止する**（crit_zero）— 同じ critical スコープで
#        一度ゼロを宣言したら、そのスコープの残りの bullet は c3 で数えない。
#        ゼロ宣言 = 明示ゼロ / ゼロ件報告行（cls_zero）・空所見語彙の bullet・
#        bullet 無しの散文ゼロ宣言（`なし。` / `該当なし` / `none` — 語彙は
#        BEGIN ブロックの zero_decl_re）。**強調形も同じくゼロ宣言**（`- **なし**` /
#        `**指摘なし**`）— 上の**強調の許容**のとおりで、これは抑止の側を広げる
#        （強調ゼロ宣言の後ろの bullet が c3 で数えられなくなる）。抑止は次の
#        見出し（head_re）で解除する。
#        抑止を入れた理由: レビュアーが Critical 節へ「なし。」と書いた後ろへ
#        裏取り・補足の箇条書き（`- DOMAIN.md:322 の記述は正確` 型のメモ）を
#        置く形が実所見として数えられ、どの CLI も Critical を報告していない
#        レビューで CRITICAL_BLOCK が立つ偽陽性が実測された。
#        既知の限界: ゼロ宣言の後ろに本物の所見（`- [app.txt:2] …` + 信頼度行）を
#        続けて書いた矛盾レポートは c3 では数えない（ゼロ宣言側を信じる）。この
#        限界は**強調形のゼロ宣言にも同じく及ぶ**（`- **なし**` + 実所見 → 数えない。
#        強調を許す前は発火していた形なので、抑止の範囲はその分広がっている）。件数行
#        （`Critical: 1`）を併記していれば c1 が拾うので検出は維持される — ただし
#        s1 は行頭の 1 ラベルでスキャンが確定するため、**集約件数行
#        （`Critical: 2 / Warning: 0`）では critical が先頭ラベルのときだけ**この
#        逃げ道が成立する。語順を入れ替えた `Warning: 0 / Critical: 2` は c1 が
#        届かない（強調の有無を問わず同じ。tests/severity-parser-intersection が
#        既知の限界として固定している）。
#        抑止は c3 だけに掛かる — c1 / c2 / c4 はゼロ宣言の後でも従来どおり発火する
#   (c4) 行頭（列 0）の `CRITICAL:` マーカー行（明示ゼロ行を除く）。bullet 無しの
#        この形は受理側の実体行ではない（受理と検出は別契約 — 検出だけが広い唯一の形)
_ff_severity_scan() { # $1: ff_mode (accept|critical|verdicts|verification) / 本文: stdin または $2 のファイル
  # verification は共通フェンス追跡で実施記録だけを集約する。記録不在・不正は unknown、
  # awk 自体の失敗は呼び出し側が unknown へ写像し、受理・重大度には影響しない。
  # awk は入力を読み切ってから終了する（早期 exit の SIGPIPE 反転を作らない）。
  # awk 自体の失敗は accept では rc 非 0 = 本文なし側（fail-loud）、critical では
  # 0/1/20 以外 = 判定不能側（wrapper が写像し、呼び出し側が Critical ありへ倒す）。
  # 見出しの `#+` と先頭スペースに interval（{0,3} 等）を使わない — BSD awk の
  # interval 対応に依存しないため。7 個以上の # は Markdown 見出しではないが、
  # スコープ開始として扱っても実体行の要求は変わらない。
  # found = フェンスマスク下の実体行 / found_any = 自己完結行（s1/s2/s3）をフェンスを
  # 無視して数えたもの（accept モードのみ使用）。accept の未閉フェンス分岐は found と
  # found_any の**論理和**で判定する（フェンス外で見つけた実体行も、放棄したマスクの
  # 内側で見つけた自己完結行も、どちらも受理の根拠になる。s4 はスコープがフェンスと
  # 独立に定義できないため found_any には含めない）。
  local ff_mode="$1"
  shift
  # 散文だけの本文を拒否した診断のラベル（accept モードだけが使う）。呼び出し側が
  # _FF_SCAN_LABEL で渡す — 引数位置は本文ファイルに使っているため
  awk -v ff_mode="$ff_mode" -v label="${_FF_SCAN_LABEL:-}" '
    # ── 型付き判定行（(t)）の検証 ──
    # 候補行（vd_cand_re）を厳密文法で読み、1 = 指摘 / 2 = `verdict: none` /
    # 0 = 不採用 を返す。不採用の理由は名前付きのコードで集め、1 行の診断にまとめて
    # stderr へ出す（黙って散文扱いにしない）。指摘のときは vd_sev / vd_fs / vd_conf /
    # vd_file / vd_line に値を置く。
    # 不採用の行が `severity=critical`（大小無視）を含むときは vd_rej_crit を数える。
    # critical モードはこれを Critical ありへ倒す（fail-safe — 書式の崩れた Critical
    # 宣言を、他の有効な型付き行や散文の判定で黙らせない）。受理判定と抽出の
    # レコードには影響しない（不採用行はレコードに出さない）。
    function vd_reject(why, line,    note) {
      note = ""
      if (tolower(line) ~ vd_rej_crit_re) {
        vd_rej_crit++
        if (!accept && !extract) note = " — counted as critical (fail-safe)"
      }
      printf "typed-verdict: line %d: rejected (%s)%s: %s\n", NR, why, note, substr(line, 1, 200) > "/dev/stderr"
      return 0
    }
    function vd_parse(line,    rest, n, i, t, eqp, k, v, why, toks, hs, hf, hc, hfi, hl) {
      if (line !~ vd_head_re) return vd_reject("malformed-head", line)
      rest = line
      sub(vd_head_re, "", rest)
      sub(/[[:space:]]+$/, "", rest)
      if (rest == "none") return 2
      if (rest ~ /^none[[:space:]]/) return vd_reject("none-with-extra", line)
      if (rest == "") return vd_reject("empty", line)
      vd_sev = ""; vd_fs = ""; vd_conf = ""; vd_file = ""; vd_line = ""
      hs = 0; hf = 0; hc = 0; hfi = 0; hl = 0
      why = ""
      n = split(rest, toks, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        t = toks[i]
        eqp = index(t, "=")
        if (eqp <= 1) { why = why ",stray-token"; continue }
        k = substr(t, 1, eqp - 1)
        v = substr(t, eqp + 1)
        if (k == "severity")              { if (hs++) why = why ",duplicate-severity";         vd_sev = v }
        else if (k == "failure_scenario") { if (hf++) why = why ",duplicate-failure_scenario"; vd_fs = v }
        else if (k == "confidence")       { if (hc++) why = why ",duplicate-confidence";       vd_conf = v }
        else if (k == "file")             { if (hfi++) why = why ",duplicate-file";            vd_file = v }
        else if (k == "line")             { if (hl++) why = why ",duplicate-line";             vd_line = v }
        else why = why ",unknown-key"
      }
      if (!hs) why = why ",missing-severity"
      else if (vd_sev !~ /^(critical|warning|suggestion|info)$/) why = why ",bad-severity"
      if (!hf) why = why ",missing-failure_scenario"
      else if (vd_fs !~ /^(yes|no)$/) why = why ",bad-failure_scenario"
      # confidence は 0〜100 の整数。桁数を 3 までに絞ってから数値比較する（巨大な
      # 桁列を浮動小数へ変換しない。先頭ゼロの `085` は 85 として受ける）
      if (!hc) why = why ",missing-confidence"
      else if (vd_conf !~ /^[0-9]+$/ || length(vd_conf) > 3 || vd_conf + 0 > 100) why = why ",bad-confidence"
      if (hfi && vd_file == "") why = why ",bad-file"
      if (hl && vd_line !~ /^[1-9][0-9]*$/) why = why ",bad-line"
      if (why != "") return vd_reject(substr(why, 2), line)
      return 1
    }
    BEGIN {
      accept = (ff_mode == "accept")
      extract = (ff_mode == "verdicts")
      # ── 行分類の正規表現（共有フラグメントからここで 1 回だけ合成する）──
      # 語彙・境界（重大度ラベル・数値 / ゼロ語とその境界・bullet 種別・コロン形）の
      # 追加箇所はこの BEGIN ブロックだけ。判定側は分類フラグ cls / cls_zero /
      # cls_crit を参照する — 判定式に語彙を再複製すると、片側だけに語彙を足す
      # 従来の非対称がこの関数の内側で再発する（Issue `#908` セルフレビューで実測）。
      sp    = "[[:space:]]"
      # 件数**値**を囲む markdown 強調（`**0**` / `*0*` / `__0__`）。ラベル側は
      # 以前から `[*]*` で強調を許していたが、値側は許していなかったため
      # `- Critical: **0**` が s1（件数行）に落ちず、s3（ラベル付き指摘行）へ
      # 流れて「Critical あり」と判定されていた。レビュー本文は LLM 出力なので
      # ゼロを太字で書くかは実行ごとに揺れ、同じ差分・同じ 0 件でもゲートが
      # 通ったり落ちたりしていた。
      # 件数**値**と**ゼロ語**の両方に掛ける。片側だけに入れると同根の非対称が
      # 残り、`- **指摘なし**` / `- **なし**` が偽の Critical として発火し続ける
      # （s1 側だけ直した版で実測）。
      # ゼロ語側で観測可能な効果を持つのは s2a_re と zero_decl_re の 2 箇所。
      # s4_empty_re にも掛けてあるが、こちらは zero_decl_re に包含され（同じ
      # zerow・同じ末尾・bullet が必須か任意かの違いだけ）、critical モードでは
      # 同じ行の先行文が先に crit_zero を立てるため到達しない。accept モードでは
      # そもそも参照されない。保険として揃えてあるだけで、外しても契約テストは
      # 緑のまま（実測: 一致しない値へ置換しても 107/107 pass）。
      emph  = "[*_]*"
      lab   = "(critical|warning|suggestion)s?( issues| vulnerabilities| gaps)?"
      # コロンの**前後**にも強調を跨がせる。ラベルとコロンをまとめて囲む
      # `- **Critical:** 0` は、ラベル側の `[*]*` でも値側の emph でも吸収できない
      # （`**` が `:` の後ろに来るため numv / zerov が数字・ゼロ語へ届かず、s1 では
      # なく s3 = ラベル付き指摘行へ落ちて偽の CRITICAL_BLOCK を立てていた）。
      # LLM が出す markdown として頻出で、値側・ゼロ語側の強調を許した回と同じ
      # 失敗形（実レポートで実測）。colon は s1 / s1_zero / s3b / s3s が共有する
      # ため、受理（review_body_present）と検出（critical_findings_present）の
      # 両モード・全ラベルへ同時に効く。
      colon = sp "*" emph sp "*(:|：)" sp "*" emph sp "*"
      numv    = emph "[0-9]+" emph sp "*(\\/|件|（|$)"   # 件数と認める数値（境界つき）
      numzero = emph "0+" emph sp "*(\\/|件|（|$)"       # 明示ゼロの数値形（同じ境界）
      zerov   = emph "(なし|none|n\\/a|zero|ゼロ)" emph sp "*(\\/|。|（|$)"  # ゼロ語 5 種
      b_opt = "^" sp "*[-*+]?" sp "*"          # bullet 任意（s1/s2）
      b_req = "^" sp "*[-*+]" sp "+"           # bullet 必須（s3 の bullet 形）
      s1_re      = b_opt "[*]*" lab "[*]*" colon "(" numv "|" zerov ")"
      s1_zero_re = b_opt "[*]*" lab "[*]*" colon "(" numzero "|" zerov ")"
      lab_crit_opt = b_opt "[*]*critical"      # s1 のラベルが critical か（前方一致）
      s2a_re = b_opt emph "(指摘なし|該当なし|指摘事項なし)" emph
      s2b_re = b_opt emph "指摘[^0-9]*0" emph sp "*件"
      s3b_re = b_req "[*]*" lab "[*]*" colon "[^[:space:]]"
      # ラベル直後の `**` は emph で受ける（リテラル要求にしない）。`**Critical**: 本文`
      # だけでなく、強調がコロンを跨ぐ `**Critical:** 本文` も同じ s3 へ落とすため。
      # リテラル `\*\*` を要求していた間、bullet 無しのこの形は s1/s2/s3 のどれにも
      # 該当せず c2 が発火しなかった。同じ本文に `**Warning:** 0` のような件数行が
      # 1 行でもあると受理は成立するので、**欠測（fail-loud）だったものが「本文あり・
      # Critical なし」（無音の fail-open）へ化ける**。ヘッダ s3 の定義「bullet または
      # 行頭 `**` 強調のラベル + コロン + 非空の本文」へ実装を揃えた形でもある。
      s3s_re = "^" sp "*\\*\\*" lab emph colon "[^[:space:]]"
      lab_crit_breq   = b_req "[*]*critical"       # s3 bullet 形のラベルが critical か
      lab_crit_strong = "^" sp "*\\*\\*critical"   # s3 強調形のラベルが critical か
      s4_bullet_re = "^" sp "*[-*+]" sp
      zerow        = "(なし|該当なし|特になし|指摘なし|指摘事項なし|none|n\\/a|no issues)"
      s4_empty_re  = "^" sp "*[-*+]" sp "*" emph zerow emph "[[:space:]。.]*$"
      # ゼロ宣言（c3 の抑止トリガ — ヘッダの (c3) を参照）。s4_empty_re から bullet
      # 要求を外した形で、bullet 無しの散文ゼロ宣言（`なし。` / `該当なし` / `none`）
      # も同じ語彙で拾う
      zero_decl_re = "^" sp "*([-*+]" sp "*)?" emph zerow emph "[[:space:]。.]*$"
      bare_re      = "^critical:"
      bare_zero_re = "^critical:" sp "*(" numzero "|" zerov ")"
      # ATX 見出し: 先頭の字下げはスペース 0〜3 個のみ（CommonMark — スペース 4 個
      # 以上とタブ字下げは indented code であり見出しではない）
      head_re = "^ ? ? ?#+" sp
      # ── 型付き判定行（(t)）の文法 — 語彙の追加箇所はここと vd_parse だけ ──
      # 候補（vd_cand_re。小文字化した行へ当てる）は広めに取る: 行頭の任意空白の後に
      # 引用 `>`（0 個以上）・bullet（- * +）/ 番号付き（`1.` / `1)`）/ 無印のいずれか、
      # 任意の強調（* _）とバッククォート、そして `verdict` 語が来る行。区切り
      # （`:` / `：` / `=`）の有無は問わない（コロン欠落・バッククォート囲み・番号付き・
      # 引用内の行を診断なしに散文へ落とさないため）。ただし行が `=` か `none` 語を
      # 含むときだけ候補にする（vd_cand_ok）— `- **Verdict:** Approve` のような散文
      # レビューの行を候補にも診断にもしない。拾った行は厳密文法（vd_head_re。元の
      # 行へ当てる）で読み、外れたら名前付きの診断を出す（malformed-head 等）。
      vd_cand_re   = "^" sp "*(>" sp "*)*([-*+]" sp "+|[0-9]+[.)]" sp "+)?[*_`]*verdict([^a-z]|$)"
      vd_none_word = "(^|[^a-z])none([^a-z]|$)"
      vd_head_re   = "^" sp "*[-*+]" sp "+verdict:" sp "+"
      # 不採用行の fail-safe（vd_reject 参照）。値側の強調・バッククォートも跨ぐ
      vd_rej_crit_re = "severity" sp "*=" sp "*[*_`]*critical"
    }
    /^[[:space:]]*(```|~~~)/ {
      # CommonMark 準拠のフェンス追跡:
      #   開始 — スペース 0〜3 個の字下げ + 同種 3 文字以上。タブ字下げは 4 列扱い
      #          = indented code なのでフェンスにしない。backtick フェンスは info
      #          string に backtick を含む行を開始と認めない（CommonMark）
      #   閉じ — 同種・同長以上・フェンス文字列の後が空白のみ・スペース 0〜3 個
      # 単純な反転トグルだとバッククォートフェンス内の ~~~ や 4 連フェンス内の
      # 3 連、```not-a-closing-fence のような info string 付きの行を「閉じ」と誤認し、
      # 引用中のテンプレート bullet が実体行として扱われる。
      match($0, /^ */)   # 字下げはスペースのみ数える（タブ混じりは ch 検査で落ちる）
      indent = RLENGTH
      rest = substr($0, RLENGTH + 1)
      ch = substr(rest, 1, 1)
      run = 0
      while (substr(rest, run + 1, 1) == ch) run++
      tail = substr(rest, run + 1)
      if ((ch == "`" || ch == "~") && run >= 3) {
        if (fence == 0) {
          if (indent <= 3 && !(ch == "`" && index(tail, "`") > 0)) {
            fence = 1; fence_ch = ch; fence_len = run; next
          }
        } else if (ch == fence_ch && run >= fence_len && indent <= 3 && tail ~ /^[[:space:]]*$/) {
          fence = 0; next
        }
      }
      # 開閉いずれの条件も満たさないフェンス様の行（タブ字下げ・スペース 4 個以上・
      # info string 内 backtick 等）は通常行 / 引用の中身として fall through —
      # 下の実体行評価で扱う（フェンス内は !fence ガードで found が立たない）
    }
    {
      if (ff_mode == "verification") {
        if (fence) next
        v = $0
        sub(/^[[:space:]]*/, "", v)
        sub(/[[:space:]]*$/, "", v)
        if (v == "- verification: none") vn++
        else if (v ~ /^- verification: (passed|failed|skipped) [|] [^[:space:]].*$/) {
          split(v, vp, " ")
          if (vp[3] == "passed") vok++
          else if (vp[3] == "failed") vfail++
          else vskip++
        } else if (tolower(v) ~ /^(([-*+>]|[0-9]+[.)])[[:space:]]*)?[*_`]*verification[[:space:]]*:/) vbad++
        next
      }
      l = tolower($0)
      isref = (l ~ /前のターン|前述|報告済み|上記で報告|上記で完了|earlier turn|previous turn|reported above|reported earlier|see above/)
      if (!fence && l ~ head_re) {
        # 見出しスコープはレベル追跡で持つ: 開いたスコープより深い見出し
        # （サブセクション）はスコープを維持し、同深度以浅の見出しで閉じて
        # 再評価する（旧 Critical 検出側のモデル。受理側もこれに統一 —
        # `### Critical` 配下の `#### 詳細` の bullet を両側が同じに扱う）。
        match(l, /#+/)
        lvl = RLENGTH
        is_sev = (l ~ /critical|warning|suggestion/ || index($0, "重大度") > 0)
        is_crit = (l ~ /critical/ && l !~ /no[[:space:]]+critical/ && l !~ /non-critical/)
        if (!(in_sev && lvl > sev_lvl)) { in_sev = is_sev; sev_lvl = lvl }
        if (!(in_crit && lvl > crit_lvl)) { in_crit = is_crit; crit_lvl = lvl }
        crit_zero = 0   # ゼロ宣言による c3 抑止は次の見出しで解除する
        next
      }
      # ── 型付き判定行（(t)）— フェンス外の候補行だけを読む（フェンス内は引用）──
      # 有効な行は数えて散文の行分類へは流さない。不採用の行は診断を出したうえで
      # 散文の行分類へそのまま流す（散文経路の判定は (t) が無い本文と同じ）。
      if (!fence && l ~ vd_cand_re && (index(l, "=") > 0 || l ~ vd_none_word)) {
        vd_r = vd_parse($0)
        if (vd_r == 1) {
          vd_n++
          if (vd_sev == "critical") vd_crit++
          if (extract) printf "finding\t%d\t%s\t%s\t%d\t%s\t%s\n", NR, vd_sev, vd_fs, vd_conf + 0, vd_file, vd_line
          next
        }
        if (vd_r == 2) {
          vd_none++
          if (extract) printf "none\t%d\n", NR
          next
        }
      }
      # ── 行分類（唯一の分類箇所 — 判定側はこのフラグだけを見る）──
      # cls: 1 = s1 件数行 / 2 = s2 ゼロ件報告行 / 3 = s3 ラベル付き指摘行
      # cls_zero: その行が明示ゼロ（数値ゼロ / ゼロ語 / ゼロ件報告）であること
      # cls_crit: その行のラベルが critical であること
      # 参照語 veto は s3/s4 のみ（s1/s2 は値を行内に持つ自己完結行 — ヘッダ参照）。
      cls = 0; cls_zero = 0; cls_crit = 0
      if (l ~ s1_re) {
        cls = 1
        cls_zero = (l ~ s1_zero_re)
        cls_crit = (l ~ lab_crit_opt)
      } else if ($0 ~ s2a_re || $0 ~ s2b_re) {
        cls = 2
        cls_zero = 1
      } else if (!isref && l ~ s3b_re) {
        cls = 3
        cls_crit = (l ~ lab_crit_breq)
      } else if (!isref && l ~ s3s_re) {
        cls = 3
        cls_crit = (l ~ lab_crit_strong)
      }
      if (accept) {
        if (cls) {
          found_any = 1
          if (!fence) found = 1
        }
        if (!fence && in_sev && !isref && l ~ s4_bullet_re) found = 1
      } else if (!fence) {
        # (c1)(c2) ラベルが critical の実体行（s1 件数行 / s3 指摘行）のうち明示ゼロ
        # でないもの。分類フラグだけで判定する — ここに語彙を書かないこと
        if (cls && cls_crit && !cls_zero) found = 1
        # (c3) critical 見出しスコープ配下の bullet。行分類のゼロ判定が優先 —
        # cls_zero の行（`- Critical: none` / `- Critical: 0` / `- 指摘なし（注記
        # つき）`）はスコープ内でも実所見に数えない。空所見語彙の裸 bullet と
        # 参照語 veto 行も不算入。さらに**ゼロ宣言の後ろは抑止する** — 同じ
        # スコープで一度ゼロを宣言した後の bullet は裏取り・補足として扱う
        # （抑止は次の見出しで解除。crit_zero は c3 だけに掛かり c1/c2/c4 は素通し）
        # ゼロ宣言の抑止トリガは**ラベルを見る**。s1 件数行（cls=1）はラベルを持つので
        # critical のゼロ（cls_crit）だけが抑止に効く — `### Critical` 配下の
        # `- **Warning:** 0` や `- **Suggestion:** 0 / **Critical:** 2` が後続の
        # 実所見を黙らせてはいけない。ラベルを持たないゼロ件報告行（cls=2 の
        # `- 指摘なし`）と散文ゼロ宣言（zero_decl_re）は従来どおり抑止に効く。
        # colon が強調を跨ぐようになって他ラベルの件数行が s1 ゼロへ落ちるように
        # なったため、ラベル非依存のままだと実所見の抑止が新たに生まれる。
        if (in_crit && ((cls_zero && (cls != 1 || cls_crit)) || l ~ zero_decl_re)) crit_zero = 1
        if (in_crit && !crit_zero && !isref && !cls_zero && l ~ s4_bullet_re && l !~ s4_empty_re) found = 1
        # (c4) 行頭の CRITICAL: マーカー（明示ゼロは s1 と同じ合成部品で除外。
        # 受理側の実体行ではないが検出は維持 — 受理と検出は別契約）
        if (l ~ bare_re && l !~ bare_zero_re) found = 1
      }
    }
    END {
      if (ff_mode == "verification") {
        if (fence || vbad || (vn && (vok + vfail + vskip)) || !(vn + vok + vfail + vskip)) print "unknown"
        else if (vskip && vfail) print "failed-skipped"
        else if (vskip) print "skipped"
        else if (vfail) print "failed"
        else if (vn) print "none"
        else print "passed"
        exit 0
      }
      vd_typed = vd_n + vd_none
      if (vd_n && vd_none) {
        printf "typed-verdict: `verdict: none` and %d finding line(s) both present; findings are counted\n", vd_n > "/dev/stderr"
      }
      # 型付き行が散文の Critical を覆した回は名指しする（ADR-065 決定 6）。検出（critical）
      # だけでなく抽出（verdicts）でも出す — 統合レポートの型付き経路は抽出だけを呼ぶので、
      # 検出モードにしか無いと覆した事実が stderr から消える。条件は両モードで同じ 1 箇所:
      # フェンスが閉じ、不採用行の fail-safe が立たず、有効な (t) 行があり、散文の行分類
      # （c1〜c4。受理モード以外で計算）が Critical を見つけ、(t) 行の Critical が 0 件
      if (!accept && fence == 0 && !vd_rej_crit && vd_typed && found && !vd_crit) {
        print "typed-verdict: prose Critical finding overridden by typed verdict lines (0 critical)" > "/dev/stderr"
      }
      # (t) 行が無い本文の散文 Critical は数えずに名指しだけする（ADR-066）。条件は上と
      # 同じ形で両モード共有: フェンスが閉じ、fail-safe が立たず、(t) 行が無く、散文の
      # 分類が Critical を見つけた回
      if (!accept && fence == 0 && !vd_rej_crit && !vd_typed && found) {
        print "typed-verdict: prose Critical finding in a body without typed verdict lines (not counted)" > "/dev/stderr"
      }
      if (extract) {
        if (fence != 0) exit 20
        exit vd_typed ? 0 : 1
      }
      if (accept) {
        # 受理は型付き判定行だけ（ADR-066）。有効な (t) 行があれば受理、無ければ不受理
        if (vd_typed) exit 0
        prose_ok = (fence != 0) ? (found || found_any) : found
        # 散文の実体行があるのに (t) 行が無い本文は、レビュアーが型付き契約を無視して
        # 散文で書いた回。受理はしないが、前置きだけの本文と区別できるよう名指しの診断を
        # 1 行出す。ラベル（`<CLI>/<観点>` 等）があれば名指しする。空ラベルで
        # `typed-verdict: : …` にしない
        if (prose_ok) print "typed-verdict: " (label != "" ? label ": " : "") "prose-only review refused (no valid verdict line)" > "/dev/stderr"
        # 散文だけの本文の拒否はドメイン専用値 22 で返す（review_body_present が不受理 rc1 と
        # 理由の種別へ写す。awk 自身の異常終了 rc=2 と衝突させない）
        exit prose_ok ? 22 : 1
      }
      # 未閉フェンスはドメイン専用値 20 で返す — awk 自身の異常終了（構文エラー等は
      # rc=2）と衝突させない。公開 rc への写像は critical_findings_present が行う
      if (fence != 0) exit 20
      # 不採用の verdict 行が severity=critical を含む回は、型付き・散文の判定より
      # 先に Critical ありへ倒す（fail-safe。診断は vd_reject が出している）
      if (vd_rej_crit) exit 0
      if (vd_typed) {
        # 型付き（降格はまだ掛けない）。散文側の Critical を覆した回の名指しは上で出した
        exit vd_crit ? 0 : 1
      }
      # (t) 行が無い本文は判定の根拠が無い（ADR-066）。散文の Critical は数えない —
      # 名指しの診断は上で出した。扱いは呼び出し側が決める
      exit 21
    }
  ' "$@"
}

# rc0: 受理 / rc1: 不受理（有効な (t) 行なし）/ rc2: 本文を解析できず不受理（awk の
# 異常終了 — 壊れた UTF-8 で towc が失敗する等。「型付き行なし」とは別の理由として扱う）。
# 不受理の種別は REVIEW_BODY_REFUSAL_KIND（none = 散文の実体行も無い / prose = 散文の
# 重大度行だけ / unparsed = 解析できない）と REVIEW_BODY_REFUSAL_RC（awk の rc）へ残す。
# アダプタは同じシェルで呼ぶので、失敗処理（fail_cli_task / review_body_refusal_clause）が
# この 2 つを読んで理由の文面と理由コードを選ぶ。受理した回は空に戻す
REVIEW_BODY_REFUSAL_KIND=""
REVIEW_BODY_REFUSAL_RC=""
review_body_present() { # $1: captured review body / $2: 警告ラベル（任意）/ rc0 = 上記の受理条件を満たす
  # 本文は引数で受け取る（ファイル経路を持たないため、下の「不可読ファイルが
  # rc=1 へ化ける」fail-open の同型経路は無い）。$2 は散文だけの本文を拒否した診断に載せる
  # 名前（`<CLI 表示名>/<観点>` 等）で、判定には使わない
  local rc=0
  printf '%s\n' "$1" | _FF_SCAN_LABEL="${2:-}" _ff_severity_scan accept || rc=$?
  REVIEW_BODY_REFUSAL_RC="$rc"
  case "$rc" in
    0)  REVIEW_BODY_REFUSAL_KIND=""; return 0 ;;
    1)  REVIEW_BODY_REFUSAL_KIND="none"; return 1 ;;
    22) REVIEW_BODY_REFUSAL_KIND="prose"; return 1 ;;
    *)  REVIEW_BODY_REFUSAL_KIND="unparsed"; return 2 ;;
  esac
}

# 不受理の理由を 1 句で返す（アダプタの ERROR 行・委譲の退避理由が
# `<主語> $(review_body_refusal_clause) — refusing it as a review result.` の形で使う）。
# 直前の review_body_present が残した種別を読む。解析できなかった回は「型付き行が無い」と
# 言わない — 本文に判定行があっても awk が落ちれば同じ不受理になるので、名指しを分ける
review_body_refusal_clause() {
  case "${REVIEW_BODY_REFUSAL_KIND:-}" in
    unparsed) echo "could not be parsed as a review body (the parser exited with status ${REVIEW_BODY_REFUSAL_RC:-?}, e.g. invalid UTF-8)" ;;
    *)        echo "contains ${REVIEW_BODY_REFUSAL_PHRASE}" ;;
  esac
}

# 型付き判定行による Critical 検出（multi-agent.sh の不採用行 fail-safe の判定が呼ぶ）。
# rc0: Critical あり（(t) 行の severity=critical・不採用行の fail-safe）/ rc1: なし /
# rc2: 未閉フェンスで判定不能 / rc3: 判定不能（不可読ファイル・awk 実行失敗）/
# rc4: 有効な (t) 行が無く判定の根拠が無い（散文の Critical は数えない — ADR-066）。
# rc2 以上の扱いは呼び出し側の方針。
critical_findings_present() { # $1: result file
  # 読めない・存在しないファイルを rc=1（Critical なし）に倒さない（fail-open
  # 防止）。ファイルは awk 自身に開かせる — シェルの `< "$1"` は redirect 失敗が
  # rc=1 に化けるが、awk の open 失敗は異常終了（下の * 分岐）= 判定不能側に落ちる。
  [[ -r "$1" ]] || return 3
  local rc=0
  _ff_severity_scan critical "$1" || rc=$?
  case "$rc" in
    0 | 1) return "$rc" ;;
    20)    return 2 ;;  # awk のドメイン値（未閉フェンス）→ 公開 rc 2
    21)    return 4 ;;  # awk のドメイン値（有効な (t) 行なし）→ 公開 rc 4
    *)     return 3 ;;  # awk 異常終了（構文・シグナル・open 失敗）= 判定不能
  esac
}

# 型付き判定行（受理条件ヘッダの (t)）の抽出。受理・Critical 検出と同じ
# _ff_severity_scan（同じフェンス追跡・同じ文法）の verdicts モードを呼ぶ。
# stdout: 有効な (t) 行 1 行につき 1 レコード（タブ区切り）
#   finding <行番号> <severity> <failure_scenario> <confidence> <file> <line>
#   none    <行番号>
#   （file / line は省略時に空欄。confidence は 10 進整数へ正規化する）
# stderr: 不採用にした `verdict` 行ごとの `typed-verdict: line N: rejected (<理由>)`
#   と、散文の Critical を (t) 行が覆した回（検出モードと同じ条件）の
#   `typed-verdict: prose Critical finding overridden by typed verdict lines (0 critical)`、
#   (t) 行が無い本文に散文の Critical があった回（同じく検出モードと同じ条件）の
#   `typed-verdict: prose Critical finding in a body without typed verdict lines (not counted)`
# rc0: 有効な (t) 行あり / rc1: なし（散文だけの本文を含む）/ rc2: 未閉フェンスで
# 判定不能（それまでのレコードは出る）/ rc3: 判定不能（不可読ファイル・awk 実行失敗）。
# critical_findings_present と同じく、読めないファイルを rc1（型付き行なし）へ
# 倒さない。
typed_verdicts_extract() { # $1: result file
  [[ -r "$1" ]] || return 3
  local rc=0
  _ff_severity_scan verdicts "$1" || rc=$?
  case "$rc" in
    0 | 1) return "$rc" ;;
    20)    return 2 ;;
    *)     return 3 ;;
  esac
}
_ac_part_loaded="adapter-common-review.sh"
