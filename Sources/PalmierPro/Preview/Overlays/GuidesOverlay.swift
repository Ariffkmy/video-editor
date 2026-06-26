import SwiftUI

/// Renders canvas guides and handles drag-to-move / drag-off-canvas-to-delete.
struct GuidesOverlay: View {
    let guides: [Guide]
    let canvasOrigin: CGPoint
    let canvasSize: CGSize
    let onMove: (String, Double) -> Void
    let onDelete: (String) -> Void

    @State private var dragging: String?

    private let hitWidth: CGFloat = 10
    private let guideColor = Color.cyan.opacity(0.8)

    var body: some View {
        ZStack {
            ForEach(guides) { guide in
                guideView(guide)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func guideView(_ guide: Guide) -> some View {
        let screenPos = screenPosition(for: guide)

        ZStack {
            // Visible line
            if guide.axis == .horizontal {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: screenPos))
                    p.addLine(to: CGPoint(x: 10000, y: screenPos))
                }
                .stroke(guideColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                Path { p in
                    p.move(to: CGPoint(x: screenPos, y: 0))
                    p.addLine(to: CGPoint(x: screenPos, y: 10000))
                }
                .stroke(guideColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            // Transparent hit area
            if guide.axis == .horizontal {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: hitWidth)
                    .offset(y: screenPos - hitWidth / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle().offset(y: screenPos - hitWidth / 2))
                    .gesture(dragGesture(for: guide))
                    .cursor(.resizeUpDown)
            } else {
                Color.clear
                    .frame(width: hitWidth)
                    .frame(maxHeight: .infinity)
                    .offset(x: screenPos - hitWidth / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle().offset(x: screenPos - hitWidth / 2))
                    .gesture(dragGesture(for: guide))
                    .cursor(.resizeLeftRight)
            }
        }
    }

    private func screenPosition(for guide: Guide) -> CGFloat {
        guide.axis == .horizontal
            ? canvasOrigin.y + guide.position * canvasSize.height
            : canvasOrigin.x + guide.position * canvasSize.width
    }

    private func dragGesture(for guide: Guide) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { val in
                dragging = guide.id
                let raw: Double
                if guide.axis == .horizontal {
                    raw = Double(val.location.y - canvasOrigin.y) / Double(canvasSize.height)
                } else {
                    raw = Double(val.location.x - canvasOrigin.x) / Double(canvasSize.width)
                }
                onMove(guide.id, raw)
            }
            .onEnded { val in
                dragging = nil
                let raw: Double
                if guide.axis == .horizontal {
                    raw = Double(val.location.y - canvasOrigin.y) / Double(canvasSize.height)
                } else {
                    raw = Double(val.location.x - canvasOrigin.x) / Double(canvasSize.width)
                }
                if raw < 0 || raw > 1 {
                    onDelete(guide.id)
                }
            }
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
