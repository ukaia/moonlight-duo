//
//  AppGridView.swift
//  Moonlight Duo
//
//  The game grid. It splits into two equal halves around the hinge when the inner
//  display is partially folded and the grid spans it, with an even column count so
//  nothing sits in the fold.
//

import SwiftUI

struct AppGridView: View {
    @Bindable var model: MoonlightModel
    let host: HostRow
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var probedFold: ClosedRange<CGFloat>?

    var body: some View {
        GeometryReader { proxy in
            let plan = GridPlan.make(width: proxy.size.width,
                                     fold: proxy.verticalFoldBand() ?? probedFold,
                                     minTile: horizontalSizeClass == .regular ? 132 : 118)
            ScrollView {
                if model.apps.isEmpty {
                    emptyState
                        .frame(width: proxy.size.width, height: proxy.size.height * 0.8)
                } else {
                    FoldAwareGrid(plan: plan, apps: model.apps) { app in
                        AppTile(app: app, image: model.boxArt(for: app), width: plan.tileWidth)
                            .onTapGesture { model.tapApp(app) }
                            .contextMenu { appMenu(app) }
                            .accessibilityAction { model.tapApp(app) }
                    }
                    .padding(.vertical, 16)
                    .animation(.smooth, value: plan)
                }
            }
            .refreshable { model.refreshSelectedHost() }
            .background(FoldProbe(band: $probedFold))
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(model.showHiddenApps ? "Hide Hidden Apps" : "Show Hidden Apps",
                       systemImage: model.showHiddenApps ? "eye.slash" : "eye") {
                    model.setShowHiddenApps(!model.showHiddenApps)
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refreshSelectedHost()
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu("PC Options", systemImage: "desktopcomputer") {
                    HostActions(model: model, host: host)
                }
            }
        }
        .confirmationDialog(model.appActionTarget?.name ?? "",
                            isPresented: Binding(get: { model.appActionTarget != nil },
                                                 set: { if !$0 { model.appActionTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: model.appActionTarget) { app in
            appMenu(app)
        } message: { app in
            if let text = model.menu(for: app)?.message, !text.isEmpty {
                Text(text)
            }
        }
    }

    @ViewBuilder
    private func appMenu(_ app: AppRow) -> some View {
        if let menu = model.menu(for: app) {
            Button(menu.primaryTitle, systemImage: "play.fill") { model.startOrResume(app) }
            if let quit = menu.quitTitle {
                Button(quit, systemImage: "stop.fill", role: .destructive) { model.quit(app) }
            }
            if let hide = menu.hideTitle {
                Button(hide, systemImage: app.hidden ? "eye" : "eye.slash") { model.toggleHidden(app) }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Apps", systemImage: "square.grid.2x2")
        } description: {
            Text(host.paired ? "Apps you add in Sunshine show up here." : "Pair with this PC to see its apps.")
        }
    }
}

// MARK: - Layout plan

struct GridPlan: Equatable {
    var columns: Int
    var tileWidth: CGFloat
    var leadingInset: CGFloat
    var spacing: CGFloat
    /// Width of the hinge gap between the two halves, when the grid spans the fold.
    var foldGap: CGFloat?

    static func make(width: CGFloat, fold: ClosedRange<CGFloat>?, minTile: CGFloat,
                     spacing: CGFloat = 16, margin: CGFloat = 20) -> GridPlan {
        if let fold {
            let left = fold.lowerBound - margin
            let right = width - margin - fold.upperBound
            let side = min(left, right)
            if side >= minTile * 0.8 {
                let perSide = max(1, Int((side + spacing) / (minTile + spacing)))
                let tile = (side - CGFloat(perSide - 1) * spacing) / CGFloat(perSide)
                let group = CGFloat(perSide) * tile + CGFloat(perSide - 1) * spacing
                return GridPlan(columns: perSide * 2, tileWidth: floor(tile),
                                leadingInset: fold.lowerBound - group, spacing: spacing,
                                foldGap: fold.upperBound - fold.lowerBound)
            }
        }
        let usable = max(minTile, width - margin * 2)
        var count = max(2, Int((usable + spacing) / (minTile + spacing)))
        // Even columns divide cleanly if the display folds.
        if count >= 4 { count -= count % 2 }
        let tile = (usable - CGFloat(count - 1) * spacing) / CGFloat(count)
        return GridPlan(columns: count, tileWidth: floor(tile), leadingInset: margin, spacing: spacing, foldGap: nil)
    }
}

struct FoldAwareGrid<Tile: View>: View {
    let plan: GridPlan
    let apps: [AppRow]
    @ViewBuilder let tile: (AppRow) -> Tile

    var body: some View {
        let rows = stride(from: 0, to: apps.count, by: plan.columns).map {
            Array(apps[$0..<min($0 + plan.columns, apps.count)])
        }
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: plan.leadingInset, height: 1)
                    if let gap = plan.foldGap {
                        let half = plan.columns / 2
                        group(Array(row.prefix(half)), count: half)
                        Color.clear.frame(width: gap, height: 1)
                        group(Array(row.dropFirst(half)), count: half)
                    } else {
                        group(row, count: plan.columns)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func group(_ items: [AppRow], count: Int) -> some View {
        HStack(alignment: .top, spacing: plan.spacing) {
            ForEach(items) { tile($0) }
            // Keep partial rows aligned to the grid
            if items.count < count {
                ForEach(0..<(count - items.count), id: \.self) { _ in
                    Color.clear.frame(width: plan.tileWidth, height: 1)
                }
            }
        }
    }
}

// MARK: - Tile

struct AppTile: View {
    let app: AppRow
    let image: UIImage?
    let width: CGFloat

    private var posterHeight: CGFloat { (width / 0.707).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                poster
                    .frame(width: width, height: posterHeight)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)

                if app.running {
                    Label("Running", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular.tint(.green.opacity(0.5)))
                        .padding(8)
                } else if app.hidden {
                    Image(systemName: "eye.slash")
                        .font(.caption.weight(.semibold))
                        .padding(7)
                        .glassEffect(.regular, in: .circle)
                        .padding(8)
                }
            }
            Text(app.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .opacity(app.hidden ? 0.55 : 1)
        .contentShape(.rect)
        .hoverEffect(.lift)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue(app.running ? "Running" : (app.hidden ? "Hidden" : ""))
        .accessibilityHint(app.running ? "Resumes streaming" : "Starts streaming")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var poster: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.42),
                                        Color(red: 0.36, green: 0.16, blue: 0.48)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 10) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: width * 0.22))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(app.name)
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                }
            }
        }
    }
}
