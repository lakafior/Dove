import Foundation
import JavaScriptCore

/// A plugin failed: its own error message, a host outside its list, a timeout, a bad answer.
public struct PluginError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Runs one plugin call in a new JavaScriptCore context (`docs/plugins.md`): evaluates the script, calls
/// `plugin.<function>(argument, ctx)` (or reads `plugin.manifest`), waits for a returned promise, and answers
/// the result as JSON text. The only bridge is `dove.fetch` (HTTPS to the hosts the policy allows, 10 MB),
/// `dove.sleep` (≤ 5 s) and `dove.log`.
///
/// JavaScriptCore is not thread-safe: everything touching the context runs on the sandbox's serial queue, and
/// network work hops back to it to settle promises.
final class PluginSandbox: @unchecked Sendable {
    static let maxResponseBytes = 10 * 1024 * 1024
    static let maxSleep: Double = 5000

    private let queue = DispatchQueue(label: "net.smigi.dove.plugin")
    private let policy: PluginHostPolicy
    private let transport: any HTTPTransport
    private var context: JSContext?
    private var continuation: CheckedContinuation<String, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var exception: String?

    private init(policy: PluginHostPolicy, transport: any HTTPTransport) {
        self.policy = policy
        self.transport = transport
    }

    /// - Parameters:
    ///   - function: the plugin function to call; nil returns `plugin.manifest`.
    ///   - argument, ctx: JSON-compatible values (dictionaries, arrays, strings, numbers, booleans).
    static func run(
        script: String,
        function: String?,
        argument: [String: Any] = [:],
        ctx: [String: Any] = [:],
        policy: PluginHostPolicy,
        transport: any HTTPTransport,
        timeout: Duration = .seconds(30)
    ) async throws -> String {
        let sandbox = PluginSandbox(policy: policy, transport: transport)
        let input = SendableBox((argument, ctx))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sandbox.queue.async {
                    sandbox.continuation = continuation
                    sandbox.start(script: script, function: function, argument: input.value.0, ctx: input.value.1)
                }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    sandbox.queue.async { sandbox.finish(.failure(PluginError("The plugin took longer than \(timeout).")))}
                }
                sandbox.queue.async { sandbox.tasks.append(timer) }
            }
        } onCancel: {
            sandbox.queue.async { sandbox.finish(.failure(CancellationError())) }
        }
    }

    // MARK: - On the queue

    private func start(script: String, function: String?, argument: [String: Any], ctx: [String: Any]) {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            return finish(.failure(PluginError("JavaScript is not available.")))
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, value in
            self?.exception = value.map(Self.describe) ?? "JavaScript error"
        }
        installHostAPI(in: context)
        context.evaluateScript(Self.prelude)
        context.evaluateScript(script)
        if let exception { return finish(.failure(PluginError("The plugin's script failed: \(exception)"))) }

        guard let plugin = context.objectForKeyedSubscript("plugin"), plugin.isObject else {
            return finish(.failure(PluginError("The script defines no `plugin`.")))
        }
        let settle: @convention(block) (String) -> Void = { [weak self] json in self?.finish(.success(json)) }
        let fail: @convention(block) (String) -> Void = { [weak self] message in self?.finish(.failure(PluginError(message))) }
        let awaitValue = context.objectForKeyedSubscript("__settle")

        guard let function else {
            awaitValue?.call(withArguments: [plugin.objectForKeyedSubscript("manifest") as Any, settle, fail])
            return
        }
        guard let method = plugin.objectForKeyedSubscript(function), !method.isUndefined else {
            return finish(.failure(PluginError("The plugin cannot \(function).")))
        }
        let result = plugin.invokeMethod(function, withArguments: [
            JSValue(object: argument, in: context) as Any, JSValue(object: ctx, in: context) as Any,
        ])
        if let exception { return finish(.failure(PluginError(exception))) }
        awaitValue?.call(withArguments: [result as Any, settle, fail])
    }

    private func installHostAPI(in context: JSContext) {
        let dove = JSValue(newObjectIn: context)
        let log: @convention(block) () -> Void = {
            let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            HTTPLog.logger.debug("plugin: \(parts.joined(separator: " "), privacy: .private)")
        }
        let sleep: @convention(block) (Double) -> JSValue? = { [weak self] milliseconds in
            self?.promise { resolve, _ in
                let wait = min(max(milliseconds, 0), Self.maxSleep)
                return Task {
                    try? await Task.sleep(for: .milliseconds(wait))
                    resolve(nil)
                }
            }
        }
        let fetch: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] address, options in
            guard let self else { return nil }
            let request = Self.request(address, options: options)
            return self.promise { [policy, transport] resolve, reject in
                guard let request, let url = request.url, policy.allows(url) else {
                    reject("dove.fetch: \(URL(string: address)?.host() ?? address) is not among the plugin's hosts.")
                    return nil
                }
                return Task {
                    do {
                        let (data, response) = try await transport.send(request)
                        if let final = response.url, !policy.allows(final) {
                            return reject("dove.fetch: redirected to \(final.host() ?? "another host"), which is not among the plugin's hosts.")
                        }
                        guard data.count <= Self.maxResponseBytes else {
                            return reject("dove.fetch: the answer is larger than 10 MB.")
                        }
                        var headers: [String: String] = [:]
                        for (key, value) in response.allHeaderFields {
                            headers[String(describing: key).lowercased()] = String(describing: value)
                        }
                        resolve([
                            "status": response.statusCode,
                            "url": (response.url ?? url).absoluteString,
                            "headers": headers,
                            "body": String(decoding: data, as: UTF8.self),
                        ])
                    } catch {
                        reject("dove.fetch: \(error.localizedDescription)")
                    }
                }
            }
        }
        dove?.setObject(log, forKeyedSubscript: "log" as NSString)
        dove?.setObject(sleep, forKeyedSubscript: "sleep" as NSString)
        dove?.setObject(fetch, forKeyedSubscript: "__fetch" as NSString)
        context.setObject(dove, forKeyedSubscript: "dove" as NSString)
    }

    /// A JS promise settled from Swift: `work` gets resolve/reject callables (safe to call from any thread: they
    /// hop to the queue) and returns the task doing the work, kept so a finished call cancels it.
    private func promise(
        _ work: @escaping (_ resolve: @escaping @Sendable (Any?) -> Void, _ reject: @escaping @Sendable (String) -> Void) -> Task<Void, Never>?
    ) -> JSValue? {
        guard let context else { return nil }
        var task: Task<Void, Never>?
        let queue = self.queue
        let promise = JSValue(newPromiseIn: context) { [weak self] resolveFunction, rejectFunction in
            guard self != nil, let resolveFunction, let rejectFunction else { return }
            let resolveBox = SendableBox(resolveFunction)
            let rejectBox = SendableBox(rejectFunction)
            task = work(
                { [weak self] value in
                    let payload = SendableBox(value)
                    queue.async { [weak self] in
                        guard self?.continuation != nil else { return }
                        resolveBox.value.call(withArguments: payload.value.map { [$0] } ?? [])
                    }
                },
                { [weak self] message in
                    queue.async { [weak self] in
                        guard let self, self.continuation != nil, let context = self.context else { return }
                        let error = context.objectForKeyedSubscript("__error")?.call(withArguments: [message])
                        rejectBox.value.call(withArguments: [error as Any])
                    }
                }
            )
        }
        if let task { tasks.append(task) }
        return promise
    }

    private func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        for task in tasks { task.cancel() }
        tasks = []
        context = nil
        continuation.resume(with: result)
    }

    private static func request(_ address: String, options: JSValue?) -> URLRequest? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let options, options.isObject {
            if let method = options.objectForKeyedSubscript("method"), method.isString { request.httpMethod = method.toString().uppercased() }
            if let headers = options.objectForKeyedSubscript("headers")?.toDictionary() as? [String: Any] {
                for (key, value) in headers { request.setValue("\(value)", forHTTPHeaderField: key) }
            }
            if let body = options.objectForKeyedSubscript("body"), body.isString { request.httpBody = Data(body.toString().utf8) }
        }
        return request
    }

    private static func describe(_ value: JSValue) -> String {
        let message = value.objectForKeyedSubscript("message")
        if let message, message.isString { return message.toString() }
        return value.toString() ?? "JavaScript error"
    }

    /// JS helpers: errors as `Error`, responses with `text()`/`json()`, and the await-and-stringify step.
    private static let prelude = """
    globalThis.__error = (message) => new Error(message);
    globalThis.dove.fetch = async (url, options) => {
      const raw = await globalThis.dove.__fetch(String(url), options || {});
      return { ...raw, text() { return raw.body }, json() { return JSON.parse(raw.body) } };
    };
    globalThis.__settle = (value, ok, fail) => {
      Promise.resolve(value).then(
        (result) => {
          try { ok(JSON.stringify(result === undefined ? null : result)) }
          catch (error) { fail("The plugin answered something that is not JSON: " + error) }
        },
        (error) => fail(String((error && error.message) || error))
      );
    };
    """
}

/// Carries a non-Sendable value across a hop the sandbox's queue serialises.
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
