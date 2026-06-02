// PureCam - An iOS camera app with AI-powered exposure control
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
import CoreMotion

/// ViewModel responsible for camera lifecycle, orientation tracking, and preview management
/// Extracts camera-related business logic from ContentView
@Observable
class CameraViewModel {
    // MARK: - Dependencies

    private let cameraService: CameraService
    private let hapticManager: HapticManager

    /// Reads the motion sensors directly to derive device orientation. Unlike
    /// `UIDevice` orientation notifications — which are suppressed while Control
    /// Center's rotation lock is on (verified on-device) — Core Motion is
    /// unaffected by the lock, the same reason capture orientation works under it.
    private let motionManager = CMMotionManager()

    // MARK: - State

    /// Current device orientation
    private(set) var deviceOrientation: UIDeviceOrientation = .portrait

    /// RAW preview state
    private(set) var showRAWPreview = false
    private(set) var rawPreviewImage: UIImage?
    private(set) var isCapturingPreview = false

    /// Capture flash effect state
    private(set) var showCaptureFlash = false

    // MARK: - Initialization

    init(cameraService: CameraService, hapticManager: HapticManager) {
        self.cameraService = cameraService
        self.hapticManager = hapticManager
    }

    // MARK: - Lifecycle Management

    /// Handle scene phase changes (active, background, inactive)
    func handleScenePhaseChange(_ newPhase: ScenePhase, autoExposureManager: AutoExposureManager?) {
        if newPhase == .active {
            cameraService.startSession()
            hapticManager.start()
            startOrientationUpdates()
            autoExposureManager?.resetForNewSession()
        } else if newPhase == .background || newPhase == .inactive {
            cameraService.stopSession()
            hapticManager.stop()
            stopOrientationUpdates()
            showRAWPreview = false
            rawPreviewImage = nil
            isCapturingPreview = false
        }
    }

    /// Setup camera callbacks (call on view appear)
    func setupCamera() {
        cameraService.onPreviewCaptured = { [weak self] image in
            guard let self = self else { return }

            self.rawPreviewImage = image

            // Show preview with animation
            withAnimation(.easeInOut(duration: 0.2)) {
                self.showRAWPreview = true
            }

            // Hide preview after 1 second
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.showRAWPreview = false
                }

                // Clear image after animation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.rawPreviewImage = nil
                    self.isCapturingPreview = false
                }
            }
        }
    }

    // MARK: - Preview Capture Control

    /// Start a preview capture operation
    /// - Returns: true if capture was initiated, false if already capturing/showing preview
    func startPreviewCapture() -> Bool {
        guard !isCapturingPreview && !showRAWPreview else {
            return false
        }

        isCapturingPreview = true
        schedulePreviewCaptureTimeout()
        return true
    }

    /// Failsafe timeout to prevent stuck state
    private func schedulePreviewCaptureTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }

            if self.isCapturingPreview && !self.showRAWPreview {
                self.isCapturingPreview = false
            }
        }
    }

    /// Setup device orientation tracking (call on view appear)
    func setupOrientationTracking() {
        startOrientationUpdates()
    }

    /// Start deriving device orientation from the gravity vector. Idempotent —
    /// safe to call again when returning to the foreground.
    private func startOrientationUpdates() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 0.2  // ~5 Hz is plenty for orientation
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }

            // Near-flat (phone face up/down): the horizontal gravity component is
            // too small to distinguish portrait from landscape, so keep the last
            // orientation — matching the previous .faceUp/.faceDown drop.
            guard hypot(gravity.x, gravity.y) > 0.3 else { return }

            let orientation: UIDeviceOrientation
            if abs(gravity.y) >= abs(gravity.x) {
                orientation = gravity.y <= 0 ? .portrait : .portraitUpsideDown
            } else {
                orientation = gravity.x > 0 ? .landscapeRight : .landscapeLeft
            }

            if orientation != self.deviceOrientation {
                self.deviceOrientation = orientation
            }
        }
    }

    private func stopOrientationUpdates() {
        motionManager.stopDeviceMotionUpdates()
    }

    // MARK: - Capture Flash Animation

    /// Trigger the capture flash animation
    func triggerCaptureFlash() {
        showCaptureFlash = true

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
            withAnimation(.easeOut(duration: 0.15)) {
                showCaptureFlash = false
            }
        }
    }

    // MARK: - Cleanup

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }
}
