#!/usr/bin/env python3
"""Import the fixed release identity into an isolated Actions keychain."""
import base64
import hashlib
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import tempfile


def run(*args):
    result = subprocess.run([str(arg) for arg in args],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f'security {args[1]} failed ({result.returncode})')


def main():
    certificate = os.environ['MACOS_SIGNING_P12']
    password = os.environ['MACOS_SIGNING_PASSWORD']
    if not certificate or not password:
        raise SystemExit('Release signing secrets are required for master builds.')
    root = Path(tempfile.mkdtemp(prefix='flameshoter-signing-', dir=os.environ['RUNNER_TEMP']))
    archive = root / 'release.p12'
    keychain = root / 'release.keychain-db'
    archive.write_bytes(base64.b64decode(certificate, validate=True))
    archive.chmod(0o600)
    keychain_password = secrets.token_urlsafe(32)
    try:
        run('/usr/bin/security', 'create-keychain', '-p', keychain_password, keychain)
        run('/usr/bin/security', 'set-keychain-settings', '-lut', '21600', keychain)
        run('/usr/bin/security', 'unlock-keychain', '-p', keychain_password, keychain)
        run('/usr/bin/security', 'import', archive, '-k', keychain, '-P', password,
            '-x', '-T', '/usr/bin/codesign')
        run('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
            '-s', '-k', keychain_password, keychain)
    finally:
        archive.unlink()
    source = Path(__file__).resolve().parents[1]
    public = ssl.PEM_cert_to_DER_cert((source / 'packaging/macos/release-signing.pem').read_text())
    identity = hashlib.sha1(public).hexdigest().upper()
    with Path(os.environ['GITHUB_ENV']).open('a') as env:
        env.write(f'MACOS_SIGN_IDENTITY={identity}\nMACOS_SIGN_KEYCHAIN={keychain}\n')
    print(f'Imported release identity: {identity}')


if __name__ == '__main__':
    main()
