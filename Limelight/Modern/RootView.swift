//
//  RootView.swift
//  Moonlight Duo
//
//  Two levels of hierarchy: PCs (sidebar) and their games (detail). On the iPhone Duo
//  outer display and other compact widths the split view collapses to a stack; on the
//  inner display both show side by side, and the system lines the columns up with the
//  fold when the device is partially open.
//

import SwiftUI

struct RootView: View {
    @Bindable var model: MoonlightModel
    @State private var columnVisibility: NavigationSplitViewVisibility = RootView.initialColumns

    private static var initialColumns: NavigationSplitViewVisibility {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "MLDetailOnly") { return .detailOnly }
#endif
        return .automatic
    }
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            HostListView(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            if let host = model.selectedHost {
                AppGridView(model: model, host: host)
            } else {
                ContentUnavailableView {
                    Label("Choose a PC", systemImage: "desktopcomputer")
                } description: {
                    Text("Moonlight streams games from a PC running Sunshine or Lumen. Pick one to see what you can play.")
                } actions: {
                    Link("Setup Guide", destination: MoonlightModel.setupGuideURL)
                }
            }
        }
        .onChange(of: model.selectedHostID) { _, id in
            compactColumn = id == nil ? .sidebar : .detail
        }

        .overlay {
            if let message = model.busyMessage {
                BusyHUD(message: message)
            }
        }
        .animation(.smooth(duration: 0.2), value: model.busyMessage)
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: Binding(get: { model.pairingPIN != nil }, set: { _ in })) {
            PairingView(hostName: model.pairingHostName, pin: model.pairingPIN ?? "") {
                model.cancelPairing()
            }
        }
        .alert(model.alert?.title ?? "",
               isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { info in
            Button("OK", role: .cancel) {}
            if info.showHelp {
                Link("Help", destination: MoonlightModel.troubleshootingURL)
            }
        } message: { info in
            Text(info.message)
        }
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.36, green: 0.55, blue: 1.0))
    }
}

// MARK: - PCs

struct HostListView: View {
    @Bindable var model: MoonlightModel
    @State private var newHostAddress = ""

    var body: some View {
        List(selection: Binding(get: { model.selectedHostID }, set: { model.selectHost($0) })) {
            if model.hosts.isEmpty {
                Section {
                    HStack(spacing: 14) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Searching your network…")
                                .font(.headline)
                            Text("PCs running Sunshine or Lumen show up here. Make sure this iPhone is on the same Wi-Fi.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    Button("Add PC Manually", systemImage: "plus.circle") {
                        model.showAddHost = true
                    }
                }
            } else {
                Section("Computers") {
                    ForEach(model.hosts) { host in
                        HostRowView(host: host)
                            .tag(host.id)
                            .contextMenu { HostActions(model: model, host: host) }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    model.remove(host)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Moonlight")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add PC", systemImage: "plus") {
                    newHostAddress = ""
                    model.showAddHost = true
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Settings", systemImage: "gearshape") {
                    model.showSettings = true
                }
            }
        }
        .alert("Add PC Manually", isPresented: $model.showAddHost) {
            TextField("IP address or hostname", text: $newHostAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") { model.addHost(newHostAddress) }
        } message: {
            Text("If Moonlight doesn't find your PC automatically, enter its address.")
        }
        .confirmationDialog(model.hostActionTarget?.name ?? "",
                            isPresented: Binding(get: { model.hostActionTarget != nil },
                                                 set: { if !$0 { model.hostActionTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: model.hostActionTarget) { host in
            HostActions(model: model, host: host)
        } message: { host in
            Text(host.statusText)
        }
    }
}

struct HostRowView: View {
    let host: HostRow

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(host.status == .online ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 46, height: 46)
                    .background(.quaternary, in: .rect(cornerRadius: 12))
                StatusDot(status: host.status, paired: host.paired)
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(host.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if host.status == .online && !host.paired {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else if host.runningGameID != nil {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Shared by the row context menu, the offline-host dialog and the detail toolbar menu.
struct HostActions: View {
    let model: MoonlightModel
    let host: HostRow

    var body: some View {
        if host.status != .online {
            Button("Wake PC", systemImage: "power") { model.wake(host) }
        } else if host.paired {
            Button("Show All Apps", systemImage: "eye") { model.showAllApps(host) }
        }
        Button("Test Network", systemImage: "network") { model.testNetwork() }
        if host.status != .online {
            Link(destination: MoonlightModel.troubleshootingURL) {
                Label("Connection Help", systemImage: "questionmark.circle")
            }
        }
        Button("Remove PC", systemImage: "trash", role: .destructive) { model.remove(host) }
    }
}
