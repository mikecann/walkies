import Foundation

/// The Convex deployment the app talks to. Both are in Sydney. The simulator uses
/// dev, so testing never touches the real walks on your and your dad's phones.
nonisolated enum Backend {
    #if targetEnvironment(simulator)
    static let name = "resolute-pig-177"
    #else
    static let name = "savory-bee-296"
    #endif

    static let cloud = URL(string: "https://\(name).ap-southeast-2.convex.cloud")!
    /// Also where Apple and Google sign-in hands back to the app (see Account.swift).
    static let site = URL(string: "https://\(name).ap-southeast-2.convex.site")!
}

nonisolated enum ConvexError: LocalizedError {
    case server(String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .badResponse(let code): "The server returned an error (\(code))."
        }
    }
}

/// Calls Convex functions over its HTTP API. Plain request and response is all the
/// sync needs, and it keeps working when iOS gives the app a few seconds in the background.
nonisolated struct ConvexClient: Sendable {
    var token: String?

    func query<Result: Decodable>(_ path: String, _ args: some Encodable = Empty()) async throws -> Result {
        try await call("query", path, args)
    }

    func mutation<Result: Decodable>(_ path: String, _ args: some Encodable = Empty()) async throws -> Result {
        try await call("mutation", path, args)
    }

    /// Uploads a file to Convex storage at a URL from `generateUploadUrl`, returning its id.
    func upload(_ data: Data, to url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        return try JSONDecoder().decode(Uploaded.self, from: body).storageId
    }

    func download(_ url: URL) async throws -> Data {
        let (body, response) = try await URLSession.shared.data(from: url)
        try Self.check(response)
        return body
    }

    struct Empty: Encodable {}

    private struct Request<Args: Encodable>: Encodable {
        var path: String
        var args: Args
        var format = "json"
    }

    private struct Envelope<Value: Decodable>: Decodable {
        var status: String
        var value: Value?
        var errorMessage: String?
    }

    private struct Uploaded: Decodable {
        var storageId: String
    }

    private func call<Result: Decodable>(_ kind: String, _ path: String, _ args: some Encodable) async throws -> Result {
        var request = URLRequest(url: Backend.cloud.appending(path: "api/\(kind)"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Request(path: path, args: args))
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let envelope = try? JSONDecoder().decode(Envelope<Result>.self, from: body) else {
            try Self.check(response)
            throw ConvexError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard envelope.status == "success" else {
            throw ConvexError.server(Self.message(from: body) ?? envelope.errorMessage ?? "Unknown error")
        }
        if let value = envelope.value { return value }
        if let nothing = Nothing() as? Result { return nothing }
        throw ConvexError.server("\(path) returned nothing")
    }

    /// For a ConvexError thrown on the server: its `message`, or its `code` when that's all
    /// it has (Chef looks for "UNAUTHENTICATED").
    private static func message(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = json["errorData"]
        else { return nil }
        if let text = data as? String { return text }
        guard let object = data as? [String: Any] else { return nil }
        return object["message"] as? String ?? object["code"] as? String
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConvexError.badResponse(http.statusCode)
        }
    }
}

/// For mutations that return null.
nonisolated struct Nothing: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}
