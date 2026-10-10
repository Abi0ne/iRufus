// Minimal test harness: the Swift Testing macro plugin shipped with the
// Command Line Tools cannot be loaded without Xcode, so the IrufusCore checks
// run as a plain executable: `swift run IrufusCoreChecks` (exit code 1 on failure).

import Foundation
@testable import IrufusCore

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var currentTest = ""

struct RequireFailed: Error {}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try !condition() { fail("expectation failed \(message())", file: file, line: line) }
    } catch {
        fail("threw \(error)", file: file, line: line)
    }
}

func expectThrows<E: Error>(_ type: E.Type, file: StaticString = #file, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        fail("expected \(E.self) to be thrown", file: file, line: line)
    } catch is E {
    } catch {
        fail("expected \(E.self), got \(error)", file: file, line: line)
    }
}

func expectThrows(code: EngineErrorCode, file: StaticString = #file, line: UInt = #line, _ body: () throws -> Any) {
    do {
        _ = try body()
        fail("expected engine error \(code)", file: file, line: line)
    } catch let e as EngineError where e.code == code {
    } catch {
        fail("expected engine error \(code), got \(error)", file: file, line: line)
    }
}

func require<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else {
        fail("required value was nil", file: file, line: line)
        throw RequireFailed()
    }
    return value
}

func fail(_ message: String, file: StaticString = #file, line: UInt = #line) {
    failures.append("\(currentTest): \(message) (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
}

@MainActor
func run(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let before = failures.count
    do { try body() } catch is RequireFailed {} catch { fail("threw \(error)") }
    print(failures.count == before ? "✔ \(name)" : "✘ \(name)")
}

/// Like run(_:_:) for async checks; the body runs off the main actor while it waits.
@MainActor
func runAsync(_ name: String, _ body: @escaping @Sendable () async throws -> Void) {
    currentTest = name
    let before = failures.count
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { try await body() } catch is RequireFailed {} catch { fail("threw \(error)") }
        done.signal()
    }
    done.wait()
    print(failures.count == before ? "✔ \(name)" : "✘ \(name)")
}
