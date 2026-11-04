//
//  SettingsView.swift
//  Moonlight Duo
//
//  Every setting from Moonlight's original settings screen, plus the Duo additions
//  (Match Display, Split Layout, touch gamepad haptics). Changes save immediately.
//

import SwiftUI

/// Editable copy of MLSettings; every change is saved straight away.
struct SettingsDraft: Equatable {
    var resolutionMode: Int     // 0 fixed, 1 match display, 2 match safe area
    var width: Int
    var height: Int
    var framerate: Int
    var automaticBitrate: Bool
    var bitrate: Int
    var codec: Int
    var enableHdr: Bool
    var useFramePacing: Bool
    var statsOverlay: Bool
    var absoluteTouchMode: Bool
    var onscreenControls: Int
    var splitLayout: Bool
    var padHaptics: Bool
    var swapABXYButtons: Bool
    var multiController: Bool
    var btMouseSupport: Bool
    var optimizeGames: Bool
    var playAudioOnPC: Bool

    init(_ s: MLSettings) {
        resolutionMode = s.resolutionMode
        width = s.width
        height = s.height
        framerate = s.framerate
        automaticBitrate = s.automaticBitrate
        bitrate = s.bitrate
        codec = s.codec
        enableHdr = s.enableHdr
        useFramePacing = s.useFramePacing
        statsOverlay = s.statsOverlay
        absoluteTouchMode = s.absoluteTouchMode
        onscreenControls = s.onscreenControls
        splitLayout = s.splitLayout
        padHaptics = s.padHaptics
        swapABXYButtons = s.swapABXYButtons
        multiController = s.multiController
        btMouseSupport = s.btMouseSupport
        optimizeGames = s.optimizeGames
        playAudioOnPC = s.playAudioOnPC
    }

    func save() {
        let s = MLSettings.current()
        s.resolutionMode = resolutionMode
        s.width = width
        s.height = height
        s.framerate = framerate
        s.automaticBitrate = automaticBitrate
        s.bitrate = bitrate
        s.codec = codec
        s.enableHdr = enableHdr
        s.useFramePacing = useFramePacing
        s.statsOverlay = statsOverlay
        s.absoluteTouchMode = absoluteTouchMode
        s.onscreenControls = onscreenControls
        s.splitLayout = splitLayout
        s.padHaptics = padHaptics
        s.swapABXYButtons = swapABXYButtons
        s.multiController = multiController
        s.btMouseSupport = btMouseSupport
        s.optimizeGames = optimizeGames
        s.playAudioOnPC = playAudioOnPC
        s.save()
    }
}

enum ResolutionChoice: Hashable {
    case matchDisplay
    case matchSafeArea
    case preset(Int, Int)
    case custom

    /// The original app's presets (360p–4K) plus 1440p.
    static let presets: [(Int, Int, String)] = [
        (640, 360, "360p"), (1280, 720, "720p"), (1920, 1080, "1080p"), (2560, 1440, "1440p"), (3840, 2160, "4K"),
    ]
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SettingsDraft(MLSettings.current())
    @State private var choice: ResolutionChoice = .matchDisplay
    @State private var customWidth = ""
    @State private var customHeight = ""

    private let native = DisplayInfo.nativeStreamSize
    private let safeArea = DisplayInfo.safeAreaStreamSize
    private let maxFPS = DisplayInfo.maximumFramesPerSecond
    private let hevc = MLDuoBridge.hevcSupported()
    private static let bitrateSteps = [500, 1000, 1500, 2000, 2500, 3000, 4000, 5000, 6000, 7000, 8000, 9000,
                                       10000, 12000, 15000, 18000, 20000, 30000, 40000, 50000, 60000, 70000,
                                       80000, 100000, 120000, 150000]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    videoSection.id("video")
                    bitrateSection.id("bitrate")
                    controlsSection.id("controls")
                    hostSection.id("pc")
                    aboutSection.id("about")
                }
                .onAppear {
#if DEBUG
                    if let section = UserDefaults.standard.string(forKey: "MLSettingsSection") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            proxy.scrollTo(section, anchor: .top)
                        }
                    }
