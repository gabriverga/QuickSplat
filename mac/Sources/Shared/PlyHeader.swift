import Foundation

enum PlyKind {
    case unknown, splat, points, mesh
}

struct PlyInfo {
    var kind: PlyKind = .unknown
    var vertexCount: Int64 = -1
    var shDegree: Int = -1          // -1 = unknown / not a splat
    var comments: [String] = []
}

/// Reads only the .ply header (a few KB) to tell Gaussian splats, point clouds and meshes apart.
enum PlyHeader {
    static func read(_ url: URL) -> PlyInfo {
        var info = PlyInfo()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return info }
        let data = handle.readData(ofLength: 65536)
        try? handle.close()

        guard let endRange = data.range(of: Data("end_header".utf8)) else { return info }
        let headerData = data.subdata(in: data.startIndex..<endRange.lowerBound)
        let header = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1)
            ?? ""
        guard header.hasPrefix("ply") else { return info }

        var elements: [String: Int64] = [:]
        var vertexProps = Set<String>()
        var current: String? = nil

        for rawLine in header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("comment ") || line.hasPrefix("obj_info ") {
                if let space = line.firstIndex(of: " ") {
                    let comment = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
                    if !comment.isEmpty && info.comments.count < 8 { info.comments.append(comment) }
                }
                continue
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
            guard let first = tokens.first else { continue }
            if first == "element" && tokens.count >= 3 {
                current = tokens[1]
                elements[tokens[1]] = Int64(tokens[2]) ?? 0
            } else if first == "property" && current == "vertex", let last = tokens.last {
                vertexProps.insert(last)
            }
        }

        if let count = elements["vertex"] { info.vertexCount = count }

        let fRest = vertexProps.filter { $0.hasPrefix("f_rest_") }.count
        let shDegree = fRest >= 45 ? 3 : (fRest >= 24 ? 2 : (fRest >= 9 ? 1 : 0))

        if elements["chunk"] != nil || vertexProps.contains("packed_position") {
            // PlayCanvas / SuperSplat compressed PLY
            info.kind = .splat
            info.shDegree = elements["sh"] != nil ? -1 : 0
        } else if vertexProps.contains("f_dc_0")
                    || (vertexProps.contains("scale_0") && vertexProps.contains("rot_0") && vertexProps.contains("opacity")) {
            info.kind = .splat
            info.shDegree = shDegree
        } else if let faces = elements["face"], faces > 0 {
            info.kind = .mesh
        } else if vertexProps.contains("x") && vertexProps.contains("y") && vertexProps.contains("z") {
            info.kind = .points
        }
        return info
    }
}
