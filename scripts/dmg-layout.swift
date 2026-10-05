// Writes the Finder layout of Juice's disk image (P976), headless: release.sh mounts the read-write image with
// -nobrowse, runs this on the mounted volume, and converts the image after. No Finder window opens and no AppleScript
// runs. The volume's .DS_Store gets what Finder reads for the window: its size with no toolbar or sidebar ("bwsp"), an
// icon view with 128-point icons over the background picture ("icvp", whose backgroundImageAlias is an alias record),
// and where the app and the Applications link sit ("Iloc").
//
// Usage: dmg-layout <mounted volume> <app name, like Juice.app> <background, relative to the volume>
//        dmg-layout --read <.DS_Store>   prints each record as "<file> <code> <type> <size>", for the tests
//
// Before it writes, it resolves its own alias back to the picture (CFURLCreateBookmarkDataFromAliasRecord, then
// URL(resolvingBookmarkData:)), so an image whose background Finder could not find is never made. The alias holds the
// volume's name and dates, the picture's path on the volume and /Volumes/<volume name>, where a downloaded image
// mounts: nothing of this Mac. No "pBBk" (the picture as the system's bookmark data): macOS writes the backing image's
// path, the startup disk's name and its UUID into that, which a public download must not carry (P977).
//
// The .DS_Store format: a "Bud1" buddy allocator holding one B-tree ("DSDB") with one leaf node, its records sorted by
// file name (case-insensitively), then by code. The layout is the one a new store starts with: the allocator's root
// block of 2048 bytes at 2048, the tree's header in 32 bytes at 32, the leaf in 4096 bytes at 4096.
import CoreFoundation
import Foundation

let windowSize = (width: 660, height: 400)
let iconSize = 128.0
let textSize = 13.0
/// The icons' centres, from the window's top left (scripts/make-dmg-art.swift draws the arrow between them).
let appPoint = (x: 170, y: 190)
let linkPoint = (x: 490, y: 190)

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("dmg-layout: \(text)\n".utf8))
    exit(1)
}

extension Data {
    mutating func be32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    mutating func be16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func code(_ s: String) {
        let bytes = Array(s.utf8)
        precondition(bytes.count == 4)
        append(contentsOf: bytes)
    }
    func u32(_ at: Int) -> UInt32 {
        let i = startIndex + at
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}

// MARK: The alias record (version 2), as Carbon's Alias Manager wrote it

/// Seconds since 1904-01-01, the Mac's epoch.
func macSeconds(_ date: Date) -> UInt32 { UInt32(clamping: Int64(date.timeIntervalSince1970 + 2_082_844_800)) }

func pascal(_ text: String, capacity: Int) -> Data {
    var bytes = Array(text.replacingOccurrences(of: ":", with: "/").utf8.prefix(capacity))
    while bytes.count > 0, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    var data = Data([UInt8(bytes.count)])
    data.append(contentsOf: bytes)
    data.append(Data(count: capacity - bytes.count))
    return data
}

func fileNumber(_ url: URL) -> UInt32 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { fail("cannot read \(url.lastPathComponent)") }
    return UInt32(truncatingIfNeeded: info.st_ino)
}

