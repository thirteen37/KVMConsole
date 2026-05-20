import XCTest
@testable import KVMCore

final class RFBAuthenticationTests: XCTestCase {
    func test_vncDESKeyReversesPasswordBitsAndPadsToEightBytes() {
        XCTAssertEqual(
            RFBAuthentication.vncDESKey(password: "pass"),
            Data([0x0e, 0x86, 0xce, 0xce, 0, 0, 0, 0])
        )
    }

    func test_vncChallengeResponseMatchesKnownVector() throws {
        let challenge = Data((0x00...0x0f).map(UInt8.init))
        let response = try RFBAuthentication.vncChallengeResponse(
            password: "password",
            challenge: challenge
        )

        XCTAssertEqual(
            response,
            Data([0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb, 0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2])
        )
    }

    func test_authSelectionPrefersImplementedAppleDHThenFallsBackToVNC() throws {
        XCTAssertEqual(
            try RFBAuthentication.selectSecurityType(
                offered: [.appleSecurity33, .appleSecurity35, .appleDiffieHellman30],
                profile: .appleScreenSharing
            ),
            .appleDiffieHellman30
        )
        XCTAssertEqual(
            try RFBAuthentication.selectSecurityType(
                offered: [.vncAuthentication, .appleSecurity33],
                profile: .appleScreenSharing
            ),
            .vncAuthentication
        )
        XCTAssertEqual(
            try RFBAuthentication.selectSecurityType(
                offered: [.appleSecurity36, .vncAuthentication],
                profile: .appleScreenSharing
            ),
            .vncAuthentication
        )
    }

    func test_appleDiffieHellmanResponseHandlesAppleSizedKeyMaterial() throws {
        let modulus = try Data(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B225
        14A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6
        F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE653
        81FFFFFFFFFFFFFFFF
        """)
        let serverPublicKey = Data(repeating: 0x03, count: modulus.count)

        let started = Date()
        let response = try RFBAuthentication.appleDiffieHellmanResponse(
            username: "user",
            password: "password",
            generator: 2,
            modulus: modulus,
            serverPublicKey: serverPublicKey
        )

        XCTAssertEqual(response.count, 128 + modulus.count)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func test_appleDiffieHellmanResponseUsesCorrectAppleSizedPublicKey() throws {
        let modulus = try Data(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B225
        14A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6
        F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE653
        81FFFFFFFFFFFFFFFF
        """)
        let privateKey = try Data(hex: """
        000102030405060708090A0B0C0D0E0F
        101112131415161718191A1B1C1D1E1F
        202122232425262728292A2B2C2D2E2F
        303132333435363738393A3B3C3D3E3F
        """)
        let expectedPublicKey = try Data(hex: """
        0BD459E79B6C61D44A5B4A8093094433AF58DD6760AEA0C719DCFEDE25B8AFB5
        4772843D5FAC44A9FED1A58F8CFA8396B8839A068ACFE36001D0F2A61A015F8
        CB5F7511D3142010F107EBE8DE54FCF363A817219E6B561CBF074D155285BDC
        98F00DDA4CEAA736E5FCDF8B437F7D0D8D3F6B6C2EB6FA891B749F10C9CE27CC3A
        """)

        let response = try RFBAuthentication.appleDiffieHellmanResponse(
            username: "user",
            password: "password",
            generator: 2,
            modulus: modulus,
            serverPublicKey: Data([0x03]).leftPadded(to: modulus.count),
            privateKey: privateKey
        )

        let publicKey = Data(response.suffix(modulus.count))
        XCTAssertEqual(publicKey, expectedPublicKey, publicKey.hexEncodedString())
    }

    func test_bigUIntModExpMatchesAppleSizedSharedSecretVector() throws {
        let modulus = RFBBigUInt(bigEndian: try Data(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B225
        14A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6
        F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE653
        81FFFFFFFFFFFFFFFF
        """))
        let exponent = RFBBigUInt(bigEndian: try Data(hex: """
        000102030405060708090A0B0C0D0E0F
        101112131415161718191A1B1C1D1E1F
        202122232425262728292A2B2C2D2E2F
        303132333435363738393A3B3C3D3E3F
        """))
        let expectedSharedSecret = try Data(hex: """
        134738A80581DB221034B7E38FCABB8A7197718B998EC3CFB1E03420D6F5DBC1
        E6D1E34FBBDD4998DA3E829DC8A6C05D120CF3C48BF96EC2166AD21214F153
        2B04D3CA89A7D63C5FACA695DB302E4CF6253BF9B632B3DBA4CCE02F7B084
        12485C04E9DD4A0AE455B44EF0E4486C2B52AE259E18C77630D7B149FBF34004AAF87
        """)

        let sharedSecret = RFBBigUInt.modExp(
            base: RFBBigUInt(3),
            exponent: exponent,
            modulus: modulus
        ).bigEndianData(paddedTo: 128)

        XCTAssertEqual(sharedSecret, expectedSharedSecret, sharedSecret.hexEncodedString())
    }
}

private extension Data {
    init(hex: String) throws {
        let compact = hex.filter { !$0.isWhitespace && !$0.isNewline }
        guard compact.count.isMultiple(of: 2) else {
            throw RFBError.malformedMessage("hex input has odd length")
        }

        var bytes: [UInt8] = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw RFBError.malformedMessage("invalid hex input")
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    func leftPadded(to byteCount: Int) -> Data {
        if count >= byteCount {
            return Data(suffix(byteCount))
        }
        return Data(repeating: 0, count: byteCount - count) + self
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
