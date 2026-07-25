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
        self.fileURL = MLFiles.trainingDataURL
        self.dataset = Self.loadDataset(from: fileURL) ?? TrainingDataset()

        // Synchronous, and before any sample can be added: a background prune
        // would race `addSample`, deleting a thumbnail written after the prune
        // snapshotted the sample IDs. Enumerating at most `maxSamples` entries
        // costs far less than the JSON decode above that already ran here.
        pruneOrphanedThumbnails()
    }

    // MARK: - Public Methods

    /// Add a new training sample and persist to disk.
    ///
    /// - Parameters:
    ///   - sample: The sample to record.
    ///   - thumbnail: JPEG of the analysed frame, kept so features added to the
    ///     schema later can be computed for this sample instead of leaving it
    ///     unusable. Optional because a sample with no thumbnail is still a
    ///     valid training row — it just cannot be backfilled.
    func addSample(_ sample: TrainingSample, thumbnail: Data?) {
        // Written before the sample is recorded, so the dataset never refers to
        // a thumbnail whose write was not attempted. The reverse order could
        // leave a sample pointing at a file that never arrived; this order can
        // only leave an orphan file, which the next launch prunes.
        if let thumbnail {
            writeThumbnail(thumbnail, for: sample.id)
        }

        let evicted = dataset.addSample(sample)
        saveDataset()

        for evictedSample in evicted {
            try? FileManager.default.removeItem(at: thumbnailURL(for: evictedSample.id))
        }

        Logger.ml.info("Added training sample (\(self.dataset.samples.count) total)")
    }

    /// The stored frame for a sample, if one was captured with it.
    ///
    /// Decode with `CIImage(data:)` and pass to `SceneFeatureExtractor.extract`
    /// to recompute that sample's features under a newer schema.
    func thumbnail(for sampleID: UUID) -> Data? {
        try? Data(contentsOf: thumbnailURL(for: sampleID))
    }

    // MARK: - Private Methods

    private func thumbnailURL(for sampleID: UUID) -> URL {
        MLFiles.thumbnailDirectoryURL.appendingPathComponent("\(sampleID.uuidString).jpg")
    }

    /// Persist one thumbnail. Failures are logged and ignored: losing a
    /// thumbnail costs a future backfill, not the sample itself.
    private func writeThumbnail(_ data: Data, for sampleID: UUID) {
        do {
            try FileManager.default.createDirectory(
                at: MLFiles.thumbnailDirectoryURL, withIntermediateDirectories: true
            )
            try data.write(to: thumbnailURL(for: sampleID), options: .atomic)
        } catch {
            Logger.ml.error("Failed to save sample thumbnail: \(error.localizedDescription)")
        }
    }

    /// Delete thumbnails with no corresponding sample.
    ///
    /// Covers samples evicted while a write failed, a dataset that failed to
    /// decode and reset to empty, and datasets orphaned by a schema-suffix bump.
    /// Without this the directory would grow without bound across those paths,
    /// in iCloud-backed Documents.
    private func pruneOrphanedThumbnails() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: MLFiles.thumbnailDirectoryURL, includingPropertiesForKeys: nil
        ) else { return }

        let liveIDs = Set(dataset.samples.map(\.id.uuidString))
        var removed = 0
        for url in contents where url.pathExtension == "jpg" {
            guard !liveIDs.contains(url.deletingPathExtension().lastPathComponent) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }

        if removed > 0 {
            Logger.ml.info("Pruned \(removed) orphaned sample thumbnail(s)")
        }
    }

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
