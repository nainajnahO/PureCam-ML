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

    /// width / height of the full screen, measured from a safe-area-ignoring
    /// background so it matches the preview's `.resizeAspectFill` bounds. Feeds
    /// the framing indicator's crop math. Default is a typical iPhone aspect,
    /// replaced on the first layout pass.
    @State private var screenAspect: CGFloat = 9.0 / 19.5

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
                    deviceOrientation: scene.cameraService.deviceOrientation
                )

                ButtonUILayer(
                    cameraService: scene.cameraService,
                    cameraVM: scene.cameraVM,
                    exposureVM: scene.exposureVM,
                    autoExposure: scene.autoExposure,
                    sizes: sizes,
                    positions: positions,
                    textPosition: textPos,
                    deviceOrientation: scene.cameraService.deviceOrientation
                )
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())

        // Measure the full screen (not the safe-area inset) so the framing
        // indicator's crop fraction matches the preview's actual bounds.
        .background {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width / proxy.size.height
                } action: { screenAspect = $0 }
        }

        // LAYER 3: Capture flash overlay (top-most). A brief black flash on
        // capture gives a "camera shutter" feel. See CameraViewModel.triggerCaptureFlash().
        .overlay {
            if scene.cameraVM.showCaptureFlash {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }

        // Framing indicator: shows the saved-photo bounds (white) and the
        // viewfinder's coverage within them (yellow). Aligned to the safe-area
        // top-trailing corner so it clears the Dynamic Island.
        .overlay(alignment: .topTrailing) {
            FramingIndicator(
                deviceOrientation: scene.cameraService.deviceOrientation,
                screenAspect: screenAspect,
                photoAspectRatio: scene.cameraService.photoAspectRatio
            )
            .padding(.trailing, 20)
            .padding(.top, 8)
        }

        // Start/stop the camera and haptics as the app moves between foreground
        // and background. Delegated to the scene's view models (MVVM).
        .onChange(of: scenePhase) { _, newPhase in
            scene.handleScenePhaseChange(newPhase)
        }
    }
}
