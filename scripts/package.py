#!/usr/bin/env python3
"""Build the SpoonInstall archive from this checkout, without third-party packages."""

import argparse
import json
import os
from pathlib import Path
import stat
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
NAME = "AeroSpaceSwipe"
FILES = {
    "LICENSE": "LICENSE",
    "README.md": "README.md",
    "docs.json": "docs/docs.json",
    "init.lua": "init.lua",
}


def build_package(source_root, output):
    """Validate all inputs, then atomically replace output with a reproducible ZIP."""
    source_root, output = Path(source_root), Path(output)
    contents = {
        destination: (source_root / source).read_bytes()
        for destination, source in FILES.items()
    }
    docs = json.loads(contents["docs.json"])
    if (
        not isinstance(docs, list)
        or len(docs) != 1
        or not isinstance(docs[0], dict)
        or docs[0].get("name") != NAME
        or docs[0].get("type") != "Module"
        or not isinstance(docs[0].get("desc"), str)
        or not docs[0]["desc"].strip()
        or not isinstance(docs[0].get("items"), list)
    ):
        raise ValueError("docs/docs.json must describe exactly one AeroSpaceSwipe module")

    if output.resolve() in {(source_root / source).resolve() for source in FILES.values()}:
        raise ValueError("output must not overwrite a package source file")

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".spoon-", suffix=".zip", delete=False) as temp:
        temporary = Path(temp.name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as archive:
            # Stored entries avoid differences between compression-library versions.
            # SpoonInstall's unzip check requires an explicit *.spoon/ directory.
            entries = {f"{NAME}.spoon/": b""}
            entries.update({f"{NAME}.spoon/{name}": body for name, body in contents.items()})
            for name, body in sorted(entries.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                directory = name.endswith("/")
                mode = (stat.S_IFDIR | 0o755) if directory else (stat.S_IFREG | 0o644)
                info.external_attr = (mode << 16) | (0x10 if directory else 0)
                archive.writestr(info, body)
        temporary.chmod(0o644)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "Spoons" / f"{NAME}.spoon.zip",
        help="ZIP destination (default: Spoons/AeroSpaceSwipe.spoon.zip in this checkout)",
    )
    args = parser.parse_args()
    try:
        build_package(ROOT, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")
    print(f"Built {args.output}")


if __name__ == "__main__":
    main()
