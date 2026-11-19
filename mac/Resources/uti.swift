// Prints the system's (non-dynamic) type identifier for a file extension, if any.
// Used by build.sh: swift Resources/uti.swift ply
import Foundation
import UniformTypeIdentifiers

if CommandLine.arguments.count > 1,
   let type = UTType(filenameExtension: CommandLine.arguments[1]),
   !type.isDynamic {
    print(type.identifier)
}
