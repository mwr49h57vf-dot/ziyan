#!/usr/bin/env python3
"""Run this repair's local regressions. Never deploys or asserts device PASS."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lua', default=os.environ.get('LUA') or shutil.which('lua5.3') or shutil.which('lua'))
    parser.add_argument('--cc', default=os.environ.get('CC') or shutil.which('gcc') or shutil.which('clang'))
    args=parser.parse_args()
    if not args.lua or not args.cc:
        parser.error('Provide an existing Lua 5.3 runtime with --lua and a C compiler with --cc')
    out=ROOT/'tmp_shots/repair-20260912'
    out.mkdir(parents=True,exist_ok=True)
    (out/'memory/memory').mkdir(parents=True,exist_ok=True)
    env=dict(os.environ, ZIYAN_REPAIR_LUA=str(Path(args.lua).resolve()), ZIYAN_TEST_LUA=str(Path(args.lua).resolve()), ZIYAN_SCRIPTGEN_LUA=str(Path(args.lua).resolve()), PYTHONDONTWRITEBYTECODE='1', PYTHONUTF8='1')
    records=[]
    def run(command):
        result=subprocess.run([str(v) for v in command],cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf8',errors='replace',timeout=120)
        records.append({'command':[str(v) for v in command],'exit_code':result.returncode,'output':result.stdout+result.stderr})
        print(('PASS ' if result.returncode==0 else 'FAIL ')+' '.join(str(v) for v in command),flush=True)
        if result.returncode: print((result.stdout+result.stderr)[-4000:],flush=True)
        return result.returncode==0
    suffix='.exe' if os.name=='nt' else ''
    for source in ['ocr_geometry','script_dependency_cli']:
        target=out/(source+suffix)
        if run([args.cc,'-Wall','-Wextra','-Werror',ROOT/'tests/repair_20260912'/f'{source}.c','-o',target]) and source=='ocr_geometry':
            run([target])
    for source in ['thread_wait','ai_result','memory_migration','offline_queue']:
        run([args.lua,ROOT/'tests/repair_20260912'/f'{source}.lua'])
    run([sys.executable,'-X','utf8','-m','unittest','discover','-s','tests/repair_20260912','-p','test_*.py','-v'])
    for name in ['test_ai_real_device_only_contract','test_capability_sequence_contract','test_test_matrix_module_contract','test_generated_capability_gate_contract']:
        run([sys.executable,'-X','utf8',ROOT/'tools'/f'{name}.py'])
    native='not_run: requires macOS Foundation and iOS device acceptance'
    if sys.platform=='darwin':
        target=out/'script_import'
        if run(['clang','-fobjc-arc','-framework','Foundation',ROOT/'tests/repair_20260912/script_import.m','-o',target]):
            native='local_foundation_pass' if run([target]) else 'local_foundation_fail'
    result={'scope':'local_regressions_only','device_verdict':'NOT_RUN','native_import':native,'results':records}
    (out/'local-results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
    return 1 if any(row['exit_code'] for row in records) else 0

if __name__=='__main__': raise SystemExit(main())
