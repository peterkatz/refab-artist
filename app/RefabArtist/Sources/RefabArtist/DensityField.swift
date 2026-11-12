import CoreGraphics
import Foundation

enum SpacingAxis {
    case x
    case y
    case z
}

enum DensityImageProjection: Sendable {
    case xy
    case xz
    case yz
}

struct DensityField {
    private enum Source {
        case uniform(cellSizeMm: Double)
        case linearDensityRamp(axis: SpacingAxis, lo: Double, hi: Double, startDensity: Double, endDensity: Double)
        case image(ImageDensity)
        case attractor(AttractorDensity)
        case nearSurface(NearSurfaceDensity)
    }

    fileprivate struct ImageDensity {
        var width: Int
        var height: Int
        var grayscale: [Double]
        var bounds: Bounds3D
        var projection: DensityImageProjection
        var minCellMm: Double
        var maxCellMm: Double
        var invert: Bool
    }

    fileprivate struct AttractorDensity {
        var point: Vec3
        var falloffMm: Double
        var minCellMm: Double
        var maxCellMm: Double
    }

    fileprivate struct NearSurfaceDensity {
        var vertices: [Vec3]
        var buckets: [SurfaceBucket: [Int]]
        var bucketSize: Double
        var bandMm: Double
        var minCellMm: Double
        var maxCellMm: Double
    }

    fileprivate struct SurfaceBucket: Hashable {
        var x: Int
        var y: Int
        var z: Int
    }

    private let source: Source

    var isUniform: Bool {
        if case .uniform = source { return true }
        return false
    }

    static func uniform(cellSizeMm: Double) -> DensityField {
        DensityField(source: .uniform(cellSizeMm: clampCell(cellSizeMm)))
    }

    static func linearDensityRamp(
        axis: SpacingAxis,
        lo: Double,
        hi: Double,
        startDensity: Double,
        endDensity: Double
    ) -> DensityField {
        DensityField(source: .linearDensityRamp(
            axis: axis,
            lo: lo,
            hi: hi,
            startDensity: max(startDensity, 1.0 / 200.0),
            endDensity: max(endDensity, 1.0 / 200.0)
        ))
    }

    static func image(
        _ cgImage: CGImage,
        bounds: Bounds3D,
        projection: DensityImageProjection,
        minCellMm: Double,
        maxCellMm: Double,
        invert: Bool = false
    ) -> DensityField? {
        guard let grayscale = Self.grayscalePixels(from: cgImage) else { return nil }
        let minCell = clampCell(min(minCellMm, maxCellMm))
        let maxCell = clampCell(max(minCellMm, maxCellMm))
        return DensityField(source: .image(ImageDensity(
            width: cgImage.width,
            height: cgImage.height,
            grayscale: grayscale,
            bounds: bounds,
            projection: projection,
            minCellMm: minCell,
            maxCellMm: maxCell,
            invert: invert
        )))
    }

    static func attractor(
        point: Vec3,
        falloffMm: Double,
        minCellMm: Double,
        maxCellMm: Double
    ) -> DensityField {
        DensityField(source: .attractor(AttractorDensity(
            point: point,
            falloffMm: min(max(falloffMm.isFinite ? falloffMm : 50.0, 5.0), 500.0),
            minCellMm: clampCell(min(minCellMm, maxCellMm)),
            maxCellMm: clampCell(max(minCellMm, maxCellMm))
        )))
    }

    static func nearSurface(
        sourceVertices: [Vec3],
        bandMm: Double,
        minCellMm: Double,
        maxCellMm: Double
    ) -> DensityField {
        let band = min(max(bandMm.isFinite ? bandMm : 10.0, 1.0), 100.0)
        let bucketSize = max(band, 1.0)
        var buckets: [SurfaceBucket: [Int]] = [:]
        buckets.reserveCapacity(sourceVertices.count)

        func bucket(for v: Vec3) -> SurfaceBucket {
            SurfaceBucket(
                x: Int((v.x / bucketSize).rounded(.down)),
                y: Int((v.y / bucketSize).rounded(.down)),
                z: Int((v.z / bucketSize).rounded(.down))
            )
        }

        for (index, vertex) in sourceVertices.enumerated() {
            guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else { continue }
            buckets[bucket(for: vertex), default: []].append(index)
        }

        return DensityField(source: .nearSurface(NearSurfaceDensity(
            vertices: sourceVertices,
            buckets: buckets,
            bucketSize: bucketSize,
            bandMm: band,
            minCellMm: clampCell(min(minCellMm, maxCellMm)),
            maxCellMm: clampCell(max(minCellMm, maxCellMm))
        )))
    }

    func cellSize(at p: SIMD3<Double>) -> Double {
        1.0 / lineDensity(at: p)
    }

    func lineDensity(at p: SIMD3<Double>) -> Double {
        switch source {
        case .uniform(let cellSizeMm):
            return 1.0 / Self.clampCell(cellSizeMm)
        case .linearDensityRamp(let axis, let lo, let hi, let startDensity, let endDensity):
            guard hi > lo else { return max(startDensity, 1.0 / 200.0) }
            let u: Double
            switch axis {
            case .x: u = p.x
            case .y: u = p.y
            case .z: u = p.z
            }
            let t = min(max((u - lo) / (hi - lo), 0), 1)
            return max(startDensity + (endDensity - startDensity) * t, 1.0 / 200.0)
        case .image(let image):
            let t = image.sample(at: p)
            let minDensity = 1.0 / image.minCellMm
            let maxDensity = 1.0 / image.maxCellMm
            return minDensity + (maxDensity - minDensity) * t
        case .attractor(let attractor):
            return attractor.lineDensity(at: p)
        case .nearSurface(let nearSurface):
            return nearSurface.lineDensity(at: p)
        }
    }

