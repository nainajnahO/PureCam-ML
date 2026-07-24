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

/// Manages persistence and retrieval of training data
class TrainingDataManager {
    // MARK: - Properties

    private let fileURL: URL
    private(set) var dataset: TrainingDataset

    // MARK: - Initialization

    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documentsPath.appendingPathComponent("trainingData.json")
        self.dataset = Self.loadDataset(from: fileURL) ?? TrainingDataset()

        print("TrainingDataManager initialized with \(dataset.samples.count) existing samples")
    }

    // MARK: - Public Methods

    /// Add a new training sample and persist to disk
    func addSample(_ sample: TrainingSample) {
        dataset.addSample(sample)
        saveDataset()
        print("Added training sample (\(dataset.samples.count) total)")
    }

    /// Clear all training data
    func clearAllData() {
        dataset = TrainingDataset()
        saveDataset()
        print("Cleared all training data")
    }

    // MARK: - Private Methods

    private func saveDataset() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(dataset)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save training data: \(error)")
        }
    }

    private static func loadDataset(from url: URL) -> TrainingDataset? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("No existing training data found")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let dataset = try decoder.decode(TrainingDataset.self, from: data)
            print("Loaded \(dataset.samples.count) training samples")
            return dataset
        } catch {
            // Also the intended path for pre-sceneLightLevel datasets: the field
            // is required, so old data fails decode and recording starts fresh.
            print("Failed to load training data: \(error)")
            return nil
        }
    }
}
