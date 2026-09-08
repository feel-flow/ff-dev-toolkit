import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { apply } from '../../scripts/asdd/generate.mjs';
import { recordWork, workStatus } from '../../scripts/asdd/work.mjs';

function fixture(t, history = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'asdd-work-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  apply(root, { schemaVersion: 1, project: { name: '文書作成', purpose: 'お知らせを作る', owner: '@example' },
    style: 'citizen', stage: 'poc', tools: ['claude', 'codex'], documents: ['MASTER'],
    features: { ace: false, retrospective: false, multiReview: false, hooks: false, ci: false },
    workflow: 'simple', decisions: [], github: { repository: 'example/project', recordIssues: true,
      saveHistory: history, allowedPaths: ['output'], branchPolicy: 'direct' } });
  fs.mkdirSync(path.join(root, 'output')); fs.writeFileSync(path.join(root, 'output/notice.md'), 'お知らせ');
  const issues = [], comments = [], calls = [];
  const command = (cmd, args, input) => {
    calls.push({ cmd, args, input });
    if (cmd !== 'gh') throw new Error('Unexpected command');
    if (args[0] === 'api' && args[1] === 'user') return JSON.stringify({ id: 42 });
    if (args[0] === 'api') return JSON.stringify([args[1].includes('/comments?') ? comments : issues]);
    if (args[0] === 'repo') return JSON.stringify({ isPrivate: true, defaultBranchRef: { name: 'main' } });
    if (args[1] === 'create') {
      issues.push({ number: 1, html_url: 'https://github.com/example/project/issues/1', body: input, state: 'open', title: 'お知らせ', user: { id: 42 } });
      return issues[0].html_url;
    }
    if (args[1] === 'comment') { comments.push({ body: input, user: { id: 42 } }); return 'comment-url'; }
    throw new Error('Unexpected gh arguments');
  };
  const record = { taskId: 'notice-01', title: 'お知らせ', summary: '初稿を作成', doneWhen: ['事実と表現を確認する'],
    decisions: ['宛先は取引先'], openItems: ['送信前の確認'], nextSteps: ['文章レビュー'], files: ['output/notice.md'] };
  return { root, issues, comments, calls, command, record };
}
test('preview never writes remote or local work records; retries do not duplicate issues or comments', t => {
  const f = fixture(t);
  assert.equal(recordWork(f.root, f.record, { command: f.command }).applied, false);
  assert.equal(f.calls.length, 0);
  assert.equal(fs.existsSync(path.join(f.root, '.asdd/local')), false);
  assert.equal(recordWork(f.root, f.record, { command: f.command, apply: true }).status, 'synced');
  recordWork(f.root, f.record, { command: f.command, apply: true });
  assert.equal(f.issues.length, 1); assert.equal(f.comments.length, 0);
  f.record.summary = 'レビュー済み'; recordWork(f.root, f.record, { command: f.command, apply: true });
  recordWork(f.root, Object.fromEntries(Object.entries(f.record).reverse()), { command: f.command, apply: true });
  assert.equal(f.comments.length, 1);
  const before = fs.statSync(path.join(f.root, '.asdd/local/work.json')).mtimeMs;
  assert.match(workStatus(f.root, f.record.taskId, { command: f.command }).comments[0].body, /レビュー済み/);
  assert.equal(fs.statSync(path.join(f.root, '.asdd/local/work.json')).mtimeMs, before);
});
test('uncertain successful server write is reconciled before retry', t => {
  const f = fixture(t); let fail = true;
  const command = (cmd, args, input) => {
    const output = f.command(cmd, args, input);
    if (args[1] === 'create' && fail) { fail = false; throw Object.assign(new Error('secret-value'), { status: 1 }); }
    return output;
  };
  const result = recordWork(f.root, f.record, { command, apply: true });
  assert.equal(result.status, 'unsynced'); assert.doesNotMatch(JSON.stringify(result), /secret-value/);
  assert.equal(recordWork(f.root, Object.fromEntries(Object.entries(f.record).reverse()), { command, apply: true }).status, 'synced');
  assert.equal(f.issues.length, 1);
});
test('unapproved, internal and symlink artifact paths are rejected before remote writes', t => {
  const f = fixture(t);
  for (const file of ['private.txt', 'output/../private.txt', 'output/.env', 'output/.git/config']) {
    assert.throws(() => recordWork(f.root, { ...f.record, files: [file] }, { command: f.command, apply: true }));
  }
  fs.symlinkSync('/etc/hosts', path.join(f.root, 'output/linked'));
  assert.throws(() => recordWork(f.root, { ...f.record, files: ['output/linked'] }, { command: f.command, apply: true }), /Symlink/);
  assert.equal(f.calls.length, 0);
});
test('real git saves only selected artifacts; push failure resumes without a second commit', t => {
  const f = fixture(t, true);
  const git = args => execFileSync('git', args, { cwd: f.root, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  git(['init', '-b', 'main']); git(['config', 'user.name', 'ASDD test']); git(['config', 'user.email', 'asdd@example.invalid']);
  const remote = path.join(f.root, 'remote.git'); git(['init', '--bare', remote]); git(['remote', 'add', 'origin', remote]);
  fs.writeFileSync(path.join(f.root, 'unrelated.txt'), 'Not selected');
  let failPush = true;
  const command = (cmd, args, input) => {
    if (cmd === 'gh') return f.command(cmd, args, input);
    if (args[0] === 'remote') return 'https://github.com/example/project.git';
    if (args[0] === 'push' && failPush) { failPush = false; throw Object.assign(new Error('Denied'), { status: 1 }); }
    return git(args);
  };
  const first = recordWork(f.root, f.record, { command, apply: true });
  assert.equal(first.status, 'unsynced'); assert.ok(first.commit); assert.equal(first.pushed, false);
  assert.deepEqual(git(['ls-tree', '-r', '--name-only', 'HEAD']).split('\n'), ['output/notice.md']);
  const second = recordWork(f.root, f.record, { command, apply: true });
  assert.equal(second.status, 'synced'); assert.equal(second.pushed, true); assert.equal(second.commit, first.commit);
  assert.equal(git(['rev-list', '--count', 'HEAD']), '1'); assert.equal(f.issues.length, 1);
  assert.equal(f.comments.length, 1);
});
test('existing staged changes prevent any Issue or commit mutation', t => {
  const f = fixture(t, true);
  const command = (cmd, args, input) => {
    if (cmd === 'gh') return f.command(cmd, args, input);
    if (args[0] === 'remote') return 'git@github.com:example/project.git';
    if (args[0] === 'symbolic-ref') return 'main';
    if (args[0] === 'diff') return 'other.txt\0';
    throw new Error('Unexpected mutation');
  };
  assert.throws(() => recordWork(f.root, f.record, { command, apply: true }), /Staged changes/);
  assert.equal(f.issues.length, 0);
});
function historyFixture(t) {
  const f = fixture(t, true);
  const git = args => execFileSync('git', args, { cwd: f.root, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  git(['init', '-b', 'main']); git(['config', 'user.name', 'ASDD test']); git(['config', 'user.email', 'asdd@example.invalid']);
  const remote = path.join(f.root, 'remote.git'); git(['init', '--bare', remote]); git(['remote', 'add', 'origin', remote]);
  git(['commit', '--allow-empty', '-m', 'Initial shared history']); git(['push', 'origin', 'main']);
  const command = (cmd, args, input) => cmd === 'gh' ? f.command(cmd, args, input)
    : args[0] === 'remote' ? 'https://github.com/example/project.git' : git(args);
  return { ...f, git, command, remote };
}
test('pre-existing unpublished commits never ride along with an allowed artifact push', t => {
  const f = historyFixture(t);
  fs.writeFileSync(path.join(f.root, 'outside-approved-scope.txt'), 'Unapproved history');
  f.git(['add', 'outside-approved-scope.txt']); f.git(['commit', '-m', 'Local work']);
  assert.throws(() => recordWork(f.root, f.record, { command: f.command, apply: true }), /Unpublished history/);
  assert.equal(f.issues.length, 0);
  assert.equal(f.git(['--git-dir', f.remote, 'ls-tree', '-r', '--name-only', 'main']), '');
});
test('failed commit hooks leave recoverable owned staging without accepting user staging', t => {
  const f = historyFixture(t); let fail = true;
  const command = (cmd, args, input) => {
    if (cmd === 'git' && args[0] === 'commit' && fail) { fail = false; throw Object.assign(new Error('Hook failed'), { status: 1 }); }
    return f.command(cmd, args, input);
  };
  assert.equal(recordWork(f.root, f.record, { command, apply: true }).status, 'unsynced');
  assert.equal(f.git(['diff', '--cached', '--name-only']), 'output/notice.md');
  // A second failure before Issue reconciliation must retain the index receipt.
  const offline = (cmd, args, input) => {
    if (cmd === 'gh' && args[0] === 'api') throw Object.assign(new Error('Offline'), { status: 1 });
    return command(cmd, args, input);
  };
  assert.equal(recordWork(f.root, f.record, { command: offline, apply: true }).status, 'unsynced');
  assert.equal(recordWork(f.root, Object.fromEntries(Object.entries(f.record).reverse()), { command, apply: true }).status, 'synced');
  assert.equal(f.issues.length, 1);
  assert.equal(f.git(['rev-list', '--count', 'HEAD']), '2');
});
test('Issue-only updates do not inspect or publish unrelated staged or unpublished Git work', t => {
  const f = historyFixture(t);
  fs.writeFileSync(path.join(f.root, 'local.txt'), 'Local');
  f.git(['add', 'local.txt']); f.git(['commit', '-m', 'Unpublished work']);
  fs.writeFileSync(path.join(f.root, 'staged.txt'), 'Staged'); f.git(['add', 'staged.txt']);
  const before = f.git(['rev-parse', 'HEAD']);
  const command = (cmd, args, input) => {
    assert.notEqual(cmd, 'git'); return f.command(cmd, args, input);
  };
  const result = recordWork(f.root, { ...f.record, files: [] }, { command, apply: true });
  assert.equal(result.status, 'synced'); assert.equal(result.commit, null); assert.equal(result.pushed, false);
  assert.equal(f.git(['rev-parse', 'HEAD']), before); assert.equal(f.git(['diff', '--cached', '--name-only']), 'staged.txt');
});
test('foreign task and event markers cannot redirect or suppress agreed Issue records', t => {
  const f = fixture(t);
  const event = recordWork(f.root, f.record, { command: f.command }).event;
  const forged = { number: 99, html_url: 'https://github.com/example/project/issues/99',
    body: `<!-- asdd-task:${f.record.taskId} -->`, user: { id: 999 }, author_association: 'NONE' };
  f.issues.push(forged);
  // Our fake create result uses the first entry URL; retain API shape while
  // returning the newly created real Issue URL.
  const command = (cmd, args, input) => {
    const output = f.command(cmd, args, input);
    return args[1] === 'create' ? f.issues.at(-1).html_url : output;
  };
  assert.equal(recordWork(f.root, f.record, { command, apply: true }).issue, 'https://github.com/example/project/issues/1');
  f.issues.at(-1).body = `<!-- asdd-task:${f.record.taskId} -->`;
  f.comments.push({ body: `<!-- asdd-event:${event} -->`, user: { id: 999 }, author_association: 'CONTRIBUTOR' });
  assert.equal(recordWork(f.root, f.record, { command, apply: true }).status, 'synced');
  assert.equal(f.comments.length, 2); assert.equal(f.comments[1].user.id, 42);
  const status = workStatus(f.root, f.record.taskId, { command });
  assert.equal(status.issue.url, 'https://github.com/example/project/issues/1');
  assert.equal(status.comments[0].trusted, false); assert.equal(status.comments[0].author.id, 999);
  assert.equal(status.comments[1].trusted, true); assert.equal(status.comments[1].author.id, 42);
  // An authorized collaborator can resume a shared task under another login.
  f.issues.at(-1).user.id = 43; f.issues.at(-1).author_association = 'COLLABORATOR';
  assert.ok(workStatus(f.root, f.record.taskId, { command }).issue);
});
test('retry retains the original artifact commit after HEAD advances, including lost local receipts', t => {
  const f = historyFixture(t);
  const first = recordWork(f.root, f.record, { command: f.command, apply: true });
  assert.equal(first.status, 'synced');
  fs.writeFileSync(path.join(f.root, 'other.txt'), 'Other saved work');
  f.git(['add', 'other.txt']); f.git(['commit', '-m', 'Another task']); f.git(['push', 'origin', 'main']);
  for (const loseReceipt of [false, true]) {
    if (loseReceipt) fs.unlinkSync(path.join(f.root, '.asdd/local/work.json'));
    const retry = recordWork(f.root, f.record, { command: f.command, apply: true });
    assert.equal(retry.status, 'synced'); assert.equal(retry.commit, first.commit);
    assert.notEqual(retry.commit, f.git(['rev-parse', 'HEAD']));
    assert.equal(f.issues.length, 1); assert.equal(f.comments.length, 1);
  }
});
test('unchanged artifacts do not attribute another task HEAD as a new saved commit', t => {
  const f = historyFixture(t);
  f.git(['add', 'output/notice.md']); f.git(['commit', '-m', 'Previously saved document']); f.git(['push', 'origin', 'main']);
  const result = recordWork(f.root, f.record, { command: f.command, apply: true });
  assert.equal(result.status, 'synced'); assert.equal(result.commit, null);
  assert.equal(result.history, 'unchanged'); assert.equal(result.pushed, false); assert.equal(f.comments.length, 0);
});
test('a message-rewriting hook leaves an accurately reported unsynced commit', t => {
  const f = historyFixture(t);
  fs.writeFileSync(path.join(f.root, '.git/hooks/commit-msg'), '#!/bin/sh\nprintf "Team formatted message\\n" > "$1"\n', { mode: 0o755 });
  const result = recordWork(f.root, f.record, { command: f.command, apply: true });
  assert.equal(result.status, 'unsynced'); assert.equal(result.pushed, false);
  assert.equal(result.commit, f.git(['rev-parse', 'HEAD'])); assert.match(result.error, /marker was changed/);
  assert.equal(f.git(['--git-dir', f.remote, 'rev-list', '--count', 'main']), '1');
  assert.equal(f.comments.length, 0);
  // Reconcile the commit with the repository's hook policy; no force push or
  // bypass is needed, and the same event can resume without a second commit.
  fs.writeFileSync(path.join(f.root, '.git/hooks/commit-msg'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  f.git(['commit', '--amend', '-m', 'Team formatted message', '-m', `ASDD event ${result.event}`]);
  assert.equal(recordWork(f.root, f.record, { command: f.command, apply: true }).status, 'synced');
  assert.equal(f.git(['rev-list', '--count', 'HEAD']), '2'); assert.equal(f.comments.length, 1);
});
test('signature display settings cannot contaminate machine-readable commit identity', t => {
  const f = historyFixture(t);
  const verifier = path.join(f.root, 'test-signature-verifier');
  fs.writeFileSync(verifier, '#!/bin/sh\nprintf "gpg: Signature made test fixture\\n" >&2\nexit 1\n', { mode: 0o755 });
  f.git(['config', 'gpg.program', verifier]); f.git(['config', 'log.showSignature', 'true']);
  const command = (cmd, args, input) => {
    const output = f.command(cmd, args, input);
    if (cmd === 'git' && args[0] === 'commit') {
      // Build a signed-looking local fixture without accessing any user's keys.
      // Git's normal signature display invokes this isolated verifier.
      const raw = f.git(['cat-file', 'commit', 'HEAD']).replace('\n\n', '\ngpgsig -----BEGIN PGP SIGNATURE-----\n fixture\n -----END PGP SIGNATURE-----\n\n');
      const signed = execFileSync('git', ['hash-object', '-t', 'commit', '-w', '--stdin'],
        { cwd: f.root, input: `${raw}\n`, encoding: 'utf8' }).trim();
      f.git(['update-ref', 'HEAD', signed]);
    }
    return output;
  };
  const result = recordWork(f.root, f.record, { command, apply: true });
  assert.equal(result.status, 'synced'); assert.equal(result.commit, f.git(['rev-parse', 'HEAD']));
  assert.match(f.git(['log', '-1', '--format=%H']), /gpg: Signature made test fixture/);
  assert.equal(recordWork(f.root, f.record, { command, apply: true }).commit, result.commit);
  assert.equal(f.comments.length, 1);
});
