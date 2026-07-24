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

import CoreML
import CreateML
import TabularData
import Foundation
import UIKit

/// Handles on-device model training (two sequential MLBoostedTreeRegressors).
///
/// Training is kicked off by `AutoExposureManager`, which can call `train(completion:)`
/// from two triggers that may land close together — recording a new sample while the
/// device is charging, and the battery transitioning to charging. The single in-flight
/// run enforced here keeps those triggers from launching overlapping runs that would
/// collide on the fixed model filenames they write.
@available(iOS 15.0, *)
class ModelTrainer {

    enum TrainingError: Error {
        /// Another run is already in progress — this request was ignored.
        case alreadyRunning
    }

    private let dataManager: TrainingDataManager

    // Shared single-flight guard across the foreground + background training paths.
    private static let lock = NSLock()
    private static var _isTraining = false

    /// Whether a training run is currently active anywhere in the app. Callers
    /// check this before kicking off work (and before showing UI for it).
    static var isCurrentlyTraining: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isTraining
    }

    init(dataManager: TrainingDataManager) {
        self.dataManager = dataManager
    }

    /// Train on a background queue, then post `.mlModelUpdated` (success) or
    /// `.mlModelTrainingFailed` (failure) and call `completion` on the main queue.
    ///
    /// The work is wrapped in a background-time assertion so a foreground-initiated
    /// run still finishes (~10s) if the user backgrounds the app mid-train. Returns
    /// immediately with `.alreadyRunning` if another run is in flight.
    func train(completion: @escaping (Result<Void, Error>) -> Void) {
        Self.lock.lock()
        if Self._isTraining {
            Self.lock.unlock()
            print("Training already in progress — ignoring duplicate request")
            completion(.failure(TrainingError.alreadyRunning))
            return
        }
        Self._isTraining = true
        Self.lock.unlock()

        print("Scheduling training with \(dataManager.dataset.samples.count) samples")

        // Background-time assertion so the run survives a mid-train backgrounding.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ModelTraining") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        DispatchQueue.global(qos: .background).async { [self] in
            let result: Result<Void, Error>
            do {
                try performTraining()
                result = .success(())
            } catch {
                result = .failure(error)
            }

            Self.lock.lock(); Self._isTraining = false; Self.lock.unlock()

            DispatchQueue.main.async {
                switch result {
                case .success:
                    print("Model training completed")
                    NotificationCenter.default.post(name: .mlModelUpdated, object: nil)
                case .failure(let error):
                    print("Model training failed: \(error)")
                    NotificationCenter.default.post(name: .mlModelTrainingFailed, object: nil)
                }
                completion(result)
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }
    }

    /// Train synchronously (called on a background queue by `train`). Throws on any
    /// failure so the caller can report it.
    private func performTraining() throws {
        print("Starting model training...")

        let startTime = Date()

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
            targetColumn: "targetLogISO"
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
            targetColumn: "targetLogShutter"
        )
        print("Shutter model trained successfully")

        // Save both models
        print("Step 6: Saving models...")
        let tempDir = FileManager.default.temporaryDirectory
        let isoModelURL = tempDir.appendingPathComponent("ISORegressor.mlmodel")
        let shutterModelURL = tempDir.appendingPathComponent("ShutterRegressor.mlmodel")

        let metadata = MLModelMetadata(
            author: "PureLenz",
            shortDescription: "Auto-exposure regressor trained on user preferences (sequential prediction, log2 targets)",
            version: "2.0"
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
        let finalISOURL = documentsPath.appendingPathComponent("ISORegressorV2.mlmodelc")
        let finalShutterURL = documentsPath.appendingPathComponent("ShutterRegressorV2.mlmodelc")

        // Remove old models if they exist
        try? FileManager.default.removeItem(at: finalISOURL)
        try? FileManager.default.removeItem(at: finalShutterURL)

        try FileManager.default.copyItem(at: compiledISOURL, to: finalISOURL)
        try FileManager.default.copyItem(at: compiledShutterURL, to: finalShutterURL)
        print("Models installed to Documents directory")

        let elapsed = Date().timeIntervalSince(startTime)
        print("Model training completed in \(String(format: "%.1f", elapsed))s")
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
                f.centerWeightedLuminance,
                // Samples recorded before sceneLightLevel existed lack it, so
                // recompute it from the sample's labels. Exact for captures shot
                // at dialed-in settings; for legacy continuous-AE captures the
                // label itself was a stale snapshot, so this stays consistent
                // with the label rather than the true scene light — no worse
                // than the sample already was.
                f.sceneLightLevel ?? SceneFeatures.computeSceneLightLevel(
                    meanLuminance: f.meanLuminance,
                    iso: sample.userChosenISO,
                    shutterSeconds: sample.userChosenShutterSeconds
                )
            ])

            targets.append((sample.userChosenISO, sample.userChosenShutterSeconds))
        }

        return (features, targets)
    }
}
