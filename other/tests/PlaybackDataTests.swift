import Cocoa

// Only dependencies outside the history/cache subsystem are replaced.
enum Preference {
  enum Key { case recordPlaybackHistory, maxThumbnailPreviewCacheSize }
  static func bool(for key: Key) -> Bool { true }
  static func integer(for key: Key) -> Int { 100 }
}

enum Utility {
  static let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  static let playbackHistoryURL = root.appendingPathComponent("history")
  static let watchLaterURL = root.appendingPathComponent("watch_later", isDirectory: true)
  static let thumbnailCacheURL = root.appendingPathComponent("thumb_cache", isDirectory: true)
  static func mpvWatchLaterMd5(_ url: URL, _ ignorePath: Bool) -> String { url.lastPathComponent }
  static func playbackProgressFromWatchLater(_ md5: String) -> VideoTime? { nil }
}

struct VideoTime {
  let second: Double
  init(_ second: Double) { self.second = second }
  var stringRepresentation: String { String(second) }
}

struct FloatingPointByteCountFormatter {
  enum PrefixFactor: Int { case mi = 1048576 }
}

struct MemoryUsage {
  static let shared = MemoryUsage()
  func logUsage(_ message: String) {}
}

enum Logger {
  enum Level { case debug, verbose, error }
  struct Sub {}
  static func makeSubsystem(_ name: String, _ icon: [String]) -> String { name }
  static func isEmitting(_ level: Level) -> Bool { false }
  static func log(_ message: () -> String, level: Level, subsystem: String) {
    if level == .error { print("Expected error-path log: \(message())") }
  }
}

extension Notification.Name {
  static let iinaHistoryUpdated = Notification.Name("historyUpdated")
  static let iinaHistoryTaskFinished = Notification.Name("historyTaskFinished")
}

@main
struct PlaybackDataTests {
  static func clear(_ history: HistoryController) async -> Result<Void, Error> {
    await withCheckedContinuation { continuation in
      history.removeAll { continuation.resume(returning: $0) }
    }
  }

  static func main() async throws {
    let fm = FileManager.default
    let history = HistoryController(plistFileURL: Utility.playbackHistoryURL)
    for index in 0..<20 {
      history.add(Utility.root.appendingPathComponent("video-\(index).mp4"),
                  duration: 60, title: nil, false)
    }
    try await clear(history).get()
    precondition(history.history.isEmpty, "Pending additions restored cleared history")
    precondition(history.tasksOutstanding == 0)
    precondition(HistoryController(plistFileURL: Utility.playbackHistoryURL).history.isEmpty,
                 "History survived reloading from disk")
    try await clear(history).get()
    print("PASS: queued additions, memory/disk clearing, repeat clearing")

    let media = Utility.root.appendingPathComponent("keep.mp4")
    try Data("keep media".utf8).write(to: media)
    for directory in [Utility.watchLaterURL, Utility.thumbnailCacheURL] {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("cache".utf8).write(to: directory.appendingPathComponent("entry"))
      try Data("hidden".utf8).write(to: directory.appendingPathComponent(".hidden"))
      try fm.createSymbolicLink(at: directory.appendingPathComponent("media-link"),
                                withDestinationURL: media)
    }
    let cache = CacheManager()
    precondition(cache.getCacheSize() > 0)
    try cache.clearPlaybackCaches()
    for directory in [Utility.watchLaterURL, Utility.thumbnailCacheURL] {
      let contents = try fm.contentsOfDirectory(atPath: directory.path)
      precondition(contents.isEmpty)
    }
    precondition(cache.getCacheSize() == 0, "Cache size was not refreshed")
    let mediaContents = try Data(contentsOf: media)
    precondition(mediaContents == Data("keep media".utf8), "Media was modified")
    try cache.clearPlaybackCaches()
    try fm.removeItem(at: Utility.watchLaterURL)
    try fm.removeItem(at: Utility.thumbnailCacheURL)
    try cache.clearPlaybackCaches()
    print("PASS: caches cleared, directories recreated, unrelated media preserved")

    try fm.removeItem(at: Utility.watchLaterURL)
    try Data().write(to: Utility.watchLaterURL)
    do {
      try cache.clearPlaybackCaches()
      fatalError("Cache filesystem errors were swallowed")
    } catch {
      print("PASS: cache filesystem errors propagate")
    }

    let blockedHistory = HistoryController(plistFileURL: media.appendingPathComponent("history"))
    let existing = PlaybackHistory(url: media, duration: 60, title: nil, mpvMd5: "keep")
    blockedHistory.history = [existing]
    switch await clear(blockedHistory) {
    case .success:
      fatalError("History filesystem errors were swallowed")
    case .failure:
      precondition(blockedHistory.history == [existing], "Failed write discarded in-memory history")
      precondition(blockedHistory.tasksOutstanding == 0)
    }
    print("PASS: history write failure reported without losing in-memory data")
  }
}
