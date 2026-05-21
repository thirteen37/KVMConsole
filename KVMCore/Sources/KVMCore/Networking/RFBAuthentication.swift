import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum RFBAuthentication {
    public static func selectSecurityType(
        offered: [RFBSecurityType],
        profile: RFBSessionProfile
    ) throws -> RFBSecurityType {
        try profile.securityPreference.choose(from: offered)
    }

    public static func vncChallengeResponse(password: String, challenge: Data) throws -> Data {
        guard challenge.count == kCCBlockSizeDES * 2 else {
            throw RFBError.malformedMessage("VNC challenge must be 16 bytes")
        }

        let key = vncDESKey(password: password)
        return try desECBEncrypt(challenge, key: key)
    }

    public static func vncDESKey(password: String) -> Data {
        let passwordBytes = Array(password.utf8.prefix(8))
        var key = [UInt8](repeating: 0, count: kCCKeySizeDES)
        for index in 0..<min(passwordBytes.count, key.count) {
            key[index] = reverseBits(passwordBytes[index])
        }
        return Data(key)
    }

    public static func appleDiffieHellmanResponse(
        username: String,
        password: String,
        generator: UInt16,
        modulus: Data,
        serverPublicKey: Data
    ) throws -> Data {
        try appleDiffieHellmanResponse(
            username: username,
            password: password,
            generator: generator,
            modulus: modulus,
            serverPublicKey: serverPublicKey,
            privateKey: nil
        )
    }

    static func appleDiffieHellmanResponse(
        username: String,
        password: String,
        generator: UInt16,
        modulus: Data,
        serverPublicKey: Data,
        privateKey suppliedPrivateKey: Data?
    ) throws -> Data {
        guard modulus.count == serverPublicKey.count, !modulus.isEmpty else {
            throw RFBError.malformedMessage("invalid Apple DH key material")
        }

        let modulusNumber = RFBBigUInt(bigEndian: modulus)
        let serverPublicNumber = RFBBigUInt(bigEndian: serverPublicKey)
        let privateKey = try suppliedPrivateKey ?? randomPrivateKey(byteCount: appleDHPrivateKeyByteCount(modulusByteCount: modulus.count))
        let privateNumber = RFBBigUInt(bigEndian: privateKey)
        let publicNumber = RFBBigUInt.modExp(
            base: RFBBigUInt(UInt32(generator)),
            exponent: privateNumber,
            modulus: modulusNumber
        )
        let sharedSecret = RFBBigUInt.modExp(
            base: serverPublicNumber,
            exponent: privateNumber,
            modulus: modulusNumber
        ).bigEndianData(paddedTo: modulus.count)
        let aesKey = md5(sharedSecret)
        let encryptedCredentials = try aesECBEncrypt(
            appleCredentialBlock(username: username, password: password),
            key: aesKey
        )
        var response = Data()
        response.append(encryptedCredentials)
        response.append(publicNumber.bigEndianData(paddedTo: modulus.count))
        return response
    }

    private static func desECBEncrypt(_ data: Data, key: Data) throws -> Data {
        guard data.count.isMultiple(of: kCCBlockSizeDES), key.count == kCCKeySizeDES else {
            throw RFBError.malformedMessage("invalid DES input")
        }

        var output = Data(count: data.count + kCCBlockSizeDES)
        var bytesWritten = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress,
                        kCCKeySizeDES,
                        nil,
                        dataBuffer.baseAddress,
                        data.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &bytesWritten
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw RFBError.authenticationFailed("DES encryption failed with status \(status).")
        }
        output.removeSubrange(bytesWritten..<output.count)
        return output
    }

    private static func aesECBEncrypt(_ data: Data, key: Data) throws -> Data {
        guard data.count.isMultiple(of: kCCBlockSizeAES128), key.count == kCCKeySizeAES128 else {
            throw RFBError.malformedMessage("invalid AES input")
        }

        var output = Data(count: data.count + kCCBlockSizeAES128)
        var bytesWritten = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress,
                        kCCKeySizeAES128,
                        nil,
                        dataBuffer.baseAddress,
                        data.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &bytesWritten
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw RFBError.authenticationFailed("AES encryption failed with status \(status).")
        }
        output.removeSubrange(bytesWritten..<output.count)
        return output
    }

    private static func appleCredentialBlock(username: String, password: String) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        let usernameBytes = Array(username.utf8.prefix(63))
        let passwordBytes = Array(password.utf8.prefix(63))
        bytes.replaceSubrange(0..<usernameBytes.count, with: usernameBytes)
        bytes.replaceSubrange(64..<(64 + passwordBytes.count), with: passwordBytes)
        return Data(bytes)
    }

    private static func appleDHPrivateKeyByteCount(modulusByteCount: Int) -> Int {
        min(64, modulusByteCount)
    }

    private static func randomPrivateKey(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw RFBError.authenticationFailed("failed to generate Apple DH private key")
        }
        return Data(bytes)
    }

    private static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    private static func reverseBits(_ value: UInt8) -> UInt8 {
        var source = value
        var result: UInt8 = 0
        for _ in 0..<8 {
            result = (result << 1) | (source & 1)
            source >>= 1
        }
        return result
    }
}
