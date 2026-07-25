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
import SwiftUI
import Observation
import UIKit
import OSLog

@Observable
class AutoExposureManager {
    // MARK: - State

    enum State: Equatable {
        case disabled              // Not enough training data, no model available
        case ready                 // Model loaded, waiting for startup
        case inferring             // Running inference
        case applied               // AI exposure applied successfully
        case manualOverride        // User dragged knob, AI disabled for session
        case error(String)         // Model loading/inference failed
    }

    private(set) var state: State = .disabled
    private(set) var hasRunStartupInference = false

    enum InferenceError: LocalizedError {
        /// The model's output was missing the expected feature column.
        case invalidModelOutput(String)

        var errorDescription: String? {
            switch self {
            case .invalidModelOutput(let column):
                return "Invalid model output (missing \(column))"
            }
        }
    }

    // MARK: - Dependencies

    private var isoModel: MLModel?
    private var shutterModel: MLModel?
    private let featureExtractor = SceneFeatureExtractor()
    private let dataManager: TrainingDataManager

    // MARK: - Initialization

    init(dataManager: TrainingDataManager) {
        self.dataManager = dataManager
        // One-time migration before the first load; V1 files never reappear,
        // so the reloads after each training run skip this.
        removeLegacyV1Models()
        loadModel()

        // Reload the model whenever a training run finishes successfully.
        NotificationCenter.default.addObserver(
            forName: .mlModelUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadModel()
        }

        // Listen for battery charging state changes
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleBatteryStateChange()
        }

        // The battery observer only fires on state *changes*, so a launch that
        // happens while already on the charger would otherwise wait for the
        // next plug-in (or a capture while charging) before training. Check
        // once now; the callee guards charging, sample count, and single-flight.
        checkAndTriggerTrainingIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    // MARK: - Model Management

    private func loadModel() {
        let isoURL = MLModelFiles.isoModelURL
        let shutterURL = MLModelFiles.shutterModelURL

        // Check if both models exist
        guard FileManager.default.fileExists(atPath: isoURL.path),
              FileManager.default.fileExists(atPath: shutterURL.path) else {
            // No models yet, wait for training
            state = .disabled
            print("No ML models found - will use iOS auto until trained")
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine

            isoModel = try MLModel(contentsOf: isoURL, configuration: config)
            shutterModel = try MLModel(contentsOf: shutterURL, configuration: config)

            state = .ready
            print("Both ML models loaded successfully (sequential prediction)")
        } catch {
            state = .error("Failed to load models: \(error.localizedDescription)")
            print("Model load error: \(error)")
        }
    }

    func reloadModel() {
        print("Reloading ML model...")
        loadModel()
    }

    // MARK: - Startup Inference

    /// Run ML inference ONCE at startup, return predicted exposure settings
    /// Uses SEQUENTIAL PREDICTION: ISO first, then shutter based on predicted ISO
    /// - Parameter frame: Live camera preview frame plus the exposure it was captured with
    /// - Returns: (iso, shutterSeconds) if successful, nil otherwise
    func runStartupInference(from frame: CameraService.CapturedFrame) -> (iso: Float, shutterSeconds: Double)? {
        guard !hasRunStartupInference else {
            print("Startup inference already completed")
            return nil
        }

        guard case .ready = state,
              let isoModel = isoModel,
              let shutterModel = shutterModel else {
            print("Models not ready for inference (state: \(state))")
            return nil
        }

        guard let prediction = performInference(
            from: frame, isoModel: isoModel, shutterModel: shutterModel, label: "Sequential"
        ) else { return nil }

        hasRunStartupInference = true
        return prediction
    }

    /// Run ML inference manually (triggered by user action like long press)
    /// Unlike runStartupInference, this can be called multiple times
    /// - Parameter frame: Live camera preview frame plus the exposure it was captured with
    /// - Returns: (iso, shutterSeconds) if successful, nil otherwise
    func runManualInference(from frame: CameraService.CapturedFrame) -> (iso: Float, shutterSeconds: Double)? {
        guard let isoModel = isoModel,
              let shutterModel = shutterModel else {
            print("Models not available for manual inference (state: \(state))")
            return nil
        }

        // Allow manual inference unless disabled or already inferring
        switch state {
        case .disabled:
            print("Cannot run inference - no models trained yet")
            return nil
        case .error(let message):
            print("Cannot run inference - error state: \(message)")
            return nil
        case .inferring:
            print("Inference already in progress")
            return nil
        default:
            break // .ready, .applied, .manualOverride are all valid
        }

        return performInference(
            from: frame, isoModel: isoModel, shutterModel: shutterModel, label: "Manual"
        )
    }

