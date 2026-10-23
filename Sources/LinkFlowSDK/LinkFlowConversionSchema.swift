import Foundation

// MARK: - Conversion-value schema (platform independent)

/// The SKAdNetwork / AdAttributionKit conversion-value schema approved in the
/// LinkFlow dashboard, fetched from `GET /api/skan/conversion-schema`.
///
/// The same document decodes postbacks on the server, so the value written on
/// device and the revenue range reported in the dashboard can never disagree.
/// Evaluation mirrors `ConversionSchema.Evaluate` on the server exactly:
///
///     fine   = max(highest band with minRevenue ≤ revenue, highest floor of events seen)
///     coarse = high   if revenue ≥ coarseHighMinRevenue
///              medium if revenue ≥ coarseMediumMinRevenue or a medium event was seen
///              low    otherwise
public struct ConversionSchema: Codable, Equatable {
    public struct RevenueBand: Codable, Equatable {
        public let fineValue: Int
        public let minRevenue: Double

        public init(fineValue: Int, minRevenue: Double) {
            self.fineValue = fineValue
            self.minRevenue = minRevenue
        }
    }

    public var revenueBands: [RevenueBand]
    public var eventFloors: [String: Int]
    public var coarseMediumMinRevenue: Double
    public var coarseHighMinRevenue: Double
    public var mediumEvents: [String]
    public var measurementWindowHours: Int
    public var lockWindowAtRevenue: Double?

    public init(
        revenueBands: [RevenueBand] = [],
        eventFloors: [String: Int] = [:],
        coarseMediumMinRevenue: Double = 0.01,
        coarseHighMinRevenue: Double = 10,
        mediumEvents: [String] = [],
        measurementWindowHours: Int = 48,
        lockWindowAtRevenue: Double? = nil
    ) {
        self.revenueBands = revenueBands
        self.eventFloors = eventFloors
        self.coarseMediumMinRevenue = coarseMediumMinRevenue
        self.coarseHighMinRevenue = coarseHighMinRevenue
        self.mediumEvents = mediumEvents
        self.measurementWindowHours = measurementWindowHours
        self.lockWindowAtRevenue = lockWindowAtRevenue
    }

    // Tolerant decoding: absent fields take the server's defaults, so a schema
    // written by a newer dashboard (with fields this SDK does not know) still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revenueBands = try c.decodeIfPresent([RevenueBand].self, forKey: .revenueBands) ?? []
        eventFloors = try c.decodeIfPresent([String: Int].self, forKey: .eventFloors) ?? [:]
        coarseMediumMinRevenue = try c.decodeIfPresent(Double.self, forKey: .coarseMediumMinRevenue) ?? 0.01
        coarseHighMinRevenue = try c.decodeIfPresent(Double.self, forKey: .coarseHighMinRevenue) ?? 10
        mediumEvents = try c.decodeIfPresent([String].self, forKey: .mediumEvents) ?? []
        measurementWindowHours = try c.decodeIfPresent(Int.self, forKey: .measurementWindowHours) ?? 48
        lockWindowAtRevenue = try c.decodeIfPresent(Double.self, forKey: .lockWindowAtRevenue)
    }

    /// Coarse values, ordered.
    public enum Coarse: String, Codable, Comparable {
        case low, medium, high

        var rank: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
        public static func < (lhs: Coarse, rhs: Coarse) -> Bool { lhs.rank < rhs.rank }
    }

    public func evaluate(revenue: Double, eventsSeen: Set<String>) -> (fine: Int, coarse: Coarse) {
        var fine = 0
        for band in revenueBands where revenue >= band.minRevenue {
            fine = max(fine, band.fineValue)
        }
        for event in eventsSeen {
            if let floor = eventFloors[event] { fine = max(fine, floor) }
        }
        fine = min(max(fine, 0), 63)

        let coarse: Coarse
        if revenue >= coarseHighMinRevenue {
            coarse = .high
        } else if revenue >= coarseMediumMinRevenue || !eventsSeen.isDisjoint(with: mediumEvents) {
            coarse = .medium
        } else {
            coarse = .low
        }
        return (fine, coarse)
    }
}

