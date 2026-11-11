#!/usr/bin/env python3
"""Validate a signed plugin APK and produce GitHub-installable release metadata."""
import argparse, hashlib, json, pathlib, re, subprocess

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, encoding='utf-8').stdout

def manifest_from_apk(dump):
    lines = dump.splitlines()
    for i, line in enumerate(lines):
        if not re.search(r'\bstring/plugin_manifest\s*$', line):
            continue
        for candidate in lines[i+1:]:
            if re.search(r'\bresource\s+0x', candidate): break
            match = re.match(r'^\s*\([^)]*\)\s+"(.*)"\s*$', candidate)
            if match:
                try: return json.loads(match.group(1))
                except json.JSONDecodeError: return json.loads(json.loads('"'+match.group(1)+'"'))
    raise ValueError('Compiled plugin manifest missing')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk',type=pathlib.Path)
    parser.add_argument('--apksigner',required=True)
    parser.add_argument('--aapt2',required=True)
    parser.add_argument('--output',required=True,type=pathlib.Path)
    args=parser.parse_args()
    root=pathlib.Path(__file__).resolve().parent.parent
    template=json.loads((root/'clipisle-plugin.template.json').read_text(encoding='utf-8-sig'))
    compiled=manifest_from_apk(run(args.aapt2,'dump','resources',str(args.apk)))
    if compiled != template: raise ValueError('Compiled plugin manifest differs from template')
    badging=run(args.aapt2,'dump','badging',str(args.apk))
    if f"name='{template['packageName']}'" not in badging or f"versionName='{template['version']}'" not in badging:
        raise ValueError('APK package/version mismatch')
    certificate=run(args.apksigner,'verify','--print-certs',str(args.apk))
    if 'CN=Android Debug' in certificate or 'Signer #2 certificate' in certificate:
        raise ValueError('One independent release signer required')
    match=re.search(r'Signer #1 certificate SHA-256 digest:\s*([a-fA-F0-9:]+)',certificate)
    if not match: raise ValueError('Certificate fingerprint missing')
    url=f"{template['source']}/releases/download/v{template['version']}/clipisle-netdisk-{template['version']}.apk"
    template['apk']={'url':url,'sha256':hashlib.sha256(args.apk.read_bytes()).hexdigest(),'certificateSha256':match.group(1).replace(':','').lower()}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(template,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f"Verified {template['id']} {template['version']}")

if __name__=='__main__': main()