    /// Shared body of startup and manual inference: extract features, run the
    /// two-stage prediction, and drive the `state` transitions. `label`
    /// prefixes the log lines.
    private func performInference(
        from frame: CameraService.CapturedFrame,
        isoModel: MLModel,
        shutterModel: MLModel,
        label: String
    ) -> (iso: Float, shutterSeconds: Double)? {
        state = .inferring
        let start = ContinuousClock.now

        // 1. Extract features
        guard let features = featureExtractor.extract(
            from: frame.image,
            frameISO: frame.iso,
            frameShutterSeconds: frame.shutterSeconds
        ) else {
            state = .error("Feature extraction failed")
            return nil
        }

        // 2. SEQUENTIAL PREDICTION
        do {
            let prediction = try predictExposure(
                features: features,
                isoModel: isoModel,
                shutterModel: shutterModel
            )

            let elapsed = start.duration(to: ContinuousClock.now)
            print("\(label) ML inference completed in \(elapsed.formatted(.units(allowed: [.milliseconds], width: .abbreviated, fractionalPart: .show(length: 1))))")
            print("     ISO: \(Int(prediction.iso))")
            print("     Shutter: 1/\(Int(1.0/prediction.shutterSeconds))")

            state = .applied
            return prediction

        } catch {
            state = .error("Inference failed: \(error.localizedDescription)")
            print("\(label) inference error: \(error)")
            return nil
        }
    }

    /// Two-stage prediction: ISO from scene features, then shutter from scene
    /// features + the predicted ISO (as `chosenLogISO`). Both models predict
    /// in log2 (stops) space — see DataFrameBuilder for why — so outputs are
    /// exponentiated back to raw ISO / seconds here.
    private func predictExposure(
        features: SceneFeatures,
        isoModel: MLModel,
        shutterModel: MLModel
    ) throws -> (iso: Float, shutterSeconds: Double) {
        let sceneFeatures = try features.toMLFeatureProvider()

        // Step 1: Predict log2(ISO) from scene features
        let isoPrediction = try isoModel.prediction(from: sceneFeatures)
        guard let predictedLogISO = isoPrediction.featureValue(for: "targetLogISO")?.doubleValue else {
            throw InferenceError.invalidModelOutput("targetLogISO")
        }

        // Step 2: Predict log2(shutter) from scene features + predicted log2(ISO)
        var shutterFeaturesDict = sceneFeatures.featureNames.reduce(into: [String: Any]()) { dict, name in
            dict[name] = sceneFeatures.featureValue(for: name)?.doubleValue ?? 0.0
        }
        shutterFeaturesDict["chosenLogISO"] = predictedLogISO

        let shutterFeatures = try MLDictionaryFeatureProvider(dictionary: shutterFeaturesDict)
        let shutterPrediction = try shutterModel.prediction(from: shutterFeatures)

        guard let predictedLogShutter = shutterPrediction.featureValue(for: "targetLogShutter")?.doubleValue else {
            throw InferenceError.invalidModelOutput("targetLogShutter")
        }

        return (iso: Float(exp2(predictedLogISO)), shutterSeconds: exp2(predictedLogShutter))
    }

    // MARK: - Manual Override

    /// Called when user drags knob - disables AI for current session
    func notifyManualOverride() {
        guard state == .applied else { return }
        state = .manualOverride
        print("AI disabled due to manual override")
    }

    /// Reset for next session (called on app restart)
    func resetForNewSession() {
        hasRunStartupInference = false
        // Reset state to .ready if it was .applied or .manualOverride
        if case .applied = state {
            state = .ready
        } else if case .manualOverride = state {
            state = .ready
        }
    }

    // MARK: - Training Data Collection

    /// Save training sample when user manually adjusts and captures
    func recordTrainingSample(features: SceneFeatures, iso: Float, shutterSeconds: Double) {
        let sample = TrainingSample(features: features, iso: iso, shutterSeconds: shutterSeconds)
        dataManager.addSample(sample)
        print("Recorded training sample (\(dataManager.dataset.samples.count) total)")

        // Check if we should train (only when charging)
        checkAndTriggerTrainingIfNeeded()
    }

