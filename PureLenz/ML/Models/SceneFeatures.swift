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
    /// Datasets recorded before this feature existed carry an older schema
    /// suffix (see `MLFiles`) and are never read.
    let sceneLightLevel: Float

    // MARK: - Spot Metering

    /// Gaussian-weighted luminance around the metering point: a tight spot at
    /// the tapped focus point while one is in effect, otherwise *exactly*
    /// `centerWeightedLuminance`.
    ///
    /// A separate feature rather than a repurposed `centerWeightedLuminance`,
    /// because that column is a trained input whose meaning ("the middle") the
    /// models learned from every sample so far. Redefining it as "wherever the
    /// user tapped" would shift a feature out from under the model; adding this
    /// one alongside lets the model learn the difference — and keeps untapped
    /// frames identical to what they always were.
    let spotLuminance: Float

    /// 1 when `spotLuminance` was metered at a tapped point, 0 when it is the
    /// centre-weighted reading. A Float rather than a Bool because every model
    /// input is a Float — `mlFeatures` is keyed on them.
    let hasSpotMeter: Float

    // MARK: - Metadata

    /// When features were extracted
    let timestamp: Date

    /// Where `spotLuminance` was metered, normalized (0,0) top-left … (1,1)
    /// bottom-right of the analysed frame, or nil when it is the centre-weighted
    /// reading. Not a model input. Kept with the sample for the same reason the
    /// frame thumbnail is (`MLFiles.thumbnailDirectoryURL`): the spot's size is a
    /// choice that may change, and only the point makes the column recomputable.
    let meteringPoint: CGPoint?

    // MARK: - Scene Light Computation

    /// Compute the exposure-normalized scene brightness in stops.
    static func computeSceneLightLevel(meanLuminance: Float, iso: Float, shutterSeconds: Double) -> Float {
        let luminance = max(meanLuminance, LuminanceConstants.sceneLightLuminanceFloor)
        let exposure = max(Double(iso) * shutterSeconds, LuminanceConstants.sceneLightExposureFloor)
        return log2(luminance) - Float(log2(exposure))
    }

    // MARK: - ML Feature Schema

    /// The single authoritative list of ML feature columns. Training
    /// (DataFrameBuilder's columns) and inference (toMLFeatureProvider's keys)
    /// both iterate this table, so the two schemas can never drift apart —
    /// adding a feature is one property plus one row here.
    static let mlFeatures: [(name: String, value: KeyPath<SceneFeatures, Float>)] = [
        ("meanLuminance", \.meanLuminance),
        ("medianLuminance", \.medianLuminance),
        ("minLuminance", \.minLuminance),
        ("maxLuminance", \.maxLuminance),
        ("stdDevLuminance", \.stdDevLuminance),
        ("shadowsPercent", \.shadowsPercent),
        ("midtonesPercent", \.midtonesPercent),
        ("highlightsPercent", \.highlightsPercent),
        ("clippedHighlightsPercent", \.clippedHighlightsPercent),
        ("clippedShadowsPercent", \.clippedShadowsPercent),
        ("colorTemperature", \.colorTemperature),
        ("saturation", \.saturation),
        ("centerWeightedLuminance", \.centerWeightedLuminance),
        ("sceneLightLevel", \.sceneLightLevel),
        ("spotLuminance", \.spotLuminance),
        ("hasSpotMeter", \.hasSpotMeter)
    ]

    // MARK: - ML Conversion

    /// Convert to MLFeatureProvider for CoreML inference
    func toMLFeatureProvider() throws -> MLDictionaryFeatureProvider {
        let dict = Self.mlFeatures.reduce(into: [String: Any]()) { dict, feature in
            dict[feature.name] = self[keyPath: feature.value]
        }
        return try MLDictionaryFeatureProvider(dictionary: dict)
    }
}

// MARK: - Decoding Samples From Before Spot Metering

extension SceneFeatures {
    /// Samples recorded before spot metering existed have no spot columns, but
    /// their values are not unknown: every one of them was metered from the
    /// centre, so the spot reading *is* the centre-weighted one with the flag
    /// off. Filling them in here is what lets the recorded dataset train the
    /// spot-aware models instead of being thrown away (#24: "legacy samples
    /// migrate without a full retrain from scratch").
    ///
    /// Encoding stays synthesized, so a dataset saved by this build carries the
    /// columns explicitly from then on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meanLuminance = try container.decode(Float.self, forKey: .meanLuminance)
        medianLuminance = try container.decode(Float.self, forKey: .medianLuminance)
        minLuminance = try container.decode(Float.self, forKey: .minLuminance)
        maxLuminance = try container.decode(Float.self, forKey: .maxLuminance)
        stdDevLuminance = try container.decode(Float.self, forKey: .stdDevLuminance)
        shadowsPercent = try container.decode(Float.self, forKey: .shadowsPercent)
        midtonesPercent = try container.decode(Float.self, forKey: .midtonesPercent)
        highlightsPercent = try container.decode(Float.self, forKey: .highlightsPercent)
        clippedHighlightsPercent = try container.decode(Float.self, forKey: .clippedHighlightsPercent)
        clippedShadowsPercent = try container.decode(Float.self, forKey: .clippedShadowsPercent)
        colorTemperature = try container.decode(Float.self, forKey: .colorTemperature)
        saturation = try container.decode(Float.self, forKey: .saturation)
        centerWeightedLuminance = try container.decode(Float.self, forKey: .centerWeightedLuminance)
        sceneLightLevel = try container.decode(Float.self, forKey: .sceneLightLevel)
        spotLuminance = try container.decodeIfPresent(Float.self, forKey: .spotLuminance)
            ?? centerWeightedLuminance
        hasSpotMeter = try container.decodeIfPresent(Float.self, forKey: .hasSpotMeter) ?? 0
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        meteringPoint = try container.decodeIfPresent(CGPoint.self, forKey: .meteringPoint)
    }
}
