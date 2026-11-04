//
//  SettingsSelfTest.swift
//  Moonlight Duo
//
//  DEBUG only: -MLSettingsSelfTest YES checks that every setting survives the new
//  Settings screen's model, lands in the same Core Data record the original app used,
//  and produces the same stream configuration as the original MainFrameViewController.
//  Results go to Documents/settings-selftest.txt. The user's settings are restored after.
//

#if DEBUG
import UIKit

@MainActor
enum SettingsSelfTest {
    private enum Store { case coreData, defaults }

    private struct Field {
        let name: String
        let key: String
        let store: Store
        let values: [Int]
        let set: (inout SettingsDraft, Int) -> Void
        let get: (SettingsDraft) -> Int
    }

    private static func boolField(_ name: String, _ key: String, _ store: Store, _ kp: WritableKeyPath<SettingsDraft, Bool>) -> Field {
        Field(name: name, key: key, store: store, values: [1, 0, 1],
              set: { $0[keyPath: kp] = $1 != 0 }, get: { $0[keyPath: kp] ? 1 : 0 })
    }

    private static func intField(_ name: String, _ key: String, _ store: Store, _ kp: WritableKeyPath<SettingsDraft, Int>, _ values: [Int]) -> Field {
        Field(name: name, key: key, store: store, values: values,
              set: { $0[keyPath: kp] = $1 }, get: { $0[keyPath: kp] })
    }

    static func runIfRequested(window: UIWindow) {
        guard UserDefaults.standard.bool(forKey: "MLSettingsSelfTest") else { return }
        var lines: [String] = []
        var failures = 0
        var checks = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks += 1
            if !ok { failures += 1 }
            lines.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }

        let original = SettingsDraft(MLSettings.current())
        let savedLayout = UserDefaults.standard.object(forKey: "MLPadLayout")

        // 1. Round trip: new Settings model -> stored record -> new Settings model.
        lines.append("== Round trip (Settings screen model -> storage -> Settings screen model)")
        let fields: [Field] = [
            intField("Resolution width", "width", .coreData, \.width, [640, 1280, 1920, 2560, 3840, 2006]),
            intField("Resolution height", "height", .coreData, \.height, [360, 720, 1080, 1440, 2160, 1398]),
            intField("Frame rate", "framerate", .coreData, \.framerate, [30, 60, 120]),
            intField("Bitrate (kbps)", "bitrate", .coreData, \.bitrate, [500, 20000, 150000]),
            intField("Video codec (0 auto, 1 H.264, 2 HEVC, 3 AV1)", "preferredCodec", .coreData, \.codec, [1, 2, 3, 0]),
            boolField("HDR", "enableHdr", .coreData, \.enableHdr),
            boolField("Frame pacing (smoothest video)", "useFramePacing", .coreData, \.useFramePacing),
            boolField("Performance overlay", "statsOverlay", .coreData, \.statsOverlay),
            boolField("Touch mode (direct touch)", "absoluteTouchMode", .coreData, \.absoluteTouchMode),
            intField("On-screen controls (0 off, 1 auto, 2 simple, 3 full)", "onscreenControls", .coreData, \.onscreenControls, [0, 2, 3, 1]),
            boolField("Swap A/B and X/Y", "swapABXYButtons", .coreData, \.swapABXYButtons),
            boolField("Controllers (automatic = multi)", "multiController", .coreData, \.multiController),
            boolField("Citrix X1 mouse", "btMouseSupport", .coreData, \.btMouseSupport),
            boolField("Optimize game settings", "optimizeGames", .coreData, \.optimizeGames),
            boolField("Play audio on PC", "playAudioOnPC", .coreData, \.playAudioOnPC),
            intField("Resolution mode (new: 0 fixed, 1 display, 2 safe area)", "MLResolutionMode", .defaults, \.resolutionMode, [0, 2, 1]),
            boolField("Automatic bitrate (new)", "MLAutomaticBitrate", .defaults, \.automaticBitrate),
            boolField("Split layout (new)", "MLSplitLayout", .defaults, \.splitLayout),
            boolField("Button haptics (new)", "MLPadHaptics", .defaults, \.padHaptics),
        ]
        for field in fields {
            for value in field.values {
                var draft = SettingsDraft(MLSettings.current())
                field.set(&draft, value)
                draft.save()
                let stored: Int
                switch field.store {
                case .coreData:
                    stored = (DataManager().getSettings().value(forKey: field.key) as? NSNumber)?.intValue ?? Int.min
                case .defaults:
                    stored = UserDefaults.standard.integer(forKey: field.key)
                }
                let reloaded = field.get(SettingsDraft(MLSettings.current()))
                check("\(field.name) = \(value)", stored == value && reloaded == value,
                      "stored \(stored), shown \(reloaded)")
            }
        }
        // Defaults for settings the original app never had
        check("Audio channels saved as stereo, as the original did",
              (DataManager().getSettings().audioConfig as NSNumber).intValue == 2)

