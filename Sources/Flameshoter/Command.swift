// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FlameshoterCore

struct NativeCommand: Codable {
  var mode = "gui"
  var delay = 0
  var display: Int?
  var region: CGRect?
  var path: String?
  var filename: String?
  var copy = false
  var raw = false
  var geometry = false
  var pin = false
  var acceptOnSelect = false
  var lastRegion = false
  var requestID: String?
  static let usage = """
    Flameshoter — native macOS screenshot and annotation
    Usage: flameshoter [gui|full|screen|launcher|config] [options]
      -p, --path PATH       Save to a directory or image file
      -d, --delay MS        Delay before capture
      -n, --number INDEX    Capture a display (zero-based)
          --region WxH+X+Y Preselect a region in pixels
      -c, --clipboard       Copy the result
      -r, --raw             Write PNG to standard output
      -g, --print-geometry  Print the selected pixel geometry
      -s, --accept-on-select Complete after selecting a region
          --last-region    Reuse the previous region
          --pin            Pin the result
      -f, --filename TEXT   Override the filename pattern
          --version        Print the version
          --help           Print this help
    """
  static func parse(_ args: [String]) throws -> NativeCommand {
    var result = NativeCommand()
    var index = 0
    if let first = args.first, !first.hasPrefix("-") {
      result.mode = first
      index = 1
    }
    guard ["gui", "full", "screen", "launcher", "config", "background"].contains(result.mode) else {
      throw CommandError.argument(result.mode)
    }
    func value() throws -> String {
      index += 1
      guard index < args.count else { throw CommandError.argument("missing option value") }
      return args[index]
    }
    while index < args.count {
      switch args[index] {
      case "-p", "--path": result.path = try value()
      case "-d", "--delay":
        guard let n = Int(try value()), (0...600_000).contains(n) else {
          throw CommandError.argument("delay")
        }
        result.delay = n
      case "-n", "--number", "--screen":
        guard let n = Int(try value()), n >= 0 else { throw CommandError.argument("display") }
        result.display = n
      case "--region": result.region = try parseRegion(value())
      case "-c", "--clipboard": result.copy = true
      case "-r", "--raw": result.raw = true
      case "-g", "--print-geometry": result.geometry = true
      case "--pin": result.pin = true
      case "-s", "--accept-on-select": result.acceptOnSelect = true
      case "--last-region": result.lastRegion = true
      case "-f", "--filename": result.filename = try value()
      default: throw CommandError.argument(args[index])
      }
      index += 1
    }
    return result
  }
  static func parseRegion(_ text: String) throws -> CGRect {
    let regex = try NSRegularExpression(pattern: "^(\\d+)x(\\d+)([+-]\\d+)([+-]\\d+)$")
    let source = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length))
    else { throw CommandError.argument("region") }
    let n = (1...4).map { Double(source.substring(with: match.range(at: $0)))! }
    guard n[0] > 0, n[1] > 0 else { throw CommandError.argument("region") }
    return CGRect(x: n[2], y: n[3], width: n[0], height: n[1])
  }
}
enum CommandError: LocalizedError {
  case argument(String)
  var errorDescription: String? {
    switch self {
    case .argument(let value): return "Invalid argument: \(value)\n\(NativeCommand.usage)"
    }
  }
}

@MainActor enum CommandBridge {
  static var identifier: String {
    Bundle.main.bundleIdentifier ?? "io.github.Word2VecT.flameshoter"
  }
  static var requestName: Notification.Name { Notification.Name(identifier + ".native.command") }
  static func responseName(_ id: String) -> Notification.Name {
    Notification.Name(identifier + ".native.response." + id)
  }
  static func resultURL(_ id: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "Flameshoter-Responses", isDirectory: true
    ).appendingPathComponent(id).appendingPathExtension("png")
  }
  static func forward(_ original: NativeCommand, to primary: NSRunningApplication) -> Int32 {
    var command = original
    command.requestID = UUID().uuidString
    var completed = false
    var status: Int32 = 0
    let id = command.requestID!
    let observer = DistributedNotificationCenter.default().addObserver(
      forName: responseName(id), object: identifier, queue: .main
    ) { notification in
      MainActor.assumeIsolated {
        if let error = notification.userInfo?["error"] as? String {
          FileHandle.standardError.write(Data((error + "\n").utf8))
          status = 1
        } else {
          let url = resultURL(id)
          if command.raw {
            do { FileHandle.standardOutput.write(try Data(contentsOf: url)) } catch {
              FileHandle.standardError.write(Data((errorMessage(error) + "\n").utf8))
              status = 1
            }
          }
          if command.geometry, let geometry = notification.userInfo?["geometry"] as? String {
            (command.raw ? FileHandle.standardError : FileHandle.standardOutput).write(
              Data((geometry + "\n").utf8))
          }
          try? FileManager.default.removeItem(at: url)
        }
        completed = true
      }
    }
    defer { DistributedNotificationCenter.default().removeObserver(observer) }
    do {
      let data = try JSONEncoder().encode(command)
      DistributedNotificationCenter.default().postNotificationName(
        requestName, object: identifier,
        userInfo: ["command": String(decoding: data, as: UTF8.self)], deliverImmediately: true)
    } catch { return 1 }
    while !completed {
      _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
      if primary.isTerminated { return 1 }
    }
    return status
  }
}
