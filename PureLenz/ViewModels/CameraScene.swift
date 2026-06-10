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
import Observation

/// Root object that owns the camera services and view models for the app.
///
/// Having a single owner means the view models are created once, in dependency
/// order, and are non-optional everywhere downstream. Child views read the
/// `@Observable` view models directly (SwiftUI tracks the dependencies), so we
/// no longer hand-roll `Binding(get:set:)` wrappers in `ContentView`.
@Observable
final class CameraScene {
    let cameraService: CameraService
    let haptics: HapticManager
    let cameraVM: CameraViewModel
    let exposureVM: ExposureControlViewModel
    let autoExposure: AutoExposureCoordinator

    init() {
        // Build dependencies bottom-up so each view model gets fully-formed
        // collaborators. Order matters: the coordinator depends on the
        // exposure view model, so it is created last.
        let cameraService = CameraService()
        let haptics = HapticManager()
        let cameraVM = CameraViewModel(cameraService: cameraService, hapticManager: haptics)
        let exposureVM = ExposureControlViewModel(cameraService: cameraService, hapticManager: haptics)
        let autoExposure = AutoExposureCoordinator(cameraService: cameraService, exposureControlVM: exposureVM)

        self.cameraService = cameraService
        self.haptics = haptics
        self.cameraVM = cameraVM
        self.exposureVM = exposureVM
        self.autoExposure = autoExposure

        // Wire up capture callbacks once. Device orientation is owned by
        // CameraService, derived from its RotationCoordinator.
        cameraVM.setupCamera()
    }

    /// Forward app lifecycle changes to the view models that care about them.
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        cameraVM.handleScenePhaseChange(newPhase, autoExposureManager: autoExposure.autoExposureManager)
        autoExposure.handleScenePhaseChange(newPhase)
    }
}
