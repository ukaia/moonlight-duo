//
//  MoonlightModel.swift
//  Moonlight Duo
//
//  App state for the SwiftUI shell: discovery, pairing, app lists and stream
//  launch. A port of MainFrameViewController's logic; the blocking network calls
//  live in MLDuoBridge and run off the main thread exactly as before.
//

import UIKit
import Observation

enum HostStatus: Hashable {
    case connecting, online, offline
}

struct HostRow: Identifiable, Hashable {
    let id: String
    var name: String
    var status: HostStatus
    var paired: Bool
    var runningGameID: String?
    var appCount: Int
    var isNvidia: Bool

    var statusText: String {
        switch status {
        case .connecting: return "Connecting…"
        case .offline: return "Offline"
        case .online:
            if !paired { return "Not paired · Tap to pair" }
            return runningGameID != nil ? "In game" : "Online"
        }
    }
}

struct AppRow: Identifiable, Hashable {
    let id: String
    var name: String
    var hidden: Bool
    var running: Bool
    var hdr: Bool
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var showHelp = false
}

/// What the app tile's menu offers, given what's running on the PC.
struct AppMenu {
    var primaryTitle: String
    var quitTitle: String?
    var hideTitle: String?
    var message: String
}

@MainActor
@Observable
final class MoonlightModel: NSObject {
    // MARK: Published state
    var hosts: [HostRow] = []
    var selectedHostID: String?
    var apps: [AppRow] = []
    var showHiddenApps = false
    var busyMessage: String?
    var pairingPIN: String?
    var pairingHostName = ""
    var alert: AlertInfo?
    var boxArt: [String: UIImage] = [:]
    var showSettings = false
    var showAddHost = false
    var appActionTarget: AppRow?
    var hostActionTarget: HostRow?
    private(set) var demoMode = false

    @ObservationIgnored weak var presenter: UIViewController?

    // MARK: Plumbing
    @ObservationIgnored private var hostMap: [String: TemporaryHost] = [:]
    @ObservationIgnored private var appMap: [String: TemporaryApp] = [:]
    @ObservationIgnored private var discovery: DiscoveryManager?
    @ObservationIgnored private var assets: AppAssetManager?
    @ObservationIgnored private let opQueue = OperationQueue()
    @ObservationIgnored private var clientCert: Data?
    @ObservationIgnored private var pairingInProgress = false
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var requestedArt: Set<String> = []
    @ObservationIgnored private(set) var isStreaming = false
    @ObservationIgnored private var streamEndObserver: NSObjectProtocol?

    static let troubleshootingURL = URL(string: "https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting")!
    static let setupGuideURL = URL(string: "https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide")!

    override init() {
        super.init()
        streamEndObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MLStreamDidEndNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.streamDidEnd() }
        }

#if DEBUG
        if UserDefaults.standard.bool(forKey: "MLDemo") {
            demoMode = true
            for host in DemoData.makeHosts() { hostMap[host.uuid] = host }
            rebuildHosts()
            return
        }
