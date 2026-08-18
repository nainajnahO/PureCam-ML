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

import CoreLocation
import ImageIO
import OSLog

/// Keeps a warm location fix for geotagging captures. Started when the camera
/// opens (CameraService owns one); iterating liveUpdates() implicitly triggers
/// the when-in-use prompt on first use. No toggle: if permission is denied or
/// no fix has arrived, latestLocation stays nil and photos save untagged.
/// Updates auto-pause in background and resume on foreground.
final class LocationService {

    /// Most recent fix, used as-is at capture time: liveUpdates only goes
    /// quiet when the device is stationary — i.e. when the last fix is still
    /// correct — so a freshness cutoff would guard against nothing.
    private(set) var latestLocation: CLLocation?

    private var updatesTask: Task<Void, Never>?

    init() {
        // [weak self] + cancel-in-deinit as a pair: the loop never completes
        // on its own, so a strong capture would make this object immortal.
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    guard let location = update.location else { continue }
                    if self.latestLocation == nil {
                        Logger.camera.debug("First location fix acquired")
                    }
                    self.latestLocation = location
                }
            } catch {
                if !(error is CancellationError) {
                    Logger.camera.error("Location updates failed: \(error.localizedDescription)")
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }
}

extension CLLocation {
    private static let gpsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd"
        return f
    }()

    private static let gpsTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// EXIF GPS dictionary for AVCapturePhotoSettings.metadata. EXIF stores
    /// coordinates as positive magnitudes plus hemisphere refs; GPS date/time
    /// stamps are the fix time in UTC. No CLLocation→GPS-dict API exists.
    var exifGPSDictionary: [String: Any] {
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef as String: coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef as String: coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSDateStamp as String: Self.gpsDateFormatter.string(from: timestamp),
            kCGImagePropertyGPSTimeStamp as String: Self.gpsTimeFormatter.string(from: timestamp),
            kCGImagePropertyGPSHPositioningError as String: horizontalAccuracy,
        ]
        // verticalAccuracy <= 0 means the fix carries no valid altitude.
        if verticalAccuracy > 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
        }
        return gps
    }
}
