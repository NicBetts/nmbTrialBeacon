import Foundation
import Compression
import SQLite3

// Mirrors TrialStore.inflate exactly.
func inflate(_ blob: Data) -> String? {
    guard blob.count > 4 else { return nil }
    let length = Int(blob.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
    let payload = blob.dropFirst(4)
    guard length > 0 else { return nil }
    if payload.count == length {
        return String(data: payload, encoding: .utf8)
    }
    var output = Data(count: length)
    let payloadCount = payload.count
    let decoded = output.withUnsafeMutableBytes { dst -> Int in
        payload.withUnsafeBytes { src -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                  let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dstBase, length, srcBase, payloadCount, nil, COMPRESSION_ZLIB)
        }
    }
    guard decoded == length else { return nil }
    return String(data: output, encoding: .utf8)
}

let path = CommandLine.arguments[1]
var db: OpaquePointer?
guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    print("open failed"); exit(1)
}

func check(_ sql: String, label: String) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        print("\(label): PREPARE FAILED — \(String(cString: sqlite3_errmsg(db)))")
        return
    }
    defer { sqlite3_finalize(stmt) }
    var ok = 0, fail = 0
    var sample = ""
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        if let s = inflate(Data(bytes: bytes, count: n)), !s.isEmpty {
            ok += 1
            if sample.isEmpty { sample = String(s.prefix(140)) }
        } else {
            fail += 1
        }
    }
    print("\(label): decoded \(ok), failed \(fail)")
    if !sample.isEmpty { print("   sample → \(sample.replacingOccurrences(of: "\n", with: " "))…") }
}

check("SELECT brief_summary_z FROM trial WHERE brief_summary_z IS NOT NULL LIMIT 400", label: "brief_summary_z")
check("SELECT detailed_description_z FROM trial WHERE detailed_description_z IS NOT NULL LIMIT 400", label: "detailed_description_z")
check("SELECT inclusion_z FROM eligibility WHERE inclusion_z IS NOT NULL LIMIT 400", label: "eligibility.inclusion_z")
check("SELECT exclusion_z FROM eligibility WHERE exclusion_z IS NOT NULL LIMIT 400", label: "eligibility.exclusion_z")
check("SELECT raw_text_z FROM eligibility WHERE raw_text_z IS NOT NULL LIMIT 400", label: "eligibility.raw_text_z")
