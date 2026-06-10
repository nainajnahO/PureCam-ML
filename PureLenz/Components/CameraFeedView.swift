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

    var body: some View {
        if cameraService.status == .configured {
            GeometryReader { geometry in
                ZStack {
                    CameraPreview(session: cameraService.session, onCropFraction: onCropFraction)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(showRAWPreview ? 0 : 1)

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
