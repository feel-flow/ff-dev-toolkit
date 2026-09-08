import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  classifyDomainEntry,
  isDomainAutoArchiveSafe,
  normalizeDomainTarget,
  parseDomainMetadata,
  validateDomainMetadata,
} from "./ace-domain";

function entry(verification = "confirmed", target = "docs/design.md#orders", marker = ""): string {
  return [
    "### ACE-1338-1: 法人の契約条件",
    "| Category | domain | Origin | Issue #1338 | Evidence | docs/source.md#approval 確認者の承認 |",
    `| Date | 2026-09-08 | Verification | ${verification} |`,
    "| Helpful | 0 | Harmful | 0 |",
    `| Status | active | Distill-To | ${target} |${marker}`,
    "",
    "法人の有効契約にのみ適用する。",
    "---",
  ].join("\n");
}

describe("domain metadata", () => {
  it("allows the established Related auxiliary table without absorbing new metadata", () => {
    const raw = entry().replace("法人の有効契約にのみ適用する。", "| Related | ACE-1-1, ACE-2-2 |\n\n法人の有効契約にのみ適用する。");
    expect(classifyDomainEntry(raw).state).toBe("candidate");
    expect(classifyDomainEntry(raw.replace("| Related | ACE-1-1, ACE-2-2 |", "| Related | ACE-1-1 | Verification | conflicting |")).diagnostics.length).toBeGreaterThan(0);
    expect(isDomainAutoArchiveSafe("", "domain")).toBe(false);
  });
  it("preserves code-formatted metadata and ignores comments, fences and later body tables", () => {
    const raw = entry("`confirmed`", "`docs/design.md#orders`")
      .replace("domain |", "`domain` |")
      .replace("| Helpful", "<!-- | Verification | conflicting | -->\n```text\n| Distilled-To | docs/other.md |\n```\n| Helpful")
      + "\n## 変更履歴\n| Verification | conflicting |\n| Distilled-To | docs/other.md |";
    const result = classifyDomainEntry(raw);
    expect(result.state).toBe("candidate");
    expect(result.metadata.distillTo).toBe("docs/design.md#orders");
    expect(result.diagnostics).toEqual([]);
  });

  it.each(["Evidence", "Verification", "Distill-To", "Distilled-To"])("rejects duplicate %s even for allowlisted entries", (key) => {
    const marker = key === "Distilled-To" ? " Distilled-To | docs/design.md#orders |" : "";
    const raw = entry("confirmed", "docs/design.md#orders", marker).replace("| Helpful |", `| ${key} | duplicate | Helpful |`);
    expect(validateDomainMetadata(parseDomainMetadata(raw), { allowLegacyMissing: true }).join(" ")).toContain(`${key} が重複`);
    expect(classifyDomainEntry(raw).state).toBe("unverified");
    expect(isDomainAutoArchiveSafe(raw)).toBe(false);
  });

  it("detects a duplicate category without hiding domain behind its first value", () => {
    const raw = entry().replace("| Category | domain |", "| Category | coding | Category | domain |");
    expect(parseDomainMetadata(raw).isDomain).toBe(true);
    expect(classifyDomainEntry(raw).diagnostics.join(" ")).toContain("Category が重複");
  });

  it("waives only missing legacy fields; refine still diagnoses legacy knowledge", () => {
    const raw = "| Category | domain |\n| Date | 2026-01-01 |\n| Helpful | 0 | Harmful | 0 |\n| Status | active |";
    const metadata = parseDomainMetadata(raw);
    expect(validateDomainMetadata(metadata)).toHaveLength(3);
    expect(validateDomainMetadata(metadata, { allowLegacyMissing: true })).toEqual([]);
    expect(classifyDomainEntry(raw).state).toBe("unverified");
    expect(isDomainAutoArchiveSafe(raw)).toBe(false);
    expect(validateDomainMetadata(parseDomainMetadata(raw + "\n| Evidence | |"), { allowLegacyMissing: true })).toContain("Evidence が必要です");
  });

  it("rejects supplemental standalone rows even when their values are valid", () => {
    const raw = entry().replace("| Evidence | docs/source.md#approval 確認者の承認 |", "|\n| Evidence | docs/source.md#approval 確認者の承認 |");
    const result = classifyDomainEntry(raw);
    expect(result.state).toBe("unverified");
    expect(result.diagnostics.join(" ")).toContain("4行");
    expect(validateDomainMetadata(parseDomainMetadata(raw), { allowLegacyMissing: true })).toEqual([]);
  });

  it("requires extension keys to remain on their specified metadata rows", () => {
    const raw = entry().replace(" | Verification | confirmed", "").replace("| Helpful |", "| Helpful | 0 | Verification | confirmed | Other |");
    const result = classifyDomainEntry(raw);
    expect(result.state).toBe("unverified");
    expect(result.diagnostics).toContain("Verification は Date 行に記録してください");
  });

  it("keeps misplaced domain metadata fail-closed when prose precedes the first row", () => {
    const raw = entry().replace("| Category |", "補足\n| Category |");
    const result = classifyDomainEntry(raw);
    expect(result.metadata.isDomain).toBe(true);
    expect(result.state).toBe("unverified");
    expect(result.diagnostics.join(" ")).toContain("エントリ先頭");
    expect(isDomainAutoArchiveSafe(raw)).toBe(false);
  });

  it("waives a legacy prose prelude while keeping new-domain placement strict", () => {
    const raw = entry().replace("| Category |", "補足\n| Category |");
    const metadata = parseDomainMetadata(raw);
    expect(metadata.verification).toBe("confirmed");
    expect(validateDomainMetadata(metadata, { allowLegacyMissing: true })).toEqual([]);
    expect(validateDomainMetadata(metadata).join(" ")).toContain("エントリ先頭");
  });

  it.each([
    ["Verification | confirmed", "Verification | invalid", "Verification"],
    ["Evidence | docs/source.md#approval 確認者の承認", "Evidence | ", "Evidence"],
    ["Distill-To | docs/design.md#orders", "Distill-To | ../escape.md", "Distill-To"],
    ["Distill-To | docs/design.md#orders", "Distill-To | docs/design.md#orders | Distilled-To | ../escape.md", "Distilled-To"],
    ["Verification | confirmed", "Verification | confirmed | Verification | unverified", "重複"],
  ])("rejects supplied invalid %s behind allowlisted prose", (from, to, diagnostic) => {
    const raw = entry().replace("| Category |", "補足\n| Category |").replace(from, to);
    expect(validateDomainMetadata(parseDomainMetadata(raw), { allowLegacyMissing: true }).join(" ")).toContain(diagnostic);
  });

  it("does not let a later domain comparison table override a first non-domain Category row", () => {
    for (const prelude of ["", "補足\n"]) {
      const raw = entry().replace("| Category | domain |", `${prelude}| Category | coding |`) + "\n| Category | domain |";
      expect(parseDomainMetadata(raw).isDomain).toBe(false);
      expect(validateDomainMetadata(parseDomainMetadata(raw))).toEqual([]);
    }
  });

  it("does not read a body comparison table as metadata", () => {
    const raw = entry() + "\n| Verification | conflicting |";
    expect(classifyDomainEntry(raw).state).toBe("candidate");
  });
});

