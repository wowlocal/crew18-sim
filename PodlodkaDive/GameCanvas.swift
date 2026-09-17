import SwiftUI

enum OceanPalette {
    static let ink = Color(red: 0.025, green: 0.10, blue: 0.15)
    static let teal = Color(red: 0.38, green: 0.89, blue: 0.80)
    static let gold = Color(red: 1, green: 0.77, blue: 0.33)
    static let muted = Color(red: 0.56, green: 0.72, blue: 0.75)
    static let white = Color.white
    static let danger = Color(red: 1, green: 0.43, blue: 0.35)
    static let blue = Color(red: 0.4, green: 0.72, blue: 1)
    static let portal = Color(red: 0.75, green: 0.43, blue: 1)
}

struct GameCanvas: View {
    @ObservedObject var engine: GameEngine
    let nightExpedition: Bool
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
                    if engine.zone == .bossCave { drawBossCave(in: &world) }
                    else { drawWorld(in: &world) }
                }
                drawLowVisibility(in: &context, size: size)
            }
            drawSubmarine(in: &context, size: size)
            if engine.state == .playing, engine.noticeRemaining <= 0, let leak = engine.journalLeak {
                let age = engine.runElapsed - leak.startedAt
                let boat = engine.screenPoint(engine.position)
                let drift = reduceMotion ? 0 : age * 9
                let width = min(260.0, size.width - 24)
                let x = min(size.width - width / 2 - 12, max(width / 2 + 12, boat.x + leak.side * 24))
                let y = min(size.height - 220, max(210, boat.y + 75 - drift))
                context.drawLayer { bubble in
                    bubble.opacity = reduceMotion ? 1 : min(1, max(0, (3.5 - age) / 0.7))
                    let rect = CGRect(x: x - width / 2, y: y - 26, width: width, height: 52)
                    bubble.fill(Path(roundedRect: rect, cornerRadius: 16), with: .color(OceanPalette.ink.opacity(0.94)))
                    bubble.stroke(Path(roundedRect: rect, cornerRadius: 16), with: .color(OceanPalette.teal.opacity(0.65)), lineWidth: 1)
                    bubble.draw(Text(leak.phrase).font(.system(size: 13, weight: .medium)).foregroundColor(OceanPalette.teal),
                                in: rect.insetBy(dx: 10, dy: 6))
                }
            }
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
        if engine.mission == .currentStation || engine.mission == .silentSignal {
            for landmark in engine.missionLandmarks where visible.insetBy(dx: -100, dy: -100).contains(landmark.position) {
                drawMissionLandmark(landmark, in: &context)
            }
        } else if visible.insetBy(dx: -120, dy: -120).contains(engine.level.wreck) {
            drawWreck(in: &context)
        }
        for pickup in engine.pickups where !pickup.collected && visible.contains(pickup.position) { drawPickup(pickup, in: &context) }
        for mine in engine.mines where visible.contains(mine.position) { drawMine(mine, in: &context) }
        if let portal = engine.portal, visible.insetBy(dx: -60, dy: -60).contains(portal.position) {
            drawPortal(portal, in: &context)
        }
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

    private func drawPortal(_ portal: OceanPortal, in context: inout GraphicsContext) {
        let p = portal.position
        let pulse = reduceMotion ? 0 : CGFloat(sin(time * 2.8)) * 5
        for index in 0..<3 {
            let radius = 25 + CGFloat(index) * 12 + pulse
            context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(OceanPalette.portal.opacity(0.75 - Double(index) * 0.18)),
                           style: StrokeStyle(lineWidth: 3 - CGFloat(index) * 0.6, dash: index == 2 ? [5, 6] : []))
        }
        context.fill(Path(ellipseIn: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)),
                     with: .radialGradient(Gradient(colors: [OceanPalette.white.opacity(0.8), OceanPalette.portal.opacity(0.35), .clear]),
                                          center: p, startRadius: 1, endRadius: 22))
        if engine.portalRevealed || hypot(engine.position.x - p.x, engine.position.y - p.y) < 200 {
            drawText("ПОРТАЛ · ПЕЩЕРА", at: CGPoint(x: p.x, y: p.y + 58), color: OceanPalette.portal, in: &context)
        }
    }

    private func drawBossCave(in context: inout GraphicsContext) {
        let size = GameEngine.caveSize
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.16, green: 0.05, blue: 0.20), OceanPalette.ink, Color(red: 0.04, green: 0.02, blue: 0.09)]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        let wallColor = OceanPalette.portal.opacity(0.18)
        for side in [CGFloat(0), size.width - 52] {
            var wall = Path()
            wall.move(to: CGPoint(x: side == 0 ? 0 : size.width, y: 0))
            for index in 0...10 {
                let y = CGFloat(index) * size.height / 10
                wall.addLine(to: CGPoint(x: side + (side == 0 ? 38 : 14) + CGFloat((index * 17) % 28), y: y))
            }
            wall.addLine(to: CGPoint(x: side == 0 ? 0 : size.width, y: size.height))
            wall.closeSubpath()
            context.fill(wall, with: .color(wallColor))
        }
        drawOctopus(in: &context)
        if let strike = engine.bossStrike {
            let radius: CGFloat = 112
            let rect = CGRect(x: strike.position.x - radius, y: strike.position.y - radius, width: radius * 2, height: radius * 2)
            switch strike.phase {
            case .warning:
                let urgency = 1 - strike.timer / 1.45
                context.fill(Path(ellipseIn: rect), with: .color(OceanPalette.danger.opacity(0.08 + urgency * 0.13)))
                context.stroke(Path(ellipseIn: rect), with: .color(OceanPalette.danger),
                               style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
                drawText("УДАР!", at: CGPoint(x: strike.position.x, y: strike.position.y - radius - 14), color: OceanPalette.danger, in: &context)
            case .impact:
                context.fill(Path(ellipseIn: rect), with: .color(OceanPalette.danger.opacity(0.28)))
                var tentacle = Path()
                tentacle.move(to: CGPoint(x: size.width / 2, y: 165))
                tentacle.addQuadCurve(to: strike.position, control: CGPoint(x: strike.position.x + 110, y: strike.position.y - 170))
                context.stroke(tentacle, with: .color(OceanPalette.portal), style: StrokeStyle(lineWidth: 27, lineCap: .round))
                context.stroke(tentacle, with: .color(OceanPalette.white.opacity(0.24)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
    }

    private func drawOctopus(in context: inout GraphicsContext) {
        let center = CGPoint(x: GameEngine.caveSize.width / 2, y: 135)
        let sway = reduceMotion ? 0 : CGFloat(sin(time * 1.4)) * 9
        context.fill(Path(ellipseIn: CGRect(x: center.x - 78, y: center.y - 66, width: 156, height: 132)),
                     with: .radialGradient(Gradient(colors: [OceanPalette.portal, Color(red: 0.31, green: 0.08, blue: 0.34)]),
                                          center: CGPoint(x: center.x - 20, y: center.y - 18), startRadius: 5, endRadius: 105))
        for index in 0..<6 {
            let start = CGPoint(x: center.x - 60 + CGFloat(index) * 24, y: center.y + 43)
            var tentacle = Path()
            tentacle.move(to: start)
            tentacle.addQuadCurve(to: CGPoint(x: start.x - 45 + CGFloat(index) * 17 + sway, y: 315 + CGFloat(index % 2) * 35),
                                  control: CGPoint(x: start.x + (index.isMultiple(of: 2) ? -50 : 50), y: 235))
            context.stroke(tentacle, with: .color(OceanPalette.portal.opacity(0.8)), style: StrokeStyle(lineWidth: 18, lineCap: .round))
        }
        for x in [center.x - 28, center.x + 28] {
            context.fill(Path(ellipseIn: CGRect(x: x - 11, y: center.y - 17, width: 22, height: 29)), with: .color(OceanPalette.gold))
            context.fill(Path(ellipseIn: CGRect(x: x - 4, y: center.y - 8, width: 8, height: 14)), with: .color(OceanPalette.ink))
        }
        drawText("ГИГАНТСКИЙ СПРУТ", at: CGPoint(x: center.x, y: 78), color: OceanPalette.portal, in: &context)
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
        let readyToDock = engine.returningToBase
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

    private func drawMissionLandmark(_ landmark: MissionLandmark, in context: inout GraphicsContext) {
        let point = landmark.position
        let station = engine.mission == .currentStation
        let rect = CGRect(x: point.x - 38, y: point.y - 25, width: 76, height: 50)
        context.fill(Path(roundedRect: rect, cornerRadius: station ? 8 : 24), with: .color(OceanPalette.ink))
        context.stroke(Path(roundedRect: rect, cornerRadius: station ? 8 : 24), with: .color(OceanPalette.gold), lineWidth: 3)
        if station || landmark.kind == .signal {
            let radius: CGFloat = station ? 68 : MissionRun.scanRadius
            context.stroke(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(OceanPalette.gold.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
        }
        let symbol: String = switch landmark.kind {
        case .station: "antenna.radiowaves.left.and.right"
        case .signal: "questionmark"
        case .drone: "camera.metering.spot"
        case .recovered: "checkmark"
        case .buoy: "lifepreserver"
        case .wreck: "ferry"
        }
        var icon = context.resolve(Image(systemName: symbol))
        icon.shading = .color(.white)
        context.draw(icon, in: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28))
        drawText(landmark.label, at: CGPoint(x: point.x, y: point.y + 46), color: .white, in: &context)
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
        let color: Color = pickup.kind == .crystal ? .cyan : pickup.kind == .shield ? OceanPalette.blue : (pickup.kind == .battery ? OceanPalette.teal : OceanPalette.gold)
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
        case .sample, .crystal:
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
        let labels: [PickupKind: String] = [.crystal: "+10 КРИСТАЛЛОВ", .battery: "+30 ЭНЕРГИИ", .shield: "ЩИТ", .sample: "ОБРАЗЕЦ · 75", .blackBox: "ЧЁРНЫЙ ЯЩИК"]
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

    /// The expedition takes place after the external lighting failed: the
    /// world remains legible only inside the submarine's headlight cone.
    private func drawLowVisibility(in context: inout GraphicsContext, size: CGSize) {
        let center = engine.screenPoint(engine.position)
        let pitch = CGFloat(engine.submarineRotationRadians)
        let direction = CGVector(dx: cos(pitch) * engine.facing, dy: sin(pitch))
        let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
        let range = engine.headlightRange
        let spread = engine.isLightBoostActive ? range * 0.43 : range * 0.36

        func cone(length: CGFloat, width: CGFloat) -> Path {
            let start = CGPoint(x: center.x + direction.dx * 24, y: center.y + direction.dy * 24)
            let near = width * 0.08
            let end = CGPoint(x: start.x + direction.dx * length, y: start.y + direction.dy * length)
            var path = Path()
            path.move(to: CGPoint(x: start.x + perpendicular.dx * near, y: start.y + perpendicular.dy * near))
            path.addQuadCurve(to: CGPoint(x: end.x + perpendicular.dx * width, y: end.y + perpendicular.dy * width),
                              control: CGPoint(x: start.x + direction.dx * length * 0.62 + perpendicular.dx * width * 0.48,
                                               y: start.y + direction.dy * length * 0.62 + perpendicular.dy * width * 0.48))
            path.addLine(to: CGPoint(x: end.x - perpendicular.dx * width, y: end.y - perpendicular.dy * width))
            path.addQuadCurve(to: CGPoint(x: start.x - perpendicular.dx * near, y: start.y - perpendicular.dy * near),
                              control: CGPoint(x: start.x + direction.dx * length * 0.62 - perpendicular.dx * width * 0.48,
                                               y: start.y + direction.dy * length * 0.62 - perpendicular.dy * width * 0.48))
            path.closeSubpath()
            return path
        }

        context.drawLayer { darkness in
            darkness.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.91)))
            darkness.blendMode = .destinationOut
            darkness.fill(cone(length: range * 1.07, width: spread * 1.12), with: .color(.white.opacity(0.30)))
            darkness.fill(cone(length: range, width: spread), with: .linearGradient(
                Gradient(colors: [.white, .white.opacity(0.88), .white.opacity(0.38)]),
                startPoint: center,
                endPoint: CGPoint(x: center.x + direction.dx * range, y: center.y + direction.dy * range)))
            let haloRadius: CGFloat = engine.isLightBoostActive ? 116 : 72
            darkness.fill(Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                                                 width: haloRadius * 2, height: haloRadius * 2)),
                          with: .radialGradient(Gradient(colors: [.white, .white.opacity(0.78), .clear]),
                                                center: center, startRadius: 12, endRadius: haloRadius))
        }

        context.fill(cone(length: range, width: spread), with: .linearGradient(
            Gradient(colors: [OceanPalette.gold.opacity(engine.isLightBoostActive ? 0.12 : 0.07), .clear]),
            startPoint: center,
            endPoint: CGPoint(x: center.x + direction.dx * range, y: center.y + direction.dy * range)))
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
            if !nightExpedition {
            let beamLength: CGFloat = ready ? 186 : engine.headlightRange / boatScale
            let beamSpread: CGFloat = ready ? 59 : beamLength * (engine.isLightBoostActive ? 0.43 : 0.36)
            var beam = Path()
            beam.move(to: CGPoint(x: 32, y: -3))
            beam.addLine(to: CGPoint(x: beamLength, y: -beamSpread))
            beam.addQuadCurve(to: CGPoint(x: beamLength, y: beamSpread),
                              control: CGPoint(x: beamLength * 1.1, y: 0))
            beam.addLine(to: CGPoint(x: 32, y: 6))
            beam.closeSubpath()
            layer.fill(beam, with: .linearGradient(
                Gradient(colors: [OceanPalette.gold.opacity(engine.isLightBoostActive ? 0.22 : 0.12), .clear]),
                startPoint: CGPoint(x: 32, y: 0), endPoint: CGPoint(x: beamLength, y: 0)))
            }

            let style = engine.selectedStyle
            let paint: Color = switch style {
            case .classic: OceanPalette.gold
            case .neon: .purple
            case .flames: .red
            case .chrome: .gray
            }
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
            layer.fill(hull, with: .linearGradient(Gradient(colors: [paint.opacity(0.6), paint, paint.opacity(0.8)]),
                startPoint: CGPoint(x: 0, y: -18), endPoint: CGPoint(x: 0, y: 21)))
            layer.stroke(hull, with: .color(Color(red: 1, green: 0.88, blue: 0.59).opacity(0.65)), lineWidth: 0.8)
            if style == .neon {
                layer.stroke(hull, with: .color(OceanPalette.teal), lineWidth: 3)
                layer.fill(Path(roundedRect: CGRect(x: -25, y: 22, width: 50, height: 4), cornerRadius: 2), with: .color(OceanPalette.teal))
            } else if style == .flames {
                var flames = Path()
                flames.move(to: CGPoint(x: -30, y: 12))
                for x in stride(from: -25, through: 20, by: 15) {
                    flames.addLine(to: CGPoint(x: x + 12, y: -13))
                    flames.addLine(to: CGPoint(x: x + 6, y: 12))
                }
                flames.closeSubpath()
                layer.fill(flames, with: .color(OceanPalette.gold))
            } else if style == .chrome {
                for x: CGFloat in [-24, 14] {
                    let speaker = Path(roundedRect: CGRect(x: x, y: -36, width: 16, height: 19), cornerRadius: 3)
                    layer.fill(speaker, with: .color(OceanPalette.ink))
                    layer.stroke(Path(ellipseIn: CGRect(x: x + 3, y: -32, width: 10, height: 10)), with: .color(.white), lineWidth: 2)
                }
            }
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
