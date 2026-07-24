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

/// Manual-exposure policy caps. Applied once, in CameraService's session
/// configuration, on top of the device-reported exposure range — the clamped
/// range is then the single source that the knob mapping, the AI ramp, and
/// setCustomExposure all read.
enum CameraConstants {
    /// Fastest shutter speed exposed to manual control (1/4000 s).
    static let fastestManualShutter: Double = 1.0 / 4000.0

    /// Slowest shutter speed exposed to manual control (1/2 s) — a UX cap,
    /// not a hardware limit; longer exposures aren't practical handheld.
    static let slowestManualShutter: Double = 1.0 / 2.0
}

/// On-device ML artifacts: the two trained model files and the recorded
/// training dataset. Named in one place so the writer (ModelTrainer), the
/// reader (AutoExposureManager), and the recorder (TrainingDataManager) can
/// never disagree — and so a schema bump touches all three together.
///
/// The V3 suffix marks the current schema: 14 features (including a true
/// Gaussian center-weighted luminance) with log2-space targets. Any change to
/// the feature set, to what a feature means, or to the target space makes
/// previously recorded samples and previously trained models incompatible.
/// Bump the suffix on all three names and the stale files are simply never
/// read again — no per-version cleanup code to carry forward.
enum MLFiles {
    /// Compiled ISO regressor installed in the Documents directory.
    static var isoModelURL: URL {
        URL.documentsDirectory.appendingPathComponent("ISORegressorV3.mlmodelc")
    }

    /// Compiled shutter regressor installed in the Documents directory.
    static var shutterModelURL: URL {
        URL.documentsDirectory.appendingPathComponent("ShutterRegressorV3.mlmodelc")
    }

    /// Recorded training samples.
    static var trainingDataURL: URL {
        URL.documentsDirectory.appendingPathComponent("trainingDataV3.json")
    }
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

    /// Floor applied to mean luminance before taking log2 in the scene-light
    /// computation, so an all-black frame stays finite.
    static let sceneLightLuminanceFloor: Float = 1e-4

    /// Floor applied to the ISO × shutter product before taking log2 in the
    /// scene-light computation, so a degenerate exposure stays finite.
    static let sceneLightExposureFloor: Double = 1e-9
}

/// Tuning constants for manual exposure gesture feedback.
enum ExposureControlConstants {
    /// Angular drag velocity (deg/sec) that maps to full-intensity rumble.
    /// Anything faster is clamped to 1.0.
    static let maxRumbleVelocity: Double = 500.0
}
