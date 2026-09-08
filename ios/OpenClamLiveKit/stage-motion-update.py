#!/usr/bin/env python3
"""Stage a private, exact-model motion library in the signed iOS resources."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--model', type=pathlib.Path, required=True)
p.add_argument('--motions', type=pathlib.Path, required=True)
p.add_argument('--destination', type=pathlib.Path, default=pathlib.Path(__file__).parent / 'App/Avatar3D/MotionUpdates.bundle')
a = p.parse_args()
def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
library = json.loads((a.motions / 'library.json').read_text())
assert library['version'] == 1 and 0 < len(library['clips']) <= 96
assert len({c['id'] for c in library['clips']}) == len(library['clips'])
names = ['library.json']
for clip in library['clips']:
    assert re.fullmatch(r'[a-z0-9_-]{1,40}', clip['id'])
    assert clip['file'] == clip['id'] + '.json'
    names.append(clip['file'])
files = {}
for name in names:
    path = a.motions / name
    assert not path.is_symlink() and 0 < path.stat().st_size <= 32 * 1024 * 1024
    files[name] = dict(sha256=digest(path), byteCount=path.stat().st_size)
assert sum(f['byteCount'] for f in files.values()) <= 512 * 1024 * 1024
a.destination.mkdir(parents=True, exist_ok=True)
for stale in a.destination.glob('*.json'):
    stale.unlink()
for name in names:
    shutil.copyfile(a.motions / name, a.destination / name)
(a.destination / 'index.local.json').write_text(json.dumps(dict(modelSHA256=digest(a.model), files=files), indent=2) + '\n')
print(f'Staged {len(library["clips"])} motions, {sum(f["byteCount"] for f in files.values()) / 1048576:.1f} MiB')
