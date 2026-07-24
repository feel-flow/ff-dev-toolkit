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
const PROCESS_TIMEOUT_MS = 30_000;

const cleanupDirs: string[] = [];

function makeTempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  cleanupDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (cleanupDirs.length > 0) {
    const dir = cleanupDirs.pop();
    if (dir !== undefined) rmSync(dir, { recursive: true, force: true });
  }
});

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
  options: { cwd?: string; path?: string; env?: Record<string, string> } = {},
): { readonly status: number | null; readonly output: string } {
  const result = spawnSync("bash", [scriptPath], {
    cwd: options.cwd ?? REPO_ROOT,
    encoding: "utf8",
    timeout: PROCESS_TIMEOUT_MS,
    env: sanitizedEnv({
      PATH: options.path ?? BASE_PATH,
      ...options.env,
    }),
  });
  if (result.error) throw result.error;
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
});

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
});
