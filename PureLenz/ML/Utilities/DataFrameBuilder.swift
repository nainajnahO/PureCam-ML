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
import TabularData

/// Utility for constructing TabularData DataFrames for ML training
/// Eliminates code duplication in ModelTrainer
///
/// Targets are in log2 (stops) space — `targetLogISO` / `targetLogShutter` —
/// so the regression loss weights a 1-stop error the same across the whole
/// exposure range. In raw linear units the squared error at ISO 3200 dwarfs
/// the same photographic error at ISO 50, which made the models sacrifice
/// bright-scene accuracy. Inference (AutoExposureManager) exponentiates back.
enum DataFrameBuilder {
    /// Add one named column per scene feature, read straight from the typed
    /// struct so the name↔value pairing is enforced by the compiler.
    /// - Parameters:
    ///   - dataFrame: The DataFrame to modify (passed as inout)
    ///   - features: Scene features for each training sample
    static func addFeatureColumns(to dataFrame: inout DataFrame, features: [SceneFeatures]) {
        dataFrame.append(column: Column(name: "meanLuminance", contents: features.map(\.meanLuminance)))
        dataFrame.append(column: Column(name: "medianLuminance", contents: features.map(\.medianLuminance)))
        dataFrame.append(column: Column(name: "minLuminance", contents: features.map(\.minLuminance)))
        dataFrame.append(column: Column(name: "maxLuminance", contents: features.map(\.maxLuminance)))
        dataFrame.append(column: Column(name: "stdDevLuminance", contents: features.map(\.stdDevLuminance)))
        dataFrame.append(column: Column(name: "shadowsPercent", contents: features.map(\.shadowsPercent)))
        dataFrame.append(column: Column(name: "midtonesPercent", contents: features.map(\.midtonesPercent)))
        dataFrame.append(column: Column(name: "highlightsPercent", contents: features.map(\.highlightsPercent)))
        dataFrame.append(column: Column(name: "clippedHighlightsPercent", contents: features.map(\.clippedHighlightsPercent)))
        dataFrame.append(column: Column(name: "clippedShadowsPercent", contents: features.map(\.clippedShadowsPercent)))
        dataFrame.append(column: Column(name: "colorTemperature", contents: features.map(\.colorTemperature)))
        dataFrame.append(column: Column(name: "saturation", contents: features.map(\.saturation)))
        dataFrame.append(column: Column(name: "centerWeightedLuminance", contents: features.map(\.centerWeightedLuminance)))
        dataFrame.append(column: Column(name: "sceneLightLevel", contents: features.map(\.sceneLightLevel)))
    }

    /// Create DataFrame for ISO model training (scene features → log2 ISO target)
    /// - Parameters:
    ///   - features: Scene features for each training sample
    ///   - isoTargets: Array of ISO target values (raw; stored as log2)
    /// - Returns: DataFrame ready for MLBoostedTreeRegressor training
    static func createISODataFrame(features: [SceneFeatures], isoTargets: [Float]) -> DataFrame {
        var dataFrame = DataFrame()
        addFeatureColumns(to: &dataFrame, features: features)
        dataFrame.append(column: Column(name: "targetLogISO", contents: isoTargets.map { log2(Double($0)) }))
        return dataFrame
    }

    /// Create DataFrame for shutter model training (scene features + chosen log2 ISO → log2 shutter target)
    /// - Parameters:
    ///   - features: Scene features for each training sample
    ///   - isoTargets: Array of chosen ISO values (raw; used as additional feature, stored as log2)
    ///   - shutterTargets: Array of shutter speed target values in seconds (raw; stored as log2)
    /// - Returns: DataFrame ready for MLBoostedTreeRegressor training
    static func createShutterDataFrame(
        features: [SceneFeatures],
        isoTargets: [Float],
        shutterTargets: [Double]
    ) -> DataFrame {
        var dataFrame = DataFrame()
        addFeatureColumns(to: &dataFrame, features: features)
        dataFrame.append(column: Column(name: "chosenLogISO", contents: isoTargets.map { log2(Double($0)) }))
        dataFrame.append(column: Column(name: "targetLogShutter", contents: shutterTargets.map { log2($0) }))
        return dataFrame
    }
}
