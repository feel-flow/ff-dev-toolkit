#!/usr/bin/env python3
"""Local predicates and finish integration. --consumer-only excludes finish cases."""
import argparse, json, os, pathlib, shutil, subprocess, sys, tempfile
HERE = pathlib.Path(__file__).resolve().parent
NAMES = ['effort-golden','effort-negative','lookup','doctor','subject','finish-probe','finish-push','finish-pr','mapping']
REQUIRED = ['effort.json','labels.json','open.json','parents.json','drafts.json','empty.json','classic.json','repo.json','rules.json','subject.json','mcp-parent-404.json','mcp-parent-403.json','mcp-parent-400.json']
a=argparse.ArgumentParser();a.add_argument('--consumer-only',action='store_true');a.add_argument('--fixtures',type=pathlib.Path,default=HERE/'fixtures');a.add_argument('--source-root',type=pathlib.Path,default=HERE.parent.parent);a.add_argument('--probe-only',action='store_true');args=a.parse_args()
p=args.source_root.resolve(); f=args.fixtures.resolve(); checks=0

def check(ok,what):
 global checks
 checks+=1
 if not ok: raise AssertionError(what)
 print('  ✓ '+what,flush=True)

def preflight():
 c=json.loads((f/'cases.json').read_text())['cases']
 if c != NAMES: raise AssertionError('case set missing/empty/drifted')
 for name in REQUIRED:
  if not (f/name).is_file(): raise AssertionError('missing fixture '+name)
  json.loads((f/name).read_text())
 for name,needle in [('effort-report.sh','effort.issues'),('knowledge-lookup.sh','lookup.open-set'),('workflow-doctor.sh','doctor_file()'),('knowledge-commit.sh','knowledge.subject-issue')]:
  if needle not in (p/'scripts'/name).read_text(): raise AssertionError('missing source needle '+name+':'+needle)
