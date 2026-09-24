# 工数実績の書き戻し（`ff-effort` ブロック）と乖離帯の較正

`/close-issue` 手順 5a・6 の詳細。本線は「ブロックがあれば実績を書き戻し、帯の外なら乖離の原因を書く」だけを持ち、規則の全文はここに置く。閉じる Issue に `ff-effort` ブロックが無い回は読まなくてよい。

## 書き戻す値

- **AI 実績は観測事実つきで申告する**。人時換算そのものは AI の判断だが、根拠となる観測可能な事実（`gh pr view "$PR_NUMBER" --json additions,deletions,commits,reviews` の差分行数・コミット数・レビュー往復回数・品質ゲートの実行回数）を必ず併記する。事実を伴わない数字は報告として不完全に扱う — 検証できない数字は KPI の母集団を汚す
- **単位はブロックの宣言に従う**。`- effort_unit: h` 行のあるブロックは `N.Nh`（小数第 1 位まで、最小 1.0h）、宣言の無い旧ブロックは起票時と同じ `N.Nd`（1d = 8h）で書く。宣言と食い違う単位で書くと集計器が `excluded_unit_mismatch` として母集団から外す
- **hook の実測を自己申告値と並記する**（`effort_ai_actual` を置き換えない）。値は `finish.sh precheck` の `EFFORT_<Issue番号>_*` 行（`scripts/effort-report.sh --issue-metrics <Issue番号>` の読み出し。記録は `${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/metrics/` から作業中のリポジトリの行だけを読む）: `wallclock_actual_h` を `effort_wallclock_actual: N.Nh`（ブランチ作成からこの書き戻し時点 = マージ直前まで）、`instruction_bytes` を `effort_instruction_bytes: N`、`change_class` を `effort_change_class:`（`docs-only` / `small` / `other`）として書く。記録置き場が無い・読めない・hook を `FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS=1` で止めている等で値が `(unmeasured)` のときは、そのまま `(unmeasured)` と書く（0 と書かない・マージは止めない）。この 3 行は Issue 単位の累積値なので、1 Issue に複数 PR でも加算せず最新の値で置き換える
- **人間の実績は書かない**（`effort_human_actual` という項目は作らない）。人間は実際には作業しないため実績は原理的に取れず、人間側は永久に予定（反実仮想）である
- **乖離率はブロックに書かない**。`effort_ai_planned` と `effort_ai_actual` から導出できる値であり、下の加算ケースで静かに stale になる。乖離率は完了報告コメントと集計器がその都度計算する

按分・加算の規則:

| 状況 | 扱い |
| ---- | ---- |
| 1 PR が複数 Issue を閉じる | 各 Issue の `effort_ai_planned` **比で按分**する。等分は大小混在で嘘になる。明らかに比と違うと判断した場合のみ上書きし、按分根拠を `effort_evidence` に 1 行書く |
| 1 Issue に複数 PR | `effort_ai_actual` が記入済みなら**加算**する（上書きしない）。加算した旨を `effort_evidence` に書く |

書き戻す形（`effort_basis` は起票時のまま保持し、`effort_evidence` を足す）:

```markdown
<!-- ff-effort:begin -->
- effort_unit: h
- effort_human_planned: 24.0h
- effort_ai_planned: 4.8h
- effort_ai_actual: 11.2h
- effort_wallclock_actual: 6.5h
- effort_instruction_bytes: 431000
- effort_change_class: other
- effort_evidence: diff +412/-88 / レビュー往復 2 / fix commit 2 / 全件ゲート 3 回
- effort_basis: （起票時のまま）
<!-- ff-effort:end -->
```

マーカー行 `<!-- ff-effort:begin -->` / `<!-- ff-effort:end -->` は**綴りを変えない**。集計器 `effort-report.sh` がこの 2 行を境界に本文を切り出すため、変えると集計から静かに落ちる。

## 完了報告コメントの工数実績セクション

```markdown
### 工数実績

| 区分 | 予定 | 実績 | 備考 |
| ---- | ---- | ---- | ---- |
| 人間（換算） | 24.0h | — | 実作業なし。圧縮率の基準線 |
| AI | 4.8h | 11.2h | 乖離率 2.33（閾値 1.40 超） |

観測事実: diff +412/-88 / レビュー往復 2 / fix commit 2 / 全件ゲート 3 回
圧縮率: 24.0h ÷ 11.2h = 2.1 倍

**乖離の原因**: 契約ゲートの mutation テストが予定に入っていなかった（レビューで要求され 4.0h 相当を追加）
```

