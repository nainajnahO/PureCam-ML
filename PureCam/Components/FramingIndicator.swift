// PureCam - An iOS camera app with AI-powered exposure control
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

/// A small HUD that shows how the live viewfinder relates to the saved photo.
///
/// The preview is `.resizeAspectFill` of the fixed-90°-rotated sensor frame into
/// the portrait-locked screen, so it always crops the photo's *short* axis while
/// showing the *full long* axis. The saved RAW, in contrast, is the full sensor.
/// This indicator draws that relationship:
/// - white rectangle = the saved photo (3:4 in portrait, 4:3 in landscape),
/// - yellow outline = the region the viewfinder currently shows, flush on the
///   long-axis edges and inset to `shortAxisFraction` on the short axis.
struct FramingIndicator: View {
    let deviceOrientation: UIDeviceOrientation
    /// width / height of the full preview area (full screen, ignoring safe area).
    let screenAspect: CGFloat
    /// long / short of the saved photo (from the camera; ≈1.333 for 4:3).
    let photoAspectRatio: CGFloat

    /// Longest edge of the outer (saved-photo) rectangle, in points.
    private let maxSide: CGFloat = 44
    private let lineWidth: CGFloat = 1.5

    private var isLandscape: Bool { deviceOrientation.isLandscape }

    /// Fraction of the photo's short axis the viewfinder covers. `.resizeAspectFill`
    /// crops the short axis to `screenAspect / (short/long) = screenAspect · (long/short)`.
    /// Constant across orientations; only which axis is "short" flips. Clamped
    /// because a screen wider than the photo (e.g. iPad) would crop the long axis
    /// instead — never happens on this portrait-locked iPhone app, but the clamp
    /// keeps the inner rect inside the outer regardless.
    private var shortAxisFraction: CGFloat {
        min(1, screenAspect * photoAspectRatio)
    }

    /// Outer (white) rectangle: long edge = `maxSide`, short edge derived from the
    /// photo ratio. Orientation decides which screen axis is long.
    private var outerSize: CGSize {
        let shortLen = maxSide / photoAspectRatio
        return isLandscape
            ? CGSize(width: maxSide, height: shortLen)   // landscape: wide
            : CGSize(width: shortLen, height: maxSide)   // portrait: tall
    }

    /// Inner (yellow) rectangle: full long axis (flush), `shortAxisFraction` of short.
    private var innerSize: CGSize {
        let outer = outerSize
        return isLandscape
            ? CGSize(width: outer.width, height: outer.height * shortAxisFraction)
            : CGSize(width: outer.width * shortAxisFraction, height: outer.height)
    }

    var body: some View {
        ZStack {
            // White = full saved-photo bounds.
            Rectangle()
                .stroke(.white.opacity(0.9), lineWidth: lineWidth)
                .frame(width: outerSize.width, height: outerSize.height)

            // Yellow = the region the viewfinder currently shows (a subset of the
            // photo), flush on the long-axis edges and inset on the short axis.
            Rectangle()
                .stroke(.yellow, lineWidth: lineWidth)
                .frame(width: innerSize.width, height: innerSize.height)
        }
        // Keep the white edge legible against bright scenes.
        .shadow(color: .black.opacity(0.35), radius: 1)
        .animation(.easeInOut(duration: 0.2), value: isLandscape)
        .allowsHitTesting(false)
    }
}
