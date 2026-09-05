import Foundation

/// Which microphone Talk records from.
enum MicChoice: Equatable {
    /// Follow whatever macOS' input device happens to be — the behaviour before
    /// there was a picker, and the reason connecting AirPods used to move
    /// dictation onto them.
    case systemDefault
    /// Always this device, whatever macOS does. `name` is a label snapshot so a
    /// disconnected device still has something to show in the menu.
    case pinned(uid: String, name: String)

    /// Reserved word for "no pin" in JSON. No real device UID looks like it.
    static let systemToken = "system"

    /// The device to record from, or nil to follow macOS.
    var deviceUID: String? {
        if case .pinned(let uid, _) = self { return uid }
        return nil
    }

    var displayName: String {
        switch self {
        case .systemDefault: return "System default"
        case .pinned(_, let name): return name
        }
    }
}

/// The settings Talk changes itself and has to remember across launches, kept in
/// ~/.talk/state.json beside the user's hand-edited config.json — which the app
/// only ever reads, so that it stays theirs to format and comment.
struct AppState {
    /// nil means the user has never picked a mic, in which case config.json's
    /// "microphone" seed (if any) applies.
    var microphone: MicChoice?

    static func fileURL() -> URL {
        Config.configFileURL().deletingLastPathComponent().appendingPathComponent("state.json")
    }

    /// A missing or unreadable file is simply "nothing chosen yet" — this is a
    /// convenience store, never a reason to fail to launch.
    static func load() -> AppState {
        guard let data = try? Data(contentsOf: fileURL()),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (json["microphone"] as? String)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty
        else { return AppState(microphone: nil) }

        if value.caseInsensitiveCompare(MicChoice.systemToken) == .orderedSame {
            return AppState(microphone: .systemDefault)
        }
        return AppState(microphone: .pinned(uid: value, name: (json["microphoneName"] as? String) ?? value))
    }

    /// Write failures are ignored: the choice still holds for this session, and a
    /// read-only home directory shouldn't break dictation.
    func save() {
        var json: [String: Any] = [:]
        switch microphone {
        case .systemDefault:
            json["microphone"] = MicChoice.systemToken
        case .pinned(let uid, let name):
            json["microphone"] = uid
            json["microphoneName"] = name
        case nil:
            break
        }
        let url = Self.fileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
