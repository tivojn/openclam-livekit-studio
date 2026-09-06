#!/usr/bin/env python3
"""Stage a private, offline model update for the next signed iOS build.

Run before xcodegen/build. The source repository retains an empty update index;
the staged archive and local index are ignored by git.
"""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import zipfile


def manifest(path):
    with zipfile.ZipFile(path) as archive:
        value = json.loads(archive.read("manifest.json"))
    assert value["variant"] == "ios-3d" and value["version"] == 5
    assert re.fullmatch(r"[a-z0-9][a-z0-9-]*", value["id"])
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=pathlib.Path, required=True)
    parser.add_argument("--previous", type=pathlib.Path, action="append", required=True)
    parser.add_argument("--destination", type=pathlib.Path, default=pathlib.Path(__file__).parent /
                        "App/AvatarCatalog/Resources/AvatarUpdates.bundle")
    args = parser.parse_args()
    target = manifest(args.package)
    sources = [manifest(path) for path in args.previous]
    assert all(source["id"] == target["id"] for source in sources), "Avatar identities must match"
    model = target["model"]
    with zipfile.ZipFile(args.package) as archive:
        with archive.open(model["path"]) as stream:
            assert hashlib.file_digest(stream, "sha256").hexdigest() == model["sha256"]
    with args.package.open("rb") as stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    entry = dict(id=target["id"], file=target["id"] + ".avtr", packageSHA256=checksum,
                 sourceModelSHA256=sorted({source["model"]["sha256"] for source in sources}),
                 targetModelSHA256=model["sha256"])
    args.destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.package, args.destination / entry["file"])
    (args.destination / "updates.local.json").write_text(json.dumps([entry], indent=2) + "\n")
    print(f"Staged {target['id']}: {len(entry['sourceModelSHA256'])} earlier model versions -> {model['sha256']}")


if __name__ == "__main__":
    main()
