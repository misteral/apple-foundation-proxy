#!/usr/bin/env swift
// Prints facts about the on-device Apple Foundation models: which model families
// are installed (and their parameter count), plus the context window, languages
// and availability of the model the FoundationModels API uses. No server needed,
// no special permissions needed.
//
//   ./scripts/model-info.swift
//
// Model families come from MobileAsset descriptor file names in
// /System/Library/AssetsV2/persisted/AutoAssetDescriptors, e.g.
// "...GenerativeModels_com.apple.fm.language.instruct_3b.base.generic_12.0.81619...state".
// The parameter count is whatever Apple encodes in the family name (3b, 300m).

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

let descriptorDir = "/System/Library/AssetsV2/persisted/AutoAssetDescriptors"

func row(_ key: String, _ value: String) {
    print(key.padding(toLength: 14, withPad: " ", startingAt: 0) + value)
}

func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

struct Family {
    var version = "?"
    var adapters = 0
    var hasBase = false
    var hasFMAPI = false
}

/// "instruct_3b" -> "3B params", "instruct_300m" -> "300M params".
func params(_ family: String) -> String {
    guard let tag = family.split(separator: "_").last, let unit = tag.last,
          "bm".contains(unit), Int(tag.dropLast()) != nil else { return "size not published" }
    return "\(tag.dropLast())\(unit.uppercased()) params"
}

let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: descriptorDir)) ?? []

/// Groups installed on-device language assets by model family (instruct_3b, instruct_300m, ...).
func installedFamilies() -> [String: Family] {
    let marker = "GenerativeModels_com.apple.fm.language."
    var result: [String: Family] = [:]
    for name in descriptors {
        guard let r = name.range(of: marker) else { continue }
        // "<family>.<asset>.generic_<version>_0.state"
        let rest = name[r.upperBound...]
        guard let dot = rest.firstIndex(of: ".") else { continue }
        let family = String(rest[..<dot])
        let asset = rest[rest.index(after: dot)...].components(separatedBy: ".generic_")
        guard asset.count == 2 else { continue }
        var f = result[family] ?? Family()
        switch asset[0] {
        case "base":
            f.hasBase = true
            f.version = asset[1].split(separator: ".").prefix(3).joined(separator: ".")
        case "tokenizer", "image_tokenizer", "base_adapter":
            break
        default:
            f.adapters += 1
            if asset[0].hasPrefix("fm_api") { f.hasFMAPI = true }
        }
        result[family] = f
    }
    return result
}

let v = ProcessInfo.processInfo.operatingSystemVersion
let ram = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
row("Machine", "\(sysctlString("machdep.cpu.brand_string") ?? "?"), \(ram) RAM, macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")

print("\nInstalled models")
let families = installedFamilies()
if families.isEmpty {
    print("  none found (Apple Intelligence off or models not downloaded yet)")
}
// Shorter family name first, so instruct_3b lists before instruct_300m.
for (name, f) in families.sorted(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) }) {
    var line = "  " + pad(name, 16) + pad(params(name), 14) + pad("v\(f.version)", 13) + "\(f.adapters) adapters"
    if !f.hasBase { line += "  (no base weights)" }
    if f.hasFMAPI { line += "  ← FoundationModels API" }
    print(line)
}
let server = descriptors.filter { $0.contains("GenerativeModels_com.apple.gm.server.") }.count
if server > 0 {
    print("  " + pad("server (PCC)", 16) + pad("not published", 27) + "\(server) adapters  (model runs in Apple's cloud)")
}
print("")

#if canImport(FoundationModels)
if #available(macOS 26.0, *) {
    let model = SystemLanguageModel.default
    row("Availability", "\(model.availability)")
    if #available(macOS 26.4, *) {
        row("Context", "\(model.contextSize) tokens (prompt + instructions + tools + response)")
    } else {
        row("Context", "4096 tokens (fixed on macOS 26.0–26.3; contextSize API needs 26.4)")
    }
    let langs = model.supportedLanguages.compactMap { $0.languageCode?.identifier }
    row("Languages", Set(langs).sorted().joined(separator: ", "))
} else {
    row("Model", "FoundationModels needs macOS 26.0+")
}
#else
row("Model", "FoundationModels is not available in this toolchain/SDK")
#endif
