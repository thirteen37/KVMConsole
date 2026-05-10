import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum NanoKVMPasswordEncryptorError: Error, LocalizedError, Equatable {
    case randomSaltFailed(OSStatus)
    case encryptionFailed(CCCryptorStatus)

    public var errorDescription: String? {
        switch self {
        case .randomSaltFailed(let status): return "Could not generate password salt (\(status))."
        case .encryptionFailed(let status): return "Could not encrypt password (\(status))."
        }
    }
}

public enum NanoKVMPasswordEncryptor {
    private static let passphrase = "nanokvm-sipeed-2024"
    private static let saltedPrefix = Data("Salted__".utf8)

    public static func encrypt(_ password: String) throws -> String {
        var salt = Data(count: 8)
        let status = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NanoKVMPasswordEncryptorError.randomSaltFailed(status)
        }
        return try encrypt(password, salt: salt)
    }

    public static func encrypt(_ password: String, salt: Data) throws -> String {
        precondition(salt.count == 8, "CryptoJS passphrase encryption uses an 8-byte salt")

        let keyAndIV = deriveKeyAndIV(passphrase: Data(passphrase.utf8), salt: salt)
        let ciphertext = try aes256CBCEncrypt(Data(password.utf8), key: keyAndIV.key, iv: keyAndIV.iv)

        var openSSLData = Data()
        openSSLData.append(saltedPrefix)
        openSSLData.append(salt)
        openSSLData.append(ciphertext)

        return encodeURIComponent(openSSLData.base64EncodedString())
    }

    private static func deriveKeyAndIV(passphrase: Data, salt: Data) -> (key: Data, iv: Data) {
        var derived = Data()
        var previous = Data()

        while derived.count < 48 {
            var input = Data()
            input.append(previous)
            input.append(passphrase)
            input.append(salt)
            previous = Data(Insecure.MD5.hash(data: input))
            derived.append(previous)
        }

        return (Data(derived.prefix(32)), Data(derived.dropFirst(32).prefix(16)))
    }

    private static func aes256CBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        let outputLength = plaintext.count + kCCBlockSizeAES128
        var output = Data(count: outputLength)
        var bytesEncrypted = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress!,
                            key.count,
                            ivBytes.baseAddress!,
                            plaintextBytes.baseAddress!,
                            plaintext.count,
                            outputBytes.baseAddress!,
                            outputLength,
                            &bytesEncrypted
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw NanoKVMPasswordEncryptorError.encryptionFailed(status)
        }

        output.removeSubrange(bytesEncrypted..<output.count)
        return output
    }

    private static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
