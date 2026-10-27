// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import MachO

@main @MainActor struct NativeMain {
  static func main() {
    resolveExecutableSymlink()
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--version") || args.contains("-v") {
      let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.2"
      let revision =
        Bundle.main.object(forInfoDictionaryKey: "FlameshoterRevision") as? String ?? "development"
      print("Flameshoter v\(version) (\(revision))\nNative Swift / AppKit · no Qt runtime")
      return
    }
    if args.contains("--help") || args.contains("-h") {
      print(NativeCommand.usage)
      return
    }
    do {
      let command = args.isEmpty ? nil : try NativeCommand.parse(args)
      let identifier = Bundle.main.bundleIdentifier ?? "io.github.Word2VecT.flameshoter"
      if ProcessInfo.processInfo.environment["FLAMESHOTER_TEST_CONFIG"] == nil,
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
          .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
      {
        exit(CommandBridge.forward(command ?? NativeCommand(mode: "launcher"), to: existing))
      }
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      let delegate = AppController(command: command)
      application.delegate = delegate
      application.run()
      withExtendedLifetime(delegate) {}
    } catch {
      FileHandle.standardError.write(Data((errorMessage(error) + "\n").utf8))
      exit(64)
    }
  }
  private static func resolveExecutableSymlink() {
    // Launch the canonical executable so Foundation recognizes the app bundle through brew's link.
    var length: UInt32 = 0
    _NSGetExecutablePath(nil, &length)
    var buffer = [CChar](repeating: 0, count: Int(length))
    guard _NSGetExecutablePath(&buffer, &length) == 0 else { return }
    let invoked = String(cString: buffer)
    let resolved = URL(fileURLWithPath: invoked).resolvingSymlinksInPath().path
    guard resolved != invoked, resolved.contains(".app/Contents/MacOS/") else { return }
    var arguments = ([resolved] + CommandLine.arguments.dropFirst()).map { strdup($0) }
    arguments.append(nil)
    resolved.withCString { _ = execv($0, &arguments) }
    perror("Flameshoter")
    exit(71)
  }
}