#endif

        CryptoManager.generateKeyPairUsingSSL()
        _ = IdManager.getUniqueId()
        clientCert = CryptoManager.readCertFromFile()
        assets = AppAssetManager(callback: self)

        let saved = MLDuoBridge.loadSavedHosts()
        for host in saved { hostMap[host.uuid] = host }
        discovery = DiscoveryManager(hosts: saved, andCallback: self)
        rebuildHosts()
        updateHostShortcuts()
    }

    // MARK: Derived

    var selectedHost: HostRow? {
        guard let id = selectedHostID else { return nil }
        return hosts.first { $0.id == id }
    }

    private var selectedTemporaryHost: TemporaryHost? {
        selectedHostID.flatMap { hostMap[$0] }
    }

    func boxArt(for app: AppRow) -> UIImage? {
        boxArt[artKey(hostID: selectedHostID ?? "", appID: app.id)]
    }

    private func artKey(hostID: String, appID: String) -> String { "\(hostID)/\(appID)" }

    // MARK: Lifecycle

    func sceneDidBecomeActive() {
        guard !isStreaming else { return }
        startRefreshTimer()
        beginForegroundRefresh()
        handlePendingShortcut()
    }

    func sceneWillResignActive() {
        guard !isStreaming else { return }
        stopRefreshTimer()
        discovery?.stopDiscovery()
    }

    private func beginForegroundRefresh() {
        rebuildHosts()
        discovery?.resetDiscoveryState()
        discovery?.startDiscovery()
        if let host = selectedTemporaryHost, host.pairState == .paired {
            open(host, userInitiated: false)
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        // Discovery updates host objects in place; poll them like the old host views did.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildHosts() }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: Hosts

    private static func row(for host: TemporaryHost) -> HostRow {
        let status: HostStatus
        switch host.state {
        case .online: status = .online
        case .offline: status = .offline
        default: status = .connecting
        }
        let game = host.currentGame
        return HostRow(id: host.uuid,
                       name: host.name,
                       status: status,
                       paired: host.pairState == .paired,
                       runningGameID: (game == nil || game == "0") ? nil : game,
                       appCount: host.appList.count,
                       isNvidia: host.isNvidiaServerSoftware)
    }

    private func rebuildHosts() {
        let rows = hostMap.values.map(Self.row(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if rows != hosts { hosts = rows }
        if let host = selectedTemporaryHost, !host.appList.isEmpty {
            refreshApps(for: host)
        }
#if DEBUG
        debugPairTick()
#endif
    }

    /// List selection. Offline hosts open their actions instead of hanging on a connect.
    func selectHost(_ id: String?) {
        guard let id, let host = hostMap[id] else {
            deselectHost()
            return
        }
        if host.state != .online {
            hostActionTarget = Self.row(for: host)
            return
        }
        if id != selectedHostID { showHiddenApps = false }
        open(host, userInitiated: true)
    }

    func deselectHost() {
        assets?.stopRetrieving()
        selectedHostID = nil
        apps = []
        showHiddenApps = false
    }

    private func open(_ host: TemporaryHost, userInitiated: Bool) {
        selectedHostID = host.uuid
        if !host.appList.isEmpty { refreshApps(for: host) } else { apps = [] }

        if demoMode {
            return
        }

        // Fast path: online, paired and a cached list. Skipped after streaming so the
        // running-game state gets refreshed from serverinfo.
        if host.state == .online && host.pairState == .paired && !host.appList.isEmpty && userInitiated {
            loadApps(for: host)
            return
        }

        if userInitiated { busyMessage = "Connecting to \(host.name)…" }
        let discovery = self.discovery
        let cert = clientCert
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var waited = 0
            while host.state == .unknown && waited < 20 {
                sleep(1)
                waited += 1
            }
            if host.state != .online {
                self?.onMain {
                    $0.busyMessage = nil
                    if $0.selectedHostID == host.uuid { $0.deselectHost() }
                    if userInitiated { $0.hostActionTarget = Self.row(for: host) }
                }
                return
            }

            discovery?.pauseDiscovery(for: host)
            var failure: Error?
            do { try MLDuoBridge.refreshServerInfo(for: host) } catch { failure = error }
            discovery?.resumeDiscovery(for: host)

            if let failure {
                self?.onMain {
                    $0.busyMessage = nil
                    guard $0.selectedHostID == host.uuid else { return }
                    $0.deselectHost()
                    host.state = .offline
                    if userInitiated {
                        $0.alert = AlertInfo(title: "Connection Failed", message: failure.localizedDescription, showHelp: true)
                    }
                }
                return
            }

            if host.pairState == .paired {
                self?.onMain { $0.loadApps(for: host) }
            } else if userInitiated, let cert {
                // Polling the server while pairing confuses it
                discovery?.stopDiscoveryBlocking()
                self?.onMain { model in
                    model.pairingHostName = host.name
                    model.pairingInProgress = true
                    MLDuoBridge.pair(with: host, clientCert: cert, callback: model, queue: model.opQueue)
                }
            } else {
                self?.onMain {
                    $0.busyMessage = nil
                    $0.deselectHost()
                }
            }
        }
    }

    private func loadApps(for host: TemporaryHost) {
        if host.appList.isEmpty {
            busyMessage = "Loading apps…"
        } else {
            busyMessage = nil
            refreshApps(for: host)
        }
        let discovery = self.discovery
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            discovery?.pauseDiscovery(for: host)
            let result = Result { try MLDuoBridge.fetchAppList(for: host) }
            discovery?.resumeDiscovery(for: host)

            self?.onMain { model in
                switch result {
                case .success(let list):
                    MLDuoBridge.mergeAppList(list, into: host)
                    model.updateHostShortcuts()
                    model.busyMessage = nil
                    guard model.selectedHostID == host.uuid else { return }
                    model.refreshApps(for: host)
                    model.assets?.stopRetrieving()
                    model.assets?.retrieveAssets(from: host)
                case .failure(let error):
                    model.busyMessage = nil
                    guard model.selectedHostID == host.uuid else { return }
                    model.deselectHost()
                    host.state = .offline
                    model.alert = AlertInfo(title: "Connection Interrupted", message: error.localizedDescription, showHelp: true)
                }
            }
        }
    }

    private func refreshApps(for host: TemporaryHost) {
        guard host.uuid == selectedHostID else { return }
        let all = host.appList.compactMap { $0 as? TemporaryApp }
        var map: [String: TemporaryApp] = [:]
        var rows: [AppRow] = []
        let running = host.currentGame
        for app in all {
            guard let id = app.id else { continue }
            map[id] = app
            if app.hidden && !showHiddenApps { continue }
            rows.append(AppRow(id: id, name: app.name ?? "App", hidden: app.hidden, running: id == running, hdr: app.hdrSupported))
        }
        rows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        appMap = map
        if rows != apps { apps = rows }
        for app in all { requestBoxArt(for: app, host: host) }
    }

    private func requestBoxArt(for app: TemporaryApp, host: TemporaryHost, force: Bool = false) {
        guard let appID = app.id else { return }
        let key = artKey(hostID: host.uuid, appID: appID)
        if !force && (requestedArt.contains(key) || boxArt[key] != nil) { return }
        requestedArt.insert(key)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let image = MLDuoBridge.decodedBoxArt(for: app) else { return }
            self?.onMain { $0.boxArt[key] = image }
        }
    }

    func setShowHiddenApps(_ show: Bool) {
        showHiddenApps = show
        if let host = selectedTemporaryHost { refreshApps(for: host) }
    }

    func refreshSelectedHost() {
        guard !demoMode, let host = selectedTemporaryHost else { return }
        loadApps(for: host)
    }

    // MARK: Pairing

    func cancelPairing() {
        pairingInProgress = false
        pairingPIN = nil
        busyMessage = nil
        discovery?.startDiscovery()
        deselectHost()
    }

    // MARK: Apps

    private func runningApp(on host: TemporaryHost) -> TemporaryApp? {
        guard let game = host.currentGame, game != "0" else { return nil }
        return host.appList.compactMap { $0 as? TemporaryApp }.first { $0.id == game }
    }

    func menu(for row: AppRow) -> AppMenu? {
        guard let host = selectedTemporaryHost, let app = appMap[row.id] else { return nil }
        let current = runningApp(on: host)
        let isCurrent = current?.id == app.id
        let primary = current == nil ? "Start \(row.name)" : (isCurrent ? "Resume \(row.name)" : "Resume \(current?.name ?? "Running App")")
        var quit: String?
        if let current {
            quit = isCurrent ? "Quit \(row.name)" : "Quit \(current.name ?? "Running App") and Start \(row.name)"
        }
        var hide: String?
        if current == nil || !isCurrent || app.hidden {
            hide = app.hidden ? "Show App" : "Hide App"
        }
        let message: String
        if let current, !isCurrent {
            message = "\(current.name ?? "Another app") is running on \(host.name)."
        } else {
            message = app.hidden ? "Hidden" : ""
        }
        return AppMenu(primaryTitle: primary, quitTitle: quit, hideTitle: hide, message: message)
    }

    /// Tap on a tile: start it, or ask what to do when something else is running.
    func tapApp(_ row: AppRow) {
        guard let host = selectedTemporaryHost, let app = appMap[row.id] else { return }
        if runningApp(on: host) != nil {
            appActionTarget = row
        } else {
            launch(app)
        }
    }

    /// The menu's primary action: resume whatever is running, else start this app.
    func startOrResume(_ row: AppRow) {
        guard let host = selectedTemporaryHost, let app = appMap[row.id] else { return }
        launch(runningApp(on: host) ?? app)
    }

    func quit(_ row: AppRow) {
        guard let host = selectedTemporaryHost, let app = appMap[row.id], let current = runningApp(on: host) else { return }
        let thenLaunch = current.id != app.id
        if demoMode {
            host.currentGame = "0"
            refreshApps(for: host)
            if thenLaunch { launch(app) }
            return
        }
        assets?.stopRetrieving()
        busyMessage = "Quitting \(current.name ?? "app")…"
        let discovery = self.discovery
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            discovery?.pauseDiscovery(for: host)
            var failure: Error?
            do { try MLDuoBridge.quitRunningApp(on: host) } catch { failure = error }
            discovery?.resumeDiscovery(for: host)
            self?.onMain { model in
                model.busyMessage = nil
                model.refreshApps(for: host)
                if let failure {
                    model.alert = AlertInfo(title: "Quitting App Failed", message: failure.localizedDescription)
                } else if thenLaunch {
                    model.launch(app)
                }
            }
        }
    }

    func toggleHidden(_ row: AppRow) {
        guard let app = appMap[row.id] else { return }
        app.hidden.toggle()
        if !demoMode { MLDuoBridge.save(app) }
        if let host = selectedTemporaryHost { refreshApps(for: host) }
    }

    private func launch(_ app: TemporaryApp) {
        assets?.stopRetrieving()
        let window = presenter?.view.window
        let controller: UIViewController
        if demoMode {
            // Preview at the native size of the view the stream will fill.
            let b = presenter?.view.bounds.size ?? CGSize(width: 640, height: 360)
            let w = Int32(max(b.width, b.height) * 3) & ~1, h = Int32(min(b.width, b.height) * 3) & ~1
            controller = MLDuoBridge.previewStreamViewController(withWidth: w, height: h, appName: app.name ?? "Preview")
        } else {
            let config = MLDuoBridge.streamConfiguration(for: app, window: window)
            controller = MLDuoBridge.streamViewController(with: config)
        }
#if DEBUG
        if let harness = HarnessViewController.current {
            isStreaming = true
            stopRefreshTimer()
            discovery?.stopDiscovery()
            harness.embed(controller)
            return
        }
#endif
        guard let presenter = topPresenter() else { return }
        isStreaming = true
        stopRefreshTimer()
        discovery?.stopDiscovery()
        presenter.present(controller, animated: true)
    }

    private func topPresenter() -> UIViewController? {
        var top = presenter
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private func streamDidEnd() {
        isStreaming = false
#if DEBUG
        // -MLStreamProbe YES: quit the app on the host afterwards, as a user would.
        if UserDefaults.standard.bool(forKey: "MLStreamProbe"), !demoMode, let host = selectedTemporaryHost {
            MLDuoBridge.debugAppend("stream ended; quitting the app on \(host.name)", toFile: "stream-status.txt")
            DispatchQueue.global(qos: .userInitiated).async {
                var result = "quit OK"
                do { try MLDuoBridge.quitRunningApp(on: host) } catch { result = "quit failed: \(error.localizedDescription)" }
                MLDuoBridge.debugAppend(result, toFile: "stream-status.txt")
            }
        }
#endif
        guard UIApplication.shared.applicationState != .background else { return }
        startRefreshTimer()
        beginForegroundRefresh()
    }

    // MARK: Host actions

    func wake(_ row: HostRow) {
        guard let host = hostMap[row.id] else { return }
        if host.mac == nil || host.mac == "00:00:00:00:00:00" {
            alert = AlertInfo(title: "Wake-on-LAN", message: "This PC's MAC address is unknown, so a wake-up packet can't be sent.")
            return
        }
        DispatchQueue.global().async { WakeOnLanManager.wake(host) }
        alert = AlertInfo(title: "Wake-on-LAN", message: "Sent a wake-up request. It may take a few moments for the PC to wake. If it never does, check that it's set up for Wake-on-LAN.")
    }

    func testNetwork() {
        busyMessage = "Testing your network…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message = MLDuoBridge.runNetworkTest()
            self?.onMain {
                $0.busyMessage = nil
                $0.alert = AlertInfo(title: "Network Test Complete", message: message)
            }
        }
    }

    func showAllApps(_ row: HostRow) {
        guard let host = hostMap[row.id] else { return }
        showHiddenApps = true
        open(host, userInitiated: true)
    }

    func remove(_ row: HostRow) {
        guard let host = hostMap[row.id] else { return }
        if selectedHostID == row.id { deselectHost() }
        discovery?.removeHost(fromDiscovery: host)
        if !demoMode { DataManager().remove(host) }
        hostMap.removeValue(forKey: row.id)
        rebuildHosts()
        updateHostShortcuts()
    }

    func addHost(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let discovery else { return }
        busyMessage = "Looking for \(trimmed)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            discovery.discoverHost(trimmed) { host, error in
                if let host {
                    self?.onMain {
                        $0.busyMessage = nil
                        $0.hostMap[host.uuid] = host
                        $0.rebuildHosts()
                    }
                } else {
                    var message = error ?? "Moonlight couldn't reach that PC."
                    if MLDuoBridge.hostPortsBlocked() {
                        message += "\n\nYour network is blocking Moonlight. Streaming may not work on this network."
                    }
                    self?.onMain {
                        $0.busyMessage = nil
                        $0.alert = AlertInfo(title: "Add PC Manually", message: message, showHelp: true)
                    }
                }
            }
        }
    }

    // MARK: Shortcuts

    func updateHostShortcuts() {
        UIApplication.shared.shortcutItems = hostMap.values
            .filter { $0.appList.count > 0 }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                UIApplicationShortcutItem(type: "PC", localizedTitle: $0.name, localizedSubtitle: nil,
                                          icon: UIApplicationShortcutIcon(type: .play),
                                          userInfo: ["UUID": $0.uuid as NSString])
            }
    }

    func handlePendingShortcut() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
              let uuid = appDelegate.pcUuidToLoad else { return }
        let host = hostMap[uuid]
        appDelegate.pcUuidToLoad = nil
        appDelegate.shortcutCompletionHandler?(host != nil)
        appDelegate.shortcutCompletionHandler = nil
        if let host, selectedHostID != uuid {
            open(host, userInitiated: false)
        }
    }

