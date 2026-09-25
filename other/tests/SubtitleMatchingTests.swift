import Foundation

@main
enum SubtitleMatchingTests {
  static var checks = 0
  static var failures: [String] = []
  static var fixtureNumber = 0
  static var fixtureRoot: URL!

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
      failures.append(message)
      print("FAIL: \(message)")
    }
  }

  static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    expect(actual == expected, "\(message); expected \(expected), got \(actual)")
  }

  static func runMatcher(videos: [String], subtitles: [String], current: String? = nil,
                         action: Preference.IINAAutoLoadAction = .iina,
                         autoAdd: Bool = false, languages: String = "",
                         priorityStrings: String? = nil) throws -> PlayerCore {
    fixtureNumber += 1
    let folder = fixtureRoot.appendingPathComponent("case-\(fixtureNumber)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in videos + subtitles {
      try Data().write(to: folder.appendingPathComponent(name))
    }
    Preference.action = action
    Preference.autoAdd = autoAdd
    Preference.languages = languages
    Preference.priorityStrings = priorityStrings
    let player = PlayerCore()
    player.info.currentURL = folder.appendingPathComponent(current ?? videos[0])
    player.mpv.playlist = [player.info.currentURL!.path]
    try AutoFileMatcher(player: player, ticket: 1).startMatching()
    expect(!player.info.isMatchingSubtitles, "matching state resets after fixture \(fixtureNumber)")
    expectEqual(Set(player.info.currentSubsInfo.map { $0.url.lastPathComponent }),
                Set(subtitles), "fixture \(fixtureNumber) discovers every subtitle")
    return player
  }

  static func matched(_ player: PlayerCore, _ video: String) -> [String] {
    let path = player.info.currentURL!.deletingLastPathComponent().appendingPathComponent(video).path
    return (player.info.matchedSubs[path] ?? []).map(\.lastPathComponent)
  }

  static func suffixTests() {
    let video = "The.Film.2024.1080p"
    let accepted = [
      "", ".zh", ".chi", ".zho", ".chs", ".cht", ".zh-Hans", ".zh_Hant",
      ".en", ".eng", ".en-US", ".en.sdh", ".en.forced", ".zh-Hans.forced",
      " [zh]", " (en)", ".[chi]", ".[zh-Hans]", " [en] [sdh]",
      "_zh", "-zh", " zh", ".en+zh", ".en&zh", ".EN.SDH"
    ]
    for suffix in accepted {
      expect(SubtitleMatching.matches(video: video, subtitle: video + suffix),
             "accept language/role suffix \(suffix.debugDescription)")
    }
    // Separators between independently meaningful language and role tokens
    // must not be mistaken for a BCP-47 region/script.
    for suffix in ["_en_sdh", "-en-forced", ".en_sdh", ".en-forced",
                   ".zh-Hant-forced", "_zh_Hant_forced", ".zh-Hant-TW.sdh"] {
      expect(SubtitleMatching.matches(video: video, subtitle: video + suffix),
             "accept separated language/role suffix \(suffix.debugDescription)")
    }
    let rejected = [
      "Other.Film.2024.1080p.zh", "The.Film.2023.1080p.zh",
      "The.Film.2024.720p.zh", video + "2.zh", video + ".Part.2.zh",
      video + ".Other.Release.zh", "Another." + video + ".zh",
      video + ".zh.Commentary", video + ".", video + ".notalanguage",
      video + ".en.sdh.other"
    ]
    for subtitle in rejected {
      expect(!SubtitleMatching.matches(video: video, subtitle: subtitle),
             "reject unrelated or invalid subtitle \(subtitle)")
    }
    expect(!SubtitleMatching.matches(video: "Up", subtitle: "Upstream.en"), "reject title prefix collision")
    expect(!SubtitleMatching.matches(video: "Up", subtitle: "The.Up.en"), "reject title substring collision")
    expect(!SubtitleMatching.matches(video: "Show.S01E01", subtitle: "Show.S01E02.zh"),
           "reject a different episode")
    expect(!SubtitleMatching.matches(video: "Show.S01E01", subtitle: "Show.S02E01.zh"),
           "reject a different season")
    expect(!SubtitleMatching.matches(video: "", subtitle: ".en"), "reject empty video name")
    expect(SubtitleMatching.matches(video: "CAFÉ", subtitle: "cafe\u{301}.en"),
           "normalize Unicode and case")
  }

  static func languageTests() {
    for code in ["zh", "chi", "zho", "chs", "cht", "zh-Hans", "zh_Hant"] {
      expectEqual(SubtitleMatching.languagePreference(for: "Movie.\(code)", languages: ["en", "zh"]),
                  1, "Chinese subtitle alias \(code)")
    }
    for (preference, suffix) in [
      ("zh", "chi"), ("chi", "zho"), ("zho", "zh"), ("chs", "zh-Hans"),
      ("cht", "zh_Hant"), ("zh-Hans", "chs"), ("zh_Hant", "cht")
    ] {
      expectEqual(SubtitleMatching.languagePreference(for: "Movie.\(suffix)", languages: [preference, "en"]),
                  0, "Chinese preference alias \(preference) matches \(suffix)")
    }
    expectEqual(SubtitleMatching.languagePreference(for: "Movie.zh-Hant", languages: ["zh-Hans", "zh"]),
                1, "script-specific preference does not override the actual subtitle script")
    for suffix in [".zh-Hant", "_zh_Hant", ".cht", ".zh-Hant-forced", ".zh_Hant_TW.sdh"] {
      expectEqual(SubtitleMatching.languagePreference(for: "Movie" + suffix, languages: ["zh-Hant", "zh"]),
                  0, "explicit Hant preference recognizes canonical alias/tag \(suffix)")
    }
    for suffix in [".zh-Hans", "_zh_Hans", ".chs", ".zh-Hans-CN.forced"] {
      expectEqual(SubtitleMatching.languagePreference(for: "Movie" + suffix, languages: ["zh-Hant", "zh"]),
                  1, "explicit Hant preference does not select Hans alias/tag \(suffix)")
    }
    for suffix in ["en", "eng", "en-US", "en.sdh", "en.forced"] {
      expectEqual(SubtitleMatching.languagePreference(for: "Movie.\(suffix)", languages: ["zh", "eng"]),
                  1, "English subtitle alias/role \(suffix)")
    }
    for suffix in [" [zh]", " (chi)", "_zh", "-zh", ".[zh-Hans]", ".en_sdh", ".en-forced"] {
      expectEqual(SubtitleMatching.languagePreference(for: "Movie" + suffix, languages: ["zh", "en"]),
                  suffix.contains("en") ? 1 : 0, "language preference handles suffix \(suffix)")
    }
    expectEqual(SubtitleMatching.languagePreference(for: "Movie.zh", languages: [" en ", " chi "]),
                1, "trim preferred language whitespace")
    expectEqual(SubtitleMatching.languagePreference(for: "Movie.en", languages: []),
                0, "empty preference list")
    expectEqual(SubtitleMatching.languagePreference(for: "Movie.fr", languages: ["zh", "en"]),
                2, "unpreferred language sorts last")
    expectEqual(SubtitleMatching.languagePreference(for: "en.Movie", languages: ["en"]),
                1, "language-looking title prefix is not a language suffix")
  }

  static func orchestrationTests() throws {
    let videos = ["Film.2024.1080p.mkv", "Other.Film.2024.1080p.mkv"]
    let subs = ["Film.2024.1080p.zh.srt", "Unrelated.2024.1080p.zh.srt"]
    for autoAdd in [false, true] {
      let disabled = try runMatcher(videos: videos, subtitles: subs,
                                    action: .disabled, autoAdd: autoAdd)
      expect(disabled.info.matchedSubs.isEmpty,
             "disabled subtitle matching stays disabled with playlist auto-add \(autoAdd)")
      expectEqual(disabled.mpv.playlist.count, autoAdd ? 2 : 1,
                  "playlist auto-add operates independently of disabled subtitle matching")
    }
    for action in [Preference.IINAAutoLoadAction.iina, .mpvFuzzy] {
      let player = try runMatcher(videos: videos, subtitles: subs, action: action, autoAdd: true)
      expectEqual(matched(player, videos[0]), [subs[0]], "only correct film subtitle with mode \(action)")
      expectEqual(matched(player, videos[1]), [], "no substring subtitle collision with mode \(action)")
      expectEqual(Set(player.mpv.playlist.map { URL(fileURLWithPath: $0).lastPathComponent }),
                  Set(videos), "auto-add still includes both films")
      let unrelated = try runMatcher(videos: ["Film.2024.1080p.mkv"],
                                    subtitles: ["Film.2023.1080p.zh.srt", "Other.Film.2024.1080p.zh.srt"],
                                    action: action, autoAdd: true)
      expect(unrelated.info.matchedSubs.isEmpty,
             "no edit-distance fallback for unmatched film with auto-add and mode \(action)")
    }
    let ordered = try runMatcher(videos: ["Movie.mkv"],
                                subtitles: ["Movie.en.forced.srt", "Movie.zho.srt", "Movie.fr.srt",
                                            "Movie.chi.srt", "Movie.zh-Hans.srt"],
                                languages: "zh,eng")
    expectEqual(matched(ordered, "Movie.mkv"),
                ["Movie.chi.srt", "Movie.zh-Hans.srt", "Movie.zho.srt", "Movie.en.forced.srt", "Movie.fr.srt"],
                "preferred aliases precede English and unpreferred languages with stable path tie-break")
    let bracketed = try runMatcher(videos: ["Movie.mkv"],
                                  subtitles: ["Movie [zh].srt", "Movie.en.srt"], languages: "zh,en")
    expectEqual(matched(bracketed, "Movie.mkv"), ["Movie [zh].srt", "Movie.en.srt"],
                "bracketed preferred Chinese sorts before English")
    let scriptOrdered = try runMatcher(videos: ["Movie.mkv"],
                                      subtitles: ["Movie.zh-Hans.srt", "Movie.zh-Hant.srt"],
                                      languages: "zh-Hant,zh")
    expectEqual(matched(scriptOrdered, "Movie.mkv"), ["Movie.zh-Hant.srt", "Movie.zh-Hans.srt"],
                "explicit Hant preference overrides alphabetical Hans-first order")
    let aliasOrdered = try runMatcher(videos: ["Movie.mkv"],
                                     subtitles: ["Movie.chs.srt", "Movie.cht.srt"],
                                     languages: "zh-Hant,zh")
    expectEqual(matched(aliasOrdered, "Movie.mkv"), ["Movie.cht.srt", "Movie.chs.srt"],
                "explicit Hant preference orders canonical script aliases correctly")
  }

  static func priorityTests() throws {
    let subtitles = [
      "Movie.zh.srt", "Movie.en.srt", "Movie.fr.srt",
      "Movie.zh.sdh.srt", "Movie.en.forced.srt", "Movie.zh.forced.srt",
      "Movie.en.sdh.forced.srt"
    ]
    let expected = [
      "Movie.en.sdh.forced.srt",
      "Movie.zh.forced.srt", "Movie.zh.sdh.srt", "Movie.en.forced.srt",
      "Movie.zh.srt", "Movie.en.srt", "Movie.fr.srt"
    ]
    // Repeated independent FileInfo sets and reversed creation order exercise
    // stability without making expectations depend on Set iteration order.
    for attempt in 0..<6 {
      let player = try runMatcher(videos: ["Movie.mkv"],
                                  subtitles: attempt.isMultiple(of: 2) ? subtitles : subtitles.reversed(),
                                  languages: "zh,en", priorityStrings: " sdh, forced, , ")
      expectEqual(matched(player, "Movie.mkv"), expected,
                  "multiple priorities promote all matches by score, preserving language/path ties (run \(attempt + 1))")
    }
  }

  static func seriesTests() throws {
    let videos = (1...3).map { "Show.S01E0\($0).Release.mkv" }
    let subs = (1...3).map { "Show.S01E0\($0).zh.srt" }
    let player = try runMatcher(videos: videos, subtitles: subs, autoAdd: true)
    for index in videos.indices {
      expectEqual(matched(player, videos[index]), [subs[index]],
                  "same series prefix and episode survives differing release suffix \(index + 1)")
    }
    expectEqual(Set(player.info.currentVideosInfo.map(\.prefix)), ["Show.S01E0"],
                "real FileGroup identifies shared series prefix")
    let episodeNames = player.info.currentVideosInfo.compactMap(\.nameInSeries)
    expectEqual(Set(episodeNames).count, 3, "real FileGroup keeps episode identities distinct")
    for video in player.info.currentVideosInfo {
      let subtitle = player.info.currentSubsInfo.first {
        $0.url.lastPathComponent == matched(player, video.url.lastPathComponent).first
      }
      expectEqual(video.nameInSeries, subtitle?.nameInSeries,
                  "real FileGroup assigns matching video/subtitle episode identity")
    }

    for otherPrefix in ["OtherShow.S01E0", "Show.S02E0", "Shox.S01E0"] {
      let otherSubs = (1...3).map { "\(otherPrefix)\($0).zh.srt" }
      let unrelated = try runMatcher(videos: videos, subtitles: otherSubs, autoAdd: true)
      expect(unrelated.info.matchedSubs.isEmpty, "reject different show/season prefix \(otherPrefix)")
    }
    let wrongEpisodes = try runMatcher(videos: videos,
                                      subtitles: (4...6).map { "Show.S01E0\($0).zh.srt" },
                                      autoAdd: true)
    expect(wrongEpisodes.info.matchedSubs.isEmpty, "same series does not match different episodes")

    let mixedVideos = ["Show.S01E01.Release.mkv", "Show.S01E02.Release.mkv", "Show.S02E01.Release.mkv"]
    let mixedSubs = ["Show.S01E01.zh.srt", "Show.S01E02.zh.srt", "Show.S02E01.zh.srt"]
    let mixed = try runMatcher(videos: mixedVideos, subtitles: mixedSubs, autoAdd: true)
    expectEqual(Set(mixed.info.currentVideosInfo.map(\.prefix)), ["Show.S0"],
                "mixed-season regression groups with prefix inside season number")
    expectEqual(mixed.info.currentVideosInfo.compactMap(\.nameInSeries),
                ["s01e01", "s01e02", "s02e01"],
                "mixed-season grouping preserves complete normalized SxxExx identity")
    for index in mixedVideos.indices {
      expectEqual(matched(mixed, mixedVideos[index]), [mixedSubs[index]],
                  "mixed-season grouping retains season AND episode identity for \(mixedVideos[index])")
    }

    let disabled = try runMatcher(videos: videos, subtitles: subs, action: .disabled, autoAdd: true)
    expect(disabled.info.matchedSubs.isEmpty, "disabled blocks series matching despite playlist auto-add")
    expectEqual(disabled.mpv.playlist.count, 3, "disabled series matching preserves playlist auto-add")
    let filenameOnly = try runMatcher(videos: videos, subtitles: subs, action: .mpvFuzzy)
    expect(filenameOnly.info.matchedSubs.isEmpty, "filename-only mode does not enable series matching")
  }

  static func main() {
    guard CommandLine.arguments.count == 2 else {
      fatalError("Run other/tests/run-subtitle-matching-tests.sh")
    }
    fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    suffixTests()
    languageTests()
    do {
      try orchestrationTests()
      try priorityTests()
      try seriesTests()
    } catch {
      expect(false, "unexpected fixture error: \(error)")
    }
    print("\(checks - failures.count)/\(checks) checks passed; \(failures.count) failed")
    if !failures.isEmpty { exit(1) }
  }
}
