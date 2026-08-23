// PureLenz - An iOS camera app with AI-powered exposure control
// Copyright (C) 2025 nainajnahO
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI
import Observation

/// ViewModel responsible for camera lifecycle, orientation tracking, and preview management
/// Extracts camera-related business logic from ContentView
@Observable
class CameraViewModel {
    // MARK: - Dependencies

    private let cameraService: CameraService
    private let hapticManager: HapticManager

    // MARK: - State

    /// RAW preview state
    private(set) var showRAWPreview = false
    private(set) var rawPreviewImage: UIImage?
    private(set) var isCapturingPreview = false

    /// Dismisses the RAW preview after its 1-second display; stored so a new
    /// capture (or backgrounding) cancels the previous dismissal instead of
    /// letting it clobber the new preview's state.
    private var previewDismissTask: Task<Void, Never>?

    /// Capture flash effect state
    private(set) var showCaptureFlash = false

    /// Whether the framing-indicator HUD is expanded to show the live full-frame preview.
    private(set) var framingPreviewExpanded = false
    /// Latest full-sensor frame shown in the expanded framing indicator (≈15fps while expanded).
    private(set) var framingPreviewImage: UIImage?
    /// Drives the frame-pull loop; cancelled on collapse and when backgrounding.
    private var framingPreviewTask: Task<Void, Never>?

    /// Fraction of the saved photo's short axis the live viewfinder shows — the
    /// rest is cropped by the preview's aspect-fill. Reported by the preview layer
    /// itself (AVCaptureVideoPreviewLayer), so it is correct on any screen size /
    /// safe-area layout without the app ever measuring the screen. nil until the
    /// layer has laid out and reported.
    private(set) var previewCropFraction: CGFloat?

    /// The water the viewfinder is seen through while focusing. The finger
    /// presses it, the lens settling releases it, and it goes still on its own.
    let water = WaterSurface()

    /// The app-drawn copy of the viewfinder that the water refracts. Non-nil
    /// *only* while the water is moving.
    ///
    /// SwiftUI cannot apply a shader to the live preview — it is a video pane the
    /// system paints straight to the screen, whose pixels SwiftUI never has (see
    /// `WaterRefraction`). So for as long as the water moves the app draws the
    /// camera itself and distorts that instead.
    private(set) var focusRippleFrame: UIImage?

    /// Keeps the copy fed from the first press until the water is still again.
    /// One per calm-to-calm session, however many presses happen inside it.
    private var rippleFramesTask: Task<Void, Never>?

    /// Waits on the lens after a lift, then lets the lit patch at the lift
    /// point fade. A new press cancels it — that press is the focus now.
    private var focusSettleTask: Task<Void, Never>?

    /// What a finger on the viewfinder asked of the camera, reported as it
    /// happens so the light meter can follow the lens (`CameraScene` wires it
    /// to `AutoExposureCoordinator`).
    enum FocusEvent {
        /// A tap: the lens was sent to a point. Fires on the lift.
        case tapped
        /// A hold grabbed a subject: the lens now follows it.
        case subjectGrabbed
        /// The hold went on: the model should keep re-metering the subject.
        case followMeteringArmed
    }
    var onFocusEvent: ((FocusEvent) -> Void)?

    /// How far a hold has got, for the touch currently on the glass.
    private enum HoldStage {
        /// Still a tap, or a hold that found nothing to grab.
        case none
        /// The lens follows a subject.
        case tracking
        /// The lens and the light meter both follow it.
        case following
    }
    private var holdStage = HoldStage.none

    /// Counts down the hold's two stages while the finger stays put. Cancelled
    /// by a lift, or by the finger wandering before the first stage lands.
    private var holdTask: Task<Void, Never>?

    /// Where the finger landed and where it is now, for the hold: the stages
    /// only count down while it stays near where it landed, and the grab is
    /// made where it is when the first stage lands, not where it landed.
    private var touchDownViewPoint = CGPoint.zero
    private var latestDevicePoint = CGPoint.zero

