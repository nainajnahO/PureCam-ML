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
    /// new tap. Applied to the app-drawn copy of the viewfinder — see `FocusRipple`.
    func focusRipple(_ focus: (point: CGPoint, token: UUID)?) -> some View {
        modifier(FocusRipple(focus: focus))
    }
}

/// A droplet ripple run across the viewfinder by `FocusRipple.metal`.
///
/// The shader displaces where each pixel is *sampled from*, so the scene itself
/// bulges and settles rather than having anything drawn over it. That is what
/// Liquid Glass claims to do — bend what is behind it — and it doubles as a
/// picture of what the hardware is doing, since a lens is curved glass and it is
/// refocusing.
///
/// **Why this is applied to a copy and not the viewfinder.** A shader effect
/// needs SwiftUI to rasterize the view it is attached to. The live viewfinder is
/// an `AVCaptureVideoPreviewLayer` inside a `UIViewRepresentable` — a video pane
/// the system paints straight to the screen, whose pixels SwiftUI's renderer
/// never has. Attaching a shader to it replaced the whole preview with SwiftUI's
/// unavailable-view placeholder. So for the length of the ripple the app draws
/// the camera itself, from frames pulled through the existing on-demand video
/// path, and distorts what it draws. See `CameraViewModel.runFocusRipple`.
///
/// (`.glassEffect` works directly on the viewfinder where a shader cannot,
/// because it samples the *composited backdrop* rather than the view's own
/// content — which is why the buttons have always refracted the camera.)
struct FocusRipple: ViewModifier {
    // `nonisolated` because `keyframeAnimator`'s content closure is @Sendable —
    // a SwiftUI view's members are main-actor isolated by default, and the
    // closure cannot reach them. These are immutable Sendable scalars, so
    // opting them out is free.

    /// Seconds from the tap to the scene being still again — and therefore how
    /// long the app holds the viewfinder. Kept short: this is the window where
    /// the frame pipeline is awake and the preview is a copy.
    nonisolated static let duration: TimeInterval = 0.7

    /// The same span as the view model's clock for the frame pull and the focus
    /// state, so all three end together.
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

    @State private var origin: CGPoint?
    @State private var tap: UUID?

    func body(content: Content) -> some View {
        // Captured by value for the same @Sendable reason as the constants above.
        let rippleOrigin = origin

        return content
            // `keyframeAnimator` rather than a `TimelineView` clock: it drives
            // `elapsed` per frame internally, and its `trigger:` restarts the
            // wave cleanly when a second tap lands mid-ripple.
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
                    // Off at both ends, so the copy is never shown through an
                    // idle shader pass and cannot ripple from (0,0) before a tap.
                    isEnabled: rippleOrigin != nil && elapsed > 0 && elapsed < Self.duration
                )
            } keyframes: { _ in
                // `elapsed` is simply seconds since the tap; all of the shaping
                // lives in the shader, where it can vary with distance too.
                LinearKeyframe(Self.duration, duration: Self.duration)
            }
            // `task(id:)` rather than `onChange`: the copy appears at the same
            // moment as the first tap, so this view is *created* with its focus
            // already set. `onChange` alone would never see a change and the
            // first ripple of every session would silently not run.
            .task(id: focus?.token) {
                guard let focus else { return }
                origin = focus.point
                tap = focus.token
            }
    }
}
