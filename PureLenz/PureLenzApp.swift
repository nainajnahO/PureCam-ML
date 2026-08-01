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


import SwiftUI

// The app is portrait-locked via the target's supported-interface-orientations
// setting (Info.plist), so no AppDelegate orientation override is needed.
@main
struct PureLenzApp: App {

    // REGISTER SETTINGS DEFAULTS
    //
    // Values configured in the Settings.bundle (Settings app) aren't copied into
    // UserDefaults until the user actually opens the app's Settings page. Registering
    // matching defaults here guarantees the app always has a known value. Keep these
    // identical to the DefaultValue entries in Root.plist.
    //
    // This runs in the App's initializer rather than an AppDelegate launch hook:
    // the App value is created before its scene body is evaluated, so the defaults
    // are in place before ContentView's @AppStorage ever reads them — and the app
    // needs no AppDelegate otherwise.
    init() {
        UserDefaults.standard.register(defaults: [
            "showFramingIndicator": true,
            "autoExposureOnLaunch": true,
            "contributeTrainingData": true,
            "maxTrainingSamples": 500
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // SET APP-WIDE ACCENT COLOUR
                .tint(.yellow)
        }
    }
}
