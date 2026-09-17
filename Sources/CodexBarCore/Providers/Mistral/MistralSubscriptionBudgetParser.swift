import Foundation

struct MistralSubscriptionBudgets: Codable, Equatable, Hashable, Sendable {
    let api: MistralSubscriptionBudget
    let vibe: MistralSubscriptionBudget?
}

struct MistralSubscriptionBudget: Codable, Equatable, Hashable, Sendable {
    let usagePercentage: Double
    let limit: Double
    let currencyCode: String
    let resetsAt: Date?
    let payAsYouGoEnabled: Bool

    var usedAmount: Double {
        self.limit * self.usagePercentage / 100
    }

    var remainingAmount: Double {
        max(self.limit - self.usedAmount, 0)
    }
}

enum MistralSubscriptionBudgetParser {
    private struct RawBudgets: Decodable, Equatable, Hashable {
        let vibe: RawBudget?
        let api: RawBudget

        enum CodingKeys: String, CodingKey {
            case vibe = "vibe_budget"
            case api = "api_budget"
        }
    }

    private struct RawBudget: Decodable, Equatable, Hashable {
        let usagePercentage: Double
        let initialBudget: Double
        let currency: String
        let resetAt: String?
        let paygEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case usagePercentage = "usage_percentage"
            case initialBudget = "initial_budget"
            case currency
            case resetAt = "reset_at"
            case paygEnabled = "payg_enabled"
        }
    }

    enum ParseError: Error, Equatable {
        case budgetNotFound
        case ambiguousBudgets
        case invalidBudget
    }

    private static let flightPushMarker = Data("self.__next_f.push(".utf8)

    static func parse(html: String) throws -> MistralSubscriptionBudgets {
        let stream = try self.flightChunks(in: html).joined()
        var matches: [RawBudgets] = []
        for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            self.collectJSONRoots(in: Data(line[line.index(after: colon)...].utf8)) { root in
                self.collectBudgets(in: root, into: &matches)
            }
        }

        let unique = Array(Set(matches))
        guard let raw = unique.first else { throw ParseError.budgetNotFound }
        guard unique.count == 1 else { throw ParseError.ambiguousBudgets }
        return try MistralSubscriptionBudgets(
            api: self.budget(from: raw.api),
            vibe: raw.vibe.map { try self.budget(from: $0) })
    }

    private static func flightChunks(in html: String) throws -> [String] {
        let data = Data(html.utf8)
        var cursor = data.startIndex
        var chunks: [String] = []
        while cursor < data.endIndex,
              let markerRange = data.range(of: self.flightPushMarker, in: cursor..<data.endIndex)
        {
            var start = markerRange.upperBound
            while start < data.endIndex, self.isWhitespace(data[start]) {
                start = data.index(after: start)
            }
            guard start < data.endIndex, data[start] == UInt8(ascii: "[") else {
                cursor = markerRange.upperBound
                continue
            }
            guard let end = self.jsonContainerEnd(in: data, from: start) else {
                cursor = data.index(after: start)
                continue
            }
            let encoded = data.subdata(in: start..<end)
            if let array = try? JSONSerialization.jsonObject(with: encoded) as? [Any],
               array.count >= 2,
               let channel = array[0] as? Int,
               channel == 1,
               let chunk = array[1] as? String
            {
                chunks.append(chunk)
            }
            cursor = end
        }
        return chunks
    }

    private static func collectJSONRoots(in data: Data, body: (Any) -> Void) {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let start = data[cursor...].firstIndex(where: {
                $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "{")
            }) else {
                return
            }
            guard let end = self.jsonContainerEnd(in: data, from: start) else { return }
            let candidate = data.subdata(in: start..<end)
            if let root = try? JSONSerialization.jsonObject(with: candidate) {
                body(root)
                cursor = end
            } else {
                cursor = data.index(after: start)
            }
        }
    }

    private static func collectBudgets(in value: Any, into results: inout [RawBudgets]) {
        if let dictionary = value as? [String: Any] {
            if let budget = dictionary["budget"] as? [String: Any],
               JSONSerialization.isValidJSONObject(budget),
               let data = try? JSONSerialization.data(withJSONObject: budget),
               let decoded = try? JSONDecoder().decode(RawBudgets.self, from: data)
            {
                results.append(decoded)
            }
            for child in dictionary.values {
                self.collectBudgets(in: child, into: &results)
            }
        } else if let array = value as? [Any] {
            for child in array {
                self.collectBudgets(in: child, into: &results)
            }
        }
    }

    private static func jsonContainerEnd(in data: Data, from start: Data.Index) -> Data.Index? {
        guard start < data.endIndex else { return nil }
        var expectedClosers: [UInt8] = []
        var inString = false
        var escaped = false
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "["):
                    expectedClosers.append(UInt8(ascii: "]"))
                case UInt8(ascii: "{"):
                    expectedClosers.append(UInt8(ascii: "}"))
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    guard expectedClosers.last == byte else { return nil }
                    expectedClosers.removeLast()
                    if expectedClosers.isEmpty { return data.index(after: index) }
                default:
                    break
                }
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func budget(from raw: RawBudget) throws -> MistralSubscriptionBudget {
        let currency = raw.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard raw.usagePercentage.isFinite,
              raw.usagePercentage >= 0,
              raw.initialBudget.isFinite,
              raw.initialBudget >= 0,
              !currency.isEmpty
        else {
            throw ParseError.invalidBudget
        }
        return MistralSubscriptionBudget(
            usagePercentage: raw.usagePercentage,
            limit: raw.initialBudget,
            currencyCode: currency,
            resetsAt: ISO8601DateParser.parse(raw.resetAt),
            payAsYouGoEnabled: raw.paygEnabled)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 13 || byte == 32
    }
}
