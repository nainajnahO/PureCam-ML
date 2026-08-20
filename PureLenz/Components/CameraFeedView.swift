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

struct CameraFeedView: View {
    let cameraService: CameraService
    let showRAWPreview: Bool
    let rawPreviewImage: UIImage?
    /// Surfaces the preview layer's true short-axis crop fraction up to the view
    /// model (see `CameraPreview`); drives the framing indicator's yellow box.
    var onCropFraction: ((CGFloat) -> Void)? = nil
    /// The water the viewfinder is seen through while focusing. Laid over the
    /// preview's own bounds, so the finger's point and the surface share a
    /// coordinate space by construction.
    let water: WaterSurface
    /// The app-drawn copy of the viewfinder that the water refracts, present
    /// only while the water moves (see `WaterRefraction`).
    var focusRippleFrame: UIImage? = nil
    /// Surfaces a finger on the viewfinder, already converted to a sensor point (see `CameraPreview`).
    var onFocusTouch: ((FocusTouchPhase, _ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void)? = nil

    var body: some View {
        if cameraService.status == .configured {
            GeometryReader { geometry in
                ZStack {
                    CameraPreview(
                        session: cameraService.session,
                        onCropFraction: onCropFraction,
                        onFocusTouch: onFocusTouch
                    )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(showRAWPreview ? 0 : 1)

                    // The water's refracted copy of the viewfinder. SwiftUI
                    // cannot bend the preview layer itself, so while this is up
                    // the app is drawing the camera and distorting what it draws.
                    // Laid out exactly like the RAW snapshot below, which is
                    // already proven to match the live preview's aspect-fill
                    // framing. The live preview is left running underneath: the
                    // copy is opaque, and where the warp samples past its edge,
                    // live pixels show through instead of black.
                    if let focusRippleFrame {
                        Image(uiImage: focusRippleFrame)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .waterRefraction(surface: water)
                            // The copy sits over the viewfinder while the water
                            // settles; a finger arriving in that tail must still
                            // reach the preview underneath.
                            .allowsHitTesting(false)
                    }

                    if showRAWPreview, let previewImage = rawPreviewImage {
                        // CameraService applies the same fixed orientation the live
                        // preview uses, so the snapshot is shown as-is — no rotation.
                        // This matches the live preview in every device orientation
                        // and works with rotation lock on.
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .transition(.opacity)
                    }
                }
                // Fires at first layout, before any finger can land, and the
                // preview is framed to this same size.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    water.resize(to: size)
                }
            }
            .ignoresSafeArea()
        } else if cameraService.status == .unauthorized {
            ContentUnavailableView(
                "Camera Access Denied",
                systemImage: "video.slash.fill",
                description: Text("Please enable camera access in Settings.")
            )
        } else if cameraService.status == .failed {
            ContentUnavailableView(
                "Camera Failed",
                systemImage: "exclamationmark.triangle.fill",
                description: Text("The camera could not be started.")
            )
        }
    }
}
