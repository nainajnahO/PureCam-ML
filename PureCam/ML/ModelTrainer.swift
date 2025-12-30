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

import CoreML
import CreateML
import TabularData
import Foundation

/// Handles on-device model training using MLUpdateTask
@available(iOS 15.0, *)
class ModelTrainer {
    private let modelURL: URL
    private let dataManager: TrainingDataManager

    init(modelURL: URL, dataManager: TrainingDataManager) {
        self.modelURL = modelURL
        self.dataManager = dataManager
    }

    /// Schedule background training if conditions are met
    func scheduleBackgroundTrainingIfNeeded() {
        guard dataManager.dataset.isReadyForTraining else {
            print("Not enough training data: \(dataManager.dataset.samples.count)/30")
            return
        }

        print("Scheduling background training with \(dataManager.dataset.samples.count) samples")

        // For now, we'll train immediately on a background queue
        // In a production app, you would use BGProcessingTask for true background execution
        DispatchQueue.global(qos: .background).async { [self] in
            print("Background task started")
            self.trainModel()
        }
    }

    /// Train model synchronously (called on background queue)
    private func trainModel() {
        print("Starting model training...")

        let startTime = Date()

        do {
            // Prepare training data
            print("Step 1: Preparing training data...")
            let (features, targets) = prepareTrainingData()
            print("Prepared \(features.count) samples with \(features[0].count) features each")

            // SEQUENTIAL PREDICTION: Two-stage model training

            // Stage 1: Train ISO model (scene features → ISO)
            print("Step 2: Creating DataFrame for ISO model...")
            let isoDataFrame = DataFrameBuilder.createISODataFrame(
                features: features,
                isoTargets: targets.map { $0.0 }
            )
            print("ISO DataFrame created with \(isoDataFrame.rows.count) rows")

            print("Step 3: Training ISO model...")
            let isoRegressor = try MLBoostedTreeRegressor(
                trainingData: isoDataFrame,
                targetColumn: "targetISO"
            )
            print("ISO model trained successfully")

            // Stage 2: Train shutter model with ISO as additional feature
            print("Step 4: Creating DataFrame for shutter model...")
            let shutterDataFrame = DataFrameBuilder.createShutterDataFrame(
                features: features,
                isoTargets: targets.map { $0.0 },
                shutterTargets: targets.map { $0.1 }
            )
            print("Shutter DataFrame created with \(shutterDataFrame.rows.count) rows")

            print("Step 5: Training shutter model...")
            let shutterRegressor = try MLBoostedTreeRegressor(
                trainingData: shutterDataFrame,
                targetColumn: "targetShutterSeconds"
            )
            print("Shutter model trained successfully")

            // Save both models
            print("Step 6: Saving models...")
            let tempDir = FileManager.default.temporaryDirectory
            let isoModelURL = tempDir.appendingPathComponent("ISORegressor.mlmodel")
            let shutterModelURL = tempDir.appendingPathComponent("ShutterRegressor.mlmodel")

            let metadata = MLModelMetadata(
                author: "PureCam",
                shortDescription: "Auto-exposure regressor trained on user preferences (sequential prediction)",
                version: "1.0"
            )

            try isoRegressor.write(to: isoModelURL, metadata: metadata)
            try shutterRegressor.write(to: shutterModelURL, metadata: metadata)
            print("Saved uncompiled models")

            // Compile models (required for iOS runtime)
            print("Step 7: Compiling models...")
            let compiledISOURL = try MLModel.compileModel(at: isoModelURL)
            let compiledShutterURL = try MLModel.compileModel(at: shutterModelURL)
            print("Models compiled successfully")

            // Copy compiled models to documents directory
            print("Step 8: Installing models...")
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let finalISOURL = documentsPath.appendingPathComponent("ISORegressor.mlmodelc")
            let finalShutterURL = documentsPath.appendingPathComponent("ShutterRegressor.mlmodelc")

            // Remove old models if they exist
            try? FileManager.default.removeItem(at: finalISOURL)
            try? FileManager.default.removeItem(at: finalShutterURL)
            try? FileManager.default.removeItem(at: modelURL)  // Remove old combined model

            try FileManager.default.copyItem(at: compiledISOURL, to: finalISOURL)
            try FileManager.default.copyItem(at: compiledShutterURL, to: finalShutterURL)
            print("Models installed to Documents directory")

            let elapsed = Date().timeIntervalSince(startTime)
            print("Model training completed in \(String(format: "%.1f", elapsed))s")

            // Notify that model has been updated
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .mlModelUpdated, object: nil)
            }

        } catch {
            print("Model training failed: \(error)")
        }
    }

    /// Prepare training data from samples
    private func prepareTrainingData() -> (features: [[Float]], targets: [(Float, Double)]) {
        let samples = dataManager.dataset.samples

        var features: [[Float]] = []
        var targets: [(Float, Double)] = []

        for sample in samples {
            let f = sample.features
            features.append([
                f.meanLuminance,
                f.medianLuminance,
                f.minLuminance,
                f.maxLuminance,
                f.stdDevLuminance,
                f.shadowsPercent,
                f.midtonesPercent,
                f.highlightsPercent,
                f.clippedHighlightsPercent,
                f.clippedShadowsPercent,
                f.colorTemperature,
                f.saturation,
                f.centerWeightedLuminance
            ])

            targets.append((sample.userChosenISO, sample.userChosenShutterSeconds))
        }

        return (features, targets)
    }
}