#if DEBUG
    /// Screenshot and test hooks: -MLSelectHost <uuid>, -MLOpenSettings YES, -MLStartStream <app name>.
    func applyDebugLaunchActions() {
        let d = UserDefaults.standard
        if let host = d.string(forKey: "MLSelectHost") { selectHost(host) }
        if d.bool(forKey: "MLOpenSettings") { showSettings = true }
        if let name = d.string(forKey: "MLStartStream") {
            debugStartStream(name, triesLeft: 60)
        }
    }

    /// Waits (up to a minute) for the app list, then starts that app.
    private func debugStartStream(_ name: String, triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isStreaming else { return }
            if let row = self.apps.first(where: { $0.name == name }), let app = self.appMap[row.id], self.busyMessage == nil {
                if !self.demoMode { MLDuoBridge.debugAppend("starting \(name)", toFile: "stream-status.txt") }
                self.launch(app)
            } else if triesLeft > 0 {
                self.debugStartStream(name, triesLeft: triesLeft - 1)
            } else {
                MLDuoBridge.debugAppend("gave up waiting for \(name)", toFile: "stream-status.txt")
            }
        }
    }

    // -MLPairHost <name> [-MLPairPIN 1234]: pairs with that host without UI, retrying each
    // timed-out attempt for up to an hour, and logs to Documents/pair-status.txt.
    @ObservationIgnored private var debugPairTarget: String? = UserDefaults.standard.string(forKey: "MLPairHost")
    @ObservationIgnored private var debugPairDeadline = Date().addingTimeInterval(3600)
    @ObservationIgnored private var debugPairAttempt = 0
    @ObservationIgnored private var debugPairNextTry = Date.distantPast
    @ObservationIgnored private var debugPairAdded = false

    func debugPairLog(_ text: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("pair-status.txt")
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + text + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        NSLog("MLPair %@", text)
    }

    private func debugPairTick() {
        guard let target = debugPairTarget, !demoMode else { return }
        // The target is a name or an address; an address wins when two hosts share a name.
        let isAddress = target.first?.isNumber == true
        func matches(_ h: TemporaryHost) -> Bool {
            if !isAddress { return h.name.caseInsensitiveCompare(target) == .orderedSame }
            return [h.activeAddress, h.localAddress, h.externalAddress].compactMap { $0 }
                .contains { $0 == target || $0.hasPrefix(target + ":") }
        }
        guard let host = hostMap.values.first(where: matches) else {
            if isAddress && !debugPairAdded && discovery != nil {
                debugPairAdded = true
                debugPairLog("adding \(target) manually")
                addHost(target)
            }
            return
        }
        if host.pairState == .paired && selectedHostID == host.uuid && !apps.isEmpty {
            debugPairLog("PAIRED with \(host.name) uuid \(host.uuid) mac \(host.mac ?? "?") at \(host.activeAddress ?? "?"); apps: \(apps.map(\.name).joined(separator: " | "))")
            debugPairTarget = nil
            return
        }
        guard !pairingInProgress, busyMessage == nil, Date() >= debugPairNextTry else { return }
        if Date() > debugPairDeadline {
            debugPairLog("GAVE UP after \(debugPairAttempt) attempts")
            debugPairTarget = nil
            return
        }
        guard host.state == .online else { return }
        if host.pairState == .paired && selectedHostID == host.uuid { return }   // loading apps
        debugPairAttempt += 1
        debugPairNextTry = Date().addingTimeInterval(5)
        debugPairLog("attempt \(debugPairAttempt): \(host.name) at \(host.activeAddress ?? "?") pairState \(host.pairState.rawValue)")
        selectHost(host.uuid)
    }

    var debugPairActive: Bool { debugPairTarget != nil }