func alias(for file: URL, volume: URL, volumeName: String, relative: String) -> Data {
    let parent = file.deletingLastPathComponent()
    let volumeValues = try? volume.resourceValues(forKeys: [.volumeCreationDateKey, .volumeIsEjectableKey])
    let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
    var record = Data()
    record.code("\0\0\0\0")                        // the application's own 4 bytes
    record.be16(0)                                 // the record's size, filled in last
    record.be16(2)                                 // version 2
    record.be16(0)                                 // a file
    record.append(pascal(volumeName, capacity: 27))
    record.be32(macSeconds(volumeValues?.volumeCreationDate ?? Date()))
    record.append(contentsOf: Array("H+".utf8))    // HFS+
    record.be16(volumeValues?.volumeIsEjectable == true ? 5 : 0)  // an ejectable disk, or a fixed one
    record.be32(fileNumber(parent))                // the folder's CNID
    record.append(pascal(file.lastPathComponent, capacity: 63))
    record.be32(fileNumber(file))
    record.be32(macSeconds(created))
    record.code("\0\0\0\0")                        // type
    record.code("\0\0\0\0")                        // creator
    record.be16(0xffff); record.be16(0xffff)       // levels from and to: not relative
    record.be32(0)                                 // volume attributes
    record.be16(0)                                 // file system id
    record.append(Data(count: 10))
    func tag(_ id: UInt16, _ data: Data) {
        record.be16(id)
        record.be16(UInt16(data.count))
        record.append(data)
        if data.count % 2 == 1 { record.append(0) }
    }
    func unicode(_ text: String) -> Data {
        let units = Array(text.utf16)
        var data = Data()
        data.be16(UInt16(units.count))
        for unit in units { data.be16(unit) }
        return data
    }
    let components = relative.split(separator: "/").map(String.init)
    tag(0, Data(parent.lastPathComponent.replacingOccurrences(of: ":", with: "/").utf8))
    var cnids = Data()
    var folder = parent
    while folder.standardizedFileURL.path != volume.standardizedFileURL.path {
        cnids.be32(fileNumber(folder))
        folder = folder.deletingLastPathComponent()
    }
    tag(1, cnids)
    tag(2, Data(([volumeName] + components).map { $0.replacingOccurrences(of: ":", with: "/") }.joined(separator: ":").utf8))
    tag(14, unicode(file.lastPathComponent))
    tag(15, unicode(volumeName))
    tag(18, Data(("/" + components.joined(separator: "/")).utf8))
    tag(19, Data("/Volumes/\(volumeName)".utf8))
    record.be16(0xffff); record.be16(0)
    let size = UInt16(record.count)
    record[record.startIndex + 4] = UInt8(size >> 8)
    record[record.startIndex + 5] = UInt8(size & 0xff)
    return record
}

/// Resolves bookmark data to its file's path, or nil.
func resolved(_ bookmark: Data) -> String? {
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                             bookmarkDataIsStale: &stale) else { return nil }
    return url.resolvingSymlinksInPath().path
}

// MARK: The .DS_Store

struct Record {
    var name: String
    var code: String
    var type: String
    var payload: Data

    var bytes: Data {
        var data = Data()
        let units = Array(name.utf16)
        data.be32(UInt32(units.count))
        for unit in units { data.be16(unit) }
        data.code(code)
        data.code(type)
        data.append(payload)
        return data
    }

    static func blob(_ name: String, _ code: String, _ data: Data) -> Record {
        var payload = Data()
        payload.be32(UInt32(data.count))
        payload.append(data)
        return Record(name: name, code: code, type: "blob", payload: payload)
    }

    static func plist(_ name: String, _ code: String, _ value: [String: Any]) -> Record {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else {
            fail("cannot write the \(code) property list")
        }
        return blob(name, code, data)
    }

    static func location(_ name: String, x: Int, y: Int) -> Record {
        var data = Data()
        data.be32(UInt32(x)); data.be32(UInt32(y)); data.be32(0xffff_ffff); data.be32(0xffff_0000)
        return blob(name, "Iloc", data)
    }
}

