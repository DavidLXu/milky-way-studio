import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

enum ImageExporter {
    static func saveRGBA16(texture: MTLTexture, to url: URL) throws {
        guard texture.pixelFormat == .rgba16Unorm else {
            throw GalaxyError.export("导出纹理格式必须是 RGBA16Unorm")
        }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 8
        let byteCount = bytesPerRow * height
        var bytes = [UInt8](repeating: 0, count: byteCount)

        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                texture.getBytes(base,
                                 bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(0, 0, width, height),
                                 mipmapLevel: 0)
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw GalaxyError.export("无法创建图像数据")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 16,
                                  bitsPerPixel: 64,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw GalaxyError.export("无法构造 16-bit 图像")
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw GalaxyError.export("无法创建 PNG 目标文件")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGsRGBIntent: 0
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw GalaxyError.export("PNG 写入失败")
        }
    }
}
