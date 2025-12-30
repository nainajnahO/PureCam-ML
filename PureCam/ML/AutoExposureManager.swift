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
import SwiftUI
import Observation

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

    // MARK: - Dependencies

    private var isoModel: MLModel?
    private var shutterModel: MLModel?
    private let featureExtractor = SceneFeatureExtractor()
    private let dataManager: TrainingDataManager

    // MARK: - Initialization

    init(dataManager: TrainingDataManager) {
        self.dataManager = dataManager
        loadModel()

        // Listen for model updates
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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    // MARK: - Model Management

    private func loadModel() {
        let isoURL = getISOModelURL()
        let shutterURL = getShutterModelURL()

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
    /// - Parameter previewImage: Live camera preview (CIImage from video buffer)
    /// - Returns: (iso, shutterSeconds) if successful, nil otherwise
    func runStartupInference(from previewImage: CIImage) -> (iso: Float, shutterSeconds: Double)? {
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

        state = .inferring

        let startTime = Date()

        // 1. Extract features
        guard let features = featureExtractor.extract(from: previewImage) else {
            state = .error("Feature extraction failed")
            return nil
        }

        // 2. SEQUENTIAL PREDICTION
        do {
            let sceneFeatures = try features.toMLFeatureProvider()

            // Step 1: Predict ISO from scene features
            let isoPrediction = try isoModel.prediction(from: sceneFeatures)
            guard let predictedISO = isoPrediction.featureValue(for: "targetISO")?.doubleValue else {
                state = .error("Invalid ISO prediction output")
                return nil
            }

            // Step 2: Predict shutter from scene features + predicted ISO
            var shutterFeaturesDict = sceneFeatures.featureNames.reduce(into: [String: Any]()) { dict, name in
                dict[name] = sceneFeatures.featureValue(for: name)?.doubleValue ?? 0.0
            }
            // Add predicted ISO as additional feature
            shutterFeaturesDict["chosenISO"] = predictedISO

            let shutterFeatures = try MLDictionaryFeatureProvider(dictionary: shutterFeaturesDict)
            let shutterPrediction = try shutterModel.prediction(from: shutterFeatures)

            guard let predictedShutter = shutterPrediction.featureValue(for: "targetShutterSeconds")?.doubleValue else {
                state = .error("Invalid shutter prediction output")
                return nil
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            print("Sequential ML inference completed in \(String(format: "%.1f", elapsed))ms")
            print("     ISO: \(Int(predictedISO))")
            print("     Shutter: 1/\(Int(1.0/predictedShutter))")

            hasRunStartupInference = true
            state = .applied

            return (iso: Float(predictedISO), shutterSeconds: predictedShutter)

        } catch {
            state = .error("Inference failed: \(error.localizedDescription)")
            print("Inference error: \(error)")
            return nil
        }
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

        // Trigger training
        print("Starting training: device charging + \(dataManager.dataset.samples.count) samples")

        if #available(iOS 15.0, *) {
            let trainer = ModelTrainer(modelURL: getModelURL(), dataManager: dataManager)
            trainer.scheduleBackgroundTrainingIfNeeded()
        } else {
            print("Training requires iOS 15+")
        }
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

    private func getISOModelURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("ISORegressor.mlmodelc")
    }

    private func getShutterModelURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("ShutterRegressor.mlmodelc")
    }

    // Legacy method for backwards compatibility
    private func getModelURL() -> URL {
        return getISOModelURL()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let mlModelUpdated = Notification.Name("MLModelUpdated")
}
