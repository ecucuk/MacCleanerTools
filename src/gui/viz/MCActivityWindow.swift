// The SwiftUI "Activity" window: a live visualization of scan and clean
// operations, fed by MCMainWindowController through the @objc MCActivityBridge
// class below. Data flows one way (AppKit -> Swift); the two buttons flow the
// other way as plain callback blocks, so the delete path -- confirmation
// alert, safety re-validation, the clean itself -- stays entirely on the
// AppKit/C++ side and this file never touches the filesystem.
//
// Compiled as its own static library (maccleaner_viz); the generated
// MacCleanerViz-Swift.h header is what MCMainWindowController.mm imports.

import AppKit
import SwiftUI

// MARK: - View model

private enum Phase: Equatable {
    case idle
    case scanning(current: String)
    case cleaning
}

private struct CategoryRow: Identifiable, Equatable {
    let id: String // label; unique per scan by construction (one row per category)
    var name: String
    var path: String
    var bytes: UInt64
    var entryCount: Int
    var scanning: Bool
}

private struct LogLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var kind: Kind
    enum Kind { case ok, skip, fail }
}

private final class ActivityState: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var rows: [CategoryRow] = []
    @Published var totalBytes: UInt64 = 0

    @Published var cleanItemsDone = 0
    @Published var cleanItemsTotal = 0
    @Published var cleanBytesFreed: UInt64 = 0
    @Published var cleanBytesPlanned: UInt64 = 0
    @Published var cleanPermanent = false
    @Published var log: [LogLine] = []
    @Published var lastFreedSummary: String?

    @Published var selectedCount = 0
    @Published var selectedBytes: UInt64 = 0

    var onRescan: (() -> Void)?
    var onClean: (() -> Void)?
}

private func humanBytes(_ bytes: UInt64) -> String {
    // Same 1024-based magnitudes and labels as the C++ humanReadableBytes, so
    // this window never disagrees with the main window or the CLI.
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit + 1 < units.count {
        value /= 1024
        unit += 1
    }
    return unit == 0 ? "\(Int(value)) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
}

// MARK: - Views

private struct CategoryBarsView: View {
    @ObservedObject var state: ActivityState

    private var maxBytes: UInt64 { max(state.rows.map(\.bytes).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.rows) { row in
                HStack(spacing: 8) {
                    if row.scanning {
                        ProgressView().controlSize(.small).frame(width: 14)
                    } else {
                        Image(systemName: row.bytes > 0 ? "folder.fill" : "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(row.entryCount > 0 ? "\(row.entryCount) items · \(humanBytes(row.bytes))"
                                                     : humanBytes(row.bytes))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule()
                                    .fill(row.scanning ? AnyShapeStyle(.tint.opacity(0.5))
                                                        : AnyShapeStyle(.tint))
                                    .frame(width: max(3, geo.size.width * CGFloat(row.bytes) / CGFloat(maxBytes)))
                            }
                        }
                        .frame(height: 6)
                        .animation(.spring(duration: 0.5), value: row.bytes)
                        .animation(.spring(duration: 0.5), value: maxBytes)
                    }
                }
                .opacity(row.scanning || row.bytes > 0 ? 1 : 0.5)
            }
        }
    }
}

private struct CleanProgressView: View {
    @ObservedObject var state: ActivityState