/// On-device measurement state for the first conversion window.
public struct ConversionValueState: Codable, Equatable {
    public var firstLaunch: Date
    public var cumulativeRevenue: Double
    public var eventsSeen: Set<String>
    public var lastFine: Int?
    public var lastCoarse: ConversionSchema.Coarse?
    public var locked: Bool

    public init(firstLaunch: Date) {
        self.firstLaunch = firstLaunch
        cumulativeRevenue = 0
        eventsSeen = []
        lastFine = nil
        lastCoarse = nil
        locked = false
    }
}

/// A value to hand to SKAdNetwork / AdAttributionKit.
public struct ConversionValueUpdate: Equatable {
    public let fine: Int
    public let coarse: ConversionSchema.Coarse
    public let lockWindow: Bool
}

/// Pure decision logic: given the state, the schema and something that just
/// happened, what (if anything) should be reported. Values only ever increase
/// within the window, so a later small event can never overwrite a more
/// valuable signal, and nothing is reported after the window or a lock.
public enum ConversionValueEngine {

    public static func record(
        state: inout ConversionValueState,
        schema: ConversionSchema,
        eventName: String?,
        revenue: Double?,
        now: Date
    ) -> ConversionValueUpdate? {
        guard !state.locked else { return nil }
        let windowEnd = state.firstLaunch.addingTimeInterval(TimeInterval(max(1, schema.measurementWindowHours)) * 3600)
        guard now <= windowEnd else { return nil }

        if let eventName, !eventName.isEmpty { state.eventsSeen.insert(eventName) }
        if let revenue, revenue.isFinite, revenue > 0 { state.cumulativeRevenue += revenue }

        let (fine, coarse) = schema.evaluate(revenue: state.cumulativeRevenue, eventsSeen: state.eventsSeen)
        let lock = schema.lockWindowAtRevenue.map { state.cumulativeRevenue >= $0 } ?? false

        let increased = state.lastFine.map { fine > $0 } ?? true
        let coarseIncreased = state.lastCoarse.map { coarse > $0 } ?? true
        guard increased || coarseIncreased || lock else { return nil }

        let reportedFine = max(fine, state.lastFine ?? 0)
        let reportedCoarse = max(coarse, state.lastCoarse ?? .low)
        state.lastFine = reportedFine
        state.lastCoarse = reportedCoarse
        state.locked = lock
        return ConversionValueUpdate(fine: reportedFine, coarse: reportedCoarse, lockWindow: lock)
    }
}

/// Small JSON-file persistence for the schema cache and window state.
public final class ConversionValueStore {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    private var stateURL: URL { directory.appendingPathComponent("linkflow-cv-state.json") }
    private var schemaURL: URL { directory.appendingPathComponent("linkflow-cv-schema.json") }

    public struct CachedSchema: Codable {
        public let revision: Int
        public let schema: ConversionSchema
        public let fetchedAt: Date
    }

    public func loadState() -> ConversionValueState? { read(ConversionValueState.self, from: stateURL) }
    public func saveState(_ state: ConversionValueState) { write(state, to: stateURL) }
    public func loadSchema() -> CachedSchema? { read(CachedSchema.self, from: schemaURL) }
    public func saveSchema(_ schema: CachedSchema) { write(schema, to: schemaURL) }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Parses `GET /api/skan/conversion-schema` (`{revision, bundleId, schema}`).
public enum ConversionSchemaResponse {
    public static func parse(_ data: Data) -> (revision: Int, schema: ConversionSchema)? {
        struct Envelope: Decodable {
            let revision: Int
            let schema: ConversionSchema
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return (envelope.revision, envelope.schema)
    }
}
