# adapter-env-isolation-selftest

`tests/lib/adapter-env-isolation.sh` の検出力を、実行環境がクリーンなCIでも固定するself-test。

## 検証境界

- ライブラリの未設定 / 空配列 / 有値、prefix境界、重複除去、センチネル拒否、
  `env -u`後のケース固有代入を直接実測する
- 共通ライブラリをsourceするconsumerを自動発見し、現行9 suiteの名簿と双方向照合する
- `run_isolated`除去、センチネル部分欠落、先頭`unset_isolated_vars`のprobe内移動、
  `review-wrapper-shim`の素起動追加を隔離コピーへ入れ、各変異が名指しでredになることを測る

一時領域を作れない環境では行頭`○ skip`で終了する。ただし本suiteは
`run-all.sh`の`REQUIRED_SUITES`に含まれるため、既定run-allでは
`FF_RUN_ALL_ALLOW_SKIP`による明示許可なしに検出力を消せない。

```bash
bash plugins/ff-dev-toolkit/tests/adapter-env-isolation-selftest/verify.sh
```
