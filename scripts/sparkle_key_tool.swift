#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private enum KeyToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message): message
        }
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sparkle-key-tool: \(message)\n".utf8))
    exit(1)
}

private func requireAbsolutePath(_ path: String) throws -> URL {
    guard path.hasPrefix("/") else {
        throw KeyToolError.message("private-key path must be absolute")
    }
    return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
}

private func ensureSecureParentDirectory(for fileURL: URL) throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    let manager = FileManager.default
    let directoryAlreadyExisted = manager.fileExists(atPath: directoryURL.path)

    if !directoryAlreadyExisted {
        try manager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directoryURL.path, S_IRWXU) == 0 else {
            throw KeyToolError.message("cannot restrict private-key directory to mode 0700")
        }
    }

    try validateSecureParentDirectory(for: fileURL)
}

private func validateSecureParentDirectory(for fileURL: URL) throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    try rejectSymlinks(in: directoryURL)

    var status = stat()
    guard lstat(directoryURL.path, &status) == 0 else {
        throw KeyToolError.message("cannot inspect private-key directory")
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
        throw KeyToolError.message("private-key parent is not a directory")
    }
    guard status.st_uid == getuid() else {
        throw KeyToolError.message("private-key directory is not owned by the current user")
    }
    guard status.st_mode & 0o777 == 0o700 else {
        throw KeyToolError.message("private-key directory permissions must be 0700")
    }
}

private func rejectSymlinks(in directoryURL: URL) throws {
    var currentPath = "/"
    for component in directoryURL.standardizedFileURL.pathComponents.dropFirst() {
        currentPath = (currentPath as NSString).appendingPathComponent(component)
        var status = stat()
        guard lstat(currentPath, &status) == 0 else {
            throw KeyToolError.message("cannot inspect private-key directory hierarchy")
        }
        guard (status.st_mode & S_IFMT) != S_IFLNK else {
            throw KeyToolError.message("private-key directory hierarchy must not contain symlinks")
        }
    }
}

private func writeSecureFile(_ data: Data, to fileURL: URL) throws {
    let descriptor = open(
        fileURL.path,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
        if errno == EEXIST {
            throw KeyToolError.message("refusing to overwrite an existing private-key file")
        }
        throw KeyToolError.message("cannot create private-key file (errno \(errno))")
    }

    var completed = false
    defer {
        close(descriptor)
        if !completed {
            unlink(fileURL.path)
        }
    }

    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw KeyToolError.message("cannot set private-key permissions to 0600")
    }

    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let count = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                data.count - offset
            )
            if count < 0 && errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw KeyToolError.message("cannot write private-key file (errno \(errno))")
            }
            offset += count
        }
    }

    guard fsync(descriptor) == 0 else {
        throw KeyToolError.message("cannot flush private-key file")
    }
    completed = true
}

private func readSecureFile(from fileURL: URL) throws -> Data {
    try validateSecureParentDirectory(for: fileURL)
    let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw KeyToolError.message("cannot open private-key file (errno \(errno))")
    }
    defer { close(descriptor) }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw KeyToolError.message("cannot inspect private-key file")
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
        throw KeyToolError.message("private-key path is not a regular file")
    }
    guard status.st_uid == getuid() else {
        throw KeyToolError.message("private-key file is not owned by the current user")
    }
    guard status.st_nlink == 1 else {
        throw KeyToolError.message("private-key file must have exactly one hard link")
    }

    let permissions = status.st_mode & 0o777
    guard permissions == 0o600 else {
        throw KeyToolError.message("private-key permissions must be 0600")
    }
    guard status.st_size > 0 && status.st_size <= 512 else {
        throw KeyToolError.message("private-key file has an invalid size")
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 512)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR {
            continue
        }
        guard count >= 0 else {
            throw KeyToolError.message("cannot read private-key file (errno \(errno))")
        }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
        guard data.count <= 512 else {
            throw KeyToolError.message("private-key file is too large")
        }
    }
    return data
}

private func loadPrivateKey(from fileURL: URL) throws -> Curve25519.Signing.PrivateKey {
    let encodedData = try readSecureFile(from: fileURL)
    guard let encoded = String(data: encodedData, encoding: .utf8) else {
        throw KeyToolError.message("private-key file is not UTF-8")
    }
    let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: trimmed), seed.count == 32 else {
        throw KeyToolError.message("private-key file must contain one base64-encoded 32-byte seed")
    }
    do {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    } catch {
        throw KeyToolError.message("private-key seed is invalid")
    }
}

private func publicKeyString(for privateKey: Curve25519.Signing.PrivateKey) -> String {
    privateKey.publicKey.rawRepresentation.base64EncodedString()
}

private func verifySignature(
    publicKeyString: String,
    fileURL: URL,
    signatureString: String
) throws {
    guard let publicKeyData = Data(base64Encoded: publicKeyString), publicKeyData.count == 32 else {
        throw KeyToolError.message("public key must be base64-encoded 32-byte data")
    }
    guard let signature = Data(base64Encoded: signatureString), signature.count == 64 else {
        throw KeyToolError.message("signature must be base64-encoded 64-byte data")
    }

    var status = stat()
    guard lstat(fileURL.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
        throw KeyToolError.message("signed path must be a regular file, not a symlink")
    }
    let signedData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signature, for: signedData) else {
        throw KeyToolError.message("Ed25519 signature verification failed")
    }
}

private func generatePrivateKey(at fileURL: URL) throws -> String {
    try ensureSecureParentDirectory(for: fileURL)
    let privateKey = Curve25519.Signing.PrivateKey()
    let encodedSeed = privateKey.rawRepresentation.base64EncodedString() + "\n"
    try writeSecureFile(Data(encodedSeed.utf8), to: fileURL)
    return publicKeyString(for: privateKey)
}

private func usage() -> Never {
    fail("usage: sparkle_key_tool.swift generate|public-key <absolute-private-key-path> | verify <public-key> <absolute-file-path> <signature>")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { usage() }
    switch command {
    case "generate":
        guard arguments.count == 2 else { usage() }
        let fileURL = try requireAbsolutePath(arguments[1])
        print(try generatePrivateKey(at: fileURL))
    case "public-key":
        guard arguments.count == 2 else { usage() }
        let fileURL = try requireAbsolutePath(arguments[1])
        print(publicKeyString(for: try loadPrivateKey(from: fileURL)))
    case "verify":
        guard arguments.count == 4 else { usage() }
        let fileURL = try requireAbsolutePath(arguments[2])
        try verifySignature(
            publicKeyString: arguments[1],
            fileURL: fileURL,
            signatureString: arguments[3]
        )
        print("verified")
    default:
        usage()
    }
} catch let error as KeyToolError {
    fail(error.description)
} catch {
    fail(error.localizedDescription)
}
