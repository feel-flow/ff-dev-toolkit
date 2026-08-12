import { afterEach, describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const REPO_ROOT = resolve(__dirname, "../../..");
const POST_MERGE_HOOK = join(REPO_ROOT, "docs-template", ".claude", "hooks", "post-merge.ace.sample.sh");
const RUN_SUBAGENT = join(REPO_ROOT, "docs-template", "scripts", "ace", "run-subagent.sh");
const BASE_PATH = "/usr/bin:/bin";
const EXECUTABLE_MODE = 0o755;
// サブプロセスの上限。超えると spawnSync 側で打ち切られ、runBashScript がスクリプト名を
// 添えて投げ直す。**遅くなった退行を捕まえるのはこの 30 秒**であって下の 40 秒ではない
// ので、検出の緩さを変えたいときに動かすのはこちら。
const PROCESS_TIMEOUT_MS = 30_000;
// vitest の既定テスト timeout は 5 秒で、上の spawnSync 上限より**短い**。この逆転が
// あると、5 秒を超えたサブプロセスは spawn 上限に達していなくても
// "Test timed out in 5000ms" で落ちる。本物の hang（30 秒超）と、単に遅かっただけの
// 実行が同じ症状になり、区別できない。実測でも、別のエージェント・CLI が並行して
// 走っている環境で 6.5〜11.7 秒へ伸びて赤くなった（単独なら 4 件で 1〜2 秒。CPU を
// 全コア飽和させても再現しない — 効くのはプロセス起動と IO の競合のほう）。
//
// そこでテスト側の上限をサブプロセス上限より必ず長くし、2 つを式で結び付けて、
// 片方だけ変えたときに再び逆転しないようにする。
// テスト本体は同期実行なので、vitest のタイマーが spawnSync の途中へ割り込むことはない。
// TEST_TIMEOUT_MS が発火しうるのは「本体は成功したが 40 秒かかっていた」という事後判定
// だけで、あくまで保険。前提は **1 テストにつき runBashScript 1 回**で、2 回呼ぶと最悪
// 60 秒 > 40 秒となり保険が先に鳴る（そのときは差を広げること）。
//
// vitest の testTimeout をプロジェクト全体で引き上げなかったのは、プロセスを起動しない
// 残りのテストまで緩めてしまい、そちらの退行が見えなくなるため。
//
// この上限は describe の**第 3 引数**で渡す。vitest 4 では `describe(name, fn, {...})` の
// オブジェクト形は削除されており、渡すと収集ごと TypeError で落ちる。逆に第 3 引数を
// 落とすと黙って 5 秒へ戻るため、各 describe に task.timeout のアサーションを 1 件ずつ
// 置いてある。新しい describe を足すときも第 3 引数を忘れない。
const TEST_TIMEOUT_MS = PROCESS_TIMEOUT_MS + 10_000;

const cleanupDirs: string[] = [];

function makeTempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  cleanupDirs.push(dir);
  return dir;
}

// hookTimeout は testTimeout とは別物で、describe の第 3 引数は**フックへ継承されない**
// （既定 10 秒のまま）。ここは一時ディレクトリの再帰削除なので通常は届かないが、
// テスト本体を 11.7 秒へ伸ばした負荷では原理的に超えうる。超えたときに
// 「Hook timed out in 10000ms」という別レイヤの分かりにくい失敗へ化けるのを避けるため、
// テスト側と同じ上限へ明示的に結び付ける。
// なおこの結び付けはテストで固定していない（10 秒超かかるクリーンアップを人工的に
// 作る必要があり割に合わない）。describe 側の 3 件と違い、外しても検査は緑のまま — 
// 実測で確認済み。
afterEach(() => {
  while (cleanupDirs.length > 0) {
    const dir = cleanupDirs.pop();
    if (dir !== undefined) rmSync(dir, { recursive: true, force: true });
  }
}, TEST_TIMEOUT_MS);

function sanitizedEnv(overrides: Record<string, string> = {}): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && !key.startsWith("GIT_")) env[key] = value;
  }
  env.GIT_CONFIG_GLOBAL = "/dev/null";
  env.GIT_CONFIG_SYSTEM = "/dev/null";
  env.HOME = process.env.HOME ?? tmpdir();
  env.TMPDIR = process.env.TMPDIR ?? tmpdir();
  return { ...env, ...overrides };
}

function writeExecutable(path: string, content: string): void {
  writeFileSync(path, content);
  chmodSync(path, EXECUTABLE_MODE);
}

