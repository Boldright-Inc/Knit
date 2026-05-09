import Foundation
import Metal

/// Lazy singleton wrapping the default Metal device, command queue, and
/// the bundle's compute library. All GPU work in KnitCore goes through here.
public final class MetalContext: @unchecked Sendable {

    public static let shared = MetalContext()

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary

    public init?() {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        guard let q = dev.makeCommandQueue() else { return nil }
        // SPM doesn't compile .metal sources — we ship them as resources and
        // compile at first use via makeLibrary(source:). On Apple Silicon the
        // compile takes a few ms and is cached by the driver thereafter.
        guard let lib = MetalContext.loadRuntimeLibrary(device: dev) else {
            return nil
        }
        self.device = dev
        self.queue = q
        self.library = lib
    }

    /// Reads every `.metal` resource from the bundle, concatenates the sources,
    /// and compiles a single `MTLLibrary` from them.
    private static func loadRuntimeLibrary(device: MTLDevice) -> MTLLibrary? {
        let bundle = Bundle.module
        guard let urls = bundle.urls(forResourcesWithExtension: "metal", subdirectory: nil),
              !urls.isEmpty else {
            return nil
        }
        var combined = ""
        for url in urls.sorted(by: { $0.path < $1.path }) {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                combined.append(s)
                combined.append("\n")
            }
        }
        if combined.isEmpty { return nil }
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        return try? device.makeLibrary(source: combined, options: opts)
    }

    public var name: String {
        "metal:\(device.name)"
    }

    public func makePipeline(_ functionName: String) throws -> MTLComputePipelineState {
        guard let fn = library.makeFunction(name: functionName) else {
            throw KnitError.unsupported("Metal function \(functionName) not found in bundle")
        }
        return try device.makeComputePipelineState(function: fn)
    }
}
