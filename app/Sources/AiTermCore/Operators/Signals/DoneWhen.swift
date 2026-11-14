import Foundation

public enum DoneWhen: Codable, Equatable, Sendable {
    case operatorJudges
    case hasReviewer
    case approved
    case threadsResolved
    case merged
    case ticketStatus(String)
    case myReviewPosted
    case mergedOrClosed
    case unknown(JSONValue)

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        switch raw["kind"]?.stringValue {
        case "operatorJudges": self = .operatorJudges
        case "hasReviewer": self = .hasReviewer
        case "approved": self = .approved
        case "threadsResolved": self = .threadsResolved
        case "merged": self = .merged
        case "ticketStatus":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing DoneWhen value")) }
            self = .ticketStatus(try value.decode(String.self))
        case "myReviewPosted": self = .myReviewPosted
        case "mergedOrClosed": self = .mergedOrClosed
        default: self = .unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        let raw: JSONValue
        switch self {
        case .operatorJudges: raw = ["kind": "operatorJudges"]
        case .hasReviewer: raw = ["kind": "hasReviewer"]
        case .approved: raw = ["kind": "approved"]
        case .threadsResolved: raw = ["kind": "threadsResolved"]
        case .merged: raw = ["kind": "merged"]
        case .ticketStatus(let value): raw = ["kind": "ticketStatus", "value": try JSONValue(encoding: value)]
        case .myReviewPosted: raw = ["kind": "myReviewPosted"]
        case .mergedOrClosed: raw = ["kind": "mergedOrClosed"]
        case .unknown(let value): raw = value
        }
        try raw.encode(to: encoder)
    }
}
