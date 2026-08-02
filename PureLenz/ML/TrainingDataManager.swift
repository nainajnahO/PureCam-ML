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

        // Synchronous: one directory enumeration over at most `maxSamples`
        // entries, far cheaper than the JSON decode immediately above. Dispatching
        // it would need an explicitly detached task to escape this type's actor
        // isolation, and that task *could* then race `addSample` — so staying
        // inline is both cheaper and simpler. See the guard in the callee for why
        // this is safe to run on every construction.
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

        // FIFO cap configured via the Settings app (Max training samples). The
        // `> 0` check falls back for an unregistered or zero read — `integer(forKey:)`
        // cannot distinguish "absent" from "0", and a 0 cap would evict every sample.
        let cap = UserDefaults.standard.integer(forKey: "maxTrainingSamples")
        let evicted = dataset.addSample(
            sample, maxSamples: cap > 0 ? cap : TrainingDataset.defaultMaxSamples
        )

        // Only release an evicted sample's thumbnail once the eviction is on
        // disk. If the save failed, the stored dataset still lists that sample,
        // and deleting its thumbnail anyway would leave a dangling reference no
        // later pass could detect — the prune only removes files without
        // samples, never the reverse. Skipping the delete leaves an orphan
        // instead, which the next launch collects. Same principle as the write
        // ordering above: fail toward orphans, never toward dangling references.
        if saveDataset() {
            for evictedSample in evicted {
                try? FileManager.default.removeItem(at: thumbnailURL(for: evictedSample.id))
            }
        }


        Logger.ml.info("Added training sample (\(self.dataset.samples.count) total)")
    }

    /// Record that a training run finished against the dataset as it stood at
    /// `version` — the `lastUpdated` read when the run started, not when it
    /// ended. Samples added mid-run therefore stay unaccounted for and trigger
    /// the next run, which is correct: the models that just landed never saw them.
    ///
    /// A failed save is left alone. It only costs one redundant run on the next
    /// trigger, which is the direction to fail in — the alternative is believing
    /// the models are current when nothing on disk says so.
    func markTrained(through version: Date) {
        dataset.trainedThrough = version
        if !saveDataset() {
            Logger.ml.error("Trained models installed but freshness marker not saved — will retrain")
        }
    }

    /// The stored frame for a sample, if one was captured with it.
    ///
    /// Decode with `CIImage(data:)` and pass to `SceneFeatureExtractor.extract`,
    /// using the sample's own `userChosenISO` / `userChosenShutterSeconds` as the
    /// frame exposure — they are the values the extractor was originally given.
    ///
    /// **Splice the new column; do not overwrite the stored ones.** `extract`
    /// returns a whole `SceneFeatures`, so assigning its result wholesale would
    /// replace all fourteen model input columns with JPEG-derived values on
    /// every migrated row. Take only the genuinely-new feature from the
    /// recomputed struct and leave the rest at the fidelity they were measured
    /// from the original full-resolution frame.
    ///
    /// Prefer recomputing the new column for *every* sample rather than only
    /// those predating it: a column that is JPEG-derived for old rows and
    /// frame-derived for new ones varies systematically with sample age, which
    /// is a correlation the trees can pick up. The difference is tiny, but
    /// uniformity is free.
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

    /// Delete thumbnails left behind by samples that are no longer in the
    /// dataset — an eviction whose save failed, or a write that outlived the
    /// sample it belonged to. Without this the directory would grow without
    /// bound across those paths.
    ///
    /// An empty dataset is never treated as evidence that the thumbnails on
    /// disk are garbage, which is what the guard below is for. Two ways to
    /// reach `init` with no samples but a full directory:
    ///
    /// - The dataset failed to decode and reset to empty. The thumbnails are
    ///   still the raw material for whatever recovery follows.
    /// - The `MLFiles` suffix was just bumped, so the current dataset file does
    ///   not exist yet. Deleting here would destroy exactly what the directory
    ///   is for, on exactly the launch that needs it.
    ///
    /// Repeated construction is therefore harmless: with the guard, pruning is
    /// idempotent and only ever removes files whose sample is genuinely absent
    /// from a dataset that loaded successfully.
    private func pruneOrphanedThumbnails() {
        guard !dataset.samples.isEmpty else { return }

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

    /// - Returns: Whether the dataset reached disk. Callers releasing per-sample
    ///   resources must not act on a save that failed.
    @discardableResult
    private func saveDataset() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(dataset)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Logger.ml.error("Failed to save training data: \(error.localizedDescription)")
            return false
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
