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
}
