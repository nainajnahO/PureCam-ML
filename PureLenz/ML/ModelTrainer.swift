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
import Foundation
import OSLog
import UIKit

/// Handles on-device model training (two sequential MLBoostedTreeRegressors).
///
/// `AutoExposureManager` owns one long-lived trainer and calls `train()` from
/// two triggers that may land close together — recording a new sample while
/// the device is charging, and the battery transitioning to charging. The
/// single in-flight run enforced here keeps those triggers from launching
/// overlapping runs that would collide on the fixed model filenames they write.
class ModelTrainer {

    private let dataManager: TrainingDataManager

    // Single-flight guard, deliberately process-wide rather than per-instance:
    // the model filenames written by `performTraining` are fixed, so two
    // concurrent runs collide on them no matter which trainer started them.
    // Scoping this to the instance would make correctness depend on there being
    // exactly one trainer alive, which nothing enforces — `CameraScene` is built
    // from a `@State` default value, and that expression is re-evaluated on
    // every enclosing view initialization.
    private static let lock = NSLock()
    private static var isTraining = false

    init(dataManager: TrainingDataManager) {
        self.dataManager = dataManager
    }

    /// Train on a background queue, then post `.mlModelUpdated` on the main
    /// queue on success. Returns immediately if another run is in flight.
    ///
    /// The work is wrapped in a background-time assertion so a foreground-initiated
    /// run still finishes (~10s) if the user backgrounds the app mid-train.
    func train() {
        Self.lock.lock()
        if Self.isTraining {
            Self.lock.unlock()
            Logger.ml.info("Training already in progress — ignoring duplicate request")
            return
        }
        Self.isTraining = true
        Self.lock.unlock()

        // Background-time assertion so the run survives a mid-train backgrounding.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ModelTraining") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { try performTraining() }

            Self.lock.lock()
            Self.isTraining = false
            Self.lock.unlock()

            DispatchQueue.main.async {
                switch result {
                case .success(let trainedThroughSampleID):
                    // Marked here rather than on the training queue so every
                    // mutation of the dataset happens on main, alongside
                    // `addSample`.
                    dataManager.markTrained(throughSampleID: trainedThroughSampleID)
                    NotificationCenter.default.post(name: .mlModelUpdated, object: nil)
                case .failure(let error):
                    Logger.ml.error("Model training failed: \(error.localizedDescription)")
                }
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }
    }

    /// Train synchronously (called on a background queue by `train`). Throws on
    /// any failure so the caller can report it.
    ///
    /// - Returns: The newest sample the resulting models were trained on, for
    ///   the caller to record once they are installed.
    private func performTraining() throws -> UUID? {
        let start = ContinuousClock.now

        // One snapshot, so the samples trained on and the id reported back are
        // guaranteed to describe the same dataset even if it grows mid-run.
        let samples = dataManager.dataset.samples
        Logger.ml.info("Training on \(samples.count) samples")

        // SEQUENTIAL PREDICTION, stage 1: ISO model (scene features → log2 ISO).
        let isoRegressor = try MLBoostedTreeRegressor(
            trainingData: DataFrameBuilder.createISODataFrame(samples: samples),
            targetColumn: "targetLogISO"
        )

        // Stage 2: shutter model with the chosen log2 ISO as an extra feature.
        let shutterRegressor = try MLBoostedTreeRegressor(
            trainingData: DataFrameBuilder.createShutterDataFrame(samples: samples),
            targetColumn: "targetLogShutter"
        )

        // Write both models, compile them (required for the iOS runtime), and
        // install the compiled models in the Documents directory.
        let tempDir = FileManager.default.temporaryDirectory
        let isoModelURL = tempDir.appendingPathComponent("ISORegressor.mlmodel")
        let shutterModelURL = tempDir.appendingPathComponent("ShutterRegressor.mlmodel")

        let metadata = MLModelMetadata(
            author: "PureLenz",
            shortDescription: "Auto-exposure regressor trained on user preferences (sequential prediction, log2 targets)",
            version: "3.0"
        )

        try isoRegressor.write(to: isoModelURL, metadata: metadata)
        try shutterRegressor.write(to: shutterModelURL, metadata: metadata)

        let compiledISOURL = try MLModel.compileModel(at: isoModelURL)
        let compiledShutterURL = try MLModel.compileModel(at: shutterModelURL)

        try? FileManager.default.removeItem(at: MLFiles.isoModelURL)
        try? FileManager.default.removeItem(at: MLFiles.shutterModelURL)
        try FileManager.default.copyItem(at: compiledISOURL, to: MLFiles.isoModelURL)
        try FileManager.default.copyItem(at: compiledShutterURL, to: MLFiles.shutterModelURL)

        let elapsed = start.duration(to: .now)
        Logger.ml.info("Model training completed in \(elapsed.formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1))))")

        return samples.last?.id
    }
}
