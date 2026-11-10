/// Limits for parsing WebAssembly modules.
///
/// The parser expands every function's declared locals into an array. These limits count declared
/// local elements, excluding function parameters, and bound that expansion. They are not a general
/// parser memory budget: other module contents and array capacity overhead also require memory.
public struct ParsingLimits: Sendable, Equatable {
    /// Maximum number of locals declared by a single function, inclusive.
    public var maxFunctionLocals: UInt64

    /// Maximum number of locals declared by all function bodies of a module combined, inclusive.
    public var maxTotalLocals: UInt64

    public init(maxFunctionLocals: UInt64, maxTotalLocals: UInt64) {
        self.maxFunctionLocals = maxFunctionLocals
        self.maxTotalLocals = maxTotalLocals
    }

    /// The default limits for parsing. The total number of locals is unbounded.
    public static var `default`: ParsingLimits {
        return ParsingLimits(maxFunctionLocals: 100000, maxTotalLocals: UInt64.max)
    }
}
