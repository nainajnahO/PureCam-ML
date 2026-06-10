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

import AppIntents
import SwiftUI
import WidgetKit

/// The control the user places in a Lock Screen slot, in Control Center, or binds
/// to the Action Button. Tapping it runs `OpenPureLenzIntent`, which opens PureLenz
/// — authenticating first when the device is locked.
struct PureLenzControlsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "nainajnahO.PureLenz.OpenCamera") {
            ControlWidgetButton(action: OpenPureLenzIntent()) {
                Label("PureLenz", systemImage: "camera.aperture")
            }
        }
        .displayName("PureLenz Camera")
        .description("Open the PureLenz camera, even from the Lock Screen.")
    }
}
