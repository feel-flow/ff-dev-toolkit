import { afterEach, describe, expect, it, vi } from "vitest";
import { main, parseTarget, verifyDistillation, verifySection, verifyLocalGateRecord, verifySourceEntry } from "./check-domain-distillation";
import type { DistillationRequest, ReadGh } from "./check-domain-distillation";

const mergeSha = "a".repeat(40);
const headSha = "b".repeat(40);
const currentBaseSha = "c".repeat(40);
const input: DistillationRequest = {
  repo: "feel-flow/example", pr: "42", id: "ACE-i1338-1",
  target: "docs/design.md#rule", rule: "取消済みの注文は発送できない。",
};
const body = `<a id="rule"></a>\n## 注文の取消\n\n${input.rule}\n\n出典: [${input.id}](08-knowledge/playbook/domain.md#${input.id.toLowerCase()})\n`;
const sourceBody = `<a id="${input.id.toLowerCase()}"></a>\n\n### ${input.id}: 注文取消\n${input.rule}\n`;
const goodPr = { statusCheckRollup: [{ name: "validation" }], number: 42, state: "MERGED", mergedAt: "2026-09-08T01:00:00Z", mergeCommit: { oid: mergeSha },
  baseRefName: "develop", baseRefOid: "d".repeat(40), headRefOid: headSha, url: "https://github.com/feel-flow/example/pull/42" };
const pass = { name: "validation", bucket: "pass", state: "SUCCESS" };

function fixture(options: { pr?: object; checks?: unknown; pages?: unknown; merged?: string; current?: string; finalPr?: object; sourceMerged?: string; sourceCurrent?: string } = {}) {
  const calls: string[][] = [];
  const run: ReadGh = (args) => {
    calls.push([...args]);
    const endpoint = args[1];
    if (args[0] === "pr" && args[1] === "view") {
      return JSON.stringify({ ...goodPr, ...options.pr, ...(args.at(-1) === "headRefOid,mergeCommit,baseRefName,state,statusCheckRollup" ? options.finalPr : {}) });
    }
    if (args[0] === "pr" && args[1] === "checks") return JSON.stringify(options.checks ?? [pass]);
    if (endpoint.includes("/pulls/")) return JSON.stringify(options.pages ?? [[{ filename: "README.md", status: "modified" }], [{ filename: "docs/design.md", status: "modified" }]]);
    if (endpoint.includes("/commits/")) return JSON.stringify({ sha: currentBaseSha });
    if (endpoint.includes("/contents/")) {
      const isSource = endpoint.includes("/docs/08-knowledge/playbook/domain.md?");
      if (!isSource && !endpoint.includes("/docs/design.md?")) throw new Error("404: referenced source missing");
      const text = isSource ? (endpoint.endsWith(mergeSha) ? options.sourceMerged ?? sourceBody : options.sourceCurrent ?? sourceBody)
        : endpoint.endsWith(mergeSha) ? options.merged ?? body : options.current ?? body;
      return JSON.stringify({ type: "file", encoding: "base64", content: Buffer.from(text).toString("base64") });
    }
    throw new Error(`unexpected gh call ${JSON.stringify(args)}`);
  };
  return { run, calls };
}

afterEach(() => vi.restoreAllMocks());

