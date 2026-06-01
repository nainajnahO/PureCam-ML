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

    // MARK: - Metadata

    /// When features were extracted
    let timestamp: Date

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
            "centerWeightedLuminance": centerWeightedLuminance
        ]
        return try MLDictionaryFeatureProvider(dictionary: dict)
    }
}
