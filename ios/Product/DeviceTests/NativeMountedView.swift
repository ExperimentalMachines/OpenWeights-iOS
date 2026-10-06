import XCTest
import UIKit
import SwiftUI

@MainActor enum NativeMountedView {
    static func capture<Content: View>(_ content: Content, size: CGSize, style: UIUserInterfaceStyle = .dark, exercise: ((UIView) async throws -> Void)? = nil, inspect: ((UIView) -> Void)? = nil) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: content), window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size); window.overrideUserInterfaceStyle = style
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000); host.view.layoutIfNeeded()
        if let exercise { try await exercise(host.view) }
        inspect?(host.view)
        host.view.layoutIfNeeded()
        var drew = false
        let image = UIGraphicsImageRenderer(size: size).image { _ in drew = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(drew, "The mounted native view did not render")
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let visiblePixels = stride(from: 0, to: bytes.count, by: 4).filter { max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) > 96 }.count
        XCTAssertGreaterThan(visiblePixels, 100, "An empty/black mounted capture is not visual evidence")
        return image
    }
}
