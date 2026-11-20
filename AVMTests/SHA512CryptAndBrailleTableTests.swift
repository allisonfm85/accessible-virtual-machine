//
//  SHA512CryptAndBrailleTableTests.swift
//  AVMTests
//
//  Two small pure pieces: the $6$ password hash the Ubuntu answer file
//  carries, and the BRLTTY braille ID table.
//

import Testing

@Suite("SHA-512 crypt")
struct SHA512CryptTests {

    // Reference values from `openssl passwd -6 -salt <salt> <password>`.
    // The first two are also the test vectors in Ulrich Drepper's
    // SHA-crypt specification.

    @Test("matches the specification's test vector")
    func specVector() {
        #expect(SHA512Crypt.hash(password: "Hello world!", salt: "saltstring")
                == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
    }

    @Test("cuts a salt longer than 16 characters, as crypt does")
    func longSalt() {
        #expect(SHA512Crypt.hash(password: "This is just a test", salt: "toolongsaltstring")
                == "$6$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0")
    }

    @Test("hashes a non-ASCII password as UTF-8")
    func utf8Password() {
        #expect(SHA512Crypt.hash(password: "mot de passe é", salt: "a/b.Z9")
                == "$6$a/b.Z9$GR3cnAfEYX8xqMtR.GJs7Ye/r9ZYPzg1hiKZRqTV7.16c4dr3YpRU6ZWT0vJyNcEwBYZ9YY5OomkGOV71Ry3h/")
    }

    @Test("makes a fresh 16-character crypt salt when none is given")
    func randomSalt() {
        let a = SHA512Crypt.hash(password: "x")
        let b = SHA512Crypt.hash(password: "x")
        #expect(a != b)
        let parts = a.split(separator: "$", omittingEmptySubsequences: false)
        #expect(parts.count == 4)
        #expect(parts[1] == "6")
        #expect(parts[2].count == 16)
        let alphabet = Set("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        #expect(parts[2].allSatisfy { alphabet.contains($0) })
        #expect(parts[3].count == 86)
    }
}

@Suite("Braille display table")
struct BrailleTableTests {

    @Test("recognizes a braille-only ID")
    func brailleID() {
        #expect(USBBrailleDeviceTable.match(vendorID: 0x0403, productID: 0xfe70) == .braille)
    }

    @Test("flags a generic serial chip that braille displays share")
    func genericChip() {
        #expect(USBBrailleDeviceTable.match(vendorID: 0x0403, productID: 0x6001) == .genericChip)
        #expect(USBBrailleDeviceTable.match(vendorID: 0x10c4, productID: 0xea60) == .genericChip)
    }

    @Test("leaves other devices alone")
    func unknownID() {
        #expect(USBBrailleDeviceTable.match(vendorID: 0x0909, productID: 0x004d) == nil)
    }
}
