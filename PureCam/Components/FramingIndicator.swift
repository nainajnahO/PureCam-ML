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
///
/// Like the viewfinder, the indicator is fixed to the portrait-locked screen — it
/// is *not* counter-rotated like the exposure text. Turning the phone to landscape
/// visually rotates the whole thing (frame, live image, and yellow crop lines) with
/// the device: the box reads wide, and the crop lines that cut the sides in portrait
/// end up cutting top/bottom — matching what the viewfinder actually crops.
///
/// Tapping the box expands it into a larger thumbnail and fills the white
/// rectangle with a live full-sensor frame (pulled from the camera's video output,
/// not a second preview layer), letting you see what the cropped main viewfinder
/// hides; the yellow lines mark the on-screen crop. Tapping again collapses back to
/// the outline-only schematic and stops the frame pull (zero cost at rest).
struct FramingIndicator: View {
    let cameraService: CameraService
    let cameraVM: CameraViewModel
    /// Invoked on tap to toggle the expanded state (owned by `CameraViewModel`).
    let onTap: () -> Void

    /// Longest edge of the outer rectangle when collapsed / expanded, in points.
    private let collapsedSide: CGFloat = 44
    private let expandedSide: CGFloat = 180
    private let lineWidth: CGFloat = 1.0

    /// Idle-fade tuning: the HUD fades linearly from full strength to its idle
    /// (grey, near-invisible) state over this duration, restarting on each tap.
    private let idleFadeSeconds: Double = 3
    private let dimmedOpacity: CGFloat = 0.15

    /// Whether the HUD has faded to its idle, near-invisible state. Local view
    /// state — the idle behaviour needs no model involvement.
    @State private var isDimmed = false
    /// Bumped on each tap to restart the idle timer (drives the `.task(id:)` below).
    @State private var wakeToken = 0

    /// long / short of the saved photo (from the camera; ≈1.333 for 4:3).
    private var photoAspectRatio: CGFloat { cameraService.photoAspectRatio }

    // Read per-frame state here (not in ContentView) so only this HUD re-renders
    // at the ~15fps frame cadence — the rest of the UI stays put.
    private var isExpanded: Bool { cameraVM.framingPreviewExpanded }
    /// Latest full-sensor frame to show while expanded (nil = not ready / collapsed).
    private var previewImage: UIImage? { cameraVM.framingPreviewImage }

    /// Longest edge of the outer (saved-photo) rectangle. Grows on tap so the live
    /// full-frame preview is legible, shrinks back to the schematic when collapsed.
    private var maxSide: CGFloat { isExpanded ? expandedSide : collapsedSide }

    /// Fraction of the photo's short axis the viewfinder covers, read straight
    /// from the preview layer (AVCaptureVideoPreviewLayer's own crop reporting,
    /// surfaced via `CameraViewModel.previewCropFraction`). Correct on any screen
    /// size and safe-area layout because the layer derives it from its real
    /// bounds — the app never measures the screen itself. nil until the layer
    /// has first laid out and reported.
    private var shortAxisFraction: CGFloat? {
        cameraVM.previewCropFraction
    }

    /// Outer (white) rectangle, fixed in the portrait-locked screen: long edge
    /// (`maxSide`) vertical, short edge from the photo ratio. It never reshapes —
    /// turning the phone makes the fixed box read wide in landscape on its own.
    private var outerSize: CGSize {
        let shortLen = maxSide / photoAspectRatio
        return CGSize(width: shortLen, height: maxSide)
    }

    /// Fixed corner radius keyed to the collapsed size — the mini state's roundness
    /// is the look we want, so it stays put rather than growing with the box when
    /// expanded (a `maxSide`-relative radius would over-round the large state).
    /// Shared by both boxes and the live-preview clip so their corners stay consistent.
    private var cornerRadius: CGFloat { collapsedSide * 0.05 }

    /// Resting opacity: full strength while expanded or just after a tap, fading to
    /// `dimmedOpacity` once idle so the HUD recedes when you're not using it.
    /// Opacity doesn't affect hit-testing, so the faded box still wakes on tap.
    private var restingOpacity: CGFloat {
        (isExpanded || !isDimmed) ? 1 : dimmedOpacity
    }

    var body: some View {
        ZStack {
            // Full-sensor frame fills the white box while expanded, aspect-fit so
            // nothing is cropped. Pulled from the camera's video output (never a
            // second preview layer), so the main viewfinder is untouched. Passive
            // display — it must NOT hit-test, or it swallows the collapse tap.
            if isExpanded, let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: outerSize.width, height: outerSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            }

            // White = full saved-photo bounds.
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.white.opacity(0.9), lineWidth: lineWidth)
                .frame(width: outerSize.width, height: outerSize.height)

            // Yellow = the region the viewfinder currently shows (a subset of the
            // photo), flush on the long-axis edges and inset on the short axis.
            // Half-opacity yellow reads as "the live view is restricted to here",
            // softer than the solid white saved-photo box. Drawn once the preview
            // layer has reported its real crop fraction.
            if let fraction = shortAxisFraction {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(.yellow.opacity(0.5), lineWidth: lineWidth)
                    .frame(width: outerSize.width * fraction, height: outerSize.height)
            }
        }
        // Guarantee a comfortable tap target even when collapsed (the short axis
        // is only ~33pt), without enlarging the drawn box.
        .frame(minWidth: 44, minHeight: 44)
        // Keep the white edge legible against bright scenes.
        .shadow(color: .black.opacity(0.35), radius: 1)
        // Recede to near-invisible when idle; full strength while expanded or just tapped.
        .opacity(restingOpacity)
        // The whole box area toggles the live preview (not just the thin strokes).
        .contentShape(Rectangle())
        .onTapGesture {
            wakeToken += 1   // wake + restart the idle timer
            onTap()
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        // Idle fade: from first appearance and after each tap, the HUD fades
        // linearly from full strength to the idle grey over `idleFadeSeconds`.
        // `isDimmed = false` snaps it back to full; the one-frame pre-sleep lets
        // that wake commit before the fade begins, so a tap mid-fade jumps to full
        // first rather than redirecting the in-flight fade from where it was.
        .task(id: wakeToken) {
            isDimmed = false
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: idleFadeSeconds)) {
                isDimmed = true
            }
        }
    }
}
