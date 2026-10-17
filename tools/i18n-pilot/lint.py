# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import json,sys,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
rows=json.loads((root/'build/i18n-pilot/syntax.json').read_text())
source=(root/'Sources/SourceVocabulary.swift').read_bytes()
lo=source.index(b'    static var shareSendingProgress')
hi=source.index(b'    static let addMoreTitle')
# Positive control: parser must see the known machine symbol outside the slice.
assert any(r['kind']=='literal' and r['file']=='Sources/SourceVocabulary.swift' and r['source']=='"power.circle"' for r in rows),'AST positive control absent'
baseline=json.loads((root/'test/i18n-pilot/lint-baseline.json').read_text())
allowed={(r['file'],r['declaration'],r['source']) for r in baseline}
files={r['file'] for r in baseline}
names={m['symbol'] for m in json.loads((root/'test/i18n-pilot/messages.json').read_text())}
names.update(['waitingToSync','screencastPrimerBody'])
def original_literal(source):
    for name in names:
        source=source.replace('String(localized: SourceVocabulary.'+name+')','SourceVocabulary.'+name)
    return source
# This pre-existing interpolation is outside the slice; its reference now renders
# the converted button resource. Its full-message extraction stays deferred.
composed={(r['file'],r['declaration'],r['source'].replace('\\(tryNow)', '\\(String(localized: tryNow))')) for r in baseline if r['declaration']=='onThisPhoneRefusalPacedMessage'}
explicit=json.loads((root/'test/i18n-pilot/lint-allow.json').read_text())
assert all(r.get('reason') for r in explicit)
exceptions={(r['file'],r['declaration'],r['source']) for r in explicit}
def violations(inventory):
    converted=[r for r in inventory if r['kind']=='literal' and (
        r['file']=='Sources/SourceVocabulary+FinishSyncing.swift' or
        (r['file']=='Sources/SourceVocabulary.swift' and lo<=r['start']<hi and r['declaration']!='stallLastReached'))]
    fresh=[r for r in inventory if r['kind']=='literal' and r['file'] in files
        and (r['file'],r['declaration'],original_literal(r['source'])) not in allowed
        and (r['file'],r['declaration'],r['source']) not in composed
        and (r['file'],r['declaration'],r['source']) not in exceptions]
    unique={(r['file'],r['start'],r['end']):r for r in converted+fresh}
    return list(unique.values())
bad=violations(rows)
for r in bad:print(f"new literal needs classification: {r['file']} {r['declaration']} {r['source']}")
if '--selftest' in sys.argv:
    with tempfile.TemporaryDirectory(prefix='i18n-lint-') as td:
        relative='Sources/Screencast/ScreencastSourceDetailView.swift'
        p=Path(td)/'probe.swift';p.write_text((root/relative).read_text()+'\nstruct Probe: View { var body: some View { Text("unwrapped regression") } }')
        found=json.loads(subprocess.run([str(root/'build/i18n-pilot/scan'),str(p)],check=True,capture_output=True,text=True).stdout)
        for r in found:r['file']=relative
        injected=violations(found)
        assert any(r['source']=='"unwrapped regression"' for r in injected),'negative control escaped the real lint predicate'
        print('i18n lint negative control: rejected Text("unwrapped regression")')
print(f'i18n lint: {len(bad)} new literal nodes in the converted declarations')
sys.exit(bool(bad))
