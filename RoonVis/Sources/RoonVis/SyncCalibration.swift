import SwiftUI
import UIKit

/// Live readout state for the calibration chrome. Updated only on nudges (and
/// the waiting-hint timer) — never per frame — so SwiftUI re-render cost stays
/// out of the render loop.
@MainActor
final class SyncCalibrationModel: ObservableObject {
    @Published var delayMs: Int = 0
    @Published var waitingForOnsets = false
}

private struct SyncCalibrationChromeView: View {
    @ObservedObject var model: SyncCalibrationModel

    var body: some View {
        VStack(spacing: RVTheme.Spacing.l) {
            Text("Sync Calibration")
                .font(RVTheme.Fonts.title)
                .foregroundStyle(RVTheme.Colors.primaryText)

            Text("\(model.delayMs) ms")
                .font(.system(size: 96, weight: .semibold, design: .monospaced))
                .foregroundStyle(RVTheme.Colors.primaryText)

            Text("Nudge until the pulse matches what you hear.")
                .font(RVTheme.Fonts.body)
                .foregroundStyle(RVTheme.Colors.secondaryText)

            if model.waitingForOnsets {
                Text("Waiting for bass hits — play rhythmic music in Roon.")
                    .font(RVTheme.Fonts.caption)
                    .foregroundStyle(RVTheme.Colors.accent)
            }

            Text("◀ ▶ ±5 ms · ▲ ▼ ±25 ms · Select saves · Menu cancels")
                .font(RVTheme.Fonts.caption)
                .foregroundStyle(RVTheme.Colors.secondaryText)
        }
        .padding(RVTheme.Spacing.xl)
    }
}

/// Full-screen calibration overlay. UIKit controller so remote presses are
/// captured natively while the modal owns focus; the onset pulse is a plain
/// UIView animated directly from the render loop (same thread).
@objc final class SyncCalibrationViewController: UIViewController {
    /// tvOS routes remote presses through the focused view's responder chain;
    /// a modal whose views are all non-focusable leaves focus on the visualizer
    /// beneath it (so left/right would change presets). A focusable root view
    /// anchors focus inside the modal and delivers presses to this controller.
    private final class FocusableRootView: UIView {
        override var canBecomeFocused: Bool { true }
    }

    private let model = SyncCalibrationModel()
    private let pulseView = UIView()
    private var waitingTimer: Timer?
    private var lastOnsetAt = Date()

    /// Called on nudge/save/cancel; wired by the factory to ANGLEGLView.
    @objc var onNudge: ((NSInteger) -> Void)?
    @objc var onSave: (() -> Void)?
    @objc var onCancel: (() -> Void)?
    @objc var initialDelayMs: NSInteger = 0

    private var draftMs: Int = 0

    override func loadView() {
        view = FocusableRootView()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [view] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.7) // visuals dim through

        draftMs = initialDelayMs
        model.delayMs = draftMs
        model.waitingForOnsets = true

        // Onset pulse: a centered ring that flashes on each detected bass hit.
        let ringSize: CGFloat = 420
        pulseView.frame = CGRect(x: 0, y: 0, width: ringSize, height: ringSize)
        pulseView.layer.cornerRadius = ringSize / 2
        pulseView.layer.borderColor = UIColor.white.cgColor
        pulseView.layer.borderWidth = 14
        pulseView.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        pulseView.alpha = 0.0
        pulseView.isUserInteractionEnabled = false
        view.addSubview(pulseView)

        let chrome = UIHostingController(rootView: SyncCalibrationChromeView(model: model))
        chrome.view.backgroundColor = .clear
        addChild(chrome)
        view.addSubview(chrome.view)
        chrome.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chrome.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chrome.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -120),
        ])
        chrome.didMove(toParent: self)

        // Surface the waiting hint when onsets stop arriving for a while.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let waiting = Date().timeIntervalSince(self.lastOnsetAt) > 4.0
                if self.model.waitingForOnsets != waiting {
                    self.model.waitingForOnsets = waiting
                }
            }
        }
        timer.tolerance = 0.25
        waitingTimer = timer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pulseView.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY - 80)
    }

    deinit {
        waitingTimer?.invalidate()
    }

    /// Fired from the render loop (main thread) when an onset landed in the
    /// samples rendered this frame.
    @objc func pulseOnset() {
        lastOnsetAt = Date()
        if model.waitingForOnsets {
            model.waitingForOnsets = false
        }
        pulseView.layer.removeAllAnimations()
        pulseView.alpha = 0.9
        pulseView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.pulseView.alpha = 0.0
            self.pulseView.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
        }
    }

    private func nudge(_ deltaMs: Int) {
        draftMs = max(0, min(500, draftMs + deltaMs))
        model.delayMs = draftMs
        onNudge?(draftMs)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:
                nudge(-5)
                handled = true
            case .rightArrow:
                nudge(5)
                handled = true
            case .upArrow:
                nudge(25)
                handled = true
            case .downArrow:
                nudge(-25)
                handled = true
            case .select, .playPause:
                onSave?()
                handled = true
            case .menu:
                onCancel?()
                handled = true
            default:
                break
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }
}

@objc final class SyncCalibrationFactory: NSObject {
    @objc(makeWithGlView:)
    @MainActor
    static func make(glView: ANGLEGLView) -> SyncCalibrationViewController {
        let controller = SyncCalibrationViewController()
        controller.initialDelayMs = glView.bridge?.syncCalibrationDelayMs ?? 0
        controller.onNudge = { [weak glView] ms in
            glView?.bridge?.setSyncCalibrationDelayMs(ms)
        }
        controller.onSave = { [weak glView] in
            glView?.dismissSyncCalibrationSaving(true)
        }
        controller.onCancel = { [weak glView] in
            glView?.dismissSyncCalibrationSaving(false)
        }
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        return controller
    }
}