        // 2. Same stream configuration as the original app for the same stored settings.
        lines.append("== Stream configuration vs. original MainFrameViewController -prepareToStreamApp:")
        let host = TemporaryHost()
        host.name = "Self-test PC"
        host.uuid = "selftest-host"
        host.activeAddress = "192.0.2.50"   // documentation range (RFC 5737)
        host.httpsPort = 47984
        host.serverCodecModeSupport = 0x0F0F
        host.state = .online
        let app = TemporaryApp()
        app.id = "881448767"
        app.name = "Steam Big Picture"
        app.host = host

        let scenarios: [(String, (inout SettingsDraft) -> Void)] = [
            ("1080p60 20 Mbps auto codec, swap, multi, audio on PC, smoothest", {
                $0.width = 1920; $0.height = 1080; $0.framerate = 60; $0.bitrate = 20000; $0.codec = 0
                $0.swapABXYButtons = true; $0.multiController = true; $0.playAudioOnPC = true
                $0.optimizeGames = false; $0.useFramePacing = true; $0.enableHdr = false }),
            ("720p30 5 Mbps H.264, everything off", {
                $0.width = 1280; $0.height = 720; $0.framerate = 30; $0.bitrate = 5000; $0.codec = 1
                $0.swapABXYButtons = false; $0.multiController = false; $0.playAudioOnPC = false
                $0.optimizeGames = true; $0.useFramePacing = false; $0.enableHdr = false }),
            ("4K120 80 Mbps HEVC + HDR", {
                $0.width = 3840; $0.height = 2160; $0.framerate = 120; $0.bitrate = 80000; $0.codec = 2
                $0.enableHdr = true }),
            ("1440p60 30 Mbps AV1", {
                $0.width = 2560; $0.height = 1440; $0.framerate = 60; $0.bitrate = 30000; $0.codec = 3
                $0.enableHdr = false }),
            ("Custom 2006x1398 at 120", {
                $0.width = 2006; $0.height = 1398; $0.framerate = 120; $0.bitrate = 40000; $0.codec = 0 }),
        ]
        for (name, apply) in scenarios {
            var draft = SettingsDraft(MLSettings.current())
            draft.resolutionMode = 0
            draft.automaticBitrate = false
            apply(&draft)
            draft.save()
            guard let legacy = MLDuoBridge.legacyStreamConfiguration(for: app) else {
                check(name, false, "original code path unavailable")
                continue
            }
            let modern = MLDuoBridge.streamConfiguration(for: app, window: window)
            let pairs: [(String, String, String)] = [
                ("width", "\(legacy.width)", "\(modern.width)"),
                ("height", "\(legacy.height)", "\(modern.height)"),
                ("fps", "\(legacy.frameRate)", "\(modern.frameRate)"),
                ("bitrate", "\(legacy.bitRate)", "\(modern.bitRate)"),
                ("video formats", String(legacy.supportedVideoFormats, radix: 16), String(modern.supportedVideoFormats, radix: 16)),
                ("audio", "\(legacy.audioConfiguration)", "\(modern.audioConfiguration)"),
                ("optimize", "\(legacy.optimizeGameSettings)", "\(modern.optimizeGameSettings)"),
                ("audio on PC", "\(legacy.playAudioOnPC)", "\(modern.playAudioOnPC)"),
                ("frame pacing", "\(legacy.useFramePacing)", "\(modern.useFramePacing)"),
                ("swap ABXY", "\(legacy.swapABXYButtons)", "\(modern.swapABXYButtons)"),
                ("multi-controller", "\(legacy.multiController)", "\(modern.multiController)"),
                ("gamepad mask", "\(legacy.gamepadMask)", "\(modern.gamepadMask)"),
                ("host", legacy.host ?? "nil", modern.host ?? "nil"),
                ("port", "\(legacy.httpsPort)", "\(modern.httpsPort)"),
                ("app", "\(legacy.appID ?? "nil")/\(legacy.appName ?? "nil")", "\(modern.appID ?? "nil")/\(modern.appName ?? "nil")"),
                ("codec support", "\(legacy.serverCodecModeSupport)", "\(modern.serverCodecModeSupport)"),
            ]
            let diffs = pairs.filter { $0.1 != $0.2 }.map { "\($0.0): original \($0.1), new \($0.2)" }
            let summary = "\(modern.width)x\(modern.height)@\(modern.frameRate) \(modern.bitRate) kbps formats 0x\(String(modern.supportedVideoFormats, radix: 16))"
            check(name, diffs.isEmpty, diffs.isEmpty ? "identical: \(summary)" : diffs.joined(separator: "; "))
        }

