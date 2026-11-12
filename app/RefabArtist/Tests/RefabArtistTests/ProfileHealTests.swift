import XCTest
import Foundation
@testable import RefabArtist

final class ProfileHealTests: XCTestCase {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testProfileSphere() throws {
        guard ProcessInfo.processInfo.environment["PROFILE_HEAL"] != nil else {
            throw XCTSkip("set PROFILE_HEAL=1")
        }
        let model = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl"))
        try profile("sphere", model.geometry)
    }

    func testProfileOpenCube() throws {
        guard ProcessInfo.processInfo.environment["PROFILE_HEAL"] != nil else {
            throw XCTSkip("set PROFILE_HEAL=1")
        }
        let s = 20.0
        let v: [Vec3] = [
            Vec3(x: 0, y: 0, z: 0), Vec3(x: s, y: 0, z: 0),
            Vec3(x: s, y: s, z: 0), Vec3(x: 0, y: s, z: 0),
            Vec3(x: 0, y: 0, z: s), Vec3(x: s, y: 0, z: s),
            Vec3(x: s, y: s, z: s), Vec3(x: 0, y: s, z: s),
        ]
        let q: [(Int,Int,Int,Int)] = [(0,3,2,1),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)]
        var idx: [Int32] = []
        for (a,b,c,d) in q { idx += [Int32(a),Int32(b),Int32(c),Int32(a),Int32(c),Int32(d)] }
        try profile("openCube", MeshGeometryData(vertices: v, triangleIndices: idx))
    }

    /// End-to-end timing of the production heal at FULL resolution (maxCells=nil),
    /// plus the Structures capped path. Reports against the OPTIMIZE targets.
    func testHealTimings() throws {
        guard ProcessInfo.processInfo.environment["PROFILE_HEAL"] != nil else {
            throw XCTSkip("set PROFILE_HEAL=1")
        }
        let sphere = try MeshInspector.inspect(url: Self.repoRoot().appending(path: "tests/fixtures/primitives/sphere_d50mm.stl")).geometry

        let s = 20.0
        let v: [Vec3] = [
            Vec3(x: 0, y: 0, z: 0), Vec3(x: s, y: 0, z: 0),
            Vec3(x: s, y: s, z: 0), Vec3(x: 0, y: s, z: 0),
            Vec3(x: 0, y: 0, z: s), Vec3(x: s, y: 0, z: s),
            Vec3(x: s, y: s, z: s), Vec3(x: 0, y: s, z: s),
        ]
        let q: [(Int,Int,Int,Int)] = [(0,3,2,1),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)]
        var idx: [Int32] = []
        for (a,b,c,d) in q { idx += [Int32(a),Int32(b),Int32(c),Int32(a),Int32(c),Int32(d)] }
        let openCube = MeshGeometryData(vertices: v, triangleIndices: idx)

        let oc = try MeshHealer.heal(openCube)            // full res
        let sp = try MeshHealer.heal(sphere)              // full res
        let spCap = try MeshHealer.heal(sphere, maxCells: 150_000)  // structures path
        print("TIMING openCube(full)=\(oc.elapsed)s edge=\(oc.edgeLength)")
        print("TIMING sphere(full)=\(sp.elapsed)s edge=\(sp.edgeLength)")
        print("TIMING sphere(capped150k)=\(spCap.elapsed)s edge=\(spCap.edgeLength)")
    }

    private func profile(_ name: String, _ mesh: MeshGeometryData) throws {
        let tris = TriangleSoup(mesh)
        let src = tris.bounds
        let dx = src.max.x - src.min.x, dy = src.max.y - src.min.y, dz = src.max.z - src.min.z
        let diag = (dx*dx+dy*dy+dz*dz).squareRoot()
        let edge = min(max(diag/90.0, 0.6), 3.0)  // FULL RES (no cap)
        let pad = edge*3.0
        let bounds = ManifoldEngine.LevelSetBounds(
            lo: Vec3(x: src.min.x-pad, y: src.min.y-pad, z: src.min.z-pad),
            hi: Vec3(x: src.max.x+pad, y: src.max.y+pad, z: src.max.z+pad))

        var t = Date()
        let grid = TriangleGrid(tris, targetCell: max(edge*2.0, diag/64.0))
        let gridBuild = Date().timeIntervalSince(t)
        t = Date()
        let fwn = FastWindingTree(tris)
        let treeBuild = Date().timeIntervalSince(t)

        // grid sample count estimate
        let nx = Int(((bounds.hi.x-bounds.lo.x)/edge).rounded(.up))
        let ny = Int(((bounds.hi.y-bounds.lo.y)/edge).rounded(.up))
        let nz = Int(((bounds.hi.z-bounds.lo.z)/edge).rounded(.up))
        let samples = nx*ny*nz

        // Counters for in-closure work
        let distCount = Counter()
        let windCount = Counter()

        // 1) Full heal via manifold level_set (C bridging + dist + wind)
        t = Date()
        let handle = try ManifoldEngine.levelSet(bounds: bounds, edgeLength: edge, level: 0.0, parallel: true) { x,y,z in
            let p = Vec3(x:x,y:y,z:z)
            let d = grid.nearestDistance(to: p)
            let w = fwn.windingNumber(at: p)
            return w > 0.5 ? d : -d
        }
        let fullHeal = Date().timeIntervalSince(t)
        _ = handle

        // 2) Just C bridging: trivial closure (constant) -> isolates per-sample crossing
        t = Date()
        _ = try? ManifoldEngine.levelSet(bounds: bounds, edgeLength: edge, level: 0.0, parallel: true) { x,y,z in
            return x + y + z - (src.min.x + src.min.y + src.min.z)  // cheap field, still a surface
        }
        let cBridgeOnly = Date().timeIntervalSince(t)

        // 3) Field-only loop in pure Swift over the grid (no C), serial
        t = Date()
        var acc = 0.0
        for k in 0..<samples {
            let iz = k / (nx*ny); let r = k % (nx*ny); let iy = r/nx; let ix = r%nx
            let p = Vec3(x: bounds.lo.x + (Double(ix)+0.5)*edge,
                         y: bounds.lo.y + (Double(iy)+0.5)*edge,
                         z: bounds.lo.z + (Double(iz)+0.5)*edge)
            let d = grid.nearestDistance(to: p)
            let w = fwn.windingNumber(at: p)
            acc += (w > 0.5 ? d : -d)
        }
        let swiftFieldSerial = Date().timeIntervalSince(t)

        // 4) distance only
        t = Date()
        var accD = 0.0
        for k in 0..<samples {
            let iz = k / (nx*ny); let r = k % (nx*ny); let iy = r/nx; let ix = r%nx
            let p = Vec3(x: bounds.lo.x + (Double(ix)+0.5)*edge,
                         y: bounds.lo.y + (Double(iy)+0.5)*edge,
                         z: bounds.lo.z + (Double(iz)+0.5)*edge)
            accD += grid.nearestDistance(to: p)
        }
        let distOnly = Date().timeIntervalSince(t)

        // 5) winding only
        t = Date()
        var accW = 0.0
        for k in 0..<samples {
            let iz = k / (nx*ny); let r = k % (nx*ny); let iy = r/nx; let ix = r%nx
            let p = Vec3(x: bounds.lo.x + (Double(ix)+0.5)*edge,
                         y: bounds.lo.y + (Double(iy)+0.5)*edge,
                         z: bounds.lo.z + (Double(iz)+0.5)*edge)
            accW += fwn.windingNumber(at: p)
        }
        let windOnly = Date().timeIntervalSince(t)

        _ = (acc, accD, accW, distCount, windCount)
        print("PROFILE[\(name)] tris=\(tris.count) edge=\(edge) grid=\(nx)x\(ny)x\(nz)=\(samples) samples")
        print("  gridBuild=\(gridBuild)s treeBuild=\(treeBuild)s")
        print("  fullHeal(C+dist+wind,parallel)=\(fullHeal)s")
        print("  cBridgeOnly(trivial field,parallel)=\(cBridgeOnly)s")
        print("  swiftFieldSerial(dist+wind,NO C)=\(swiftFieldSerial)s")
        print("  distOnly(serial)=\(distOnly)s  windOnly(serial)=\(windOnly)s")
    }

    final class Counter { var n = 0 }
}
