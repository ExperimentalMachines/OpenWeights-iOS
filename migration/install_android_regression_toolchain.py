#!/usr/bin/env python3
"""Install only the explicitly approved Android regression prerequisites."""
import datetime
import hashlib
import json
import os
import subprocess
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
PREFLIGHT = ROOT / 'migration/android-toolchain-license-preflight-2026-10-07.json'
STATE = WORKSPACE / '.benchmark-work/Android'


def digest(path, algorithm='sha256'):
    value = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024**2), b''):
            value.update(block)
    return value.hexdigest()


def main():
    approved = json.loads(PREFLIGHT.read_text())
    if approved.get('authorization', {}).get('answer') != 'Approve license and installation':
        raise SystemExit('Explicit license and installation approval is absent.')
    sdk = Path(approved['sdkRoot'])
    if sdk != STATE / 'sdk':
        raise SystemExit('SDK root differs from the approved workspace location.')
    STATE.mkdir(parents=True, exist_ok=True)
    metadata = STATE / 'repository2-3.xml'
    if not metadata.exists():
        urllib.request.urlretrieve('https://dl.google.com/android/repository/repository2-3.xml', metadata)
    if digest(metadata) != approved['repositoryMetadataSHA256']:
        raise SystemExit('Official metadata changed. Recheck the approved package set.')
    tree = ET.parse(metadata)
    license_text = next(node.text for node in tree.getroot().iter()
                        if node.tag.rsplit('}', 1)[-1] == 'license' and node.attrib.get('id') == 'android-sdk-license')
    if hashlib.sha256(license_text.encode()).hexdigest() != approved['licenseTextSHA256']:
        raise SystemExit('License text differs from the approved preflight.')
    cli = approved['packages'][0]
    archive = STATE / Path(cli['url']).name
    if not archive.exists():
        print('Downloading approved command-line tools.', flush=True)
        urllib.request.urlretrieve(cli['url'], archive)
    if archive.stat().st_size != cli['bytes'] or digest(archive, cli['officialChecksumType']) != cli['officialChecksum']:
        raise SystemExit('Command-line tools fail the official size/checksum check.')
    manager = sdk / 'cmdline-tools/latest/bin/sdkmanager'
    if not manager.exists():
        with zipfile.ZipFile(archive) as zipped:
            if zipped.testzip() is not None:
                raise SystemExit('Command-line tools ZIP CRC check failed.')
            target = sdk / 'cmdline-tools/latest'
            target.mkdir(parents=True, exist_ok=True)
            for info in zipped.infolist():
                parts = Path(info.filename).parts
                if not parts or parts[0] != 'cmdline-tools' or '..' in parts:
                    raise SystemExit('Unexpected archive path: ' + info.filename)
                relative = Path(*parts[1:])
                output = target / relative
                if info.is_dir():
                    output.mkdir(parents=True, exist_ok=True)
                else:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(zipped.read(info))
                    mode = (info.external_attr >> 16) & 0o777
                    if mode:
                        output.chmod(mode)
    # SDK Manager records acceptance as the hash of the approved license text.
    # No other license is accepted and stdin remains closed during installation.
    accepted_hash = hashlib.sha1(license_text.strip().encode()).hexdigest()
    licenses = sdk / 'licenses'
    licenses.mkdir(parents=True, exist_ok=True)
    license_file = licenses / 'android-sdk-license'
    previous = license_file.read_text().splitlines() if license_file.exists() else []
    if accepted_hash not in previous:
        license_file.write_text('\n'.join(previous + [accepted_hash]) + '\n')
    jdk = WORKSPACE / 'openweights/ios/Benchmark/.build/android-toolchain/jdk21/jdk-21.0.12.1+1/Contents/Home'
    if not (jdk / 'bin/java').is_file():
        raise SystemExit('Previously verified JDK 21 is missing.')
    env = dict(os.environ, JAVA_HOME=str(jdk), ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    command = [str(manager), '--sdk_root=' + str(sdk), '--install'] + [p['path'] for p in approved['packages'][1:]]
    log = STATE / 'sdk-install-2026-10-07.log'
    print('Accepted the approved Android SDK license. Installing the four named packages.', flush=True)
    with log.open('w') as stream:
        result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
    expected = ['cmdline-tools/latest', 'platforms/android-37.0', 'build-tools/37.0.0', 'ndk/29.0.14206865', 'cmake/4.1.2']
    installed = {}
    for relative in expected:
        properties = sdk / relative / 'source.properties'
        if properties.exists():
            installed[relative] = {'sourceProperties': properties.read_text(), 'sourcePropertiesSHA256': digest(properties)}
    proof = {'schemaVersion': 1, 'status': 'approved-packages-installed' if result.returncode == 0 and len(installed) == len(expected) else 'installation-failed-or-incomplete',
             'preflightSHA256': digest(PREFLIGHT), 'authorization': approved['authorization'],
             'completedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'sdkRoot': str(sdk), 'command': command, 'exitCode': result.returncode,
             'acceptedLicenseID': 'android-sdk-license', 'acceptedLicenseSHA1': accepted_hash,
             'bootstrapArchiveSHA256': digest(archive), 'bootstrapOfficialSHA1Verified': True,
             'installed': installed, 'logSHA256': digest(log),
             'limits': ['SDK Manager retrieves and validates the four package archives. Those temporary downloads are not retained.',
                        'Installation alone does not establish that Android regressions pass.']}
    destination = ROOT / 'migration/android-toolchain-installation-2026-10-07.json'
    destination.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    approved.update(licenseAccepted=True, installationHasOccurred=True, status=proof['status'])
    PREFLIGHT.write_text(json.dumps(approved, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'status': proof['status'], 'exitCode': result.returncode, 'installed': list(installed), 'proof': str(destination)}), flush=True)
    raise SystemExit(result.returncode if result.returncode else (0 if len(installed) == len(expected) else 1))


if __name__ == '__main__':
    main()
