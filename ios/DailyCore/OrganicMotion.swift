import Foundation

/// Bounded fractal connections. Stored CH1–CH6 followed by CH7 (variant), CH0 (size);
/// ornaments never create graph relationships or change node positions.
public enum OrganicMotion {
    public static let defaults: [Double] = [674, 351, 380, 620, 384, 690, 694, 512]
    public struct Segment: Equatable, Sendable { public let a, b: CGPoint; public let width: Double; public let depth: Int }
    public struct Branch: Sendable { public let stem: [CGPoint]; public let segments: [Segment] }
    public static func normalized(_ values: [Double]) -> [Double] {
        defaults.enumerated().map { i, fallback in
            guard values.indices.contains(i), values[i].isFinite else { return fallback }
            return min(1023, max(0, values[i])).rounded()
        }
    }
    private static func random(_ seed: UInt32) -> Double {
        var value = (seed ^ 0x9e3779b9) &* 0x85ebca6b
        value = (value ^ (value >> 13)) &* 0xc2b2ae35
        return Double(value ^ (value >> 16)) / 4294967295
    }
    private static func noise(_ seed: UInt32, _ time: Double) -> Double {
        let cell = floor(time), t = time - cell, smooth = t*t*t*(t*(t*6-15)+10)
        let index = UInt32(truncatingIfNeeded: Int64(cell))
        return (random(seed &+ index) * (1-smooth) + random(seed &+ index &+ 1) * smooth) * 2-1
    }
    public static func branch(from a: CGPoint, to b: CGPoint, key: String, channels: [Double], time: Double, budget: Int = 1200) -> Branch {
        let c = normalized(channels).map { $0 / 1023 }
        let seed = (key + ":" + String(Int(floor(c[6]*10)))).utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        let dx = Double(b.x-a.x), dy = Double(b.y-a.y), length = hypot(dx, dy)
        guard length.isFinite, length >= 1 else { return Branch(stem: [a,b], segments: []) }
        let clock = time.isFinite ? min(1e9, max(-1e9,time)) : 0
        let phase = c[4]*4, bend = (noise(seed,clock*0.12+phase)*0.55+0.2)*min(70,length*0.2)
        func point(_ t: Double) -> CGPoint {
            CGPoint(x: Double(a.x)+dx*t-dy/length*sin(t*Double.pi)*bend,
                    y: Double(a.y)+dy*t+dx/length*sin(t*Double.pi)*bend)
        }
        var stem = (0...24).map { point(Double($0)/24) }; stem[0] = a; stem[24] = b
        var segments: [Segment] = []
        let branches = 1+Int(floor(c[5]*5)), cap = min(1200,max(0,budget))
        let spread = 0.22+c[3]*1.05+noise(seed &+ 18,clock*0.055)*0.12
        let distribution = 0.45+c[2]*1.9, disorder = c[1]*0.8, reach = min(100,length*0.32)*(0.5+pow(c[7],0.35)*0.6)
        func grow(_ root: CGPoint, _ angle: Double, _ size: Double, _ depth: Int, _ s: UInt32) {
            guard depth > 0, size >= 0.8, segments.count < cap else { return }
            let wind = noise(s,clock*0.23+phase)*(0.12+Double(depth)*0.025)+noise(seed &+ 6,clock*0.09)*0.14
            let direction = angle+wind
            let end = CGPoint(x:Double(root.x)+cos(direction)*size,y:Double(root.y)+sin(direction)*size)
            segments.append(Segment(a:root,b:end,width:(0.16+c[0]*0.75)*(0.35+Double(depth)*0.46),depth:depth))
            guard depth > 1 else { return }
            for i in 0..<branches {
                let side = i % 2 == 0 ? 1.0 : -1.0, child = s &+ UInt32((i+1)*7919+depth*101)
                let t = 0.16+0.84*pow(Double(i+1)/Double(branches+1),distribution)
                let rootNext = CGPoint(x:Double(root.x)+Double(end.x-root.x)*t,y:Double(root.y)+Double(end.y-root.y)*t)
                let fan = side*spread+(random(child)-0.5)*disorder
                let scale = 0.36+random(child &+ 77)*0.16+noise(child &+ 23,clock*0.15+phase)*0.04
                grow(rootNext,direction+fan,size*scale,depth-1,child)
            }
        }
        for i in 0..<6 {
            let t = 0.1+0.8*pow(Double(i+1)/7,distribution), side = i % 2 == 0 ? 1.0 : -1.0
            let root = point(t), ahead = point(min(1,t+0.01))
            grow(root,atan2(Double(ahead.y-root.y),Double(ahead.x-root.x))+side*spread,
                 reach*(0.65+random(seed &+ UInt32(i))*0.35),4,seed &+ UInt32(i*1013))
        }
        return Branch(stem:stem,segments:segments)
    }
}
