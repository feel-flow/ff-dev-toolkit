// Decide, for one Stop event, whether the turn that just ended reached the
// workflow chain tail — the only point at which the automatic retrospective is
// owed (Issue `#1612` / OBS-187).
//
// Reads the Stop hook input JSON on stdin and writes exactly one state word to
// stdout:
//
//   active  — stop is already allowed (host re-entry flag, a retrospective
//             result in the final message or earlier in this turn span, or a
//             Codex host)
//   no-tail — the turn provably did NOT reach the chain tail; stay silent
//   first   — block: the turn reached the chain tail, or the scan could not
//             decide (fail-closed toward the behavior this replaced)
//
// Exit 2 means "not an input this module recognises as a Stop event" —
// unparsable JSON, a non-object payload, a different `hook_event_name`, or a
// missing `stop_hook_active`. The caller treats that as fail-open, exactly as
// the inline parser it replaces did, and treats every OTHER non-zero exit as a
// module that would not run.
//
// WHY THIS RUNS ON Stop AND NOT ON UserPromptSubmit
// The chain tail is made of things the turn *does* (`/merge-cleanup`,
// `/ace-curate`, `gh pr merge`), so the evidence only exists once the turn is
// over. UserPromptSubmit fires before generation, when the transcript holds
// nothing of the turn it is about to introduce, so it cannot make this call —
// measured 2026-09-14, claude 2.1.x on macOS: the UserPromptSubmit input
// carries session_id / transcript_path / cwd / scratchpad_dir / prompt_id /
// permission_mode / hook_event_name / prompt (that adds scratchpad_dir to the
// 2026-09-10 list recorded in retrospective-context.sh), and the transcript at
// that moment ends at the previous turn. The pre-injection therefore keeps firing and
// simply stops demanding a status line; this hook is what decides.
//
// DIRECTION OF THE BIAS
// A false positive costs one continuation prompt (the behavior this replaced). A
// false negative silently drops a retrospective that was owed. So every
// uncertain branch — no transcript path, unreadable file, no turn boundary
// inside the read cap, unparsable line — resolves to `first`.
//
// One false-positive class is known and accepted for that reason: a Bash
// command that CONTAINS a command-position `gh pr merge` inside a quoted
// string, a here-document, or markdown inline code it is writing. The leading
// set cannot tell "runs the command" from "writes the three words" without a
// shell parser, so `echo "手順: ; gh pr merge --squash"` and
// `gh issue create --body '… `gh pr merge 1 --squash` …'` both read as a
// chain tail. The cost is one continuation prompt. Backtick is in the leading
// set because POSIX command substitution is an invocation (Issue `#1635`);
// markdown inline code uses the same character and therefore joins this class.

import fs from "node:fs";

const CAP_STAGES = [512 * 1024, 8 * 1024 * 1024];

