"""Generate independent gzip wire fixtures, with no Swift encoder involved."""
import gzip
import hashlib
import json
import random
import zlib
from pathlib import Path

folder = Path(__file__).resolve().parents[1] / 'OpenWeightsCoreTests/Fixtures'
inputs = {'unicode': b'\xef\xbb\xbf' + '旅行 🌿 Cedar 730'.encode(),
          'exact-limit': b'A' * 512, 'over-limit': b'A' * 513,
          'bomb': b'A' * (8 * 1024 * 1024), 'first-member': b'Cedar ', 'second-member': b'730'}
fixtures = {}
for name, data in inputs.items():
    wire = gzip.compress(data, mtime=0)
    fixtures[name] = {'gzipHex': wire.hex(), 'encodedBytes': len(wire),
                      'encodedSHA256': hashlib.sha256(wire).hexdigest(), 'decodedBytes': len(data),
                      'decodedSHA256': hashlib.sha256(data).hexdigest()}
fixtures['unicode']['expectedText'] = '旅行 🌿 Cedar 730'
randomizer = random.Random(730)
large = bytes(randomizer.randrange(32, 127) for _ in range(900_000))
wire = gzip.compress(large, mtime=0)
name = 'gzip-large-wire.gz'
(folder / name).write_bytes(wire)
fixtures['large-wire'] = {'file': name, 'encodedBytes': len(wire), 'encodedSHA256': hashlib.sha256(wire).hexdigest(),
                          'decodedBytes': len(large), 'decodedSHA256': hashlib.sha256(large).hexdigest(),
                          'decodedPrefixSHA256': hashlib.sha256(large[:512 * 1024]).hexdigest()}
reference = {'generator': 'Python gzip.compress, mtime=0; large-wire PRNG seed=730',
             'pythonZlibRuntime': zlib.ZLIB_RUNTIME_VERSION, 'fixtures': fixtures}
(folder / 'gzip-reference.json').write_text(json.dumps(reference, indent=2, sort_keys=True) + '\n')
