#!/usr/bin/env python3
"""Actual four entry points, isolated Git transports and rejecting gh in file mode."""
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile

SUITE = Path(__file__).resolve().parent
ROOT = SUITE.parents[3]
P = Path('plugins/ff-dev-toolkit')
SCRIPTS = ['release-dev-toolkit.sh', 'check-release-required.sh', 'check-dev-toolkit-sync-drift.sh', 'check-weekly-run-all-health.sh']
# release 段の処理は scripts/lib/release-publish-functions.sh へ分けてある。鍵は scripts/ からの相対パス
NEEDLES = {SCRIPTS[0]: ['release_delegate "$CURRENT_STAGE" "$HEALTH_SCRIPT"'],
           'lib/release-publish-functions.sh': ['release_list after', 'github_file_plan release.create'],
           SCRIPTS[1]: ['github_file_read "$GITHUB_INPUT" release.open-preparation'],
           SCRIPTS[2]: ['github_file_read "$GITHUB_INPUT" release.sync-base'],
           SCRIPTS[3]: ['health_file_read release.health.log', 'health_file_read release.health.workflow']}
REQUIRED_CASES = {'weekly-healthy', 'weekly-empty', 'weekly-warming-up', 'weekly-fields', 'weekly-log', 'weekly-scope', 'drift-optional', 'required-pr', 'release-lists', 'release-create', 'delegates', 'miss-probes'}

def audit_inputs(root, suite):
    cases = json.loads((suite / 'fixtures/cases.json').read_text())
    assert isinstance(cases, list) and len(cases) == len(set(cases)) and set(cases) == REQUIRED_CASES, 'case set empty/missing/duplicate/unexpected'
    assert (suite / 'fixtures/log.txt').is_file() and (suite / 'fixtures/log.txt').stat().st_size > 0, 'raw log fixture missing/empty'
    for name, needles in NEEDLES.items():
        source = (root / 'scripts' / name).read_text()
        for needle in needles:
            assert source.count(needle) == 1, f'{name}: source needle missing/duplicate: {needle}'
    return cases

