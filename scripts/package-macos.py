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
    minimum = tuple((list(map(int, plistlib.loads((app / 'Contents/Info.plist').read_bytes())['LSMinimumSystemVersion'].split('.'))) + [0, 0])[:3])
    framework_dir = app / 'Contents/Frameworks'
    for path in macho_files(app):
        load = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
        for version in re.findall(r'\bminos (\d+(?:\.\d+)+)', load):
            target = tuple((list(map(int, version.split('.'))) + [0, 0])[:3])
            if target > minimum:
                raise RuntimeError(f'{path.name} requires macOS {version}, above the declared minimum')
        for line in subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True).splitlines()[1:]:
            if ' (compatibility version' not in line:
                continue
            dep = line.strip().split(' (', 1)[0]
            if dep.startswith('/') and not dep.startswith(('/System/Library/', '/usr/lib/')):
                raise RuntimeError(f'Unbundled dependency in {path.name}: {dep}')
            if dep.startswith('@rpath/') and not (framework_dir / dep[7:]).exists():
                raise RuntimeError(f'Missing bundled dependency: {dep}')
    for locale in ['en', 'zh_CN']:
        if not (app / f'Contents/Resources/translations/Internationalization_{locale}.qm').is_file():
            raise RuntimeError(f'Missing {locale} translation')
    print('Bundle audit passed: OS minimum, runtime dependencies, English and Chinese catalogs')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--qt', required=True, type=Path)
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
        def ignore(folder, names):
            return set(names) & {'Frameworks', 'PlugIns', '_CodeSignature'} if Path(folder).name == 'Contents' else set()
        shutil.copytree(args.app, app, symlinks=True, copy_function=copy_without_xattrs, ignore=ignore)
        resources = app / 'Contents/Resources'
        if args.icon_assets:
            for asset in args.icon_assets.iterdir():
                if asset.is_file():
                    shutil.copyfile(asset, resources / asset.name)
        else:
            run('/usr/bin/xcrun', 'actool', source / 'packaging/macos/Flameshoter.icon',
                '--compile', resources, '--platform', 'macosx', '--minimum-deployment-target', '26.0',
                '--target-device', 'mac', '--app-icon', 'Flameshoter',
                '--output-partial-info-plist', stage / 'icon-info.plist')
        if not (resources / 'Assets.car').is_file():
            raise RuntimeError('The Icon Composer document must be compiled into Assets.car')
        run(args.qt / 'bin/macdeployqt', app, '-no-codesign', '-verbose=1')
        translations = resources / 'translations'
        translations.mkdir(exist_ok=True)
        for catalog in ['qtbase_zh_CN.qm', 'qt_zh_CN.qm']:
            shutil.copyfile(args.qt / 'translations' / catalog, translations / catalog)
        (resources / 'qt.conf').write_text('[Paths]\nPlugins=PlugIns\nTranslations=Resources/translations\n')
        for name in ['LICENSE', 'THIRD_PARTY.md']:
            if (source / name).exists():
                shutil.copyfile(source / name, resources / name)
        shutil.copytree(source / 'licenses', resources / 'licenses', dirs_exist_ok=True)
        # Delete development-only search paths after deployment.
        for binary in macho_files(app):
            load = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
            for path in set(re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', load)):
                if path.startswith('/') and not path.startswith(('/System/', '/usr/lib/')):
                    run('/usr/bin/install_name_tool', '-delete_rpath', path, binary)
        for binary in macho_files(app):
            ids = subprocess.check_output(['/usr/bin/otool', '-D', str(binary)], text=True).splitlines()[1:]
            ids = [line.strip() for line in ids if line.strip() and not line.endswith(':')]
            if ids:
                if (app / 'Contents/Frameworks') in binary.parents:
                    install_id = '@rpath/' + str(binary.relative_to(app / 'Contents/Frameworks'))
                else:
                    install_id = '@loader_path/' + binary.name
                run('/usr/bin/install_name_tool', '-id', install_id, binary)
        audit(app)
        sign(app, args.identity, args.keychain, args.hardened_runtime)
        run(app / "Contents/MacOS/Flameshoter", "--version")
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
