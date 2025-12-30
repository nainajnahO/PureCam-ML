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

/// Utility for logarithmic exposure calculations
/// Consolidates forward and inverse mappings for ISO and shutter speed
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
        let logISO = logMin + Float(progress) * (logMax - logMin)
        return exp(logISO)
    }

    /// Convert rotation progress (0-1) to shutter speed using logarithmic mapping
    /// - Parameters:
    ///   - progress: Rotation progress from 0 to 1
    ///   - min: Minimum shutter speed in seconds
    ///   - max: Maximum shutter speed in seconds
    /// - Returns: Shutter speed in seconds
    static func shutterFromProgress(_ progress: Double, min: Double, max: Double) -> Double {
        // Apply hardware limits (1/4000 to 1/2)
        let minShutter = Swift.max(min, 1.0 / 4000.0)
        let maxShutter = Swift.min(max, 1.0 / 2.0)

        let logMin = log(minShutter)
        let logMax = log(maxShutter)
        let logShutter = logMin + progress * (logMax - logMin)
        return exp(logShutter)
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
        let logMin = log(min)
        let logMax = log(max)
        let logISO = log(iso)

        // Solve for progress
        let progress = (logISO - logMin) / (logMax - logMin)
        let clampedProgress = Swift.max(0, Swift.min(1, progress))

        // Convert progress to degrees (full rotation = 360°)
        let degrees = clampedProgress * 360.0
        return Angle.degrees(Double(degrees))
    }

    /// Calculate rotation angle from shutter speed (inverse of shutterFromProgress)
    /// Used for AI predictions to set knob positions
    /// - Parameters:
    ///   - shutterSeconds: Shutter speed in seconds
    ///   - min: Minimum shutter speed in seconds
    ///   - max: Maximum shutter speed in seconds
    /// - Returns: Rotation angle (0° = top, increases clockwise)
    static func angleFromShutter(_ shutterSeconds: Double, min: Double, max: Double) -> Angle {
        // Apply hardware limits (1/4000 to 1/2)
        let minShutter = Swift.max(min, 1.0 / 4000.0)
        let maxShutter = Swift.min(max, 1.0 / 2.0)

        let logMin = log(minShutter)
        let logMax = log(maxShutter)
        let logShutter = log(shutterSeconds)

        let progress = (logShutter - logMin) / (logMax - logMin)
        let clampedProgress = Swift.max(0, Swift.min(1, progress))

        let degrees = clampedProgress * 360.0
        return Angle.degrees(degrees)
    }
}
