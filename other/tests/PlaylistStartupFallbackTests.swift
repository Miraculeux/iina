import Foundation

@main
struct PlaylistStartupFallbackTests {
  static let source = URL(fileURLWithPath: "/fixtures/channels.M3U")

  static func activeFallback() -> PlaylistStartupFallback {
    var fallback = PlaylistStartupFallback()
    fallback.begin(url: source)
    precondition(fallback.fileStarted(path: source.path, entryID: 1, now: 0) == nil)
    fallback.playlistExpanded(entryID: 1, count: 3)
    precondition(fallback.isActive)
    return fallback
  }

  static func main() {
    var fallback = activeFallback()
    precondition(fallback.fileStarted(path: "http://channel/2", entryID: 2, now: 100) == 10)
    precondition(!fallback.timedOut(entryID: 2, now: 109.999))
    precondition(fallback.fileStarted(path: "http://channel/2", entryID: 2, now: 105) == 5)
    precondition(fallback.timedOut(entryID: 2, now: 110))
    let idleEntries: [PlaylistStartupFallback.Entry] = [
      .init(id: 2, isPlaying: false), .init(id: 3, isPlaying: false), .init(id: 4, isPlaying: false)
    ]
    precondition(fallback.nextAction(entries: idleEntries, after: 2) == .play(1))
    print("PASS: exact 10-second deadline, duplicate events do not extend it, sequential fallback")

    precondition(fallback.fileStarted(path: "http://channel/3", entryID: 3, now: 110) == 10)
    precondition(!fallback.timedOut(entryID: 2, now: 120))
    precondition(!fallback.timedOut(entryID: 4, now: 120))
    let advancedEntries: [PlaylistStartupFallback.Entry] = [
      .init(id: 2, isPlaying: false), .init(id: 3, isPlaying: true), .init(id: 4, isPlaying: false)
    ]
    precondition(fallback.nextAction(entries: advancedEntries, after: 2) == .wait)
    fallback.fileFailed(entryID: 3)
    precondition(fallback.nextAction(entries: idleEntries, after: 3) == .play(2))
    print("PASS: stale events do not skip mpv's new loading entry; explicit errors advance immediately")

    fallback = activeFallback()
    fallback.fileFailed(entryID: 4)
    precondition(fallback.nextAction(entries: idleEntries, after: 4) == .play(0))
    fallback.fileFailed(entryID: 2)
    precondition(fallback.nextAction(entries: idleEntries, after: 2) == .play(1))
    fallback.fileFailed(entryID: 3)
    precondition(fallback.nextAction(entries: idleEntries, after: 3) == .exhausted)
    precondition(fallback.fileStarted(path: "http://channel/4", entryID: 4, now: 200) == 0)
    precondition(fallback.nextAction(entries: [], after: 3) == .exhausted)
    print("PASS: restored last entry wraps once, failed entries never retry, exhaustion and empty lists")

    fallback = activeFallback()
    _ = fallback.fileStarted(path: "http://channel/2", entryID: 2, now: 0)
    fallback.cancel()
    precondition(!fallback.isActive)
    precondition(!fallback.timedOut(entryID: 2, now: 10))
    precondition(fallback.nextAction(entries: idleEntries, after: 2) == .wait)
    print("PASS: playback readiness, stop, close, quit and replacement cancel the fallback")

    for path in ["/fixtures/movie.mp4", "/fixtures/list.pls", "/fixtures/stream.m3u8"] {
      fallback.begin(url: URL(fileURLWithPath: path))
      precondition(fallback.fileStarted(path: path, entryID: 10, now: 0) == nil)
      precondition(!fallback.isActive)
      precondition(!fallback.timedOut(entryID: 10, now: 100))
    }
    fallback.playlistExpanded(entryID: 99, count: 3)
    precondition(!fallback.isActive)
    fallback.playlistExpanded(entryID: 10, count: 0)
    precondition(!fallback.isActive)
    print("PASS: ordinary media and non-expanded HLS are unaffected; unrelated/empty redirects ignored")

    fallback = activeFallback()
    _ = fallback.fileStarted(path: "http://nested/list", entryID: 2, now: 0)
    fallback.playlistExpanded(entryID: 2, count: 2)
    precondition(!fallback.timedOut(entryID: 2, now: 10))
    precondition(fallback.fileStarted(path: "http://nested/channel", entryID: 5, now: 8) == 10)
    fallback.begin(url: source)
    precondition(!fallback.timedOut(entryID: 5, now: 18))
    print("PASS: nested playlists get a fresh per-item deadline and replacement invalidates old attempts")
  }
}
