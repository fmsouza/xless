import Foundation
import XlessASC
import XlessCore

/// Sends a plan's requests with the API key. A POST is sent once, never retried (a retry could create a second
/// resource); so is a request carrying the demo account's password, which is read from its secret only here, put into
/// that one body, and scrubbed from whatever App Store Connect answers.
public struct StoreSender: Sendable {
    public let client: ASCClient
    /// The value of a secret, by name (`Secrets.required`).
    public let secret: @Sendable (String) throws -> String

    let cache = SecretCache()

    public init(client: ASCClient, secret: @escaping @Sendable (String) throws -> String) {
        self.client = client; self.secret = secret
    }

    /// A secret's value, read once per push (a store passphrase is asked at most once).
    public func value(of name: String) throws -> String {
        if let v = cache.get(name) { return v }
        let v = try secret(name)
        HTTPTrace.hide(v)
        cache.set(name, v)
        return v
    }

    /// Sends a change's requests in order; `{id}` in a path is the ID the previous request created.
    public func apply(_ change: StoreChange) async throws {
        var created: String?
        for request in change.requests {
            var request = request
            if request.path.contains("{id}") {
                guard let created else { throw XlessError(.account, "App Store Connect did not say which \(change.subject) it created", fix: "re-run `xless store push`") }
                request.path = request.path.replacingOccurrences(of: "{id}", with: created)
                if case .object(var doc)? = request.body, case .object(var data)? = doc["data"], data["id"] == .string("{id}") {
                    data["id"] = .string(created)
                    doc["data"] = .object(data)
                    request.body = .object(doc)
                }
            }
            created = try await send(request, path: request.path)
        }
    }

    /// The created resource's ID, for a POST.
    func send(_ request: StoreRequest, path: String) async throws -> String? {
        guard let name = request.secret else {
            let response = try await client.request(request.method, path, body: try request.body.map { try JSONEncoder().encode($0) },
                                                    maxAttempts: request.method == "POST" ? 1 : ASCClient.maxAttempts)
            return Self.createdID(response.data)
        }
        let value = try value(of: name)
        let body = Self.inject(value, into: request.body ?? .object([:]))
        do {
            let response = try await client.request(request.method, path, body: try JSONEncoder().encode(body), maxAttempts: 1)
            return Self.createdID(response.data)
        } catch let error as ASCError {
            throw Self.scrub(error, value)
        } catch {
            if !value.isEmpty, "\(error)".contains(value) {
                throw XlessError(.account, "sending the App Review details failed", fix: "re-run `xless store push`")
            }
            throw error
        }
    }

    /// The body with `data.attributes.demoAccountPassword` set.
    static func inject(_ value: String, into body: JSONValue) -> JSONValue {
        guard case .object(var doc) = body, case .object(var data)? = doc["data"] else { return body }
        var attributes: [String: JSONValue] = [:]
        if case .object(let a)? = data["attributes"] { attributes = a }
        attributes["demoAccountPassword"] = .string(value)
        data["attributes"] = .object(attributes)
        doc["data"] = .object(data)
        return .object(doc)
    }

    /// Apple's error without the secret's value, wherever its answer repeated it.
    static func scrub(_ error: ASCError, _ value: String) -> ASCError {
        guard !value.isEmpty else { return error }
        var e = error
        func clean(_ s: String?) -> String? { s?.replacingOccurrences(of: value, with: HTTPTrace.placeholder) }
        e.items = error.items.map { item in
            var i = item
            i.title = clean(i.title); i.detail = clean(i.detail); i.code = clean(i.code)
            if let source = i.source { i.source = .init(pointer: clean(source.pointer), parameter: clean(source.parameter)) }
            return i
        }
        return e
    }

    struct Created: Decodable {
        struct Data: Decodable { var id: String }
        var data: Data
    }

    static func createdID(_ data: Data) -> String? { (try? JSONDecoder().decode(Created.self, from: data))?.data.id }
}

/// The secrets one push has read, kept for its own requests only.
final class SecretCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func get(_ name: String) -> String? { lock.withLock { values[name] } }
    func set(_ name: String, _ value: String) { lock.withLock { values[name] = value } }
}
