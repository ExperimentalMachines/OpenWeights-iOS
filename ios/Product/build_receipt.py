#!/usr/bin/env python3
"""Fingerprint the current native product build and its shared-engine dependency."""
import hashlib
import json
import plistlib
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent
repo = root.parents[1]
def source_files():
    files = [p for folder in ['App', 'Native', 'Sources', 'ScriptExtension', 'InferenceExtension', 'InferenceFramework', 'DeviceTests', 'Tests', 'Resources']
             for p in (root / folder).rglob('*') if p.is_file()]
    files += [root / p for p in ['Package.swift', 'Package.resolved', 'App-Package.resolved', 'project.yml', 'build.sh', 'run.sh', 'build_receipt.py', 'prepare_inference_dependencies.py']]
    files += list((repo / 'core/engine/src/main/cpp').glob('engine_session.*'))
    files += [repo / name for name in ['core/engine/src/main/cpp/PatchGGMLGraphOffset.cmake',
                                     'core/engine/src/main/cpp/llama.cpp/ggml/src/ggml.c',
                                     'ios/Benchmark/Native/CMakeLists.txt']]
    quickjs = repo / 'core/sandbox/src/main/cpp/quickjs'
    files += sorted(quickjs.glob('*.h')) + [quickjs / name for name in ['quickjs.c', 'dtoa.c', 'libregexp.c', 'libunicode.c', 'LICENSE']]
    return files


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def source_hashes():
    return {str(p.relative_to(repo)): digest(p) for p in sorted(source_files())}


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['capture', 'stamp'], nargs='?', default='stamp')
    parser.add_argument('--expected', type=Path)
    parser.add_argument('--derived-data', type=Path, default=root / '.build/DerivedData')
    args = parser.parse_args()
    sources = source_hashes()
    before = root / '.build/product-source-inputs-before.json'
    if args.action == 'capture':
        before.write_text(json.dumps(sources, indent=2, sort_keys=True) + '\n')
        return
    if args.expected and json.loads(args.expected.read_text()) != sources:
        raise SystemExit('Product sources changed during compilation. Rebuild before stamping a receipt.')
    xcode = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
    build = xcode.splitlines()[1].split()[-1]
    native = root.parent / f'Benchmark/.build/native-{build}-ninja/libopenweights_apple.a'
    products_root = args.derived_data.resolve() / 'Build/Products'
    products = products_root / 'Release-iphoneos/OpenWeights.app'
    info = plistlib.loads((products / 'Info.plist').read_bytes())
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(products)], check=True)
    signature = subprocess.run(['codesign', '-dv', str(products)], capture_output=True, text=True, check=True).stderr
    if 'Signature=adhoc' in signature:
        raise SystemExit('An ad-hoc build cannot stamp a signed iPhone product receipt.')
    receipt = {'bundleIdentifier': info['CFBundleIdentifier'], 'status': 'release-build-verified-device-product-flows-pending', 'xcode': xcode,
               'sdk': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
               'sources': sources,
               'nativeArchiveSHA256': digest(native), 'executables': {
                   name: digest(products / name) for name in ['OpenWeights', 'PlugIns/ProductTests.xctest/ProductTests']}}
    app_strings = subprocess.check_output(['strings', str(products / 'OpenWeights')], text=True)
    receipt['backgroundDownloadValidationBuild'] = 'OWBackgroundDownloadValidationMarker-v1' in app_strings
    receipt['scriptArchiveSHA256'] = digest(root / '.build/script-ios/libopenweights_script.a')
    helper = products / 'Extensions/ScriptSandbox.appex'
    receipt['executables']['Extensions/ScriptSandbox.appex/ScriptSandbox'] = digest(helper / 'ScriptSandbox')
    receipt['scriptExtensionInfo'] = plistlib.loads((helper / 'Info.plist').read_bytes())
    inference = products / 'Extensions/InferenceHelper.appex'
    receipt['executables']['Extensions/InferenceHelper.appex/InferenceHelper'] = digest(inference / 'InferenceHelper')
    receipt['inferenceExtensionInfo'] = plistlib.loads((inference / 'Info.plist').read_bytes())
    entitlements = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(inference)])
    receipt['inferenceExtensionEntitlements'] = plistlib.loads(entitlements)
    receipt['inferenceIncreasedMemoryLimitBuild'] = receipt['inferenceExtensionEntitlements'].get('com.apple.developer.kernel.increased-memory-limit', False)
    receipt['inferenceDependencies'] = json.loads((root / 'InferenceExtension/dependencies.json').read_text())
    framework = products / 'Frameworks/OWInferenceProbe.framework/OWInferenceProbe'
    receipt['executables']['Frameworks/OWInferenceProbe.framework/OWInferenceProbe'] = digest(framework)
    exports = subprocess.check_output(['nm', '-gU', str(framework)], text=True)
    public = sorted(line.split()[-1] for line in exports.splitlines() if line.strip())
    expected_exports = sorted((root / 'InferenceFramework/exports.txt').read_text().split())
    if public != expected_exports:
        raise SystemExit('Inference framework exposes symbols outside its C probe interface.')
    symbols = subprocess.check_output(['nm', '-m', str(framework)], text=True)
    if ' _OBJC_CLASS_$_ExecuTorch' in symbols or any('(undefined)' in line and ('executorch' in line or 'mlx' in line) for line in symbols.splitlines()):
        raise SystemExit('Inference framework has colliding Objective-C classes or unresolved ET/MLX symbols.')
    receipt['inferenceFrameworkExports'] = public
    receipt['inferenceFrameworkMetalLibrarySHA256'] = digest(products / 'executorch_backend_mlx_resources.bundle/mlx-ios.metallib')
    if receipt['inferenceFrameworkMetalLibrarySHA256'] != receipt['inferenceDependencies']['metalLibrarySHA256']:
        raise SystemExit('Host inference Metal library differs from its pinned device slice.')
    for name, entry in receipt['inferenceDependencies']['libraries'].items():
        for relative, expected in entry['files'].items():
            if digest(root / '.build/inference-deps' / name / relative) != expected:
                raise SystemExit('Staged inference dependency changed: ' + name + '/' + relative)
            if name == 'executorch' and relative.startswith('Headers/') and not relative.endswith('.modulemap'):
                header = root / '.build/inference-deps/core-headers' / Path(relative).relative_to('Headers')
                if digest(header) != expected:
                    raise SystemExit('Inference C++ header differs from its pinned device slice.')
    metal = inference / 'executorch_backend_mlx_resources.bundle/mlx-ios.metallib'
    receipt['inferenceMetalLibrarySHA256'] = digest(metal)
    if receipt['inferenceMetalLibrarySHA256'] != receipt['inferenceDependencies']['metalLibrarySHA256']:
        raise SystemExit('Embedded inference Metal library differs from its pin.')
    helper_strings = subprocess.check_output(['strings', str(helper / 'ScriptSandbox')], text=True).splitlines()
    validation_actions = [name for name in ['validateAccess', 'terminateForValidation'] if name in helper_strings]
    if len(validation_actions) == 1:
        raise SystemExit('Incomplete script validation wire-action build. Rebuild before device validation.')
    receipt['scriptSecurityValidationBuild'] = len(validation_actions) == 2
    receipt['scriptValidationWireActionsInHelper'] = validation_actions
    receipt['quickjsRevision'] = subprocess.check_output(['git', '-C', str(repo / 'core/sandbox/src/main/cpp/quickjs'), 'rev-parse', 'HEAD'], text=True).strip()
    (products_root / 'openweights-product-build.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print('Product executable/source receipt saved.')


if __name__ == '__main__':
    main()
