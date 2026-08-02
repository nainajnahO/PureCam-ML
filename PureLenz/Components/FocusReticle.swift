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

/// The square that marks where a focus tap landed: scales in, holds, fades out.
///
/// Hand-drawn because there is no system-provided focus reticle — UIKit and
/// SwiftUI both leave this to the app. Yellow to match the framing indicator's
/// crop rectangle, which is the app's existing "this is what the camera is
/// doing" colour.
///
/// The animation runs from `onAppear` and is not driven by any external state,
/// so a fresh SwiftUI identity per tap (see `CameraViewModel.focusReticle`) is
/// what restarts it.
struct FocusReticle: View {
    private static let appearDuration = 0.2
    private static let holdDuration = 0.7
    private static let fadeDuration = 0.35

    /// Time from the start of the scale-in to the end of the fade-out.
    /// `CameraViewModel` clears its reticle state after exactly this, so the
    /// square is removed as it becomes invisible rather than while still fading.
    static let lifetime: Duration = .seconds(appearDuration + holdDuration + fadeDuration)

    /// Deliberately not scaled by `UIConstants.globalScale`: that governs the
    /// size of the controls, while this marks a point in the scene.
    private let size: CGFloat = 80

    @State private var scale: CGFloat = 1.35
    @State private var opacity: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .opacity(opacity)
            // The reticle sits over the viewfinder, so it must never swallow the
            // next tap.
            .allowsHitTesting(false)
            // Purely decorative — the focus it marks is not an element to
            // navigate to, so it should not appear in the VoiceOver rotor for
            // the second-and-a-bit it is on screen.
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeOut(duration: Self.appearDuration)) {
                    scale = 1
                    opacity = 1
                }
                withAnimation(
                    .easeIn(duration: Self.fadeDuration)
                        .delay(Self.appearDuration + Self.holdDuration)
                ) {
                    opacity = 0
                }
            }
    }
}
