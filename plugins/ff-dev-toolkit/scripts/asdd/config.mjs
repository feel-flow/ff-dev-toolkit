import fs from 'node:fs';
import path from 'node:path';

export const DOCUMENTS = Object.freeze({
  MASTER: 'docs/MASTER.md', PROJECT: 'docs/01-context/PROJECT.md',
  DOMAIN: 'docs/02-design/DOMAIN.md', ARCHITECTURE: 'docs/02-design/ARCHITECTURE.md',
  PATTERNS: 'docs/03-implementation/PATTERNS.md', TESTING: 'docs/04-quality/TESTING.md',
  DEPLOYMENT: 'docs/05-operations/DEPLOYMENT.md',
});
export const FEATURES = ['ace', 'retrospective', 'multiReview', 'hooks', 'ci'];
const assert = (ok, message) => { if (!ok) throw new Error(message); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = value => typeof value === 'string' && value.trim().length > 0;
function keys(value, allowed, label) {
  assert(object(value), `${label}: object required`);
  assert(Object.keys(value).every(key => allowed.includes(key)), `${label}: unknown field`);
}
export function relativePath(value) {
  assert(text(value) && !path.isAbsolute(value) && !value.includes('\\') &&
    !value.split('/').some(part => !part || part === '.' || part === '..' || part.startsWith('-')) &&
    !/[\x00-\x1f]/.test(value), 'Path must be a relative path without traversal');
  return value;
}
// All managed paths must remain inside the selected project; never follow a symlink.
export function projectPath(root, relative) {
  relativePath(relative);
  let current = fs.realpathSync(root);
  for (const part of relative.split('/')) {
    current = path.join(current, part);
    if (fs.existsSync(current) || fs.lstatSync(path.dirname(current), { throwIfNoEntry: false })) {
      const stat = fs.lstatSync(current, { throwIfNoEntry: false });
      assert(!stat?.isSymbolicLink(), `Symlink is not a managed target: ${relative}`);
    }
  }
  return current;
}
export function validateConfig(config) {
  keys(config, ['schemaVersion', 'project', 'style', 'stage', 'tools', 'documents', 'features', 'workflow', 'decisions', 'github'], 'config');
  assert(config.schemaVersion === 1, 'Unsupported ASDD config schemaVersion');
  keys(config.project, ['name', 'purpose', 'owner'], 'project');
  for (const key of ['name', 'purpose', 'owner']) assert(text(config.project[key]), `project.${key} is required`);
  assert(['citizen', 'developer'].includes(config.style), 'style must be citizen or developer');
  assert(['poc', 'ongoing'].includes(config.stage), 'stage must be poc or ongoing');
  assert(['simple', 'standard', 'strict'].includes(config.workflow), 'Invalid workflow');
  for (const [field, allowed] of [['tools', ['claude', 'codex']], ['documents', Object.keys(DOCUMENTS)]]) {
    assert(Array.isArray(config[field]) && config[field].length > 0 &&
      config[field].every(item => allowed.includes(item)) && new Set(config[field]).size === config[field].length,
    `Invalid or duplicate ${field}`);
  }
  assert(config.documents.includes('MASTER'), 'MASTER is the shared entrypoint');
  keys(config.features, FEATURES, 'features');
  for (const feature of FEATURES) assert(typeof config.features[feature] === 'boolean', `features.${feature} must be boolean`);
  assert(Array.isArray(config.decisions), 'decisions must be an array');
  for (const decision of config.decisions) {
    keys(decision, ['topic', 'status', 'value', 'reason'], 'decision');
    assert(text(decision.topic) && text(decision.value) && text(decision.reason), 'Decision requires topic, value and reason');
    assert(['fact', 'agreed', 'proposed', 'unresolved'].includes(decision.status), 'Invalid decision status');
  }
  assert(Object.hasOwn(config, 'github'), 'github must be explicitly null or configured');
  if (config.github !== null) {
    keys(config.github, ['repository', 'recordIssues', 'saveHistory', 'allowedPaths', 'branchPolicy'], 'github');
    assert(typeof config.github.repository === 'string' && /^[\w.-]+\/[\w.-]+$/.test(config.github.repository), 'Invalid GitHub repository');
    for (const key of ['recordIssues', 'saveHistory']) assert(typeof config.github[key] === 'boolean', `github.${key} must be boolean`);
    assert(['direct', 'pull-request'].includes(config.github.branchPolicy), 'Invalid branchPolicy');
    assert(Array.isArray(config.github.allowedPaths), 'allowedPaths must be an explicit array');
    config.github.allowedPaths.forEach(relativePath);
    assert(!config.github.saveHistory || config.github.allowedPaths.length > 0, 'History saving needs allowedPaths');
    assert(!config.github.saveHistory || config.github.recordIssues, 'History saving requires Issue recording (recordIssues=true)');
  }
  return config;
}
export function loadConfig(root) {
  const file = projectPath(root, '.asdd/config.json');
  return fs.existsSync(file) ? validateConfig(JSON.parse(fs.readFileSync(file, 'utf8'))) : null;
}
