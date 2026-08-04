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

/// The mark a focus tap leaves on the viewfinder: a droplet hitting still water.
///
/// A circle of Liquid Glass lands at the tap point, spreads, thins out and
/// flattens back into the scene. It is the same material as the capture and
/// preview buttons (`ButtonUILayer`), so focus now speaks the app's own visual
/// language instead of borrowing the stock camera app's yellow square. It also
/// gives the yellow back to `FramingIndicator`, which can mean "framing" alone
/// again.
///
/// Glass is a *refractive* material, and the viewfinder is the one surface in
/// this app with something real behind it to bend — so the ring warps the live
/// scene rather than drawing a marker over it. That doubles as a picture of what
/// the hardware is doing: a lens is curved glass, and it is refocusing.
///
/// The animation runs from `onAppear` and is not driven by any external state,
/// so a fresh SwiftUI identity per tap (see `CameraViewModel.focusReticle`) is
/// what restarts it.
struct FocusReticle: View {
    private static let impactDuration = 0.22
    private static let holdDuration = 0.18
    private static let settleDuration = 0.45
    /// The leading edge outlives the impact only briefly — it is the flash of a
    /// ring running out, not an outline sitting on the scene.
    private static let rimFadeDuration = 0.25

    /// Time from contact to the ring being fully gone. `CameraViewModel` clears
    /// its reticle state after exactly this, so the view is removed as it
    /// becomes invisible rather than while still fading.
    static let lifetime: Duration = .seconds(impactDuration + holdDuration + settleDuration)

    /// The three diameters the ring passes through: where the droplet lands, the
    /// ring at full strength, and where it has spread thin enough to vanish.
    ///
    /// Deliberately not scaled by `UIConstants.globalScale`: that governs the
    /// size of the controls, while this marks a point in the scene.
    private static let contactDiameter: CGFloat = 26
    private static let ringDiameter: CGFloat = 92
    private static let dissipatedDiameter: CGFloat = 132

    @State private var diameter = FocusReticle.contactDiameter
    @State private var opacity: Double = 1
    @State private var rimOpacity: Double = 1

    var body: some View {
        Circle()
            .fill(.clear)
            // The *frame* animates, not `scaleEffect`: scaling would magnify an
            // already-sampled backdrop, which reads as a zoom. Resizing the glass
            // re-samples it at every size, so the refraction genuinely travels
            // across the scene the way a ring on water does.
            .frame(width: diameter, height: diameter)
            // `.clear` matches the buttons. No `.interactive()` — that responds
            // to touch, and this view is explicitly not hit-testable.
            .glassEffect(.clear, in: .circle)
            .overlay {
                // A neutral hairline on the ring's leading edge. The refraction
                // is the signal, but it has nothing to bend over a flat bright
                // sky or a dark low-contrast wall — this keeps the tap readable
                // there without reintroducing a coloured marker.
                Circle()
                    .stroke(.white.opacity(0.45), lineWidth: 1)
                    .opacity(rimOpacity)
            }
            .opacity(opacity)
            // The reticle sits over the viewfinder, so it must never swallow the
            // next tap.
            .allowsHitTesting(false)
            // Purely decorative — the focus it marks is not an element to
            // navigate to, so it should not appear in the VoiceOver rotor for
            // the second it is on screen.
            .accessibilityHidden(true)
            .onAppear {
                // Contact is instant, on the same beat as the focus haptic; only
                // what follows it is animated.
                withAnimation(.easeOut(duration: Self.impactDuration)) {
                    diameter = Self.ringDiameter
                }
                withAnimation(.easeOut(duration: Self.rimFadeDuration).delay(Self.impactDuration)) {
                    rimOpacity = 0
                }
                withAnimation(
                    .easeOut(duration: Self.settleDuration)
                        .delay(Self.impactDuration + Self.holdDuration)
                ) {
                    diameter = Self.dissipatedDiameter
                    opacity = 0
                }
            }
    }
}
