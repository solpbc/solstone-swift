# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import argparse,datetime,json,os,re,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[2]
ap=argparse.ArgumentParser();ap.add_argument('--language',default='en');ap.add_argument('--region',default='US');ap.add_argument('--gallery',action='store_true');ap.add_argument('--only-pilot',action='store_true');args=ap.parse_args()
start=time.monotonic();run=datetime.datetime.now().strftime('%Y%m%dT%H%M%S');out=root/f'build/i18n-pilot/{args.language}-{args.region}-{run}';out.mkdir(parents=True)
def call(command,**kw):return subprocess.run(command,cwd=root,check=True,**kw)
udid=call(['xcrun','simctl','create',f'i18n-pilot-{run}','com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro','com.apple.CoreSimulator.SimRuntime.iOS-26-5'],capture_output=True,text=True).stdout.strip()
receipt={'language':args.language,'region':args.region,'expected_locale':args.language+'_'+args.region,'simulator':udid,'start':datetime.datetime.now().isoformat()}
try:
    cmd=['xcodebuild','test','-project','solstone-swift.xcodeproj','-scheme','solstone-swift','-skipMacroValidation','-destination',f'platform=iOS Simulator,id={udid}','-derivedDataPath','DerivedData','-resultBundlePath',str(out/'result.xcresult'),'-testLanguage',args.language,'-testRegion',args.region,'-parallel-testing-enabled','NO']
    if args.gallery:cmd+=['-only-testing:solstone-swiftUITests/I18nPilotGalleryTests']
    else:
        tests=['I18nPilotTests','SourceVocabularyTests','ScreencastCopyTests','FinishSyncingCoordinatorTests','SourceStateMappingTests','HomeStatusPillStateTests','SendStateStyleTests','ImportRecentPresentationTests','MobileSegmentScreencastStopReasonTests','StatusPaneTests','DiagnosticsFiltersTests','TransferRefusalPacingTests']
        if args.only_pilot: tests=['I18nPilotTests']
        cmd+=['-only-testing:solstone-swiftTests/'+t for t in tests]
    receipt['command']=cmd
    with (out/'xcodebuild.log').open('w') as log:result=subprocess.run(cmd,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
    receipt['exit']=result.returncode
    summary=call(['xcrun','xcresulttool','get','test-results','summary','--path',str(out/'result.xcresult')],capture_output=True,text=True).stdout
    (out/'summary.json').write_text(summary);receipt['summary']=json.loads(summary)
    log=(out/'xcodebuild.log').read_text(errors='replace')
    receipt['canaries']=sorted(set(re.findall(r'I18N_CANARY locale=([^\s]+)',log)))
    receipt['bundles']=sorted(set(re.findall(r'I18N_BUNDLE ([^\n]+)',log)))
    if not args.gallery:
        expected=args.language+'_'+args.region
        receipt['locale_verified']=expected in receipt['canaries']
        if expected not in receipt['canaries']:raise RuntimeError(f'locale did not demonstrably take effect: expected {expected}, got {receipt["canaries"]}')
    if result.returncode:raise RuntimeError(f'xcodebuild failed: {out}')
finally:
    subprocess.run(['xcrun','simctl','shutdown',udid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    deletion=subprocess.run(['xcrun','simctl','delete',udid]);receipt['deleted']=deletion.returncode==0
    receipt['seconds']=round(time.monotonic()-start,3);(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    if not receipt['deleted']: raise RuntimeError(f'simulator deletion failed: {udid}')
print(json.dumps(receipt,indent=2))
