#!/usr/bin/env node
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { plan, apply, check } from './generate.mjs';
import { validateConfig } from './config.mjs';

export function main(args) {
  let root = process.cwd(), input, adoption, mode = 'plan';
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--root' || arg === '--config' || arg === '--adopt') {
      if (!args[i + 1] || args[i + 1].startsWith('--')) throw new Error(`${arg} requires a value`);
      if (arg === '--root') root = args[++i]; else if (arg === '--adopt') adoption = args[++i]; else input = args[++i];
    } else if (arg === '--apply' || arg === '--check') {
      if (mode !== 'plan') throw new Error('Choose --apply or --check');
      mode = arg.slice(2);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  root = fs.realpathSync(root);
  if (mode === 'check') {
    if (input || adoption) throw new Error('--check reads existing config; do not pass --config or --adopt');
    const result = check(root);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result.errors.length ? 1 : 0;
  }
  if (!input) throw new Error('Provide agreed settings with --config; default operation previews changes without writing');
  const config = validateConfig(JSON.parse(fs.readFileSync(input, 'utf8')));
  const options = { adopt: adoption ? JSON.parse(fs.readFileSync(adoption, 'utf8')) : {} };
  if (mode === 'apply') {
    process.stdout.write(`${JSON.stringify(apply(root, config, options), null, 2)}\n`);
    return 0;
  }
  const result = plan(root, config, options);
  process.stdout.write(`${JSON.stringify({ changes: result.changes, conflicts: result.conflicts, retained: result.retained, adopted: result.adopted }, null, 2)}\n`);
  return result.conflicts.length ? 1 : 0;
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`ASDD: ${error.message}\n`); process.exitCode = 1; }
}
