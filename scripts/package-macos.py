#!/usr/bin/env python3
"""Build a portable, signed bundle; reject accidental developer-machine dependencies."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def copy_without_xattrs(source, destination):
    shutil.copyfile(source, destination)
    shutil.copymode(source, destination)
    return destination


def macho_files(root):
    magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
    for path in root.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as file:
            if file.read(4) in magic:
                yield path


def sign(app, identity, keychain=None, hardened_runtime=False):
    # Signing inside a cloud-synced Documents folder can reintroduce FinderInfo.
    run('/usr/bin/xattr', '-cr', app)
    flags = ['--force', '--sign', identity]
    if keychain:
        flags += ['--keychain', str(keychain)]
    if hardened_runtime:
        flags += ['--options', 'runtime', '--timestamp']
    else:
        flags += ['--timestamp=none']
    for path in macho_files(app):
        run('/usr/bin/codesign', *flags, path, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for framework in sorted(app.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
        run('/usr/bin/codesign', *flags, framework, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('/usr/bin/codesign', *flags, app)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)


def audit(app):
    binary = app / 'Contents/MacOS/Flameshoter'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    minimum = tuple(map(int, (info['LSMinimumSystemVersion'].split('.') + ['0', '0'])[:3]))
    load = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
    for version in re.findall(r'\bminos (\d+(?:\.\d+)+)', load):
        if tuple(map(int, (version.split('.') + ['0', '0'])[:3])) > minimum:
            raise RuntimeError(f'Executable requires macOS {version}, above its declared minimum')
    for line in subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True).splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        if 'Qt' in dependency:
            raise RuntimeError(f'Qt dependency remains: {dependency}')
        if not dependency.startswith(('/System/Library/', '/usr/lib/', '@rpath/libswift')):
            raise RuntimeError(f'Non-system dependency: {dependency}')
    if (app / 'Contents/Frameworks').exists():
        raise RuntimeError('Native release must not bundle third-party frameworks')
    for locale in ['en', 'zh-Hans']:
        if not (app / f'Contents/Resources/{locale}.lproj/InfoPlist.strings').exists():
            raise RuntimeError(f'Missing {locale} localization')
    if not (app / 'Contents/Resources/MenuBarIcon@2x.png').is_file():
        raise RuntimeError('Missing original flame menu-bar template image')
    print('Bundle audit passed: macOS minimum, Apple frameworks only, no Qt, English and Chinese')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--icon-assets', type=Path)
    parser.add_argument('--identity', default=os.environ.get('MACOS_SIGN_IDENTITY', '-'))
    parser.add_argument('--keychain', default=os.environ.get('MACOS_SIGN_KEYCHAIN'))
    parser.add_argument('--hardened-runtime', action='store_true')
    parser.add_argument('--keep-stage', action='store_true')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    stage = Path(tempfile.mkdtemp(prefix='flameshoter-package-'))
    app = stage / 'Flameshoter.app'
    print(f'Staged app: {app}', flush=True)
    try:
        executable = app / 'Contents/MacOS/Flameshoter'
        executable.parent.mkdir(parents=True)
        shutil.copyfile(args.binary, executable)
        executable.chmod(0o755)
        version = (source / 'VERSION').read_text().strip()
        revision = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=source, text=True).strip()
        info = {
            'CFBundleExecutable': 'Flameshoter', 'CFBundleIdentifier': 'io.github.Word2VecT.flameshoter',
            'CFBundleName': 'Flameshoter', 'CFBundleDisplayName': 'Flameshoter',
            'CFBundleVersion': version, 'CFBundleShortVersionString': version,
            'CFBundlePackageType': 'APPL', 'CFBundleInfoDictionaryVersion': '6.0',
            'CFBundleIconFile': 'Flameshoter', 'CFBundleIconName': 'Flameshoter',
            'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'zh-Hans'],
            'LSMinimumSystemVersion': '26.0', 'LSUIElement': True,
            'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
            'LSApplicationCategoryType': 'public.app-category.productivity',
            'NSScreenCaptureUsageDescription': 'Flameshoter captures your screen so you can select and annotate screenshots.',
            'NSHumanReadableCopyright': 'GPL-3.0-or-later. Based on Flameshot by Alejandro Sirgo Rica and contributors.',
            'FlameshoterRevision': revision,
        }
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        resources = app / 'Contents/Resources'
        shutil.copytree(source / 'Resources', resources, copy_function=copy_without_xattrs)
        if args.icon_assets:
            for name in ['Assets.car', 'Flameshoter.icns']:
                shutil.copyfile(args.icon_assets / name, resources / name)
        else:
            run('/usr/bin/xcrun', 'actool', source / 'packaging/macos/Flameshoter.icon',
                '--compile', resources, '--platform', 'macosx', '--minimum-deployment-target', '26.0',
                '--target-device', 'mac', '--app-icon', 'Flameshoter',
                '--output-partial-info-plist', stage / 'icon-info.plist')
        if not (resources / 'Assets.car').is_file():
            raise RuntimeError('Compile the Icon Composer document with Apple actool')
        shutil.copytree(source / 'licenses', resources / 'licenses', copy_function=copy_without_xattrs)
        for name in ['LICENSE', 'THIRD_PARTY.md']:
            shutil.copyfile(source / name, resources / name)
        audit(app)
        sign(app, args.identity, args.keychain, args.hardened_runtime)
        run(executable, '--version')
        link = stage / 'flameshoter'
        link.symlink_to(executable)
        reported = subprocess.check_output([str(link), '--version'], text=True)
        if f'Flameshoter v{version} ({revision})' not in reported:
            raise RuntimeError('The Homebrew-style CLI link did not recognize the app bundle')
        environment = dict(os.environ, FLAMESHOTER_TEST_IMAGE=str(resources / 'demo.png'),
                           FLAMESHOTER_TEST_CONFIG=str(stage / 'test-settings'))
        capture = subprocess.check_output([str(link), 'full', '--raw'], env=environment, timeout=30)
        if not capture.startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('The standalone CLI did not return a PNG')
        print('Homebrew-style CLI link and standalone fixture capture passed')
        args.out.parent.mkdir(parents=True, exist_ok=True)
        run('/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, args.out)
        print(f'Package: {args.out.resolve()}')
        if args.keep_stage:
            print(f'Staged app: {app}')
    finally:
        if not args.keep_stage:
            shutil.rmtree(stage)


if __name__ == '__main__':
    main()
