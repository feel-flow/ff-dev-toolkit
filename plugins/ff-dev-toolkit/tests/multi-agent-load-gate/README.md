# multi-agent-load-gate test

`scripts/multi-agent.sh` のレーン起動前の負荷判定（Issue `#1810`）と、`--perspective` のカンマ区切り受理（Issue `#1833`）を検証する suite。

## 検査

| 群 | 内容 |
| --- | --- |
| (A) 契約 | 正本 `docs-template/05-operations/deployment/multi-cli-review-orchestration.md` の `lane-load-gate` 節の規定行（閾値の形・既定係数 10・根拠の実測 3 件・係数の環境変数・閾値以下で無出力）と、`git-workflow.md` ステップ6 からの参照。既定係数は実装の定数 `LOAD_GATE_DEFAULT_PER_CORE` とも照合する |
| (B) 挙動 | stub codex で 2 タスクを実走し、load average を内部の注入口 `FF_MULTI_AGENT_LOAD_SAMPLE` で与える。閾値超 → 判定 1 行（閾値 = コア数 × 既定 10 の実値まで照合）+ 逐次、閾値以下 → 無出力で並列、境界（load = 閾値は並列、+0.01 は逐次）、係数 `0` → 判定しない、係数不正 → プラン構築前に rc=2（前回結果を消さない。dry-run / `--sequential` / 1 タスク / 7 桁以上でも）、係数 `08` → 10 進、1 タスク → 判定しない、注入値が数値でない → 原因を名乗る注記 1 行で並列。注入なしの実測経路（`sysctl` が `PATH` に無い形を含む）も 1 回ずつ走らせる |
| (C) カンマ区切り | `--perspective a,b` の分割、繰り返し指定との併用、区切りだけの値（`,`）の拒否、分割後の各語が `is_safe_token` を通ること（dry-run） |
| (D) 検出力 | orchestrator の一時コピーから負荷判定の呼び出し行 / カンマ分割を外す変異、比較を `>=` にする変異で (B) / (C) の針が赤になることを同じ実行内で実測する |

## 他 suite との関係

`tests/lib/adapter-env-isolation.sh` の `run_isolated` は `FF_MULTI_AGENT_LOAD_PER_CORE=0` を置いて負荷判定を止める。全件ゲート自体がホストの負荷を上げるため、判定を生かしたままだと並列起動や待機行の位置を固定する suite（multi-agent-serialization / multi-agent-review-banner 等）が負荷次第で赤になる。本 suite だけが `env -u` でその固定を外し、既定係数の挙動を見る。

実 CLI・ネットワーク・課金は伴わない。単独実測 約 12 秒（2026-09-27）。