describe("repository-relative domain targets", () => {
  it.each(["/tmp/spec.md", "https://example.com/spec", "//example.com/spec", "C:\\spec.md", "../spec.md", "docs/../../spec.md", "docs\\..\\spec.md", "%2e%2e/spec.md", "%2fetc/passwd", "#section", "unresolved", "", "docs/%zz.md"])("rejects %s", (target) => {
    expect(normalizeDomainTarget(target)).toBeUndefined();
  });

  it("normalizes safe relative segments while retaining the anchor", () => {
    expect(normalizeDomainTarget("./docs/section/../design.md#orders")).toBe("docs/design.md#orders");
  });
});

describe("domain workflow states and auto-archive", () => {
  it.each([
    ["unverified", "docs/design.md#orders", "", "unverified"],
    ["conflicting", "unresolved", "", "conflicting"],
    ["confirmed", "unresolved", "", "unresolved"],
    ["confirmed", "docs/design.md#orders", "", "candidate"],
    ["confirmed", "docs/design.md#orders", " Distilled-To | ./docs/design.md#orders |", "distilled"],
  ])("classifies %s / %s as %s", (verification, target, marker, state) => {
    const raw = entry(verification, target, marker);
    expect(classifyDomainEntry(raw).state).toBe(state);
    expect(isDomainAutoArchiveSafe(raw)).toBe(state === "distilled");
  });

  it.each([
    ["unverified", "docs/design.md#orders", "docs/design.md#orders"],
    ["conflicting", "docs/design.md#orders", "docs/design.md#orders"],
    ["confirmed", "unresolved", "docs/design.md#orders"],
    ["confirmed", "docs/design.md#orders", "docs/design.md#other"],
    ["confirmed", "docs/design.md#orders", "../spec.md"],
    ["confirmed", "docs/design.md#orders", ""],
    ["unknown", "docs/design.md#orders", "docs/design.md#orders"],
  ])("malformed marker never claims distilled (%s / %s / %s)", (verification, target, distilled) => {
    const raw = entry(verification, target, ` Distilled-To | ${distilled} |`);
    const result = classifyDomainEntry(raw);
    expect(result.state).toBe("unverified");
    expect(result.diagnostics.length).toBeGreaterThan(0);
    expect(isDomainAutoArchiveSafe(raw)).toBe(false);
  });

  it("puts malformed conflicting metadata before the conflict bucket", () => {
    expect(classifyDomainEntry(entry("conflicting", "../escape.md")).state).toBe("unverified");
  });

  it("leaves non-domain archive eligibility unchanged", () => {
    expect(isDomainAutoArchiveSafe(entry().replace("| domain |", "| coding |"))).toBe(true);
  });
});

// Both distributed instructions must produce metadata accepted by the actual gate.
// Exercise the docs-template and repository mirror layouts without copying fixture rows.
describe("published domain metadata examples", () => {
  const templateRoot = new URL(import.meta.url.includes("/docs-template/")
    ? "../../" : "../../plugins/ff-dev-toolkit/docs-template/", import.meta.url);
  it.each([".claude/agents/ace-capture.md", "05-operations/deployment/ace-domain.md"])("validates %s against the production contract", (relative) => {
    const document = readFileSync(new URL(relative, templateRoot), "utf8");
    const examples = [...document.matchAll(/```text\r?\n(\| Category \| domain \|[\s\S]*?)\r?\n```/gu)];
    expect(examples).toHaveLength(1);
    const metadata = parseDomainMetadata(examples[0][1]);
    expect(metadata.isDomain).toBe(true);
    expect(metadata.verification).toBe("unverified");
    expect(metadata.distillTo).toBe("unresolved");
    expect(validateDomainMetadata(metadata)).toEqual([]);
  });
});
