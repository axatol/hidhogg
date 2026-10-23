import AppKit
import SwiftUI

@MainActor
struct WorkspaceInspectorInitialWidthAdapter: NSViewRepresentable {
    let targetWidth: CGFloat

    func makeNSView(context: Context) -> WorkspaceInspectorInitialWidthView {
        WorkspaceInspectorInitialWidthView(targetWidth: targetWidth)
    }

    func updateNSView(_ nsView: WorkspaceInspectorInitialWidthView, context: Context) {}

    static func dismantleNSView(
        _ nsView: WorkspaceInspectorInitialWidthView,
        coordinator: ()
    ) {
        nsView.cancelPendingSizing()
    }
}

@MainActor
final class WorkspaceInspectorInitialWidthView: NSView {
    private let targetWidth: CGFloat
    private var sizingTask: Task<Void, Never>?
    private var sizingGeneration = UUID()
    private var sizingAttempts = 0
    private let maximumSizingAttempts = 8
    private var hasAppliedInitialWidth = false

    init(targetWidth: CGFloat) {
        self.targetWidth = targetWidth
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize { .zero }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            cancelPendingSizing()
            return
        }
        scheduleSizingAttempt()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else {
            cancelPendingSizing()
            return
        }
        scheduleSizingAttempt()
    }

    override func layout() {
        super.layout()
        scheduleSizingAttempt()
    }

    func cancelPendingSizing() {
        sizingGeneration = UUID()
        sizingTask?.cancel()
        sizingTask = nil
    }

    private func scheduleSizingAttempt() {
        guard
            !hasAppliedInitialWidth,
            sizingAttempts < maximumSizingAttempts,
            sizingTask == nil,
            window != nil,
            superview != nil
        else {
            return
        }

        let generation = sizingGeneration
        sizingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }

            guard let self, self.sizingGeneration == generation else { return }
            guard !self.hasAppliedInitialWidth else {
                self.sizingTask = nil
                return
            }
            guard self.window != nil, self.superview != nil else {
                self.sizingTask = nil
                return
            }

            self.sizingAttempts += 1
            self.hasAppliedInitialWidth = self.applyInitialWidth()
            self.sizingTask = nil

            if !self.hasAppliedInitialWidth {
                self.scheduleSizingAttempt()
            }
        }
    }

    private func applyInitialWidth() -> Bool {
        guard let pane = trailingPaneAndDivider() else { return false }

        let splitView = pane.splitView
        splitView.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()

        let dividerThickness = splitView.dividerThickness
        guard
            splitView.bounds.width.isFinite,
            splitView.bounds.width > targetWidth + dividerThickness,
            pane.view.frame.width > 0
        else {
            return false
        }

        let minimumPosition = splitView.minPossiblePositionOfDivider(at: pane.dividerIndex)
        let maximumPosition = splitView.maxPossiblePositionOfDivider(at: pane.dividerIndex)
        guard
            minimumPosition.isFinite,
            maximumPosition.isFinite,
            minimumPosition <= maximumPosition
        else {
            return false
        }

        let requestedPosition = splitView.bounds.maxX - targetWidth - dividerThickness
        let position = Swift.min(Swift.max(requestedPosition, minimumPosition), maximumPosition)
        splitView.setPosition(position, ofDividerAt: pane.dividerIndex)
        return true
    }

    private func trailingPaneAndDivider() -> (splitView: NSSplitView, view: NSView, dividerIndex: Int)? {
        var candidate: NSView = self

        while let parent = candidate.superview {
            if let splitView = parent as? NSSplitView {
                let panes = splitView.arrangedSubviews
                guard
                    splitView.isVertical,
                    panes.count > 1,
                    let paneIndex = panes.firstIndex(where: { $0 === candidate }),
                    paneIndex == panes.count - 1
                else {
                    return nil
                }

                return (splitView, candidate, paneIndex - 1)
            }

            candidate = parent
        }

        return nil
    }
}
