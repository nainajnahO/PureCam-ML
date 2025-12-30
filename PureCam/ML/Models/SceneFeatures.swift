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