    func cellSize(at p: Vec3) -> Double {
        cellSize(at: SIMD3<Double>(p.x, p.y, p.z))
    }

    func lineDensity(at p: Vec3) -> Double {
        lineDensity(at: SIMD3<Double>(p.x, p.y, p.z))
    }

    private static func clampCell(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 1.0, 1.0), 200.0)
    }

    private static func grayscalePixels(from image: CGImage) -> [Double]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var gray = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Double(rgba[i * 4])
            let g = Double(rgba[i * 4 + 1])
            let b = Double(rgba[i * 4 + 2])
            gray[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
        }
        return gray
    }
}

private extension DensityField.AttractorDensity {
    func lineDensity(at p: SIMD3<Double>) -> Double {
        let dx = p.x - point.x
        let dy = p.y - point.y
        let dz = p.z - point.z
        let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
        let t = 1.0 - min(max(distance / falloffMm, 0), 1)
        let farDensity = 1.0 / maxCellMm
        let nearDensity = 1.0 / minCellMm
        return farDensity + (nearDensity - farDensity) * t
    }
}

private extension DensityField.NearSurfaceDensity {
    func lineDensity(at p: SIMD3<Double>) -> Double {
        guard !buckets.isEmpty else { return 1.0 / maxCellMm }
        let distance = minDistance(to: p)
        let t = 1.0 - min(max(distance / bandMm, 0), 1)
        let farDensity = 1.0 / maxCellMm
        let nearDensity = 1.0 / minCellMm
        return farDensity + (nearDensity - farDensity) * t
    }

    func minDistance(to p: SIMD3<Double>) -> Double {
        let center = DensityField.SurfaceBucket(
            x: Int((p.x / bucketSize).rounded(.down)),
            y: Int((p.y / bucketSize).rounded(.down)),
            z: Int((p.z / bucketSize).rounded(.down))
        )
        var bestSq = bandMm * bandMm
        var found = false
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let key = DensityField.SurfaceBucket(
                        x: center.x + dx,
                        y: center.y + dy,
                        z: center.z + dz
                    )
                    guard let indices = buckets[key] else { continue }
                    for index in indices {
                        let v = vertices[index]
                        let sx = p.x - v.x
                        let sy = p.y - v.y
                        let sz = p.z - v.z
                        let d2 = sx * sx + sy * sy + sz * sz
                        if d2 < bestSq {
                            bestSq = d2
                            found = true
                        }
                    }
                }
            }
        }
        return found ? bestSq.squareRoot() : bandMm
    }
}

private extension DensityField.ImageDensity {
    func sample(at p: SIMD3<Double>) -> Double {
        let uv = projectedUV(p)
        let x = min(max(uv.x, 0), 1) * Double(max(width - 1, 0))
        let y = (1.0 - min(max(uv.y, 0), 1)) * Double(max(height - 1, 0))
        let x0 = min(max(Int(x.rounded(.down)), 0), width - 1)
        let y0 = min(max(Int(y.rounded(.down)), 0), height - 1)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = x - Double(x0)
        let ty = y - Double(y0)
        func pixel(_ ix: Int, _ iy: Int) -> Double { grayscale[iy * width + ix] }
        let a = pixel(x0, y0) * (1 - tx) + pixel(x1, y0) * tx
        let b = pixel(x0, y1) * (1 - tx) + pixel(x1, y1) * tx
        let sampled = a * (1 - ty) + b * ty
        return invert ? 1.0 - sampled : sampled
    }

    func projectedUV(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let min = bounds.min
        let max = bounds.max
        func unit(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
            guard hi > lo else { return 0.5 }
            return (value - lo) / (hi - lo)
        }
        switch projection {
        case .xy:
            return SIMD2<Double>(unit(p.x, min.x, max.x), unit(p.y, min.y, max.y))
        case .xz:
            return SIMD2<Double>(unit(p.x, min.x, max.x), unit(p.z, min.z, max.z))
        case .yz:
            return SIMD2<Double>(unit(p.y, min.y, max.y), unit(p.z, min.z, max.z))
        }
    }
}

enum VariableSpacing {
    static func linePositions(
        field: DensityField,
        axis: SpacingAxis,
        lo: Double,
        hi: Double,
        sampleAt: (Double) -> SIMD3<Double>
    ) -> [Double] {
        _ = axis
        guard hi > lo else { return [] }
        let sampleCount = 2048
        let step = (hi - lo) / Double(sampleCount)
        var cumulative = [Double](repeating: 0, count: sampleCount + 1)
        var previous = field.lineDensity(at: sampleAt(lo))
        for i in 1...sampleCount {
            let u = lo + Double(i) * step
            let current = field.lineDensity(at: sampleAt(u))
            cumulative[i] = cumulative[i - 1] + (previous + current) * 0.5 * step
            previous = current
        }
        let total = cumulative[sampleCount]
        let lineCount = Int((total + 1.0e-9).rounded(.down))
        guard lineCount > 0 else { return [] }

        var positions: [Double] = []
        positions.reserveCapacity(lineCount)
        for n in 1...lineCount {
            let target = Double(n)
            guard target <= total + 1.0e-9 else { continue }
            var low = 0
            var high = sampleCount
            while low < high {
                let mid = (low + high) / 2
                if cumulative[mid] < target {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            let i = max(low, 1)
            let c0 = cumulative[i - 1]
            let c1 = cumulative[i]
            let t = c1 > c0 ? (target - c0) / (c1 - c0) : 0
            positions.append(lo + (Double(i - 1) + t) * step)
        }
        return positions
    }
}