if len(sys.argv) > 1 and sys.argv[1] == '--audit-inputs':
    try:
        audit_inputs(Path(sys.argv[2]), Path(sys.argv[3]))
    except (OSError, ValueError, AssertionError) as exc:
        print(f'input audit rejected: {exc}', file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

# Root scripts are absent only in the actual published Git root, identified by
# its own toolkit manifest. A missing/broken/unknown manifest is never a skip.
public_root = SUITE.parent.parent
public_manifest = public_root / '.claude-plugin/plugin.json'
if public_manifest.is_file():
    try:
        public_identity = json.loads(public_manifest.read_text())
        identity_env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
        identity = subprocess.run(['git','-C',str(public_root),'rev-parse','--show-toplevel'], env=identity_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        if public_identity.get('name') == 'ff-dev-toolkit' and identity.returncode == 0 and Path(identity.stdout.decode().strip()).resolve() == public_root.resolve():
            print('○ skip: 公開Git rootのtoolkit manifestを確認したため適用外（root release scriptsは配布しません。検査は1件も実行されていません）')
            sys.exit(0)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass

try:
    CASES = audit_inputs(ROOT, SUITE)
except (OSError, ValueError, AssertionError) as exc:
    print(f'✗ github-input-release: {exc}', file=sys.stderr)
    sys.exit(1)

PASS = 0
FAIL = 0
EXECUTED = set()

def check(condition, label, detail=''):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f'  ✓ {label}')
    else:
        FAIL += 1
        print(f'  ✗ {label}: {detail}', file=sys.stderr)

def run(argv, cwd, env, timeout=90):
    return subprocess.run([str(v) for v in argv], cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)

with tempfile.TemporaryDirectory(prefix='github-input-release.') as tmp:
    T = Path(tmp)
    bin_dir = T / 'bin'
    bin_dir.mkdir()
    # env -i equivalent: deliberately retain no caller GH_REPO/GH_HOST, Git hooks/config,
    # identity or plugin overrides. Each command is linked explicitly; no real gh in PATH.
    for name in ['bash','sh','git','jq','awk','sed','date','env','dirname','mktemp','cat','rm','mkdir','grep','head','tr','wc','sort','tail','comm','sleep','cp','find','cut','uname','rmdir','mv','chmod','touch','diff','basename','stat','python3','node']:
        found = shutil.which(name)
        assert found, f'required test command missing: {name}'
        (bin_dir / name).write_text('#!/bin/bash\nexec '+shlex.quote(found)+' "$@"\n')
        (bin_dir / name).chmod(0o755)
    env = {'HOME': os.environ['HOME'], 'PATH': str(bin_dir), 'TMPDIR': str(T), 'LC_ALL': 'C', 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
           'FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD': '1', 'TEST_DATA': str(T/'data'), 'TEST_GH_CALLS': str(T/'gh-calls'), 'TEST_GH_LEAKS': str(T/'gh-leaks')}
    # The executable path is an observed local interpreter; this stub cannot fetch/write.
    gh = bin_dir / 'gh'
    gh.write_text('#!' + sys.executable + '\n' + r'''
import json,os,pathlib,sys
args=sys.argv[1:]
if os.environ.get('TEST_REJECT_GH') == '1':
 with open(os.environ['TEST_GH_LEAKS'],'a') as f:f.write(json.dumps(args)+'\n')
 sys.exit(97)
with open(os.environ['TEST_GH_CALLS'],'a') as f:f.write(json.dumps(args)+'\n')
d=json.loads(pathlib.Path(os.environ['TEST_DATA']).read_text())
if args[:2]==['repo','view']: print(d['repo']['nameWithOwner'])
elif args[:2]==['pr','list']:
 for x in d['prs']:
  if x['headRefName'].startswith('chore/'+chr(35)+'549-release-'):print('#%s(%s)'%(x['number'],x['headRefName']))
elif args[:2]==['run','view']:sys.stdout.write(d['log'])
elif args[:2]==['release','create']:
 title=args[args.index('-t')+1];notes=pathlib.Path(args[args.index('--notes-file')+1]).read_text()
 pathlib.Path(os.environ['TEST_CREATE']).write_text(json.dumps({'tag_name':args[2],'name':title,'body':notes,'draft':False}))
elif args and args[0]=='api':
 endpoint=next((x for x in args[1:] if x.startswith('repos/')),'')
 if endpoint.endswith('/releases/latest'):
  print(d['latest'].get('published_at','') if '.published_at' in ' '.join(args) else d['latest']['tag_name'])
 elif endpoint.endswith('/releases'):
  for x in d['releases']:
   if x['draft'] is False:print(x['tag_name'])
 elif '/commits?' in endpoint:
  for x in d['commits']:print(x['commit']['message'].split('\n')[0])
 elif '/runs?' in endpoint:
  event=endpoint.split('event=')[1].split('&')[0];print(json.dumps(d[event]))
 elif '/actions/workflows/' in endpoint:print(json.dumps(d['workflow']))
 elif endpoint.startswith('repos/'):print(json.dumps(d['repo']))
 else:sys.exit(98)
else:sys.exit(99)
''')
    gh.chmod(0o755)
    # Keep sleeps observable while making all six propagation attempts inexpensive.
    (bin_dir/'sleep').unlink()
    (bin_dir/'sleep').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$TEST_SLEEPS"\n')
    (bin_dir/'sleep').chmod(0o755)
    env['TEST_SLEEPS'] = str(T/'sleeps')
    env['TEST_CREATE'] = str(T/'created.json')
    root = T/'ssot'
    root.mkdir()
    for name in SCRIPTS:
        dst=root/'scripts'/name; dst.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(ROOT/'scripts'/name,dst)
    # Real existing materialization and Git checks are exercised, not reimplemented.
    for name in ['sync-dev-toolkit-to-public.sh','scan-unreachable-repo-refs.sh','materialize-dev-toolkit-changelog.sh']:
        shutil.copy2(ROOT/'scripts'/name,root/'scripts'/name)
    shutil.copytree(ROOT/'scripts/lib',root/'scripts/lib')
    shutil.copytree(ROOT/P/'scripts/lib',root/P/'scripts/lib')
    (root/P/'.claude-plugin').mkdir(parents=True)
    (root/P/'.claude-plugin/plugin.json').write_text('{"name":"ff-dev-toolkit","version":"1.1.0"}\n')
    (root/P/'skills/demo').mkdir(parents=True)
    (root/P/'skills/demo/SKILL.md').write_text('---\nname: demo\ndescription: example\n---\n')
    (root/'oss/ff-dev-toolkit').mkdir(parents=True)
    changelog=root/'oss/ff-dev-toolkit/CHANGELOG.md'
    changelog.write_text('# Changelog\n\n## [Unreleased]\n\n## [1.1.0] - 2026-10-22\n\n### 修正\n\n- Fixture change.\n\n## [1.0.0] - 2026-10-21\n\n### 修正\n\n- Initial.\n')
    (root/'changelog.d').mkdir();(root/'changelog.d/README.md').write_text('# fragments\n')
    # Real Python/Node run the upstream preflight over local capability data.
    # The npm stub permits ls only; no dependency install or network occurs.
    media=root/'plugins/ff-media-toolkit'
    (media/'scripts/lib').mkdir(parents=True)
    shutil.copy2(ROOT/'plugins/ff-media-toolkit/scripts/lib/node-bin.sh',media/'scripts/lib/node-bin.sh')
    (media/'node_modules/typescript/bin').mkdir(parents=True)
    (media/'node_modules/typescript/bin/tsc').write_text('// controlled prerequisite\n')
    (media/'package.json').write_text('{"dependencies":{"fixture-media":"1.0.0"},"devDependencies":{"typescript":"1.0.0"}}\n')
    (media/'package-lock.json').write_text('{"lockfileVersion":3}\n')
    (root/'.gitignore').write_text('node_modules/\n')
    env['TEST_MEDIA']=str(media.resolve())
    (bin_dir/'npm').write_text('''#!/bin/bash
expected="ls --prefix $TEST_MEDIA --depth=0 --include=dev --include=optional --include=peer --package-lock-only=false --global=false --json=false --parseable=false --long=false --color=false"
[[ "$*" == "$expected" ]] || { echo "unexpected npm request: $*" >&2; exit 64; }
printf '%s\\n' 'fixture-media@1.0.0'
''')
    (bin_dir/'npm').chmod(0o755)
    # Mandatory isolation helper validates .git before setting fixture identity.
    fixture = ROOT/P/'tests/lib/git-fixture.sh'
    init_code = '. "$1"; ff_git_fixture_init "$2"; git -C "$2" symbolic-ref HEAD refs/heads/develop'
    q=run(['bash','-c',init_code,'fixture',fixture,root],T,env);assert q.returncode==0,q.stderr
    def git(*args, cwd=root):
        q=run(['git',*args],cwd,env); assert q.returncode==0,(args,q.stdout,q.stderr); return q.stdout.decode().strip()
    git('add','.');git('commit','-qm','fixture baseline')
    base=git('rev-parse','HEAD')
    # Local URL transport rewrite preserves the Git configured GitHub identity.
    repo_url='https://github.com/owner/repo'
    remote=T/'ssot.git';git('clone','--bare',str(root),str(remote),cwd=T)
    git('remote','add','origin',repo_url)
    git('config','url.'+str(remote)+'.insteadOf',repo_url)
    git('fetch','-q','origin','+refs/heads/develop:refs/remotes/origin/develop')
    pub=T/'public';pub.mkdir()
    q=run(['bash','-c','. "$1"; ff_git_fixture_init "$2"; git -C "$2" symbolic-ref HEAD refs/heads/main','fixture',fixture,pub],T,env);assert q.returncode==0,q.stderr
    (pub/'plugin.json').write_text('{"version":"1.1.0"}\n')
    (pub/'README.md').write_text('public fixture\n')
    # The sync anchor is parsed by existing scripts, with name assembled at runtime.
    ssot_name='feelflow-'+'plugins'
    git('add','.',cwd=pub);git('commit','-qm',f'sync: {ssot_name} {base[:12]} を反映',cwd=pub)
    git('tag','v1.0.0',cwd=pub);git('tag','v1.1.0',cwd=pub)
    public_remote=T/'public.git';git('clone','--bare',str(pub),str(public_remote),cwd=T)
    git('remote','add','origin',str(public_remote),cwd=pub)
    git('fetch','-q','origin','+refs/heads/main:refs/remotes/origin/main',cwd=pub)
    gitdir=Path(git('rev-parse','--absolute-git-dir'))
    (gitdir/'ff-release-state').write_text('GATE_OK='+base+':full\n')
    now=dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    iso=lambda days:(now-dt.timedelta(days=days)).isoformat().replace('+00:00','Z')
    runrow=lambda ident,event,days=1:{'id':ident,'status':'completed','event':event,'head_branch':'develop','created_at':iso(days),'updated_at':iso(days),'html_url':'https://example.invalid/runs/'+str(ident),'conclusion':'success'}
    log=(SUITE/'fixtures/log.txt').read_text()
    data={'repo':{'nameWithOwner':'owner/repo','default_branch':'develop'},'workflow':{'state':'active','created_at':iso(30)},
          'schedule':{'workflow_runs':[runrow(11,'schedule',2)]},'workflow_dispatch':{'workflow_runs':[runrow(22,'workflow_dispatch')]},
          'log':log,'prs':[], 'releases':[{'draft':False,'tag_name':'v1.0.0'},{'draft':False,'tag_name':'v1.1.0'}],
          'latest':{'tag_name':'v1.1.0','published_at':iso(2)},'commits':[{'commit':{'message':f'sync: {ssot_name} {base[:12]} を反映\nbody'}}]}
    index=T/'index.json'
    def write_raw(name,value,text=False):
        path=T/(name+('.txt' if text else '.json'))
        path.write_text(value if text else json.dumps(value,ensure_ascii=False)+'\n')
        return str(path)
    def entry(op, scope, phase, value, **meta):
        text=meta.pop('text',False)
        result={'operation':op,'scope':scope,'phase':phase,'body':write_raw('body-'+str(len(entries)),value,text)}
        if text:result['format']='text'
        result.update(meta);return result
    entries=[]
    def build(d=data):
        global entries
        entries=[]
        for phase in ['health','gate','report']:
            entries.append(entry('release.health.repo',{'repository':repo_url},phase,d['repo']))
            entries.append(entry('release.health.workflow',{'repository':repo_url,'workflow':'weekly-run-all.yml'},phase,d['workflow']))
            for event in ['schedule','workflow_dispatch']:
                entries.append(entry('release.health.runs',{'repository':repo_url,'workflow':'weekly-run-all.yml','event':event,'per_page':100,'max_age_days':14},phase,d[event]))
            entries.append(entry('release.health.log',{'repository':repo_url,'run_id':22},phase,d['log'],last=True,text=True))
        for phase in ['sync','due','check']:
            entries.append(entry('release.sync-base',{'repository':'https://github.com/feel-flow/ff-dev-toolkit','per_page':30},phase,d['commits']))
        for phase in ['check','prepare-finalize']:
            entries.append(entry('release.open-preparation',{'repository':repo_url,'state':'open','limit':200},phase,d['prs'],last=True))
        for phase in ['check','before']:
            entries.append(entry('release.list',{'repository':'https://github.com/feel-flow/ff-dev-toolkit'},phase,d['releases'],page=1,last=True))
        for attempt in range(1,7):
            entries.append(entry('release.list',{'repository':'https://github.com/feel-flow/ff-dev-toolkit'},'after',d['releases'],page=1,attempt=attempt,last=True))
        entries.append(entry('release.latest-post',{'repository':'https://github.com/feel-flow/ff-dev-toolkit'},'after',d['latest']))
        entries.append(entry('release.latest-due',{'repository':'https://github.com/feel-flow/ff-dev-toolkit'},'due',d['latest']))
        commit_index(d)
    def commit_index(d=data):
        index.write_text(json.dumps({'version':1,'responses':entries},ensure_ascii=False)+'\n')
        (T/'data').write_text(json.dumps(d,ensure_ascii=False)+'\n')
    def invoke(name, args=(), file=True, extra=None):
        e=dict(env)
        if file:e['TEST_REJECT_GH']='1'
        if extra:e.update(extra)
        return run(['bash',root/'scripts'/name,*args,*(('--github-input',index) if file else ())],root,e)
    def scalar(q,key):
        lines=[x[len(key)+1:] for x in q.stdout.decode().splitlines() if x.startswith(key+'=')]
        return lines[0] if len(lines)==1 else None
    def parity(name,args,label,d=data):
        build(d)
        g=invoke(name,args,file=False);f=invoke(name,args)
        check((g.returncode,g.stdout,g.stderr)==(f.returncode,f.stdout,f.stderr),label,repr((g.returncode,g.stdout[-400:],g.stderr[-200:],f.returncode,f.stdout[-400:],f.stderr[-200:])))
        return f
    def missing(name,args,op,field='',mutate=None):
        build()
        if mutate:mutate()
        else:entries[:]=[x for x in entries if x['operation']!=op]
        commit_index()
        q=invoke(name,args)
        check(q.returncode==2 and op.encode() in q.stdout+q.stderr and (not field or field.encode() in q.stdout+q.stderr),f'{op}: {field or "missing response"} => rc2',repr((q.returncode,q.stdout[-300:],q.stderr[-200:])))
        return q
    def change_body(op,phase,fn):
        for e in entries:
            if e['operation']==op and e['phase']==phase:
                p=Path(e['body']);v=json.loads(p.read_text());fn(v);p.write_text(json.dumps(v)+'\n')
    health=SCRIPTS[3];drift=SCRIPTS[2];required=SCRIPTS[1];release=SCRIPTS[0]
    print('github-input-release verify:')
    EXECUTED.add('weekly-healthy')
    f=parity(health,(), 'weekly healthy: whole stdout/stderr/rc gh=file')
    check(scalar(f,'HEALTH')=='healthy' and scalar(f,'EVIDENCE_RUN_ID')=='22','healthy uses latest completed adopted run22')
    # Explicit repo overrides ambient GH_REPO; auto repo comes only from configured Git.
    parity(health,('--repo','owner/repo'),'weekly explicit repo parity')
    EXECUTED.update(['weekly-empty','weekly-warming-up'])
    empty=copy.deepcopy(data);empty['schedule']={'workflow_runs':[]};empty['workflow_dispatch']={'workflow_runs':[]};empty['workflow']['created_at']=iso(1)
    f=parity(health,(),'valid empty runs => original warming-up',empty)
    check(f.returncode==0 and scalar(f,'HEALTH')=='warming-up','empty input acquired, not unknown')
    stale=copy.deepcopy(empty);stale['workflow']['created_at']=iso(40)
    f=parity(health,(),'empty runs beyond window => original stale',stale);check(f.returncode==1,'expired empty window rc1')
    EXECUTED.add('weekly-fields')
    for field in ['nameWithOwner','default_branch']:
        missing(health,(),'release.health.repo',field,lambda field=field:change_body('release.health.repo','health',lambda v:v.pop(field)))
    for field in ['state','created_at']:
        missing(health,(),'release.health.workflow',field,lambda field=field:change_body('release.health.workflow','health',lambda v:v.pop(field)))
    for field in ['id','status','event','head_branch','created_at','updated_at','html_url','conclusion']:
        missing(health,(),'release.health.runs',field,lambda field=field:change_body('release.health.runs','health',lambda v:v['workflow_runs'][0].pop(field)))
    EXECUTED.add('weekly-log')
    missing(health,(),'release.health.log')
    build();e=next(x for x in entries if x['operation']=='release.health.log' and x['phase']=='health');Path(e['body']).write_bytes(b'');commit_index();q=invoke(health)
    check(q.returncode==2 and b'release.health.log' in q.stdout+q.stderr,'empty raw run log => rc2')
    build();e=next(x for x in entries if x['operation']=='release.health.log' and x['phase']=='health');e['scope']['run_id']=11;commit_index();q=invoke(health)
    check(q.returncode==2 and b'release.health.log' in q.stdout+q.stderr,'different adopted log run ID => rc2')
    build();e=next(x for x in entries if x['operation']=='release.health.log' and x['phase']=='health');e['last']=False;commit_index();q=invoke(health)
    check(q.returncode==2 and b'whole-run log' in q.stdout+q.stderr,'incomplete log metadata => rc2')
    build();e=next(x for x in entries if x['operation']=='release.health.log' and x['phase']=='health');e['scope']['job_id']=88;commit_index();q=invoke(health)
    check(q.returncode==2 and b'release.health.log' in q.stdout+q.stderr,'individual-job scope cannot replace adopted whole-run log')
    EXECUTED.add('weekly-scope')
    for key,value in [('repository','https://github.com/other/repo'),('event','push'),('max_age_days',30)]:
        build()
        for e in entries:
            if e['operation']=='release.health.runs' and e['phase']=='health' and e['scope']['event']=='schedule':e['scope'][key]=value
        commit_index();q=invoke(health)
        check(q.returncode==2 and b'release.health.runs' in q.stdout+q.stderr,f'wrong runs {key} => rc2')
    build();entries[:]=[x for x in entries if x['phase']!='health'];commit_index();q=invoke(health)
    check(q.returncode==2 and b'release.health.repo' in q.stdout+q.stderr,'gate/report snapshots cannot fill health phase')
    EXECUTED.add('drift-optional')
    f=parity(drift,(),'sync commit raw JSON: stdout/stderr/rc gh=file')
    check(f.returncode==0 and scalar(f,'DRIFT_COUNT')=='0','actual Git drift remains0')
    build();entries[:]=[e for e in entries if e['operation']!='release.sync-base'];commit_index();q=invoke(drift)
    check(q.returncode==1 and scalar(q,'SKIP_REASON') is not None and scalar(q,'DRIFT_COUNT') is None,'optional sync acquisition => SKIP, never synchronized')
    EXECUTED.add('required-pr')
    # Required checker full original local path reaches PR, then original attribution logic.
    f=parity(required,('--public',pub,'--fetch'),'required preparation check: stdout/stderr/rc gh=file')
    check(f.returncode==0 and scalar(f,'RELEASE_CHECK')=='OK','required baseline actually reaches OK',repr((f.returncode,f.stdout,f.stderr)))
    missing(required,('--public',pub,'--fetch'),'release.open-preparation')
    for field in ['number','headRefName']:
        build();change_body('release.open-preparation','check',lambda v,field=field:v.append({k:w for k,w in {'number':8,'headRefName':'chore/'+chr(35)+'549-release-x'}.items() if k!=field}));commit_index();q=invoke(required,('--public',pub,'--fetch'))
        check(q.returncode==2 and field.encode() in q.stdout+q.stderr,f'preparation PR missing {field} => rc2')
    # Caller phase does not silently reuse check snapshot.
    missing(required,('--public',pub,'--fetch','--github-phase','prepare-finalize'),'release.open-preparation',mutate=lambda:entries.__setitem__(slice(None),[e for e in entries if e['phase']!='prepare-finalize']))
    # The offline preparation simulation has no GitHub read and must not require origin.
    build();q=invoke(required,('--public',pub,'--github-phase','prepare-simulation'))
    check(q.returncode in (0,1) and b'github-input:' not in q.stderr,'prepare-simulation offline checker adds no GitHub read',repr((q.returncode,q.stdout,q.stderr)))
    EXECUTED.add('release-lists')
    f=parity(release,('--public',pub,'--only','release'),'existing Release postconditions: stdout/stderr/rc gh=file')
    check(f.returncode==0 and scalar(f,'RELEASE_RESULT')=='stage-done','existing Release needs latest + fresh all-page after list')
    check(b'RELEASE_PYTHON_PATH=' in f.stdout and b'RELEASE_MEDIA_TYPECHECK=ready' in f.stdout,'release fixture reaches real upstream preflight before mandatory file acquisition')
    # Exact default gh argv survives: real original request selectors are recorded.
    calls=[json.loads(line) for line in (T/'gh-calls').read_text().splitlines()]
    check(['api','--paginate','repos/feel-flow/ff-dev-toolkit/releases','--jq','.[] | select(.draft == false) | .tag_name'] in calls,'gh release-list exact argv retained')
    check(['run','view','22','--repo','owner/repo','--log'] in calls,'gh whole adopted-run log exact argv retained')
    missing(release,('--public',pub,'--only','release'),'release.latest-post','tag_name')
    build();entries[:]=[e for e in entries if not(e['operation']=='release.list' and e['phase']=='after')];commit_index();q=invoke(release,('--public',pub,'--only','release'))
    check(q.returncode==2 and scalar(q,'RELEASE_RESULT')=='unavailable','before snapshot cannot satisfy mandatory after list')
    build();e=next(e for e in entries if e['operation']=='release.list' and e['phase']=='before');e['last']=False;commit_index();q=invoke(release,('--public',pub,'--only','release'))
    check(q.returncode==2 and b'release.list' in q.stdout+q.stderr,'missing second release page => rc2')
    build();e=next(e for e in entries if e['operation']=='release.list' and e['phase']=='before');e['last']=False
    entries.append(entry('release.list',{'repository':'https://github.com/feel-flow/ff-dev-toolkit'},'before',[],page=2,last=True));commit_index();q=invoke(release,('--public',pub,'--only','release'))
    check(q.returncode==0,'complete second release page accepted')
    build();change_body('release.latest-post','after',lambda v:v.update(tag_name='v9.9.9'));commit_index();q=invoke(release,('--public',pub,'--only','release'))
    check(q.returncode==1 and scalar(q,'RELEASE_RESULT')=='stopped','wrong post Latest preserves stop rc1')
    build()
    for e in entries:
        if e['operation']=='release.list' and e['phase']=='after':Path(e['body']).write_text('[]\n')
    commit_index();q=invoke(release,('--public',pub,'--only','release'))
    check(q.returncode==2,'one-sided empty tags/releases stays unavailable')
    # Actual six attempts/5-second waits remain; pre-write list still contains current.
    build()
    for e in entries:
        if e['operation']=='release.list' and e['phase']=='after':Path(e['body']).write_text('[{"draft":false,"tag_name":"v1.0.0"}]\n')
    (T/'sleeps').write_text('');commit_index();q=invoke(release,('--public',pub,'--only','release'))
    check(q.returncode==1 and (T/'sleeps').read_text().splitlines()==['5']*5,'post propagation keeps6 attempts/5 sleeps of5sec')
    build();entries[:]=[e for e in entries if not(e['operation']=='release.list' and e.get('attempt')==2)];
    for e in entries:
        if e['operation']=='release.list' and e['phase']=='after' and e['attempt']==1:Path(e['body']).write_text('[{"draft":false,"tag_name":"v1.0.0"}]\n')
    commit_index();q=invoke(release,('--public',pub,'--only','release'))
    check(q.returncode==2,'attempt1 data cannot substitute missing attempt2')
    EXECUTED.add('release-create')
    d=copy.deepcopy(data);d['releases']=[{'draft':False,'tag_name':'v1.0.0'}]
    build(d);q=invoke(release,('--public',pub,'--only','release'))
    plans=[json.loads(x[5:]) for x in q.stdout.decode().splitlines() if x.startswith('PLAN:{')]
    check(q.returncode==2 and len(plans)==1 and scalar(q,'RELEASE_RESULT')=='unavailable','create emits PLAN then waits rc2 without actual writer')
    plan=plans[0] if plans else {'arguments':{}}
    args=plan['arguments'];check(args.get('tag')=='v1.1.0' and args.get('repo')=='feel-flow/ff-dev-toolkit' and args.get('verify-tag') is True and args.get('latest') is True and args.get('title','').startswith('v1.1.0 — ') and args.get('notes','').endswith('\n'),'PLAN preserves tag/repo/title/complete notes/verify-tag/latest')
    # Fill real-shaped fresh read-back separately; after reads are still mandatory.
    build(d);entries.append(entry('release.create',{'repository':'https://github.com/feel-flow/ff-dev-toolkit'},'create-readback',{'tag_name':args.get('tag'),'name':args.get('title'),'body':args.get('notes'),'draft':False}))
    for e in entries:
        if e['operation']=='release.list' and e['phase']=='after':Path(e['body']).write_text(json.dumps(data['releases']))
    commit_index(d);q=invoke(release,('--public',pub,'--only','release'))
    check(q.returncode==0 and b'write read-back' in q.stdout and b'PLAN:{' not in q.stdout,'matched external write read-back completes without another write PLAN')
    # A changed raw body (including its final LF) is pending and retains exact args.
    build(d);entries.append(entry('release.create',{'repository':'https://github.com/feel-flow/ff-dev-toolkit'},'create-readback',{'tag_name':args.get('tag'),'name':args.get('title'),'body':args.get('notes').removesuffix('\n'),'draft':False}))
    commit_index(d);q=invoke(release,('--public',pub,'--only','release'))
    retry_plans=[json.loads(x[5:]) for x in q.stdout.decode().splitlines() if x.startswith('PLAN:{')]
    check(q.returncode==2 and len(retry_plans)==1 and retry_plans[0]==plan and b'write read-back' not in q.stdout,'mismatched final-LF read-back retains exact PLAN and rc2')
    # The gh branch emits exactly its old write args and passes the same notes bytes.
    build(d);q=invoke(release,('--public',pub,'--only','release'),file=False)
    actual=json.loads((T/'created.json').read_text()) if (T/'created.json').exists() else {}
    check(actual=={'tag_name':args.get('tag'),'name':args.get('title'),'body':args.get('notes'),'draft':False},'file PLAN title/notes match actual gh branch arguments byte-for-byte')
    EXECUTED.add('delegates')
    # Run the real orchestrator and all3 delegates; no stubbed delegate body.
    for phase in ['gate','report']:
        build();entries[:]=[e for e in entries if e['phase']!=phase];commit_index();q=invoke(release,('--public',pub,'--only',phase,'--dry-run'))
        check(q.returncode==2 and scalar(q,'RELEASE_RESULT')=='unavailable' and b'release.health.repo' in q.stdout+q.stderr,f'orchestrator {phase} mandatory shortage propagated, no fallback')
    # The gh inability branch retains its existing full-gate alternative.
    build();bad=copy.deepcopy(data);bad['workflow']={};(T/'data').write_text(json.dumps(bad));(gitdir/'ff-release-state').write_text('');q=invoke(release,('--public',pub,'--only','gate','--dry-run'),file=False)
    check(q.returncode==0 and b'FF_RUN_ALL_FULL=1 bash' in q.stdout,'gh weekly unknown still plans full-gate fallback',repr((q.returncode,q.stdout,q.stderr)))
    (gitdir/'ff-release-state').write_text('GATE_OK='+base+':full\n')
    # No-op drift is a legitimate no-due result; forced drift reaches raw due latest.
    build();q=invoke(release,('--due','--drift-count','1','--last-sync-sha',base))
    check(q.returncode==0 and scalar(q,'RELEASE_DUE')=='yes','due scalar published_at read reached without gh')
    missing(release,('--due','--drift-count','1','--last-sync-sha',base),'release.latest-due','published_at')
    # Full default call enters real required delegate/check phase and stops on missing PR.
    build();entries[:]=[e for e in entries if e['operation']!='release.open-preparation'];commit_index();q=invoke(release,('--public',pub,'--dry-run'))
    check(q.returncode==2 and b'release.open-preparation' in q.stdout+q.stderr,'orchestrator check context reaches real required delegate')
    # Real drift delegate was used above. Its optional failure becomes caller unavailable.
    build();entries[:]=[e for e in entries if e['operation']!='release.sync-base'];commit_index();q=invoke(release,('--due',))
    check(q.returncode==2 and scalar(q,'RELEASE_DUE')=='unknown','optional sync SKIP keeps release caller stop meaning')
    check(not (T/'gh-leaks').exists(),'file mode gh leaks=0 (rejecting stub, minimal env-i PATH)')
    # Exercise the actual prepare_finalize body and actual capture/delegate/checker.
    # Only the outer writing snapshot is inert; DRY_RUN=1 prevents commits/pushes.
    # The orchestrator keeps per-stage functions in scripts/lib/release-*-functions.sh;
    # read the body and those libs as one source so each function is still found exactly once.
    release_source=''.join(p.read_text() for p in [root/'scripts'/release,*sorted((root/'scripts/lib').glob('release-*-functions.sh'))])
    def function_source(name):
        marker=name+'() {'
        assert release_source.count(marker)==1, 'prepare function source absent/duplicate: '+name
        start=release_source.index(marker);line_end=release_source.index('\n',start)
        if release_source[start:line_end].rstrip().endswith('}'):
            return release_source[start:line_end]+'\n'
        end=release_source.index('\n}\n',start)+2
        return release_source[start:end]+'\n'
    prepare_globals=[]
    for name in ['CONTRACT_VERIFY','FRAGMENTS_VERIFY','RELEASE_PREFIX']:
        lines=[line for line in release_source.splitlines() if line.startswith(name+'=')]
        assert len(lines)==1, 'prepare global source absent/duplicate: '+name
        prepare_globals.append(lines[0])
    prepare_globals_text='\n'.join(prepare_globals)+'\n'
    prepare_driver=T/'prepare-finalize-driver.sh'
    function_names=['finish','stop','unavailable','mark','plan','kv','capture','release_delegate','prepare_fix_hint','prepare_finalize']
    prepare_driver.write_text('set -u\nGITHUB_INPUT="$1"; PUBLIC="$2"; CHECK_SCRIPT="$3"\nROOT="$4"; CURRENT_STAGE=prepare; VER=1.1.0; DRY_RUN=1\nPREPARE_PATHS_TEXT=fixture; CHANGELOG=fixture; PLUGIN_JSON=fixture; AGENT_CONFIG=fixture; FRAGMENT_DIR=fixture\nwriting_snapshot() { :; }\n'+prepare_globals_text+''.join(function_source(name) for name in function_names)+'prepare_finalize 1.1.0 fixture\n')
    def prepare_call(file=True):
        e=dict(env)
        if file:e['TEST_REJECT_GH']='1'
        return run(['bash',prepare_driver,str(index) if file else '',pub,root/'scripts'/required,root],root,e)
    def healthy_prepare(g,f):
        marker=b'RELEASE_STAGE=prepare STATUS=plan NOTE=fixture'
        return (g.returncode==f.returncode==0 and g.stderr==f.stderr==b'' and
                g.stdout==f.stdout and g.stdout.splitlines().count(marker)==1)
    def prepare_pair(label,d):
        build(d);g=prepare_call(False);f=prepare_call()
        check((g.returncode,g.stdout,g.stderr)==(f.returncode,f.stdout,f.stderr) and g.returncode==1,label,repr((g.returncode,g.stdout,g.stderr,f.returncode,f.stdout,f.stderr)))
    build();g=prepare_call(False);f=prepare_call()
    complete_prepare=f
    check(healthy_prepare(g,f),'prepare_finalize complete raw reaches dry-run plan marker',repr((g.returncode,g.stdout,g.stderr,f.returncode,f.stdout,f.stderr)))
    preparing=copy.deepcopy(data);preparing['prs']=[{'number':8,'headRefName':'chore/'+chr(35)+'549-release-another'}]
    prepare_pair('prepare_finalize valid open preparation PR is existing stopped rc1, not missing input',preparing)
    hidden_remote=T/'ssot-hidden.git';remote.rename(hidden_remote)
    try:
        prepare_pair('prepare_finalize Git fetch failure is existing stopped rc1, not missing input',data)
    finally:hidden_remote.rename(remote)
    build();entries[:]=[e for e in entries if not(e['operation']=='release.open-preparation' and e['phase']=='prepare-finalize')];commit_index();q=prepare_call()
    check(q.returncode==2 and scalar(q,'RELEASE_RESULT')=='unavailable' and b'SKIP_REASON=release.open-preparation:' in q.stdout,'prepare_finalize mandatory file shortage alone propagates rc2 with original SKIP_REASON')
    build();entries[:]=[e for e in entries if not(e['operation']=='release.open-preparation' and e['phase']=='check')];commit_index();g=prepare_call(False);q=prepare_call()
    check(healthy_prepare(g,q) and q.stdout==complete_prepare.stdout,'prepare_finalize does not borrow adjacent check phase or its shortage',repr((q.returncode,q.stdout,q.stderr)))
    EXECUTED.add('miss-probes')
    # These are independent failed executions of the suite's own preflight, not
    # "zero assertions passed" or expected runtime-unavailable cases.
    for kind in ['zero-cases','fixture-removal','source-needle-removal']:
        mutant=T/('miss-'+kind);ms=mutant/'suite';mr=mutant/'root';shutil.copytree(SUITE/'fixtures',ms/'fixtures')
        (mr/'scripts').mkdir(parents=True)
        (mr/'scripts/lib').mkdir()
        for name in [*SCRIPTS,*NEEDLES]:shutil.copy2(ROOT/'scripts'/name,mr/'scripts'/name)
        if kind=='zero-cases':(ms/'fixtures/cases.json').write_text('[]')
        if kind=='fixture-removal':(ms/'fixtures/log.txt').unlink()
        if kind=='source-needle-removal':
            p=mr/'scripts'/SCRIPTS[0];p.write_text(p.read_text().replace('release_delegate "$CURRENT_STAGE" "$HEALTH_SCRIPT"','capture bash "$HEALTH_SCRIPT"',1))
        q=run([sys.executable,__file__,'--audit-inputs',mr,ms],T,env)
        check(q.returncode==1,f'miss {kind} rejected rc1',q.stderr.decode())
    # Verify the explicit published layout and refuse absent/broken/unknown identity.
    published=T/'published-layout'
    q=run(['bash','-c','. "$1"; ff_git_fixture_init "$2"','fixture',fixture,published],T,env);assert q.returncode==0,q.stderr
    (published/'.claude-plugin').mkdir()
    shutil.copytree(SUITE,published/'tests/github-input-release',ignore=shutil.ignore_patterns('__pycache__'))
    manifest=published/'.claude-plugin/plugin.json'
    manifest.write_text('{"name":"ff-dev-toolkit"}')
    q=run([sys.executable,published/'tests/github-input-release/verify.py'],published,env)
    check(q.returncode==0 and q.stdout.startswith('○ skip:'.encode()),'actual public Git-root manifest => explicit not-applicable')
    for value in [None,'{','{"name":"unknown"}']:
        if value is None:manifest.unlink()
        else:manifest.write_text(value)
        q=run([sys.executable,published/'tests/github-input-release/verify.py'],published,env)
        check(q.returncode==1 and '○ skip:'.encode() not in q.stdout,'missing/broken/unknown public manifest cannot hide source loss')
    workflow=(ROOT/'oss/ff-dev-toolkit/.github/workflows/weekly-public-run-all.yml').read_text()
    exclusion=workflow.split('EXCLUDED_SSOT_SUITES="',1)[1].split('"',1)[0]
    check(exclusion.split().count('github-input-release')==1,'public workflow excludes this root-only suite exactly once')
    check(EXECUTED==set(CASES),'case manifest all reached, zero/dormant cases forbidden',str(EXECUTED ^ set(CASES)))
    check(PASS>0,'positive assertion count')
print(f'github-input-release: {PASS} passed, {FAIL} failed')
sys.exit(1 if FAIL else 0)