    private var fraction: Double {
        state.cleanItemsTotal == 0 ? 0 : Double(state.cleanItemsDone) / Double(state.cleanItemsTotal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.cleanPermanent ? "xmark.bin.fill" : "trash.fill")
                    .foregroundStyle(state.cleanPermanent ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                Text(state.cleanPermanent ? "Deleting permanently" : "Moving to Trash")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(state.cleanItemsDone) / \(state.cleanItemsTotal)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .animation(.easeOut(duration: 0.25), value: fraction)
            HStack {
                Text("Freed \(humanBytes(state.cleanBytesFreed))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.default, value: state.cleanBytesFreed)
                Text("of \(humanBytes(state.cleanBytesPlanned)) planned")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CleanLogView: View {
    @ObservedObject var state: ActivityState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.log) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            switch line.kind {
                            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .skip: Image(systemName: "shield.slash").foregroundStyle(.orange)
                            case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            }
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: state.log.count) {
                if let last = state.log.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

private struct ActivityRootView: View {
    @ObservedObject var state: ActivityState

    private var headerText: String {
        switch state.phase {
        case .idle:
            if let summary = state.lastFreedSummary {
                return summary
            }
            return state.totalBytes > 0 ? "Reclaimable: \(humanBytes(state.totalBytes))" : "Ready"
        case .scanning(let current):
            return "Scanning \(current)…"
        case .cleaning:
            return "Cleaning…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                switch state.phase {
                case .idle:
                    Image(systemName: "internaldrive").foregroundStyle(.tint)
                case .scanning:
                    ProgressView().controlSize(.small)
                case .cleaning:
                    ProgressView().controlSize(.small)
                }
                Text(headerText)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
                Spacer()
            }

            if state.phase == .cleaning || state.cleanItemsTotal > 0 {
                CleanProgressView(state: state)
                CleanLogView(state: state)
                    .frame(minHeight: 90, maxHeight: 160)
            }

            ScrollView {
                CategoryBarsView(state: state)
                    .padding(.vertical, 2)
            }

            Divider()

            HStack {
                Text(state.selectedCount == 0
                     ? "Nothing selected"
                     : "\(state.selectedCount) selected · \(humanBytes(state.selectedBytes))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(state.selectedCount == 0 ? .secondary : .primary)
                Spacer()
                Button("Rescan") { state.onRescan?() }
                    .disabled(state.phase != .idle)
                Button("Clean Selected…") { state.onClean?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.phase != .idle || state.selectedCount == 0)
            }
        }
        .padding(14)
        .frame(minWidth: 380, minHeight: 420)
    }
}

// MARK: - @objc bridge

@objc(MCActivityBridge)
public final class MCActivityBridge: NSObject {
    private let state = ActivityState()
    private var window: NSWindow?

    /// Called when the user presses Rescan in this window.
    @objc public var onRescanRequested: (() -> Void)? {
        get { state.onRescan }
        set { state.onRescan = newValue }
    }

    /// Called when the user presses "Clean Selected…" in this window. The
    /// receiver is expected to run its own confirmation before deleting.
    @objc public var onCleanRequested: (() -> Void)? {
        get { state.onClean }
        set { state.onClean = newValue }
    }

    /// Shows (creating on first use) the activity window. `relativeTo` places
    /// it beside that window the first time; pass nil to center.
    @objc(showWindowRelativeTo:) public func showWindow(relativeTo other: NSWindow?) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: ActivityRootView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Activity"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 420, height: 560))
        window.isReleasedWhenClosed = false

        if let other, let screen = other.screen {
            let gap: CGFloat = 12
            var origin = NSPoint(x: other.frame.maxX + gap, y: other.frame.maxY - window.frame.height)
            if origin.x + window.frame.width > screen.visibleFrame.maxX {
                origin.x = max(screen.visibleFrame.minX, other.frame.minX - gap - window.frame.width)
            }
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Scan events (all main-thread, as MCScanModel guarantees)

    @objc public func scanBegan() {
        state.rows.removeAll()
        state.totalBytes = 0
        state.lastFreedSummary = nil
        state.phase = .scanning(current: "")
    }

    @objc public func categoryScanBegan(label: String, path: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            state.rows.append(CategoryRow(id: label, name: label, path: path,
                                           bytes: 0, entryCount: 0, scanning: true))
            state.phase = .scanning(current: label)
        }
    }

    @objc public func categoryScanFinished(label: String, bytes: UInt64, entryCount: Int) {
        guard let index = state.rows.firstIndex(where: { $0.id == label }) else { return }
        withAnimation(.spring(duration: 0.5)) {
            state.rows[index].scanning = false
            state.rows[index].bytes = bytes
            state.rows[index].entryCount = entryCount
            state.totalBytes += bytes
        }
    }

    @objc public func scanFinished() {
        withAnimation(.easeOut(duration: 0.3)) {
            // Empty categories linger greyed-out during the scan so the user
            // sees them being visited; once it's over they're just noise.
            state.rows.removeAll { $0.bytes == 0 }
            state.phase = .idle
        }
    }

    // MARK: Clean events

    @objc public func cleanBegan(itemsTotal: Int, bytesPlanned: UInt64, permanent: Bool) {
        state.log.removeAll()
        state.cleanItemsDone = 0
        state.cleanItemsTotal = itemsTotal
        state.cleanBytesFreed = 0
        state.cleanBytesPlanned = bytesPlanned
        state.cleanPermanent = permanent
        state.lastFreedSummary = nil
        state.phase = .cleaning
    }

    @objc public func cleanItemFinished(path: String, succeeded: Bool, skippedBySafety: Bool,
                                         message: String, bytesFreedSoFar: UInt64, itemsDone: Int) {
        state.cleanItemsDone = itemsDone
        state.cleanBytesFreed = bytesFreedSoFar

        let kind: LogLine.Kind = succeeded ? .ok : (skippedBySafety ? .skip : .fail)
        let name = (path as NSString).lastPathComponent
        let text = succeeded ? name : "\(name) — \(message)"
        state.log.append(LogLine(text: text, kind: kind))
        // The log is a live tail, not an archive; the summary alert in the
        // main window lists every problem afterwards.
        if state.log.count > 500 {
            state.log.removeFirst(state.log.count - 500)
        }
    }

    @objc public func cleanFinished(bytesFreed: UInt64) {
        withAnimation(.easeOut(duration: 0.3)) {
            state.phase = .idle
            state.lastFreedSummary = "Freed \(humanBytes(bytesFreed))"
        }
    }

    // MARK: Selection

    @objc public func selectionChanged(count: Int, bytes: UInt64) {
        state.selectedCount = count
        state.selectedBytes = bytes
    }
}
