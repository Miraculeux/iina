//
//  FileGroup.swift
//  iina
//
//  Created by lhc on 20/5/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

fileprivate let subsystem = Logger.makeSubsystem("fgroup", ["rectangle.3.group"])

class FileInfo: Hashable {
  var url: URL
  var path: String
  var filename: String
  var ext: String
  var nameInSeries: String?
  var characters: [Character]
  var relatedSubs: [FileInfo] = []
  var isMatched = false

  var prefix: String {  // prefix detected by FileGroup
    didSet {
      if prefix.count < self.characters.count {
        suffix = String(filename[filename.index(filename.startIndex, offsetBy: prefix.count)...])
        getNameInSeries()
      } else {
        prefix = ""
        suffix = self.filename
      }
    }
  }
  var suffix: String  // filename - prefix

  init(_ url: URL) {
    self.url = url
    self.path = url.path
    self.ext = url.pathExtension
    self.filename = url.deletingPathExtension().lastPathComponent
    self.characters = [Character](self.filename)
    self.prefix = ""
    self.suffix = self.filename
  }

  private func getNameInSeries() {
    if let range = filename.range(of: "(?i)(?<![a-z0-9])s[0-9]+e[0-9]+(?:e[0-9]+)*(?![a-z0-9])",
                                  options: .regularExpression) {
      self.nameInSeries = String(filename[range]).lowercased()
      return
    }
    // e.g. "abc_" "ch01_xxx" -> "ch01"
    var firstDigit = false
    let name = suffix.unicodeScalars.prefix {
      if CharacterSet.decimalDigits.contains($0) {
        if !firstDigit {
          firstDigit = true
        }
      } else {
        if firstDigit {
          return false
        }
      }
      return true
    }
    self.nameInSeries = String(name)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(path)
  }
  
  static func == (lhs: FileInfo, rhs: FileInfo) -> Bool {
    return lhs.path == rhs.path
  }
}

enum SubtitleMatching {
  private static let separators = CharacterSet(charactersIn: "._- ()[]")
  private static let tokenSeparators = CharacterSet(charactersIn: ". ()[]+&")
  private static let roles: Set<String> = ["forced", "sdh", "cc", "default"]
  private static let languageCodes: Set<String> = {
    if #available(macOS 13, *) {
      return Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
    } else {
      return Set(Locale.isoLanguageCodes)
    }
  }()

  static func matches(video: String, subtitle: String) -> Bool {
    let video = video.precomposedStringWithCanonicalMapping.lowercased()
    let subtitle = subtitle.precomposedStringWithCanonicalMapping.lowercased()
    guard !video.isEmpty, subtitle.hasPrefix(video) else { return false }
    let suffix = String(subtitle.dropFirst(video.count))
    if suffix.isEmpty { return true }
    guard let first = suffix.unicodeScalars.first, separators.contains(first) else { return false }
    return suffixLanguages(suffix) != nil
  }

  static func languagePreference(for filename: String, languages: [String]) -> Int {
    var subtitleLanguages: [String] = []
    for index in filename.unicodeScalars.indices where separators.contains(filename.unicodeScalars[index]) {
      if let suffix = suffixLanguages(String(filename[index...])) {
        subtitleLanguages = suffix
        break
      }
    }
    return languages.firstIndex {
      guard let language = languageCode($0.trimmingCharacters(in: .whitespaces)) else { return false }
      return subtitleLanguages.contains { $0 == language || $0.hasPrefix(language + "-") }
    } ?? languages.count
  }

  private static func suffixLanguages(_ suffix: String) -> [String]? {
    let tokens = suffix.lowercased().trimmingCharacters(in: separators)
      .components(separatedBy: tokenSeparators).filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }
    var languages: [String] = []
    for token in tokens {
      var parts = token.components(separatedBy: CharacterSet(charactersIn: "_-"))
      while let last = parts.last, roles.contains(last) { parts.removeLast() }
      if parts.isEmpty { continue }
      guard let language = languageCode(parts.joined(separator: "-")) else { return nil }
      languages.append(language)
    }
    return languages
  }

  private static func languageCode(_ token: String) -> String? {
    let token = token.lowercased()
    if token == "chs" { return "zh-hans" }
    if token == "cht" { return "zh-hant" }
    guard token.range(of: "^[a-z]{2,3}([_-][a-z]{4})?([_-]([a-z]{2}|[0-9]{3}))?$",
                      options: .regularExpression) != nil else { return nil }
    let canonical = Locale.canonicalLanguageIdentifier(from: token).lowercased()
    guard let code = canonical.split(separator: "-").first,
          languageCodes.contains(String(code)) else { return nil }
    return canonical
  }
}