function runBashScript(
  scriptPath: string,
  options: { cwd?: string; path?: string; env?: Record<string, string>; timeoutMs?: number } = {},
): { readonly status: number; readonly output: string } {
  // timeoutMs は上限そのものを検査するテストのための上書き。これが無いと ETIMEDOUT 分岐は
  // 30 秒待たないと踏めず、事実上テスト不能になる。
  const timeoutMs = options.timeoutMs ?? PROCESS_TIMEOUT_MS;
  const result = spawnSync("bash", [scriptPath], {
    cwd: options.cwd ?? REPO_ROOT,
    encoding: "utf8",
    timeout: timeoutMs,
    env: sanitizedEnv({
      PATH: options.path ?? BASE_PATH,
      ...options.env,
    }),
  });
  if (result.error) {
    // ここへ来るのは spawn そのものが失敗したときだけ（ETIMEDOUT / ENOENT / EACCES など）。
    // スクリプトが単に非 0 で終了した場合は error が立たず status に載る。
    // エラーの spawnargs にはスクリプトのパスが入っているが、**message は
    // "spawnSync bash ETIMEDOUT" までしか持たない**。message だけを読む導線で見落とすため、
    // こちらで足しておく。
    // 上限値は ETIMEDOUT のときだけ足す — bash が PATH に無い ENOENT に "timeout: 30000ms"
    // が付くと、PATH の問題をハングと読み違える（Windows で実際に出る形）。
    // 追記は .stack を読む**前**に行うこと。V8 は最初に .stack へ触れた時点で文字列を
    // 固定するので、先に読むと追記がスタック側へ入らない。
    const error = result.error as NodeJS.ErrnoException;
    const limit = error.code === "ETIMEDOUT" ? `, timeout: ${timeoutMs}ms` : "";
    error.message = `${error.message} (script: ${scriptPath}${limit})`;
    throw error;
  }
  if (result.status === null) {
    // 外部シグナルで殺された場合、spawnSync は error を立てず status を null にする。
    // これをそのまま返すと `expect(status).not.toBe(0)` が null !== 0 で通ってしまい、
    // 検査対象の fail-loud 経路を一度も通らないまま緑になる（fail-open）。
    throw new Error(
      `${scriptPath} がスクリプト自身の exit で終了しなかった（signal=${result.signal ?? "unknown"}）`,
    );
  }
  return { status: result.status, output: `${result.stdout ?? ""}${result.stderr ?? ""}` };
}

function makeGitStub(scriptBody: string): string {
  const bin = makeTempDir("ace-fake-git-");
  writeExecutable(join(bin, "git"), scriptBody);
  return bin;
}

function makeRunSubagentGitStub(): { readonly bin: string; readonly repoRoot: string; readonly marker: string } {
  const bin = makeTempDir("ace-runner-bin-");
  const repoRoot = makeTempDir("ace-runner-repo-");
  const marker = join(repoRoot, "git-calls.log");
  writeExecutable(
    join(bin, "git"),
    `#!/bin/sh
set -eu
if [ "$1" = "rev-parse" ] && [ "$2" = "--is-inside-work-tree" ]; then
  echo true
  exit 0
fi
if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
  echo "$FAKE_REPO_ROOT"
  exit 0
fi
if [ "$1" = "worktree" ] && [ "$2" = "add" ]; then
  printf 'worktree-add branch=%s path=%s base=%s\n' "$4" "$5" "$6" >>"$GIT_MARKER"
  mkdir -p "$5"
  exit 0
fi
if [ "$1" = "worktree" ] && [ "$2" = "remove" ]; then
  printf 'worktree-remove path=%s\n' "$4" >>"$GIT_MARKER"
  rm -rf "$4"
  exit 0
fi
printf 'unexpected git args: %s\n' "$*" >&2
exit 99
`,
  );
  return { bin, repoRoot, marker };
}

function writeDateStub(bin: string, body: string): void {
  writeExecutable(join(bin, "date"), body);
}

describe("post-merge.ace.sample.sh", () => {
  it("git rev-parse --show-toplevel が失敗したら runner 欠落扱いで握り潰さず fail-loud に失敗する", () => {
    const bin = makeGitStub(`#!/bin/sh
if [ "$1" = "rev-parse" ] && [ "$2" = "--is-inside-work-tree" ]; then
  echo true
  exit 0
fi
if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
  echo 'show-toplevel failed' >&2
  exit 42
fi
exit 99
`);

    const result = runBashScript(POST_MERGE_HOOK, {
      path: `${bin}:${BASE_PATH}`,
      env: { ACE_SUBAGENT_ENABLED: "1" },
    });

    expect(result.status).not.toBe(0);
    expect(result.output).toContain("show-toplevel failed");
  });

  it("describe の第 3 引数が効いている（落とすと黙って 5 秒へ戻る）", ({ task }) => {
    expect(task.timeout).toBe(TEST_TIMEOUT_MS);
    expect(task.timeout).toBeGreaterThan(PROCESS_TIMEOUT_MS);
  });
}, TEST_TIMEOUT_MS);

