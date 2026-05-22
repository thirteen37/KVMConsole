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
            case "input":
                try await runInput(args: Array(args.dropFirst()))
            case "all":
                try await runAll(args: Array(args.dropFirst()))
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
        LatencyBench — KVM Console latency measurement bench.

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
          input --device <name|uuid> [opts]   Measure input round-trip latency.
            --mode cursor|keystroke|keystroke-verify  (default: cursor)
                                              keystroke-verify reconnects per
                                              sample to bypass framebuffer
                                              staleness in Apple Screen Sharing;
                                              reports only hit/miss, no latency.
            --samples <count>                 (default: 50)
            --region <px>                     Watch region side length (default: 48)
            --threshold <0..255>              Mean abs delta to consider changed (default: 8)
            --settle-ms <ms>                  Inter-sample settle time (default: 250)
            --timeout-ms <ms>                 Per-sample timeout (default: 1500)
            --echo-region x,y,w,h             Required in --mode keystroke; framebuffer
                                              pixel rect where digit echo appears.
            --key-hold-ms <ms>                Hold time between keydown and keyup
                                              (default: 30). Sub-millisecond holds
                                              get coalesced by Apple Screen Sharing.
            --debug-keys                      Print per-sample detail: HID/keysym
                                              sent, max delta seen, frames searched.
            --out <directory>                 (default: ./Scripts/latency-reports)
          all --device <name|uuid> [opts]     Run video then input back-to-back.

        Examples:
          swift run LatencyBench list
          swift run LatencyBench video --device "MacBook" --duration 20
          swift run LatencyBench input --device "NanoKVM" --samples 30
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

        try writeReport(
            metric: "video",
            device: selection.device,
            frames: frames,
            input: [],
            opts: opts,
            framebufferSize: size
        )
    }

    static func runInput(args: [String]) async throws {
        let opts = try parseOptions(args: args)
        let selection = try DeviceSelector.resolve(
            identifier: opts.device,
            requireKVMType: nil,
            storeURL: opts.store
        )
        FileHandle.standardError.write(Data(
            "Target: \(TTYPrompt.describe(selection.device))\n".utf8
        ))

        if opts.inputMode == .keystrokeVerify {
            try await runKeystrokeVerify(selection: selection, opts: opts)
            return
        }

        let target = try makeTarget(for: selection)
        try await target.connect()
        let size = await target.framebufferSize

        let runner = InputLatencyRunner(
            target: target,
            configuration: .init(
                mode: opts.inputMode,
                samples: opts.inputSamples,
                regionSide: opts.regionSide,
                changeThreshold: opts.threshold,
                settleMs: opts.settleMs,
                perSampleTimeoutMs: opts.perSampleTimeoutMs,
                echoRegion: opts.echoRegion,
                keyHoldMs: opts.keyHoldMs,
                debugKeys: opts.debugKeys
            )
        )
        let inputSamples = try await runner.run()
        await target.disconnect()

        try writeReport(
            metric: "input",
            device: selection.device,
            frames: [],
            input: inputSamples,
            opts: opts,
            framebufferSize: size
        )
    }

    static func runKeystrokeVerify(selection: DeviceSelector.Selection, opts: Options) async throws {
        guard let echoRegion = opts.echoRegion else {
            throw OptionError.invalidValue("--mode keystroke-verify", "missing --echo-region")
        }
        guard selection.device.kvmType == .appleScreenSharing || selection.device.kvmType == .vnc else {
            throw OptionError.invalidValue("--mode keystroke-verify", "only works with RFB targets")
        }
        let verifier = KeystrokeVerifier(
            device: selection.device,
            password: selection.password,
            configuration: .init(
                samples: opts.inputSamples,
                regionSide: opts.regionSide,
                changeThreshold: opts.threshold,
                settleMs: opts.settleMs,
                perSampleTimeoutMs: opts.perSampleTimeoutMs,
                echoRegion: echoRegion,
                keyHoldMs: opts.keyHoldMs,
                postKeyHoldMs: opts.settleMs,
                debugKeys: opts.debugKeys
            )
        )
        let inputSamples = try await verifier.run()

        try writeReport(
            metric: "keystroke-verify",
            device: selection.device,
            frames: [],
            input: inputSamples,
            opts: opts,
            framebufferSize: nil
        )
    }

    static func runAll(args: [String]) async throws {
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

        let videoRunner = VideoLatencyRunner(
            target: target,
            configuration: .init(duration: opts.duration, maxFrames: opts.frames)
        )
        let frames = try await videoRunner.run()

        let inputRunner = InputLatencyRunner(
            target: target,
            configuration: .init(
                mode: opts.inputMode,
                samples: opts.inputSamples,
                regionSide: opts.regionSide,
                changeThreshold: opts.threshold,
                settleMs: opts.settleMs,
                perSampleTimeoutMs: opts.perSampleTimeoutMs,
                echoRegion: opts.echoRegion,
                keyHoldMs: opts.keyHoldMs,
                debugKeys: opts.debugKeys
            )
        )
        let inputSamples = try await inputRunner.run()
        await target.disconnect()

        try writeReport(
            metric: "all",
            device: selection.device,
            frames: frames,
            input: inputSamples,
            opts: opts,
            framebufferSize: size
        )
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

    static func writeReport(
        metric: String,
        device: Device,
        frames: [VideoLatencyRunner.FrameSample],
        input: [InputLatencyRunner.InputSample],
        opts: Options,
        framebufferSize size: CGSize?
    ) throws {
        let metadata: [String: AnyEncodable] = [
            "durationSec": AnyEncodable(opts.duration),
            "frameLimit": AnyEncodable(opts.frames ?? 0),
            "inputSamples": AnyEncodable(opts.inputSamples),
            "inputMode": AnyEncodable(opts.inputMode.rawValue),
            "regionSide": AnyEncodable(opts.regionSide),
            "changeThreshold": AnyEncodable(opts.threshold),
            "framebufferWidth": AnyEncodable(Int(size?.width ?? 0)),
            "framebufferHeight": AnyEncodable(Int(size?.height ?? 0))
        ]
        let report = Report(
            device: device,
            metric: metric,
            metadata: metadata,
            frameSamples: frames,
            inputSamples: input
        )
        let outDirectory = opts.out ?? DefaultReportLocation.directory()
        let urls = try report.write(to: outDirectory)

        print(report.summaryDescription())
        print("Wrote:")
        print("  \(urls.json.path)")
        print("  \(urls.csv.path)")
    }

    struct Options {
        var device: String?
        var duration: TimeInterval = 30
        var frames: Int?
        var out: URL?
        var inputMode: InputLatencyRunner.Mode = .cursor
        var inputSamples: Int = 50
        var regionSide: Int = 48
        var threshold: Double = 8
        var settleMs: Int = 250
        var perSampleTimeoutMs: Int = 1500
        var echoRegion: CGRect?
        var store: URL?
        var keyHoldMs: Int = 30
        var debugKeys: Bool = false
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
            case "--mode":
                let raw = try value(after: arg, args: args, i: &i)
                guard let mode = InputLatencyRunner.Mode(rawValue: raw) else {
                    throw OptionError.invalidValue(arg, raw)
                }
                opts.inputMode = mode
            case "--samples":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw) else { throw OptionError.invalidValue(arg, raw) }
                opts.inputSamples = n
            case "--region":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw) else { throw OptionError.invalidValue(arg, raw) }
                opts.regionSide = n
            case "--threshold":
                let raw = try value(after: arg, args: args, i: &i)
                guard let d = Double(raw) else { throw OptionError.invalidValue(arg, raw) }
                opts.threshold = d
            case "--settle-ms":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw) else { throw OptionError.invalidValue(arg, raw) }
                opts.settleMs = n
            case "--timeout-ms":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw) else { throw OptionError.invalidValue(arg, raw) }
                opts.perSampleTimeoutMs = n
            case "--store":
                let raw = try value(after: arg, args: args, i: &i)
                opts.store = URL(fileURLWithPath: raw)
            case "--key-hold-ms":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw) else { throw OptionError.invalidValue(arg, raw) }
                opts.keyHoldMs = n
            case "--debug-keys":
                opts.debugKeys = true
            case "--echo-region":
                let raw = try value(after: arg, args: args, i: &i)
                let parts = raw.split(separator: ",").map { Int($0) }
                guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else {
                    throw OptionError.invalidValue(arg, raw)
                }
                opts.echoRegion = CGRect(
                    x: parts[0]!,
                    y: parts[1]!,
                    width: parts[2]!,
                    height: parts[3]!
                )
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
