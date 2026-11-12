import AppKit
import SwiftUI

/// Layout overflow audit: finds every panel section whose content is wider
/// than its side pane — the rows that make a pane cut its labels off.
/// (A row that can't shrink widens every frame around it, up to the
/// scroll view's content, which the scroll view then centers: labels lose
/// their first letters on the left and units on the right.)
///
/// Off unless the app is launched with `REFAB_LAYOUT_AUDIT=<report
/// path>`. Then ContentView walks every construction technique and inspector
/// tab with both side panes at their narrowest, the probes record each
/// section's width and each pane's visible width, and the report lists every
/// section wider than its pane's content area.
enum LayoutOverflowAudit {
    static let reportPath = ProcessInfo.processInfo.environment["REFAB_LAYOUT_AUDIT"]
    static var isEnabled: Bool { reportPath != nil }

    /// Pane widths the audit lays out at (rail, inspector), pt; default the
    /// panes' minimums. `REFAB_LAYOUT_AUDIT_WIDTHS=270,264` overrides.
    static let paneWidths: (rail: CGFloat, inspector: CGFloat) = {
        let parts = (ProcessInfo.processInfo.environment["REFAB_LAYOUT_AUDIT_WIDTHS"] ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 2 ? (CGFloat(parts[0]), CGFloat(parts[1])) : (320, 300)
    }()

    /// What the audit is showing right now ("mode=stacked tab=object").
    @MainActor static var context = ""
    /// [context: [pane: visible content width]]
    @MainActor private static var measuredPaneWidths: [String: [String: CGFloat]] = [:]
    /// [context: [pane/section: laid-out width]]
    @MainActor private static var sectionWidths: [String: [String: (pane: String, width: CGFloat)]] = [:]

    /// Latest content width per pane (a `PaneColumn` never grows with its
    /// content, so this is the width every section must fit in).
    @MainActor private static var latestPaneWidths: [String: CGFloat] = [:]

    @MainActor static func recordPane(_ pane: String, contentWidth: CGFloat) {
        guard isEnabled, contentWidth > 1 else { return }
        measuredPaneWidths[context, default: [:]][pane] = contentWidth
        latestPaneWidths[pane] = contentWidth
    }

    @MainActor static func recordSection(_ name: String, pane: String, width: CGFloat) {
        guard isEnabled, width > 1 else { return }
        sectionWidths[context, default: [:]]["\(pane)/\(name)"] = (pane, width)
    }

    /// Every section wider than its pane's content area, one line each.
    @MainActor static func findings() -> [String] {
        var lines: [String] = []
        for (ctx, sections) in sectionWidths {
            for (name, entry) in sections {
                guard let available = measuredPaneWidths[ctx]?[entry.pane] ?? latestPaneWidths[entry.pane],
                      entry.width > available + 0.5 else { continue }
                lines.append(String(format: "%@ | %@ | %.1f wide in %.1f (+%.1f)",
                                    name, ctx, entry.width, available, entry.width - available))
            }
        }
        return lines.sorted()
    }

    /// Write the findings to the report path; returns how many.
    @MainActor @discardableResult
    static func writeReport() -> Int {
        guard let reportPath else { return 0 }
        let lines = findings()
        let contexts = sectionWidths.keys.sorted().joined(separator: ", ")
        var detail: [String] = []
        if ProcessInfo.processInfo.environment["REFAB_LAYOUT_AUDIT_VERBOSE"] == "1" {
            for ctx in sectionWidths.keys.sorted() {
                let panes = (measuredPaneWidths[ctx] ?? [:]).map { "\($0.key)=\(Int($0.value))" }.sorted().joined(separator: " ")
                detail.append("## \(ctx)  panes: \(panes)")
                for (name, e) in (sectionWidths[ctx] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    detail.append("   \(name): \(String(format: "%.1f", e.width))")
                }
            }
        }
        let text = (["layout overflow audit: \(lines.count) overflow(s) across \(sectionWidths.count) state(s): \(contexts)"] + lines + detail)
            .joined(separator: "\n") + "\n"
        try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
        return lines.count
    }
}

private struct OverflowPaneKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The side pane a view sits in, for the layout overflow audit.
    var overflowPane: String {
        get { self[OverflowPaneKey.self] }
        set { self[OverflowPaneKey.self] = newValue }
    }
}

/// Records this section's laid-out width (audit only).
private struct OverflowSectionProbe: ViewModifier {
    let name: String
    @Environment(\.overflowPane) private var pane

    func body(content: Content) -> some View {
        if LayoutOverflowAudit.isEnabled {
            content.background(GeometryReader { g in
                Color.clear
                    .onAppear { LayoutOverflowAudit.recordSection(name, pane: pane, width: g.size.width) }
                    .onChange(of: g.size.width) { _, w in LayoutOverflowAudit.recordSection(name, pane: pane, width: w) }
            })
        } else {
            content
        }
    }
}

extension View {
    /// Report this section's width to the layout overflow audit (no effect
    /// unless the audit is running).
    func overflowProbe(_ name: String) -> some View {
        modifier(OverflowSectionProbe(name: name))
    }
}

/// A side pane's scrolling column, laid out at exactly the pane's width
/// minus its padding. A row that can't shrink then overflows only itself
/// (and the layout audit reports it) instead of widening the whole column —
/// which the scroll view would center, cutting the first letters off every
/// label on the left and the units off on the right.
struct PaneColumn<Content: View>: View {
    let name: String
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let inner = max(0, geo.size.width - 2 * horizontalPadding)
            ScrollView {
                content()
                    .frame(width: inner, alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
            }
            .environment(\.overflowPane, name)
            .onAppear { LayoutOverflowAudit.recordPane(name, contentWidth: inner) }
            .onChange(of: inner) { _, w in LayoutOverflowAudit.recordPane(name, contentWidth: w) }
        }
    }
}

/// Keeps a split-view pane from being dragged or squeezed narrower than
/// `minWidth`, by pinning a width constraint on the split view's own
/// subview. A child's `.frame(minWidth:)` alone isn't a guarantee for the
/// HSplitView divider, and a pane narrower than its laid-out content gets
/// centered in its slot — cutting labels off on both sides.
struct SplitPaneMinimumWidth: NSViewRepresentable {
    let minWidth: CGFloat

    func makeNSView(context: Context) -> Anchor { Anchor(minWidth: minWidth) }

    func updateNSView(_ view: Anchor, context: Context) {
        view.minWidth = minWidth
        view.install()
    }

    final class Anchor: NSView {
        var minWidth: CGFloat
        private weak var pane: NSView?
        private var constraint: NSLayoutConstraint?

        init(minWidth: CGFloat) {
            self.minWidth = minWidth
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        func install() {
            // The ancestor that is a direct subview of the split view.
            var node: NSView? = self
            while let current = node, let parent = current.superview, !(parent is NSSplitView) {
                node = parent
            }
            guard let found = node, found.superview is NSSplitView else { return }
            if pane === found, let constraint {
                constraint.constant = minWidth
                return
            }
            constraint?.isActive = false
            let c = found.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
            c.priority = NSLayoutConstraint.Priority(999)
            c.isActive = true
            constraint = c
            pane = found
        }
    }
}
