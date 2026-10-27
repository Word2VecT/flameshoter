#!/usr/bin/env python3
import argparse
import hashlib
from pathlib import Path
import re
p = argparse.ArgumentParser()
p.add_argument('--archive', type=Path, required=True)
p.add_argument('--version', required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', a.version):
    p.error('Invalid version')
digest = hashlib.sha256(a.archive.read_bytes()).hexdigest()
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text('''cask "flameshoter" do
  version "%s"
  sha256 "%s"

  url "https://github.com/Word2VecT/flameshoter/releases/download/v#{version}/Flameshoter-#{version}-macos-arm64.zip"
  name "Flameshoter"
  desc "Screenshot and annotation app with native Liquid Glass controls"
  homepage "https://github.com/Word2VecT/flameshoter"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Flameshoter.app"
  binary "#{appdir}/Flameshoter.app/Contents/MacOS/Flameshoter", target: "flameshoter"

  uninstall quit: "io.github.Word2VecT.flameshoter"

  zap trash: ["~/.config/flameshoter", "~/Library/Preferences/io.github.Word2VecT.flameshoter.plist"]

  caveats <<~EOS
    Allow Screen Recording for Flameshoter when first taking a screenshot.
    Official releases use a fixed self-signed certificate and are not notarized by Apple.
    Upgrading from an older ad hoc signed release requires granting Screen Recording again once.
    If macOS blocks the first launch, use System Settings > Privacy & Security > Open Anyway.
  EOS
end
''' % (a.version, digest))
print(digest)
