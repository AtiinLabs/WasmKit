import Testing
import WAT

@testable import WasmKit

@Suite
struct ExecutionTests {

    @Test
    func dropWithRelinkingOptimization() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (func (export "_start") (result i32) (local $x i32)
                        (i32.const 42)
                        (i32.const 0)
                        (i32.eqz)
                        (drop)
                        (local.set $x)
                        (local.get $x)
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let _start = try #require(instance.exports[function: "_start"])
        let results = try _start()
        #expect(results == [.i32(42)])
    }

    @Test
    func updateCurrentMemoryCacheOnGrow() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (memory 0)
                    (func (export "_start") (result i32)
                        (drop (memory.grow (i32.const 1)))
                        (i32.store (i32.const 1) (i32.const 42))
                        (i32.load (i32.const 1))
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let _start = try #require(instance.exports[function: "_start"])
        let results = try _start()
        #expect(results == [.i32(42)])
    }

    /// A host function may re-enter the guest and grow the caller's memory. The interpreter's
    /// cached memory base and bound have to be refreshed when the host call returns, or the next
    /// in-bounds access traps (or, with a moving buffer, reads freed storage).
    @Test
    func aHostCallThatGrowsMemoryDoesNotLeaveTheCachedMemoryStale() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                  (import "env" "cb" (func $cb))
                  (memory (export "mem") 1 100)
                  (func (export "growit") (result i32) (memory.grow (i32.const 8)))
                  (func (export "start") (result i32)
                    (call $cb)
                    ;; In bounds only once the callback has grown the memory.
                    (i32.store (i32.const 100000) (i32.const 0x5A5A5A5A))
                    (i32.load (i32.const 100000))))
                """
            )
        )
        let store = Store(engine: Engine())
        final class Box: @unchecked Sendable { var instance: Instance? }
        let box = Box()
        var imports = Imports()
        imports.define(
            module: "env", name: "cb",
            Function(store: store, type: FunctionType(parameters: [], results: [])) { _, _ in
                _ = try box.instance?.exports[function: "growit"]?()
                return []
            }
        )
        let instance = try module.instantiate(store: store, imports: imports)
        box.instance = instance
        let start = try #require(instance.exports[function: "start"])
        #expect(try start() == [.i32(0x5A5A_5A5A)])
    }

    func expectTrap(_ wat: String, assertTrap: (Trap) throws -> Void) throws {
        let module = try parseWasm(
            bytes: wat2wasm(wat, options: EncodeOptions(nameSection: true))
        )

        let engine = Engine()
        let store = Store(engine: engine)
        var imports = Imports()
        for importEntry in module.imports {
            guard case .function(let type) = importEntry.descriptor else { continue }
            let function = try Function(
                store: store,
                type: module.resolveFunctionType(type),
                body: { _, _ in
                    return []
                }
            )
            imports.define(importEntry, .function(function))
        }
        let instance = try module.instantiate(store: store, imports: imports)
        let _start = try #require(instance.exports[function: "_start"])

        let trap: Trap
        do {
            let _ = try _start()
            #expect((false), "Expected trap")
            return
        } catch let _trap as Trap {
            trap = _trap
        } catch {
            #expect((false), "Expected trap: \(error)")
            return
        }
        try assertTrap(trap)
    }

    @Test
    func backtraceBasic() throws {
        try expectTrap(
            """
            (module
                (func $foo
                    unreachable
                )
                (func $bar
                    (call $foo)
                )
                (func (export "_start")
                    (call $bar)
                )
            )
            """
        ) { trap in
            #expect(
                trap.backtrace?.symbols.compactMap(\.name) == [
                    "foo",
                    "bar",
                    "_start",
                ])
        }
    }

    @Test
    func backtraceWithImports() throws {
        try expectTrap(
            """
            (module
                (func (import "env" "bar"))
                (func
                    unreachable
                )
                (func $bar
                    (call 1)
                )
                (func (export "_start")
                    (call $bar)
                )
            )
            """
        ) { trap in
            #expect(
                trap.backtrace?.symbols.compactMap(\.name) == [
                    "wasm function[1]",
                    "bar",
                    "_start",
                ])
        }
    }
}
