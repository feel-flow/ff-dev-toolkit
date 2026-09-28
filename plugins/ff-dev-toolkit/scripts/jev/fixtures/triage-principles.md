# 分類の検証用原則

### P-001: 加法的な superset リリースをまとめた SDK bump は 1 PR にする
<a id="p-001"></a>
- 不変条件: 加法的な superset リリースをまとめた SDK bump は 1 PR にする

### P-002: SDK bump 前に consumer 側 touchpoint を repo 横断で grep 監査する
<a id="p-002"></a>
- 不変条件: SDK bump 前に consumer 側 touchpoint を repo 横断で grep 監査する

### P-003: lockfile の大幅差分は SDK bump と無関係な dedup を PR 本文で切り分ける
<a id="p-003"></a>
- 不変条件: lockfile の大幅差分は SDK bump と無関係な dedup を PR 本文で切り分ける
