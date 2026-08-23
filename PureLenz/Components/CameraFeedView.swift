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
import AVFoundation

/// The outline that rides on a tracked subject: a thin light ring, sized to
/// the subject's box. Quiet on purpose — it sits on a face for as long as the
/// subject is held, so it has to be something the eye can look past. White
/// while only the lens follows the subject; the shutter dial's yellow once
/// the light meter does too.
private struct TrackingMarker: View {
    let isFollowMetering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder((isFollowMetering ? Color.yellow : Color.white).opacity(0.85), lineWidth: 1.5)
            // Legible over a bright subject, without a dark outline that
            // would read as a drawn box.
            .shadow(color: .black.opacity(0.35), radius: 2)
    }
}

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
    /// Whether the tracked subject is being re-metered as well as focused —
    /// the marker's colour (see `TrackingMarker`).
    var isFollowMetering = false

    /// The preview layer, for mapping the tracked subject's sensor-space box
    /// onto the screen. Set once the preview is made (see `CameraPreview`).
    @State private var previewLayer: AVCaptureVideoPreviewLayer?

    var body: some View {
        if cameraService.status == .configured {
            GeometryReader { geometry in
                ZStack {
                    CameraPreview(
                        session: cameraService.session,
                        onCropFraction: onCropFraction,
                        onFocusTouch: onFocusTouch,
                        onPreviewLayer: { previewLayer = $0 }
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

                    // The tracked subject's marker. Above the water's copy on
                    // purpose: the grab lands while the finger is still down
                    // and the copy still up, and the marker is how the grab is
                    // seen. Distinct from the one-shot focus by construction —
                    // an outline that moves, rather than a lit patch that
                    // breathes where the finger lifted.
                    if let bounds = cameraService.trackedSubjectBounds, let previewLayer {
                        let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: bounds)
                        TrackingMarker(isFollowMetering: isFollowMetering)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            // Each new box is a real move (CameraService holds
                            // back the twitches), so a longer glide between
                            // them reads as following rather than hopping.
                            .animation(.smooth(duration: 0.35), value: rect)
                            .transition(.opacity.combined(with: .scale(scale: 1.15)))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: cameraService.trackedSubjectBounds == nil)
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