preflight()
if args.probe_only: sys.exit(0)
with tempfile.TemporaryDirectory(prefix='github-input-knowledge.') as d:
 t=pathlib.Path(d); b=t/'bin';b.mkdir(); cfg=t/'claude';cfg.mkdir(); leak=t/'gh-leak';calls=t/'gh-calls'
 # No system bin directory is exposed: installed gh cannot leak through PATH.
 for name in ['bash','git','jq','dirname','sed','cat','mktemp','rm','awk','find','head','sort','tr','grep','cut','wc','basename','date','uname','readlink','mv','mkdir','tail','env','chmod','sleep','touch','printf','ls']:
  loc=shutil.which(name)
  if loc: (b/name).symlink_to(loc)
 env={'PATH':str(b),'LC_ALL':'C','TMPDIR':str(t),'HOME':os.environ['HOME'],'CLAUDE_CONFIG_DIR':str(cfg),'FF_DEV_TOOLKIT_ROOT':str(p),'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'}
 def stub(body):
  q=b/'gh'
  if q.exists() or q.is_symlink():q.unlink()
  q.write_text('#!/bin/bash\n'+body+'\n');q.chmod(0o755)
 def refuse():stub("printf 'leak\\n' >> "+str(leak)+"\nexit 97")
 def run(script,argv,cwd=None,expected=0,diagnostic=None):
  cp=subprocess.run([str(b/'env'),'-i',*[key+'='+value for key,value in env.items()],str(b/'bash'),str(p/'scripts'/script),*map(str,argv)],cwd=cwd or t,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
  if cp.returncode != expected:raise AssertionError(f'{script} {argv}: rc={cp.returncode} expected={expected}\n'+cp.stdout.decode(errors='replace')+'\n'+cp.stderr.decode(errors='replace'))
  if diagnostic is not None and diagnostic.encode() not in cp.stdout+cp.stderr:raise AssertionError('expected diagnostic missing: '+diagnostic)
  return cp.stdout
 def put(name,obj):
  x=t/name;x.write_text(json.dumps(obj,ensure_ascii=False)+'\n');return x
 def index(entries,name='index.json'):
  return put(name,{'version':1,'responses':entries})
 def entry(op,scope,body,phase='inspect',**kw):
  return dict(operation=op,scope={'repository':'https://github.com/example/repo',**scope},phase=phase,body=str(body),last=True,**kw)
 def repo(name='repo',branch='develop'):
  x=t/name;x.mkdir(); bare=t/(name+'.git')
  def g(*argv):return subprocess.check_output([str(b/'git'),'-C',str(x),*argv],env=env,stderr=subprocess.DEVNULL).decode().strip()
  subprocess.run([str(b/'git'),'init','--bare','--initial-branch=develop',str(bare)],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  g('init','--initial-branch=develop');g('config','user.name','Fixture');g('config','user.email','fixture@example.invalid');g('config','remote.origin.url','https://github.com/example/repo');g('config','remote.origin.fetch','+refs/heads/*:refs/remotes/origin/*');g('config','url.file://'+str(bare)+'.insteadOf','https://github.com/example/repo')
  (x/'seed').write_text('seed\n');g('add','seed');g('commit','-m','seed');g('push','-u','origin','develop');g('symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/develop')
  if branch!='develop':g('switch','-c',branch)
  return x,g
 # Explicit empty file selection must stop before optional/default gh fallback.
 empty_root,empty_git=repo('empty-selection','ace-from-pr-7-'+chr(35)+'9')
 empty_doc=empty_root/'docs/08-knowledge/OBSERVATIONS.md';empty_doc.parent.mkdir(parents=True);empty_doc.write_text('observation\n')
 refuse()
 for label,script,argv in [
  ('effort','effort-report.sh',['--repo','example/repo','--github-input','']),
  ('lookup','knowledge-lookup.sh',['--root',empty_root,'--promoted-open','--github-input','']),
  ('doctor','workflow-doctor.sh',['--root',empty_root,'--repo','example/repo','--github-input','']),
  ('add','knowledge-commit.sh',['add','--github-input','','--source','obs','--id','OBS-001','--summary','fixture','--',empty_doc]),
  ('commit','knowledge-commit.sh',['commit','--github-input','']),
 ]:
  run(script,argv,cwd=empty_root,expected=2)
  check(not leak.exists(),'explicit empty --github-input '+label+' rc2 before gh')
 # effort: both acquisition modes feed exactly the same existing two passes.
 raw=f/'effort.json'
 stub("printf '%s\\n' \"$*\" >> "+str(calls)+"\ncat "+str(raw))
 gh=run('effort-report.sh',['--repo','example/repo','--state','closed','--limit','2','--format','kv'])
 check(calls.read_text()=='issue list --repo example/repo --state closed --limit 2 --json number,body\n','effort original gh argv')
 ix=index([entry('effort.issues',{'state':'closed','limit':2},raw,'collect')]);refuse()
 fi=run('effort-report.sh',['--repo','example/repo','--state','closed','--limit','2','--format','kv','--github-input',ix])
 check(gh==fi,'effort gh/file bytes and limit display identical')
 for body,scope,desc in [(put('missing-body.json',[{'number':7}]),{'state':'closed','limit':2},'body'),(put('other.json',[]),{'state':'closed','limit':2,'repository':'https://github.com/other/repo'},'repository'),(t/'bad.json',{'state':'closed','limit':2},'JSON')]:
  if desc=='JSON':body.write_text('{bad\n')
  ix=index([entry('effort.issues',scope,body,'collect')]);run('effort-report.sh',['--repo','example/repo','--state','closed','--limit','2','--github-input',ix],expected=2);check(True,'effort mandatory '+desc+' rejected rc2')
 ix=index([entry('effort.issues',{'state':'all','limit':200},f/'empty.json','collect')]);run('effort-report.sh',['--repo','example/repo','--github-input',ix]);check(True,'effort complete [] stays valid')
 run('effort-report.sh',['--input',t/'missing-body.json'],expected=1);check(True,'legacy raw missing-body rc1 unchanged')
 # lookup uses one response for both references and retains unknown vs complete[].
 root=t/'lookup';k=root/'docs/08-knowledge';k.mkdir(parents=True)
 (k/'OBSERVATIONS.md').write_text('''# Observations
### OBS-001: file lookup fixture
| Kind | problem |
| Count | 1 |
| Last | 2026-10-22 |
| Status | promoted |
| Issue | example/repo#7 / example/repo#8 |
fixture
''')
 argv=['--root',root,'--promoted-open']
 stub("printf '%s\\n' \"$*\" >> "+str(calls)+"\nprintf '7\\n'")
 gh=run('knowledge-lookup.sh',argv);refuse()
 ix=index([entry('lookup.open-set',{'state':'open','limit':1000},put('lookup-open.json',[{'number':7}]),'lookup')]);fi=run('knowledge-lookup.sh',[*argv,'--github-input',ix]);check(gh==fi and (b'#'+b'7(open)') in fi and (b'#'+b'8(closed)') in fi,'lookup gh/file bytes and repo cache')
 ix=index([]);out=run('knowledge-lookup.sh',[*argv,'--github-input',ix]);check(('#'+'7(未確認)').encode() in out,'lookup unavailable keeps local result unknown')
 stub('exit 0');empty_gh=run('knowledge-lookup.sh',argv);refuse()
 ix=index([entry('lookup.open-set',{'state':'open','limit':1000},f/'empty.json','lookup')]);out=run('knowledge-lookup.sh',[*argv,'--github-input',ix]);check(empty_gh==out and (b'#'+b'7(') not in out,'lookup complete [] differs from unavailable')
 ix=index([entry('lookup.open-set',{'state':'open','limit':1000},put('limit.json',[{'number':n+1} for n in range(1000)]),'lookup')]);out=run('knowledge-lookup.sh',[*argv,'--github-input',ix]);check(('#'+'7(未確認)').encode() in out,'lookup 1000 bound stays unknown')
 # Doctor preserves original projections, skips PRs and handles parent/draft failures.
 root=t/'doctor';(root/'.claude').mkdir(parents=True);(root/'.claude/settings.json').write_text('{}\n')
 (root/'CLAUDE.md').write_text('# CLAUDE.md\n\n## Git Workflow\n\n1. 着手前\n\n## スコープ外の発見\n\n1. YAGNI\n2. 同 PR インライン\n3. 既存 bundle へ追記\n4. 新規は bundle 単位のみ\n')
 argv=['--root',root,'--repo','example/repo','--global-claude',t/'no-global','--settings',root/'.claude/settings.json']
 base=[entry('doctor.labels',{'limit':200},f/'labels.json'),entry('doctor.bundle-list',{'state':'open','label':'bundle','limit':200},put('bundle.json',[{'number':20}])),entry('doctor.open-issues',{'state':'open','per_page':100},f/'open.json',page=1),entry('doctor.parents',{'numbers':[7]},f/'parents.json'),entry('doctor.drafts',{'state':'open','draft':True,'author':'@me','limit':200},f/'drafts.json')]
 stub('''case "$*" in
'label list '*) printf 'bundle\\nepic\\nfollow-up\\npriority:high\\n' ;;
'issue list '*) printf '1\\n' ;;
'api --paginate '*) printf '7\\n' ;;
'api graphql '*) printf '7\\n' ;;
'pr list '*) printf '10\\tknowledge: ignored\\n11\\tfeature\\n' ;;
*) exit 98 ;; esac''')
 gh=run('workflow-doctor.sh',argv);refuse();ix=index(base);fi=run('workflow-doctor.sh',[*argv,'--github-input',ix]);check(gh==fi,'doctor gh/file byte equality, PR exclusion and @me selector')
 for op,no in [('doctor.labels',5),('doctor.parents',6),('doctor.drafts',11)]:
  ix=index([x for x in base if x['operation']!=op]);out=run('workflow-doctor.sh',[*argv,'--github-input',ix]);check(('SKIP\t'+str(no)+'\t').encode() in out,op+' unavailable is SKIP')
 ix=index([{**x,'scope':{**x['scope'],'author':'another'}} if x['operation']=='doctor.drafts' else x for x in base]);out=run('workflow-doctor.sh',[*argv,'--github-input',ix]);check(b'SKIP\t11\t' in out,'doctor cannot replace @me with guessed identity')
 for status in [403,400]:
  entries=[{**x,'body':str(f/f'mcp-parent-{status}.json'),'http_status':status} if x['operation']=='doctor.parents' else x for x in base];out=run('workflow-doctor.sh',[*argv,'--github-input',index(entries)]);check(b'SKIP\t6\t' in out,'doctor parent '+str(status)+' never becomes parent=null')
 entries=[{**x,'last':False} if x['operation']=='doctor.open-issues' else x for x in base];out=run('workflow-doctor.sh',[*argv,'--github-input',index(entries)]);check(b'SKIP\t6\t' in out,'doctor incomplete pagination stays SKIP')
 # Optional subject provenance retains real Git guards and branch fallback.
 for n,entries,expected in [('subject-file',[entry('knowledge.subject-issue',{'pr':7},f/'subject.json','subject')],42),('subject-fallback',[],9)]:
  root,g=repo(n,'ace-from-pr-7-#9');hook=root/'.git/hooks/commit-msg';hook.write_text('#!/bin/bash\ngrep -qE \'#[0-9]+\' \"$1\"\n');hook.chmod(0o755);doc=root/'docs/08-knowledge/OBSERVATIONS.md';doc.parent.mkdir(parents=True);doc.write_text('observation\n')
  run('knowledge-commit.sh',['add','--github-input',index(entries),'--source','obs','--id','OBS-001','--summary','fixture','--',doc],cwd=root)
  pending=(root/'.git/ff-knowledge-pending').read_text();check(('I\t'+str(expected)+'\n') in pending,n+' optional closing reference/fallback')
 # Fixture mapping does not certify an MCP call or its authenticated actor.
 for status in [404,403,400]:
  e=json.loads((f/f'mcp-parent-{status}.json').read_text())
  mapped={'number':7,'parent':None} if e.get('error_data',{}).get('status')==404 else None
  check((mapped is not None)==(status==404),'mapping recognizes API '+str(status)+' without guessing parent')
 # Empty doctor collections retain their distinct existing outcomes.
 empty_entries=[{**x,'body':str(f/'empty.json')} if x['operation'] in ['doctor.bundle-list','doctor.open-issues','doctor.drafts'] else x for x in base]
 out=run('workflow-doctor.sh',[*argv,'--github-input',index(empty_entries)])
 check(b'WARN\t4\t' in out and b'INFO\t6\t' in out and b'OK\t11\t' in out,'doctor complete [] differs from missing collections')
 origin,g=repo('doctor-origin');(origin/'.claude').mkdir();(origin/'.claude/settings.json').write_text('{}\n');(origin/'CLAUDE.md').write_text((t/'doctor/CLAUDE.md').read_text())
 origin_argv=['--root',origin,'--global-claude',t/'no-global','--settings',origin/'.claude/settings.json']
 out=run('workflow-doctor.sh',[*origin_argv,'--github-input',index(base)])
 check(b'OK\t5\t' in out and b'WARN\t6\t' in out and b'WARN\t11\t' in out,'doctor resolves configured origin before local transport rewrite')
 # A canonical parent-null mapped only from a recognized endpoint API404 has the normal result.
 mapped=put('mapped-parent.json',{'data':{'repository':{'i7':{'number':7,'parent':None}}}})
 out=run('workflow-doctor.sh',[*argv,'--github-input',index([{**x,'body':str(mapped)} if x['operation']=='doctor.parents' else x for x in base])])
 check(b'WARN\t6\t' in out,'doctor accepts mapped parent-null, distinct from forbidden acquisition')
 for kind,payload in [('missing-parent',{'data':{'repository':{'i7':{'number':7}}}}),('extra-parent',{'data':{'repository':{'i7':{'number':7,'parent':None},'i8':{'number':8,'parent':None}}}})]:
  out=run('workflow-doctor.sh',[*argv,'--github-input',index([{**x,'body':str(put(kind+'.json',payload))} if x['operation']=='doctor.parents' else x for x in base])]);check(b'SKIP\t6\t' in out,'doctor '+kind+' cannot establish orphan set')
 if not args.consumer_only:
  # Optional identity lookup must not turn local add/commit/probe/push into a stop.
  env['FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD']='1'  # only disposable fixture commits
  for transport in ['userinfo','local-bare']:
   for lane in ['direct','wrapper']:
    origin_root,origin_git=repo('optional-'+transport+'-'+lane,'ace-from-pr-7-'+chr(35)+'9');bare=t/(origin_root.name+'.git')
    origin_url='https://fixture@github.com/example/repo' if transport=='userinfo' else str(bare)
    origin_git('config','remote.origin.url',origin_url);origin_git('config','url.file://'+str(bare)+'.insteadOf',origin_url)
    hook=origin_root/'.git/hooks/commit-msg';hook.write_text('#!/bin/bash\ngrep -qE \'#[0-9]+\' "$1"\n');hook.chmod(0o755)
    doc=origin_root/'docs/08-knowledge/OBSERVATIONS.md';doc.parent.mkdir(parents=True);doc.write_text('optional origin\n');ix=index([])
    script='finish.sh' if lane=='wrapper' else 'knowledge-commit.sh';prefix=['knowledge-commit'] if lane=='wrapper' else []
    run(script,[*prefix,'add','--github-input',ix,'--source','obs','--id','OBS-001','--summary','origin fixture','--',doc],cwd=origin_root)
    check('I\t9\n' in (origin_root/'.git/ff-knowledge-pending').read_text(),'optional '+transport+' '+lane+' add keeps branch issue fallback')
    run(script,[*prefix,'commit','--github-input',ix],cwd=origin_root)
    check((chr(35)+'9 ') in origin_git('log','-1','--format=%s'),'optional '+transport+' '+lane+' commit preserves local result')
    if lane=='wrapper':
     out=run('finish.sh',['knowledge-commit','probe','--github-input',ix],cwd=origin_root)
     check(b'protection=unknown' in out,'optional '+transport+' probe stays unknown')
     if transport=='local-bare':
      for argv in [['precheck','7'],['cleanup','7','--dry-run'],['knowledge-commit','pr','--branch',origin_git('branch','--show-current')]]:
       out=run('finish.sh',[*argv,'--github-input',ix],cwd=origin_root,expected=2,diagnostic='github-input: repository:')
       check(True,'mandatory '+argv[0]+' rejects unresolved identity')
      run('finish.sh',['knowledge-commit','add','--github-input','relative.json'],cwd=origin_root,expected=2)
      run('finish.sh',['knowledge-commit','add','--github-input',''],cwd=origin_root,expected=2)
      check(True,'optional origin does not weaken explicit blank/relative argument errors')
   pushing,push_git=repo('optional-push-'+transport);bare=t/(pushing.name+'.git')
   origin_url='https://fixture@github.com/example/repo' if transport=='userinfo' else str(bare)
   push_git('config','remote.origin.url',origin_url);push_git('config','url.file://'+str(bare)+'.insteadOf',origin_url)
   (pushing/'seed').write_text('knowledge update\n');push_git('add','seed');push_git('commit','-m','knowledge: optional identity')
   out=run('finish.sh',['knowledge-commit','push','--github-input',index([])],cwd=pushing)
   check(b'KNOWLEDGE_PUSH=ok' in out and b'KNOWLEDGE_CI=(unavailable)' in out,'optional '+transport+' push is local delivered with CI unavailable')
  env.pop('FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD')
  # Central finish glue is required, never silently skipped by the registered suite.
  root,g=repo('finish-probe');ix=index([entry('knowledge.repo',{},f/'repo.json','probe'),entry('knowledge.classic-protection',{'branch':'develop'},f/'classic.json','probe',http_status=200),entry('knowledge.rulesets',{'branch':'develop'},f/'rules.json','probe')]);out=run('finish.sh',['knowledge-commit','probe','--github-input',ix],cwd=root);check(b'protection=unprotected' in out,'finish file protection probe')
  for status in [403,400]:
   ix=index([entry('knowledge.repo',{},f/'repo.json','probe'),entry('knowledge.classic-protection',{'branch':'develop'},f/f'mcp-parent-{status}.json','probe',http_status=status),entry('knowledge.rulesets',{'branch':'develop'},f/'rules.json','probe')]);out=run('finish.sh',['knowledge-commit','probe','--github-input',ix],cwd=root);check(b'protection=unknown' in out,'finish classic '+str(status)+' remains unknown')
  # Central integration regressions: metadata provenance and exact write/read-back bytes.
  for kind,classic_body,classic_status,rules_last,rules_status,want in [
   ('recognized-404',f/'mcp-parent-404.json',404,True,None,'unprotected'),
   ('text-404-not-status',f/'mcp-parent-404.json',None,True,None,'unknown'),
  ]:
   cl=entry('knowledge.classic-protection',{'branch':'develop'},classic_body,'probe')
   if classic_status is not None: cl['http_status']=classic_status
   ru={**entry('knowledge.rulesets',{'branch':'develop'},f/'empty.json','probe'),'last':rules_last}
   if rules_status is not None: ru['http_status']=rules_status
   out=run('finish.sh',['knowledge-commit','probe','--github-input',index([entry('knowledge.repo',{},f/'repo.json','probe'),cl,ru])],cwd=root)
   check(('protection='+want+' ').encode() in out,'central probe '+kind)
  # Real Git push is to an isolated bare repository; CI comes only after it.
  (root/'seed').write_text('knowledge\n');g('add','seed');g('commit','-m','knowledge: fixture');sha=g('rev-parse','HEAD')
  ci=put('ci.json',[{'status':'completed','conclusion':'success','workflowName':'gate','headSha':'0'*40}]);ix=index([entry('knowledge.ci',{'branch':'develop','limit':5,'pushed_sha':sha},ci,'after-push')]);out=run('finish.sh',['knowledge-commit','push','--github-input',ix],cwd=root);check(b'KNOWLEDGE_PUSH=ok' in out and b'\tother' in out and b'this-push' not in out,'finish delivered push does not claim other SHA CI')
  (root/'seed').write_text('knowledge2\n');g('add','seed');g('commit','-m','knowledge: next');out=run('finish.sh',['knowledge-commit','push','--github-input',index([])],cwd=root);check(b'KNOWLEDGE_PUSH=ok' in out and b'KNOWLEDGE_CI=(unavailable)' in out,'finish delivered push survives optional missing CI')
  for kind in ['nullable-conclusion','wrong-scope-sha','missing-status','over-limit']:
   (root/'seed').write_text(kind+'\n');g('add','seed');g('commit','-m','knowledge: '+kind);actual=g('rev-parse','HEAD')
   item={'status':'completed','conclusion':None,'workflowName':'nullable','headSha':actual}
   data=[item]*6 if kind=='over-limit' else [item]
   if kind=='missing-status': del item['status']
   scope_sha='0'*40 if kind=='wrong-scope-sha' else actual
   ci=put('central-ci.json',data);ix=index([entry('knowledge.ci',{'branch':'develop','limit':5,'pushed_sha':scope_sha},ci,'after-push')])
   out=run('finish.sh',['knowledge-commit','push','--github-input',ix],cwd=root)
   check(b'KNOWLEDGE_PUSH=ok' in out and ((b'nullable\tcompleted\t-\tthis-push' in out) if kind=='nullable-conclusion' else b'KNOWLEDGE_CI=(unavailable)' in out),'central after-push '+kind)
  # PR plan performs the existing isolated Git push but creates no remote PR.
  (root/'seed').write_text('knowledge3\n');g('add','seed');g('commit','-m','knowledge: PR');sha=g('rev-parse','HEAD');title='knowledge: exact title';body='line1\nline2';branch='chore/knowledge-fixture'
  out=run('finish.sh',['knowledge-commit','pr','--github-input',index([]),'--branch',branch,'--title',title,'--body',body],cwd=root,expected=2)
  plans=[json.loads(x[5:]) for x in out.decode().splitlines() if x.startswith('PLAN:')];check(len(plans)==1 and plans[0]['arguments']=={'head':branch,'base':'develop','title':title,'body':body,'head_sha':sha} and b'KNOWLEDGE_PR=' not in out,'finish exact PLAN with no completion marker before readback')
  # Retry on the pushed PR branch; mismatch must remain pending.
  pr=put('pr.json',{'number':30,'url':'https://github.com/example/repo/pull/30','state':'OPEN','headRefName':branch,'baseRefName':'develop','title':title,'body':body,'headRefOid':sha})
  mismatch=put('pr-mismatch.json',{**json.loads(pr.read_text()),'headRefOid':'f'*40})
  out=run('finish.sh',['knowledge-commit','pr','--github-input',index([entry('knowledge.pr-create',{},mismatch,'after-write')]),'--branch',branch,'--title',title,'--body',body],cwd=root,expected=2);check(b'PLAN:' in out and b'KNOWLEDGE_PR=' not in out,'finish mismatched PR head remains pending')
  ix=index([entry('knowledge.pr-create',{},pr,'after-write')]);out=run('finish.sh',['knowledge-commit','pr','--github-input',ix,'--branch',branch,'--title',title,'--body',body],cwd=root);check(b'KNOWLEDGE_PR=https://github.com/example/repo/pull/30' in out,'finish matching raw PR readback permits existing completion marker')
  nested,g=repo('finish-nested','ace-from-pr-7-#9');hook=nested/'.git/hooks/commit-msg';hook.write_text('#!/bin/bash\ngrep -qE \'#[0-9]+\' \"$1\"\n');hook.chmod(0o755);doc=nested/'docs/08-knowledge/OBSERVATIONS.md';doc.parent.mkdir(parents=True);doc.write_text('nested\n')
  ix=index([entry('knowledge.subject-issue',{'pr':7},f/'subject.json','subject')]);out=run('finish.sh',['knowledge-commit','add','--github-input',ix,'--source','obs','--id','OBS-001','--summary','nested','--',doc],cwd=nested);check((b'#'+b'42 ') in out,'finish forwards explicit index to nested knowledge add before pathspec')
 if not args.consumer_only:
  special,g=repo('central-pr-special');(special/'seed').write_text('special\n');g('add','seed');g('commit','-m','knowledge: special');sha=g('rev-parse','HEAD')
  title='--github-input';body="日本語 ' 引用\n末尾\n\n";branch='chore/knowledge-special'
  out=run('finish.sh',['knowledge-commit','pr','--title',title,'--body',body,'--github-input',index([]),'--branch',branch],cwd=special,expected=2)
  plan=[json.loads(x[5:]) for x in out.decode().splitlines() if x.startswith('PLAN:')]
  check(len(plan)==1 and plan[0]['arguments']=={'head':branch,'base':'develop','title':title,'body':body,'head_sha':sha},'central exact PLAN preserves option-valued title, Japanese, quotes and final LF')
  canonical={'number':55,'url':'https://github.com/example/repo/pull/55','state':'OPEN','headRefName':branch,'baseRefName':'develop','title':title,'body':body,'headRefOid':sha}
  for kind in ['wrong-url','receipt-not-readback']:
   raw=dict(canonical)
   if kind=='wrong-url':raw['url']='https://other.example/example/repo/pull/55'
   ent=entry('knowledge.pr-create',{},put('central-pr.json',raw),'after-write')
   if kind=='receipt-not-readback':ent['http_status']=201
   out=run('finish.sh',['knowledge-commit','pr','--title',title,'--body',body,'--github-input',index([ent]),'--branch',branch],cwd=special,expected=2)
   check(b'PLAN:' in out and b'KNOWLEDGE_PR=' not in out,'central PR read-back '+kind+' stays pending')
  ix=index([entry('knowledge.pr-create',{},put('central-pr.json',canonical),'after-write')])
  out=run('finish.sh',['knowledge-commit','pr','--title',title,'--body',body,'--github-input',ix,'--branch',branch],cwd=special)
  check(b'KNOWLEDGE_PR=https://github.com/example/repo/pull/55' in out,'central matching byte-exact PR read-back')
 check(not leak.exists(),'file mode gh leak count 0')
 # Vaguely preserved names are not sufficient: preflight misses must be red.
 for mutation in ['empty-cases','missing-fixture','missing-source-needle']:
  mf=t/('miss-'+mutation);shutil.copytree(f,mf);source=p
  if mutation=='empty-cases':(mf/'cases.json').write_text('{"cases":[]}\n')
  elif mutation=='missing-fixture':(mf/'effort.json').unlink()
  else:
   source=t/'missing-source';(source/'scripts').mkdir(parents=True)
   for name in ['effort-report.sh','knowledge-lookup.sh','workflow-doctor.sh','knowledge-commit.sh']:
    text=(p/'scripts'/name).read_text().replace('effort.issues','absent.operation');(source/'scripts'/name).write_text(text)
  cp=subprocess.run([sys.executable,str(HERE/'verify.py'),'--probe-only','--fixtures',str(mf),'--source-root',str(source)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
  check(cp.returncode==1,'vacuity '+mutation+' red rc1')
 print(('PARTIAL consumer-only; finish wrapper/probe/push/PR cases excluded. ' if args.consumer_only else 'COMPLETE ')+'pass='+str(checks)+' fail=0',flush=True)
