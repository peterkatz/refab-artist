import Foundation
import CoreGraphics
import ImageIO
import Metal
import RealityKit

#if canImport(AppKit)
import AppKit
#endif

/// MatCap (material-capture / lit-sphere) material for the imported model.
///
/// PBR + scene lighting reads sculptural form poorly — the imported scan looked
/// like flat clay no matter how the lights were tuned. A MatCap samples a pre-lit
/// sphere image by the *view-space* surface normal, so form reads with strong,
/// stable contrast from every angle with no lights, environment, or UVs. This is
/// the technique ZBrush, Blender sculpt mode, and Sketchfab use.
///
/// The shading lives in a precompiled Metal surface shader (`matcap.metallib`,
/// built from `tools/shaders/Matcap.metal`) so the normal SwiftPM build needs no
/// Metal toolchain. The neutral capture (`matcap_studio.png`) is recolored by the
/// material's base-color tint, so one capture serves every object tint.
enum ViewportMatcapMaterial {
    static let shaderFunctionName = "neoMatcapSurface"
    static let metallibName = "matcap"

    enum LoadError: Error, CustomStringConvertible {
        case metalDeviceUnavailable
        case missingMetallib
        case shaderLibraryUnreadable
        case missingCapture(String)
        case unreadableCapture(String)

        var description: String {
            switch self {
            case .metalDeviceUnavailable: return "no Metal device available for the MatCap shader"
            case .missingMetallib: return "matcap.metallib is not bundled in the module resources"
            case .shaderLibraryUnreadable: return "matcap.metallib could not be loaded as an MTLLibrary"
            case .missingCapture(let name): return "\(name).png is not bundled in the module resources"
            case .unreadableCapture(let name): return "\(name).png could not be decoded"
            }
        }
    }

    @MainActor private static var cachedShader: RealityKit.CustomMaterial.SurfaceShader?
    @MainActor private static var cachedCaptures: [String: TextureResource] = [:]

    @MainActor
    private static func surfaceShader() throws -> RealityKit.CustomMaterial.SurfaceShader {
        if let cachedShader { return cachedShader }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LoadError.metalDeviceUnavailable
        }
        guard let url = AppResourceBundle.bundle.url(forResource: metallibName, withExtension: "metallib") else {
            throw LoadError.missingMetallib
        }
        guard let library = try? device.makeLibrary(URL: url) else {
            throw LoadError.shaderLibraryUnreadable
        }
        let shader = RealityKit.CustomMaterial.SurfaceShader(named: shaderFunctionName, in: library)
        cachedShader = shader
        return shader
    }

    @MainActor
    private static func capture(named name: String) async throws -> TextureResource {
        if let cached = cachedCaptures[name] { return cached }
        // Load via CGImage, NOT TextureResource(named:in:) — the bundle-lookup
        // initializer hard-crashes (SIGSEGV in CoreRE) when the resource isn't
        // resolved as a compiled asset, which it isn't under SwiftPM .process.
        guard let url = AppResourceBundle.bundle.url(forResource: name, withExtension: "png") else {
            throw LoadError.missingCapture(name)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LoadError.unreadableCapture(name)
        }
        let resource = try await TextureResource(image: image, withName: name, options: .init(semantic: .color))
        cachedCaptures[name] = resource
        return resource
    }

    /// Build an unlit MatCap material: a neutral per-style capture recoloured by
    /// `color`. The shader keeps the specular highlight white while tinting the
    /// diffuse/shadow tones, so any colour reads with a believable finish.
    @MainActor
    static func make(material: ViewportAppearanceSettings.ObjectMaterial, color: WorkspaceRGBA) async throws -> RealityKit.CustomMaterial {
        let shader = try surfaceShader()
        let capture = try await capture(named: material.captureName)

        var mat = try RealityKit.CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
        let tint = NSColor(
            calibratedRed: min(max(color.red, 0), 1),
            green: min(max(color.green, 0), 1),
            blue: min(max(color.blue, 0), 1),
            alpha: 1
        )
        mat.baseColor = .init(PhysicallyBasedMaterial.BaseColor(tint: tint, texture: .init(capture)))
        mat.faceCulling = .back
        return mat
    }
}
