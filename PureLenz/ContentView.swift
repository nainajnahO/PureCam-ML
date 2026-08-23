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


struct ContentView: View {
    /// Single owner of the camera services and view models (see CameraScene).
    /// Created once; child views read its `@Observable` view models directly.
    @State private var scene = CameraScene()

    /// Tracks app lifecycle (active, background, inactive) for camera session management.
    @Environment(\.scenePhase) private var scenePhase

    /// User preference (Settings app → Show Framing Indicator). Backed by UserDefaults;
    /// @AppStorage re-reads when the app returns to the foreground, so flipping it in
    /// Settings takes effect on return. Default matches the registered default.
    @AppStorage("showFramingIndicator") private var showFramingIndicator = true

    // MARK: - View Body

    var body: some View {
        ZStack {
            // LAYER 1: Live camera feed (background)
            CameraFeedView(
                cameraService: scene.cameraService,
                showRAWPreview: scene.cameraVM.showRAWPreview,
                rawPreviewImage: scene.cameraVM.rawPreviewImage,
                onCropFraction: { fraction in
                    scene.cameraVM.setPreviewCropFraction(fraction)
                },
                water: scene.cameraVM.water,
                focusRippleFrame: scene.cameraVM.focusRippleFrame,
                onFocusTouch: { phase, viewPoint, devicePoint in
                    scene.cameraVM.focusTouch(phase, viewPoint: viewPoint, devicePoint: devicePoint)
                },
                isFollowMetering: scene.cameraVM.isFollowMetering
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
                    haptics: scene.haptics,
                    sizes: sizes,
                    positions: positions,
                    textPosition: textPos
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

        // Framing indicator: shows the saved-photo bounds (white) and the
        // viewfinder's coverage within them (yellow). Aligned to the safe-area
        // top-trailing corner so it clears the Dynamic Island.
        .overlay(alignment: .topTrailing) {
            if showFramingIndicator {
                FramingIndicator(
                    cameraService: scene.cameraService,
                    cameraVM: scene.cameraVM,
                    onTap: {
                        scene.haptics.impact(.light)
                        scene.cameraVM.toggleFramingPreview()
                    }
                )
                .padding(.trailing, 20)
                .padding(.top, 8)
            }
        }

        // Start/stop the camera and haptics as the app moves between foreground
        // and background. Delegated to the scene's view models (MVVM).
        .onChange(of: scenePhase) { _, newPhase in
            scene.handleScenePhaseChange(newPhase)
        }
    }
}