    /// Handle battery state changes - trigger training if now charging
    private func handleBatteryStateChange() {
        let batteryState = UIDevice.current.batteryState

        if batteryState == .charging || batteryState == .full {
            print("Device is charging - checking if training needed")
            checkAndTriggerTrainingIfNeeded()
        }
    }

    /// Whether both installed models were already built from the dataset as it
    /// currently stands. `ModelTrainer` stamps each model it installs with the
    /// `lastUpdated` of the dataset it snapshotted, so a model that is not older
    /// than the dataset was trained on exactly these samples.
    ///
    /// The edge cases fall out: no model yet means no date, so it trains; a run
    /// that failed leaves the previous stamp in place, so the next trigger
    /// retries; a sample added since the last run makes the dataset newer.
    private var isTrainingUpToDate: Bool {
        // A stamp does not survive the filesystem exactly: `Date` is a Double of
        // seconds and the on-disk timestamp is a timespec, so a value read back
        // lands within a few hundred nanoseconds either side of what was written.
        // Without slack, a model built from precisely this dataset can measure a
        // nanosecond older than it and retrain anyway. Real new data is separated
        // by a capture — milliseconds at the very least — so this is far too
        // small to swallow a sample.
        let filesystemTimestampSlack: TimeInterval = 0.001

        let modelDates = [MLModelFiles.isoModelURL, MLModelFiles.shutterModelURL].compactMap { url -> Date? in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        }
        guard modelDates.count == 2 else { return false }

        let datasetVersion = dataManager.dataset.lastUpdated
        return modelDates.allSatisfy {
            $0.timeIntervalSince(datasetVersion) >= -filesystemTimestampSlack
        }
    }

    /// Check conditions and trigger training if appropriate
    private func checkAndTriggerTrainingIfNeeded() {
        // Only train if device is charging
        let batteryState = UIDevice.current.batteryState
        guard batteryState == .charging || batteryState == .full else {
            if dataManager.dataset.isReadyForTraining {
                print("Ready to train (\(dataManager.dataset.samples.count) samples) but waiting for charging")
            }
            return
        }

        // Must have enough samples
        guard dataManager.dataset.isReadyForTraining else {
            return
        }

        // Single-flight: the capture trigger and the battery-state trigger can fire
        // close together — don't launch a second run on top of one already going.
        guard !ModelTrainer.isCurrentlyTraining else {
            print("Training already in progress — skipping")
            return
        }

        // Two of the three triggers (launch, plugging in) say nothing about new
        // data, so without this the same samples are refit into identical models
        // on every launch while charging — burning battery and briefly removing
        // two loadable models for no gain.
        guard !isTrainingUpToDate else {
            print("Models already built from the current dataset — skipping training")
            return
        }

        let sampleCount = dataManager.dataset.samples.count
        print("Starting training: device charging + \(sampleCount) samples")

        let trainer = ModelTrainer(dataManager: dataManager)
        trainer.train { _ in }
    }

    // MARK: - Rotation Angle Calculation (Inverse Mapping)
    // NOTE: These methods delegate to ExposureCalculator for consistency

    /// Calculate rotation angle from ISO value (inverse of CaptureButton's logarithmic mapping)
    static func rotationAngleForISO(_ iso: Float, min: Float, max: Float) -> Angle {
        return ExposureCalculator.angleFromISO(iso, min: min, max: max)
    }

    /// Calculate rotation angle from shutter speed (inverse of CaptureButton's logarithmic mapping)
    static func rotationAngleForShutter(_ shutterSeconds: Double, min: Double, max: Double) -> Angle {
        return ExposureCalculator.angleFromShutter(shutterSeconds, min: min, max: max)
    }

    // MARK: - Utilities

    /// Delete V1 models (raw-linear target schema). Their output columns don't
    /// match the log2-space readers, so they must never be loaded; V2 models
    /// train from freshly recorded samples (the old dataset is discarded too).
    private func removeLegacyV1Models() {
        for url in MLModelFiles.legacyModelURLs {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                Logger.ml.info("Removed legacy V1 model \(url.lastPathComponent)")
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let mlModelUpdated = Notification.Name("MLModelUpdated")
    static let mlModelTrainingFailed = Notification.Name("MLModelTrainingFailed")
}
