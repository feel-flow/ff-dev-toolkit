# Release acquisition fixtures

`bash plugins/ff-dev-toolkit/tests/github-input-release/verify.sh` runs the four real root entry points in disposable repositories. Git fetch/tag queries use local bare transports. The gh path uses an argv-recording stub. File mode uses a rejecting gh stub with an empty inherited environment and an explicit minimal PATH (the real HOME value is retained; Git config is isolated). No external acquisition, sync, tag publication or Release write is performed. The old gh suites remain separate and unchanged. The public workflow explicitly excludes this root-script suite. A direct invocation skips only after confirming the actual public Git root and its valid toolkit manifest; SSOT source loss and unknown/broken layouts fail.

Every file invocation takes `--github-input /absolute/index.json`. The existing helper's index version 1 selects raw bytes by exact operation, scope, phase and position. A response's `body` points to the original JSON file; whole-run logs use `format: "text"`. `last` and optional `http_status` are metadata in the index, not fields invented in the raw response. File validation requires the consumer fields below; absent required input returns rc2 and names the operation/field. `[]` or `{"workflow_runs":[]}` is acquired empty data. It is not an acquisition-failure replacement.

## Exact selectors and phases

`repository` is a full URL. Public Release operations use `https://github.com/feel-flow/ff-dev-toolkit`. The preparation PR and default health context use the repository configured in Git's origin before transport rewrites. An explicit health `--repo OWNER/REPO` instead selects `https://github.com/OWNER/REPO`; GH_REPO/GH_HOST and response payloads do not select another repository. `release.sync-base` retains the existing explicit SYNC_DRIFT_PUBLIC_REPO selector when set.

| Operation | Exact scope in addition to repository | Phase | Position / completeness | Raw requirements |
| --- | --- | --- | --- | --- |
| release.latest-due | none | due | `{}` | published_at string, parsed by existing time rule |
| release.list | none | check / before / after | page starts at1; every page has last=true/false; after also attempt1..6 | array; each draft boolean and tag_name string; all pages in original order |
| release.create | none | create-readback | `{}` | fresh external GET: tag_name/name/body/draft match the PLAN's exact tag/title/notes/non-draft |
| release.latest-post | none | after | `{}` | tag_name string; mismatch remains existing rc1 stop |
| release.open-preparation | state=open, limit=200 | check / prepare-finalize | `{}`, last=true | array of number/headRefName, at most200; original prefix selection |
| release.sync-base | per_page=30 | sync / due / check | `{}` | array of commit.message; original first-line sync anchor |
| release.health.repo | none | health / gate / report | `{}` | nameWithOwner matches selected repo; nonempty default_branch |
| release.health.workflow | workflow=weekly-run-all.yml | health / gate / report | `{}` | state/created_at; original ISO and time rules |
| release.health.runs | workflow=weekly-run-all.yml, event=schedule or workflow_dispatch, per_page=100, max_age_days=14 by default | health / gate / report | `{}` | workflow_runs array; id/status/event/head_branch/created_at/updated_at/html_url/conclusion; event must match selector |
| release.health.log | run_id=adopted evidence ID | health / gate / report | `{}`, last=true | nonempty complete whole-run raw text, original complete suite summary |

The weekly run request retains the original one-page100 window, rather than claiming an all-history enumeration. max_age_days follows the explicit checker option. Release lists preserve the original all-page request. A missing next page, missing attempt, wrong phase, wrong repo/event/window or wrong adopted log ID cannot reuse another entry.

The real orchestrator passes `--github-phase` only with `--github-input`: due→sync-drift(due), check→required(check) and sync-drift(check), prepare's offline simulation→required(prepare-simulation), finalization→required(prepare-finalize), gate→weekly(gate), report→weekly(report). The three standalone defaults are sync, check and health, respectively. The accepted phase sets are closed. Preparation simulation still runs without `--fetch`, removes its temporary origin and performs no GitHub read; the phase handoff is not an acquisition receipt. No repository override was added for that offline path.

## Write handoff and evidence boundary

File mode never runs `gh release create`. When creation is needed after the normal Git/gate conditions, it emits the common `PLAN:{...}` containing exact tag/repo/title/notes/verify-tag/latest and requests a separate fresh `release.create` create-readback. Without it, the command returns rc2/unavailable. An already matching fresh read-back emits no new creation PLAN and still requires fresh post Latest plus all-page Release/tag reconciliation. Static phase names cannot establish when a host acquired the bytes; the host must perform the approved actual write and capture fresh read-back. The existing release approval boundary remains in the canonical sync skill.

Optional sync-drift acquisition failure keeps SKIP_REASON/rc1; it does not claim DRIFT_COUNT=0 or synchronized status. The release caller still stops on that unknown result. File weekly shortages stop the release orchestrator with rc2 and cannot select a full-gate alternative or fall through to released. The original gh unknown→full-gate/warning behavior remains.

## GitHub MCP mapping and limitations

These are local mapping fixtures, not proof of a live MCP-only run. A host can place successfully acquired raw REST JSON in body files if its actual fields and selectors satisfy the table. Missing fields must be acquired from a capable primary source, not filled with guessed/default values. In particular normalized repository responses may lack default_branch/nameWithOwner together, normalized PRs may omit headRefName, and workflows/runs may lack state/created_at or the eight run fields. A generic successful envelope with zero log bytes is unavailable. An individual-job scope cannot satisfy the whole-run selector. Static bytes cannot prove that all jobs were acquired; last=true is the acquiring host’s completeness assertion, which needs a separate actual acquisition trace. Neither a summary extract nor a single job log may be relabeled as the whole-run raw log. Pagination and event/run identity must be inspected at acquisition time.

Historical MCP probes confirmed some Release/commit/open-PR GET paths, while workflow/runs acquisition and complete run-log text were not established. The currently connected MCP has no Release-create tool. This change adds neither a network client nor a writer/capability schema. Local gh/file parity, mapping completeness, live acquisition, external write and fresh read-back remain distinct statuses.

The local release fixture also passes the unchanged upstream environment preflight with real Python/Node, the existing media Node resolver, local manifest/tsc data and an npm stub that accepts only `ls`. Its unset loader condition uses a matching `disabled` state receipt; this is a synthetic fixture condition, not evidence of a live gate.

The suite measures exact stdout/stderr/rc parity on meaningful acquired paths, mandatory missing-field/scope/phase/page/log controls, complete create arguments and read-back separation, the six-attempt/five-second policy, and three independent suite-miss failures (empty case set, deleted raw fixture, removed source needle). Missing source or dependencies fails the suite; it is not a zero-case green result.

The prepare-finalize regression invokes the actual extracted function with the actual capture/delegate/checker and disposable Git fetches; only the outer writing snapshot is inert and dry-run prevents commits. It distinguishes operation-prefixed mandatory input shortages (rc2) from valid open preparation PRs and Git fetch failures (the existing gh stopped/rc1 result), and checks adjacent phase isolation.
