import Foundation

/// Uploads an audio file to a Whisper-compatible transcription API
/// (Groq or OpenAI — both use the OpenAI multipart shape).
struct Transcriber {
    let config: Config

    func transcribe(_ fileURL: URL, language: String?, prompt: String?, translate: Bool) throws -> String {
        let isLocal = (config.provider == "local")
        let endpoint = translate ? config.translationEndpoint : config.transcriptionEndpoint
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Local servers need no auth; cloud providers do.
        if !config.transcriptionKey.isEmpty {
            request.setValue("Bearer \(config.transcriptionKey)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        func append(_ string: String) { body.append(string.data(using: .utf8)!) }

        // file field
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        append("\r\n")

        // model field. The cloud translations endpoint needs a translation-capable
        // model; turbo isn't one, so fall back to the full model when translating.
        let model = (translate && !isLocal && config.transcriptionModel.contains("turbo"))
            ? "whisper-large-v3" : config.transcriptionModel
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        // temperature=0 → deterministic, fewer silence hallucinations
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n")
        append("0\r\n")

        // Language hint. The cloud translations endpoint auto-detects the source
        // and rejects a language param, so only send it for transcription or for
        // the local server (which accepts it as a source hint even when translating).
        if (!translate || isLocal), let language = language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        // The local whisper.cpp server performs translation via a flag.
        if translate && isLocal {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"translate\"\r\n\r\n")
            append("true\r\n")
        }

        // optional vocabulary/spelling bias (names, jargon, acronyms)
        if let prompt = prompt, !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("\(prompt)\r\n")
        }

        // response_format=text → the response body is the raw transcript
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("text\r\n")

        append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, http) = try postSync(request)
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TalkError.api("Transcription failed (\(http.statusCode)): \(message)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
