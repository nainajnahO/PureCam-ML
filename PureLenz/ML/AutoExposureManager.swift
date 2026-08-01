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
import Observation
import UIKit
import OSLog

@Observable
class AutoExposureManager {
    // MARK: - State

    enum State: Equatable {
        case disabled              // Not enough training data, no model available
        case loading               // Models exist on disk, being loaded
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
    private let trainer: ModelTrainer

    // MARK: - Initialization

    init(dataManager: TrainingDataManager) {
        self.dataManager = dataManager
        self.trainer = ModelTrainer(dataManager: dataManager)
        loadModel()

        // Reclaim space from earlier schema versions. Housekeeping only — the
        // versioned filenames are what make stale artifacts safe — so it runs
        // off-main and never blocks startup. It only ever deletes names that
        // are not the current ones, so it cannot race the load above.
        DispatchQueue.global(qos: .utility).async {
            MLFiles.removeSupersededArtifacts()
        }

        // Reload the model whenever a training run finishes successfully.
        NotificationCenter.default.addObserver(
            forName: .mlModelUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadModel()
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

    /// Load (or reload) both compiled models.
    ///
    /// The existence check stays synchronous — it is two `stat` calls, and it
    /// decides between two states that mean very different things: `.disabled`
    /// is "no model has ever been trained, so record what the user shoots",
    /// while `.loading` is "a trained model is on its way". Leaving `state` at
    /// `.disabled` while a trained model loaded would make a capture in that
    /// window record a sample labelled with iOS auto-exposure rather than a
    /// user preference.
    ///
    /// Only the expensive part — constructing the two `MLModel`s — goes to a
    /// background queue, so the first frame never waits on it. Until that
    /// lands, `.loading` reports not-ready to both inference paths and is
    /// excluded from `wantsTrainingSample`.
    private func loadModel() {
        let isoURL = MLFiles.isoModelURL
        let shutterURL = MLFiles.shutterModelURL

        guard FileManager.default.fileExists(atPath: isoURL.path),
              FileManager.default.fileExists(atPath: shutterURL.path) else {
            isoModel = nil
            shutterModel = nil
            state = .disabled
            Logger.ml.info("No ML models found - will use iOS auto until trained")
            return
        }

        state = .loading

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let newState: State
            var models: (iso: MLModel, shutter: MLModel)?
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                models = (
                    iso: try MLModel(contentsOf: isoURL, configuration: config),
                    shutter: try MLModel(contentsOf: shutterURL, configuration: config)
                )
                newState = .ready
                Logger.ml.info("Both ML models loaded successfully (sequential prediction)")
            } catch {
                newState = .error("Failed to load models: \(error.localizedDescription)")
                Logger.ml.error("Model load error: \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isoModel = models?.iso
                self.shutterModel = models?.shutter
                self.state = newState
            }
        }
    }

    // MARK: - Startup Inference

    /// Run ML inference ONCE at startup, return predicted exposure settings
    /// Uses SEQUENTIAL PREDICTION: ISO first, then shutter based on predicted ISO
    /// - Parameter frame: Live camera preview frame plus the exposure it was captured with
    /// - Returns: (iso, shutterSeconds) if successful, nil otherwise
    func runStartupInference(from frame: CameraService.CapturedFrame) -> (iso: Float, shutterSeconds: Double)? {
        guard !hasRunStartupInference else {
            Logger.ml.debug("Startup inference already completed")
            return nil
        }

        guard case .ready = state,
              let isoModel = isoModel,
              let shutterModel = shutterModel else {
            Logger.ml.debug("Models not ready for inference")
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
            Logger.ml.debug("Models not available for manual inference")
            return nil
        }

        // Allow manual inference unless disabled, still loading, or already inferring
        switch state {
        case .disabled:
            Logger.ml.debug("Cannot run inference - no models trained yet")
            return nil
        case .loading:
            Logger.ml.debug("Cannot run inference - models still loading")
            return nil
        case .error(let message):
            Logger.ml.error("Cannot run inference - error state: \(message)")
            return nil
        case .inferring:
            Logger.ml.debug("Inference already in progress")
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

            let elapsed = start.duration(to: .now)
            Logger.ml.info("""
                \(label) ML inference completed in \(elapsed.formatted(.units(allowed: [.milliseconds], width: .abbreviated, fractionalPart: .show(length: 1)))): \
                ISO \(Int(prediction.iso)), shutter 1/\(Int(1.0 / prediction.shutterSeconds))
                """)

            state = .applied
            return prediction

        } catch {
            state = .error("Inference failed: \(error.localizedDescription)")
            Logger.ml.error("\(label) inference error: \(error.localizedDescription)")
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
        Logger.ml.info("AI disabled due to manual override")
    }

    /// Reset for next session (called by the coordinator on becoming active)
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

    /// Whether a capture right now should be recorded as a training sample:
    /// while collecting initial data (.disabled), after a manual override
    /// (.manualOverride), or when the model failed (.error) and needs retraining.
    var wantsTrainingSample: Bool {
        switch state {
        case .disabled, .manualOverride, .error:
            return true
        default:
            return false
        }
    }

    /// Extract features from a captured frame and persist them as a training
    /// sample, then trigger training if conditions allow. No-op unless
    /// `wantsTrainingSample`.
    func recordTrainingSampleIfNeeded(from frame: CameraService.CapturedFrame) {
        guard wantsTrainingSample else { return }

        // Features and thumbnail come from one call so the source frame is
        // downsampled once rather than once per output — this runs on the main
        // actor at shutter press.
        guard let extracted = featureExtractor.extractWithThumbnail(
            from: frame.image,
            frameISO: frame.iso,
            frameShutterSeconds: frame.shutterSeconds
        ) else { return }

        // Label with the frame's own exposure, not the cached
        // currentISO/currentShutterSpeed, which goes stale under continuous
        // auto-exposure — see CameraService.CapturedFrame.
        //
        // The thumbnail is the analysed frame itself. Keeping it is what lets a
        // feature added to the schema later be computed for this sample rather
        // than forcing the dataset to be discarded — see MLFiles.thumbnailDirectoryURL.
        dataManager.addSample(
            TrainingSample(
                features: extracted.features,
                iso: frame.iso,
                shutterSeconds: frame.shutterSeconds
            ),
            thumbnail: extracted.thumbnail
        )

        // Check if we should train (only when charging)
        checkAndTriggerTrainingIfNeeded()
    }

    /// Handle battery state changes - trigger training if now charging
    private func handleBatteryStateChange() {
        let batteryState = UIDevice.current.batteryState

        if batteryState == .charging || batteryState == .full {
            checkAndTriggerTrainingIfNeeded()
        }
    }

    /// Check conditions and trigger training if appropriate
    private func checkAndTriggerTrainingIfNeeded() {
        // Only train if device is charging
        let batteryState = UIDevice.current.batteryState
        guard batteryState == .charging || batteryState == .full else {
            if dataManager.dataset.isReadyForTraining {
                Logger.ml.debug("Ready to train (\(self.dataManager.dataset.samples.count) samples) but waiting for charging")
            }
            return
        }

        // Must have enough samples
        guard dataManager.dataset.isReadyForTraining else {
            return
        }

        Logger.ml.info("Starting training: device charging + \(self.dataManager.dataset.samples.count) samples")
        trainer.train()
    }

}

// MARK: - Notification Names

extension Notification.Name {
    static let mlModelUpdated = Notification.Name("MLModelUpdated")
}
