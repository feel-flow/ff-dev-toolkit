// ace-run-ts.sh の runner 判定用 probe（Issue #932）
//
// 役割は 1 つだけ: 「候補の runner が、本番と同じ `<候補> <script.ts>` の形で
// **同梱ゲートと同じ土台の TypeScript を実際に実行できる**」ことを、標準出力の 1 行で示す。
//
// フラグ（`--version` 等）を足す probe は使えない。外側のラッパーがそのフラグを
// 自分で消費しうるため、内側の tsx へ届かないまま exit 0 が返る（実測: yarn 1.22.22 は
// `yarn exec tsx --version` に yarn 自身の version を出して成功する）。フラグを含まない
// この形なら、どのラッパーを通しても引数はファイルパスとして内側へ渡る。
//
// 出力する値は**呼び出し側が実行時に渡す使い捨てトークン**である。固定文字列だけを
// 出すと、このファイルの内容を表示するだけの候補（`cat` のような形）が「実行できた」
// ことになってしまう — その候補は続く本番実行でもゲートを実行せず、内容を表示して
// exit 0 する。つまり**ゲートが走らないまま緑になる**。トークンはこのソースのどこにも
// 現れないので、環境変数を読んで出力できるのは実際に実行された場合だけになる。
//
// 型注釈と「node 互換の実行系か」の確認を置いているのは意図的である。同梱ゲートは
// `node:fs` / `node:path` を使うので、TypeScript を変換するだけの実行系や node 組み込みを
// 持たない実行系を採用すると、probe は通ってもゲート本体で初めて失敗する。ここで
// `process.versions.node` を要求しておけば、その候補は probe の時点で落ちる。
// `node:fs` を実際に import してはいない — このディレクトリは型検査の対象外で
// `@types/node` が解決されないため、import すると編集時に型エラーとして出続ける。
// 判定したいのは「node 互換の実行系か」なので、実行時の値で確認すれば足りる。
//
// 「型注釈があれば JavaScript 専用の実行系は必ず構文エラーになる」とは書かない —
// 近年の Node は `.ts` の型注釈を剥がして実行できるため、それは環境依存の主張になる。
// 判定の本体はあくまでトークンであり、型注釈と実行系の確認は「ゲートと同じ土台か」を
// probe 側へ近づけるための追加条件である。
const proc: { env?: Record<string, string | undefined>; versions?: { node?: string } } =
  (globalThis as {
    process?: { env?: Record<string, string | undefined>; versions?: { node?: string } };
  }).process ?? {};
const token: string = proc.env?.ACE_RUN_TS_PROBE_TOKEN ?? "";
// ファイルシステムには触らない — 読めない cwd を持つサンドボックスで
// 「実行できたのに不採用」になるのを避ける。
const nodeLike: boolean = typeof proc.versions?.node === "string" && proc.versions.node.length > 0;
console.log("ACE_RUN_TS_PROBE_OK:" + (nodeLike ? token : ""));
