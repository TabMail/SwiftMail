import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import CoreFoundation
#endif

extension String {
    /// Encodes the string using quoted-printable encoding
    public func quotedPrintableEncoded() -> String {
        struct Token {
            let value: String
            let isLiteralWhitespace: Bool
        }

        let maxLineLength = 76
        let maxContentLengthForSoftBreak = maxLineLength - 1 // Reserve one char for '=' soft-break marker

        let normalizedLineEndings = self
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let logicalLines = normalizedLineEndings.split(separator: "\n", omittingEmptySubsequences: false)

        func token(for byte: UInt8, isEndOfLogicalLine: Bool) -> Token {
            switch byte {
            case UInt8(ascii: "="):
                return Token(value: "=3D", isLiteralWhitespace: false)
            case UInt8(ascii: " "):
                if isEndOfLogicalLine {
                    return Token(value: "=20", isLiteralWhitespace: false)
                }
                return Token(value: " ", isLiteralWhitespace: true)
            case UInt8(ascii: "\t"):
                if isEndOfLogicalLine {
                    return Token(value: "=09", isLiteralWhitespace: false)
                }
                return Token(value: "\t", isLiteralWhitespace: true)
            case 33...60, 62...126:
                return Token(value: String(UnicodeScalar(byte)), isLiteralWhitespace: false)
            default:
                return Token(value: String(format: "=%02X", byte), isLiteralWhitespace: false)
            }
        }

        func encodeLogicalLine(_ line: Substring) -> String {
            let bytes = Array(line.utf8)
            var encodedTokens: [Token] = []
            encodedTokens.reserveCapacity(bytes.count)

            for (index, byte) in bytes.enumerated() {
                encodedTokens.append(token(for: byte, isEndOfLogicalLine: index == bytes.count - 1))
            }

            var wrappedLines: [String] = []
            var currentTokens: [Token] = []
            var currentLength = 0

            func flushWithSoftBreak() {
                guard !currentTokens.isEmpty else {
                    return
                }

                var carriedTokens: [Token] = []

                while let last = currentTokens.last, last.isLiteralWhitespace {
                    _ = currentTokens.popLast()
                    currentLength -= last.value.count

                    let encodedWhitespace = Token(
                        value: last.value == " " ? "=20" : "=09",
                        isLiteralWhitespace: false
                    )

                    if currentLength + encodedWhitespace.value.count <= maxContentLengthForSoftBreak {
                        currentTokens.append(encodedWhitespace)
                        currentLength += encodedWhitespace.value.count
                    } else {
                        carriedTokens.insert(encodedWhitespace, at: 0)
                    }
                }

                wrappedLines.append(currentTokens.map(\.value).joined() + "=")
                currentTokens = carriedTokens
                currentLength = carriedTokens.reduce(0) { $0 + $1.value.count }
            }

            for token in encodedTokens {
                if currentLength + token.value.count > maxContentLengthForSoftBreak {
                    flushWithSoftBreak()
                }

                currentTokens.append(token)
                currentLength += token.value.count
            }

            wrappedLines.append(currentTokens.map(\.value).joined())
            return wrappedLines.joined(separator: "\r\n")
        }

        return logicalLines.map(encodeLogicalLine).joined(separator: "\r\n")
    }

    /// Decodes a quoted-printable encoded string by removing "soft line" breaks and replacing all
    /// quoted-printable escape sequences with the matching characters.
    /// - Returns: The decoded string, or `nil` for invalid input.
    public func decodeQuotedPrintable() -> String? {
        if let decoded = decodeQuotedPrintable(encoding: .utf8) {
            return decoded
        }
        return decodeQuotedPrintable(encoding: .isoLatin1)
    }

    /// Decodes a quoted-printable encoded string but tolerates invalid sequences by leaving them as-is
    /// in the output. This is useful for handling real-world messages that might contain malformed
    /// quoted-printable data.
    /// - Returns: The decoded string with invalid sequences preserved.
    public func decodeQuotedPrintableLossy() -> String {
        return decodeQuotedPrintableLossy(encoding: .utf8)
    }