#endif
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .onAppear(perform: loadChoice)
        .onChange(of: draft) { _, new in new.save() }
        .onChange(of: choice) { _, new in applyChoice(new) }
    }

    // MARK: Sections

    private var videoSection: some View {
        Section {
            Picker("Resolution", selection: $choice) {
                Text("Match Display (\(Int(native.width))×\(Int(native.height)))").tag(ResolutionChoice.matchDisplay)
                Text("Safe Area (\(Int(safeArea.width))×\(Int(safeArea.height)))").tag(ResolutionChoice.matchSafeArea)
                ForEach(ResolutionChoice.presets, id: \.2) { preset in
                    Text("\(preset.2) (\(preset.0)×\(preset.1))")
                        .tag(ResolutionChoice.preset(preset.0, preset.1))
                        .selectionDisabled(preset.0 == 3840 && !hevc)   // as before: 4K needs an HEVC decoder (A9 or later)
                }
                Text("Custom").tag(ResolutionChoice.custom)
            }
            .pickerStyle(.navigationLink)

            if choice == .custom {
                HStack {
                    TextField("Width", text: $customWidth)
                        .keyboardType(.numberPad)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: $customHeight)
                        .keyboardType(.numberPad)
                }
                .onChange(of: customWidth) { _, _ in applyCustom() }
                .onChange(of: customHeight) { _, _ in applyCustom() }
            }

            Picker("Frame Rate", selection: $draft.framerate) {
                ForEach(frameRates, id: \.self) { Text("\($0) FPS").tag($0) }
            }

            Picker("Video Codec", selection: $draft.codec) {
                Text("Automatic").tag(0)
                Text("H.264").tag(1)
                if hevc { Text("HEVC").tag(2) }
                if MLDuoBridge.av1Supported() { Text("AV1").tag(3) }
            }

            Toggle("HDR", isOn: $draft.enableHdr)
                .disabled(!MLDuoBridge.hdrSupported())

            Picker("Frame Pacing", selection: $draft.useFramePacing) {
                Text("Lowest Latency").tag(false)
                Text("Smoothest Video").tag(true)
            }

            Toggle("Performance Overlay", isOn: $draft.statsOverlay)
        } header: {
            Text("Video")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Match Display streams at the native resolution of the screen you start on, so it fills either iPhone Duo display edge to edge. Sunshine and Lumen create a matching virtual display; with other hosts, set the PC's resolution yourself.")
                if !MLDuoBridge.hdrSupported() {
                    Text("HDR isn't supported on this device.")
                }
                Link("About custom resolutions", destination: URL(string: "https://moonlight-stream.org/custom-resolution")!)
            }
        }
    }

    private var bitrateSection: some View {
        Section {
            Toggle("Automatic Bitrate", isOn: $draft.automaticBitrate)
            if draft.automaticBitrate {
                LabeledContent("Estimated", value: mbps(estimatedBitrate))
            } else {
                VStack(alignment: .leading) {
                    LabeledContent("Bitrate", value: mbps(draft.bitrate))
                    Slider(value: bitrateIndex,
                           in: 0...Double(Self.bitrateSteps.count - 1), step: 1) {
                        Text("Bitrate")
                    } minimumValueLabel: {
                        Text("0.5")
                    } maximumValueLabel: {
                        Text("150")
                    }
                }
            }
        } header: {
            Text("Bitrate")
        } footer: {
            Text("Automatic uses Moonlight's usual estimate for the resolution and frame rate. Lower the bitrate if the stream stutters on a busy network.")
        }
    }

    private var controlsSection: some View {
        Section {
            Picker("Touch Mode", selection: $draft.absoluteTouchMode) {
                Text("Trackpad").tag(false)
                Text("Direct Touch").tag(true)
            }
            Picker("On-Screen Controls", selection: $draft.onscreenControls) {
                Text("Off").tag(0)
                Text("Automatic").tag(1)
                Text("2D (Simple)").tag(2)
                Text("3D (Full)").tag(3)
            }
            .disabled(draft.absoluteTouchMode)
            Toggle("Button Haptics", isOn: $draft.padHaptics)
                .disabled(draft.absoluteTouchMode || draft.onscreenControls == 0)
            Toggle("Split Layout", isOn: $draft.splitLayout)
            Toggle("Swap A/B and X/Y", isOn: $draft.swapABXYButtons)
            Picker("Controllers", selection: $draft.multiController) {
                Text("Single").tag(false)
                Text("Automatic").tag(true)
            }
            Toggle("Citrix X1 Mouse", isOn: $draft.btMouseSupport)
        } header: {
            Text("Controls")
        } footer: {
            Text("The touch gamepad is the one from nxnative. Tap its 2D / 3D button at the top to switch layouts: 3D adds the D-pad, L3 / R3 and a right stick you swipe in the right third of the screen; Tap hides the controls so touches move the mouse. Automatic hides it while a controller, keyboard or mouse is connected. Swap A/B and X/Y gives Nintendo positions. With Split Layout, the video moves above the hinge when iPhone Duo stands partly open, and to the top in portrait, with the controls below. Swipe from the left edge to end a stream.")
        }
    }

    private var hostSection: some View {
        Section {
            Toggle("Optimize Game Settings", isOn: $draft.optimizeGames)
            Toggle("Play Audio on PC", isOn: $draft.playAudioOnPC)
        } header: {
            Text("PC")
        } footer: {
            Text("Optimize Game Settings lets the PC change a game's settings to fit this stream.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: MLDuoBridge.appVersion())
            Link("Setup Guide", destination: MoonlightModel.setupGuideURL)
            Link("Troubleshooting", destination: MoonlightModel.troubleshootingURL)
        } header: {
            Text("About")
        } footer: {
            Text("Moonlight is free, open-source software (GPLv3). This build adds iPhone Duo support and nxnative's touch gamepad.")
        }
    }

    // MARK: Helpers

    /// As before: 30 and 60, plus 120 on displays faster than 62 Hz.
    private var frameRates: [Int] {
        var rates = [30, 60]
        if maxFPS > 62 { rates.append(120) }
        if !rates.contains(draft.framerate) { rates.append(draft.framerate); rates.sort() }
        return rates
    }

    private var effectiveSize: (Int, Int) {
        switch draft.resolutionMode {
        case 1: return (Int(native.width), Int(native.height))
        case 2: return (Int(safeArea.width), Int(safeArea.height))
        default: return (draft.width, draft.height)
        }
    }

    private var estimatedBitrate: Int {
        let (w, h) = effectiveSize
        return MLSettings.defaultBitrate(forWidth: w, height: h, fps: min(draft.framerate, maxFPS))
    }

    private var bitrateIndex: Binding<Double> {
        Binding {
            let index = Self.bitrateSteps.lastIndex { $0 <= draft.bitrate } ?? 0
            return Double(index)
        } set: { value in
            draft.bitrate = Self.bitrateSteps[Int(value.rounded())]
        }
    }

    private func mbps(_ kbps: Int) -> String {
        String(format: "%.1f Mbps", Double(kbps) / 1000)
    }

    private func loadChoice() {
        switch draft.resolutionMode {
        case 1: choice = .matchDisplay
        case 2: choice = .matchSafeArea
        default:
            if ResolutionChoice.presets.contains(where: { $0.0 == draft.width && $0.1 == draft.height }) {
                choice = .preset(draft.width, draft.height)
            } else {
                choice = .custom
            }
        }
        customWidth = "\(draft.width)"
        customHeight = "\(draft.height)"
    }

    private func applyChoice(_ choice: ResolutionChoice) {
        switch choice {
        case .matchDisplay:
            draft.resolutionMode = 1
            draft.width = Int(native.width)
            draft.height = Int(native.height)
        case .matchSafeArea:
            draft.resolutionMode = 2
            draft.width = Int(safeArea.width)
            draft.height = Int(safeArea.height)
        case .preset(let w, let h):
            draft.resolutionMode = 0
            draft.width = w
            draft.height = h
        case .custom:
            draft.resolutionMode = 0
            applyCustom()
        }
    }

    /// Same limits as the original custom-resolution dialog: 4096, or 8192 with an HEVC decoder.
    private func applyCustom() {
        let limit = hevc ? 8192 : 4096
        guard let w = Int(customWidth), let h = Int(customHeight), w > 0, h > 0 else { return }
        draft.width = min(w, limit)
        draft.height = min(h, limit)
    }
}
