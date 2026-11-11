import Foundation

/// Requests the local address checks send to the real gateway and media server.
extension SetbeamProbe {
    struct ProbeReply { let status: Int; let body: Data; var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] } }

    static func http(_ url: String, json: [String: Any]? = nil, pass: String? = nil) async throws -> ProbeReply {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        if let json {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        if let pass { request.setValue(pass, forHTTPHeaderField: "X-Setbeam-Pass") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ProbeReply(status: (response as! HTTPURLResponse).statusCode, body: data)
    }

    static func whep(_ url: String, _ user: String, _ password: String) async throws -> Int {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        request.httpMethod = "POST"; request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = Data("v=0\r\n".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    static func decodedFrames(tools: URL, directory: URL, rtsp: String, user: String, password: String) async throws -> Int {
        var parts = URLComponents(string: rtsp)!; parts.user = user; parts.password = password
        let data = try await run(tools: tools, args: ["-v", "error", "-rtsp_transport", "tcp", "-read_intervals", "%+3", "-select_streams", "v:0",
                                                       "-count_frames", "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", parts.string!],
                                 directory: directory, executable: "ffprobe")
        return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "") ?? 0
    }
}
