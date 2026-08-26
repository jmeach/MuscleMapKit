//
//  MuscleBodyGeometry.swift
//  Cinder
//
//  ONE continuous body mesh instead of balloon parts: the figure is a signed
//  distance field (capsule/ellipsoid primitives smooth-blended into a single
//  organic surface), meshed with naive surface nets and shaded with normals
//  from the SDF gradient. Muscle groups are painted onto the surface — every
//  vertex is assigned to the nearest muscle proxy region (with a soft blend
//  band), so intensity tinting recolors regions of the body rather than
//  lighting up separate blobs. Small "relief" bumps from the muscle proxies
//  give definition without balloon seams.
//
//  Build cost ~0.3-1s → computed once per process on a background queue and
//  cached (see MuscleBodyGeometry.shared).
//

import Foundation
import simd

struct BodyMesh {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [Int32] = []
    /// Per-vertex muscle assignment: index into MuscleGroup.allCases, -1 = base body.
    var muscleIds: [Int16] = []
    /// Per-vertex 0…1 blend toward the muscle color (soft region edges).
    var muscleBlend: [Float] = []
}

enum MuscleBodyGeometry {

    // MARK: - Cached build

    private static let lock = NSLock()
    private static var cached: BodyMesh?

    /// Blocking accessor — loads on first call (call off-main).
    /// Prefers the baked MakeHuman body (body.mesh, CC0) and falls back to the
    /// procedural SDF figure if the resource is missing or corrupt.
    static func shared() -> BodyMesh {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let mesh = loadBakedBody() ?? build()
        cached = mesh
        return mesh
    }

    /// Parse the baked binary ('CMB1', u32 vertCount, u32 indexCount, then
    /// pos f32*3, normal f32*3, muscleId i16, blend f32, indices u32).
    private static func loadBakedBody() -> BodyMesh? {
        guard let url = Bundle.module.url(forResource: "body", withExtension: "mesh"),
              let data = try? Data(contentsOf: url),
              data.count > 12, data.prefix(4) == Data("CMB1".utf8) else { return nil }

        var offset = 4
        func read<T>(_ type: T.Type, count: Int) -> [T]? {
            let bytes = count * MemoryLayout<T>.size
            guard offset + bytes <= data.count else { return nil }
            let out = data.subdata(in: offset..<offset + bytes).withUnsafeBytes {
                Array($0.bindMemory(to: T.self))
            }
            offset += bytes
            return out
        }

        guard let counts = read(UInt32.self, count: 2) else { return nil }
        let vertCount = Int(counts[0]), indexCount = Int(counts[1])
        guard vertCount > 0, indexCount > 0,
              let pos = read(Float32.self, count: vertCount * 3),
              let nrm = read(Float32.self, count: vertCount * 3),
              let ids = read(Int16.self, count: vertCount),
              let blend = read(Float32.self, count: vertCount),
              let idx = read(UInt32.self, count: indexCount) else { return nil }

        var mesh = BodyMesh()
        mesh.positions = (0..<vertCount).map {
            SIMD3(pos[$0 * 3], pos[$0 * 3 + 1], pos[$0 * 3 + 2])
        }
        mesh.normals = (0..<vertCount).map {
            SIMD3(nrm[$0 * 3], nrm[$0 * 3 + 1], nrm[$0 * 3 + 2])
        }
        mesh.muscleIds = ids
        mesh.muscleBlend = blend
        mesh.indices = idx.map(Int32.init)
        return mesh
    }

    // MARK: - SDF primitives

