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
import OSLog

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
/// read again — the rename, not a delete, is what makes them safe.
/// `removeSupersededArtifacts()` then reclaims the space without needing to
/// know which versions ever existed.
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

    /// Directory holding one JPEG per training sample: the downsampled buffer
    /// feature extraction actually analysed, kept as raw material.
    ///
    /// Deliberately *not* version-suffixed, and that is the whole point. The
    /// features derived from a frame go stale when the schema changes; the frame
    /// itself never does. Keeping the pixels means a new feature can be computed
    /// for samples recorded before it existed — a backfill instead of the reset
    /// that a suffix bump forces. Stored beside the dataset rather than inside
    /// it because these are cold: written once, read only during a backfill,
    /// while `trainingDataURL` is decoded in full at every launch.
    ///
    /// Thumbnails are only meaningful attached to a sample's exposure labels, so
    /// they are pruned against the dataset rather than kept independently.
    static var thumbnailDirectoryURL: URL {
        URL.documentsDirectory.appendingPathComponent("SampleThumbnails", isDirectory: true)
    }

    /// The name stem and extension of each artifact family, used to recognise
    /// versioned files from *any* schema generation.
    private static let artifactPatterns: [(stem: String, fileExtension: String)] = [
        ("ISORegressor", "mlmodelc"),
        ("ShutterRegressor", "mlmodelc"),
        ("trainingData", "json")
    ]

    /// Delete artifacts left behind by earlier schema versions.
    ///
    /// Matched by pattern rather than by a list of old filenames, so bumping the
    /// suffix above needs no corresponding edit here — anything that looks like
    /// one of our artifacts but isn't a current name is by definition stale.
    /// These live in Documents, which is iCloud-backed and counts against the
    /// user's storage, so leaving a set behind per schema bump isn't free.
    ///
    /// Purely housekeeping: correctness comes from the versioned names, so a
    /// failure to delete is logged and ignored.
    static func removeSupersededArtifacts() {
        let currentNames = Set(
            [isoModelURL, shutterModelURL, trainingDataURL].map(\.lastPathComponent)
        )

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: .documentsDirectory, includingPropertiesForKeys: nil
        ) else { return }

        for url in contents where !currentNames.contains(url.lastPathComponent) {
            let name = url.deletingPathExtension().lastPathComponent
            let matchesArtifact = artifactPatterns.contains {
                name.hasPrefix($0.stem) && url.pathExtension == $0.fileExtension
            }
            guard matchesArtifact else { continue }

            do {
                try FileManager.default.removeItem(at: url)
                Logger.ml.info("Removed superseded ML artifact \(url.lastPathComponent)")
            } catch {
                Logger.ml.error(
                    "Could not remove superseded artifact \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
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