describe("verifyDistillation", () => {
  it("reads all changed-file pages and verifies merged and pinned current-base contents", () => {
    const { run, calls } = fixture();
    expect(verifyDistillation(input, run)).toMatchObject({ repo: input.repo, pr: 42, mergeSha, headSha, currentBaseSha, target: input.target, id: input.id });
    expect(calls).toContainEqual(["api", "repos/feel-flow/example/pulls/42/files?per_page=100", "--paginate", "--slurp"]);
    expect(calls).toContainEqual(["api", `repos/feel-flow/example/contents/docs/design.md?ref=${mergeSha}`]);
    expect(calls).toContainEqual(["api", `repos/feel-flow/example/contents/docs/design.md?ref=${currentBaseSha}`]);
    expect(calls).toContainEqual(["api", `repos/feel-flow/example/contents/docs/08-knowledge/playbook/domain.md?ref=${mergeSha}`]);
    expect(calls).toContainEqual(["api", `repos/feel-flow/example/contents/docs/08-knowledge/playbook/domain.md?ref=${currentBaseSha}`]);
    expect(calls.filter((args) => args[0] === "pr" && args[1] === "view")).toHaveLength(2);
  });
  it.each(["OPEN", "CLOSED"])("rejects %s PR", (state) => {
    expect(() => verifyDistillation(input, fixture({ pr: { state } }).run)).toThrow("must be merged");
  });
  it.each([{ mergedAt: null }, { mergeCommit: null }, { mergeCommit: { oid: "main" } }, { headRefOid: null }])("rejects missing merge/SHA evidence %j", (pr) => {
    expect(() => verifyDistillation(input, fixture({ pr }).run)).toThrow();
  });
  it.each([[], [{ ...pass, bucket: "fail", state: "FAILURE" }], [pass, { ...pass, bucket: "pending" }],
    [pass, { ...pass, bucket: "cancel" }], [{ ...pass, state: "FAILURE" }], [{ ...pass, bucket: "skipping", state: "SKIPPED" }]].map((checks) => ({ checks })))("rejects missing or unsuccessful checks %j", ({ checks }) => {
    expect(() => verifyDistillation(input, fixture({ checks }).run)).toThrow("checks");
  });
  it("allows unrelated skipped checks alongside actual success", () => {
    expect(verifyDistillation(input, fixture({ checks: [pass, { name: "unrelated", bucket: "skipping", state: "SKIPPED" }] }).run).mergeSha).toBe(mergeSha);
  });
  it.each([[], [[{ filename: "other.md", status: "modified" }]], [[{ filename: "docs/design.md", status: "removed" }]]].map((pages) => ({ pages })))("rejects unchanged/removed target %j", ({ pages }) => {
    expect(() => verifyDistillation(input, fixture({ pages }).run)).toThrow("not changed");
  });
  it("rejects content removed after the PR merge (revert)", () => {
    expect(() => verifyDistillation(input, fixture({ current: body.replace(input.rule, "") }).run)).toThrow("expected rule");
  });
  it("rejects a source removed after the PR merge", () => {
    expect(() => verifyDistillation(input, fixture({ current: body.replace(`出典: [${input.id}]`, "source:") }).run)).toThrow("expected rule");
  });
  it("rejects a merged marker that lacks the rule", () => {
    expect(() => verifyDistillation(input, fixture({ merged: body.replace(input.rule, `Distilled-To: ${input.target}`) }).run)).toThrow("expected rule");
  });
  it("rejects PR head changes during check collection", () => {
    expect(() => verifyDistillation(input, fixture({ finalPr: { headRefOid: "e".repeat(40) } }).run)).toThrow("changed during");
  });
  it("fails closed on gh errors or invalid JSON", () => {
    expect(() => verifyDistillation(input, () => { throw new Error("gh unavailable"); })).toThrow("gh unavailable");
    expect(() => verifyDistillation(input, () => "not json")).toThrow();
  });
});

describe("section evidence", () => {
  it("accepts a source ../ link within the repository", () => {
    verifySection(body.replace("08-knowledge/", "../08-knowledge/"), { ...input, target: "docs/02-design/spec.md#rule" });
  });
  it("works without an anchor when the section is unambiguous", () => {
    verifySection(body, { ...input, target: "docs/design.md" });
  });
  it.each([
    body.replace("出典:", "## Other\n出典:"),
    body.replace("出典:", "Other\n=====\n出典:"),
    body + '\n<a id="rule"></a>\n',
    body.replace(`[${input.id}]`, "[ACE-i1338-10]"),
    body.replace(`#${input.id.toLowerCase()}`, "#ace-other"),
    body.replace("08-knowledge/playbook/domain.md", "https://example.com/domain.md"),
    body.replace("08-knowledge/playbook/domain.md", "../../outside.md"),
    body.replace(input.rule, `<!-- ${input.rule} -->`),
    body.replace(input.rule, `\`\`\`\n${input.rule}\n\`\`\``),
    body.replace(input.rule, `    ${input.rule}`),
    body.replace("出典: ", "`出典: ").trimEnd() + "`\n",
    body.replace('id="rule"', 'id="other"'),
    body + body,
  ])("rejects mismatched or non-prose evidence %j", (content) => {
    expect(() => verifySection(content, input)).toThrow();
  });
});

describe("input and CLI", () => {
  it.each(["/tmp/design.md", "../design.md", "https://example.com/a", "C:\\a.md", "docs/a.md#", "docs/a.md#one#two"])("rejects unsafe target %s", (target) => {
    expect(() => parseTarget(target)).toThrow();
  });
  it("uses shared normalization for encoded paths, spaces and safe relative segments", () => {
    expect(parseTarget("./docs/a/../design%20rules.md#rule")).toEqual({ path: "docs/design rules.md", anchor: "rule" });
    expect(verifyDistillation({ ...input, target: "./docs/a/../design.md#rule" }, fixture().run).target).toBe(input.target);
  });
  it("prints one JSON receipt on success", () => {
    const output = vi.spyOn(console, "log").mockImplementation(() => {});
    expect(main(Object.values(input), fixture().run)).toBe(0);
    expect(output).toHaveBeenCalledOnce();
    expect(JSON.parse(output.mock.calls[0][0] as string)).toMatchObject({ mergeSha, id: input.id });
  });
  it("invalid input exits 2 without any gh call", () => {
    const run = vi.fn<ReadGh>();
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main([input.repo, "0", input.id, input.target, input.rule], run)).toBe(2);
    expect(main([], run)).toBe(2);
    expect(run).not.toHaveBeenCalled();
  });
  it("verification failures exit 1 and never print a receipt", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const output = vi.spyOn(console, "log").mockImplementation(() => {});
    expect(main(Object.values(input), fixture({ pr: { state: "OPEN" } }).run)).toBe(1);
    expect(output).not.toHaveBeenCalled();
  });
});

