# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import json, math, re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
messages = json.loads((root/'test/i18n-pilot/messages.json').read_text())
assert len({m['id'] for m in messages}) == len(messages), 'duplicate message identity'
assert len({m['symbol'] for m in messages}) == len(messages), 'duplicate generated symbol'
accent = str.maketrans('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ','àƀçďéƒğħíĵķľɱñóƥɋřšţúṽŵẋýžÀƁÇĎÉƑĞĦÍĴĶĽṀÑÓƤɊŘŠŢÚṼŴẊÝŽ')
def pseudo(s):
    parts = re.split(r'(%\d+\$lld)',s)
    return '['+''.join(p if p.startswith('%') else p.translate(accent) for p in parts)+'~'*math.ceil(len(s)*.35)+']'
def unit(s): return {'stringUnit':{'state':'translated','value':s}}
strings = {}
swift = ['// SPDX-License-Identifier: AGPL-3.0-only','// Copyright (c) 2026 sol pbc','','import Foundation','', 'nonisolated struct SourceSyncMessage: Sendable {',
    '    let id: String', '    let arguments: [String: Int]', '    let resource: LocalizedStringResource',
    '    let legacyEnglish: String',
    '    var rendered: String {',
    '        guard resource.locale.identifier == "en_US" else { return String(localized: resource) }',
    '        let template = Bundle.main.localizedString(forKey: id, value: legacyEnglish, table: "Pilot")',
    '        return String(format: template, locale: Locale(identifier: "en_US_POSIX"), arguments.values.first ?? 0)',
    '    }', '}', '', 'nonisolated enum PilotCopy {']
for m in messages:
    localizations={}
    for loc in ['en','en-XA']:
        if 'plural' in m:
            localizations[loc]={'variations':{'plural':{k:unit(v if loc=='en' else pseudo(v)) for k,v in m['plural'].items()}}}
        else: localizations[loc]=unit(m['english'] if loc=='en' else pseudo(m['english']))
    strings[m['id']]={'comment':m['description'],'extractionState':'manual','localizations':localizations}
    q=lambda s:json.dumps(s,ensure_ascii=False)
    if m['args']:
        assert len(m['args']) == 1, 'pilot lowering supports exactly one integer argument'
        assert list(m['args'].values()) == ['Int'], 'placeholder type must remain an integer'
        assert set(m['plural']) == {'one','other'}
        assert all(v.count('%1$lld') == 1 and '%' not in v.replace('%1$lld','') for v in m['plural'].values()), 'unsupported positional specifier'
        assert m['number_style'] == 'legacy ungrouped for en_US; native locale format elsewhere'
        arg=next(iter(m['args']))
        default=q(m['english']).replace('%1$lld','\\('+arg+')')
        singular=q(m['plural']['one']).replace('%1$lld','\\('+arg+')')
        swift += [f'    static func {m["symbol"]}(_ {arg}: Int) -> SourceSyncMessage {{',
            f'        SourceSyncMessage(id: {q(m["id"])}, arguments: [{q(arg)}: {arg}],',
            f'            resource: LocalizedStringResource({q(m["id"])}, defaultValue: {arg} == 1 ? {singular} : {default}, table: "Pilot"),',
            f'            legacyEnglish: {arg} == 1 ? {singular} : {default})','    }']
    else:
        swift += [f'    static var {m["symbol"]}: LocalizedStringResource {{',
            f'        LocalizedStringResource({q(m["id"])}, defaultValue: {q(m["english"])}, table: "Pilot")','    }']
swift += ['    static var allResources: [LocalizedStringResource] { [']
swift += ['        '+('Self.'+m['symbol']+'(2).resource' if m['args'] else 'Self.'+m['symbol'])+',' for m in messages]
swift += ['    ] }', '    static func resources(locale: Locale, bundle: LocalizedStringResource.BundleDescription) -> [LocalizedStringResource] {', '        [']
for m in messages:
    default=json.dumps(m['english'],ensure_ascii=False).replace('%1$lld','\\(2)')
    swift += [f'            LocalizedStringResource({json.dumps(m["id"])}, defaultValue: {default}, table: "Pilot", locale: locale, bundle: bundle),']
swift += ['        ]','    }','}']
(root/'Sources/PilotCopy.swift').write_text('\n'.join(swift)+'\n')
(root/'Localization').mkdir(exist_ok=True)
(root/'Localization/Pilot.xcstrings').write_text(json.dumps({'sourceLanguage':'en','strings':strings,'version':'1.0'},ensure_ascii=False,indent=2)+'\n')
snapshot=['// SPDX-License-Identifier: AGPL-3.0-only','// Copyright (c) 2026 sol pbc','','@testable import solstone_swift','import Foundation','','extension I18nPilotTests {','    static var vocabularySnapshot: [String: String] { [']
snapshot += ['        '+json.dumps(m['symbol'])+': String(localized: SourceVocabulary.'+m['symbol']+'),' for m in messages if 'origin' in m]
snapshot += ['    ] }','}']
(root/'Tests/I18nPilotSnapshot.swift').write_text('\n'.join(snapshot)+'\n')
print(f'generated {len(messages)} messages for en + en-XA')