// `gh pr merge` at a command position. The leading set is what separates an
// invocation from the same three words sitting inside someone's grep pattern or
// echo string — `grep -n 'gh pr merge' file` puts a quote in front of `gh`, and
// a quote is not a command separator. Optional leading `VAR=value` assignments
// and an explicit path (`/usr/local/bin/gh`) are still invocations.
//
// Three shapes were missing until Issue `#1635` measured them, all of them
// false negatives (the direction this module calls expensive):
//   - command substitution and grouping — `` `gh pr merge` `` and `{ gh pr
//     merge; }` put a backtick or a brace in command position, not a quote
//   - reserved words that introduce a command on the same line — `if gh pr
//     merge …; then`, `else gh pr merge`, and `! gh pr merge`. `!` belongs
//     here rather than in the character class because POSIX requires it to be
//     its own word; `!gh` is history expansion, not a command. `else` is the
//     same class as `if`/`elif`/`then`/`do`: it introduces a command, and a
//     missing match is a silent drop. `)` (case-arm) is not in the leading
//     set; adding it would be the same accepted quote-internal false-positive
//     class as `;`, but it is not a reserved word and is left as a known
//     boundary rather than widening the character class.
//   - a newline directly after `merge`, so that `gh pr merge\necho done` is an
//     invocation. The tail stays a narrow allow-list rather than a negative
//     lookahead: `(?![A-Za-z0-9_-])` would also accept the `|` in the
//     argument-less form `sed 's|gh pr merge|x|'`. An argument-bearing
//     `s|gh pr merge 1|x|` still matches either tail, because the character
//     after `merge` is a space. The narrow tail therefore buys only the
//     argument-less sed delimiter, not "every docs edit in this repository".
const GH_PR_MERGE = /(?:^|[\n;&|(`{])[ \t]*(?:(?:!|if|elif|else|while|until|then|do|time)[ \t]+)*(?:[A-Za-z_][A-Za-z0-9_]*=[^\s]*[ \t]+)*(?:[^\s]*\/)?gh[ \t]+pr[ \t]+merge(?:[ \t\n]|$)/;

// Skill names are matched on the segment after the plugin prefix, so
// `ff-dev-toolkit:ace-curate` and a bare `ace-curate` both count, and a skill
// that merely contains the word (`ace-curate-report`) does not.
const TAIL_SKILLS = new Set(["ace-curate", "merge-cleanup"]);
// The user pointing at the chain tail themselves, including the explicit
// `/retrospective` of AC4. This has to match the command FORM, not the token
// anywhere in the text: a slash is also a path separator, so an earlier version
// that searched the whole prompt read `hooks/retrospective-stop.sh を直して` and
// `tests/retrospective-contract/verify.sh が落ちる` as chain tails — ordinary
// prompts in this repository, and the same noise class this module exists to
// remove. A notice carrying `/tmp/…/retrospective-review.log` defeated the
// notification narrowing the same way.
//
// The host records a typed slash command as `<command-name>/name</command-name>`
// (measured 2026-09-14, claude 2.1.x on macOS, across six local transcripts;
// those entries carry no `isMeta`, so they reach here as ordinary boundaries).
// A host that does not wrap it leaves the command as the prompt's first token.
const COMMAND_NAME = /<command-name>\s*([^<\s]+)\s*<\/command-name>/;
const TAIL_COMMAND = /^\/(?:[A-Za-z0-9_-]+:)?(?:ace-curate|merge-cleanup|retrospective)$/;

const invokesTailCommand = (text) => {
  if (typeof text !== "string") return false;
  const wrapped = COMMAND_NAME.exec(text);
  if (wrapped) return TAIL_COMMAND.test(wrapped[1]);
  return TAIL_COMMAND.test(text.trim().split(/\s+/)[0] || "");
};

// "A retrospective was delivered", not "the word appeared". Only the heading
// form counts here: the one-line `振り返り: …` report is also what an agent
// writes to say the turn was NOT a closeout, and prose about this very hook
// starts lines with it too (a session editing the skill or the observation
// ledger hits that). The caller keeps the looser marker for
// `last_assistant_message`, where it has always been and where the text is the
// response itself rather than anything quoted inside the span.
const RETROSPECTIVE_DELIVERED = /(^|\n)## セッション振り返り/;
const RETROSPECTIVE_DONE = /(^|\n)(振り返り:|## セッション振り返り)/m;

const finish = (state) => {
  process.stdout.write(state);
  process.exit(0);
};

const skillSegment = (name) => {
  const trimmed = String(name).trim();
  const colon = trimmed.lastIndexOf(":");
  return colon === -1 ? trimmed : trimmed.slice(colon + 1);
};

const isChainTailTool = (block) => {
  if (!block || block.type !== "tool_use" || !block.input || typeof block.input !== "object") return false;
  const input = block.input;
  if (block.name === "Skill" && typeof input.skill === "string") {
    return TAIL_SKILLS.has(skillSegment(input.skill));
  }
  if (block.name === "SlashCommand" && typeof input.command === "string") {
    return invokesTailCommand(input.command);
  }
  if (block.name === "Bash" && typeof input.command === "string") {
    return GH_PR_MERGE.test(input.command);
  }
  return false;
};

// The boundary of "this turn" is the newest entry the host wrote for a prompt
// submission: type user, textual content, not a subagent's sidechain, not a
// tool result (those are user entries whose content is an array of
// tool_result blocks), not host bookkeeping (isMeta).
const boundaryText = (entry) => {
  if (!entry || entry.type !== "user" || entry.isSidechain === true || entry.isMeta === true) return null;
  const content = entry.message && entry.message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  if (content.some((block) => block && block.type === "tool_result")) return null;
  const text = content
    .filter((block) => block && block.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n");
  return text === "" ? null : text;
};

// `isSidechain` is filtered for boundaries but NOT for evidence, and that
// asymmetry is the point: a subagent's prompt is not a turn boundary (nobody
// typed it), while a subagent's tool_use IS work this turn did — a merge or a
// cleanup delegated to a background agent still reached the chain tail. Making
// this symmetric would drop delegated tails on hosts that inline subagent
// entries, which is the false-negative direction.
const assistantBlocks = (entry) => {
  if (!entry || entry.type !== "assistant") return [];
  const content = entry.message && entry.message.content;
  return Array.isArray(content) ? content : [];
};

// A retrospective already delivered inside this same turn span. A background
// task finishing re-enters the agent, and whether that re-entry writes a user
// entry — a turn boundary — depends on the notice: measured 2026-09-15 by
// correlating task ids across four local transcripts, most re-entries wrote a
// `type:"user"` record, while 3 to 5 per session appeared only as `attachment`
// records and left no boundary at all. A span can therefore hold the chain
// tail, the retrospective, and then several more responses, and without this
// terminal state the fallback re-asks on every one of them — the noise OBS-187
// is about, moved later in the session. last_assistant_message only carries the
// newest response, so the answer has to come from the transcript.
const deliveredRetrospective = (block) =>
  block && block.type === "text" && typeof block.text === "string" && RETROSPECTIVE_DELIVERED.test(block.text);

// Scan one tail slice newest-first. Returns "tail", "done", "no-tail",
// "unknown" (a record that cannot be read, so nothing further can be claimed),
// or null when the slice ran out before the turn boundary appeared (the caller
// then widens it).
const scanSlice = (text, partialHead) => {
  const lines = text.split("\n");
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i];
    if (!line) continue;
    // No content pre-filter here. An earlier version skipped lines holding
    // neither `"tool_use"` nor `"user"` — which silently skipped assistant
    // text-only entries, the very records that carry a delivered retrospective,
    // and a skipped record reads exactly like an absent one (a false negative,
    // the expensive direction). It bought little anyway: the big lines are tool
    // results, and those are `"type":"user"` records that the filter let
    // through regardless. Measured 2026-09-14 on a 23 MB transcript: ~50 ms
    // either way. The budget to compare against is not the hook's whole 5 s —
    // retrospective-stop.sh allocates up to ~4.3 s of that to the stdin read
    // and drain, so the residual for this scan is about 1 s.
    let entry;
    try {
      entry = JSON.parse(line);
    } catch (_) {
      // Only line 0 of a slice that starts mid-file is explained: the tail read
      // cut it. Anywhere else — a record still being flushed at Stop time, a
      // corrupt write — the honest answer is that the decisive evidence might
      // have been in THIS line, so nothing can be concluded from the older
      // lines behind it. Skipping it would silently convert "could not read the
      // record" into "there is provably no tail", which is the false negative
      // this module is built to avoid.
      if (i === 0 && partialHead) continue;
      return "unknown";
    }
    // Entries are walked newest-first; within one entry, POSITION decides.
    // An ordinary assistant message is `[text][tool_use]`, so a retrospective
    // followed by a chain-tail tool_use means the tail is still owed, while a
    // tail followed by a retrospective means it was already paid.
    //
    // Returning the FIRST match instead inverted both directions (measured
    // 2026-09-15, Issue `#1635`). The expensive half was the Epic batch shape
    // `[振り返り][tool_use]` — an agent delivering one PR's retrospective and
    // moving straight to the next PR's `/merge-cleanup` in the same message —
    // which read as "done" and silently dropped a retrospective that was owed.
    // The comment here used to justify that as "not a case the skill's own
    // output produces", but what produces it is the agent's response, not the
    // skill. The other half blocked turns that had already delivered one.
    //
    // A tie is impossible: one block cannot be both a text block and a
    // tool_use. `-1` for absent therefore also gives the single-kind answers —
    // a tail alone beats -1, a retrospective alone does not.
    const blocks = assistantBlocks(entry);
    let lastRetrospective = -1;
    let lastTail = -1;
    for (let b = 0; b < blocks.length; b += 1) {
      if (deliveredRetrospective(blocks[b])) lastRetrospective = b;
      if (isChainTailTool(blocks[b])) lastTail = b;
    }
    if (lastRetrospective !== -1 || lastTail !== -1) {
      return lastTail > lastRetrospective ? "tail" : "done";
    }
    const prompt = boundaryText(entry);
    if (prompt !== null) return invokesTailCommand(prompt) ? "tail" : "no-tail";
  }
  return null;
};

// readSync is allowed to come back short, and a short read here would not just
// lose data — it would hand back the OLDEST part of the slice while the scan
// below assumes it is holding the newest. Loop until the window is full.
const readTail = (fd, size, bytes) => {
  const length = Math.min(size, bytes);
  const buffer = Buffer.allocUnsafe(length);
  let filled = 0;
  while (filled < length) {
    const read = fs.readSync(fd, buffer, filled, length - filled, size - length + filled);
    // A short read that ends early leaves the NEWEST bytes missing, because the
    // window is filled from `size - length` upward. Returning it would hand the
    // scan the wrong end of the file while it assumes it holds the newest — so
    // an incomplete window is not a smaller window, it is no answer at all.
    if (read <= 0) return null;
    filled += read;
  }
  return buffer.toString("utf8", 0, filled);
};

const reachedChainTail = (transcriptPath) => {
  if (typeof transcriptPath !== "string" || transcriptPath === "") return "first";
  let fd;
  try {
    fd = fs.openSync(transcriptPath, "r");
  } catch (_) {
    return "first";
  }
  try {
    const size = fs.fstatSync(fd).size;
    if (size === 0) return "first";
    let verdict = null;
    for (const bytes of CAP_STAGES) {
      const slice = readTail(fd, size, bytes);
      if (slice === null) return "first";
      verdict = scanSlice(slice, bytes < size);
      // A slice that already covers the whole file cannot grow, and a decided
      // slice does not need to. "unknown" does not grow out of it either — the
      // unreadable record is in every wider window too.
      if (verdict !== null || bytes >= size) break;
    }
    if (verdict === "no-tail") return "no-tail";
    if (verdict === "done") return "active";
    // "tail", "unknown" and an undecided scan all block; only the reason differs.
    return "first";
  } catch (_) {
    return "first";
  } finally {
    try {
      fs.closeSync(fd);
    } catch (_) {
      /* the fd is going away with the process anyway */
    }
  }
};

let source = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  source += chunk;
});
process.stdin.on("end", () => {
  let input;
  try {
    input = JSON.parse(source);
  } catch (_) {
    process.exit(2);
  }
  // `null` and scalars parse fine but are not Stop inputs; without this the
  // property read below throws and the process exits 1, which the caller cannot
  // tell from a module that will not run at all.
  if (!input || typeof input !== "object") process.exit(2);
  if (input.hook_event_name !== "Stop") process.exit(2);
  if (typeof input.stop_hook_active !== "boolean") process.exit(2);
  const message = typeof input.last_assistant_message === "string" ? input.last_assistant_message : "";
  // Codex renders a Stop decision:block reason as a visible HookPrompt, so that
  // host relies on the UserPromptSubmit pre-injection alone. Codex inputs carry
  // `model`; Claude Code's do not.
  const codexStop = typeof input.model === "string" && input.model !== "";
  if (input.stop_hook_active || RETROSPECTIVE_DONE.test(message) || codexStop) finish("active");
  finish(reachedChainTail(input.transcript_path));
});
