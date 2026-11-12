import Foundation

/// Maps raw SpaceMouse axis reports to viewport camera deltas.
///
/// FRAME: the macOS ConnexionClient driver delivers a right-handed **Z-up**
/// device frame (X right, Y toward the user / depth, Z up). This was confirmed
/// two independent ways:
///   • Blender's `intern/ghost/GHOST_NDOFManagerCocoa.mm` remaps the raw axes
///     `t = {axis0, -axis2, axis1}`, `r = {-axis3, axis5, -axis4}` — i.e. it
///     treats axis1 as depth/zoom, axis2 as vertical, and yaw as axis5.
///   • The owner's hardware, directly: with the earlier Y-up mapping, twisting
///     the cap did NOTHING (twist landed on axis5=rz, which was ignored) and
///     lifting the cap ZOOMED (vertical landed on axis2=tz, which drove zoom).
/// Earlier PRs (#272/#273) followed the 3Dconnexion/FreeCAD "Y-up presented
/// frame"; the RAW macOS delivery is Z-up, as Blender's Cocoa handler shows.
///
/// Axis→gesture assignment CONFIRMED from raw device captures (every motion
/// report logged, clustered by gesture, cross-checked by isolation + temporal
/// order). All six DOF, each firing cleanly in isolation:
///
///   axis0  Motion.tx  slide left/right       → horizontal pan (MOVE)
///   axis1  Motion.ty  push/pull (depth)      → zoom / dolly   (MOVE)
///   axis2  Motion.tz  lift up/down           → vertical pan   (MOVE)
///   axis3  Motion.rx  tilt forward/back      → orbit pitch    (ROTATE)
///   axis4  Motion.ry  tilt / roll left-right → camera ROLL    (ROTATE)
///   axis5  Motion.rz  twist about vertical   → orbit yaw      (ROTATE)
///
/// All six DOF map to SIX DISTINCT actions — the standard 6-DOF navigation.
/// Every translation moves and every rotation turns, each about its own axis:
/// pitch (ax3), roll (ax4) and yaw (ax5) are genuinely different rotations. Roll
/// spins the SCULPTURE about the view axis (ViewportCameraState.modelSpin), NOT
/// the camera — so the viewport stays upright and pan never drifts diagonally.
/// It is distinct from the ax5 twist/yaw.
///
/// Signs follow object mode; panY is hardware-anchored (lift reports tz < 0 →
/// +tz = content up). Remaining DIRECTION bits (pan L/R, zoom in/out, roll and
/// yaw sense) are one-line sign flips if any feels reversed.
///
/// Camera sign conventions (ViewportCameraState.pan/rotate/zoom):
///   pan  deltaX > 0 → content moves LEFT   (panLeft uses +24)
///   pan  deltaY > 0 → content moves DOWN   (panDown uses +24)
///   zoom scrollDeltaY > 0 → distance grows → zoom OUT
///   rotate deltaX → yaw, deltaY → pitch
enum SpaceMouseMapping {
    struct CameraDeltas: Equatable {
        var orbitX: Double
        var orbitY: Double
        var roll: Double
        var panX: Double
        var panY: Double
        var zoom: Double
    }

    static let orbitGain = 0.02
    static let panGain = 0.015
    static let zoomGain = 0.012

    static func cameraDeltas(for motion: SpaceMouseController.Motion) -> CameraDeltas {
        CameraDeltas(
            orbitX: motion.rz * orbitGain,   // twist (ax5) → yaw
            orbitY: motion.rx * orbitGain,   // tilt fwd/back (ax3) → pitch
            roll: motion.ry * orbitGain,     // tilt/roll left-right (ax4) → sculpture roll
            panX: motion.tx * panGain,       // slide left/right (ax0) → horizontal pan
            panY: motion.tz * panGain,       // lift up (ax2) → content up
            zoom: -motion.ty * zoomGain      // push/pull (ax1) → zoom
        )
    }
}
