import SwiftUI

/// A 2D-projected view cube drawn with SwiftUI Canvas. Tracks the viewport
/// camera orientation live (yaw/pitch from ViewportCameraState) and responds
/// to face / edge / corner clicks to snap the camera.
///
/// Placed as an overlay at the viewport's top-right, above the existing
/// ViewportControls strip.
struct ViewCubeOverlay: View {
    @Binding var cameraState: ViewportCameraState
    let isEnabled: Bool

    @State private var hoveringTarget: ViewCubeTarget?
    @State private var isShowingHome = false

    private let size: Double = ViewCubeProjection.widgetSize + 14  // padding

    var body: some View {
        ZStack {
            cubeCanvas
            if isShowingHome {
                homeButton
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onHover { hovering in
            isShowingHome = hovering && isEnabled
            if !hovering { hoveringTarget = nil }
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { value in
                    guard isEnabled else { return }
                    // Drag on the cube forwards deltas to cameraState.rotate
                    // (same sign convention as the viewport's drag handler).
                    let sensitivity = 0.6
                    cameraState.rotate(deltaX: value.velocity.width * sensitivity * 0.01,
                                       deltaY: -value.velocity.height * sensitivity * 0.01)
                }
        )
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    // Tap is handled separately by the overlay's onTapGesture below
                }
        )
        .disabled(!isEnabled)
    }

    // MARK: - Canvas

    private var cubeCanvas: some View {
        Canvas { ctx, canvasSize in
            let yaw = cameraState.yawDegrees
            let pitch = cameraState.pitchDegrees

            // Offset the projection origin to the widget centre within the canvas.
            let offset = CGPoint(
                x: (canvasSize.width - ViewCubeProjection.widgetSize) / 2,
                y: (canvasSize.height - ViewCubeProjection.widgetSize) / 2
            )

            let quads = ViewCubeProjection.faceQuads(yaw: yaw, pitch: pitch)

            // Sort back-to-front for painter's algorithm.
            let sorted = quads.sorted { a, b in
                let da = faceDepthFor(target: a.target, yaw: yaw, pitch: pitch)
                let db = faceDepthFor(target: b.target, yaw: yaw, pitch: pitch)
                return da < db
            }

            for quad in sorted {
                let pts = quad.points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
                var path = Path()
                path.move(to: pts[0])
                for pt in pts.dropFirst() { path.addLine(to: pt) }
                path.closeSubpath()

                let isHovered = hoveringTarget == quad.target
                let isFront = isFacingCamera(target: quad.target, yaw: yaw, pitch: pitch)
                let fillColor = faceColor(target: quad.target, hovered: isHovered, frontFacing: isFront)
                ctx.fill(path, with: .color(fillColor))
                ctx.stroke(path, with: .color(.primary.opacity(0.35)), lineWidth: 0.8)

                // Draw face label on visible faces only.
                if isFront, let label = quad.target.faceLabel {
                    let center = CGPoint(
                        x: pts.map(\.x).reduce(0, +) / Double(pts.count),
                        y: pts.map(\.y).reduce(0, +) / Double(pts.count)
                    )
                    let text = Text(label)
                        .font(.system(size: 6, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.8))
                    ctx.draw(text, at: center)
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard isEnabled else { return }
            switch phase {
            case .active(let location):
                let localPt = adjustedPoint(location, canvasSize: size)
                hoveringTarget = ViewCubeProjection.hit(
                    at: localPt,
                    yaw: cameraState.yawDegrees,
                    pitch: cameraState.pitchDegrees
                )
            case .ended:
                hoveringTarget = nil
            }
        }
        .onTapGesture { location in
            guard isEnabled else { return }
            let localPt = adjustedPoint(location, canvasSize: size)
            if let target = ViewCubeProjection.hit(
                at: localPt,
                yaw: cameraState.yawDegrees,
                pitch: cameraState.pitchDegrees
            ) {
                snapCamera(to: target)
            }
        }
    }

    // MARK: - Home button

    private var homeButton: some View {
        VStack {
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    cameraState.reset()
                }
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 9))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Reset camera to home position")
            Spacer()
        }
        .frame(width: size, height: size)
        .allowsHitTesting(true)
    }

    // MARK: - Helpers

    private func snapCamera(to target: ViewCubeTarget) {
        withAnimation(.easeOut(duration: 0.25)) {
            cameraState.yawDegrees = target.yawDegrees
            cameraState.pitchDegrees = target.pitchDegrees
            cameraState.panX = 0
            cameraState.panY = 0
        }
    }

    /// Translate a tap/hover location from the full canvas space to the
    /// projection widget's internal coordinate space.
    private func adjustedPoint(_ location: CGPoint, canvasSize: Double) -> CGPoint {
        let offset = (canvasSize - ViewCubeProjection.widgetSize) / 2
        return CGPoint(x: location.x - offset, y: location.y - offset)
    }

    private func faceDepthFor(target: ViewCubeTarget, yaw: Double, pitch: Double) -> Double {
        let normal = faceNormal(target)
        let yawR = yaw * .pi / 180
        let pitchR = pitch * .pi / 180
        let cosY = cos(-yawR), sinY = sin(-yawR)
        _ = normal.x * cosY - normal.y * sinY  // x1 (unused depth-x component)
        let y1 = normal.x * sinY + normal.y * cosY
        let z1 = normal.z
        let cosP = cos(-pitchR), sinP = sin(-pitchR)
        let y2 = y1 * cosP - z1 * sinP
        return y2
    }

    private func isFacingCamera(target: ViewCubeTarget, yaw: Double, pitch: Double) -> Bool {
        faceDepthFor(target: target, yaw: yaw, pitch: pitch) < 0
    }

    private func faceNormal(_ target: ViewCubeTarget) -> (x: Double, y: Double, z: Double) {
        switch target {
        case .front:  return (0, -1, 0)
        case .back:   return (0,  1, 0)
        case .left:   return (-1, 0, 0)
        case .right:  return (1,  0, 0)
        case .top:    return (0,  0, 1)
        case .bottom: return (0,  0, -1)
        default:      return (0,  0, 0)
        }
    }

    private func faceColor(target: ViewCubeTarget, hovered: Bool, frontFacing: Bool) -> Color {
        if hovered {
            return Color.accentColor.opacity(0.75)
        }
        if !frontFacing {
            return Color(nsColor: .windowBackgroundColor).opacity(0.55)
        }
        switch target {
        case .top:    return Color(nsColor: .systemBlue).opacity(0.55)
        case .bottom: return Color(nsColor: .systemIndigo).opacity(0.45)
        case .front:  return Color(nsColor: .systemOrange).opacity(0.55)
        case .back:   return Color(nsColor: .systemOrange).opacity(0.35)
        case .right:  return Color(nsColor: .systemGreen).opacity(0.55)
        case .left:   return Color(nsColor: .systemGreen).opacity(0.35)
        default:      return Color.secondary.opacity(0.25)
        }
    }
}