        // 3. The Duo additions.
        lines.append("== Duo additions")
        var draft = SettingsDraft(MLSettings.current())
        draft.resolutionMode = 1; draft.automaticBitrate = false; draft.save()
        let native = MLDuoBridge.nativeStreamSize(for: window)
        var config = MLDuoBridge.streamConfiguration(for: app, window: window)
        check("Match Display streams at the display's pixels", Int(config.width) == Int(native.width) && Int(config.height) == Int(native.height),
              "\(config.width)x\(config.height), display \(Int(native.width))x\(Int(native.height))")
        draft.resolutionMode = 2; draft.save()
        let safe = MLDuoBridge.safeAreaStreamSize(for: window)
        config = MLDuoBridge.streamConfiguration(for: app, window: window)
        check("Safe Area streams at the safe-area pixels", Int(config.width) == Int(safe.width) && Int(config.height) == Int(safe.height),
              "\(config.width)x\(config.height)")
        draft.resolutionMode = 0; draft.width = 1920; draft.height = 1080; draft.framerate = 60; draft.automaticBitrate = true; draft.save()
        config = MLDuoBridge.streamConfiguration(for: app, window: window)
        let expected = MLSettings.defaultBitrate(forWidth: 1920, height: 1080, fps: 60)
        check("Automatic bitrate uses Moonlight's estimate", Int(config.bitRate) == expected, "\(config.bitRate) kbps, expected \(expected)")
        UserDefaults.standard.set(1, forKey: "MLPadLayout")
        draft.onscreenControls = draft.onscreenControls == 3 ? 2 : 3; draft.save()
        check("Changing On-Screen Controls resets the gamepad's 2D/3D choice", UserDefaults.standard.object(forKey: "MLPadLayout") == nil)

        // 4. The touch gamepad (synthetic touches through the real touch handlers).
        lines.append("== Touch gamepad (nxnative port)")
        for line in MLTouchGamepad.debugSelfTest().dropFirst() {
            checks += 1
            if line.hasPrefix("FAIL") { failures += 1 }
            lines.append(line)
        }

        // Restore what the user had.
        original.save()
        if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: "MLPadLayout") } else { UserDefaults.standard.removeObject(forKey: "MLPadLayout") }
        check("User's settings restored", SettingsDraft(MLSettings.current()) == original)

        lines.insert("Moonlight Duo settings self-test: \(checks - failures)/\(checks) passed", at: 0)
        let text = lines.joined(separator: "\n") + "\n"
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? text.write(to: docs.appendingPathComponent("settings-selftest.txt"), atomically: true, encoding: .utf8)
        }
        NSLog("MLSettingsSelfTest %d/%d passed", checks - failures, checks)
    }
}
#endif