- **`ff-effort` ブロックが無い Issue では節ごと省略する**（手順 5a のスキップと対になる）
- 人間の実績欄は常に `—`。「まだ埋めていない」ではなく「原理的に埋まらない」の意味である
- **乖離率が閾値の外（`0.71` 未満 または `1.40` 超）にある場合、「乖離の原因」は必須**。何が予定に無かったか（過小）／何を過剰に見込んだか（過大）を書く。閾値内なら省略してよい。**端ちょうど（`0.71` / `1.40`）は帯内**である
- **`0.71` は `1/1.40` の丸めであり、帯は乗法的に対称である**（どちらの方向にも 1.40 倍）。加法的な ±40%（= `0.60`）ではない。この導出を書かないと、「対称性を直す」つもりで加法側へ置換されたときに**すべてのゲートが緑のまま**過大側の検出帯が広がる（検査は 3 箇所の一致しか見ない）
- **この 2 値の複製先は 3 箇所**: 本ファイル（正本）・`/retrospective` の記録帯（`skills/retrospective/references/effort.md`）・`scripts/effort-report.sh` の `VARIANCE_LOWER` / `VARIANCE_UPPER`。変えるときは 3 箇所すべてを同時に直すこと
- 観測事実は手順 5a で取得した値をそのまま書く（記憶から書かない）

## 帯の較正手順（実測分布から引く）

閾値 `0.71` / `1.40` は**実測分布から導出した値**である。出荷時の暫定値（`0.77` / `1.30`。「0.6d 予定に対し 0.75d は運用上の誤差だが 2 倍は前提が壊れている」という設計判断）は、2026-09-10 に 3 リポジトリ・母集団 78 件で較正して置き換えた。次に較正するときも同じ手順で引く:

1. **母集団を取る**。`scripts/effort-report.sh --repo <owner/repo> --format kv` の `variance_population` が較正母集団で、その条件は集計器の除外規則と同一である — `effort_ai_actual` と `effort_ai_planned` がブロックの単位宣言どおりの正の数で記入されていること（`effort_unit: h` なら `N.Nh`、宣言の無い旧ブロックは `N.Nd` を 1d = 8h で人時へ正規化。乖離率は比なので単位に依らない）。次のものは母集団に入らない: `ff-effort` ブロック不在（`excluded_noblock`）／実績が未記入（`excluded_planned_only`）／**実績が複数 PR の加算更新の途中にあり同じキーが 2 行ある**・数値でない値・未知の単位宣言・未閉鎖ブロック（いずれも `excluded_malformed`）／単位宣言と値の単位の食い違い（`excluded_unit_mismatch`）。`suspect_marker` が 1 以上・`limit_reached=1` のまま較正しない（前者は本文が読めていない Issue が落ちている、後者は母集団が打ち切られている）
2. **分位点を読む**。同じ出力の `variance_p10` / `variance_p25` / `variance_median` / `variance_p75` / `variance_p90`
3. **上限を引く**。`上限 = max(p75, 1/p25)` を小数第 2 位へ丸める。これで帯は「中央値を中心に p25〜p75 を包む乗法対称帯」になる
4. **下限は上限の逆数**。`下限 = 1/上限` を小数第 2 位へ丸める。**乗法対称を崩さない**（加法的な ±x% にしない）
5. **p10〜p90 を包む案は採らない**。実測では下側の裾が長く（78 件で p10 = 0.27）、p10 を包むと上限が 3.7 倍まで広がって「2 倍は前提が壊れている」という判定機能が消える。下側の裾は帯を広げて隠す対象ではなく、`/create-issue` の目安表・推定手順で詰める対象である
6. **3 箇所を同時に直し**、`tests/effort-contract` の閾値検査と帯の端の fixture（`fixtures/band-edge.json`）も新しい値へ合わせる

較正に使った分布（2026-09-10・3 リポジトリ合算 78 件）: p10 = 0.27 / p25 = 0.75 / 中央値 = 1.00 / p75 = 1.40 / p90 = 1.75。上限 = max(1.40, 1/0.75 = 1.33) = 1.40、下限 = 1/1.40 = 0.71。
