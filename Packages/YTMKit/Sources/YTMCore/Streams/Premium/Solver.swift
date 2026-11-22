import Foundation
import JavaScriptCore

/// Each solve gets a throwaway context, so nothing of YouTube's code stays in memory between songs.
/// The limits are checked only between JavaScript steps, so one native call (a huge `repeat` or `fill`)
/// can overshoot them: JavaScriptCore has no heap limit, and iOS gives an app no separate process.
enum Solver {
    struct Solution: Sendable, Equatable {
        let n: String?
        let signature: String?
    }

    static let timeLimit: Duration = .seconds(2)
    /// A solve needs about 2 MB; the cap is on the whole app's footprint,
    /// which other work can grow meanwhile, hence the room.
    static let memoryLimit: UInt64 = 64 << 20
    /// How often, in seconds, the limits are checked while a script runs.
    fileprivate static let checkInterval = 0.05

    /// Solves one at a time, off the cooperative pool, as a solve blocks.
    private static let queue = DispatchQueue(label: "Lily.Solver", qos: .userInitiated)

    static func solve(_ code: String, n: String?, signature: String?) async throws -> Solution {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try solveNow(code, n: n, signature: signature) })
            }
        }
    }

    private static func solveNow(_ code: String, n: String?, signature: String?) throws -> Solution {
        guard let context = JSContext() else { throw failure("JavaScriptCore didn't start") }
        let limits = try Limits()
        return try withExtendedLifetime(limits) {
            limits.arm(JSContextGetGroup(context.jsGlobalContextRef))
            func check() throws {
                if let reason = limits.reason { throw failure(reason) }
                if let exception = context.exception {
                    throw failure(exception.toString() ?? "an error")
                }
            }
            context.evaluateScript("(function (_result) {\n" + code + "\n})(globalThis.__s = {});")
            try check()
            let solvers = context.objectForKeyedSubscript("__s")
            func call(_ name: String, _ input: String) throws -> String {
                let result = solvers?.objectForKeyedSubscript(name)?.call(withArguments: [input])
                try check()
                guard let result, result.isString, let value = result.toString() else {
                    throw failure("the \(name) function gave no answer")
                }
                return value
            }
            return try Solution(n: n.map { try call("n", $0) }, signature: signature.map { try call("sig", $0) })
        }
    }

    private static func failure(_ reason: String) -> YTMError {
        let reason = reason.hasSuffix(".") ? reason : reason + "."
        return YTMError(.unplayable, "The Premium stream couldn't be unlocked: " + reason)
    }
}

/// The watchdog's C API is only in JavaScriptCore's private header, so it is looked up at run time;
/// without it nothing is solved, as a runaway player could never be stopped.
private final class Limits {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    let deadline = ContinuousClock.now + Solver.timeLimit
    let memoryCeiling = Limits.footprint() + Solver.memoryLimit
    private let setLimit: SetLimit
    /// Which limit stopped the script, read once it has returned.
    private(set) var reason: String?

    init() throws {
        // RTLD_DEFAULT, which Swift doesn't import: every loaded image.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else {
            throw YTMError(.unplayable, "The Premium stream couldn't be unlocked: JavaScriptCore can't limit the player.")
        }
        setLimit = unsafeBitCast(symbol, to: SetLimit.self)
    }

    /// The watchdog calls back once per limit set, so each check that lets the script carry on sets the
    /// next. Unretained: `self` outlives every script the context runs, and the callback runs only within one.
    func arm(_ group: JSContextGroupRef?) {
        setLimit(group, Solver.checkInterval, { context, info in
            guard let context, let info else { return true }
            let limits = Unmanaged<Limits>.fromOpaque(info).takeUnretainedValue()
            guard !limits.exceeded() else { return true }
            limits.arm(JSContextGetGroup(JSContextGetGlobalContext(context)))
            return false
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func exceeded() -> Bool {
        if ContinuousClock.now > deadline {
            reason = "the player took too long"
        } else if Self.footprint() > memoryCeiling {
            reason = "the player used too much memory"
        }
        return reason != nil
    }

    /// The app's memory footprint, as the system counts it against its limit.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
