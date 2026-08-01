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
    /// Retained-sample cap used when Settings holds no value of its own. Kept in
    /// step with the `maxTrainingSamples` default in `Settings.bundle/Root.plist`.
    static let defaultMaxSamples = 500

    /// All training samples (FIFO, capped — see `addSample(_:maxSamples:)`)
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

    /// Add a new training sample, dropping the oldest past `maxSamples`.
    ///
    /// - Parameters:
    ///   - sample: The sample to append.
    ///   - maxSamples: Retained-sample cap, configurable in the Settings app.
    /// - Returns: The samples evicted by this call, so the caller can release
    ///   whatever it stores per sample. Empty until the cap is reached.
    @discardableResult
    mutating func addSample(
        _ sample: TrainingSample,
        maxSamples: Int = Self.defaultMaxSamples
    ) -> [TrainingSample] {
        samples.append(sample)
        lastUpdated = Date()

        // FIFO: keep only the most recent `maxSamples`. Lowering the cap in
        // Settings drops the whole backlog on the next capture, not a single
        // sample, so every dropped sample is returned rather than just the head.
        let overflow = samples.count - maxSamples
        guard overflow > 0 else { return [] }

        let evicted = Array(samples.prefix(overflow))
        samples.removeFirst(overflow)
        return evicted
    }

    /// Whether we have enough samples to start training
    var isReadyForTraining: Bool {
        samples.count >= 30
    }
}
