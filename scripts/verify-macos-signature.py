#!/usr/bin/env python3
"""Verify the release certificate and, optionally, identity across an upgrade."""
import argparse
import hashlib
from pathlib import Path
import re
import ssl
import subprocess
import tempfile


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True,
                          capture_output=True, text=True)


def inspect(app, certificate):
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    with tempfile.TemporaryDirectory(prefix='flameshoter-signature-') as temp:
        prefix = Path(temp) / 'certificate'
        run('/usr/bin/codesign', '--display', '--extract-certificates=' + str(prefix), app)
        if Path(str(prefix) + '0').read_bytes() != certificate:
            raise RuntimeError(f'{app}: unexpected release signing certificate')
    output = run('/usr/bin/codesign', '--display', '--verbose=4', '--requirements', '-', app)
    text = output.stdout + output.stderr
    requirement = re.search(r'^designated => (.+)$', text, re.MULTILINE).group(1)
    cdhash = re.search(r'^CDHash=(.+)$', text, re.MULTILINE).group(1)
    expected = ('identifier "io.github.Word2VecT.flameshoter" and certificate root = H"'
                + hashlib.sha1(certificate).hexdigest() + '"')
    if requirement != expected:
        raise RuntimeError(f'{app}: unexpected designated requirement: {requirement}')
    return requirement, cdhash


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--previous', type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    certificate = ssl.PEM_cert_to_DER_cert(
        (source / 'packaging/macos/release-signing.pem').read_text())
    requirement, cdhash = inspect(args.app, certificate)
    print(f'CDHash: {cdhash}\nDesignated requirement: {requirement}')
    if args.previous:
        previous_requirement, previous_cdhash = inspect(args.previous, certificate)
        if previous_cdhash == cdhash:
            raise RuntimeError('Upgrade verification requires two different code signatures')
        run('/usr/bin/codesign', '--verify', '-R=' + previous_requirement, args.app)
        run('/usr/bin/codesign', '--verify', '-R=' + requirement, args.previous)
        print(f'Previous CDHash: {previous_cdhash}\nBoth builds satisfy each other\'s identity requirement')
    print('Release signature verified')


if __name__ == '__main__':
    main()
