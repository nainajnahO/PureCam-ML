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

    /// Where the last focus tap landed, in the viewfinder's own coordinates, plus
    /// a token identifying that tap. The token gives the reticle a fresh SwiftUI
    /// identity per tap, so tapping again restarts the animation instead of
    /// inheriting the previous one's half-faded state.
    private(set) var focusReticle: (point: CGPoint, token: UUID)?

    /// Clears the reticle once it has finished fading; cancelled by a newer tap
    /// so a stale timer cannot dismiss the current one.
    private var focusReticleTask: Task<Void, Never>?

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
            focusReticleTask?.cancel()
            focusReticle = nil
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

    /// Handle a viewfinder tap: focus the lens there and show the reticle.
    ///
    /// Both points come from `CameraPreview`, which is the only place that can
    /// convert between them correctly — `viewPoint` positions the reticle on
    /// screen, `devicePoint` is the normalized sensor point focus needs.
    ///
    /// Exposure is untouched on purpose. See `CameraService.focus(at:)`.
    func focusTapped(viewPoint: CGPoint, devicePoint: CGPoint) {
        cameraService.focus(at: devicePoint)
        hapticManager.impact(.light)

        focusReticleTask?.cancel()
        focusReticle = (point: viewPoint, token: UUID())
        focusReticleTask = Task { [weak self] in
            try? await Task.sleep(for: FocusReticle.lifetime)
            guard let self, !Task.isCancelled else { return }
            self.focusReticle = nil
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
