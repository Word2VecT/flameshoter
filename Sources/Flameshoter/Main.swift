// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@main @MainActor struct NativeMain {
  static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--version") || args.contains("-v") {
      let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
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
      if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
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
}
