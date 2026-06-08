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

import AppIntents

/// The intent fired by the PureCam Lock Screen / Control Center control.
///
/// `openAppWhenRun` makes the system launch PureCam once the intent runs. Tapping
/// the control while the device is locked makes iOS authenticate (Face ID /
/// passcode) first, then open the app — which launches straight into the camera
/// viewfinder, so there's nothing to deep-link to.
///
/// ⚠️ TARGET MEMBERSHIP: this file must belong to BOTH `PureCam` (app) and
/// `PureCamControlsExtension`. Apple requires the action intent in both targets
/// for a control to open the app, and the widget references it directly.
struct OpenPureCamIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PureCam"
    static let description = IntentDescription("Opens the PureCam camera.")

    /// Foreground the app after running. With an empty `perform()` this is the
    /// whole behaviour: the control just opens PureCam.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
