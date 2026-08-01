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

/// Utility for logarithmic exposure calculations
/// Consolidates forward and inverse mappings for ISO and shutter speed
///
/// Pure math over the range it is handed: callers pass CameraService's
/// min/max values, which already have the manual-control policy caps applied
/// at session configuration (see CameraConstants).
enum ExposureCalculator {
    // MARK: - Forward Mapping (Progress → Value)

    /// Convert rotation progress (0-1) to ISO value using logarithmic mapping
    /// - Parameters:
    ///   - progress: Rotation progress from 0 to 1
    ///   - min: Minimum ISO value
    ///   - max: Maximum ISO value
    /// - Returns: ISO value (not rounded to discrete steps)
    static func isoFromProgress(_ progress: Double, min: Float, max: Float) -> Float {
        let logMin = log(min)
        let logMax = log(max)
        let logISO = logMin + Float(clampProgress(progress)) * (logMax - logMin)
        return exp(logISO)
    }

    /// Convert rotation progress (0-1) to shutter speed using logarithmic mapping
    /// - Parameters:
    ///   - progress: Rotation progress from 0 to 1
    ///   - min: Minimum shutter speed in seconds
    ///   - max: Maximum shutter speed in seconds
    /// - Returns: Shutter speed in seconds
    static func shutterFromProgress(_ progress: Double, min: Double, max: Double) -> Double {
        let logMin = log(min)
        let logMax = log(max)
        let logShutter = logMin + clampProgress(progress) * (logMax - logMin)
        return exp(logShutter)
    }

    // MARK: - Inverse Mapping (Value → Progress)

    /// Progress along the knob's arc for an ISO value (inverse of `isoFromProgress`).
    /// - Returns: Progress clamped to 0...1.
    static func progressFromISO(_ iso: Float, min: Float, max: Float) -> Double {
        let logMin = log(min)
        let logMax = log(max)
        let logISO = log(iso)

        return clampProgress(Double((logISO - logMin) / (logMax - logMin)))
    }

    /// Progress along the knob's arc for a shutter speed (inverse of `shutterFromProgress`).
    /// - Returns: Progress clamped to 0...1.
    static func progressFromShutter(_ shutterSeconds: Double, min: Double, max: Double) -> Double {
        let logMin = log(min)
        let logMax = log(max)
        let logShutter = log(shutterSeconds)

        return clampProgress((logShutter - logMin) / (logMax - logMin))
    }

    // MARK: - Knob Geometry

    /// Where along the arc a given progress sits.
    ///
    /// The arc is `ExposureControlConstants.sweepDegrees`, not a full turn, so
    /// 0 and 1 land at visibly different bearings either side of 12 o'clock.
    /// - Returns: Rotation angle (0° = top, increases clockwise).
    static func angle(forProgress progress: Double) -> Angle {
        Angle.degrees(clampProgress(progress) * ExposureControlConstants.sweepDegrees)
    }

    /// Signed shortest-arc difference between two compass bearings, in degrees.
    ///
    /// A thumb crossing 12 o'clock reports bearings that jump 359° → 1°, which
    /// naively reads as a 358° leap backwards. Taking the shortest arc turns that
    /// into the +2° it physically was. Result is always within ±180°.
    static func shortestArcDelta(from: Double, to: Double) -> Double {
        var delta = to - from
        if delta > 180 {
            delta -= 360
        } else if delta < -180 {
            delta += 360
        }
        return delta
    }

    /// Advance accumulated progress by a thumb movement, stopping at the ends.
    ///
    /// This is what makes the wall a wall: progress is carried across frames and
    /// clamped, rather than being recomputed from the thumb's absolute bearing.
    /// Pushing further into an end has no effect, and reversing leaves it on the
    /// very next frame — no unwinding of overshoot, because none is stored.
    ///
    /// - Parameters:
    ///   - progress: Accumulated progress so far, 0...1.
    ///   - bearingDelta: Degrees turned since the last frame, signed.
    /// - Returns: The new progress, and whether this call was the one that
    ///   arrived at an end — so a caller can fire feedback once rather than on
    ///   every frame spent pressed against it.
    static func accumulate(
        progress: Double,
        bearingDelta: Double
    ) -> (progress: Double, hitWall: Bool) {
        let unclamped = progress + bearingDelta / ExposureControlConstants.sweepDegrees
        let clamped = clampProgress(unclamped)

        // Only a transition counts. Already sitting at an end and pushing harder
        // is not a new arrival, so `clamped != progress` guards the repeat.
        let hitWall = unclamped != clamped && clamped != progress
        return (clamped, hitWall)
    }

    // MARK: - Private Helpers

    private static func clampProgress(_ progress: Double) -> Double {
        Swift.max(0, Swift.min(1, progress))
    }

    // MARK: - Inverse Mapping (Value → Angle)

    /// Calculate rotation angle from ISO value (inverse of isoFromProgress)
    /// Used for AI predictions to set knob positions
    /// - Parameters:
    ///   - iso: ISO value
    ///   - min: Minimum ISO value
    ///   - max: Maximum ISO value
    /// - Returns: Rotation angle (0° = top, increases clockwise)
    static func angleFromISO(_ iso: Float, min: Float, max: Float) -> Angle {
        angle(forProgress: progressFromISO(iso, min: min, max: max))
    }

    /// Calculate rotation angle from shutter speed (inverse of shutterFromProgress)
    /// Used for AI predictions to set knob positions
    /// - Parameters:
    ///   - shutterSeconds: Shutter speed in seconds
    ///   - min: Minimum shutter speed in seconds
    ///   - max: Maximum shutter speed in seconds
    /// - Returns: Rotation angle (0° = top, increases clockwise)
    static func angleFromShutter(_ shutterSeconds: Double, min: Double, max: Double) -> Angle {
        angle(forProgress: progressFromShutter(shutterSeconds, min: min, max: max))
    }
}
