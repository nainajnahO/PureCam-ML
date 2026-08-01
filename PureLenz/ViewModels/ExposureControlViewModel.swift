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

    /// Accumulated position of each knob along its arc, 0...1.
    ///
    /// This is the source of truth for both the value and the dot position. It
    /// is carried across frames and clamped rather than being recomputed from
    /// the thumb's bearing, which is what gives the arc ends instead of a seam.
    private(set) var isoProgress: Double = 0
    private(set) var shutterProgress: Double = 0

    /// Where the dots sit. Derived, never set: a stored angle would be a second
    /// source of truth that could drift from the value it is supposed to depict,
    /// and — because `Angle` interpolates linearly on `.degrees` — an accumulated
    /// one could send the AI's spring animation the long way round the circle.
    var isoRotationAngle: Angle { ExposureCalculator.angle(forProgress: isoProgress) }
    var shutterRotationAngle: Angle { ExposureCalculator.angle(forProgress: shutterProgress) }

    /// Last discrete ISO value (for haptic change detection)
    private var lastDiscreteISO: Float = 0

    /// Active control (ISO or shutter)
    private(set) var activeControl: ExposureControl? = nil

    /// Thumb bearing at the previous frame. `nil` means no drag is in progress —
    /// and is what makes touch-down inert: the first frame only records where the
    /// thumb landed, so the knob turns by how far you move it rather than jumping
    /// to wherever you happened to touch.
    private var lastBearing: Double?

    /// Time of the previous shutter drag frame, for rumble intensity.
    /// `nil` means no shutter drag is in progress.
    private var lastDragTime: ContinuousClock.Instant?

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

    /// Begin a drag on a knob without moving it.
    ///
    /// Recording the bearing and nothing else is the whole point: the knob turns
    /// by how far the thumb travels, so grabbing it anywhere — including the far
    /// side of the button — leaves the exposure exactly where it was.
    /// - Parameter bearing: Thumb bearing in degrees, 0° = top, clockwise.
    func beginDrag(control: ExposureControl, bearing: Double) {
        activeControl = control
        lastBearing = bearing

        // The rumble belongs to the whole gesture, so it starts here rather than
        // on the first frame that moves. Nothing else about the knob changes yet.
        if control == .shutter {
            hapticManager.startShutterRumble()
            lastDragTime = .now
        }
    }

    /// Advance ISO by the thumb movement since the last frame.
    /// - Parameter bearing: Thumb bearing in degrees, 0° = top, clockwise.
    func updateISO(bearing: Double) {
        guard let delta = consumeBearingDelta(bearing) else { return }

        // A manual adjustment takes over from the AI prediction for the session.
        autoExposureManager.notifyManualOverride()

        let step = ExposureCalculator.accumulate(progress: isoProgress, bearingDelta: delta)
        isoProgress = step.progress
        reportWall(hit: step.hitWall)

        let continuousISO = ExposureCalculator.isoFromProgress(
            isoProgress,
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

    /// Advance shutter speed by the thumb movement since the last frame.
    /// - Parameter bearing: Thumb bearing in degrees, 0° = top, clockwise.
    func updateShutter(bearing: Double) {
        guard let delta = consumeBearingDelta(bearing) else { return }

        // A manual adjustment takes over from the AI prediction for the session.
        autoExposureManager.notifyManualOverride()

        let previousProgress = shutterProgress
        let step = ExposureCalculator.accumulate(progress: shutterProgress, bearingDelta: delta)
        shutterProgress = step.progress
        reportWall(hit: step.hitWall)

        // Rumble tracks how fast the *value* is moving, not how fast the thumb
        // is. Driving it from the raw thumb delta kept it buzzing at full
        // intensity against a knob that had stopped, because the thumb was still
        // travelling. Applied travel shrinks to nothing as the knob reaches an
        // end, so it now eases off into the wall instead.
        let appliedDegrees = (shutterProgress - previousProgress)
            * ExposureControlConstants.sweepDegrees

        // Easing off is not enough on its own: `updateShutterRumble` floors
        // intensity at 0.2, so a stopped knob would still hum. Pinned against an
        // end, stop outright — the shutter counterpart of the ISO click falling
        // silent once the detent stops changing. Both calls are idempotent, so
        // driving them every frame is safe.
        let isPinned = shutterProgress == previousProgress
            && (shutterProgress == 0 || shutterProgress == 1)

        let now = ContinuousClock.now
        if isPinned {
            hapticManager.stopShutterRumble()
        } else if let previousDragTime = lastDragTime {
            hapticManager.startShutterRumble()

            let timeDelta = previousDragTime.duration(to: now) / .seconds(1)
            let velocity = timeDelta > 0 ? abs(appliedDegrees / timeDelta) : 0
            let normalizedVelocity = min(velocity / ExposureControlConstants.maxRumbleVelocity, 1.0)

            hapticManager.updateShutterRumble(velocity: normalizedVelocity)
        }
        lastDragTime = now

        let newShutter = ExposureCalculator.shutterFromProgress(
            shutterProgress,
            min: cameraService.minShutterSpeed,
            max: cameraService.maxShutterSpeed
        )

        // Apply new shutter (ISO stays fixed)
        cameraService.setCustomExposure(
            iso: cameraService.currentISO,
            shutterSeconds: newShutter
        )
    }

    // MARK: - Stepped Adjustment

    /// Current ISO, rounded to the detent it sits on.
    var currentISO: Float { cameraService.roundToNearestISO(cameraService.currentISO) }

    /// Current shutter speed in seconds.
    var currentShutterSeconds: Double { cameraService.currentShutterSpeed }

    /// Move ISO by whole detents.
    ///
    /// Steps the detent table rather than nudging progress by a fixed fraction,
    /// so a step always lands exactly on a supported value — the same places the
    /// drag gesture clicks through.
    func stepISO(by steps: Int) {
        let detents = cameraService.isoDetents
        guard let index = detents.firstIndex(of: currentISO) else { return }

        let target = detents[Swift.max(0, Swift.min(detents.count - 1, index + steps))]
        guard target != currentISO else { return }

        autoExposureManager.notifyManualOverride()
        isoProgress = ExposureCalculator.progressFromISO(
            target, min: cameraService.minISO, max: cameraService.maxISO
        )
        cameraService.setCustomExposure(
            iso: target,
            shutterSeconds: cameraService.currentShutterSpeed
        )
    }

    /// Move shutter speed by thirds of a stop, matching the ISO detent spacing.
    func stepShutter(by steps: Int) {
        let low = cameraService.minShutterSpeed
        let high = cameraService.maxShutterSpeed
        let scaled = currentShutterSeconds * pow(2.0, Double(steps) / 3.0)
        let target = Swift.max(low, Swift.min(high, scaled))
        guard target != currentShutterSeconds else { return }

        autoExposureManager.notifyManualOverride()
        shutterProgress = ExposureCalculator.progressFromShutter(target, min: low, max: high)
        cameraService.setCustomExposure(iso: cameraService.currentISO, shutterSeconds: target)
    }

    /// Place a knob at an absolute position, for the AI to drive it.
    /// - Parameters:
    ///   - control: Which control (ISO or shutter)
    ///   - progress: Position along the arc, 0...1
    func setProgress(control: ExposureControl, progress: Double) {
        switch control {
        case .iso:
            isoProgress = progress
        case .shutter:
            shutterProgress = progress
        }
    }

    /// Reset active control after drag ends
    func resetActiveControl() {
        // Stop rumble if we were adjusting shutter
        if activeControl == .shutter {
            hapticManager.stopShutterRumble()
            lastDragTime = nil
        }

        lastBearing = nil
        activeControl = nil
    }

    // MARK: - Private Methods

    /// Degrees turned since the previous frame, advancing the stored bearing.
    /// - Returns: The shortest-arc delta, or `nil` on the first frame of a drag,
    ///   when there is no previous bearing to measure against and the knob must
    ///   therefore stay put.
    private func consumeBearingDelta(_ bearing: Double) -> Double? {
        defer { lastBearing = bearing }

        guard let previous = lastBearing else { return nil }
        return ExposureCalculator.shortestArcDelta(from: previous, to: bearing)
    }

    /// Bump once on reaching an end. `hitWall` is already true only on the frame
    /// that arrives, so pushing on against the wall stays silent.
    private func reportWall(hit: Bool) {
        guard hit else { return }
        hapticManager.impact(.medium)
    }
}
