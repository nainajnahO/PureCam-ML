//
//  PureCamControlsControl.swift
//  PureCamControls
//
//  The Lock Screen / Control Center button that opens PureCam's camera.
//

import AppIntents
import SwiftUI
import WidgetKit

/// The control the user places in a Lock Screen slot, in Control Center, or binds
/// to the Action Button. Tapping it runs `OpenPureCamIntent`, which opens PureCam
/// — authenticating first when the device is locked.
struct PureCamControlsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "nainajnahO.PureCam.OpenCamera") {
            ControlWidgetButton(action: OpenPureCamIntent()) {
                Label("PureCam", systemImage: "camera.aperture")
            }
        }
        .displayName("PureCam Camera")
        .description("Open the PureCam camera, even from the Lock Screen.")
    }
}
