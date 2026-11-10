import XCTest

@testable import WasmParser

final class ParsingLimitsTests: XCTestCase {
    /// A function body's local declarations as `(count, type)` groups.
    private typealias Locals = [(count: UInt32, type: UInt8)]

    private static let i32: UInt8 = 0x7f

    private func leb(_ value: UInt32) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    /// Builds a module with one `() -> ()` function per element of `functions`.
    private func module(functions: [Locals]) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        // Type section: one `() -> ()` type.
        bytes += [0x01, 0x04, 0x01, 0x60, 0x00, 0x00]
        // Function section.
        let functionSection = leb(UInt32(functions.count)) + [UInt8](repeating: 0x00, count: functions.count)
        bytes += [0x03] + leb(UInt32(functionSection.count)) + functionSection
        // Code section.
        var codeSection = leb(UInt32(functions.count))
        for locals in functions {
            var body = leb(UInt32(locals.count))
            for local in locals {
                body += leb(local.count) + [local.type]
            }
            body.append(0x0b)  // end
            codeSection += leb(UInt32(body.count)) + body
        }
        bytes += [0x0a] + leb(UInt32(codeSection.count)) + codeSection
        return bytes
    }

    private func parseCodes(functions: [Locals], limits: ParsingLimits) throws -> [Code] {
        var parser = Parser(bytes: module(functions: functions), limits: limits)
        var codes: [Code] = []
        while let payload = try parser.parseNext() {
            if case .codeSection(let section) = payload {
                codes = section
            }
        }
        return codes
    }

    private func assertTooManyLocals(
        functions: [Locals], limits: ParsingLimits, messagePrefix: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try parseCodes(functions: functions, limits: limits), file: file, line: line
        ) { error in
            guard let error = error as? WasmParserError else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                error.message.text.hasPrefix(messagePrefix),
                "unexpected message: \(error.message.text)", file: file, line: line
            )
        }
    }

    func testDefaultLimits() {
        XCTAssertEqual(ParsingLimits.default.maxFunctionLocals, 100000)
        XCTAssertEqual(ParsingLimits.default.maxTotalLocals, UInt64.max)
    }

    func testFunctionLimit() throws {
        let limits = ParsingLimits(maxFunctionLocals: 10, maxTotalLocals: 1000)

        // Exactly at the limit, split across groups.
        let codes = try parseCodes(functions: [[(4, Self.i32), (6, Self.i32)]], limits: limits)
        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(codes[0].locals.count, 10)

        assertTooManyLocals(functions: [[(11, Self.i32)]], limits: limits, messagePrefix: "Too many locals:")
        assertTooManyLocals(
            functions: [[(4, Self.i32), (7, Self.i32)]], limits: limits, messagePrefix: "Too many locals:"
        )
    }

    func testTotalLimit() throws {
        let limits = ParsingLimits(maxFunctionLocals: 10, maxTotalLocals: 15)

        // Exactly at the limit.
        let codes = try parseCodes(functions: [[(8, Self.i32)], [(7, Self.i32)]], limits: limits)
        XCTAssertEqual(codes.map(\.locals.count), [8, 7])

        // Each function is within its own limit, but the module as a whole is not.
        assertTooManyLocals(
            functions: [[(8, Self.i32)], [(8, Self.i32)]], limits: limits,
            messagePrefix: "Too many locals in module:"
        )
        assertTooManyLocals(
            functions: [[(5, Self.i32)], [(5, Self.i32)], [(5, Self.i32)], [(1, Self.i32)]], limits: limits,
            messagePrefix: "Too many locals in module:"
        )
    }

    func testHugeDeclarationIsRejectedBeforeAllocation() {
        // A single group declaring 2^32 - 1 locals must fail without expanding the declaration.
        let hostile: [Locals] = [[(UInt32.max, Self.i32)]]
        assertTooManyLocals(functions: hostile, limits: .default, messagePrefix: "Too many locals:")
        assertTooManyLocals(
            functions: hostile, limits: ParsingLimits(maxFunctionLocals: UInt64.max, maxTotalLocals: 1000),
            messagePrefix: "Too many locals in module:"
        )
    }

    func testDefaultLimitsAllowUnboundedTotal() throws {
        let function: Locals = [(UInt32(ParsingLimits.default.maxFunctionLocals), Self.i32)]
        let codes = try parseCodes(functions: [function, function], limits: .default)
        XCTAssertEqual(codes.map(\.locals.count), [100000, 100000])
    }

    func testDuplicateCodeSectionIsRejectedBeforeParsingLocals() throws {
        var bytes = module(functions: [[(1, Self.i32)]])
        // Duplicate code section: one body declaring two locals, above both limits.
        bytes += [0x0a, 0x06, 0x01, 0x04, 0x01, 0x02, Self.i32, 0x0b]
        var parser = Parser(bytes: bytes, limits: ParsingLimits(maxFunctionLocals: 1, maxTotalLocals: 1))
        _ = try parser.parseNext()  // header
        _ = try parser.parseNext()  // type
        _ = try parser.parseNext()  // function
        let payload = try parser.parseNext()  // first code section remains retained
        guard case .codeSection(let codes) = payload else {
            return XCTFail("expected code section")
        }
        XCTAssertThrowsError(try parser.parseNext()) { error in
            guard let error = error as? WasmParserError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(error.message.text, WasmParserError.Message.sectionOutOfOrder.text)
        }
        // Parsing stopped at the duplicate section's header, before its declarations.
        XCTAssertEqual(parser.offset, bytes.count - 6)
        XCTAssertEqual(codes[0].locals.count, 1)
    }

    func testZeroLimitsAllowOnlyUndeclaredLocals() throws {
        let limits = ParsingLimits(maxFunctionLocals: 0, maxTotalLocals: 0)
        let codes = try parseCodes(functions: [[], [(0, Self.i32)]], limits: limits)
        XCTAssertEqual(codes.map(\.locals.count), [0, 0])
        assertTooManyLocals(functions: [[(1, Self.i32)]], limits: limits, messagePrefix: "Too many locals:")
        assertTooManyLocals(
            functions: [[(1, Self.i32)]],
            limits: ParsingLimits(maxFunctionLocals: 1, maxTotalLocals: 0),
            messagePrefix: "Too many locals in module:"
        )
    }

    func testCustomFunctionLimitAboveDefault() throws {
        let count = ParsingLimits.default.maxFunctionLocals + 1
        let functions: [Locals] = [[(UInt32(count), Self.i32)]]
        assertTooManyLocals(functions: functions, limits: .default, messagePrefix: "Too many locals:")
        let codes = try parseCodes(
            functions: functions, limits: ParsingLimits(maxFunctionLocals: count, maxTotalLocals: count)
        )
        XCTAssertEqual(codes[0].locals.count, Int(count))
    }
}
