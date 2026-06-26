import SwiftUI

/// Horizontal and vertical pixel rulers overlaid on the preview area.
/// Dragging from the H-ruler downward creates a horizontal guide;
/// dragging from the V-ruler rightward creates a vertical guide.
struct CanvasRulersView: View {
    let canvasOrigin: CGPoint
    let canvasSize: CGSize
    let pixelWidth: Int
    let pixelHeight: Int
    let onCreateGuide: (GuideAxis, Double) -> Void

    static let size: CGFloat = 20

    @State private var hDragPos: CGFloat?
    @State private var vDragPos: CGFloat?

    private var pxPerPtX: CGFloat { canvasSize.width / CGFloat(pixelWidth) }
    private var pxPerPtY: CGFloat { canvasSize.height / CGFloat(pixelHeight) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Horizontal ruler (top strip)
            hRuler
                .frame(height: Self.size)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Vertical ruler (left strip, below corner)
            vRuler
                .frame(width: Self.size)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, Self.size)

            // Corner box
            Rectangle()
                .fill(Color(AppTheme.Background.raised))
                .frame(width: Self.size, height: Self.size)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(AppTheme.Border.primaryColor).frame(width: AppTheme.BorderWidth.hairline)
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.hairline)
                }

            // Preview line while dragging from ruler
            if let y = hDragPos {
                Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: 5000, y: y)) }
                    .stroke(Color.cyan.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
            }
            if let x = vDragPos {
                Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: 5000)) }
                    .stroke(Color.cyan.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(true)
    }

    // MARK: - Horizontal ruler

    private var hRuler: some View {
        Canvas { ctx, size in
            drawRuler(ctx: ctx, size: size, axis: .horizontal)
        }
        .background(Color(AppTheme.Background.raised))
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.hairline)
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { val in hDragPos = val.location.y }
                .onEnded { val in
                    let norm = Double(val.location.y - canvasOrigin.y) / Double(canvasSize.height)
                    hDragPos = nil
                    if norm >= 0 && norm <= 1 { onCreateGuide(.horizontal, norm) }
                }
        )
    }

    // MARK: - Vertical ruler

    private var vRuler: some View {
        Canvas { ctx, size in
            drawRuler(ctx: ctx, size: size, axis: .vertical)
        }
        .background(Color(AppTheme.Background.raised))
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(width: AppTheme.BorderWidth.hairline)
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { val in vDragPos = val.location.x }
                .onEnded { val in
                    let norm = Double(val.location.x - canvasOrigin.x) / Double(canvasSize.width)
                    vDragPos = nil
                    if norm >= 0 && norm <= 1 { onCreateGuide(.vertical, norm) }
                }
        )
    }

    // MARK: - Ruler drawing

    private func drawRuler(ctx: GraphicsContext, size: CGSize, axis: GuideAxis) {
        let isH = axis == .horizontal
        let pxPerPt = isH ? pxPerPtX : pxPerPtY
        let origin = isH ? canvasOrigin.x : (canvasOrigin.y - Self.size)
        let viewLength = isH ? size.width : size.height

        guard pxPerPt > 0 else { return }

        let step = niceStep(pxPerPt: pxPerPt)
        let ptPerStep = CGFloat(step) * pxPerPt
        let firstCanvasPx = floor(-origin / pxPerPt / CGFloat(step)) * CGFloat(step)

        var px = firstCanvasPx
        while true {
            let screenPos = px * pxPerPt + origin
            if screenPos > viewLength { break }
            if screenPos >= 0 {
                let isMajor = Int(px) % (step * 5) == 0
                let tickLen: CGFloat = isMajor ? Self.size * 0.6 : Self.size * 0.35
                let p1: CGPoint, p2: CGPoint
                if isH {
                    p1 = CGPoint(x: screenPos, y: size.height)
                    p2 = CGPoint(x: screenPos, y: size.height - tickLen)
                } else {
                    p1 = CGPoint(x: size.width, y: screenPos)
                    p2 = CGPoint(x: size.width - tickLen, y: screenPos)
                }
                var tick = Path()
                tick.move(to: p1)
                tick.addLine(to: p2)
                ctx.stroke(tick, with: .color(.white.opacity(0.4)), lineWidth: 0.5)

                if isMajor {
                    let labelText = Text("\(Int(px))")
                        .font(.system(size: 7))
                        .foregroundStyle(Color.white.opacity(0.5))
                    let resolved = ctx.resolve(labelText)
                    if isH {
                        ctx.draw(resolved, at: CGPoint(x: screenPos + 2, y: 2), anchor: .topLeading)
                    } else {
                        ctx.draw(resolved, at: CGPoint(x: 2, y: screenPos + 1), anchor: .topLeading)
                    }
                }
            }
            px += CGFloat(step)
            if ptPerStep < 1 { break }
        }
    }

    private func niceStep(pxPerPt: CGFloat) -> Int {
        // We want ticks roughly every 40pt on screen.
        let rawStep = 40.0 / pxPerPt
        let candidates = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500, 1000]
        return candidates.first { CGFloat($0) >= rawStep } ?? 1000
    }
}
