//
//  AutoFileMatcher.swift
//  iina
//
//  Created by lhc on 7/7/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

class AutoFileMatcher {

  private enum AutoMatchingError: Error {
    case ticketExpired
  }

  weak private var player: PlayerCore!
  var ticket: Int

  private let fm = FileManager.default
  private let searchOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]

  private var currentFolder: URL!
  private var filesGroupedByMediaType: [MPVTrack.TrackType: [FileInfo]] = [.video: [], .audio: [], .sub: []]
  private var videosGroupedBySeries: [String: [FileInfo]] = [:]
  private var subtitles: [FileInfo] = []
  private var subsGroupedBySeries: [String: [FileInfo]] = [:]

  private let subsystem: Logger.Subsystem

  private func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }

  init(player: PlayerCore, ticket: Int) {
    self.player = player
    self.ticket = ticket
    subsystem = Logger.makeSubsystem("fmatcher\(player.playerNumber)", ["square.stack.3d.up"])
  }

  /// checkTicket
  private func checkTicket() throws {
    try player.checkTicket(ticket)
  }

  private var mediaFiles: [FileInfo] {
    filesGroupedByMediaType[.video]! + filesGroupedByMediaType[.audio]!
  }

  private func getAllMediaFiles() throws {
    // get all files in current directory
    guard let files = try? fm.contentsOfDirectory(at: currentFolder, includingPropertiesForKeys: nil, options: searchOptions) else { return }

    log("Getting all media files...")
    // group by extension
    for file in files {
      try checkTicket()
      let fileInfo = FileInfo(file)
      if let mediaType = Utility.mediaType(forExtension: fileInfo.ext) {
        filesGroupedByMediaType[mediaType]!.append(fileInfo)
      }
    }

    log("Got all media files, video=\(filesGroupedByMediaType[.video]!.count), audio=\(filesGroupedByMediaType[.audio]!.count)")

    // natural sort
    filesGroupedByMediaType[.video]!.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    filesGroupedByMediaType[.audio]!.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
  }

  private func getAllPossibleSubs() throws -> [FileInfo] {
    try checkTicket()
    log("Getting all sub files...")

    // search subs
    let subExts = Utility.supportedFileExt[.sub]!
    var subDirs: [URL] = []

    // search subs in other directories
    let rawUserDefinedSearchPaths = Preference.string(for: .subAutoLoadSearchPath) ?? "./*"
    let userDefinedSearchPaths = rawUserDefinedSearchPaths.components(separatedBy: ":").filter { !$0.isEmpty }
    for path in userDefinedSearchPaths {
      var p = path
      // handle `~`
      if path.hasPrefix("~") {
        p = NSString(string: path).expandingTildeInPath
      }
      if path.hasSuffix("/") { p.deleteLast(1) }
      // only check wildcard at the end
      let hasWildcard = path.hasSuffix("/*")
      if hasWildcard { p.deleteLast(2) }
      // handle absolute paths
      let pathURL = path.hasPrefix("/") || path.hasPrefix("~") ? URL(fileURLWithPath: p, isDirectory: true) : currentFolder.appendingPathComponent(p, isDirectory: true)
      // handle wildcards
      if hasWildcard {
        // append all sub dirs
        if let contents = try? fm.contentsOfDirectory(at: pathURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
          subDirs.append(contentsOf: contents.filter { $0.isExistingDirectory })
        }
      } else {
        subDirs.append(pathURL)
      }
    }

    log("Searching subtitles from \(subDirs.count) directories...")
    log("\(subDirs)", level: .verbose)
    // get all possible sub files
    var subtitles = filesGroupedByMediaType[.sub]!
    for subDir in subDirs {
      try checkTicket()
      if let contents = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil, options: searchOptions) {
        subtitles.append(contentsOf: contents.compactMap { subExts.contains($0.pathExtension.lowercased()) ? FileInfo($0) : nil })
      }
    }

    log("Got \(subtitles.count) subtitles")
    let languages = (Preference.string(for: .subLang) ?? "").components(separatedBy: ",")
    return subtitles.sorted {
      let lhs = SubtitleMatching.languagePreference(for: $0.filename, languages: languages)
      let rhs = SubtitleMatching.languagePreference(for: $1.filename, languages: languages)
      return lhs == rhs ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : lhs < rhs
    }
  }

  private func addFilesToPlaylist() throws {
    var addedCurrentVideo = false
    var needQuit = false

    log("Adding files to playlist")
    // add videos
    for video in filesGroupedByMediaType[.video]! + filesGroupedByMediaType[.audio]! {
      // add to playlist
      if video.url.path == player.info.currentURL?.path {
        addedCurrentVideo = true
      } else if addedCurrentVideo {
        try checkTicket()
        player.appendToPlaylist(video.path, silent: true)
      } else {
        let count = player.mpv.getInt(MPVProperty.playlistCount)
        let current = player.mpv.getInt(MPVProperty.playlistPos)
        try checkTicket()
        player.appendToPlaylist(video.path, silent: true)
        player.mpv.command(.playlistMove, args: ["\(count)", "\(current)"], checkError: false,
                           level: .verbose) { err in
          if err == MPV_ERROR_COMMAND.rawValue { needQuit = true }
          if err != 0 {
            self.log("Error \(err) when adding files to playlist", level: .error)
          }
        }
      }
      if needQuit { break }
    }
  }

  private func matchVideoAndSubSeries() throws -> [String: String] {
    log("Matching video and sub series...")
    var matchedPrefixes: [String: String] = [:]  // video: sub
    for (vp, vl) in videosGroupedBySeries {
      try checkTicket()
      guard vl.count > 2, !vp.isEmpty else { continue }
      let matches = subsGroupedBySeries.keys.filter {
        $0.compare(vp, options: .caseInsensitive) == .orderedSame
      }
      if matches.count == 1, let prefix = matches.first {
        matchedPrefixes[vp] = prefix
        log("Matched \(vp) with \(prefix)")
      }
    }

    log("Finished matching")
    return matchedPrefixes
  }

  private func matchSubs(withMatchedSeries matchedPrefixes: [String: String]) throws {
    log("Matching subs with matched series, prefixes=\(matchedPrefixes.count)...")

    // get auto load option
    let subAutoLoadOption: Preference.IINAAutoLoadAction = Preference.enum(for: .subAutoLoadIINA)
    guard subAutoLoadOption != .disabled else { return }

    for video in mediaFiles {
      var matchedSubs = Set<FileInfo>()
      log("Matching for \(video.filename)")

      // Series matching requires the same series prefix and episode.
      if subAutoLoadOption.shouldLoadSubsMatchedByIINA() {
        log("Matching by IINA...", level: .verbose)
        // is in series
        if !video.prefix.isEmpty, let matchedSubPrefix = matchedPrefixes[video.prefix] {
          // find sub with same name
          for sub in subtitles {
            guard let vn = video.nameInSeries, let sn = sub.nameInSeries else { continue }
            var nameMatched: Bool
            if let vnInt = Int(vn), let snInt = Int(sn) {
              nameMatched = vnInt == snInt
            } else {
              nameMatched = vn == sn
            }
            if nameMatched {
              log("Matched \(video.filename)(\(vn)) and \(sub.filename)(\(sn)) ...", level: .verbose)
              video.relatedSubs.append(sub)
              if sub.prefix == matchedSubPrefix {
                try checkTicket()
                player.info.$matchedSubs.withLock { $0[video.path, default: []].append(sub.url) }
                sub.isMatched = true
                matchedSubs.insert(sub)
              }
            }
          }
        }
        log("Finished", level: .verbose)
      }

      // Allow language and accessibility suffixes, but not arbitrary title substrings.
      if subAutoLoadOption.shouldLoadSubsContainingVideoName() {
        log("Matching subtitles containing video name...", level: .verbose)
        try subtitles.filter {
          SubtitleMatching.matches(video: video.filename, subtitle: $0.filename) && !$0.isMatched
        }.forEach { sub in
          try checkTicket()
          log("Matched \(sub.filename) and \(video.filename)", level: .verbose)
          player.info.$matchedSubs.withLock { $0[video.path, default: []].append(sub.url) }
          sub.isMatched = true
          matchedSubs.insert(sub)
        }
        log("Finished", level: .verbose)
      }

      // if no match
      if matchedSubs.isEmpty {
        log("No matched sub for this file")
      } else {
        log("Matched \(matchedSubs.count) subtitles")
      }

      // move the sub to front if it contains priority strings
      if let priorString = Preference.string(for: .subAutoLoadPriorityString), !matchedSubs.isEmpty {
        log("Moving sub containing priority strings...", level: .verbose)
        let stringList = priorString
          .components(separatedBy: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        let priorities = Dictionary(uniqueKeysWithValues: matchedSubs.map { sub in
          (sub.url, stringList.reduce(0) { $0 + sub.filename.countOccurrences(of: $1, in: nil) })
        })
        try checkTicket()
        player.info.$matchedSubs.withLock { subs in
          subs[video.path] = subs[video.path]?.enumerated().sorted {
            let lhs = priorities[$0.element, default: 0]
            let rhs = priorities[$1.element, default: 0]
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
          }.map(\.element)
        }
        log("Finished", level: .verbose)
      }
    }

    try checkTicket()
    player.info.currentVideosInfo = mediaFiles
  }

  func startMatching() throws {
    log("**Start matching")
    let shouldAutoLoad = Preference.bool(for: .playlistAutoAdd)

    do {
      guard let folder = player.info.currentURL?.deletingLastPathComponent(), folder.isFileURL else { return }
      currentFolder = folder

      player.info.isMatchingSubtitles = true
      try getAllMediaFiles()

      // get all possible subtitles
      subtitles = try getAllPossibleSubs()
      player.info.currentSubsInfo = subtitles

      // add files to playlist
      if shouldAutoLoad {
        try addFilesToPlaylist()
        player.postNotification(.iinaPlaylistChanged)
      }

      // group video and sub files
      log("Grouping video files...")
      videosGroupedBySeries = FileGroup.group(files: mediaFiles).flatten()
      log("Finished with \(videosGroupedBySeries.count) groups")

      log("Grouping sub files...")
      subsGroupedBySeries = FileGroup.group(files: subtitles).flatten()
      log("Finished with \(subsGroupedBySeries.count) groups")

      // match video and sub series
      let matchedPrefixes = try matchVideoAndSubSeries()

      try matchSubs(withMatchedSeries: matchedPrefixes)

      player.info.isMatchingSubtitles = false
      player.postNotification(.iinaPlaylistChanged)
      log("**Finished matching")
    } catch PlayerCore.TicketExpiredError.ticketExpired {
      player.info.isMatchingSubtitles = false
      throw PlayerCore.TicketExpiredError.ticketExpired
    } catch let err {
      player.info.isMatchingSubtitles = false
      log(err.localizedDescription, level: .error)
      return
    }
  }
}
