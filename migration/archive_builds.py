#!/usr/bin/env python3
"""Archive inactive host build directories with file-by-file round-trip checks."""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import tarfile
import tempfile
from pathlib import Path

from archive_packages import ROOT, WORKSPACE, STATE, HfApi, digest, write_json


def tree_manifest(folder):
    result = {}
    for base, directories, files in os.walk(folder, followlinks=False):
        for name in sorted(directories + files):
            path = Path(base) / name
            relative = str(path.relative_to(folder))
            if path.is_symlink():
                result[relative] = {'type': 'symlink', 'target': os.readlink(path)}
            elif path.is_file():
                result[relative] = {'type': 'file', 'bytes': path.stat().st_size, 'sha256': digest(path)}
            elif path.is_dir():
                result[relative] = {'type': 'directory'}
            else:
                raise RuntimeError('Unsupported build entry: ' + relative)
    return result


def verify_archive(archive_path, expected):
    found = {}
    with tarfile.open(archive_path, 'r:gz') as archive:
        for member in archive:
            if member.name == '.':
                continue
            name = member.name.removeprefix('./')
            if name.startswith('/') or '..' in Path(name).parts or name in found:
                raise RuntimeError('Invalid archive member: ' + name)
            if member.isfile():
                stream = archive.extractfile(member)
                value = hashlib.sha256()
                for block in iter(lambda: stream.read(4 * 1024**2), b''):
                    value.update(block)
                found[name] = {'type': 'file', 'bytes': member.size, 'sha256': value.hexdigest()}
            elif member.issym():
                found[name] = {'type': 'symlink', 'target': member.linkname}
            elif member.isdir():
                found[name] = {'type': 'directory'}
            else:
                raise RuntimeError('Unsupported archive member: ' + name)
    if found != expected:
        raise RuntimeError('Downloaded archive differs from the source tree manifest.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, default=ROOT / 'migration/build-transfer-plan.json')
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    bucket = plan['bucket']
    api = HfApi()
    if not api.bucket_info(bucket).private:
        raise RuntimeError('Refusing a public archive destination.')
    catalog_path = ROOT / 'migration/build-artifact-catalog.json'
    catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {'schemaVersion': 1, 'bucket': bucket, 'directories': {}}
    allowed = {WORKSPACE / 'openweights/ios/Product/.build', ROOT / 'ios/Product/.build'}
    for item in plan['directories']:
        relative = item['localRelativePath']
        local = WORKSPACE / relative
        if local.parent not in allowed or local.is_symlink():
            raise RuntimeError('Build plan contains a path outside the allowed host-build directory.')
        if not local.exists():
            if catalog['directories'].get(relative, {}).get('status') == 'archived-local-directory-removed':
                print('Already archived: ' + relative, flush=True)
                continue
            raise RuntimeError('Missing uncatalogued build directory: ' + relative)
        print('Fingerprinting and compressing: ' + relative, flush=True)
        manifest = tree_manifest(local)
        logical_bytes = sum(value.get('bytes', 0) for value in manifest.values())
        if logical_bytes != item['logicalBytes']:
            raise RuntimeError('Build contents changed since planning: ' + relative)
        with tempfile.TemporaryDirectory(prefix='build-', dir=STATE) as temporary:
            archive_path = Path(temporary) / (local.name + '.tar.gz')
            with tarfile.open(archive_path, 'w:gz', compresslevel=1, dereference=False) as archive:
                # Add regular hard-linked files independently so every file has a digest.
                for name in ['.'] + sorted(manifest):
                    path = local if name == '.' else local / name
                    info = archive.gettarinfo(str(path), arcname=name)
                    if info.islnk():
                        info.type = tarfile.REGTYPE
                        info.linkname = ''
                        info.size = path.stat().st_size
                    if info.isfile():
                        with path.open('rb') as stream:
                            archive.addfile(info, stream)
                    else:
                        archive.addfile(info)
            sha = digest(archive_path)
            verify_archive(archive_path, manifest)
            remote = 'builds/' + sha + '/' + archive_path.name
            print('Uploading compressed build: ' + local.name + ' (' + str(archive_path.stat().st_size) + ' bytes)', flush=True)
            api.batch_bucket_files(bucket, add=[(archive_path, remote)])
            fetched = Path(temporary) / 'downloaded.tar.gz'
            api.download_bucket_files(bucket, [(remote, fetched)], raise_on_missing_files=True)
            if digest(fetched) != sha:
                raise RuntimeError('Downloaded build archive SHA-256 mismatch.')
            verify_archive(fetched, manifest)
            if tree_manifest(local) != manifest:
                raise RuntimeError('Build changed during transfer. Local directory retained.')
            entry = {'localRelativePath': relative, 'logicalBytes': logical_bytes,
                     'archiveBytes': archive_path.stat().st_size, 'sha256': sha, 'remotePath': remote,
                     'remoteURI': 'hf://buckets/' + bucket + '/' + remote, 'fileManifest': manifest,
                     'verifiedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     'downloadedSHA256Matches': True, 'downloadedTreeManifestMatches': True,
                     'status': 'remote-round-trip-verified-local-directory-present'}
            receipt = Path(temporary) / 'manifest.json'
            write_json(receipt, entry)
            api.batch_bucket_files(bucket, add=[(receipt, remote + '.manifest.json')])
            catalog['directories'][relative] = entry
            write_json(catalog_path, catalog)
            write_json(local.with_name(local.name + '.remote.json'), entry)
            shutil.rmtree(local)
            entry['status'] = 'archived-local-directory-removed'
            write_json(catalog_path, catalog)
            write_json(local.with_name(local.name + '.remote.json'), entry)
        print('Archived, verified and removed host build: ' + relative, flush=True)


if __name__ == '__main__':
    main()