#endif

    // MARK: Helpers

    /// Hops to the main actor in submission order (callbacks arrive on worker threads).
    nonisolated private func onMain(_ body: @escaping @MainActor (MoonlightModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
    }
}

// MARK: - Discovery, pairing and box art callbacks (worker threads)

extension MoonlightModel: DiscoveryCallback, PairCallback, AppAssetCallback {
    nonisolated func updateAllHosts(_ hosts: [Any]!) {
        let list = (hosts ?? []).compactMap { $0 as? TemporaryHost }
        onMain { model in
            for host in list { model.hostMap[host.uuid] = host }
            model.rebuildHosts()
            model.updateHostShortcuts()
        }
    }

    nonisolated func startPairing(_ PIN: String!) {
        // Synchronous so the PIN is up before any failure callback can arrive.
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.busyMessage = nil
                self.pairingPIN = PIN
#if DEBUG
                if self.debugPairActive { self.debugPairLog("PIN \(PIN ?? "?") shown, waiting for the host") }
#endif
            }
        }
    }

    nonisolated func pairSuccessful(_ serverCert: Data!) {
        onMain { model in
            guard let host = model.selectedTemporaryHost else { return }
            host.serverCert = serverCert
            model.pairingInProgress = false
            model.pairingPIN = nil
            model.discovery?.startDiscovery()
            model.loadApps(for: host)
        }
    }

    nonisolated func pairFailed(_ message: String!) {
        onMain { model in
            guard model.pairingInProgress else { return }
            model.pairingInProgress = false
            model.pairingPIN = nil
            model.busyMessage = nil
            model.discovery?.startDiscovery()
            model.deselectHost()
#if DEBUG
            if model.debugPairActive {
                model.debugPairLog("attempt failed: \(message ?? "")")
                return
            }
#endif
            model.alert = AlertInfo(title: "Pairing Failed", message: message ?? "", showHelp: true)
        }
    }

    nonisolated func alreadyPaired() {
        onMain { model in
            guard let host = model.selectedTemporaryHost else { return }
            model.pairingInProgress = false
            model.pairingPIN = nil
            model.discovery?.startDiscovery()
            model.loadApps(for: host)
        }
    }

    nonisolated func receivedAsset(for app: TemporaryApp!) {
        guard let app, let host = app.host else { return }
        onMain { model in model.requestBoxArt(for: app, host: host, force: true) }
    }
}
