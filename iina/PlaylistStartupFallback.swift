import Foundation

struct PlaylistStartupFallback {
  struct Entry {
    let id: Int64
    let isPlaying: Bool
  }

  enum Action: Equatable {
    case wait
    case play(Int)
    case exhausted
  }

  static let timeout: TimeInterval = 10

  private var source: String?
  private var sourceEntryID: Int64?
  private var failedEntries = Set<Int64>()
  private var attempt: (id: Int64, deadline: TimeInterval)?
  private(set) var isActive = false
  private(set) var lastFailedEntryID: Int64?

  mutating func begin(url: URL) {
    cancel()
    if ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
      source = url.isFileURL ? url.path : url.absoluteString
    }
  }

  mutating func fileStarted(path: String, entryID: Int64, now: TimeInterval) -> TimeInterval? {
    if !isActive {
      if path == source {
        sourceEntryID = entryID
      }
      return nil
    }
    if failedEntries.contains(entryID) {
      attempt = (entryID, now)
      return 0
    }
    if attempt?.id != entryID {
      attempt = (entryID, now + Self.timeout)
    }
    return attempt.map { max(0, $0.deadline - now) }
  }

  mutating func playlistExpanded(entryID: Int64, count: Int) {
    guard count > 0, entryID == sourceEntryID || isActive else { return }
    isActive = true
    attempt = nil
  }

  mutating func fileFailed(entryID: Int64) {
    guard isActive else { return }
    failedEntries.insert(entryID)
    lastFailedEntryID = entryID
    if attempt?.id == entryID {
      attempt = nil
    }
  }

  mutating func timedOut(entryID: Int64, now: TimeInterval) -> Bool {
    guard isActive, let attempt, attempt.id == entryID, now >= attempt.deadline else { return false }
    fileFailed(entryID: entryID)
    return true
  }

  func nextAction(entries: [Entry], after entryID: Int64) -> Action {
    guard isActive else { return .wait }
    // mpv may already have advanced by the time its end-file event reaches the UI.
    if entries.contains(where: { $0.isPlaying && !failedEntries.contains($0.id) }) {
      return .wait
    }
    guard !entries.isEmpty else { return .exhausted }
    let start = entries.firstIndex(where: { $0.id == entryID }).map { $0 + 1 } ?? 0
    for offset in 0..<entries.count {
      let index = (start + offset) % entries.count
      if !failedEntries.contains(entries[index].id) {
        return .play(index)
      }
    }
    return .exhausted
  }

  mutating func cancel() {
    source = nil
    sourceEntryID = nil
    failedEntries.removeAll()
    attempt = nil
    isActive = false
    lastFailedEntryID = nil
  }
}
