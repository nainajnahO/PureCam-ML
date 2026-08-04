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

extension View {
    /// Ripples this view outward from the given focus tap, restarting on each
    /// new tap. Applied to the viewfinder itself — see `FocusRipple`.
    func focusRipple(_ focus: (point: CGPoint, token: UUID)?) -> some View {
        modifier(FocusRipple(focus: focus))
    }
}

/// A droplet ripple run across the viewfinder by `FocusRipple.metal`.
///
/// Nothing is drawn over the camera: the shader displaces where each pixel is
/// *sampled from*, so the live scene itself bulges and settles. That is what
/// Liquid Glass claims to do — bend what is behind it — done to the one surface
/// in this app with something real behind it. It is also a picture of what the
/// hardware is doing, since a lens is curved glass and it is refocusing.
///
/// Escalated from a plain `.glassEffect` circle, which read as a blob rather
/// than a droplet (issue #35 anticipated exactly this: "if a still circular lens
/// turns out to read as inert, escalate to B for the travelling ring").
struct FocusRipple: ViewModifier {
    // `nonisolated` because `keyframeAnimator`'s content closure is @Sendable —
    // a SwiftUI view's members are main-actor isolated by default, and the
    // closure cannot reach them. These are immutable Sendable scalars, so
    // opting them out is free.

    /// Seconds from the tap to the scene being still again. Sized so the
    /// wavefront outruns `radius` and the oscillation has decayed by the end —
    /// past this the shader is displacing by less than a pixel.
    nonisolated static let duration: TimeInterval = 0.9

    /// The same span as the view model's clock for clearing focus state, so the
    /// state lives exactly as long as the thing it describes.
    nonisolated static let lifetime: Duration = .seconds(duration)

    /// Peak sample displacement, in points. Also bounds `maxSampleOffset`, which
    /// tells SwiftUI how far outside its bounds the effect may reach.
    nonisolated private static let amplitude: Float = 18
    /// ~2.5Hz, so one crest and a much weaker trough land inside the decay.
    nonisolated private static let frequency: Float = 16
    nonisolated private static let decay: Float = 7
    /// Wavefront speed, points per second.
    nonisolated private static let speed: Float = 1400
    /// Distance over which the ripple dies out. Keeps it a local disturbance at
    /// the tap rather than a screen-wide wobble.
    nonisolated private static let radius: Float = 220

    let focus: (point: CGPoint, token: UUID)?

    /// Latched from the last tap rather than read from `focus` directly. The view
    /// model clears its focus state when the reticle is done, and letting the
    /// trigger fall back to nil would fire the animator a second time and replay
    /// the ripple on the way out.
    @State private var origin: CGPoint?
    @State private var tap: UUID?

    func body(content: Content) -> some View {
        // Captured by value for the same @Sendable reason as the constants above.
        let rippleOrigin = origin

        return content
            // `keyframeAnimator` rather than a `TimelineView` clock: it drives
            // `elapsed` per frame internally, without re-evaluating the enclosing
            // body. A TimelineView would rebuild the `CameraPreview`
            // representable every frame, calling `updateUIView` — and poking the
            // capture connection — ~100 times per ripple.
            .keyframeAnimator(initialValue: 0.0, trigger: tap) { view, elapsed in
                view.distortionEffect(
                    ShaderLibrary.focusRipple(
                        .float2(Float(rippleOrigin?.x ?? 0), Float(rippleOrigin?.y ?? 0)),
                        .float(Float(elapsed)),
                        .float(Self.amplitude),
                        .float(Self.frequency),
                        .float(Self.decay),
                        .float(Self.speed),
                        .float(Self.radius)
                    ),
                    maxSampleOffset: CGSize(
                        width: CGFloat(Self.amplitude), height: CGFloat(Self.amplitude)
                    ),
                    // Off at both ends, so the viewfinder pays for no shader pass
                    // at rest — and cannot ripple from (0,0) before the first tap.
                    isEnabled: rippleOrigin != nil && elapsed > 0 && elapsed < Self.duration
                )
            } keyframes: { _ in
                // `elapsed` is simply seconds since the tap; all of the shaping
                // lives in the shader, where it can vary with distance too.
                LinearKeyframe(Self.duration, duration: Self.duration)
            }
            .onChange(of: focus?.token) { _, token in
                guard let focus, token != nil else { return }
                origin = focus.point
                tap = focus.token
            }
    }
}
