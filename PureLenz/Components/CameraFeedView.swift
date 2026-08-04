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
    /// The active focus reticle, drawn here rather than as a `ContentView`
    /// overlay so it shares the preview's coordinate space — the tap point is
    /// reported in the preview's own bounds.
    var focusReticle: (point: CGPoint, token: UUID)? = nil
    /// The app-drawn copy of the viewfinder that the focus ripple warps, present
    /// only while a ripple runs (see `FocusRipple`).
    var focusRippleFrame: UIImage? = nil
    /// Whether the lens has settled for the current tap; releases the warp.
    var focusSettled: Bool = false
    /// Surfaces a viewfinder tap, already converted to a sensor point (see `CameraPreview`).
    var onFocusTap: ((_ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void)? = nil

    var body: some View {
        if cameraService.status == .configured {
            GeometryReader { geometry in
                ZStack {
                    CameraPreview(
                        session: cameraService.session,
                        onCropFraction: onCropFraction,
                        onFocusTap: onFocusTap
                    )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(showRAWPreview ? 0 : 1)

                    // The focus ripple's warped copy of the viewfinder. SwiftUI
                    // cannot bend the preview layer itself, so while this is up
                    // the app is drawing the camera and distorting what it draws.
                    // Laid out exactly like the RAW snapshot below, which is
                    // already proven to match the live preview's aspect-fill
                    // framing. The live preview is left running underneath: the
                    // copy is opaque, and where the warp samples past its edge,
                    // live pixels show through instead of black.
                    if let focusRippleFrame, let focusReticle {
                        Image(uiImage: focusRippleFrame)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .focusRipple(origin: focusReticle.point, settled: focusSettled)
                            // A fresh identity per tap, so the wave's clock
                            // restarts from zero instead of animating on from
                            // wherever the last one finished. Safe to re-identify
                            // here in a way it would not be on `CameraPreview`:
                            // this is a plain Image, not a live capture layer.
                            .id(focusReticle.token)
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

                    if let focusReticle {
                        FocusReticle()
                            .position(focusReticle.point)
                            .id(focusReticle.token)
                    }
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
