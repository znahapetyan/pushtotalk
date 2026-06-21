import Foundation

enum TalkError: Error, CustomStringConvertible {
    case config(String)
    case network(String)
    case api(String)

    var description: String {
        switch self {
        case .config(let m): return m
        case .network(let m): return m
        case .api(let m): return m
        }
    }
}

/// Performs a blocking HTTP request. MUST be called from a background queue
/// (never the main thread) since it parks the caller on a semaphore.
func postSync(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var data: Data?
    var response: URLResponse?
    var error: Error?

    let task = URLSession.shared.dataTask(with: request) { d, r, e in
        data = d
        response = r
        error = e
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    if let error = error {
        throw TalkError.network(error.localizedDescription)
    }
    guard let data = data, let http = response as? HTTPURLResponse else {
        throw TalkError.network("No response from server")
    }
    return (data, http)
}
