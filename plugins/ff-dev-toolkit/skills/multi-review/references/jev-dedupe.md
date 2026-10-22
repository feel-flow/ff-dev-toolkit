# 重複 finding の Jev 判定（判定点 dedupe）

§3-1 の工程 2（同じファイル・行・種類の指摘は 1 つにまとめる）の前に、`FF_JEV_MODE=on` のときだけ、親が委譲の前に次の入口を呼ぶ。`REVIEW_OUTPUT_DIR` には今回 `multi-review.sh --output-dir` に渡した出力先を、同じ Bash 呼び出しの中で代入する（既定値は置かない — 未設定・空は exit 2 で止まり、別の回の結果を判定しない）。判定点 `dedupe` は既定の名簿に無いので、`FF_JEV_POINTS` へ明示したときだけ Jev を呼ぶ。`off`（既定）と名簿に無いときはこの節が存在しないのと同じで、委譲プロンプトも結果も従来とバイト同一。

<!-- ff-jev-dedupe-entry:start -->
```bash
if [ "${FF_JEV_MODE:-off}" = on ]; then
  dedupe_rc=0
  FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/jev/review-dedupe.sh" "${REVIEW_OUTPUT_DIR:-}" || dedupe_rc=$?
  case "$dedupe_rc" in 0|11|12) ;; *) exit "$dedupe_rc" ;; esac
fi
```
<!-- ff-jev-dedupe-entry:end -->

- 入口の stdout が空でなければ、§3-1 の委譲プロンプトの末尾へそのまま足す（Jev が閾値以上の confidence で「同じ欠陥」と判定した対の一覧と、その扱いの指示）。空なら何も足さない。stderr の集計行（`review-dedupe: pairs=…`）はプロンプトへ足さない
- 足した対はサブエージェントが本文を読み比べずに 1 件へまとめる（両方の CLI 名と観点を併記し、重大度は高い方を採る）。まとめた結果に同じレーンの別の指摘が 2 件以上入るときは、そのレーンの指摘どうしは別のまま残す（評価は対ごとで、連鎖したまとめ方の精度は測っていない）。一覧に無い対（Jev が「別」と答えた・閾値未満・失敗）は従来どおり判定する。採用した対を Jev へ再送せず、従来の判定と二重に走らせない
- まとめても `CRITICAL_BLOCK` / `CRITICAL_NONBLOCK` は変わらない（結果ファイルごとに先に決まっている）。まとめ方で Critical / Warning を落とさない
- 終了コード 0 / 11 / 12 は続行する（11 は Jev の経路が使えなかった回で、出力は空）。2 / 64 / 69 は従来経路へ黙って落とさず、止めて直す
- 対の作り方（同じ回の別レーン・同じ file・行差 ≤ 5）と Jev へ渡す本文は offline 評価と同じコード（`scripts/jev/build-dedupe-eval-sets.ts --run`）。組み込み閾値 0.8 の根拠（事前登録した採否規則と帯別表）・有効化と戻し方の正本は `${FF_DEV_TOOLKIT_ROOT}/scripts/jev/README.md` §切替
