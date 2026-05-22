#if os(macOS)
import Foundation
import KVMCore

@MainActor
struct BenchCLI {
    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = args.first else {
            printUsage()
            exit(2)
        }
        do {
            switch subcommand {
            case "list":
                try runList(args: Array(args.dropFirst()))
            case "video":
                try await runVideo(args: Array(args.dropFirst()))
            case "-h", "--help", "help":
                printUsage()
                exit(0)
            default:
                FileHandle.standardError.write(Data("Unknown subcommand: \(subcommand)\n".utf8))
                printUsage()
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        let usage = """
        LatencyBench — KVM Console video latency measurement bench.

        Global options (apply to any subcommand):
          --store <path>                      Path to devices.json (overrides
                                              automatic discovery of the
                                              sandboxed app container).

        Subcommands:
          list [--store <path>]               List saved devices.
          video --device <name|uuid> [opts]   Measure video pipeline latency.
            --duration <seconds>              (default: 30)
            --frames <count>                  Stop after N frames.
            --out <directory>                 Where reports are written.
                                              (default: ./Scripts/latency-reports)

        Examples:
          swift run LatencyBench list
          swift run LatencyBench video --device "MacBook" --duration 60
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }

    static func runList(args: [String] = []) throws {
        let opts = try parseOptions(args: args)
        let resolved = DeviceSelector.resolveStoreURL(override: opts.store)
        let devices = DeviceSelector.listSavedDevices(storeURL: opts.store)

        if let resolved {
            FileHandle.standardError.write(Data("Reading: \(resolved.path)\n".utf8))
        } else {
            FileHandle.standardError.write(Data(
                "No devices.json found at any of these locations:\n".utf8
            ))
            for candidate in DeviceSelector.candidateStoreURLs(override: opts.store) {
                FileHandle.standardError.write(Data("  - \(candidate.path)\n".utf8))
            }
            FileHandle.standardError.write(Data((
                "If KVM Console (sandboxed) holds your devices, grant the terminal Full Disk Access\n"
                + "in System Settings → Privacy & Security, or pass --store <path>.\n"
            ).utf8))
        }
        if devices.isEmpty {
            print("No saved devices.")
            return
        }
        for device in devices {
            print(TTYPrompt.describe(device))
            print("    id=\(device.id.uuidString)  scheme=\(device.scheme.rawValue)")
        }
    }

    static func runVideo(args: [String]) async throws {
        let opts = try parseOptions(args: args)
        let selection = try DeviceSelector.resolve(
            identifier: opts.device,
            requireKVMType: nil,
            storeURL: opts.store
        )
        FileHandle.standardError.write(Data(
            "Target: \(TTYPrompt.describe(selection.device))\n".utf8
        ))

        let target = try makeTarget(for: selection)
        try await target.connect()

        let size = await target.framebufferSize
        if let size {
            FileHandle.standardError.write(Data(
                "Framebuffer: \(Int(size.width))×\(Int(size.height))\n".utf8
            ))
        }

        let runner = VideoLatencyRunner(
            target: target,
            configuration: .init(duration: opts.duration, maxFrames: opts.frames)
        )
        let frames = try await runner.run()
        await target.disconnect()

        let metadata: [String: AnyEncodable] = [
            "durationSec": AnyEncodable(opts.duration),
            "frameLimit": AnyEncodable(opts.frames ?? 0),
            "framebufferWidth": AnyEncodable(Int(size?.width ?? 0)),
            "framebufferHeight": AnyEncodable(Int(size?.height ?? 0))
        ]
        let report = Report(
            device: selection.device,
            metric: "video",
            metadata: metadata,
            frameSamples: frames
        )
        let outDirectory = opts.out ?? DefaultReportLocation.directory()
        let urls = try report.write(to: outDirectory)

        print(report.summaryDescription())
        print("Wrote:")
        print("  \(urls.json.path)")
        print("  \(urls.csv.path)")
    }

    static func makeTarget(for selection: DeviceSelector.Selection) throws -> LatencyTarget {
        switch selection.device.kvmType {
        case .appleScreenSharing, .vnc:
            return RFBLatencyTarget(device: selection.device, password: selection.password)
        case .nanoKVMLite, .nanoKVMUSB:
            return NanoKVMLatencyTarget.make(
                device: selection.device,
                password: selection.password,
                account: selection.passwordAccount
            )
        case .comet:
            return GLKVMLatencyTarget.make(
                device: selection.device,
                password: selection.password,
                account: selection.passwordAccount
            )
        }
    }

    struct Options {
        var device: String?
        var duration: TimeInterval = 30
        var frames: Int?
        var out: URL?
        var store: URL?
    }

    static func parseOptions(args: [String]) throws -> Options {
        var opts = Options()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--device":
                opts.device = try value(after: arg, args: args, i: &i)
            case "--duration":
                let raw = try value(after: arg, args: args, i: &i)
                guard let d = TimeInterval(raw) else { throw OptionError.invalidValue(arg, raw) }
                opts.duration = d
            case "--frames":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw) else { throw OptionError.invalidValue(arg, raw) }
                opts.frames = n
            case "--out":
                let raw = try value(after: arg, args: args, i: &i)
                opts.out = URL(fileURLWithPath: raw)
            case "--store":
                let raw = try value(after: arg, args: args, i: &i)
                opts.store = URL(fileURLWithPath: raw)
            default:
                throw OptionError.unknown(arg)
            }
            i += 1
        }
        return opts
    }

    static func value(after flag: String, args: [String], i: inout Int) throws -> String {
        guard i + 1 < args.count else { throw OptionError.missingValue(flag) }
        i += 1
        return args[i]
    }
}

enum OptionError: Error, LocalizedError {
    case missingValue(String)
    case invalidValue(String, String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag): return "Missing value for \(flag)."
        case .invalidValue(let flag, let raw): return "Invalid value \(raw) for \(flag)."
        case .unknown(let flag): return "Unknown flag \(flag)."
        }
    }
}

await BenchCLI.run()
#else
import Foundation
FileHandle.standardError.write(Data("LatencyBench is macOS-only.\n".utf8))
exit(1)
#endif
