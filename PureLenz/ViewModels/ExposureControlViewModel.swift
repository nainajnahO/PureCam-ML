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

/// ViewModel responsible for manual exposure control (ISO & shutter speed)
/// Handles rotation gestures, haptic feedback, and velocity tracking
@Observable
class ExposureControlViewModel {
    // MARK: - Dependencies

    private let cameraService: CameraService
    private let hapticManager: HapticManager
    private let autoExposureManager: AutoExposureManager

    // MARK: - State

    /// Current rotation angle for ISO control (inner dot)
    private(set) var isoRotationAngle: Angle = .zero

    /// Current rotation angle for shutter control (outer dot)
    private(set) var shutterRotationAngle: Angle = .zero

    /// Last discrete ISO value (for haptic change detection)
    private var lastDiscreteISO: Float = 0

    /// Active control (ISO or shutter)
    private(set) var activeControl: ExposureControl? = nil

    /// Velocity tracking for shutter rumble intensity
    private var lastDragTime: Date = .distantPast
    private var lastDragAngle: Double = 0.0

    // MARK: - Initialization

    init(
        cameraService: CameraService,
        hapticManager: HapticManager,
        autoExposureManager: AutoExposureManager
    ) {
        self.cameraService = cameraService
        self.hapticManager = hapticManager
        self.autoExposureManager = autoExposureManager
    }

    // MARK: - Public Methods

    /// Update ISO based on drag gesture progress
    /// - Parameter progress: Progress value (0-1) representing rotation around the circle
    func updateISO(progress: Double) {
        // A manual adjustment takes over from the AI prediction for the session.
        autoExposureManager.notifyManualOverride()

        // Map progress to ISO logarithmically using ExposureCalculator
        let continuousISO = ExposureCalculator.isoFromProgress(
            progress,
            min: cameraService.minISO,
            max: cameraService.maxISO
        )

        // Round to nearest discrete ISO value
        let newISO = cameraService.roundToNearestISO(continuousISO)

        // Trigger haptic when discrete ISO value changes
        if newISO != lastDiscreteISO {
            lastDiscreteISO = newISO
            hapticManager.playISOClick()
        }

        // Apply new ISO (shutter stays fixed)
        cameraService.setCustomExposure(
            iso: newISO,
            shutterSeconds: cameraService.currentShutterSpeed
        )
    }

    /// Update shutter speed based on drag gesture progress
    /// - Parameters:
    ///   - progress: Progress value (0-1) representing rotation around the circle
    ///   - normalizedAngle: Angle in degrees (0-360) for velocity tracking
    func updateShutter(progress: Double, normalizedAngle: Double) {
        // A manual adjustment takes over from the AI prediction for the session.
        autoExposureManager.notifyManualOverride()

        // Start rumble on first drag
        if lastDragTime == .distantPast {
            hapticManager.startShutterRumble()
            lastDragTime = Date()
            lastDragAngle = normalizedAngle
        } else {
            // Calculate velocity for rumble intensity
            let now = Date()
            let timeDelta = now.timeIntervalSince(lastDragTime)

            // Handle angle wraparound (360° → 0° or 0° → 360°)
            var angleDelta = normalizedAngle - lastDragAngle
            if angleDelta > 180 {
                angleDelta -= 360
            } else if angleDelta < -180 {
                angleDelta += 360
            }

            // Calculate velocity and normalize to 0-1 range
            let velocity = timeDelta > 0 ? abs(angleDelta / timeDelta) : 0
            let normalizedVelocity = min(velocity / ExposureControlConstants.maxRumbleVelocity, 1.0)

            // Update rumble intensity based on velocity
            hapticManager.updateShutterRumble(velocity: normalizedVelocity)

            // Update tracking variables
            lastDragTime = now
            lastDragAngle = normalizedAngle
        }

        // Map progress to shutter speed logarithmically using ExposureCalculator
        let newShutter = ExposureCalculator.shutterFromProgress(
            progress,
            min: cameraService.minShutterSpeed,
            max: cameraService.maxShutterSpeed
        )

        // Apply new shutter (ISO stays fixed)
        cameraService.setCustomExposure(
            iso: cameraService.currentISO,
            shutterSeconds: newShutter
        )
    }

    /// Set rotation angle for a specific control
    /// - Parameters:
    ///   - control: Which control (ISO or shutter)
    ///   - angle: Rotation angle to set
    func updateRotationAngle(control: ExposureControl, angle: Angle) {
        switch control {
        case .iso:
            isoRotationAngle = angle
        case .shutter:
            shutterRotationAngle = angle
        }
    }

    /// Set which control is currently active
    /// - Parameter control: The active control (ISO or shutter)
    func setActiveControl(_ control: ExposureControl) {
        activeControl = control
    }

    /// Reset active control after drag ends
    func resetActiveControl() {
        // Stop rumble if we were adjusting shutter
        if activeControl == .shutter {
            hapticManager.stopShutterRumble()
            lastDragTime = .distantPast
            lastDragAngle = 0.0
        }

        activeControl = nil
    }
}
