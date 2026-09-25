import Foundation

// Only external dependencies are doubled. Matching, grouping, discovery, and
// playlist orchestration compile directly from the application source.
enum Logger {
  typealias Subsystem = String
  enum Level { case debug, verbose, error }
  static func makeSubsystem(_ name: String, _ symbols: [String]) -> Subsystem { name }
  static func log(_ message: @autoclosure () -> String,
                  level: Level = .debug, subsystem: Subsystem) {}
  static func log(_ message: () -> String,
                  level: Level = .debug, subsystem: Subsystem) {}
}

enum MPVTrack {
  enum TrackType: Hashable { case video, audio, sub }
}

enum Utility {
  static let supportedFileExt: [MPVTrack.TrackType: [String]] = [
    .video: ["mkv", "mp4"], .audio: ["mp3"], .sub: ["srt", "ass"]
  ]
  static func mediaType(forExtension ext: String) -> MPVTrack.TrackType? {
    supportedFileExt.first { $0.value.contains(ext.lowercased()) }?.key
  }
}

enum Preference {
  enum Key {
    case playlistAutoAdd, subAutoLoadSearchPath, subLang
    case subAutoLoadIINA, subAutoLoadPriorityString
  }
  // Mirrors Preference.IINAAutoLoadAction; deliberately no UserDefaults access.
  enum IINAAutoLoadAction: Int {
    case disabled = 0, mpvFuzzy, iina
    func shouldLoadSubsContainingVideoName() -> Bool { self != .disabled }
    func shouldLoadSubsMatchedByIINA() -> Bool { self == .iina }
  }
  static var autoAdd = false
  static var action = IINAAutoLoadAction.iina
  static var languages = ""
  static var priorityStrings: String?
  static func bool(for key: Key) -> Bool { key == .playlistAutoAdd && autoAdd }
  static func string(for key: Key) -> String? {
    switch key {
    case .subAutoLoadSearchPath: return "" // Fixtures only; no external directories.
    case .subLang: return languages
    case .subAutoLoadPriorityString: return priorityStrings
    default: return nil
    }
  }
  static func `enum`(for key: Key) -> IINAAutoLoadAction { action }
}

@propertyWrapper
final class TestLocked<Value> {
  var wrappedValue: Value
  var projectedValue: TestLocked<Value> { self }
  init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    try body(&wrappedValue)
  }
}

final class TestPlaybackInfo {
  var currentURL: URL?
  var isMatchingSubtitles = false
  var currentVideosInfo: [FileInfo] = []
  var currentSubsInfo: [FileInfo] = []
  @TestLocked var matchedSubs: [String: [URL]] = [:]
}

enum MPVProperty {
  static let playlistCount = "playlist-count"
  static let playlistPos = "playlist-pos"
}
enum TestMPVCommand { case playlistMove }
enum TestMPVError: Int32 { case command = -12 }
let MPV_ERROR_COMMAND = TestMPVError.command

final class TestMPV {
  var playlist: [String] = []
  var position = 0
  func getInt(_ property: String) -> Int {
    property == MPVProperty.playlistCount ? playlist.count : position
  }
  func command(_ command: TestMPVCommand, args: [String], checkError: Bool,
               level: Logger.Level, completion: (Int32) -> Void) {
    let from = Int(args[0])!
    let to = Int(args[1])!
    let path = playlist.remove(at: from)
    playlist.insert(path, at: to)
    if to <= position { position += 1 }
    completion(0)
  }
}

extension Notification.Name {
  static let iinaPlaylistChanged = Notification.Name("testPlaylistChanged")
}

final class PlayerCore {
  enum TicketExpiredError: Error { case ticketExpired }
  let playerNumber = 0
  let info = TestPlaybackInfo()
  let mpv = TestMPV()
  var notifications: [Notification.Name] = []
  func checkTicket(_ ticket: Int) throws {
    if ticket != 1 { throw TicketExpiredError.ticketExpired }
  }
  func appendToPlaylist(_ path: String, silent: Bool) { mpv.playlist.append(path) }
  func postNotification(_ name: Notification.Name) { notifications.append(name) }
}

extension URL {
  var isExistingDirectory: Bool {
    (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}

extension String {
  mutating func deleteLast(_ count: Int) { removeLast(count) }
  func countOccurrences(of string: String, in range: Range<String.Index>?) -> Int {
    guard !string.isEmpty else { return 0 }
    return String(self[range ?? startIndex..<endIndex]).components(separatedBy: string).count - 1
  }
}
