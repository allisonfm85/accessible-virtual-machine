// SHA512Crypt.swift
// AVM — Accessible Virtual Machine
//
// SHA-512 crypt ("$6$" password hashes), the form Ubuntu's installer
// requires for the account it creates.
//
// WHY THIS EXISTS: Ubuntu's autoinstall answer file takes the new account's
// password only as a crypt hash, never in plain text. macOS has no tool that
// makes one: its openssl is LibreSSL, whose `passwd` has no -6, and libc's
// crypt() is DES only. Shipping a second openssl for one hash is out of
// proportion, so this is Ulrich Drepper's published algorithm
// (https://www.akkadia.org/drepper/SHA-crypt.txt) on CommonCrypto's SHA-512.
//
// VERIFIED against the specification's own test vectors and against
// OpenSSL 3's `openssl passwd -6` output for the same salt and password.
//
// PRIVACY: the password never leaves this function except as the hash, and
// nothing here logs.

import CommonCrypto
import Foundation
import Security

nonisolated enum SHA512Crypt {

    /// The 64 characters crypt uses for its base-64, in crypt's own order.
    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// A "$6$<salt>$<hash>" string for `password`. With no salt, a random
    /// 16-character one is made (the most the format uses). The default
    /// 5000 rounds is the one the format leaves out of the string.
    static func hash(password: String, salt: String? = nil) -> String {
        let saltString = String((salt ?? randomSalt()).prefix(16))
        let key = Array(password.utf8)
        let saltBytes = Array(saltString.utf8)
        let rounds = 5000

        // Digest B: password, salt, password.
        let b = sha512(key + saltBytes + key)

        // Digest A: password, salt, then B for each byte of the password,
        // then B or the password for each bit of the password's length.
        var a = key + saltBytes
        a += repeated(b, toLength: key.count)
        var length = key.count
        while length > 0 {
            a += (length & 1) != 0 ? b : key
            length >>= 1
        }
        var digestA = sha512(a)

        // P: the password, once for each of its bytes.
        var dp: [UInt8] = []
        for _ in 0..<key.count { dp += key }
        let p = repeated(sha512(dp), toLength: key.count)

        // S: the salt, 16 plus A's first byte times.
        var ds: [UInt8] = []
        for _ in 0..<(16 + Int(digestA[0])) { ds += saltBytes }
        let s = repeated(sha512(ds), toLength: saltBytes.count)

        // The rounds.
        for i in 0..<rounds {
            var c: [UInt8] = (i & 1) != 0 ? p : digestA
            if i % 3 != 0 { c += s }
            if i % 7 != 0 { c += p }
            c += (i & 1) != 0 ? digestA : p
            digestA = sha512(c)
        }

        // crypt's base-64 of the final digest, in its fixed byte order.
        let order: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
            (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
            (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
            (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
            (62, 20, 41)
        ]
        var encoded = ""
        for (x, y, z) in order {
            encoded += base64(UInt32(digestA[x]) << 16 | UInt32(digestA[y]) << 8 | UInt32(digestA[z]), count: 4)
        }
        encoded += base64(UInt32(digestA[63]), count: 2)

        return "$6$\(saltString)$\(encoded)"
    }

    private static func sha512(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        _ = bytes.withUnsafeBufferPointer { buffer in
            CC_SHA512(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest
    }

    /// `digest` repeated, then cut, to exactly `length` bytes.
    private static func repeated(_ digest: [UInt8], toLength length: Int) -> [UInt8] {
        var out: [UInt8] = []
        while out.count < length { out += digest }
        return Array(out.prefix(length))
    }

    private static func base64(_ value: UInt32, count: Int) -> String {
        var v = value
        var out = ""
        for _ in 0..<count {
            out.append(alphabet[Int(v & 0x3f)])
            v >>= 6
        }
        return out
    }

    private static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SecRandomCopyBytes does not fail in practice; fall back to the
            // system generator rather than to a fixed salt.
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return String(bytes.map { alphabet[Int($0) & 0x3f] })
    }
}
