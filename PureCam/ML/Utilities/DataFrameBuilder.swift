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

import TabularData

/// Utility for constructing TabularData DataFrames for ML training
/// Eliminates code duplication in ModelTrainer
enum DataFrameBuilder {
    /// Add all 13 scene feature columns to a DataFrame
    /// - Parameters:
    ///   - dataFrame: The DataFrame to modify (passed as inout)
    ///   - features: Array of feature arrays, where each inner array has 13 Float values
    static func addFeatureColumns(to dataFrame: inout DataFrame, features: [[Float]]) {
        dataFrame.append(column: Column(name: "meanLuminance", contents: features.map { $0[0] }))
        dataFrame.append(column: Column(name: "medianLuminance", contents: features.map { $0[1] }))
        dataFrame.append(column: Column(name: "minLuminance", contents: features.map { $0[2] }))
        dataFrame.append(column: Column(name: "maxLuminance", contents: features.map { $0[3] }))
        dataFrame.append(column: Column(name: "stdDevLuminance", contents: features.map { $0[4] }))
        dataFrame.append(column: Column(name: "shadowsPercent", contents: features.map { $0[5] }))
        dataFrame.append(column: Column(name: "midtonesPercent", contents: features.map { $0[6] }))
        dataFrame.append(column: Column(name: "highlightsPercent", contents: features.map { $0[7] }))
        dataFrame.append(column: Column(name: "clippedHighlightsPercent", contents: features.map { $0[8] }))
        dataFrame.append(column: Column(name: "clippedShadowsPercent", contents: features.map { $0[9] }))
        dataFrame.append(column: Column(name: "colorTemperature", contents: features.map { $0[10] }))
        dataFrame.append(column: Column(name: "saturation", contents: features.map { $0[11] }))
        dataFrame.append(column: Column(name: "centerWeightedLuminance", contents: features.map { $0[12] }))
    }

    /// Create DataFrame for ISO model training (scene features → ISO target)
    /// - Parameters:
    ///   - features: Array of 13-element Float arrays (scene features)
    ///   - isoTargets: Array of ISO target values
    /// - Returns: DataFrame ready for MLBoostedTreeRegressor training
    static func createISODataFrame(features: [[Float]], isoTargets: [Float]) -> DataFrame {
        var dataFrame = DataFrame()
        addFeatureColumns(to: &dataFrame, features: features)
        dataFrame.append(column: Column(name: "targetISO", contents: isoTargets.map { Double($0) }))
        return dataFrame
    }

    /// Create DataFrame for shutter model training (scene features + chosen ISO → shutter target)
    /// - Parameters:
    ///   - features: Array of 13-element Float arrays (scene features)
    ///   - isoTargets: Array of chosen ISO values (used as additional feature)
    ///   - shutterTargets: Array of shutter speed target values in seconds
    /// - Returns: DataFrame ready for MLBoostedTreeRegressor training
    static func createShutterDataFrame(
        features: [[Float]],
        isoTargets: [Float],
        shutterTargets: [Double]
    ) -> DataFrame {
        var dataFrame = DataFrame()
        addFeatureColumns(to: &dataFrame, features: features)
        dataFrame.append(column: Column(name: "chosenISO", contents: isoTargets.map { Double($0) }))
        dataFrame.append(column: Column(name: "targetShutterSeconds", contents: shutterTargets))
        return dataFrame
    }
}
