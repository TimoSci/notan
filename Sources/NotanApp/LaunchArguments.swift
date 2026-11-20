import Foundation

/// The photo to open at launch: the first command-line argument that is an existing file.
/// Flags and their values (Xcode passes several when it launches an app) are not photos.
public func initialPhotoURL(arguments: [String]) -> URL? {
    for argument in arguments.dropFirst() where !argument.hasPrefix("-") {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            return URL(fileURLWithPath: argument)
        }
    }
    return nil
}
