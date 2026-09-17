import SwiftUI

struct OceanLevel: Codable {
  let size: CGSize
  let spawn: CGPoint
  let base: CGPoint
  let wreck: CGPoint
  var rocks: [OceanRock] = []
  var pickups: [OceanPickup] = []
  var mines: [OceanMine] = []
  var currents: [OceanCurrent] = []
  var portalCandidates: [CGPoint] = []

  static var expedition: OceanLevel {
    func rock(_ id: Int, _ points: [(CGFloat, CGFloat)]) -> OceanRock {
      OceanRock(id: id, vertices: points.map { CGPoint(x: $0.0, y: $0.1) })
    }
    func pickup(_ id: Int, _ kind: PickupKind, _ x: CGFloat, _ y: CGFloat) -> OceanPickup {
      OceanPickup(id: id, kind: kind, position: CGPoint(x: x, y: y))
    }
    return OceanLevel(
      size: CGSize(width: 1560, height: 2600), spawn: CGPoint(x: 245, y: 290),
      base: CGPoint(x: 190, y: 230), wreck: CGPoint(x: 1370, y: 2330),
      rocks: [
        rock(
          0, [(345, 480), (510, 445), (630, 535), (665, 730), (560, 920), (345, 875), (290, 690)]),
        rock(1, [(1080, 425), (1430, 480), (1480, 700), (1390, 960), (1060, 905), (985, 650)]),
        rock(
          2,
          [
            (700, 1140), (965, 1120), (1070, 1310), (1000, 1550), (770, 1620), (595, 1450),
            (610, 1260),
          ]),
        rock(3, [(110, 1460), (245, 1410), (350, 1570), (320, 1880), (170, 1990), (75, 1810)]),
        rock(
          4, [(1010, 1860), (1160, 1820), (1260, 1970), (1200, 2130), (995, 2160), (895, 2030)]),
        rock(5, [(580, 2230), (720, 2200), (805, 2350), (725, 2520), (515, 2530), (470, 2380)]),
      ],
      pickups: [
        pickup(0, .blackBox, 1370, 2330),
        pickup(1, .battery, 185, 1070), pickup(2, .battery, 440, 1780),
        pickup(3, .battery, 1480, 2470), pickup(4, .battery, 1450, 1240),
        pickup(5, .shield, 790, 470), pickup(6, .shield, 860, 2260),
        pickup(7, .sample, 390, 320), pickup(8, .sample, 740, 830),
        pickup(9, .sample, 1220, 1080), pickup(10, .sample, 465, 1370),
        pickup(11, .sample, 820, 1770), pickup(12, .sample, 1350, 1660),
        pickup(13, .sample, 190, 2250), pickup(14, .sample, 900, 2450),
        pickup(15, .crystal, 320, 320), pickup(16, .crystal, 740, 900),
        pickup(17, .crystal, 440, 1700), pickup(18, .crystal, 1350, 1740),
      ],
      mines: [
        OceanMine(id: 0, position: CGPoint(x: 820, y: 700)),
        OceanMine(id: 1, position: CGPoint(x: 875, y: 1030)),
        OceanMine(id: 2, position: CGPoint(x: 1190, y: 1390)),
        OceanMine(id: 3, position: CGPoint(x: 1370, y: 1950)),
        OceanMine(id: 4, position: CGPoint(x: 440, y: 2190)),
        OceanMine(id: 5, position: CGPoint(x: 1060, y: 2420)),
      ],
      currents: [
        OceanCurrent(
          id: 0, bounds: CGRect(x: 725, y: 540, width: 205, height: 490),
          velocity: CGVector(dx: 0, dy: 48)),
        OceanCurrent(
          id: 1, bounds: CGRect(x: 520, y: 1645, width: 780, height: 155),
          velocity: CGVector(dx: 58, dy: 0)),
        OceanCurrent(
          id: 2, bounds: CGRect(x: 1290, y: 1460, width: 230, height: 750),
          velocity: CGVector(dx: 0, dy: -38)),
      ],
      portalCandidates: [
        CGPoint(x: 850, y: 320), CGPoint(x: 410, y: 1120),
        CGPoint(x: 1330, y: 1740), CGPoint(x: 870, y: 2110),
      ])
  }
}

