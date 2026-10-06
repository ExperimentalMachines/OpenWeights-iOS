#!/usr/bin/env python3
"""Move selected benchmark packages to private HF storage after round-trip verification."""
import argparse
import datetime
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
STATE = ROOT / '.build/archive-transfers'
STATE.mkdir(parents=True, exist_ok=True)
os.environ.setdefault('HF_XET_CACHE', str(STATE / 'xet'))
os.environ.setdefault('HF_XET_CHUNK_CACHE_SIZE_BYTES', '0')
from huggingface_hub import HfApi


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024**2), b''):
            value.update(block)
    return value.hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def verify_package(path, expected):
    if digest(path) != expected:
        raise RuntimeError('Package SHA-256 mismatch: ' + path.name)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise RuntimeError('Package ZIP CRC verification failed: ' + path.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, default=ROOT / 'migration/artifact-transfer-plan.json')
    parser.add_argument('--restore', help='Restore a catalogued path relative to the workspace.')
    args = parser.parse_args()
    api = HfApi()
    plan = json.loads(args.plan.read_text())
    bucket = plan['bucket']
    if not api.bucket_info(bucket).private:
        raise RuntimeError('Refusing to archive into a public bucket.')
    catalog_path = ROOT / 'migration/artifact-catalog.json'
    catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {'schemaVersion': 1, 'bucket': bucket, 'files': {}}
    if catalog['bucket'] != bucket:
        raise RuntimeError('Plan and existing catalog use different buckets.')
    items = [{'localRelativePath': args.restore}] if args.restore else plan['files']
    for item in items:
        relative = item['localRelativePath']
        local = WORKSPACE / relative
        if not local.resolve().is_relative_to(WORKSPACE) or local.is_symlink() or local.suffix != '.zip':
            raise RuntimeError('Unsafe package path: ' + relative)
        old = catalog['files'].get(relative)
        if args.restore:
            if old is None:
                raise RuntimeError('Path is absent from the archive catalog.')
            if local.exists():
                verify_package(local, old['sha256'])
                print('Already restored: ' + relative, flush=True)
                continue
            local.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='restore-', dir=STATE) as folder:
                fetched = Path(folder) / local.name
                api.download_bucket_files(bucket, [(old['remotePath'], fetched)], raise_on_missing_files=True)
                verify_package(fetched, old['sha256'])
                fetched.replace(local)
            old.update(status='remote-verified-local-copy-restored', restoredAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
            write_json(catalog_path, catalog)
            write_json(local.with_suffix(local.suffix + '.remote.json'), old)
            print('Restored and verified: ' + relative, flush=True)
            continue
        if not local.exists():
            if old and old.get('status') == 'archived-local-copy-removed':
                print('Already archived: ' + relative, flush=True)
                continue
            raise RuntimeError('Uncatalogued missing local package: ' + relative)
        before = local.stat()
        if before.st_size != item['bytes']:
            raise RuntimeError('Package size changed after planning: ' + relative)
        sha = digest(local)
        if old and old['sha256'] != sha:
            raise RuntimeError('Catalogued package changed: ' + relative)
        remote = 'packages/' + sha + '/' + local.name
        entry = {'localRelativePath': relative, 'bytes': before.st_size, 'sha256': sha,
                 'remotePath': remote, 'remoteURI': 'hf://buckets/' + bucket + '/' + remote}
        print('Uploading: ' + relative, flush=True)
        existing = list(api.get_bucket_paths_info(bucket, [remote]))
        if existing and existing[0].size != before.st_size:
            raise RuntimeError('Remote content-addressed object has a different size.')
        if not existing:
            api.batch_bucket_files(bucket, add=[(local, remote)])
        print('Downloading for SHA-256 and ZIP CRC verification: ' + local.name, flush=True)
        with tempfile.TemporaryDirectory(prefix='verify-', dir=STATE) as folder:
            fetched = Path(folder) / local.name
            api.download_bucket_files(bucket, [(remote, fetched)], raise_on_missing_files=True)
            if fetched.stat().st_size != before.st_size:
                raise RuntimeError('Downloaded package size mismatch.')
            verify_package(fetched, sha)
        after = local.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or digest(local) != sha:
            raise RuntimeError('Local package changed during transfer. Local copy retained.')
        entry.update(status='remote-round-trip-verified-local-copy-present', verifiedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     downloadedSHA256Matches=True, downloadedZipCRCMatches=True)
        manifest_path = STATE / (sha + '.json')
        write_json(manifest_path, entry)
        api.batch_bucket_files(bucket, add=[(manifest_path, remote + '.manifest.json')])
        # Retain a locator before eviction, so every removed package is recoverable.
        catalog['files'][relative] = entry
        write_json(catalog_path, catalog)
        write_json(local.with_suffix(local.suffix + '.remote.json'), entry)
        local.unlink()
        entry['status'] = 'archived-local-copy-removed'
        write_json(catalog_path, catalog)
        write_json(local.with_suffix(local.suffix + '.remote.json'), entry)
        print('Archived, verified and removed local copy: ' + relative + ' (' + str(before.st_size) + ' bytes)', flush=True)


if __name__ == '__main__':
    main()
