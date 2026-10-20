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
    case coded(String, String)
    case badResponse(Int)

    var code: String? { if case .coded(let code, _) = self { code } else { nil } }

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .coded(let code, let message):
            switch code {
            case "RATE_LIMITED": "Too many invite attempts. Please wait up to an hour before trying again."
            case "MEMBER_REMOVED": "You were removed from this team. Ask its creator for a new invite link."
            case "TEAM_FULL": "This team is full. A team can have up to 8 members."
            case "NOT_A_MEMBER", "TEAM_NOT_FOUND": "You no longer have access to this team. You may have been removed or the team has closed."
            default: message
            }
        case .badResponse(let code): "The server returned an error (\(code))."
        }
    }
}

/// Calls Convex functions over its HTTP API. Plain request and response is all the
/// sync needs, and it keeps working when iOS gives the app a few seconds in the background.
nonisolated struct ConvexClient: Sendable {
    var token: String?
    var session: URLSession = .shared

    func query<Result: Decodable>(_ path: String, _ args: some Encodable = Empty()) async throws -> Result {
        try await call("query", path, args)
    }

    func mutation<Result: Decodable>(_ path: String, _ args: some Encodable = Empty()) async throws -> Result {
        try await call("mutation", path, args)
    }

    /// A cold place fetch can try both Overpass servers. Cached actions return quickly.
    func action<Result: Decodable>(_ path: String, _ args: some Encodable = Empty()) async throws -> Result {
        try await call("action", path, args, timeout: 360)
    }

    /// Uploads a file to Convex storage at a URL from `generateUploadUrl`, returning its id.
    func upload(_ data: Data, to url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.data(for: request)
        try Self.check(response)
        return try JSONDecoder().decode(Uploaded.self, from: body).storageId
    }

    func download(_ url: URL) async throws -> Data {
        let (body, response) = try await session.data(from: url)
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

    private func call<Result: Decodable>(_ kind: String, _ path: String, _ args: some Encodable, timeout: TimeInterval = 30) async throws -> Result {
        var request = URLRequest(url: Backend.cloud.appending(path: "api/\(kind)"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Request(path: path, args: args))
        let (body, response) = try await session.data(for: request)
        guard let envelope = try? JSONDecoder().decode(Envelope<Result>.self, from: body) else {
            try Self.check(response)
            throw ConvexError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard envelope.status == "success" else {
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let error = json["errorData"] as? [String: Any], let code = error["code"] as? String {
                throw ConvexError.coded(code, error["message"] as? String ?? code)
            }
            throw ConvexError.server(Self.message(from: body) ?? envelope.errorMessage ?? "Unknown error")
        }
        if let value = envelope.value { return value }
        // Optional query results (such as an unknown invite) legitimately return null.
        if let null = try? JSONDecoder().decode(Result.self, from: Data("null".utf8)) { return null }
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
