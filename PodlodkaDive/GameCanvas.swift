import SwiftUI

enum OceanPalette {
    static let ink = Color(red: 0.025, green: 0.10, blue: 0.15)
    static let teal = Color(red: 0.38, green: 0.89, blue: 0.80)
    static let gold = Color(red: 1, green: 0.77, blue: 0.33)
    static let muted = Color(red: 0.56, green: 0.72, blue: 0.75)
    static let white = Color(red: 0.91, green: 0.96, blue: 0.93)
    static let danger = Color(red: 1, green: 0.43, blue: 0.35)
    static let blue = Color(red: 0.4, green: 0.72, blue: 1)
}

struct GameCanvas: View {
    @ObservedObject var engine: GameEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var time: Double { reduceMotion ? 0 : engine.elapsed }

    var body: some View {
        Canvas { context, actualSize in
            let scale = actualSize.width / engine.viewport.width
            context.scaleBy(x: scale, y: scale)
            let size = engine.viewport
            drawWater(in: &context, size: size)
            if engine.state == .ready {
                drawWelcome(in: &context, size: size)
            } else {
                context.drawLayer { world in
                    world.translateBy(x: size.width / 2 - engine.camera.x, y: size.height / 2 - engine.camera.y)
                    drawWorld(in: &world)
                }
            }
            drawSubmarine(in: &context, size: size)
            if engine.sonarRemaining > 0 && engine.state != .ready { drawSonar(in: &context) }
        }
        .background(OceanPalette.ink)
        .accessibilityHidden(true)
    }

    private var visible: CGRect {
        CGRect(x: engine.camera.x - engine.viewport.width / 2 - 120,
               y: engine.camera.y - engine.viewport.height / 2 - 120,
               width: engine.viewport.width + 240, height: engine.viewport.height + 240)
    }