    /// Seconds of holding still before the first stage — a subject is grabbed.
    /// The same wait as the preview button's long press, the app's one other
    /// tap/hold split, so the two holds feel like one gesture.
    private static let holdToTrackSeconds: TimeInterval = 0.5

    /// Seconds of quiet after the first stage lands before anything further
    /// is hinted at. The grab's tap needs to be felt as its own event; a
    /// rumble starting on its heels reads as the tap not having ended.
    private static let holdQuietSeconds: TimeInterval = 0.5

    /// Further seconds of holding, after the quiet, before the second stage —
    /// the light meter starts following the subject too. A rumble swells for
    /// exactly this long, so the stage arrives as its peak. Long enough that
    /// a hold that only wants to track can lift without brushing it.
    private static let holdToFollowMeterSeconds: TimeInterval = 1.0

    /// How far the finger may drift, in points, and still count as holding
    /// still. A finger resting on glass is never perfectly still.
    private static let holdSlopPoints: CGFloat = 12

    /// Long-edge pixels for the frames the water refracts. `nextFramingPreviewImage`
    /// only ever downscales, so this is high enough to leave the video output's
    /// native size alone — the copy standing in for the viewfinder should not be
    /// visibly softer than the viewfinder. This is the effect's main cost dial.
    private static let rippleFrameSize: CGFloat = 2400

    // MARK: - Initialization

    init(cameraService: CameraService, hapticManager: HapticManager) {
        self.cameraService = cameraService
        self.hapticManager = hapticManager
    }

    // MARK: - Lifecycle Management

