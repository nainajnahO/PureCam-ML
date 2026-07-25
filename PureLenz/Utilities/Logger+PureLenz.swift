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

import OSLog

/// Shared os.Logger categories for PureLenz.
/// Using the unified logging system instead of print() so messages are
/// structured, can be filtered by category in Console.app, and are stripped
/// from release builds at the appropriate log level.
extension Logger {
    private static let subsystem = "com.purelenz"

    /// Camera session, capture, and exposure plumbing.
    static let camera = Logger(subsystem: subsystem, category: "camera")

    /// Machine-learning inference, training, and feature extraction.
    static let ml = Logger(subsystem: subsystem, category: "ml")

    /// Haptic engine lifecycle and playback.
    static let haptics = Logger(subsystem: subsystem, category: "haptics")
}