    private static func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        guard k > 0 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    private static func sdSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                  _ r0: Float, _ r1: Float) -> Float {
        let pa = p - a, ba = b - a
        let t = simd_clamp(dot(pa, ba) / dot(ba, ba), 0, 1)
        return length(pa - ba * t) - (r0 + (r1 - r0) * t)
    }

    private static func sdEllipsoid(_ p: SIMD3<Float>, _ c: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
        let q = p - c
        let k0 = length(q / r)
        let k1 = length(q / (r * r))
        return k1 > 0 ? k0 * (k0 - 1) / k1 : -min(r.x, min(r.y, r.z))
    }

    // MARK: - The body

    /// Mirrored helper: evaluates f at |x| so the body is symmetric.
    private static func mirrored(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(abs(p.x), p.y, p.z)
    }

    /// The whole figure as one SDF. Tuned for a lean athletic silhouette:
    /// V-taper torso, real neck, no joint seams.
    static func bodySDF(_ point: SIMD3<Float>) -> Float {
        let p = mirrored(point)
        var d: Float = .greatestFiniteMagnitude

        // Head + neck.
        d = sdEllipsoid(p, SIMD3(0, 1.625, 0.005), SIMD3(0.082, 0.102, 0.090))
        d = smin(d, sdSegment(p, SIMD3(0, 1.560, -0.005), SIMD3(0, 1.470, -0.010), 0.043, 0.052), 0.030)

        // Torso: chest volume → waist → pelvis, one smooth chain.
        let chest = sdEllipsoid(p, SIMD3(0, 1.315, -0.005), SIMD3(0.150, 0.150, 0.082))
        let waist = sdEllipsoid(p, SIMD3(0, 1.095, -0.008), SIMD3(0.103, 0.115, 0.070))
        let pelvis = sdEllipsoid(p, SIMD3(0, 0.945, -0.005), SIMD3(0.128, 0.095, 0.078))
        var torso = smin(chest, waist, 0.09)
        torso = smin(torso, pelvis, 0.07)
        d = smin(d, torso, 0.04)

        // Shoulder mass + trap slope (neck→shoulder), merged into the torso.
        d = smin(d, sdEllipsoid(p, SIMD3(0.172, 1.400, -0.008), SIMD3(0.062, 0.058, 0.058)), 0.035)
        d = smin(d, sdSegment(p, SIMD3(0.010, 1.480, -0.020), SIMD3(0.150, 1.415, -0.015), 0.030, 0.040), 0.045)

        // Arm: shoulder → elbow → wrist, tapered, slightly away from torso.
        let shoulder = SIMD3<Float>(0.196, 1.398, 0.000)
        let elbow = SIMD3<Float>(0.225, 1.135, 0.012)
        let wrist = SIMD3<Float>(0.243, 0.905, 0.035)
        d = smin(d, sdSegment(p, shoulder, elbow, 0.049, 0.037), 0.025)
        d = smin(d, sdSegment(p, elbow, wrist, 0.037, 0.026), 0.020)
        // Hand.
        d = smin(d, sdEllipsoid(p, SIMD3(0.250, 0.845, 0.042), SIMD3(0.028, 0.048, 0.036)), 0.018)

        // Leg: hip → knee → ankle, tapered.
        let hip = SIMD3<Float>(0.082, 0.930, -0.005)
        let knee = SIMD3<Float>(0.092, 0.505, 0.000)
        let ankle = SIMD3<Float>(0.094, 0.085, -0.012)
        d = smin(d, sdSegment(p, hip, knee, 0.068, 0.046), 0.050)
        d = smin(d, sdSegment(p, knee, ankle, 0.044, 0.026), 0.030)
        // Foot.
        d = smin(d, sdEllipsoid(p, SIMD3(0.096, 0.035, 0.045), SIMD3(0.040, 0.030, 0.092)), 0.022)

        // Sculpt bulges — gentle relief only (small k, shrunken proxies).
        // Glutes.
        d = smin(d, sdEllipsoid(p, SIMD3(0.066, 0.905, -0.058), SIMD3(0.058, 0.062, 0.045)), 0.030)
        // Chest plates.
        d = smin(d, sdEllipsoid(p, SIMD3(0.072, 1.320, 0.058), SIMD3(0.066, 0.048, 0.030)), 0.028)
        // Calf bellies.
        d = smin(d, sdEllipsoid(p, SIMD3(0.094, 0.335, -0.026), SIMD3(0.034, 0.085, 0.032)), 0.026)
        // Biceps/triceps relief.
        d = smin(d, sdEllipsoid(p, SIMD3(0.219, 1.265, 0.022), SIMD3(0.033, 0.062, 0.030)), 0.022)
        d = smin(d, sdEllipsoid(p, SIMD3(0.224, 1.255, -0.022), SIMD3(0.032, 0.066, 0.030)), 0.022)
        // Lat sweep (upper back width).
        d = smin(d, sdEllipsoid(p, SIMD3(0.105, 1.240, -0.045), SIMD3(0.055, 0.095, 0.028)), 0.035)

        return d
    }

    // MARK: - Muscle regions (painted, not modeled)
    //
    // Region proxies mirror gym vocabulary; a surface vertex belongs to the
    // nearest proxy within `assignRange`, blended out over `blendBand`.

    private struct Region {
        let group: MuscleGroup
        let center: SIMD3<Float>
        let radii: SIMD3<Float>
        var mirrored = true
    }

    private static let regions: [Region] = [
        Region(group: .chest, center: SIMD3(0.080, 1.322, 0.058), radii: SIMD3(0.088, 0.052, 0.045)),

        Region(group: .frontDelts, center: SIMD3(0.180, 1.408, 0.040), radii: SIMD3(0.045, 0.052, 0.040)),
        Region(group: .sideDelts, center: SIMD3(0.212, 1.415, -0.005), radii: SIMD3(0.048, 0.058, 0.045)),
        Region(group: .rearDelts, center: SIMD3(0.180, 1.400, -0.052), radii: SIMD3(0.045, 0.048, 0.038)),

        Region(group: .biceps, center: SIMD3(0.216, 1.262, 0.032), radii: SIMD3(0.042, 0.078, 0.040)),
        Region(group: .triceps, center: SIMD3(0.224, 1.252, -0.032), radii: SIMD3(0.042, 0.082, 0.040)),
        Region(group: .forearms, center: SIMD3(0.238, 1.000, 0.028), radii: SIMD3(0.040, 0.118, 0.040)),

        Region(group: .traps, center: SIMD3(0.075, 1.452, -0.025), radii: SIMD3(0.078, 0.048, 0.045)),
        Region(group: .upperBack, center: SIMD3(0.055, 1.330, -0.075), radii: SIMD3(0.062, 0.085, 0.038)),
        Region(group: .lats, center: SIMD3(0.112, 1.205, -0.048), radii: SIMD3(0.068, 0.110, 0.045)),
        Region(group: .lowerBack, center: SIMD3(0.035, 1.040, -0.068), radii: SIMD3(0.045, 0.090, 0.035)),

        Region(group: .abs, center: SIMD3(0.034, 1.108, 0.072), radii: SIMD3(0.033, 0.102, 0.033)),
        Region(group: .obliques, center: SIMD3(0.098, 1.110, 0.020), radii: SIMD3(0.032, 0.105, 0.055)),

        Region(group: .glutes, center: SIMD3(0.068, 0.905, -0.062), radii: SIMD3(0.062, 0.068, 0.048)),
        Region(group: .quads, center: SIMD3(0.086, 0.700, 0.042), radii: SIMD3(0.062, 0.165, 0.048)),
        Region(group: .hamstrings, center: SIMD3(0.088, 0.690, -0.048), radii: SIMD3(0.058, 0.155, 0.045)),
        Region(group: .calves, center: SIMD3(0.094, 0.330, -0.028), radii: SIMD3(0.045, 0.100, 0.042)),
    ]

    private static let groupIndex: [MuscleGroup: Int16] = {
        var map: [MuscleGroup: Int16] = [:]
        for (i, g) in MuscleGroup.allCases.enumerated() { map[g] = Int16(i) }
        return map
    }()

    /// (muscleId, blend 0…1) for a surface point.
    private static func classify(_ point: SIMD3<Float>) -> (Int16, Float) {
        let p = mirrored(point)
        var bestD: Float = .greatestFiniteMagnitude
        var best: MuscleGroup?
        for region in regions {
            let d = sdEllipsoid(p, region.center, region.radii)
            if d < bestD { bestD = d; best = region.group }
        }
        guard let best else { return (-1, 0) }
        // Fully "in" a region while inside its proxy; fades out over 12mm.
        let blendBand: Float = 0.012
        let blend = 1 - simd_clamp(bestD / blendBand, 0, 1)
        guard blend > 0.001 else { return (-1, 0) }
        return (groupIndex[best] ?? -1, blend)
    }

    // MARK: - Surface nets mesher

    static func build() -> BodyMesh {
        // Bounds with margin.
        let lo = SIMD3<Float>(-0.34, -0.03, -0.20)
        let hi = SIMD3<Float>(0.34, 1.80, 0.20)
        let cell: Float = 0.0105
        let nx = Int(((hi.x - lo.x) / cell).rounded(.up))
        let ny = Int(((hi.y - lo.y) / cell).rounded(.up))
        let nz = Int(((hi.z - lo.z) / cell).rounded(.up))
        let cx = nx + 1, cy = ny + 1, cz = nz + 1

        // Sample the field at grid corners.
        var field = [Float](repeating: 1, count: cx * cy * cz)
        @inline(__always) func fi(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * cy + y) * cx + x }
        @inline(__always) func corner(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
            lo + SIMD3(Float(x), Float(y), Float(z)) * cell
        }
        // Parallel fill by z-slab (unsafe buffer: disjoint writes, no COW races).
        field.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: cz) { z in
                for y in 0..<cy {
                    for x in 0..<cx {
                        buf[fi(x, y, z)] = bodySDF(corner(x, y, z))
                    }
                }
            }
        }

        var mesh = BodyMesh()
        // One vertex per surface-crossing cell.
        var cellVertex = [Int32](repeating: -1, count: nx * ny * nz)
        @inline(__always) func ci(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * ny + y) * nx + x }

        let cornerOffsets: [SIMD3<Int32>] = [
            SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(1,1,0),
            SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(0,1,1), SIMD3(1,1,1),
        ]
        // The 12 cell edges as corner-index pairs.
        let edges: [(Int, Int)] = [
            (0,1),(2,3),(4,5),(6,7),   // x edges
            (0,2),(1,3),(4,6),(5,7),   // y edges
            (0,4),(1,5),(2,6),(3,7),   // z edges
        ]

        for z in 0..<nz {
            for y in 0..<ny {
                for x in 0..<nx {
                    var values = [Float](repeating: 0, count: 8)
                    var inside = 0
                    for (i, o) in cornerOffsets.enumerated() {
                        let v = field[fi(x + Int(o.x), y + Int(o.y), z + Int(o.z))]
                        values[i] = v
                        if v < 0 { inside += 1 }
                    }
                    guard inside > 0 && inside < 8 else { continue }

                    // Average of edge crossings.
                    var sum = SIMD3<Float>(); var count: Float = 0
                    for (a, b) in edges where (values[a] < 0) != (values[b] < 0) {
                        let t = values[a] / (values[a] - values[b])
                        let pa = corner(x + Int(cornerOffsets[a].x), y + Int(cornerOffsets[a].y), z + Int(cornerOffsets[a].z))
                        let pb = corner(x + Int(cornerOffsets[b].x), y + Int(cornerOffsets[b].y), z + Int(cornerOffsets[b].z))
                        sum += pa + (pb - pa) * t; count += 1
                    }
                    let pos = sum / count

                    // Normal from SDF gradient.
                    let e: Float = 0.004
                    let n = normalize(SIMD3(
                        bodySDF(pos + SIMD3(e, 0, 0)) - bodySDF(pos - SIMD3(e, 0, 0)),
                        bodySDF(pos + SIMD3(0, e, 0)) - bodySDF(pos - SIMD3(0, e, 0)),
                        bodySDF(pos + SIMD3(0, 0, e)) - bodySDF(pos - SIMD3(0, 0, e))))

                    let (mid, blend) = classify(pos)
                    cellVertex[ci(x, y, z)] = Int32(mesh.positions.count)
                    mesh.positions.append(pos)
                    mesh.normals.append(n)
                    mesh.muscleIds.append(mid)
                    mesh.muscleBlend.append(blend)
                }
            }
        }

        // Quads across every sign-changing grid edge (interior only).
        @inline(__always) func quad(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, _ flip: Bool) {
            guard a >= 0, b >= 0, c >= 0, d >= 0 else { return }
            if flip {
                mesh.indices.append(contentsOf: [a, d, c, a, c, b])
            } else {
                mesh.indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        for z in 1..<nz {
            for y in 1..<ny {
                for x in 1..<nx {
                    let v000 = field[fi(x, y, z)]
                    // x-directed edge → quad in the yz cell ring.
                    let v100 = field[fi(x + 1, y, z)]
                    if (v000 < 0) != (v100 < 0) {
                        quad(cellVertex[ci(x, y - 1, z - 1)], cellVertex[ci(x, y, z - 1)],
                             cellVertex[ci(x, y, z)], cellVertex[ci(x, y - 1, z)],
                             v100 < 0)
                    }
                    // y-directed edge.
                    let v010 = field[fi(x, y + 1, z)]
                    if (v000 < 0) != (v010 < 0) {
                        quad(cellVertex[ci(x - 1, y, z - 1)], cellVertex[ci(x - 1, y, z)],
                             cellVertex[ci(x, y, z)], cellVertex[ci(x, y, z - 1)],
                             v010 < 0)
                    }
                    // z-directed edge.
                    let v001 = field[fi(x, y, z + 1)]
                    if (v000 < 0) != (v001 < 0) {
                        quad(cellVertex[ci(x - 1, y - 1, z)], cellVertex[ci(x, y - 1, z)],
                             cellVertex[ci(x, y, z)], cellVertex[ci(x - 1, y, z)],
                             v001 < 0)
                    }
                }
            }
        }

        return mesh
    }
}
