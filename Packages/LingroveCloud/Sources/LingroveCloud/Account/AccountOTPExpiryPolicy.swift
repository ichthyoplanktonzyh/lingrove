import Foundation

/// A display-only upper bound for the existing signed OTP envelope. The auth service may return
/// the same challenge during resend throttling, so request time alone must not renew its TTL.
/// Reading the envelope's timestamp never authenticates a token or identity: the hint can only
/// shorten local eligibility, and the server still validates signature, CSRF, code and expiry.
public nonisolated enum AccountOTPExpiryPolicy {
    public static func expiry(token: String, requestedAt: Date) -> Date {
        let upperBound = requestedAt.addingTimeInterval(180)
        guard let encoded = token.split(separator: ".", omittingEmptySubsequences: false).first,
              encoded.utf8.count <= 32_768 else { return upperBound }
        var base64 = String(encoded).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let hint = try? JSONDecoder().decode(AccountOTPTimestampHint.self, from: data),
              hint.createdAtMilliseconds.isFinite, hint.createdAtMilliseconds > 0 else { return upperBound }
        return min(upperBound, Date(timeIntervalSince1970: hint.createdAtMilliseconds / 1_000 + 180))
    }
}

/// One ephemeral decoder value names the existing envelope's millisecond field without treating
/// any other payload field as trusted account information.
private struct AccountOTPTimestampHint: Decodable {
    let createdAtMilliseconds: Double
    enum CodingKeys: String, CodingKey { case createdAtMilliseconds = "t" }
}
