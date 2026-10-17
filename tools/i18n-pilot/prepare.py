# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import hashlib,json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
rows = json.loads((root / 'build/i18n-pilot/before-syntax.json').read_text())
source_hashes = {}
byfile = {}
for row in rows:
    byfile.setdefault(row['file'], []).append(row)
for filename, inventory in sorted(byfile.items()):
    data = (root / filename).read_bytes()
    for row in (r for r in inventory if 'source' in r):
        if data[row['start']:row['end']].decode() != row['source']:
            raise RuntimeError('stale syntax inventory: ' + filename)
    source_hashes[filename] = hashlib.sha256(data).hexdigest()
source = (root / 'Sources/SourceVocabulary.swift').read_bytes()
lo = source.index(b'    static let shareSendingProgress')
hi = source.index(b'    static let addMoreTitle')
selected = [r for r in rows if r['kind'] == 'literal' and (
    r['file'] == 'Sources/SourceVocabulary+FinishSyncing.swift' or
    (r['file'] == 'Sources/SourceVocabulary.swift' and lo <= r['start'] < hi)
)]
functions = {'finishSyncingCardBody', 'finishSyncingInterrupted', 'finishSyncingSystemSubtitle', 'standingSyncFootnote', 'stallLastReached'}
messages = []
for r in selected:
    if r['declaration'] in functions:
        continue
    name = r['declaration']
    messages.append(dict(symbol=name, id='ios.sourceSync.' + name,
        english=json.loads(r['source']), args={}, description='Source status or sync control: ' + name,
        risk='routine', surfaces=['app','share','liveActivity','watch','watchWidget'],
        max_length=None, screenshot_refs=[], source_revision='1d4da7f', origin=r))
for name, arg in [('finishSyncingCardBody','count'), ('finishSyncingInterrupted','count'), ('finishSyncingSystemSubtitle','remaining')]:
    variants = [r for r in selected if r['declaration'] == name]
    one = json.loads(variants[0]['source'])
    other = json.loads(variants[1]['source'].replace('\\(' + arg + ')', '%1$lld'))
    # Include the selector as an interpolation even in the singular branch.
    one = one.replace('1 ', '%1$lld ', 1)
    messages.append(dict(symbol=name,id='ios.sourceSync.'+name, english=other,
        plural={'one':one,'other':other},args={arg:'Int'},description='Background sync result, selected by remaining item count.',
        risk='routine',surfaces=['app'],max_length=None,screenshot_refs=[],source_revision='1d4da7f'))
for r, suffix in zip([r for r in selected if r['declaration']=='standingSyncFootnote'],['Sustaining','Limited']):
    messages.append(dict(symbol='standingSyncFootnote'+suffix,id='ios.sourceSync.standingSyncFootnote'+suffix,
        english=json.loads(r['source']),args={},description='Background sync availability; the boolean selects a distinct complete message.',
        risk='routine',surfaces=['app'],max_length=None,screenshot_refs=[],source_revision='1d4da7f'))
out = root / 'test/i18n-pilot'
out.mkdir(parents=True,exist_ok=True)
(out/'source-hashes.json').write_text(json.dumps(source_hashes,indent=2)+'\n')
(out/'messages.json').write_text(json.dumps(messages,ensure_ascii=False,indent=2)+'\n')
(out/'discovery.json').write_text(json.dumps(selected,ensure_ascii=False,indent=2)+'\n')
expressions = {m['symbol']:'SourceVocabulary.'+m['symbol'] for m in messages if not m['args'] and not m['symbol'].startswith('standingSyncFootnote')}
for name,arg in [('finishSyncingCardBody','count'),('finishSyncingInterrupted','count'),('finishSyncingSystemSubtitle','remaining')]:
    for count in [0,1,2,10000]: expressions[f'{name}.{count}']=f'SourceVocabulary.{name}({arg}: {count})'
for b in ['true','false']: expressions['standingSyncFootnote.'+b]=f'SourceVocabulary.standingSyncFootnote(sustaining: {b})'
(out/'baseline-main.swift').write_text('import Foundation\nlet values: [String: String] = [\n'+',\n'.join(json.dumps(k)+': '+v for k,v in expressions.items())+'\n]\nlet data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])\nFileHandle.standardOutput.write(data)\n')
print(json.dumps({'selected_literal_nodes':len(selected),'messages':len(messages),'baseline_cases':len(expressions),'excluded_declarations':['stallLastReached']},indent=2))
