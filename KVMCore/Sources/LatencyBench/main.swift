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
          input --device <name|uuid> [opts]   Measure visible input echo latency.
            --input-mode <cursor|keyboard>    (default: keyboard for Apple Screen Sharing,
                                               cursor otherwise)
            --samples <count>                 Inputs to send. (default: 50)
            --warmup <count>                  Inputs to ignore before recording.
                                              (default: 2 keyboard, 0 cursor)
            --interval <seconds>              Pause between inputs.
                                              (default: 1.25 keyboard, 0.25 cursor)
            --timeout <seconds>               Per-move miss timeout. (default: 2)
            --region-side <pixels>            Cursor diff square side. (default: 48)
            --change-threshold <pixels>       Changed pixels needed for a hit.
                                              (default: 64 keyboard, 8 cursor)
            --pixel-delta <value>             Per-pixel diff threshold. (default: 24)
            --skip-arm-prompt                 Do not wait before sending keyboard input.
            --out <directory>                 Where reports are written.
                                              (default: ./Scripts/latency-reports)

        Examples:
          swift run LatencyBench list
          swift run LatencyBench video --device "MacBook" --duration 60
          swift run LatencyBench input --device "MacBook" --samples 50
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

        let inputMode = opts.inputMode ?? defaultInputMode(for: selection.device)
        if inputMode == .keyboard && !opts.skipArmPrompt {
            FileHandle.standardError.write(Data((
                "Keyboard input mode sends printable test keystrokes. "
                + "Focus a harmless text field on the remote Mac and keep the screen still.\n"
            ).utf8))
            _ = TTYPrompt.promptLine("Press Return when ready")
        }

        let target = try makeTarget(for: selection)
        try await target.connect()

        let size = await target.framebufferSize
        if let size {
            FileHandle.standardError.write(Data(
                "Framebuffer: \(Int(size.width))×\(Int(size.height))\n".utf8
            ))
        }
        let inputInterval = opts.inputInterval ?? defaultInputInterval(for: inputMode)
        let changeThreshold = opts.changeThreshold ?? defaultChangeThreshold(for: inputMode)
        let warmupCount = opts.warmupCount ?? defaultWarmupCount(for: inputMode)

        let runner = InputLatencyRunner(
            target: target,
            configuration: .init(
                mode: inputMode,
                sampleCount: opts.inputSamples,
                warmupCount: warmupCount,
                interval: inputInterval,
                timeout: opts.inputTimeout,
                regionSide: opts.regionSide,
                changeThreshold: changeThreshold,
                pixelDeltaThreshold: opts.pixelDelta
            )
        )
        let inputSamples: [InputLatencyRunner.InputSample]
        do {
            inputSamples = try await runner.run()
        } catch {
            await target.disconnect()
            throw error
        }

        let metadata: [String: AnyEncodable] = [
            "framebufferWidth": AnyEncodable(Int(size?.width ?? 0)),
            "framebufferHeight": AnyEncodable(Int(size?.height ?? 0)),
            "inputMode": AnyEncodable(inputMode.rawValue),
            "inputSamples": AnyEncodable(opts.inputSamples),
            "warmupSamples": AnyEncodable(warmupCount),
            "inputIntervalSec": AnyEncodable(inputInterval),
            "inputTimeoutSec": AnyEncodable(opts.inputTimeout),
            "regionSide": AnyEncodable(opts.regionSide),
            "changeThreshold": AnyEncodable(changeThreshold),
            "pixelDelta": AnyEncodable(opts.pixelDelta)
        ]
        let report = Report(
            device: selection.device,
            metric: "input",
            metadata: metadata,
            inputSamples: inputSamples
        )
        await target.disconnect()
        let outDirectory = opts.out ?? DefaultReportLocation.directory()
        let urls = try report.write(to: outDirectory)

        print(report.summaryDescription())
        print("Wrote:")
        print("  \(urls.json.path)")
        print("  \(urls.csv.path)")
    }

    static func defaultInputMode(for device: Device) -> InputLatencyRunner.InputMode {
        device.kvmType == .appleScreenSharing ? .keyboard : .cursor
    }

    static func defaultChangeThreshold(for mode: InputLatencyRunner.InputMode) -> Int {
        switch mode {
        case .keyboard: return 64
        case .cursor: return 8
        }
    }

    static func defaultInputInterval(for mode: InputLatencyRunner.InputMode) -> TimeInterval {
        switch mode {
        case .keyboard: return 1.25
        case .cursor: return 0.25
        }
    }

    static func defaultWarmupCount(for mode: InputLatencyRunner.InputMode) -> Int {
        switch mode {
        case .keyboard: return 2
        case .cursor: return 0
        }
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
        var inputMode: InputLatencyRunner.InputMode?
        var inputSamples: Int = 50
        var warmupCount: Int?
        var inputInterval: TimeInterval?
        var inputTimeout: TimeInterval = 2
        var regionSide: Int = 48
        var changeThreshold: Int?
        var pixelDelta: Int = 24
        var skipArmPrompt = false
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
            case "--input-mode":
                let raw = try value(after: arg, args: args, i: &i)
                guard let mode = InputLatencyRunner.InputMode(rawValue: raw) else {
                    throw OptionError.invalidValue(arg, raw)
                }
                opts.inputMode = mode
            case "--samples":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw), n > 0 else { throw OptionError.invalidValue(arg, raw) }
                opts.inputSamples = n
            case "--warmup":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw), n >= 0 else { throw OptionError.invalidValue(arg, raw) }
                opts.warmupCount = n
            case "--interval":
                let raw = try value(after: arg, args: args, i: &i)
                guard let d = TimeInterval(raw), d >= 0 else { throw OptionError.invalidValue(arg, raw) }
                opts.inputInterval = d
            case "--timeout":
                let raw = try value(after: arg, args: args, i: &i)
                guard let d = TimeInterval(raw), d > 0 else { throw OptionError.invalidValue(arg, raw) }
                opts.inputTimeout = d
            case "--region-side":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw), n > 0 else { throw OptionError.invalidValue(arg, raw) }
                opts.regionSide = n
            case "--change-threshold":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw), n > 0 else { throw OptionError.invalidValue(arg, raw) }
                opts.changeThreshold = n
            case "--pixel-delta":
                let raw = try value(after: arg, args: args, i: &i)
                guard let n = Int(raw), n > 0 else { throw OptionError.invalidValue(arg, raw) }
                opts.pixelDelta = n
            case "--skip-arm-prompt":
                opts.skipArmPrompt = true
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
