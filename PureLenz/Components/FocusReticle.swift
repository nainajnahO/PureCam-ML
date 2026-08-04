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

/// The point of contact: a neutral hairline that flashes where the tap landed
/// and is gone in a third of a second.
///
/// The ripple (`FocusRipple`) is the real answer to "where did I focus" — this
/// only covers what refraction physically cannot. A distortion needs detail to
/// bend, so over a flat bright sky or a dark low-contrast wall the ripple has
/// nothing to work with and the tap would register as nothing at all. This is
/// the floor under that case, kept deliberately brief and colourless so it reads
/// as the droplet's contact rather than as a marker sitting on the scene.
///
/// White rather than the old yellow, which now means "framing" alone again
/// (`FramingIndicator`).
///
/// The animation runs from `onAppear` and is not driven by any external state,
/// so a fresh SwiftUI identity per tap (see `CameraViewModel.focusReticle`) is
/// what restarts it.
struct FocusReticle: View {
    private static let duration = 0.32

    /// Deliberately not scaled by `UIConstants.globalScale`: that governs the
    /// size of the controls, while this marks a point in the scene.
    private static let contactDiameter: CGFloat = 22
    private static let spreadDiameter: CGFloat = 66

    @State private var diameter = FocusReticle.contactDiameter
    @State private var opacity: Double = 0.55

    var body: some View {
        Circle()
            .stroke(.white, lineWidth: 1)
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
            // The reticle sits over the viewfinder, so it must never swallow the
            // next tap.
            .allowsHitTesting(false)
            // Purely decorative — the focus it marks is not an element to
            // navigate to, so it should not appear in the VoiceOver rotor for
            // the moment it is on screen.
            .accessibilityHidden(true)
            .onAppear {
                // Contact is instant, on the same beat as the focus haptic and
                // the start of the ripple; only the spread is animated.
                withAnimation(.easeOut(duration: Self.duration)) {
                    diameter = Self.spreadDiameter
                    opacity = 0
                }
            }
    }
}
