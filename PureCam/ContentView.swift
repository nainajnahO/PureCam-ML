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

import SwiftUI


struct ContentView: View {
    /// Single owner of the camera services and view models (see CameraScene).
    /// Created once; child views read its `@Observable` view models directly.
    @State private var scene = CameraScene()

    /// Tracks app lifecycle (active, background, inactive) for camera session management.
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - View Body

    var body: some View {
        ZStack {
            // LAYER 1: Live camera feed (background)
            CameraFeedView(
                cameraService: scene.cameraService,
                showRAWPreview: scene.cameraVM.showRAWPreview,
                rawPreviewImage: scene.cameraVM.rawPreviewImage
            )

            // LAYER 2: Button UI (foreground)
            GeometryReader { geometry in
                // Responsive layout derived from the current screen geometry.
                let sizes = UIConstants.buttonSizes(for: geometry)
                let positions = UIConstants.buttonPositions(for: geometry)
                let textPos = UIConstants.textPosition(
                    captureX: positions.captureX,
                    buttonY: positions.buttonY,
                    captureButtonSize: sizes.captureButtonSize,
                    deviceOrientation: scene.cameraVM.deviceOrientation
                )

                ButtonUILayer(
                    cameraService: scene.cameraService,
                    cameraVM: scene.cameraVM,
                    exposureVM: scene.exposureVM,
                    autoExposure: scene.autoExposure,
                    sizes: sizes,
                    positions: positions,
                    textPosition: textPos,
                    deviceOrientation: scene.cameraVM.deviceOrientation
                )
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())

        // LAYER 3: Capture flash overlay (top-most). A brief black flash on
        // capture gives a "camera shutter" feel. See CameraViewModel.triggerCaptureFlash().
        .overlay {
            if scene.cameraVM.showCaptureFlash {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }

        // Start/stop the camera and haptics as the app moves between foreground
        // and background. Delegated to the scene's view models (MVVM).
        .onChange(of: scenePhase) { _, newPhase in
            scene.handleScenePhaseChange(newPhase)
        }
    }
}
