# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import hashlib,json,re,collections,time
from pathlib import Path
root=Path(__file__).resolve().parents[2]
rows=json.loads((root/'build/i18n-pilot/before-syntax.json').read_text())
byfile=collections.defaultdict(list)
for row in rows:byfile[row['file']].append(row)
messages=json.loads((root/'test/i18n-pilot/messages.json').read_text())
constants={m['symbol']:m for m in messages if 'origin' in m}
# Offset-based edits are safe only on the discovery tree. Refuse every changed
# literal before writing any file, rather than applying offsets to a later tree.
for m in constants.values():
    r=m['origin']
    if (root/r['file']).read_bytes()[r['start']:r['end']].decode()!=r['source']:
        raise RuntimeError('apply requires the original discovery tree')
dynamic={m['symbol']:m for m in messages if m['args']}
aliases={'waitingToSync':'sendStateCompactSaved','screencastPrimerBody':'screencastPrimerBodyOff'}
keys={k:m['id'] for k,m in constants.items()}
keys.update({k:keys[v] for k,v in aliases.items()})
edits=collections.defaultdict(list)
timings={};phase=time.perf_counter()
def add(f,a,b,s,reason): edits[f].append((a,b,s.encode(),reason))
for name,m in constants.items():
    r=m['origin']; data=(root/r['file']).read_bytes()
    start=data.rfind(b'\n',0,r['start'])+1
    prefix=data[start:r['start']].decode()
    # The variable declaration may wrap its initializer onto a second line.
    if 'static let' not in prefix:
        start=data.rfind(b'\n',0,start-1)+1; prefix=data[start:r['start']].decode()
    modifiers=prefix.split('static let')[0]
    add(r['file'],start,r['end'],f'{modifiers}static var {name}: LocalizedStringResource {{ PilotCopy.{name} }}','constant')
f='Sources/SourceVocabulary+FinishSyncing.swift'; data=(root/f).read_bytes()
timings['constant_edit_planning']=time.perf_counter()-phase;phase=time.perf_counter()
for name,m in dynamic.items():
    pattern=rb'    nonisolated static func '+name.encode()+rb'\([^\n]+\) -> String \{.*?\n    \}'
    match=re.search(pattern,data,re.S); assert match,name
    arg=next(iter(m['args']))
    add(f,match.start(),match.end(),f'    nonisolated static func {name}({arg}: Int) -> SourceSyncMessage {{\n        PilotCopy.{name}({arg})\n    }}','plural')
match=re.search(rb'    nonisolated static func standingSyncFootnote.*?\n    \}',data,re.S);assert match
add(f,match.start(),match.end(),'    nonisolated static func standingSyncFootnote(sustaining: Bool) -> LocalizedStringResource {\n        sustaining ? PilotCopy.standingSyncFootnoteSustaining : PilotCopy.standingSyncFootnoteLimited\n    }','select')
# Tests of literal copy become tests of the stable identity. The separate byte
# comparison keeps the English invariant, instead of duplicating every label.
timings['plural_select_edit_planning']=time.perf_counter()-phase;phase=time.perf_counter()
migrated=[]; pins=[]
for r in rows:
    if r['kind']!='call' or not r['file'].startswith(('Tests/','WatchTests/')):continue
    s=r['source']
    refs=[x for x in keys if 'SourceVocabulary.'+x in s]
    if not refs:continue
    literals=[x for x in byfile[r['file']] if x['kind']=='literal' and r['start']<=x['start']<r['end']]
    if literals:pins.append(r)
    match=re.fullmatch(r'XCTAssertEqual\(\s*SourceVocabulary\.(\w+),\s*("(?:[^"\\]|\\.)*")\s*\)',s,re.S)
    if match and match[1] in keys:
        add(r['file'],r['start'],r['end'],f'XCTAssertEqual(SourceVocabulary.{match[1]}.key, {json.dumps(keys[match[1]])})','assertion')
        migrated.append(r)
timings['assertion_edit_planning']=time.perf_counter()-phase;phase=time.perf_counter()
for r in rows:
    if r['kind']=='member' and r['base'] in ['SourceVocabulary','Self'] and r['name'] in keys:
        if r['parent']=='functionCallExpr':continue # overloaded helper, not the constant
        data=(root/r['file']).read_bytes(); token=data[r['start']:r['end']].decode()
        # Text(resource) retains SwiftUI's typed path. Other APIs require a rendered String.
        textcall=any(x['kind']=='call' and x.get('callee')=='Text' and x['start']<r['start']<x['end'] and re.fullmatch(r'Text\(\s*'+re.escape(token)+r'\s*\)',x['source']) for x in byfile[r['file']])
        if not textcall:add(r['file'],r['start'],r['end'],'String(localized: '+token+')','string-boundary')
    if r['kind']=='call' and r.get('callee','').removeprefix('SourceVocabulary.') in dynamic and r['callee'].startswith('SourceVocabulary.'):
        add(r['file'],r['start'],r['end'],r['source']+'.rendered','plural-boundary')
    if r['kind']=='call' and r.get('callee')=='SourceVocabulary.standingSyncFootnote':
        add(r['file'],r['start'],r['end'],'String(localized: '+r['source']+')','select-boundary')
counts=collections.Counter()
timings['boundary_edit_planning']=time.perf_counter()-phase;phase=time.perf_counter()
source_hashes=json.loads((root/'test/i18n-pilot/source-hashes.json').read_text())
for filename in edits:
    if hashlib.sha256((root/filename).read_bytes()).hexdigest()!=source_hashes[filename]:
        raise RuntimeError('stale consumer file: '+filename)
for f,patches in edits.items():
    data=(root/f).read_bytes(); retained=[]
    # Enclosing declaration/assertion edits own their range; drop nested rewrites.
    for p in sorted(patches,key=lambda p:(p[0],-p[1])):
        if retained and p[0]<retained[-1][1]:continue
        retained.append(p);counts[p[3]]+=1
    for a,b,s,_ in reversed(retained):data=data[:a]+s+data[b:]
    (root/f).write_bytes(data)
timings['file_application']=time.perf_counter()-phase
(root/'test/i18n-pilot/migration.json').write_text(json.dumps({'edits':counts,'files':len(edits),'english_pins':pins,'migrated':migrated,'mechanical_seconds':timings},ensure_ascii=False,indent=2)+'\n')
print(dict(counts), 'files',len(edits))
