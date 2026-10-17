# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import json,shutil,subprocess,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
out=root/'build/i18n-pilot/collected';out.mkdir(exist_ok=True)
runs=[];gallery=None
for p in sorted((root/'build/i18n-pilot').glob('*/receipt.json')):
    r=json.loads(p.read_text());r['run']=p.parent.name;runs.append(r)
    if any('I18nPilotGalleryTests' in arg for arg in r.get('command',[])) and r.get('exit')==0:gallery=p.parent
(out/'runs.json').write_text(json.dumps(runs,indent=2)+'\n')
ci=[]
for p in ([] if '--gallery-only' in sys.argv else sorted((root/'build').glob('ci-*-test-attempt-*.xcresult'))):
    r=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(p)],check=True,capture_output=True,text=True)
    ci.append({'bundle':str(p),'summary':json.loads(r.stdout)})
(out/'ci.json').write_text(json.dumps(ci,indent=2)+'\n')
if gallery:
    with tempfile.TemporaryDirectory(dir=out) as scratch:
        export=Path(scratch)/'attachments'
        subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(gallery/'result.xcresult'),'--output-path',str(export)],check=True)
        if (out/'gallery').exists():shutil.rmtree(out/'gallery')
        shutil.move(str(export),out/'gallery')
for r in runs:
    s=r.get('summary',{})
    print(r['run'],r.get('canaries'),s.get('result'),s.get('passedTests'),s.get('failedTests'),s.get('skippedTests'),'deleted',r.get('deleted'))
for r in ci:print(r['bundle'],r['summary'].get('result'),r['summary'].get('totalTestCount'))
assert all(r.get('deleted') for r in runs),'a simulator still needs cleanup'