    /// Decodes a quoted-printable encoded string with a specific encoding
    /// - Parameter enc: The target string encoding. The default is UTF-8.
    /// - Returns: The decoded string, or `nil` for invalid input.
    public func decodeQuotedPrintable(encoding enc: String.Encoding) -> String? {
        // Remove soft line breaks (=<CR><LF> or =<LF>)
        let withoutSoftBreaks = self.replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")

        var bytes = Data()
        var index = withoutSoftBreaks.startIndex

        while index < withoutSoftBreaks.endIndex {
            let char = withoutSoftBreaks[index]

            if char == "=" {
                let nextIndex = withoutSoftBreaks.index(after: index)
                guard nextIndex < withoutSoftBreaks.endIndex else {
                    return nil
                }
                let nextNextIndex = withoutSoftBreaks.index(after: nextIndex)
                guard nextNextIndex < withoutSoftBreaks.endIndex else {
                    return nil
                }
                let hex = String(withoutSoftBreaks[nextIndex...nextNextIndex])
                guard let byte = UInt8(hex, radix: 16) else {
                    return nil
                }
                bytes.append(byte)
                index = withoutSoftBreaks.index(after: nextNextIndex)
            } else {
                if let ascii = char.asciiValue {
                    bytes.append(ascii)
                } else if let data = String(char).data(using: enc) {
                    bytes.append(contentsOf: data)
                }
                index = withoutSoftBreaks.index(after: index)
            }
        }

        return String(data: bytes, encoding: enc)
    }

    /// Decodes a quoted-printable encoded string with a specific encoding, tolerating invalid sequences
    /// by preserving them in the output.
    /// - Parameter enc: The target string encoding. The default is UTF-8.
    /// - Returns: The decoded string with invalid sequences preserved.
    public func decodeQuotedPrintableLossy(encoding enc: String.Encoding) -> String {
        // Remove soft line breaks
        let withoutSoftBreaks = self.replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")

        var bytes = Data()
        var index = withoutSoftBreaks.startIndex

        while index < withoutSoftBreaks.endIndex {
            let char = withoutSoftBreaks[index]

            if char == "=" {
                let nextIndex = withoutSoftBreaks.index(after: index)
                if nextIndex < withoutSoftBreaks.endIndex {
                    let nextNextIndex = withoutSoftBreaks.index(after: nextIndex)
                    if nextNextIndex < withoutSoftBreaks.endIndex {
                        let hex = String(withoutSoftBreaks[nextIndex...nextNextIndex])
                        if let byte = UInt8(hex, radix: 16) {
                            bytes.append(byte)
                            index = withoutSoftBreaks.index(after: nextNextIndex)
                            continue
                        }
                    }
                }
                // Invalid or incomplete sequence: treat '=' literally
                bytes.append(UInt8(ascii: "="))
                index = withoutSoftBreaks.index(after: index)
            } else {
                if let ascii = char.asciiValue {
                    bytes.append(ascii)
                } else if let data = String(char).data(using: enc) {
                    bytes.append(contentsOf: data)
                }
                index = withoutSoftBreaks.index(after: index)
            }
        }

        return String(data: bytes, encoding: enc) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Decode a MIME-encoded header string
    /// - Returns: The decoded string
    public func decodeMIMEHeader() -> String {
        let pattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }

        let matches = regex.matches(in: self, options: [], range: NSRange(self.startIndex..., in: self))

        var result = ""
        var lastIndex = self.startIndex
        var lastWasEncodedWord = false

        for match in matches {
            guard let range = Range(match.range, in: self),
                  let charsetRange = Range(match.range(at: 1), in: self),
                  let encodingRange = Range(match.range(at: 2), in: self),
                  let textRange = Range(match.range(at: 3), in: self) else {
                continue
            }

            let between = self[lastIndex..<range.lowerBound]
            if !(lastWasEncodedWord && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += String(between)
            }

            let charset = String(self[charsetRange])
            let encoding = String(self[encodingRange]).uppercased()
            var encodedText = String(self[textRange])
            var decodedText = ""

            let stringEncoding = String.encodingFromCharset(charset)

            if encoding == "B" {
                if let data = Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters),
                   let decoded = String(data: data, encoding: stringEncoding) {
                    decodedText = decoded
                } else if let data = Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters),
                          let decoded = String(data: data, encoding: .utf8) {
                    decodedText = decoded
                }
            } else if encoding == "Q" {
                // In MIME headers, underscores represent spaces
                encodedText = encodedText.replacingOccurrences(of: "_", with: " ")
                if let decoded = encodedText.decodeQuotedPrintable(encoding: stringEncoding) {
                    decodedText = decoded
                } else if let decoded = encodedText.decodeQuotedPrintable() {
                    decodedText = decoded
                }
            }

