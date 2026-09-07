/** Parse skill argv without evaluating source strings as shell commands. Read-only. */
import { isDirectExecution } from './check-category-size';

export type CurateInput = Readonly<{
  mode: 'latest-pr' | 'pr' | 'sources';
  pr: string | null;
  issue: string | null;
  sources: readonly string[];
}>;
export function parseCurateInput(args: readonly string[]): CurateInput {
  let pr: string | null = null;
  let issue: string | null = null;
  const sources: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--source' || arg === '--issue') {
      const value = args[++i];
      if (!value?.trim() || value.startsWith('--')) throw new Error(`${arg}: value required`);
      if (arg === '--source') sources.push(value);
      else {
        if (issue !== null || !/^[1-9][0-9]*$/.test(value)) throw new Error('unique positive --issue required');
        issue = value;
      }
    } else if (arg && /^[1-9][0-9]*$/.test(arg) && pr === null) pr = arg;
    else throw new Error(`invalid argument: ${arg}`);
  }
  if (pr === null && sources.length > 0 && issue === null) throw new Error('sources-only requires --issue');
  if (pr === null && sources.length === 0 && issue !== null) throw new Error('--issue alone requires --source or a PR');
  return { mode: pr ? 'pr' : sources.length ? 'sources' : 'latest-pr', pr, issue, sources };
}
if (isDirectExecution(import.meta.url, process.argv[1])) {
  try { console.log(JSON.stringify(parseCurateInput(process.argv.slice(2)))); }
  catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 2; }
}