const gateRecord = [
  "RECORD_VERSION=1", "STATUS=pass", `COMMIT=${headSha}`, "BRANCH=docs/issue-1338",
  "DIRTY=no", "GATE=tests/run-all.sh", "MODE=full", "SUITES=",
  "RESULT=passed=213 failed=0 skipped=0 not-run=0 excluded=0", "RECORDED_AT=2026-01-01T00:00:00Z", "",
].join("\n");

describe("existing local gate record fallback", () => {
  it("accepts only full clean successful exact-head machine-record shape", () => {
    expect(verifyLocalGateRecord(gateRecord, headSha)).toMatchObject({ kind: "local-gate", commit: headSha, mode: "full" });
  });
  it.each([
    ["RECORD_VERSION=1", "RECORD_VERSION=2"], ["STATUS=pass", "STATUS=fail"],
    ["STATUS=pass", "STATUS=partial"], ["DIRTY=no", "DIRTY=yes"],
    [`COMMIT=${headSha}`, `COMMIT=${mergeSha}`], ["GATE=tests/run-all.sh", "GATE="],
    ["GATE=tests/run-all.sh", "GATE=   "],
    ["SUITES=", "SUITES=one-suite"],
    ["passed=213", "passed=0"], ["failed=0", "failed=1"], ["skipped=0", "skipped=1"],
    ["not-run=0", "not-run=1"], ["excluded=0", "excluded=1"], ["RECORDED_AT=2026-01-01T00:00:00Z", "RECORDED_AT=invalid"],
    ["RECORDED_AT=2026-01-01T00:00:00Z", "RECORDED_AT=2999-01-01T00:00:00Z"],
    ["BRANCH=docs/issue-1338\n", ""], ["STATUS=pass", "STATUS=pass\nSTATUS=fail"],
    ["MODE=full", "MODE=full\nMODE=full"], ["SUITES=", "UNKNOWN=anything\nSUITES="],
  ])("rejects invalid or incomplete local evidence %s -> %s", (before, after) => {
    expect(() => verifyLocalGateRecord(gateRecord.replace(before, after), headSha)).toThrow();
  });
  it("accepts a consumer project gate with recorder-default empty MODE", () => {
    const custom = gateRecord.replace("GATE=tests/run-all.sh", "GATE=npm run validate:all").replace("MODE=full", "MODE=");
    expect(verifyDistillation({ ...input, localGate: "/tmp/gate" }, fixture({ pr: { statusCheckRollup: [] } }).run, () => custom).checksEvidence)
      .toMatchObject({ gate: "npm run validate:all", mode: "", commit: headSha });
  });
  it("treats a nonempty MODE as inert information, not code or coverage authority", () => {
    const custom = gateRecord.replace("MODE=full", "MODE=$(false)");
    expect(verifyLocalGateRecord(custom, headSha).mode).toBe("$(false)");
    expect(() => verifyLocalGateRecord(custom.replace("excluded=0", "excluded=1"), headSha)).toThrow();
  });
  it("rejects a gate label or mode changing during the final reread", () => {
    for (const [before, after] of [["GATE=tests/run-all.sh", "GATE=another gate"], ["MODE=full", "MODE="]]) {
      const read = vi.fn().mockReturnValueOnce(gateRecord).mockReturnValueOnce(gateRecord.replace(before, after));
      expect(() => verifyDistillation({ ...input, localGate: "/tmp/gate" }, fixture({ pr: { statusCheckRollup: [] } }).run, read)).toThrow("record changed");
    }
  });
  it("uses the local record only when initial and final GitHub check lists are empty", () => {
    const { run, calls } = fixture({ pr: { statusCheckRollup: [] } });
    const read = vi.fn(() => gateRecord);
    expect(verifyDistillation({ ...input, localGate: "/tmp/gate-record" }, run, read).checksEvidence).toMatchObject({ kind: "local-gate", commit: headSha });
    expect(read).toHaveBeenCalledTimes(2);
    expect(calls.some((args) => args[0] === "pr" && args[1] === "checks")).toBe(false);
  });
  it("does not infer absent checks from missing/null metadata", () => {
    expect(() => verifyDistillation({ ...input, localGate: "/tmp/gate" }, fixture({ pr: { statusCheckRollup: null } }).run, () => gateRecord)).toThrow("missing GitHub");
  });
  it("requires an explicit record when no GitHub checks exist", () => {
    expect(() => verifyDistillation(input, fixture({ pr: { statusCheckRollup: [] } }).run)).toThrow("--local-gate");
  });
  it.each(["fail", "pending", "cancel"])("does not override remote %s checks", (bucket) => {
    const read = vi.fn(() => gateRecord);
    expect(() => verifyDistillation({ ...input, localGate: "/tmp/gate" }, fixture({ checks: [{ ...pass, bucket }] }).run, read)).toThrow("checks");
    expect(read).not.toHaveBeenCalled();
  });
  it("does not override an empty/malformed checks response when rollup was nonempty", () => {
    expect(() => verifyDistillation({ ...input, localGate: "/tmp/gate" }, fixture({ checks: [] }).run, () => gateRecord)).toThrow("checks");
  });
  it("rejects GitHub checks appearing during local verification", () => {
    expect(() => verifyDistillation({ ...input, localGate: "/tmp/gate" }, fixture({ pr: { statusCheckRollup: [] }, finalPr: { statusCheckRollup: [{ name: "new" }] } }).run, () => gateRecord)).toThrow("appeared");
  });
  it("rejects a failed run replacing the pass record during verification", () => {
    const read = vi.fn().mockReturnValueOnce(gateRecord).mockReturnValueOnce(gateRecord.replace("STATUS=pass", "STATUS=fail"));
    expect(() => verifyDistillation({ ...input, localGate: "/tmp/gate" }, fixture({ pr: { statusCheckRollup: [] } }).run, read)).toThrow("local gate");
  });
  it("fails closed when the record cannot be read", () => {
    expect(() => verifyDistillation({ ...input, localGate: "/missing" }, fixture({ pr: { statusCheckRollup: [] } }).run, () => { throw new Error("ENOENT"); })).toThrow("ENOENT");
  });
  it("CLI accepts the optional record and returns its evidence type", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    expect(main([...Object.values(input), "--local-gate", "/tmp/gate"], fixture({ pr: { statusCheckRollup: [] } }).run, () => gateRecord)).toBe(0);
    expect(JSON.parse(log.mock.calls[0][0] as string).checksEvidence.kind).toBe("local-gate");
  });
  it("CLI rejects missing, duplicate or unknown optional arguments before gh calls", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const run = vi.fn<ReadGh>();
    for (const extra of [["--local-gate"], ["--local-gate", ""], ["--yes", "true"], ["--local-gate", "a", "--local-gate", "b"]]) {
      expect(main([...Object.values(input), ...extra], run)).toBe(2);
    }
    expect(run).not.toHaveBeenCalled();
  });
});


