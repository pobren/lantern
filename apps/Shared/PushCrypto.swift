// Instant alerts: opening Fastmail's encrypted push notices (RFC 8291, "aes128gcm" from RFC 8188).
// Fastmail encrypts each notice for this device's own key, so the relay that passes it on can't read it.
// Shared by the app (which reads Fastmail's confirmation code) and the notification extension.

import Foundation
import CryptoKit

enum PushCrypto {
    enum Failure: Error { case tooShort, badHeader, badPadding }

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// The plain text of one notice, given this device's private key and 16 byte auth secret.
    static func decrypt(_ body: Data, key: P256.KeyAgreement.PrivateKey, auth: Data) throws -> Data {
        let b = [UInt8](body)
        // Header: salt (16), record size (4), key id length (1), key id (the sender's public key, 65).
        guard b.count > 21 else { throw Failure.tooShort }
        let idLength = Int(b[20])
        guard idLength == 65, b.count > 21 + idLength + 16 else { throw Failure.badHeader }
        let salt = Data(b[0..<16])
        let senderKeyBytes = Data(b[21..<(21 + idLength)])
        let sealed = Data(b[(21 + idLength)...])

        let senderKey = try P256.KeyAgreement.PublicKey(x963Representation: senderKeyBytes)
        let shared = try key.sharedSecretFromKeyAgreement(with: senderKey)
        let ecdh = shared.withUnsafeBytes { Data($0) }
        let myKey = key.publicKey.x963Representation

        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(myKey)
        keyInfo.append(senderKeyBytes)
        keyInfo.append(1)
        let ikm = hmac(hmac(auth, ecdh), keyInfo)
        let prk = hmac(salt, ikm)

        var cekInfo = Data("Content-Encoding: aes128gcm".utf8)
        cekInfo.append(contentsOf: [0, 1])
        var nonceInfo = Data("Content-Encoding: nonce".utf8)
        nonceInfo.append(contentsOf: [0, 1])
        let cek = hmac(prk, cekInfo).prefix(16)
        let nonce = hmac(prk, nonceInfo).prefix(12)

        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(nonce)),
                                        ciphertext: Data(sealed.dropLast(16)), tag: Data(sealed.suffix(16)))
        var plain = [UInt8](try AES.GCM.open(box, using: SymmetricKey(data: Data(cek))))
        // The last record ends with a 2, then any padding zeros.
        while plain.last == 0 { plain.removeLast() }
        guard plain.last == 2 else { throw Failure.badPadding }
        plain.removeLast()
        return Data(plain)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