    /// Handle scene phase changes (active, background, inactive)
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .active {
            cameraService.startSession()
            hapticManager.start()
        } else if newPhase == .background || newPhase == .inactive {
            cameraService.stopSession()
            hapticManager.stop()
            previewDismissTask?.cancel()
            showRAWPreview = false
            rawPreviewImage = nil
            isCapturingPreview = false
            framingPreviewExpanded = false
            stopFramingPreviewLoop()
            rippleFramesTask?.cancel()
            focusSettleTask?.cancel()
            holdTask?.cancel()
            water.reset()
            // Cancelling mid-wave leaves the copy on screen, which would freeze
            // the viewfinder on a stale frame until the next touch.
            focusRippleFrame = nil
            // Release the lens too, not just the marker for it. `.inactive`
            // covers brief interruptions — Control Center, a banner, the app
            // switcher — so leaving focus locked would mean returning to a lens
            // held at a distance with nothing on screen saying so.
            cameraService.releaseFocus()
        }
    }

    /// Setup camera callbacks (call on view appear)
    func setupCamera() {
        cameraService.onPreviewCaptured = { [weak self] image in
            guard let self = self else { return }

            guard let image else {
                // Capture failed — release the preview button instead of
                // leaving it stuck in the in-flight state.
                self.isCapturingPreview = false
                return
            }

            self.rawPreviewImage = image

            // Show preview with animation
            withAnimation(.easeInOut(duration: 0.2)) {
                self.showRAWPreview = true
            }

            // Show for 1 second, fade out, then clear.
            self.previewDismissTask?.cancel()
            self.previewDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.showRAWPreview = false
                }

                // Clear image after the fade-out animation
                try? await Task.sleep(for: .seconds(0.2))
                guard !Task.isCancelled else { return }
                self.rawPreviewImage = nil
                self.isCapturingPreview = false
            }
        }
    }

    // MARK: - Preview Capture Control

    /// Start a preview capture operation. The in-flight state is released by
    /// `onPreviewCaptured` on both success and failure.
    /// - Returns: true if capture was initiated, false if already capturing/showing preview
    func startPreviewCapture() -> Bool {
        guard !isCapturingPreview && !showRAWPreview else {
            return false
        }

        isCapturingPreview = true
        return true
    }

    // MARK: - Capture Flash Animation

    /// Trigger the capture flash animation
    func triggerCaptureFlash() {
        showCaptureFlash = true

        Task {
            try? await Task.sleep(for: .seconds(0.05))
            withAnimation(.easeOut(duration: 0.15)) {
                showCaptureFlash = false
            }
        }
    }

    // MARK: - Framing Indicator

    /// Record the preview layer's reported short-axis crop fraction (see
    /// `CameraPreview`). Drives the framing indicator's yellow crop rectangle.
    func setPreviewCropFraction(_ fraction: CGFloat) {
        previewCropFraction = fraction
    }

    // MARK: - Focus

    /// A finger on the viewfinder, phase by phase: it presses the water on
    /// touch-down, drags the dent while it moves, and on lift lets the water
    /// go and focuses the lens there. The finger is in the water exactly as
    /// long as it is on the glass; only the lit patch at the lift point waits
    /// for the lens, breathing until `settle()` tells it focus has landed —
    /// and even then it finishes the breath it is in before fading, so the
    /// glow always lasts a whole number of breaths.
    ///
    /// A finger that stays put is a hold instead, in two stages, each announced
    /// by its own haptic: half a second grabs the subject under the finger and
    /// the lens follows it; a beat of quiet, then a second more under a
    /// rumble that swells the whole way, and the light meter follows it too.
    /// A hold over nothing the camera recognises stays a tap. Whatever
    /// stage the hold reached persists after the lift — both hands are free
    /// to shoot — until the next tap, or the subject leaves the frame.
    ///
    /// Both points come from `CameraPreview`, which is the only place that can
    /// convert between them correctly — `viewPoint` is where the water is
    /// pressed, `devicePoint` is the normalized sensor point focus needs.
    ///
    /// Exposure is untouched on purpose. See `CameraService.focus(at:)`.
    func focusTouch(_ phase: FocusTouchPhase, viewPoint: CGPoint, devicePoint: CGPoint) {
        switch phase {
        case .began:
            // A new press supersedes a pending settle: this is the focus now.
            focusSettleTask?.cancel()
            let wasCalm = water.isCalm
            water.press(at: viewPoint)
            // One pump per calm-to-calm session. A press during the tail of the
            // last one joins the surface that is already being drawn.
            if wasCalm, !water.isCalm {
                startRippleFrames()
            }
            touchDownViewPoint = viewPoint
            latestDevicePoint = devicePoint
            holdStage = .none
            startHoldCountdown()

        case .moved:
            water.move(to: viewPoint)
            latestDevicePoint = devicePoint
            // A finger on the move is dragging the water, not holding; once a
            // subject is grabbed, though, the finger's position is moot.
            if holdStage == .none,
               hypot(viewPoint.x - touchDownViewPoint.x, viewPoint.y - touchDownViewPoint.y) > Self.holdSlopPoints {
                holdTask?.cancel()
            }

        case .ended:
            holdTask?.cancel()
            // A lift between the stages is the finger declining the second
            // one; the rumble promising it stops with the finger.
            hapticManager.stopRisingRumble()
            water.lift()
            guard holdStage == .none else {
                // The hold already chose; the lift just lets the water go. The
                // lit patch fades on its own, the tracking marker takes over.
                water.settle()
                return
            }
            cameraService.focus(at: devicePoint)
            hapticManager.impact(.light)
            onFocusEvent?(.tapped)
            focusSettleTask = Task { [weak self] in
                guard let self else { return }
                await cameraService.awaitFocusSettled()
                guard !Task.isCancelled else { return }
                water.settle()
            }

        case .cancelled:
            // Nothing was chosen: the water lets go and nothing waits for a
            // lens that was never asked. A hold that had already grabbed keeps
            // what it grabbed — the system took the finger, not the subject.
            holdTask?.cancel()
            hapticManager.stopRisingRumble()
            water.lift()
            water.settle()
        }
    }

    /// Count the hold's stages down while the finger stays on the glass. Each
    /// stage is reached only if the previous one landed: a hold over nothing
    /// recognisable never reaches the first, so it never reaches the second.
    private func startHoldCountdown() {
        holdTask?.cancel()
        hapticManager.prepare(.medium)
        holdTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(Self.holdToTrackSeconds))
            guard !Task.isCancelled else { return }
            guard await cameraService.beginTracking(at: latestDevicePoint) else { return }
            guard !Task.isCancelled else { return }
            holdStage = .tracking
            hapticManager.impact(.medium)
            onFocusEvent?(.subjectGrabbed)

            // A beat of quiet, then the wait for the second stage is felt: a
            // rumble swells under the finger for exactly that long, so the
            // impact that ends it arrives as a peak rather than a surprise.
            try? await Task.sleep(for: .seconds(Self.holdQuietSeconds))
            guard !Task.isCancelled else { return }
            hapticManager.prepare(.heavy)
            hapticManager.startRisingRumble(over: Self.holdToFollowMeterSeconds)
            try? await Task.sleep(for: .seconds(Self.holdToFollowMeterSeconds))
            guard !Task.isCancelled else { return }
            holdStage = .following
            hapticManager.impact(.heavy)
            onFocusEvent?(.followMeteringArmed)
        }
    }

    /// Hold a refracted copy of the viewfinder over the real one for as long as
    /// the water moves, then hand the viewfinder back to the system.
    ///
    /// The frame pipeline is woken only for this window. `captureOutput` does no
    /// per-frame work unless a request is pending (`CameraService.swift`), so
    /// pulling frames here and stopping at the end leaves the camera exactly as
    /// idle as it was before the touch — the effect costs nothing while nobody
    /// is touching.
    ///
    /// Frames are pulled live rather than one being frozen, so the lens is seen
    /// racking focus through the water. Freezing would hide the very thing the
    /// touch was asking for.
    private func startRippleFrames() {
        rippleFramesTask?.cancel()
        rippleFramesTask = Task { [weak self] in
            while let self, !Task.isCancelled, !water.isCalm {
                // A nil frame means the session is not running; there is
                // nothing to draw a copy of, and the live preview shows through.
                guard let frame = await cameraService.nextFramingPreviewImage(
                    maxDimension: Self.rippleFrameSize
                ) else { break }
                guard !Task.isCancelled else { return }
                focusRippleFrame = frame
            }
            guard !Task.isCancelled else { return }
            self?.focusRippleFrame = nil
        }
    }

    /// Toggle the framing-indicator HUD between the small outline schematic and
    /// the expanded live full-frame preview, starting/stopping the frame loop.
    func toggleFramingPreview() {
        withAnimation(.easeInOut(duration: 0.2)) {
            framingPreviewExpanded.toggle()
        }
        if framingPreviewExpanded {
            startFramingPreviewLoop()
        } else {
            stopFramingPreviewLoop()
        }
    }

    /// Continuously pull full-sensor frames from the camera's video output and
    /// publish them for the expanded indicator. Uses the existing on-demand frame
    /// API (no second preview layer), so it never disturbs the main viewfinder.
    private func startFramingPreviewLoop() {
        framingPreviewTask?.cancel()
        framingPreviewTask = Task { [weak self] in
            while let self, self.framingPreviewExpanded, !Task.isCancelled {
                let image = await self.cameraService.nextFramingPreviewImage(maxDimension: 400)
                if Task.isCancelled { break }
                self.framingPreviewImage = image
                // ~15fps is plenty for a framing diagnostic; caps CPU and SwiftUI churn.
                try? await Task.sleep(for: .seconds(0.066))
            }
        }
    }

    private func stopFramingPreviewLoop() {
        framingPreviewTask?.cancel()
        framingPreviewTask = nil
        framingPreviewImage = nil
    }
}
