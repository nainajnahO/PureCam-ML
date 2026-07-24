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
import CoreML

/// Scene features extracted from camera preview for ML inference
struct SceneFeatures: Codable {
    // MARK: - Luminance Statistics (Primary Features)

    /// Overall brightness (0-1, where 0 is pure black, 1 is pure white)
    let meanLuminance: Float

    /// Middle value, robust to outliers
    let medianLuminance: Float

    /// Darkest pixel value
    let minLuminance: Float

    /// Brightest pixel value
    let maxLuminance: Float

    /// Standard deviation - indicates contrast
    let stdDevLuminance: Float

    // MARK: - Histogram Analysis

    /// Percentage of pixels in bottom 25% luminance (shadows)
    let shadowsPercent: Float

    /// Percentage of pixels in 25-75% luminance (midtones)
    let midtonesPercent: Float

    /// Percentage of pixels in top 25% luminance (highlights)
    let highlightsPercent: Float

    /// Percentage of pixels at pure white (>0.98) - clipping indicator
    let clippedHighlightsPercent: Float

    /// Percentage of pixels at pure black (<0.02) - underexposure indicator
    let clippedShadowsPercent: Float

    // MARK: - Color Information (Secondary Features)

    /// Estimated color temperature in Kelvin (2000-10000)
    let colorTemperature: Float

    /// Average saturation (0-1)
    let saturation: Float

    // MARK: - Spatial Information

    /// Center-weighted luminance (photography standard)
    let centerWeightedLuminance: Float

    // MARK: - Scene Light

    /// Exposure-normalized scene brightness in stops:
    /// log2(meanLuminance) - log2(frameISO × frameShutterSeconds).
    ///
    /// The preview's luminance alone is ambiguous — a well-exposed sunny scene
    /// and a well-exposed dim scene look the same — so this divides out the
    /// exposure the frame was captured with to recover the absolute light level.
    /// Required: datasets recorded before this feature existed fail to decode,
    /// which intentionally discards them (see TrainingDataManager.loadDataset).
    let sceneLightLevel: Float

    // MARK: - Metadata

    /// When features were extracted
    let timestamp: Date

    // MARK: - Scene Light Computation

    /// Compute the exposure-normalized scene brightness in stops.
    static func computeSceneLightLevel(meanLuminance: Float, iso: Float, shutterSeconds: Double) -> Float {
        let luminance = max(meanLuminance, LuminanceConstants.sceneLightLuminanceFloor)
        let exposure = max(Double(iso) * shutterSeconds, 1e-9)
        return log2(luminance) - Float(log2(exposure))
    }

    // MARK: - ML Conversion

    /// Convert to MLFeatureProvider for CoreML inference
    func toMLFeatureProvider() throws -> MLDictionaryFeatureProvider {
        let dict: [String: Any] = [
            "meanLuminance": meanLuminance,
            "medianLuminance": medianLuminance,
            "minLuminance": minLuminance,
            "maxLuminance": maxLuminance,
            "stdDevLuminance": stdDevLuminance,
            "shadowsPercent": shadowsPercent,
            "midtonesPercent": midtonesPercent,
            "highlightsPercent": highlightsPercent,
            "clippedHighlightsPercent": clippedHighlightsPercent,
            "clippedShadowsPercent": clippedShadowsPercent,
            "colorTemperature": colorTemperature,
            "saturation": saturation,
            "centerWeightedLuminance": centerWeightedLuminance,
            "sceneLightLevel": sceneLightLevel
        ]
        return try MLDictionaryFeatureProvider(dictionary: dict)
    }
}
