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

import Foundation

/// Camera hardware limits shared across exposure math.
enum CameraConstants {
    /// Fastest shutter speed supported by typical iPhone hardware (1/4000 s).
    static let hardwareMinShutter: Double = 1.0 / 4000.0

    /// Slowest shutter speed exposed to manual control (1/2 s).
    static let hardwareMaxShutter: Double = 1.0 / 2.0
}

/// Perceptual luminance weights and tonal-range thresholds used by feature extraction.
enum LuminanceConstants {
    /// Rec. 709 luma coefficient for the red channel.
    static let rec709Red: Float = 0.2126

    /// Rec. 709 luma coefficient for the green channel.
    static let rec709Green: Float = 0.7152

    /// Rec. 709 luma coefficient for the blue channel.
    static let rec709Blue: Float = 0.0722

    /// Pixels below this normalized luminance are counted as crushed shadows.
    static let clippedShadowsThreshold: Float = 0.02

    /// Pixels above this normalized luminance are counted as blown highlights.
    static let clippedHighlightsThreshold: Float = 0.98

    /// Upper bound of the shadows histogram bin (normalized luminance).
    static let shadowsUpperBound: Float = 0.25

    /// Upper bound of the midtones histogram bin (normalized luminance).
    static let midtonesUpperBound: Float = 0.75
}

/// Tuning constants for manual exposure gesture feedback.
enum ExposureControlConstants {
    /// Angular drag velocity (deg/sec) that maps to full-intensity rumble.
    /// Anything faster is clamped to 1.0.
    static let maxRumbleVelocity: Double = 500.0
}