            result += decodedText
            lastIndex = range.upperBound
            lastWasEncodedWord = true
        }

        let remainder = self[lastIndex...]
        result += String(remainder)

        return result
    }

    /// Detects the charset from content and returns the appropriate String.Encoding
    /// - Returns: The detected String.Encoding, or .utf8 as fallback
    public func detectCharsetEncoding() -> String.Encoding {
        // Look for Content-Type header with charset
        let contentTypePattern = "Content-Type:.*?charset=([^\\s;\"']+)"
        if let range = self.range(of: contentTypePattern, options: .regularExpression, range: nil, locale: nil),
           let charsetRange = self[range].range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
            let charsetString = self[charsetRange].replacingOccurrences(of: "charset=", with: "")
            return String.encodingFromCharset(charsetString)
        }

        // Look for meta tag with charset
        let metaPattern = "<meta[^>]*charset=([^\\s;\"'/>]+)"
        if let range = self.range(of: metaPattern, options: .regularExpression, range: nil, locale: nil),
           let charsetRange = self[range].range(of: "charset=([^\\s;\"'/>]+)", options: .regularExpression) {
            let charsetString = self[charsetRange].replacingOccurrences(of: "charset=", with: "")
            return String.encodingFromCharset(charsetString)
        }

        // Default to UTF-8
        return .utf8
    }

    /// Decode quoted-printable content in message bodies
    /// - Returns: The decoded content
    public func decodeQuotedPrintableContent() -> String {
        // Split the content into lines
        let lines = self.components(separatedBy: .newlines)
        var inBody = false
        var bodyContent = ""
        var headerContent = ""
        var contentEncoding: String.Encoding = .utf8

        // Process each line
        for line in lines {
            if !inBody {
                // Check if we've reached the end of headers
                if line.isEmpty {
                    inBody = true
                    headerContent += line + "\n"
                    continue
                }

                // Add header line
                headerContent += line + "\n"

                // Check for Content-Type header with charset
                if line.lowercased().contains("content-type:") && line.lowercased().contains("charset=") {
                    if let range = line.range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
                        let charsetString = line[range].replacingOccurrences(of: "charset=", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                        contentEncoding = String.encodingFromCharset(charsetString)
                    }
                }

                // Check if this is a Content-Transfer-Encoding header
                if line.lowercased().contains("content-transfer-encoding:") &&
                   line.lowercased().contains("quoted-printable") {
                    // Found quoted-printable encoding
                    inBody = false
                }
            } else {
                // Add body line
                bodyContent += line + "\n"
            }
        }

        // If we found quoted-printable encoding, decode the body
        if !bodyContent.isEmpty {
            // Decode the body content with the detected encoding
            if let decodedBody = bodyContent.decodeQuotedPrintable(encoding: contentEncoding) {
                return headerContent + decodedBody
            } else if let decodedBody = bodyContent.decodeQuotedPrintable() {
                // Fallback to UTF-8 if the specified charset fails
                return headerContent + decodedBody
            }
        }

        // If we didn't find quoted-printable encoding or no body content,
        // try to decode the entire content with the detected charset
        if let decodedContent = self.decodeQuotedPrintable(encoding: contentEncoding) {
            return decodedContent
        }

        // Last resort: try with UTF-8
        return self.decodeQuotedPrintable() ?? self
    }
}
