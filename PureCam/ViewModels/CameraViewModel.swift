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
            autoExposureManager?.resetForNewSession()
        } else if newPhase == .background || newPhase == .inactive {
            cameraService.stopSession()
            hapticManager.stop()
            showRAWPreview = false
            rawPreviewImage = nil
            isCapturingPreview = false
            framingPreviewExpanded = false
            stopFramingPreviewLoop()
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

    // MARK: - Framing Indicator

    /// Record the preview layer's reported short-axis crop fraction (see
    /// `CameraPreview`). Drives the framing indicator's yellow crop rectangle.
    func setPreviewCropFraction(_ fraction: CGFloat) {
        previewCropFraction = fraction
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
                try? await Task.sleep(nanoseconds: 66_000_000)
            }
        }
    }

    private func stopFramingPreviewLoop() {
        framingPreviewTask?.cancel()
        framingPreviewTask = nil
        framingPreviewImage = nil
    }
}
