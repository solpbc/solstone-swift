#!/usr/bin/env python3
"""Keep existing English accessibility assertions bound to their catalog calls."""
import json,re,sys
from pathlib import Path
root=Path(__file__).resolve().parent.parent
source=(root/sys.argv[1]).read_text();expected=sys.argv[2]
if expected in source:raise SystemExit(0)
xc=json.loads((root/'Localization/Localizable.xcstrings').read_text())
for key,entry in xc['strings'].items():
 if not re.fullmatch('m[0-9a-f]+',key):continue
 value=entry['localizations'].get('en-US',{}).get('stringUnit',{}).get('value')
 if value==expected:
  name=bytes.fromhex(key[1:]).decode().replace('.','_')
  if re.search(r'AppStrings\.'+re.escape(name)+r'\(',source):raise SystemExit(0)
raise SystemExit('Missing accessibility metadata: '+sys.argv[1]+': '+expected)