describe("referenced source existence", () => {
  it("returns the resolved source path for pinned-commit lookup", () => {
    expect(verifySection(body, input)).toBe("docs/08-knowledge/playbook/domain.md");
    verifySourceEntry(sourceBody, input.id);
  });
  it("rejects a label pointing at a missing source file", () => {
    expect(() => verifyDistillation(input, fixture({ merged: body.replace("08-knowledge/playbook/domain.md", "totally-missing.md") }).run)).toThrow("404");
  });
  it.each([
    "", sourceBody.replace(input.id, "ACE-i1338-2"),
    sourceBody.replace(input.id.toLowerCase(), "ace-i1338-2"),
    sourceBody.replace(`<a id="${input.id.toLowerCase()}"></a>`, ""),
    sourceBody + sourceBody,
    `\`\`\`markdown\n${sourceBody}\n\`\`\``,
    `<!-- ${sourceBody} -->`,
    sourceBody.replace(`### ${input.id}`, `### ACE-999-1: wrong entry\n### ${input.id}`),
  ])("rejects absent/mismatched/duplicate source entries %j", (sourceMerged) => {
    expect(() => verifyDistillation(input, fixture({ sourceMerged }).run)).toThrow();
  });
  it("rejects the source anchor being removed after merge", () => {
    expect(() => verifyDistillation(input, fixture({ sourceCurrent: sourceBody.replace(`<a id="${input.id.toLowerCase()}"></a>`, "") }).run)).toThrow("ACE source");
  });
  it("rejects a current target linking to a missing file after merge", () => {
    expect(() => verifyDistillation(input, fixture({ current: body.replace("08-knowledge/playbook/domain.md", "totally-missing.md") }).run)).toThrow("404");
  });
});
