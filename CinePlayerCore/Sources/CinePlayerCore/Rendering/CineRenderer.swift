import Metal

public enum CineRendererError: Error, CustomStringConvertible {
    case commandQueueCreationFailed
    case shaderLibraryNotFound
    case functionNotFound(String)
    case pipelineCreationFailed(String)

    public var description: String {
        switch self {
        case .commandQueueCreationFailed:
            return "Failed to create a Metal command queue."
        case .shaderLibraryNotFound:
            return "Could not locate default.metallib in the resource bundle."
        case .functionNotFound(let name):
            return "Metal function '\(name)' not found in the shader library."
        case .pipelineCreationFailed(let reason):
            return "Failed to create the tonemap render pipeline state: \(reason)"
        }
    }
}

/// Renders a raw `.r16Uint` sensor texture into an arbitrary color render
/// target, applying the linear black/white tone-mapping fragment shader.
/// Two render-target formats are supported, each with its own
/// `MTLRenderPipelineState` built at `init` time (a pipeline state's
/// declared `colorAttachments[0].pixelFormat` must match the actual
/// render-target texture bound to it, so one pipeline can't serve both):
/// `.bgra8Unorm` (the live view, `FrameExporter`, `cine-diagnostic`) and
/// `.rgba16Unorm` (16-bit TIFF range export — see `RangeExporter`). Both
/// pipelines share the identical `tonemapVertex`/`tonemapFragment` shader
/// functions; the fragment shader's linear `float4` output is quantized by
/// the GPU to whichever bit depth the bound render target declares, so no
/// shader changes were needed to add the second pipeline.
///
/// This is the single code path for the tone-mapping render pass. The live
/// `MTKView` delegate (rendering into `view.currentDrawable`'s texture), the
/// offscreen `cine-diagnostic` CLI, and the app's frame exporters (rendering
/// into private textures) all call through
/// `render(rawTexture:uniforms:into:colorAttachment:)` — there is no second
/// implementation of this render pass.
public final class CineRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    private let pipelineState: MTLRenderPipelineState
    private let pipelineState16Bit: MTLRenderPipelineState
    /// Bound at the fragment shader's LUT texture argument slot (index 1)
    /// whenever `render(...)` isn't given a real `lutTexture` — Metal
    /// requires *something* valid bound to any texture argument a fragment
    /// function declares, even when `tonemapFragment`'s
    /// `uniforms.lutEnabled == 0` branch never actually samples it. See
    /// `LUTTexture.makeIdentityDummy`.
    private let dummyLUTTexture: MTLTexture

    /// - Parameter bundle: Resource bundle to load `CinePlayerShaders.metallib`
    ///   from (deliberately not named "default.metallib" — see the doc
    ///   comment in `Plugins/MetalShaderPlugin/plugin.swift` for why).
    ///   Pass `nil` (the default) to use `Bundle.module`, i.e. this
    ///   package's own generated resource bundle. `Bundle.module` is
    ///   internal, so it can't appear directly in a public default
    ///   parameter value — it's resolved inside the initializer instead.
    public init(device: MTLDevice, bundle: Bundle? = nil) throws {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw CineRendererError.commandQueueCreationFailed
        }
        self.commandQueue = queue

        let resourceBundle = bundle ?? Bundle.module
        guard let metallibURL = resourceBundle.url(forResource: "CinePlayerShaders", withExtension: "metallib") else {
            throw CineRendererError.shaderLibraryNotFound
        }
        let library = try device.makeLibrary(URL: metallibURL)

        guard let vertexFunction = library.makeFunction(name: "tonemapVertex") else {
            throw CineRendererError.functionNotFound("tonemapVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "tonemapFragment") else {
            throw CineRendererError.functionNotFound("tonemapFragment")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw CineRendererError.pipelineCreationFailed(String(describing: error))
        }

        // Second pipeline state, identical to the one above except for the
        // declared render-target pixel format — reuses the exact same
        // vertex/fragment functions (see this class's own doc comment for
        // why no shader changes are needed to add a second output bit
        // depth). Used only by 16-bit TIFF range export today.
        let pipelineDescriptor16Bit = MTLRenderPipelineDescriptor()
        pipelineDescriptor16Bit.vertexFunction = vertexFunction
        pipelineDescriptor16Bit.fragmentFunction = fragmentFunction
        pipelineDescriptor16Bit.colorAttachments[0].pixelFormat = .rgba16Unorm

        do {
            self.pipelineState16Bit = try device.makeRenderPipelineState(descriptor: pipelineDescriptor16Bit)
        } catch {
            throw CineRendererError.pipelineCreationFailed(String(describing: error))
        }

        // Built once and retained for the lifetime of this renderer — see
        // this property's own doc comment for why `render(...)` always needs
        // *something* bound at the LUT texture argument slot.
        self.dummyLUTTexture = try LUTTexture.makeIdentityDummy(device: device)
    }

    /// Encodes the full-screen tone-mapping render pass into `commandBuffer`,
    /// reading `rawTexture` and writing into `colorAttachment`.
    ///
    /// `colorAttachment.pixelFormat` must be either `.bgra8Unorm` or
    /// `.rgba16Unorm` — whichever it is selects the matching pipeline state
    /// built at `init` time. Any other format is a programmer error (passing
    /// a render target this renderer was never given a matching pipeline
    /// for), not a runtime condition callers should recover from, so it
    /// traps via `preconditionFailure` rather than silently no-op'ing or
    /// producing a blank image — this intentionally still traps in Release
    /// builds, unlike `assert`.
    ///
    /// The caller owns the command buffer's lifecycle: for a live view,
    /// commit (and present the drawable) afterwards; for an offscreen
    /// render, commit and wait for completion before reading pixels back.
    ///
    /// - Parameter lutTexture: an optional 3D color-grading LUT texture (see
    ///   `LUTTexture.make(from:device:)`), bound at the fragment shader's LUT
    ///   texture argument slot. Passing `nil` (the default) binds this
    ///   renderer's own dummy identity texture instead and leaves
    ///   `uniforms.lutEnabled` in charge of whether `tonemapFragment` samples
    ///   it at all — every existing call site keeps compiling and rendering
    ///   unchanged. Passing a real LUT texture only has a visible effect
    ///   when `uniforms.lutEnabled != 0` (`ExposureUniforms`'s own default is
    ///   `false`).
    /// - Parameter grading: the "Cine Colour" grading uniforms (see
    ///   `GradingUniforms`), bound to both stages at buffer index 1.
    ///   Defaults to `.identity`, which is a true no-op through every stage
    ///   it touches (see that struct's own doc comment for the by-hand
    ///   proof) — so, like `lutTexture`, every existing call site keeps
    ///   compiling and rendering unchanged without being touched.
    /// - Parameter viewport: the on-screen zoom/pan transform (see
    ///   `ViewportUniforms`), bound only to the vertex stage at buffer index
    ///   2 — `tonemapFragment` never declares that buffer, since it never
    ///   needs it. Defaults to `.identity` (no zoom/pan), a true no-op
    ///   through `tonemapVertex`'s UV remap regardless of `center` (see that
    ///   struct's own doc comment for the by-hand proof), so every existing
    ///   call site keeps rendering unchanged without being touched.
    public func render(
        rawTexture: MTLTexture,
        uniforms: ExposureUniforms,
        into commandBuffer: MTLCommandBuffer,
        colorAttachment: MTLTexture,
        lutTexture: MTLTexture? = nil,
        grading: GradingUniforms = .identity,
        viewport: ViewportUniforms = .identity
    ) {
        let selectedPipeline: MTLRenderPipelineState
        switch colorAttachment.pixelFormat {
        case .bgra8Unorm:
            selectedPipeline = pipelineState
        case .rgba16Unorm:
            selectedPipeline = pipelineState16Bit
        default:
            preconditionFailure(
                "CineRenderer.render: colorAttachment.pixelFormat (\(colorAttachment.pixelFormat)) "
                    + "matches neither pipeline state this renderer was built with (.bgra8Unorm or "
                    + ".rgba16Unorm) — this is a programmer error, not a runtime condition to recover from."
            )
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = colorAttachment
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encoder.setRenderPipelineState(selectedPipeline)
        encoder.setFragmentTexture(rawTexture, index: 0)
        encoder.setFragmentTexture(lutTexture ?? dummyLUTTexture, index: 1)

        var mutableUniforms = uniforms
        withUnsafeBytes(of: &mutableUniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }

        var mutableGrading = grading
        withUnsafeBytes(of: &mutableGrading) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
        }

        var mutableViewport = viewport
        withUnsafeBytes(of: &mutableViewport) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 2)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
