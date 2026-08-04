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
/// Two rings of Liquid Glass run outward from the tap point — a strong crest and
/// a weaker one trailing it — over a hairline that flashes at the point of
/// contact. Same material as the capture and preview buttons (`ButtonUILayer`),
/// so focus speaks the app's own visual language instead of borrowing the stock
/// camera app's yellow square. It also gives the yellow back to
/// `FramingIndicator`, which can mean "framing" alone again.
///
/// Glass is a *refractive* material, and the viewfinder is the one surface in
/// this app with something real behind it to bend — so the rings warp the live
/// scene rather than drawing over it. That doubles as a picture of what the
/// hardware is doing: a lens is curved glass, and it is refocusing.
///
/// **Why rings and not a Metal ripple.** Issue #35 offered a shader
/// (`.distortionEffect`) as the more expressive route, and a filled glass circle
/// did read as a blob rather than a droplet. But a shader effect requires
/// SwiftUI to rasterize the view it is applied to, and the viewfinder is an
/// `AVCaptureVideoPreviewLayer` inside a `UIViewRepresentable` — content
/// SwiftUI's renderer cannot sample. Attaching one replaced the entire preview
/// with SwiftUI's unavailable-view placeholder, before the shader had even run.
/// `.glassEffect` works where the shader cannot because it samples the
/// *composited backdrop* rather than the view's own content, which is also why
/// the buttons have always refracted the camera correctly.
///
/// An annulus is what buys back the expressiveness: a filled disc bulges the
/// middle and just grows, while a ring leaves the centre flat and reads as a
/// crest travelling away from the tap.
///
/// The animation runs from `onAppear` and is not driven by any external state,
/// so a fresh SwiftUI identity per tap (see `CameraViewModel.focusReticle`) is
/// what restarts it.
struct FocusReticle: View {
    /// How long one crest takes to run out and disappear.
    fileprivate static let crestDuration = 0.55
    /// How far the second crest trails the first.
    private static let trail = 0.13

    /// Time from contact to the last crest being gone. `CameraViewModel` clears
    /// its reticle state after exactly this, so the view is removed as it becomes
    /// invisible rather than while still fading.
    static let lifetime: Duration = .seconds(crestDuration + trail)

    /// Where the droplet lands. Deliberately not scaled by
    /// `UIConstants.globalScale`: that governs the size of the controls, while
    /// this marks a point in the scene.
    fileprivate static let contactDiameter: CGFloat = 24

    private static let flashDuration = 0.32
    private static let flashSpread: CGFloat = 66

    @State private var flashDiameter = FocusReticle.contactDiameter
    @State private var flashOpacity: Double = 0.55

    var body: some View {
        ZStack {
            // The leading crest, and a weaker one behind it. Two rather than one
            // because a single ring reads as a pulse; two read as water. Three
            // starts to fight a busy scene — add a third entry here if it turns
            // out otherwise.
            RippleCrest(delay: 0, spread: 168, band: 12, peakOpacity: 1)
            RippleCrest(delay: Self.trail, spread: 118, band: 8, peakOpacity: 0.55)

            // The point of contact. Covers what refraction physically cannot: a
            // distortion needs detail to bend, so over a flat bright sky or a
            // dark low-contrast wall the rings have nothing to work with and the
            // tap would register as nothing at all. Colourless and brief, so it
            // reads as the droplet landing rather than a marker on the scene.
            Circle()
                .stroke(.white, lineWidth: 1)
                .frame(width: flashDiameter, height: flashDiameter)
                .opacity(flashOpacity)
                .onAppear {
                    // Contact is instant, on the same beat as the focus haptic;
                    // only the spread is animated.
                    withAnimation(.easeOut(duration: Self.flashDuration)) {
                        flashDiameter = Self.flashSpread
                        flashOpacity = 0
                    }
                }
        }
        // The reticle sits over the viewfinder, so it must never swallow the
        // next tap.
        .allowsHitTesting(false)
        // Purely decorative — the focus it marks is not an element to navigate
        // to, so it should not appear in the VoiceOver rotor for the moment it
        // is on screen.
        .accessibilityHidden(true)
    }
}

/// One ring of the ripple: a band of glass that expands away from the tap point
/// and thins out as it goes.
private struct RippleCrest: View {
    /// How far behind the leading crest this one starts.
    let delay: Double
    /// Diameter this crest reaches before it is gone.
    let spread: CGFloat
    /// Thickness of the refracting band.
    let band: CGFloat
    let peakOpacity: Double

    /// How quickly the crest reaches full strength once it leaves the tap point.
    private static let riseDuration = 0.06

    @State private var diameter = FocusReticle.contactDiameter
    @State private var opacity: Double = 0

    var body: some View {
        Color.clear
            .frame(width: diameter, height: diameter)
            // A stroked circle *as the glass shape* — the band refracts and the
            // middle is left alone, which is what makes this a crest rather than
            // a growing lens. `.clear` matches the buttons; no `.interactive()`,
            // since that responds to touch and this is not hit-testable.
            .glassEffect(.clear, in: Circle().stroke(lineWidth: band))
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: FocusReticle.crestDuration).delay(delay)) {
                    diameter = spread
                }
                withAnimation(.linear(duration: Self.riseDuration).delay(delay)) {
                    opacity = peakOpacity
                }
                // Thins out as it runs away from the tap, the way a real crest
                // loses height spreading over a larger circumference.
                withAnimation(
                    .easeIn(duration: FocusReticle.crestDuration - Self.riseDuration)
                        .delay(delay + Self.riseDuration)
                ) {
                    opacity = 0
                }
            }
    }
}
