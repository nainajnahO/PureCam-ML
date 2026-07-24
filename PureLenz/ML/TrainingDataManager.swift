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
import OSLog

/// Manages persistence and retrieval of training data
class TrainingDataManager {
    // MARK: - Properties

    private let fileURL: URL
    private(set) var dataset: TrainingDataset

    // MARK: - Initialization

    init() {
        self.fileURL = URL.documentsDirectory.appendingPathComponent("trainingDataV2.json")

        // V1 samples lack sceneLightLevel and carry potentially stale exposure
        // labels, so they can't train the V2 models — delete the old dataset
        // and start recording fresh.
        try? FileManager.default.removeItem(
            at: URL.documentsDirectory.appendingPathComponent("trainingData.json")
        )

        self.dataset = Self.loadDataset(from: fileURL) ?? TrainingDataset()
    }

    // MARK: - Public Methods

    /// Add a new training sample and persist to disk
    func addSample(_ sample: TrainingSample) {
        dataset.addSample(sample)
        saveDataset()
        Logger.ml.info("Added training sample (\(self.dataset.samples.count) total)")
    }

    // MARK: - Private Methods

    private func saveDataset() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(dataset)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.ml.error("Failed to save training data: \(error.localizedDescription)")
        }
    }

    private static func loadDataset(from url: URL) -> TrainingDataset? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.ml.info("No existing training data found")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let dataset = try decoder.decode(TrainingDataset.self, from: data)
            Logger.ml.info("Loaded \(dataset.samples.count) training samples")
            return dataset
        } catch {
            Logger.ml.error("Failed to load training data: \(error.localizedDescription)")
            return nil
        }
    }
}
