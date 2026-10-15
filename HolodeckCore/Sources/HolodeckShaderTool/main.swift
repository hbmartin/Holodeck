import Foundation
import HolodeckCore

#if os(macOS)
do { try ShaderTool.run(arguments: Array(CommandLine.arguments.dropFirst())) }
catch let error as ShaderCheckerExit { exit(error.status) }
catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
#else
FileHandle.standardError.write(Data("holodeck-shader-tool requires macOS.\n".utf8))
exit(1)
#endif
