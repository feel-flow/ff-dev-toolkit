# setup-multi-agent-yq

`scripts/setup-multi-agent.sh` の yq 導入・検証契約の回帰テスト（Issue #271）。

## 何を固定するか

1. **Linux の導入経路が distro パッケージに依存しない**  
   `apt-get install yq` / `yum install yq` / `pacman -S yq` を導入処理に使わない。
   Mike Farah 公式 GitHub release バイナリ（または macOS の `brew install yq`）だけを使う。
2. **存在するだけでは成功にしない**  
   Python yq / Mike Farah v3 / capability 欠落 shim を PATH に置いても、
   `ensure_yq` は成功表示せず非 0 を返す。
3. **install の exit 0 を信用しない（ACE-66-1）**  
   `install_yq` を成功スタブにしても、PATH 上に互換 yq が無い・別実装が残る場合は fail-loud。
4. **Homebrew 経路を壊さない**  
   package manager が brew のとき `brew install yq` を呼ぶ静的契約。
5. **互換な Mike Farah v4 は通る**  
   実環境の本物 yq があれば green。無ければそのケースだけ skip（他ケースは継続）。
6. **オフライン fixture で GitHub 経路を実測**  
   ホストの本物 yq をローカル release として置き、前方に非互換 yq がある状態から
   `download_yq_binary_to` → 配置 → PATH 先頭化 → 成功までをネットワーク無しで固定。

## 実行

```bash
bash plugins/ff-dev-toolkit/tests/setup-multi-agent-yq/verify.sh
# または
bash plugins/ff-dev-toolkit/tests/run-all.sh
```

一時ディレクトリを使う。書き込み不可の環境では suite ごと `○ skip`。
