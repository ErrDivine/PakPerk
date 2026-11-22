"""Download only the pinned public files and verify their recorded hashes."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
manifest_path = Path(__file__).with_name('dataset_manifest.json')
manifest = json.loads(manifest_path.read_text())
args.output.mkdir(parents=True, exist_ok=True)
for name, record in manifest['files'].items():
    target = args.output / name
    body = target.read_bytes() if target.exists() else urllib.request.urlopen(record['url'], timeout=60).read()
    if hashlib.sha256(body).hexdigest() != record['sha256']:
        raise RuntimeError(f'Checksum mismatch: {name}')
    if len(body) != record['bytes']:
        raise RuntimeError(f'Length mismatch: {name}')
    target.write_bytes(body)
    print(f'{name}: verified')
(args.output/'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