func store(_ records: [Record]) -> Data {
    let sorted = records.sorted {
        let a = $0.name.lowercased(), b = $1.name.lowercased()
        return a != b ? Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16)) : Array($0.code.utf8).lexicographicallyPrecedes(Array($1.code.utf8))
    }
    var leaf = Data()
    leaf.be32(0)                                   // a leaf: no rightmost child
    leaf.be32(UInt32(sorted.count))
    for record in sorted { leaf.append(record.bytes) }
    guard leaf.count <= 4096 else { fail("the layout's records take \(leaf.count) bytes, more than one 4096-byte node") }

    // Blocks: 0 the allocator's root (2048 at 2048), 1 the tree's header (32 at 32), 2 the leaf (4096 at 4096). An
    // address is the offset with log2 of the size in its low five bits.
    let addresses: [UInt32] = [2048 | 11, 32 | 5, 4096 | 12]
    var header = Data()
    header.be32(2)                                 // the root node: block 2
    header.be32(0)                                 // no levels above it
    header.be32(UInt32(sorted.count))
    header.be32(1)                                 // one node
    header.be32(4096)                              // the page size

    var root = Data()
    root.be32(UInt32(addresses.count))
    root.be32(0)
    for index in 0..<256 { root.be32(index < addresses.count ? addresses[index] : 0) }
    root.be32(1)                                   // one directory entry
    root.append(4); root.append(contentsOf: Array("DSDB".utf8)); root.be32(1)
    // The free lists, by log2 of the size, as a new store's start (one block of each size at its own offset), less the
    // three blocks above: none of 32, 2048 or 4096 bytes is left, nor any of 2^31.
    for k in 0..<32 {
        var free: [UInt32] = []
        if ![5, 11, 12, 31].contains(k) { free = [UInt32(1) << UInt32(k)] }
        root.be32(UInt32(free.count))
        for offset in free { root.be32(offset) }
    }
    guard root.count <= 2048 else { fail("the allocator's root block does not fit") }

    // The file: four bytes, then the allocator's space, in which offset 0 holds the 32-byte header.
    var space = Data(count: 8192)
    func put(_ data: Data, at offset: Int) { space.replaceSubrange(offset..<offset + data.count, with: data) }
    var top = Data()
    top.code("Bud1")
    top.be32(2048); top.be32(2048); top.be32(2048)
    top.append(contentsOf: [0x00, 0x00, 0x10, 0x0c, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0b, 0x00, 0x00, 0x00, 0x00])
    put(top, at: 0)
    put(header, at: 32)
    put(root, at: 2048)
    put(leaf, at: 4096)
    var file = Data()
    file.be32(1)
    file.append(space)
    return file
}

