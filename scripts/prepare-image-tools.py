#!/usr/bin/env python3
"""Fetch the pinned upstream arm64 OxiPNG release for tests and packaging."""
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

VERSION = '10.2.1'
SHA256 = '7039fcfc78e8aa1ed2b57d848057a0296f082e92b3e1807ac65402d10d926764'
URL = f'https://github.com/oxipng/oxipng/releases/download/v{VERSION}/oxipng-{VERSION}-aarch64-apple-darwin.tar.gz'


def prepare():
    cache = Path(subprocess.check_output(['getconf', 'DARWIN_USER_CACHE_DIR'], text=True).strip())
    root = cache / 'flameshoter-image-tools' / f'oxipng-{VERSION}-arm64'
    binary = root / 'oxipng'
    if not binary.exists():
        root.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root.parent) as directory:
            stage = Path(directory)
            archive = stage / 'oxipng.tar.gz'
            subprocess.run(['curl', '--http1.1', '-fsSL', '--retry', '2', '--retry-all-errors', '--connect-timeout', '15',
                            '--max-time', '90', URL, '-o', str(archive)], check=True)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
                raise RuntimeError('OxiPNG release checksum mismatch')
            files = stage / 'files'
            files.mkdir()
            with tarfile.open(fileobj=io.BytesIO(archive.read_bytes())) as package:
                for name in ['oxipng', 'LICENSE']:
                    member = next(item for item in package.getmembers()
                                  if item.isfile() and Path(item.name).name == name)
                    (files / name).write_bytes(package.extractfile(member).read())
            (files / 'oxipng').chmod(0o755)
            shutil.move(str(files), str(root))
    return binary


if __name__ == '__main__':
    print(prepare())
