import SwiftUI

struct GameCanvas: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.13, blue: 0.68),
                    Color(red: 0.27, green: 0.02, blue: 0.55),
                    Color(red: 0.015, green: 0.025, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Canvas { context, size in
                drawWater(in: &context, size: size)
                drawDistantTerrain(in: &context, size: size)
                drawAmbientBubbles(in: &context, size: size)

                for reef in engine.reefs {
                    drawReef(reef, in: &context, size: size)
                }

                drawSubmarine(in: &context)
                drawForeground(in: &context, size: size)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func drawWater(in context: inout GraphicsContext, size: CGSize) {
        let glowCenter = CGPoint(x: size.width * 0.18, y: size.height * 0.08)
        context.fill(
            Path(ellipseIn: CGRect(x: -size.width * 0.4, y: -120, width: size.width * 1.3, height: size.height * 0.55)),
            with: .radialGradient(
                Gradient(colors: [.cyan.opacity(0.26), .clear]),
                center: glowCenter,
                startRadius: 5,
                endRadius: size.width * 0.7
            )
        )

        for index in 0..<5 {
            let drift = CGFloat(sin(engine.elapsed * 0.35 + Double(index))) * 22
            var ray = Path()
            let x = size.width * (0.02 + CGFloat(index) * 0.22) + drift
            ray.move(to: CGPoint(x: x, y: -20))
            ray.addLine(to: CGPoint(x: x + 52, y: -20))
            ray.addLine(to: CGPoint(x: x + 145, y: size.height * 0.72))
            ray.addLine(to: CGPoint(x: x + 80, y: size.height * 0.72))
            ray.closeSubpath()
            context.fill(ray, with: .color(.cyan.opacity(0.025)))
        }

        var surface = Path()
        surface.move(to: .zero)
        let waveStep: CGFloat = 20
        var x: CGFloat = 0
        while x <= size.width + waveStep {
            let y = 8 + sin(x * 0.045 + CGFloat(engine.elapsed) * 1.8) * 3
            surface.addLine(to: CGPoint(x: x, y: y))
            x += waveStep
        }
        surface.addLine(to: CGPoint(x: size.width, y: 0))
        surface.closeSubpath()
        context.fill(surface, with: .color(.white.opacity(0.16)))
    }

    private func drawDistantTerrain(in context: inout GraphicsContext, size: CGSize) {
        for layer in 0..<2 {
            let baseY = size.height - CGFloat(68 + layer * 35)
            let speed = CGFloat(layer + 1) * 7
            let offset = CGFloat(engine.elapsed) * speed
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: baseY))

            let step: CGFloat = 54
            var x: CGFloat = -step
            while x < size.width + step {
                let phaseX = x + offset.truncatingRemainder(dividingBy: step * 4)
                let y = baseY - (sin(phaseX * 0.021 + CGFloat(layer)) + 1) * CGFloat(10 + layer * 8)
                path.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(Color.indigo.opacity(layer == 0 ? 0.24 : 0.16)))
        }
    }

    private func drawAmbientBubbles(in context: inout GraphicsContext, size: CGSize) {
        for index in 0..<16 {
            let baseX = CGFloat((index * 83) % 397) / 397 * size.width
            let speed = CGFloat(10 + (index * 7) % 18)
            let travel = CGFloat(engine.elapsed) * speed
            let baseY = CGFloat((index * 131) % 701) / 701 * size.height
            let y = size.height - (baseY + travel).truncatingRemainder(dividingBy: size.height + 50)
            let x = baseX + sin(CGFloat(engine.elapsed) * 0.7 + CGFloat(index)) * 7
            let radius = CGFloat(1.5 + Double(index % 4))
            let bubble = Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
            context.stroke(bubble, with: .color(.white.opacity(0.18)), lineWidth: 1)
        }
    }

    private func drawReef(_ reef: ReefGate, in context: inout GraphicsContext, size: CGSize) {
        drawRockColumn(
            centerX: reef.x,
            from: 0,
            to: reef.topEdge,
            opensDownward: true,
            seed: reef.seed,
            in: &context
        )
        drawRockColumn(
            centerX: reef.x,
            from: reef.bottomEdge,
            to: size.height,
            opensDownward: false,
            seed: reef.seed &+ 17,
            in: &context
        )

        drawCoral(at: CGPoint(x: reef.x, y: reef.topEdge - 4), flipped: true, in: &context)
        drawCoral(at: CGPoint(x: reef.x, y: reef.bottomEdge + 5), flipped: false, in: &context)
    }

    private func drawRockColumn(
        centerX: CGFloat,
        from startY: CGFloat,
        to endY: CGFloat,
        opensDownward: Bool,
        seed: UInt64,
        in context: inout GraphicsContext
    ) {
        let halfWidth: CGFloat = 39
        let left = centerX - halfWidth
        let right = centerX + halfWidth
        let lipY = opensDownward ? endY : startY
        var path = Path()
        path.move(to: CGPoint(x: left, y: startY))
        path.addLine(to: CGPoint(x: right, y: startY))

        let height = max(1, endY - startY)
        for index in 0...7 {
            let fraction = CGFloat(index) / 7
            let y = startY + height * fraction
            let wobble = sin(CGFloat(index) * 2.1 + CGFloat(seed % 11)) * 5
            path.addLine(to: CGPoint(x: right + wobble, y: y))
        }

        path.addLine(to: CGPoint(x: right + 10, y: lipY))
        path.addLine(to: CGPoint(x: centerX + 17, y: lipY + (opensDownward ? 10 : -10)))
        path.addLine(to: CGPoint(x: centerX - 17, y: lipY + (opensDownward ? 5 : -5)))
        path.addLine(to: CGPoint(x: left - 10, y: lipY))

        for index in stride(from: 7, through: 0, by: -1) {
            let fraction = CGFloat(index) / 7
            let y = startY + height * fraction
            let wobble = cos(CGFloat(index) * 1.8 + CGFloat(seed % 7)) * 5
            path.addLine(to: CGPoint(x: left + wobble, y: y))
        }
        path.closeSubpath()

        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.18, green: 0.05, blue: 0.31),
                    Color(red: 0.43, green: 0.04, blue: 0.58),
                    Color(red: 0.14, green: 0.02, blue: 0.25)
                ]),
                startPoint: CGPoint(x: left, y: 0),
                endPoint: CGPoint(x: right, y: 0)
            )
        )
        context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 2)

        for index in 0..<4 {
            let dotY = startY + height * CGFloat(index + 1) / 5
            let dotX = centerX + (index.isMultiple(of: 2) ? -13 : 12)
            let dot = Path(ellipseIn: CGRect(x: dotX - 4, y: dotY - 4, width: 8, height: 8))
            context.fill(dot, with: .color(.black.opacity(0.16)))
        }
    }

    private func drawCoral(
        at point: CGPoint,
        flipped: Bool,
        in context: inout GraphicsContext
    ) {
        let direction: CGFloat = flipped ? -1 : 1
        var coral = Path()
        coral.move(to: point)
        coral.addCurve(
            to: CGPoint(x: point.x - 17, y: point.y + 17 * direction),
            control1: CGPoint(x: point.x - 4, y: point.y + 7 * direction),
            control2: CGPoint(x: point.x - 13, y: point.y + 8 * direction)
        )
        coral.move(to: CGPoint(x: point.x - 5, y: point.y + 5 * direction))
        coral.addCurve(
            to: CGPoint(x: point.x + 2, y: point.y + 24 * direction),
            control1: CGPoint(x: point.x - 5, y: point.y + 12 * direction),
            control2: CGPoint(x: point.x + 2, y: point.y + 14 * direction)
        )
        coral.move(to: CGPoint(x: point.x + 1, y: point.y + 7 * direction))
        coral.addCurve(
            to: CGPoint(x: point.x + 20, y: point.y + 17 * direction),
            control1: CGPoint(x: point.x + 8, y: point.y + 7 * direction),
            control2: CGPoint(x: point.x + 11, y: point.y + 16 * direction)
        )
        context.stroke(
            coral,
            with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.36, blue: 0.42), Color.orange]),
                startPoint: point,
                endPoint: CGPoint(x: point.x, y: point.y + 25 * direction)
            ),
            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawSubmarine(in context: inout GraphicsContext) {
        let bob = engine.state == .ready ? CGFloat(sin(engine.elapsed * 2)) * 7 : 0
        let center = CGPoint(x: engine.submarineX, y: engine.submarineY + bob)

        for index in 0..<4 {
            let phase = (CGFloat(engine.elapsed) * CGFloat(34 + index * 5) + CGFloat(index * 17))
                .truncatingRemainder(dividingBy: 78)
            let radius = CGFloat(2 + index)
            let x = center.x - 43 - phase
            let y = center.y + sin(phase * 0.11 + CGFloat(index)) * 9
            let bubble = Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
            context.stroke(bubble, with: .color(.cyan.opacity(0.56)), lineWidth: 1.5)
        }

        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .radians(engine.submarineRotationRadians))

            var tail = Path()
            tail.move(to: CGPoint(x: -27, y: -5))
            tail.addLine(to: CGPoint(x: -48, y: -18))
            tail.addLine(to: CGPoint(x: -44, y: 0))
            tail.addLine(to: CGPoint(x: -48, y: 18))
            tail.addLine(to: CGPoint(x: -25, y: 7))
            tail.closeSubpath()
            layer.fill(tail, with: .color(Color(red: 0.76, green: 0.12, blue: 0.42)))

            let propellerShift = CGFloat(sin(engine.elapsed * (engine.isThrustActive ? 24 : 6))) * 4
            let propeller = Path(
                roundedRect: CGRect(x: -54, y: -15 + propellerShift, width: 7, height: 30 - propellerShift * 2),
                cornerRadius: 4
            )
            layer.fill(propeller, with: .color(.white.opacity(0.9)))

            let body = Path(roundedRect: CGRect(x: -35, y: -19, width: 73, height: 38), cornerRadius: 19)
            layer.fill(
                body,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 1, green: 0.49, blue: 0.22), Color(red: 0.98, green: 0.18, blue: 0.42)]),
                    startPoint: CGPoint(x: 0, y: -20),
                    endPoint: CGPoint(x: 0, y: 20)
                )
            )
            layer.stroke(body, with: .color(.white.opacity(0.9)), lineWidth: 2.3)

            let cabin = Path(roundedRect: CGRect(x: -10, y: -29, width: 28, height: 16), cornerRadius: 8)
            layer.fill(cabin, with: .color(Color(red: 0.34, green: 0.03, blue: 0.55)))
            layer.stroke(cabin, with: .color(.white.opacity(0.82)), lineWidth: 2)

            var periscope = Path()
            periscope.move(to: CGPoint(x: 4, y: -28))
            periscope.addLine(to: CGPoint(x: 4, y: -38))
            periscope.addLine(to: CGPoint(x: 13, y: -38))
            layer.stroke(periscope, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            for windowX in [-13.0, 9.0] {
                let ring = Path(ellipseIn: CGRect(x: windowX - 7, y: -7, width: 14, height: 14))
                layer.fill(ring, with: .color(.white.opacity(0.95)))
                let glass = Path(ellipseIn: CGRect(x: windowX - 4.5, y: -4.5, width: 9, height: 9))
                layer.fill(glass, with: .color(Color.cyan.opacity(0.9)))
            }

            var fin = Path()
            fin.move(to: CGPoint(x: -1, y: 17))
            fin.addLine(to: CGPoint(x: 13, y: 29))
            fin.addLine(to: CGPoint(x: 21, y: 17))
            fin.closeSubpath()
            layer.fill(fin, with: .color(Color(red: 0.73, green: 0.08, blue: 0.43)))
        }
    }

    private func drawForeground(in context: inout GraphicsContext, size: CGSize) {
        var floor = Path()
        floor.move(to: CGPoint(x: 0, y: size.height - 30))
        let step: CGFloat = 28
        var x: CGFloat = 0
        while x <= size.width + step {
            let y = size.height - 28 + sin(x * 0.06 + CGFloat(engine.elapsed) * 0.25) * 5
            floor.addLine(to: CGPoint(x: x, y: y))
            x += step
        }
        floor.addLine(to: CGPoint(x: size.width, y: size.height))
        floor.addLine(to: CGPoint(x: 0, y: size.height))
        floor.closeSubpath()
        context.fill(floor, with: .color(Color(red: 0.055, green: 0.015, blue: 0.12)))

        for index in 0..<8 {
            let plantX = CGFloat(index) * size.width / 7 + 8
            let sway = CGFloat(sin(engine.elapsed * 1.1 + Double(index))) * 5
            var plant = Path()
            plant.move(to: CGPoint(x: plantX, y: size.height))
            plant.addCurve(
                to: CGPoint(x: plantX + sway, y: size.height - CGFloat(24 + (index % 3) * 9)),
                control1: CGPoint(x: plantX - 8, y: size.height - 10),
                control2: CGPoint(x: plantX + sway + 7, y: size.height - 19)
            )
            context.stroke(plant, with: .color(.cyan.opacity(0.25)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }
}