/// Reads a store this writes back into its records, for the tests: "<file> <code> <type> <size>" a line, and for a
/// plist blob its keys too.
func read(_ path: String) {
    guard let file = FileManager.default.contents(atPath: path), file.count > 36,
          file.u32(0) == 1, String(data: file.subdata(in: 4..<8), encoding: .ascii) == "Bud1" else { fail("not a .DS_Store") }
    let space = file.subdata(in: 4..<file.count)
    let rootOffset = Int(space.u32(4))
    let count = Int(space.u32(rootOffset))
    var addresses: [UInt32] = []
    for i in 0..<count { addresses.append(space.u32(rootOffset + 8 + 4 * i)) }
    let tocAt = rootOffset + 8 + 4 * max(256, (count + 255) / 256 * 256)
    guard space.u32(tocAt) >= 1, space[tocAt + 4] == 4,
          String(data: space.subdata(in: tocAt + 5..<tocAt + 9), encoding: .ascii) == "DSDB" else { fail("no DSDB") }
    func block(_ n: Int) -> Int { Int(addresses[n] & ~0x1f) }
    let tree = block(Int(space.u32(tocAt + 9)))
    let leafAt = block(Int(space.u32(tree)))
    guard space.u32(tree + 4) == 0, space.u32(leafAt) == 0 else { fail("more than one level") }
    var at = leafAt + 8
    for _ in 0..<Int(space.u32(leafAt + 4)) {
        let length = Int(space.u32(at)); at += 4
        var units: [UInt16] = []
        for i in 0..<length { units.append(UInt16(space[at + 2 * i]) << 8 | UInt16(space[at + 2 * i + 1])) }
        at += 2 * length
        let name = String(decoding: units, as: UTF16.self)
        let code = String(decoding: space.subdata(in: at..<at + 4), as: UTF8.self)
        let type = String(decoding: space.subdata(in: at + 4..<at + 8), as: UTF8.self)
        at += 8
        var size = 0, extra = ""
        switch type {
        case "blob":
            size = Int(space.u32(at))
            let data = space.subdata(in: at + 4..<at + 4 + size)
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                extra = " " + plist.keys.sorted().map { key in
                    if let n = plist[key] as? NSNumber { return "\(key)=\(n)" }
                    if let s = plist[key] as? String { return "\(key)=\(s.replacingOccurrences(of: " ", with: ""))" }
                    return key
                }.joined(separator: " ")
            } else if code == "Iloc" {
                extra = " \(data.u32(0)),\(data.u32(4))"
            }
            at += 4 + size
        case "long", "shor": size = 4; extra = " \(space.u32(at))"; at += 4
        case "type": size = 4; extra = " " + String(decoding: space.subdata(in: at..<at + 4), as: UTF8.self); at += 4
        case "bool": size = 1; at += 1
        default: fail("a record of type \(type)")
        }
        print("\(name) \(code) \(type) \(size)\(extra)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--read", arguments.count == 2 {
    read(arguments[1])
    exit(0)
}
guard arguments.count == 3 else {
    fail("usage: dmg-layout <mounted volume> <app name> <background, relative to the volume> | --read <.DS_Store>")
}
let volume = URL(fileURLWithPath: arguments[0], isDirectory: true).resolvingSymlinksInPath()
let appName = arguments[1], relative = arguments[2]
let background = volume.appendingPathComponent(relative)
guard FileManager.default.fileExists(atPath: volume.appendingPathComponent(appName).path) else { fail("no \(appName) on the volume") }
guard FileManager.default.fileExists(atPath: background.path) else { fail("no \(relative) on the volume") }
let volumeName = (try? volume.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? volume.lastPathComponent

let aliasRecord = alias(for: background, volume: volume, volumeName: volumeName, relative: relative)
guard let fromAlias = CFURLCreateBookmarkDataFromAliasRecord(kCFAllocatorDefault, aliasRecord as CFData)?.takeRetainedValue() as Data?,
      resolved(fromAlias) == background.resolvingSymlinksInPath().path else {
    fail("the background's alias does not lead back to \(relative)")
}

let windowBounds = "{{200, 120}, {\(windowSize.width), \(windowSize.height)}}"
let records: [Record] = [
    .plist(".", "bwsp", ["WindowBounds": windowBounds, "ShowSidebar": false, "ShowToolbar": false, "ShowStatusBar": false,
                         "ShowPathbar": false, "ShowTabView": false, "ContainerShowSidebar": false, "PreviewPaneVisibility": false,
                         "SidebarWidth": 180]),
    .plist(".", "icvp", ["viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": aliasRecord,
                         "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
                         "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "arrangeBy": "none",
                         "showIconPreview": false, "showItemInfo": false, "labelOnBottom": true, "textSize": textSize,
                         "iconSize": iconSize, "scrollPositionX": 0.0, "scrollPositionY": 0.0]),
    Record(name: ".", code: "vSrn", type: "long", payload: { var d = Data(); d.be32(1); return d }()),
    Record(name: ".", code: "vstl", type: "type", payload: Data("icnv".utf8)),
    .location(appName, x: appPoint.x, y: appPoint.y),
    .location("Applications", x: linkPoint.x, y: linkPoint.y),
]
let target = volume.appendingPathComponent(".DS_Store")
let bytes = store(records)
// Nothing of this Mac: not the home folder, and not where this run mounted the volume (unless that is /Volumes/<name>).
for leak in [NSHomeDirectory(), volume.path] where leak != "/Volumes/\(volumeName)" && leak.count > 1 {
    if bytes.range(of: Data(leak.utf8)) != nil { fail("the layout would name \(leak)") }
}
do {
    try bytes.write(to: target)
} catch {
    fail("cannot write .DS_Store: \(error.localizedDescription)")
}
print("dmg-layout: \(target.path)")
