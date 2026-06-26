import SwiftUI

/// Draws action-safe (10% inset) and title-safe (20% inset) rectangles over the canvas.
struct SafeZonesOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height

            func insetRect(_ frac: CGFloat) -> CGRect {
                CGRect(x: w * frac, y: h * frac, width: w * (1 - frac * 2), height: h * (1 - frac * 2))
            }

            let dash = StrokeStyle(lineWidth: 1, dash: [4, 3])

            // Action safe — 10% inset, white
            ctx.stroke(Path(insetRect(0.10)), with: .color(.white.opacity(0.55)), style: dash)

            // Title safe — 20% inset, yellow
            ctx.stroke(Path(insetRect(0.20)), with: .color(.yellow.opacity(0.55)), style: dash)

            // Center crosshair
            let cx = w / 2, cy = h / 2, arm: CGFloat = 12
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: cx - arm, y: cy))
                p.addLine(to: CGPoint(x: cx + arm, y: cy))
                p.move(to: CGPoint(x: cx, y: cy - arm))
                p.addLine(to: CGPoint(x: cx, y: cy + arm))
            }, with: .color(.white.opacity(0.45)), lineWidth: 0.5)

            // Labels
            let labelStyle = AttributeContainer()
            func label(_ text: String, at point: CGPoint) {
                var a = labelStyle
                a[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.white.opacity(0.55)
                a[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = Font.system(size: 8)
                let resolved = ctx.resolve(Text(AttributedString(text, attributes: a)))
                ctx.draw(resolved, at: point, anchor: .topLeading)
            }
            label("Action Safe", at: CGPoint(x: w * 0.10 + 2, y: h * 0.10 + 2))
            label("Title Safe",  at: CGPoint(x: w * 0.20 + 2, y: h * 0.20 + 2))
        }
        .allowsHitTesting(false)
    }
}
