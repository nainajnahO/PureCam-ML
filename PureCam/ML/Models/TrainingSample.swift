import Foundation

/// A single training sample: scene features + user's chosen exposure settings
struct TrainingSample: Codable, Identifiable {
    /// Unique identifier for this sample
    let id: UUID

    /// Scene features at capture time
    let features: SceneFeatures

    /// The ISO value the user chose
    let userChosenISO: Float

    /// The shutter speed the user chose (in seconds)
    let userChosenShutterSeconds: Double

    /// When this sample was captured
    let capturedAt: Date

    init(features: SceneFeatures, iso: Float, shutterSeconds: Double) {
        self.id = UUID()
        self.features = features
        self.userChosenISO = iso
        self.userChosenShutterSeconds = shutterSeconds
        self.capturedAt = Date()
    }
}

/// Storage container for the training dataset
struct TrainingDataset: Codable {
    /// All training samples (max 500, FIFO)
    var samples: [TrainingSample]

    /// When the dataset was first created
    var createdAt: Date

    /// When the dataset was last modified
    var lastUpdated: Date

    init() {
        self.samples = []
        self.createdAt = Date()
        self.lastUpdated = Date()
    }

    /// Add a new training sample
    /// Maintains FIFO queue with max 500 samples
    mutating func addSample(_ sample: TrainingSample) {
        samples.append(sample)
        lastUpdated = Date()

        // FIFO: Keep only last 500 samples
        if samples.count > 500 {
            samples.removeFirst(samples.count - 500)
        }
    }

    /// Whether we have enough samples to start training
    var isReadyForTraining: Bool {
        samples.count >= 30
    }
}