extension OceanLevel {
  private static func reef(_ id: Int, _ vertices: [(CGFloat, CGFloat)]) -> OceanRock {
    OceanRock(id: id, vertices: vertices.map { CGPoint(x: $0.0, y: $0.1) })
  }
  private static func finds(_ groups: [(PickupKind, [(CGFloat, CGFloat)])]) -> [OceanPickup] {
    groups.flatMap { kind, positions in positions.map { (kind, $0) } }.enumerated().map {
      OceanPickup(
        id: $0.offset, kind: $0.element.0,
        position: CGPoint(x: $0.element.1.0, y: $0.element.1.1))
    }
  }
  static var currentStation: OceanLevel {
    OceanLevel(
      size: CGSize(width: 1560, height: 2200),
      spawn: CGPoint(x: 255, y: 290), base: CGPoint(x: 200, y: 230),
      wreck: CGPoint(x: 1360, y: 1910),
      rocks: [
        reef(
          0,
          [
            (630, 610), (950, 610), (990, 760), (990, 1480), (920, 1570), (630, 1550), (590, 1410),
            (590, 760),
          ]),
        reef(1, [(1370, 630), (1510, 630), (1510, 830), (1370, 830)]),
        reef(2, [(60, 1090), (175, 1090), (175, 1320), (60, 1320)]),
      ],
      pickups: finds([
        (.battery, [(1340, 1720), (375, 1540), (360, 650)]), (.shield, [(1050, 365)]),
        (
          .sample, [(1030, 405), (1450, 1000), (1360, 1560), (1190, 1950), (505, 1050), (320, 700)]
        ),
        (.crystal, [(1140, 480), (1430, 930), (500, 1800), (355, 1000)]),
      ]),
      mines: [
        OceanMine(id: 0, position: CGPoint(x: 1430, y: 1120)),
        OceanMine(id: 1, position: CGPoint(x: 525, y: 1200)),
        OceanMine(id: 2, position: CGPoint(x: 850, y: 1930)),
      ],
      currents: [
        OceanCurrent(
          id: 0, bounds: CGRect(x: 1090, y: 520, width: 230, height: 1080),
          velocity: CGVector(dx: 0, dy: 55)),
        OceanCurrent(
          id: 1, bounds: CGRect(x: 235, y: 740, width: 240, height: 970),
          velocity: CGVector(dx: 0, dy: -50)),
        OceanCurrent(
          id: 2, bounds: CGRect(x: 450, y: 1740, width: 650, height: 170),
          velocity: CGVector(dx: -40, dy: 0)),
      ],
      portalCandidates: [
        CGPoint(x: 780, y: 340), CGPoint(x: 470, y: 480), CGPoint(x: 1400, y: 1490),
      ])
  }
  static var silentSignal: OceanLevel {
    OceanLevel(
      size: CGSize(width: 1560, height: 2300),
      spawn: CGPoint(x: 780, y: 315), base: CGPoint(x: 780, y: 230),
      wreck: CGPoint(x: 780, y: 1150),
      rocks: [
        reef(0, [(540, 570), (920, 550), (990, 630), (970, 760), (600, 790), (530, 700)]),
        reef(1, [(440, 1260), (590, 1240), (640, 1370), (625, 1590), (500, 1640), (420, 1500)]),
        reef(
          2, [(960, 1330), (1140, 1280), (1220, 1410), (1200, 1690), (1020, 1720), (940, 1570)]),
      ],
      pickups: finds([
        (.battery, [(330, 1080), (1330, 1480), (780, 1780)]), (.shield, [(380, 460)]),
        (.sample, [(300, 700), (530, 1030), (1180, 1060), (1380, 1580), (680, 1810), (820, 2040)]),
        (.crystal, [(300, 1020), (1220, 940), (1380, 1820), (760, 1740)]),
      ]),
      mines: [
        OceanMine(id: 0, position: CGPoint(x: 180, y: 1410)),
        OceanMine(id: 1, position: CGPoint(x: 940, y: 990)),
        OceanMine(id: 2, position: CGPoint(x: 1370, y: 580)),
      ],
      currents: [
        OceanCurrent(
          id: 0, bounds: CGRect(x: 1130, y: 1660, width: 300, height: 180),
          velocity: CGVector(dx: 35, dy: 0))
      ],
      portalCandidates: [
        CGPoint(x: 550, y: 1030), CGPoint(x: 1100, y: 360), CGPoint(x: 1050, y: 2100),
      ])
  }
}
