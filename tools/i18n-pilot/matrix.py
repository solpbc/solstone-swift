# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import subprocess,sys
results=[]
for language,region in [('en','US'),('tr','TR'),('de','DE'),('ar','SA')]:
    run=subprocess.run([sys.executable,'tools/i18n-pilot/run.py','--language',language,'--region',region,*sys.argv[1:]])
    results.append((language,region,run.returncode))
print('I18N_MATRIX',results)
sys.exit(any(code for _,_,code in results))
