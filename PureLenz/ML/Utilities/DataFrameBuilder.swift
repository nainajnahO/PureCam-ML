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
    /// Add one named column per scene feature, iterating the shared
    /// `SceneFeatures.mlFeatures` table — the same table inference reads —
    /// so the training and inference schemas cannot drift apart.
    /// - Parameters:
    ///   - dataFrame: The DataFrame to modify (passed as inout)
    ///   - features: Scene features for each training sample
    static func addFeatureColumns(to dataFrame: inout DataFrame, features: [SceneFeatures]) {
        for (name, value) in SceneFeatures.mlFeatures {
            dataFrame.append(column: Column(name: name, contents: features.map { $0[keyPath: value] }))
        }
    }

    /// Create DataFrame for ISO model training (scene features → log2 ISO target)
    /// - Parameter samples: Training samples (features + user-chosen exposure)
    /// - Returns: DataFrame ready for MLBoostedTreeRegressor training
    static func createISODataFrame(samples: [TrainingSample]) -> DataFrame {
        var dataFrame = DataFrame()
        addFeatureColumns(to: &dataFrame, features: samples.map(\.features))
        dataFrame.append(column: Column(
            name: "targetLogISO",
            contents: samples.map { log2(Double($0.userChosenISO)) }
        ))
        return dataFrame
    }

    /// Create DataFrame for shutter model training (scene features + chosen log2 ISO → log2 shutter target)
    /// - Parameter samples: Training samples (features + user-chosen exposure)
    /// - Returns: DataFrame ready for MLBoostedTreeRegressor training
    static func createShutterDataFrame(samples: [TrainingSample]) -> DataFrame {
        var dataFrame = DataFrame()
        addFeatureColumns(to: &dataFrame, features: samples.map(\.features))
        dataFrame.append(column: Column(
            name: "chosenLogISO",
            contents: samples.map { log2(Double($0.userChosenISO)) }
        ))
        dataFrame.append(column: Column(
            name: "targetLogShutter",
            contents: samples.map { log2($0.userChosenShutterSeconds) }
        ))
        return dataFrame
    }
}