describe("run-subagent.sh", () => {
  it("fake git/date 環境で worktree 作成まで到達する smoke test", () => {
    const { bin, repoRoot, marker } = makeRunSubagentGitStub();
    writeDateStub(bin, "#!/bin/sh\necho 1234567890\n");

    const result = runBashScript(RUN_SUBAGENT, {
      path: `${bin}:${BASE_PATH}`,
      env: {
        FAKE_REPO_ROOT: repoRoot,
        GIT_MARKER: marker,
        ACE_GARDEN_WALL_PATHS: "docs-template/08-knowledge/PLAYBOOK.md",
      },
    });

    expect(result.status).toBe(0);
    expect(result.output).toContain("worktree を作成しました");
    expect(result.output).toContain("ACE_CLAUDE_CMD が未設定");
    const markerContent = readFileSync(marker, "utf8");
    expect(markerContent).toContain("worktree-add branch=ace-capture-1234567890");
    expect(markerContent).toContain("base=develop");
  });

  it("git rev-parse --show-toplevel が失敗したら ACE_GARDEN_WALL_PATHS 未設定扱いにせず fail-loud に失敗する", () => {
    const bin = makeGitStub(`#!/bin/sh
if [ "$1" = "rev-parse" ] && [ "$2" = "--is-inside-work-tree" ]; then
  echo true
  exit 0
fi
if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
  echo 'runner show-toplevel failed' >&2
  exit 42
fi
exit 99
`);

    const result = runBashScript(RUN_SUBAGENT, {
      path: `${bin}:${BASE_PATH}`,
      env: { ACE_GARDEN_WALL_PATHS: "docs-template/08-knowledge/PLAYBOOK.md" },
    });

    expect(result.status).not.toBe(0);
    expect(result.output).toContain("runner show-toplevel failed");
    expect(result.output).not.toContain("ACE_GARDEN_WALL_PATHS が未設定");
  });

  it("date が失敗したら worktree add へ進まず fail-loud に失敗する", () => {
    const { bin, repoRoot, marker } = makeRunSubagentGitStub();
    writeDateStub(bin, "#!/bin/sh\necho 'date failed' >&2\nexit 88\n");

    const result = runBashScript(RUN_SUBAGENT, {
      path: `${bin}:${BASE_PATH}`,
      env: {
        FAKE_REPO_ROOT: repoRoot,
        GIT_MARKER: marker,
        ACE_GARDEN_WALL_PATHS: "docs-template/08-knowledge/PLAYBOOK.md",
      },
    });

    expect(result.status).not.toBe(0);
    expect(result.output).toContain("date failed");
    expect(existsSync(marker)).toBe(false);
  });

  it("describe の第 3 引数が効いている（落とすと黙って 5 秒へ戻る）", ({ task }) => {
    expect(task.timeout).toBe(TEST_TIMEOUT_MS);
    expect(task.timeout).toBeGreaterThan(PROCESS_TIMEOUT_MS);
  });
}, TEST_TIMEOUT_MS);

// 上の 4 件が拠り所にしている診断経路そのものを固定する。上限を 30 秒のまま許容できるのは
// 「発火したときスクリプト名が分かる」からで、その性質が無検証だと論拠ごと崩れる。
describe("runBashScript の失敗経路", () => {
  it("spawn に失敗したらスクリプト名を添えて投げ直し、errno を保つ", () => {
    const emptyBin = makeTempDir("ace-empty-bin-");

    let caught: NodeJS.ErrnoException | undefined;
    try {
      runBashScript(POST_MERGE_HOOK, { path: emptyBin });
    } catch (error) {
      caught = error as NodeJS.ErrnoException;
    }

    expect(caught?.code).toBe("ENOENT");
    expect(caught?.message).toContain("post-merge.ace.sample.sh");
    // PATH の問題に上限値が付くと、ハングと読み違える
    expect(caught?.message).not.toContain("timeout:");
  });

  it("上限に触れたら上限値つきで投げ直し、errno を保つ", () => {
    const dir = makeTempDir("ace-slow-script-");
    const script = join(dir, "sleeps.sh");
    writeExecutable(script, "#!/bin/sh\nsleep 5\n");

    let caught: NodeJS.ErrnoException | undefined;
    try {
      runBashScript(script, { timeoutMs: 200 });
    } catch (error) {
      caught = error as NodeJS.ErrnoException;
    }

    expect(caught?.code).toBe("ETIMEDOUT");
    expect(caught?.message).toContain("sleeps.sh");
    expect(caught?.message).toContain("timeout: 200ms");
  });

  it("外部シグナルで殺されたら status=null を返さず落ちる", () => {
    const dir = makeTempDir("ace-selfkill-");
    const script = join(dir, "selfkill.sh");
    writeExecutable(script, "#!/bin/sh\nkill -9 $$\n");

    // status=null をそのまま返すと `.not.toBe(0)` を通過してしまう
    expect(() => runBashScript(script)).toThrow(/signal=SIGKILL/);
  });
}, TEST_TIMEOUT_MS);