    private func drawWater(in context: inout GraphicsContext, size: CGSize) {
        let depth = engine.state == .ready ? 0.2 : min(1, engine.camera.y / engine.level.size.height)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.055 - depth * 0.025, green: 0.27 - depth * 0.12, blue: 0.32 - depth * 0.08),
                              OceanPalette.ink, Color(red: 0.025, green: 0.14, blue: 0.21)]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        for index in 0..<5 {
            let x = CGFloat(index) * 100 - 80 + CGFloat(sin(time * 0.18)) * 12
            var ray = Path()
            ray.move(to: CGPoint(x: x, y: 0))
            ray.addLine(to: CGPoint(x: x + 32, y: 0))
            ray.addLine(to: CGPoint(x: x - 90, y: size.height))
            ray.addLine(to: CGPoint(x: x - 180, y: size.height))
            ray.closeSubpath()
            context.fill(ray, with: .linearGradient(Gradient(colors: [OceanPalette.teal.opacity(0.045 * (1 - depth)), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        for index in 0..<45 {
            let parallax: CGFloat = reduceMotion || engine.state == .ready ? 0 : 0.18
            let rawX = CGFloat((index * 97) % 419) - engine.camera.x * parallax
            let rawY = CGFloat((index * 173) % 937) - engine.camera.y * parallax - CGFloat(time) * 3
            let x = (rawX.truncatingRemainder(dividingBy: size.width) + size.width).truncatingRemainder(dividingBy: size.width)
            let y = (rawY.truncatingRemainder(dividingBy: size.height) + size.height).truncatingRemainder(dividingBy: size.height)
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(OceanPalette.teal.opacity(0.22)))
        }
        for index in 0..<5 {
            let y = CGFloat(index) * 160 + 160
            var tick = Path()
            tick.move(to: CGPoint(x: 12, y: y))
            tick.addLine(to: CGPoint(x: 21, y: y))
            context.stroke(tick, with: .color(OceanPalette.teal.opacity(0.12)), lineWidth: 1)
        }
    }

    private func drawWelcome(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.43)
        for radius: CGFloat in [76, 108, 140] {
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(OceanPalette.teal.opacity(radius == 76 ? 0.14 : 0.06)),
                           style: StrokeStyle(lineWidth: 0.8, dash: radius == 108 ? [2, 7] : []))
        }
        for layer in 0..<3 {
            var ridge = Path()
            ridge.move(to: CGPoint(x: 0, y: size.height))
            for i in 0...16 {
                let x = CGFloat(i) * size.width / 16
                ridge.addLine(to: CGPoint(x: x, y: size.height - CGFloat(60 + layer * 40) - sin(x * 0.022 + CGFloat(layer)) * 24))
            }
            ridge.addLine(to: CGPoint(x: size.width, y: size.height))
            ridge.closeSubpath()
            context.fill(ridge, with: .color(OceanPalette.teal.opacity(0.025)))
        }
    }

    private func drawWorld(in context: inout GraphicsContext) {
        let size = engine.level.size
        let surface = CGRect(x: 0, y: 0, width: size.width, height: 100)
        context.fill(Path(surface), with: .color(OceanPalette.teal.opacity(0.09)))
        var line = Path()
        line.move(to: CGPoint(x: 0, y: 100))
        line.addLine(to: CGPoint(x: size.width, y: 100))
        context.stroke(line, with: .color(OceanPalette.teal.opacity(0.3)), lineWidth: 2)
        context.fill(Path(CGRect(x: 0, y: size.height - 25, width: size.width, height: 25)), with: .color(OceanPalette.ink))
        for zone in engine.level.currents where visible.intersects(zone.bounds) { drawCurrent(zone, in: &context) }
        for rock in engine.level.rocks where visible.intersects(rock.bounds) { drawRock(rock, in: &context) }
        if visible.insetBy(dx: -80, dy: -80).contains(engine.level.base) { drawBase(in: &context) }
        if visible.insetBy(dx: -120, dy: -120).contains(engine.level.wreck) { drawWreck(in: &context) }
        for pickup in engine.pickups where !pickup.collected && visible.contains(pickup.position) { drawPickup(pickup, in: &context) }
        for mine in engine.mines where visible.contains(mine.position) { drawMine(mine, in: &context) }
        // Small schools belong to the world, making camera movement easy to read.
        for group in 0..<15 {
            let origin = CGPoint(x: CGFloat((group * 347 + 430) % 1450), y: CGFloat(group * 173 + 310))
            guard visible.contains(origin) else { continue }
            for i in 0..<5 {
                let x = origin.x + CGFloat(i * 12) + CGFloat(sin(time * 0.4)) * 14
                let y = origin.y + CGFloat((i * 17) % 29)
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 8, height: 3)), with: .color(OceanPalette.teal.opacity(0.2)))
            }
        }
    }

    private func drawRock(_ rock: OceanRock, in context: inout GraphicsContext) {
        var path = Path()
        path.addLines(rock.vertices)
        path.closeSubpath()
        let bounds = rock.bounds
        context.fill(path, with: .linearGradient(Gradient(colors: [
            Color(red: 0.075, green: 0.28, blue: 0.30), Color(red: 0.055, green: 0.19, blue: 0.23),
            Color(red: 0.025, green: 0.12, blue: 0.18)]),
            startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
        context.stroke(path, with: .color(OceanPalette.teal.opacity(0.38)), lineWidth: 1.4)
        context.drawLayer { layer in
            layer.clip(to: path)
            for i in 0..<12 {
                let y = bounds.minY + CGFloat(i) * 52
                var seam = Path()
                seam.move(to: CGPoint(x: bounds.minX - 10, y: y + 40))
                seam.addLine(to: CGPoint(x: bounds.midX - 30, y: y))
                seam.addLine(to: CGPoint(x: bounds.maxX + 10, y: y + 60))
                layer.stroke(seam, with: .color(OceanPalette.ink.opacity(0.35)), lineWidth: 3)
                let x = bounds.minX + CGFloat((i * 37 + rock.id * 43) % max(1, Int(bounds.width)))
                layer.fill(Path(ellipseIn: CGRect(x: x, y: y + 13, width: 4, height: 4)), with: .color(OceanPalette.teal.opacity(0.3)))
            }
        }
        for (index, vertex) in rock.vertices.enumerated() where index.isMultiple(of: 2) {
            let p = CGPoint(x: vertex.x * 0.92 + bounds.midX * 0.08, y: vertex.y * 0.92 + bounds.midY * 0.08)
            drawCoral(at: p, height: 20 + CGFloat(index) * 2, direction: p.y < bounds.midY ? 1 : -1,
                      color: index.isMultiple(of: 4) ? OceanPalette.teal : OceanPalette.danger, in: &context)
        }
    }

    private func drawCurrent(_ zone: OceanCurrent, in context: inout GraphicsContext) {
        let rect = zone.bounds
        context.fill(Path(roundedRect: rect, cornerRadius: 45), with: .color(OceanPalette.blue.opacity(0.045)))
        let vertical = abs(zone.velocity.dy) > abs(zone.velocity.dx)
        let direction: CGFloat = (vertical ? zone.velocity.dy : zone.velocity.dx) > 0 ? 1 : -1
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            for i in 0..<28 {
                let travel = CGFloat(time) * 25 * direction
                let x = vertical ? rect.minX + CGFloat((i * 41) % max(1, Int(rect.width)))
                    : rect.minX + (CGFloat(i * 43) + travel).truncatingRemainder(dividingBy: rect.width)
                let y = vertical ? rect.minY + (CGFloat(i * 53) + travel).truncatingRemainder(dividingBy: rect.height)
                    : rect.minY + CGFloat((i * 31) % max(1, Int(rect.height)))
                var streak = Path()
                streak.move(to: CGPoint(x: x, y: y))
                streak.addLine(to: CGPoint(x: x + (vertical ? 0 : 18 * direction), y: y + (vertical ? 18 * direction : 0)))
                layer.stroke(streak, with: .color(OceanPalette.blue.opacity(0.2)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                var arrow = Path()
                if vertical {
                    arrow.move(to: CGPoint(x: x - 3, y: y + 12 * direction))
                    arrow.addLine(to: CGPoint(x: x, y: y + 18 * direction))
                    arrow.addLine(to: CGPoint(x: x + 3, y: y + 12 * direction))
                } else {
                    arrow.move(to: CGPoint(x: x + 12 * direction, y: y - 3))
                    arrow.addLine(to: CGPoint(x: x + 18 * direction, y: y))
                    arrow.addLine(to: CGPoint(x: x + 12 * direction, y: y + 3))
                }
                layer.stroke(arrow, with: .color(OceanPalette.blue.opacity(0.25)), lineWidth: 1)
            }
        }
    }

    private func drawBase(in context: inout GraphicsContext) {
        let p = engine.level.base
        let readyToDock = engine.hasBlackBox
        context.stroke(Path(ellipseIn: CGRect(x: p.x - 68, y: p.y - 68, width: 136, height: 136)),
                       with: .color(OceanPalette.teal.opacity(readyToDock ? 0.7 : 0.22)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 7]))
        var cable = Path()
        cable.move(to: CGPoint(x: p.x, y: 100))
        cable.addLine(to: CGPoint(x: p.x, y: p.y - 55))
        context.stroke(cable, with: .color(OceanPalette.muted.opacity(0.45)), lineWidth: 2)
        let dock = Path(roundedRect: CGRect(x: p.x - 54, y: p.y - 62, width: 108, height: 34), cornerRadius: 9)
        context.fill(dock, with: .color(Color(red: 0.12, green: 0.31, blue: 0.33)))
        context.stroke(dock, with: .color(OceanPalette.teal.opacity(0.6)), lineWidth: 1.2)
        for i in 0..<5 {
            context.fill(Path(roundedRect: CGRect(x: p.x - 41 + CGFloat(i) * 18, y: p.y - 53, width: 10, height: 7), cornerRadius: 2),
                         with: .color(OceanPalette.teal.opacity(0.7)))
        }
        drawText(readyToDock ? "БАЗА · СТЫКОВКА" : "БАЗА · 18", at: CGPoint(x: p.x, y: p.y + 84), color: OceanPalette.teal, in: &context)
        if readyToDock && hypot(engine.position.x - p.x, engine.position.y - p.y) < 100 {
            drawText("Отпусти стик", at: CGPoint(x: p.x, y: p.y + 101), color: OceanPalette.white, in: &context)
        }
    }

    private func drawWreck(in context: inout GraphicsContext) {
        let p = engine.level.wreck
        context.drawLayer { layer in
            layer.translateBy(x: p.x, y: p.y + 49)
            layer.rotate(by: .degrees(-9))
            var hull = Path()
            hull.move(to: CGPoint(x: -95, y: -20))
            hull.addLine(to: CGPoint(x: -75, y: 25))
            hull.addLine(to: CGPoint(x: 54, y: 30))
            hull.addLine(to: CGPoint(x: 91, y: -13))
            hull.addLine(to: CGPoint(x: 22, y: -9))
            hull.addLine(to: CGPoint(x: 11, y: 9))
            hull.addLine(to: CGPoint(x: -8, y: -16))
            hull.closeSubpath()
            layer.fill(hull, with: .color(Color(red: 0.24, green: 0.28, blue: 0.27)))
            layer.stroke(hull, with: .color(OceanPalette.gold.opacity(0.25)), lineWidth: 1.5)
            layer.fill(Path(roundedRect: CGRect(x: -60, y: -46, width: 45, height: 30), cornerRadius: 4),
                       with: .color(Color(red: 0.15, green: 0.25, blue: 0.27)))
            for i in 0..<3 {
                layer.fill(Path(ellipseIn: CGRect(x: -52 + CGFloat(i) * 14, y: -36, width: 7, height: 7)), with: .color(OceanPalette.ink))
            }
            drawCoral(at: CGPoint(x: 45, y: 10), height: 38, direction: -1, color: OceanPalette.teal, in: &layer)
        }
        drawText("ASTER · ЗАТОНУВШИЙ КОРАБЛЬ", at: CGPoint(x: p.x - 8, y: p.y + 109), color: OceanPalette.muted, in: &context)
    }

    private func drawPickup(_ pickup: OceanPickup, in context: inout GraphicsContext) {
        let p = CGPoint(x: pickup.position.x, y: pickup.position.y + CGFloat(sin(time * 1.8 + Double(pickup.id))) * 3)
        let color: Color = pickup.kind == .shield ? OceanPalette.blue : (pickup.kind == .battery ? OceanPalette.teal : OceanPalette.gold)
        context.fill(Path(ellipseIn: CGRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.17), .clear]), center: p, startRadius: 2, endRadius: 32))
        switch pickup.kind {
        case .battery:
            let body = Path(roundedRect: CGRect(x: p.x - 8, y: p.y - 12, width: 16, height: 24), cornerRadius: 4)
            context.fill(body, with: .color(OceanPalette.ink))
            context.stroke(body, with: .color(color), lineWidth: 1.5)
            context.fill(Path(CGRect(x: p.x - 3, y: p.y - 16, width: 6, height: 4)), with: .color(color))
            for i in 0..<3 { context.fill(Path(CGRect(x: p.x - 4, y: p.y - 7 + CGFloat(i) * 6, width: 8, height: 3)), with: .color(color)) }
        case .shield:
            var shield = Path()
            shield.move(to: CGPoint(x: p.x, y: p.y - 15))
            shield.addLine(to: CGPoint(x: p.x + 12, y: p.y - 9))
            shield.addQuadCurve(to: CGPoint(x: p.x, y: p.y + 15), control: CGPoint(x: p.x + 13, y: p.y + 6))
            shield.addQuadCurve(to: CGPoint(x: p.x - 12, y: p.y - 9), control: CGPoint(x: p.x - 13, y: p.y + 6))
            shield.closeSubpath()
            context.fill(shield, with: .color(color.opacity(0.15)))
            context.stroke(shield, with: .color(color), lineWidth: 1.5)
        case .sample:
            var crystal = Path()
            crystal.addLines([CGPoint(x: p.x, y: p.y - 12), CGPoint(x: p.x + 9, y: p.y), CGPoint(x: p.x, y: p.y + 12), CGPoint(x: p.x - 9, y: p.y)])
            crystal.closeSubpath()
            context.fill(crystal, with: .linearGradient(Gradient(colors: [OceanPalette.white, color]),
                startPoint: CGPoint(x: p.x - 8, y: p.y - 12), endPoint: CGPoint(x: p.x + 8, y: p.y + 12)))
        case .blackBox:
            let box = Path(roundedRect: CGRect(x: p.x - 18, y: p.y - 12, width: 36, height: 24), cornerRadius: 5)
            context.fill(box, with: .color(OceanPalette.ink))
            context.stroke(box, with: .color(color), lineWidth: 2)
            context.fill(Path(CGRect(x: p.x - 13, y: p.y - 10, width: 4, height: 20)), with: .color(color))
            context.fill(Path(CGRect(x: p.x + 9, y: p.y - 10, width: 4, height: 20)), with: .color(color))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(OceanPalette.teal))
        }
        let labels: [PickupKind: String] = [.battery: "+30 ЭНЕРГИИ", .shield: "ЩИТ", .sample: "ОБРАЗЕЦ · 75", .blackBox: "ЧЁРНЫЙ ЯЩИК"]
        if hypot(engine.position.x - p.x, engine.position.y - p.y) < 200 || pickup.kind == .blackBox {
            drawText(labels[pickup.kind] ?? "", at: CGPoint(x: p.x, y: p.y + 31), color: color, in: &context)
        }
    }

    private func drawMine(_ mine: OceanMine, in context: inout GraphicsContext) {
        let p = mine.position
        if mine.phase == .spent { return }
        if mine.phase == .exploding {
            let progress = 1 - mine.timer / 0.65
            let radius = OceanMine.blastRadius * CGFloat(0.3 + progress * 0.7)
            let blast = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            context.fill(blast, with: .color(OceanPalette.danger.opacity((1 - progress) * 0.2)))
            context.stroke(blast, with: .color(OceanPalette.gold.opacity(1 - progress)), lineWidth: 3)
            return
        }
        let armed = mine.phase == .armed
        let color = armed ? OceanPalette.danger : OceanPalette.muted
        if armed || engine.sonarRemaining > 0 {
            let radius = OceanMine.blastRadius
            let danger = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            context.fill(danger, with: .color(OceanPalette.danger.opacity(armed ? 0.055 : 0.025)))
            context.stroke(danger, with: .color(OceanPalette.danger.opacity(armed ? 0.6 : 0.25)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
        }
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            var spike = Path()
            spike.move(to: CGPoint(x: p.x + cos(a) * 12, y: p.y + sin(a) * 12))
            spike.addLine(to: CGPoint(x: p.x + cos(a) * 21, y: p.y + sin(a) * 21))
            context.stroke(spike, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        let body = Path(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
        context.fill(body, with: .color(OceanPalette.ink))
        context.stroke(body, with: .color(color), lineWidth: 2)
        context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                     with: .color(OceanPalette.danger.opacity(armed ? 1 : 0.65)))
        if armed {
            var fuse = Path()
            fuse.addArc(center: p, radius: 29, startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * mine.timer / OceanMine.fuse), clockwise: false)
            context.stroke(fuse, with: .color(OceanPalette.danger), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    private func drawSonar(in context: inout GraphicsContext) {
        guard !reduceMotion else { return }
        let p = engine.screenPoint(engine.position)
        let progress = 1 - engine.sonarRemaining / 5
        let radius = CGFloat(progress) * 760
        context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(OceanPalette.teal.opacity((1 - progress) * 0.5)), lineWidth: 1.5)
    }

    private func drawText(_ text: String, at point: CGPoint, color: Color, in context: inout GraphicsContext) {
        context.draw(Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(color), at: point)
    }

    private func drawCoral(at p: CGPoint, height: CGFloat, direction: CGFloat, color: Color, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: p)
        path.addQuadCurve(to: CGPoint(x: p.x + 3, y: p.y + height * direction), control: CGPoint(x: p.x - 4, y: p.y + height * direction * 0.6))
        path.move(to: CGPoint(x: p.x, y: p.y + height * direction * 0.4))
        path.addLine(to: CGPoint(x: p.x - 9, y: p.y + height * direction * 0.73))
        path.addLine(to: CGPoint(x: p.x - 10, y: p.y + height * direction))
        path.move(to: CGPoint(x: p.x + 1, y: p.y + height * direction * 0.65))
        path.addLine(to: CGPoint(x: p.x + 10, y: p.y + height * direction * 0.88))
        context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func drawSubmarine(in context: inout GraphicsContext, size: CGSize) {
        let ready = engine.state == .ready
        let center = ready ? CGPoint(x: size.width / 2, y: size.height * 0.43 + CGFloat(sin(time * 1.7)) * 5) : engine.screenPoint(engine.position)
        let boatScale: CGFloat = ready ? 1.6 : 0.86
        let facing: CGFloat = ready ? 1 : engine.facing
        for index in 0..<7 {
            let phase = (CGFloat(time) * (engine.isThrustActive ? 65 : 34) + CGFloat(index) * 14)
                .truncatingRemainder(dividingBy: 100)
            let radius = (1 + phase / 55) * boatScale
            let x = center.x - (48 + phase * 0.65) * boatScale * facing
            let y = center.y + CGFloat(sin(Double(phase) * 0.06 + Double(index))) * 8 - phase * 0.09
            context.stroke(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                           with: .color(OceanPalette.teal.opacity(Double(1 - phase / 100) * 0.4)), lineWidth: 0.8)
        }
        if !ready && engine.hasShield {
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 38, y: center.y - 36, width: 76, height: 72)),
                           with: .color(OceanPalette.blue.opacity(0.65)), lineWidth: 1.5)
        }
        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .radians(ready ? -0.055 : engine.submarineRotationRadians * Double(facing)))
            layer.scaleBy(x: boatScale * facing, y: boatScale)
            if !ready && engine.invulnerability > 0 { layer.opacity = reduceMotion ? 0.65 : 0.45 + abs(sin(time * 18)) * 0.55 }
            var beam = Path()
            beam.move(to: CGPoint(x: 32, y: -3))
            beam.addLine(to: CGPoint(x: 186, y: -59))
            beam.addQuadCurve(to: CGPoint(x: 186, y: 59), control: CGPoint(x: 207, y: 0))
            beam.addLine(to: CGPoint(x: 32, y: 6))
            beam.closeSubpath()
            layer.fill(beam, with: .linearGradient(Gradient(colors: [OceanPalette.gold.opacity(0.12), .clear]),
                startPoint: CGPoint(x: 32, y: 0), endPoint: CGPoint(x: 180, y: 0)))

            let darkGold = Color(red: 0.63, green: 0.34, blue: 0.12)
            var fin = Path()
            fin.move(to: CGPoint(x: -23, y: -8))
            fin.addLine(to: CGPoint(x: -42, y: -23))
            fin.addLine(to: CGPoint(x: -39, y: 20))
            fin.addLine(to: CGPoint(x: -22, y: 10))
            fin.closeSubpath()
            layer.fill(fin, with: .color(darkGold))
            layer.fill(Path(roundedRect: CGRect(x: -46, y: -3, width: 15, height: 6), cornerRadius: 3), with: .color(OceanPalette.muted))
            let propellerHeight = CGFloat(7 + abs(sin(time * (engine.isThrustActive ? 35 : 19))) * 20)
            layer.fill(Path(roundedRect: CGRect(x: -47, y: -propellerHeight / 2, width: 4, height: propellerHeight), cornerRadius: 2),
                       with: .color(OceanPalette.white.opacity(0.9)))
            let cabin = Path(roundedRect: CGRect(x: -14, y: -27, width: 28, height: 19), cornerRadius: 7)
            layer.fill(cabin, with: .linearGradient(Gradient(colors: [OceanPalette.gold, darkGold]),
                startPoint: CGPoint(x: 0, y: -27), endPoint: CGPoint(x: 0, y: -9)))
            var scope = Path()
            scope.move(to: CGPoint(x: -2, y: -26))
            scope.addLine(to: CGPoint(x: -2, y: -36))
            scope.addQuadCurve(to: CGPoint(x: 2, y: -40), control: CGPoint(x: -2, y: -40))
            scope.addLine(to: CGPoint(x: 9, y: -40))
            layer.stroke(scope, with: .color(OceanPalette.gold), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            layer.fill(Path(roundedRect: CGRect(x: 7, y: -43, width: 5, height: 6), cornerRadius: 1.5), with: .color(OceanPalette.ink))
            let hull = Path(roundedRect: CGRect(x: -34, y: -18, width: 72, height: 37), cornerRadius: 18.5)
            layer.fill(hull, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.88, blue: 0.53), OceanPalette.gold, Color(red: 0.87, green: 0.49, blue: 0.16)]),
                startPoint: CGPoint(x: 0, y: -18), endPoint: CGPoint(x: 0, y: 21)))
            layer.stroke(hull, with: .color(Color(red: 1, green: 0.88, blue: 0.59).opacity(0.65)), lineWidth: 0.8)
            let shine = Path(roundedRect: CGRect(x: -23, y: -14, width: 39, height: 3), cornerRadius: 1.5)
            layer.fill(shine, with: .color(.white.opacity(0.38)))
            for x: CGFloat in [-13, 11] {
                layer.fill(Path(ellipseIn: CGRect(x: x - 9, y: -9, width: 18, height: 18)), with: .color(darkGold))
                layer.fill(Path(ellipseIn: CGRect(x: x - 7.5, y: -7.5, width: 15, height: 15)), with: .color(Color(red: 0.98, green: 0.88, blue: 0.61)))
                let glass = Path(ellipseIn: CGRect(x: x - 5.8, y: -5.8, width: 11.6, height: 11.6))
                layer.fill(glass, with: .linearGradient(Gradient(colors: [Color(red: 0.10, green: 0.32, blue: 0.39), OceanPalette.teal]),
                    startPoint: CGPoint(x: x, y: -6), endPoint: CGPoint(x: x, y: 6)))
                layer.fill(Path(ellipseIn: CGRect(x: x - 3.7, y: -3.7, width: 3.5, height: 2.5)), with: .color(.white.opacity(0.7)))
            }
            for x: CGFloat in [-24, -2, 24] {
                layer.fill(Path(ellipseIn: CGRect(x: x, y: 12, width: 1.5, height: 1.5)), with: .color(darkGold.opacity(0.8)))
            }
            layer.fill(Path(roundedRect: CGRect(x: -9, y: 16, width: 26, height: 5), cornerRadius: 2), with: .color(darkGold))
            layer.fill(Path(roundedRect: CGRect(x: 33, y: -5, width: 6, height: 10), cornerRadius: 3), with: .color(Color(red: 1, green: 0.94, blue: 0.73)))
        }
    }

}
