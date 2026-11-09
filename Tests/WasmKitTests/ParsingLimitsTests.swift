import Testing
import WAT
import WasmParser

@testable import WasmKit

@Suite
struct ParsingLimitsTests {
    private func wasm(functionLocals: [Int]) throws -> [UInt8] {
        let functions = functionLocals.map { count in
            "(func" + String(repeating: " (local i32)", count: count) + ")"
        }
        return try wat2wasm("(module \(functions.joined(separator: " ")))")
    }

    @Test
    func parsesAtLimits() throws {
        let bytes = try wasm(functionLocals: [3, 2])
        let limits = ParsingLimits(maxFunctionLocals: 3, maxTotalLocals: 5)
        _ = try parseWasm(bytes: bytes, limits: limits)
    }

    @Test
    func rejectsFunctionOverLimit() throws {
        let bytes = try wasm(functionLocals: [4])
        let limits = ParsingLimits(maxFunctionLocals: 3, maxTotalLocals: 100)
        #expect(throws: WasmParserError.self) {
            try parseWasm(bytes: bytes, limits: limits)
        }
    }

    @Test
    func rejectsModuleOverTotalLimit() throws {
        let bytes = try wasm(functionLocals: [3, 3])
        let limits = ParsingLimits(maxFunctionLocals: 3, maxTotalLocals: 5)
        #expect(throws: WasmParserError.self) {
            try parseWasm(bytes: bytes, limits: limits)
        }
    }

    @Test
    func defaultLimitsAreUnchanged() throws {
        let bytes = try wasm(functionLocals: [3, 3])
        _ = try parseWasm(bytes: bytes)
    }
}
