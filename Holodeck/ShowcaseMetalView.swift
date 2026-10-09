import MetalKit

/// A full-screen shader still needs a focus target to receive Siri Remote presses.
final class ShowcaseMetalView: MTKView {
    var acceptsFocus = true
    override var canBecomeFocused: Bool { acceptsFocus }
}