class FileGroup {

  var prefix: String
  var contents: [FileInfo]
  var groups: [FileGroup]

  private let chineseNumbers: [Character] = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

  static func group(files: [FileInfo]) -> FileGroup {
    Logger.log("Start grouping \(files.count) files", subsystem: subsystem)
    let group = FileGroup(prefix: "", contents: files)
    group.tryGroupFiles()
    return group
  }

  init(prefix: String, contents: [FileInfo] = []) {
    self.prefix = prefix
    self.contents = contents
    self.groups = []
  }

  private func tryGroupFiles() {
    Logger.log("Try group files, prefix=\(prefix), count=\(contents.count)", level: .verbose, subsystem: subsystem)
    guard contents.count >= 3 else {
      Logger.log("Contents count < 3, skipped", level: .verbose, subsystem: subsystem)
      return
    }

    var tempGroup: [String: [FileInfo]] = [:]
    var currChars: [(Character, String)] = []
    var i = prefix.count

    while tempGroup.count < 2 {
      var lastPrefix = prefix
      var anyProcessed = false
      for finfo in contents {
        // if reached string end
        if i >= finfo.characters.count {
          tempGroup[prefix, default: []].append(finfo)
          currChars.append(("/", prefix))
          continue
        }
        let c = finfo.characters[i]
        var p = prefix
        p.append(c)
        lastPrefix = p
        if tempGroup[p] == nil {
          tempGroup[p] = []
          currChars.append((c, p))
        }
        tempGroup[p]!.append(finfo)
        anyProcessed = true
      }
      // if all items have the same prefix
      if tempGroup.count == 1 {
        prefix = lastPrefix
        tempGroup.removeAll()
        currChars.removeAll()
      }
      i += 1
      // if all items have the same name
      if !anyProcessed {
        break
      }
    }

    let maxSubGroupCount = tempGroup.reduce(0, { max($0, $1.value.count) })
    if stopGrouping(currChars) || maxSubGroupCount < 3 {
      Logger.log("Stop grouping, maxSubGroup=\(maxSubGroupCount)", level: .verbose, subsystem: subsystem)
      contents.forEach { $0.prefix = self.prefix }
    } else {
      Logger.log("Continue grouping, groups=\(tempGroup.count), chars=\(currChars)", level: .verbose, subsystem: subsystem)
      groups = tempGroup.map { FileGroup(prefix: $0.0, contents: $0.1) }
      // continue
      for g in groups {
        g.tryGroupFiles()
      }
    }
  }

  func flatten() -> [String: [FileInfo]] {
    var result: [String: [FileInfo]] = [:]
    func search(_ group: FileGroup) {
      if group.groups.count > 0 {
        for g in group.groups {
          search(g)
        }
      } else {
        result[group.prefix] = group.contents
      }
    }
    search(self)
    return result
  }

  private func stopGrouping(_ chars: [(Character, String)]) -> Bool {
    var chineseNumberCount = 0
    for (c, _) in chars {
      if c >= "0" && c <= "9" { return true }
      // chinese characters
      if chineseNumbers.contains(c) { chineseNumberCount += 1 }
      if chineseNumberCount >= 3 { return true }
    }
    return false
  }

}
