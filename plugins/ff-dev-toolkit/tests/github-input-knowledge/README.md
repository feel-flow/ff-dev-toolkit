# Knowledge file acquisition fixtures

`bash verify.sh` is the complete suite for run-all registration: four acquisition consumers **and** `finish.sh knowledge-commit` integration must pass. `bash verify.sh --consumer-only` is an explicitly partial subset, prints `PARTIAL … finish wrapper/probe/push/PR cases excluded`, and is not the bundle gate. Each child process has a 60 second timeout; callers allow 600 seconds in the foreground. Requirements: bash, Python 3, git, jq and the standard utilities enumerated by `verify.py`. The isolated `env -i` environment exposes only those utilities and a refusing `gh` stub for file runs; it does not expose a system bin directory containing another installed gh. HOME retains its existing value; Claude settings are explicitly isolated. Real fixture Git pushes use local bare repositories through a repository-local transport rewrite, while the configured origin remains a GitHub URL.

The new `--github-input /absolute/index.json` uses the common version 1 raw file index. An explicitly empty value is an argument error (rc2) at all five effort/lookup/doctor/knowledge-add/knowledge-commit entry points, before any gh call. Existing `gh` commands and effort's raw `--input` remain separate. Every scope below includes `repository` (e.g. `https://github.com/example/repo`). Position is `{}` unless stated. `last=true` means the host supplied the complete requested result including the declared limit, not that a phase label proves live freshness. HTTP error bodies never supply a successful collection.

| Operation | Scope selectors | Phase / position | Canonical raw / insufficient data |
| --- | --- | --- | --- |
| effort.issues | state, limit | collect / `{}` | number/body array, excluding PRs, bounded by limit; missing mandatory body/scope/raw → rc2 |
| lookup.open-set | state=open, limit=1000 | lookup / `{}` | number array, excluding PRs; complete `[]` differs from unavailable; >=1000 → unconfirmed |
| doctor.labels | limit=200 | inspect / `{}` | repository-wide name array; issue-attached labels are insufficient; unavailable/empty → SKIP |
| doctor.bundle-list | state=open, label=bundle, limit=200 | inspect / `{}` | number array excluding PRs; valid `[]` retains zero-bundle WARN |
| doctor.open-issues | state=open, per_page=100 | inspect / `{page:1}`, then contiguous pages | REST array with number/labels; PRs and epic/bundle excluded by existing predicate; missing page or terminal `last` → SKIP |
| doctor.parents | numbers (current <=100 batch, ordered) | inspect / `{}` | `data.repository.iN = {number:N,parent:null\|{number}}`; all requested aliases and no extra aliases required |
| doctor.drafts | state=open, draft=true, author=@me, limit=200 | inspect / `{}` | number/title array; preserve author selector and exclude knowledge titles as before; unknown actor is not all-author data |
| knowledge.subject-issue | pr | subject / `{}` | closingIssuesReferences[0].number; optional failure retains branch #N fallback |
| knowledge.repo | none | probe / `{}` | nameWithOwner equal to Git origin identity; missing → unknown |
| knowledge.classic-protection | branch | probe / `{}` | required protection fields; recognized HTTP404 only means classic absent, HTTP403/400 remains unknown |
| knowledge.rulesets | branch | probe / `{}` | applicable branch rules array, every type known; unavailable → unknown |
| knowledge.ci | branch, limit=5, pushed_sha | after-push / `{}` | status/conclusion/workflowName/headSha array; only actual pushed SHA is this-push, missing → unavailable after delivered Git push |
| knowledge.pr-create | none | after-write / `{}` | exact head/base/title/body/headRefOid and number/URL/OPEN; absent/mismatched raw → PLAN+rc2, no completion marker |

For effort and doctor, explicit `--repo OWNER/REPO` names GitHub.com's repository as the existing selector does. Lookup references are also `owner/repo#N`. When doctor omits `--repo`, its file path resolves the configured Git origin before transport rewrites and retains the host. Knowledge's subject/probe/CI/PR expected URL is anchored in the configured Git origin before transport rewrites. Do not replace a different repository's response by editing the expected scope.

MCP → canonical mapping is a host responsibility. This suite contains local mapping examples, not a new client or capability schema:

| MCP/raw source | Deterministic mapping | Evidence boundary |
| --- | --- | --- |
| REST issue collection | Keep actual number/body, filter `.pull_request` before requested state/order/limit. Record every page and terminal page; do not fill omitted body. | Fixture covers canonical parity and PR exclusion. Actual MCP ordering, pages, source fields and actor must be checked on the acquisition trace. |
| Parent endpoint success / recognized error_data.status=404 | Success number becomes requested alias's parent number; only recognized endpoint-specific API404 becomes parent=null. `mcp-parent-404.json` is a local example. | 403/400 examples stay unavailable; generic normalized missing/error data is not parent absence proof. A canonical field alone cannot authenticate source mapping. |
| Repository labels / branch protection / branch rules | Use repository-wide labels and actual protection/rules response fields and status. | Previously unavailable MCP responses (labels/rules400, classic403) remain unavailable; issue labels and text mentioning404 cannot fill them. |
| Draft PR list with authenticated actor | Preserve draft/state/limit and original authenticated `@me` actor; keep number/title raw fields. | An index scope with `author:"@me"` is not proof of actor identity. If acquisition cannot establish the actor, withhold the response and retain SKIP. |
| Repository Actions runs | Map actual branch/limit fields only after real Git push, retaining actual head SHA. | Static `after-push` fixture tests predicates, not live acquisition timing or a successful workflow. |
| PR write and fresh read-back | Host executes exactly the PLAN arguments using an available write tool, then fetches a fresh raw PR preserving its fields. | Tool metadata, PLAN and static read-back fixture differ from actual write receipt plus later live read. This suite performs no GitHub write and claims no MCP-only completion. |

The default suite exercises the complete consumer and finish integration. `--consumer-only` runs effort, lookup, doctor, direct knowledge subject fallback, explicit empty-index validation, mapping and miss probes; it excludes finish wrapper/probe/push/PR cases, including optional-origin integration. Its PARTIAL result is not a complete suite pass. The original effort-contract, knowledge-lookup and workflow-doctor suites are kept unchanged.
