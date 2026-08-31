import SwiftUI
import Charts
import UniFiBackupKit

/// Gives the loaded `stat_*` / `event_archive` collections a real home
/// instead of the opaque "Other Collections" dead-end (ROADMAP Tier-1 #3 /
/// Tier-2 #12): a list of what's present, plus a best-effort chart of
/// throughput and client counts over time drawn from the richest available
/// collection.
struct StatisticsView: View {
    @Bindable var controller: InspectorController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Statistics")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let backup = controller.backup, backup.statsLoaded {
                loadedContent(backup: backup)
            } else {
                loadPrompt
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - Not-yet-loaded prompt

    private var loadPrompt: some View {
        ContentUnavailableView {
            Label("Statistics not loaded", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            Text("Historical stat collections (hourly/daily/monthly throughput, client counts) are kept separate from the main configuration and are only parsed on request — they can be large.")
        } actions: {
            Button {
                Task { await controller.loadStatistics() }
            } label: {
                if controller.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Load statistics…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isLoading || controller.backup == nil)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func loadedContent(backup: Backup) -> some View {
        let statCollections = Self.statCollections(in: backup.model.opaqueCollections)

        if statCollections.isEmpty {
            ContentUnavailableView(
                "No statistics collections",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("This backup carries no stat_* or event_archive collections.")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    collectionSummary(statCollections)

                    if let chosen = Self.richestCollection(statCollections) {
                        let series = Self.aggregate(records: chosen.records)
                        Text("Charted from `\(chosen.name)` (\(chosen.records.count) records)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if series.throughput.isEmpty && series.clients.isEmpty {
                            fallbackTable(for: chosen)
                        } else {
                            if !series.throughput.isEmpty {
                                GroupBox("Throughput") {
                                    throughputChart(series.throughput)
                                }
                            }
                            if !series.clients.isEmpty {
                                GroupBox("Client count") {
                                    clientChart(series.clients)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func collectionSummary(_ collections: [OpaqueCollection]) -> some View {
        GroupBox("Collections") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(collections, id: \.name) { c in
                    HStack {
                        Text(c.name)
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text("\(c.records.count) records")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func throughputChart(_ points: [ThroughputPoint]) -> some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.time),
                y: .value("Bytes", point.bytes)
            )
            .foregroundStyle(by: .value("Series", point.series))
            .interpolationMethod(.monotone)
        }
        .frame(height: 220)
    }

    private func clientChart(_ points: [ClientPoint]) -> some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.time),
                y: .value("Clients", point.clients)
            )
            .foregroundStyle(.blue)
            .interpolationMethod(.monotone)
        }
        .frame(height: 160)
    }

    /// No chartable numeric fields were found on any record — fall back to a
    /// plain read-only listing of the first ~50 rows' key fields so the data
    /// is still inspectable.
    private func fallbackTable(for collection: OpaqueCollection) -> some View {
        GroupBox("Sample rows (no chartable fields found)") {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(collection.records.prefix(50).enumerated()), id: \.offset) { _, record in
                        Text("\(record.id): " + Self.summaryLine(for: record.rawDocument))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 280)
        }
    }

    // MARK: - Data shaping (pure, testable-by-inspection helpers)

    private struct ThroughputPoint: Identifiable {
        let id = UUID()
        let time: Date
        let series: String
        let bytes: Double
    }

    private struct ClientPoint: Identifiable {
        let id = UUID()
        let time: Date
        let clients: Double
    }

    private struct Bucket {
        var rx: Double = 0
        var tx: Double = 0
        var hasRxTx = false
        var total: Double = 0
        var hasTotal = false
        var numSta: Double = 0
        var hasNumSta = false
    }

    /// Finds `stat_*` and `event_archive` opaque collections.
    private static func statCollections(in collections: [OpaqueCollection]) -> [OpaqueCollection] {
        collections
            .filter { $0.name.hasPrefix("stat_") || $0.name == "event_archive" }
            .sorted { $0.name < $1.name }
    }

    /// Prefers `stat_daily`, else `stat_hourly`, else `stat_5minutes`, else
    /// `stat_monthly`; otherwise falls back to whichever stat collection has
    /// the most records.
    private static func richestCollection(_ collections: [OpaqueCollection]) -> OpaqueCollection? {
        var byName: [String: OpaqueCollection] = [:]
        for c in collections { byName[c.name] = c }
        for preferred in ["stat_daily", "stat_hourly", "stat_5minutes", "stat_monthly"] {
            if let match = byName[preferred], !match.records.isEmpty { return match }
        }
        return collections.max { $0.records.count < $1.records.count }
    }

    /// Extracts a bucket timestamp from a record, defensively: `datetimeValue`
    /// already handles a genuine BSON datetime and a plausible epoch-ms int64;
    /// this also tolerates epoch-seconds.
    private static func extractTime(_ doc: BSONDocument) -> Date? {
        guard let field = doc["time"] else { return nil }
        if let d = field.datetimeValue { return d }
        if let n = field.int64Value, n > 1_000_000_000, n < 10_000_000_000 {
            return Date(timeIntervalSince1970: Double(n))
        }
        return nil
    }

    /// Groups records by their `time` bucket (summing across sites/devices
    /// that share a timestamp), then caps to the most recent 500 buckets.
    /// Many stat records are missing one field or another — every access here
    /// is optional and simply skipped rather than failing the whole record.
    private static func aggregate(records: [OpaqueRecord]) -> (throughput: [ThroughputPoint], clients: [ClientPoint]) {
        var byTime: [Date: Bucket] = [:]

        for record in records {
            let doc = record.rawDocument
            guard let time = extractTime(doc) else { continue }
            var bucket = byTime[time] ?? Bucket()

            let rx = doc["rx_bytes"]?.doubleValue ?? doc["wan-rx_bytes"]?.doubleValue
            let tx = doc["tx_bytes"]?.doubleValue ?? doc["wan-tx_bytes"]?.doubleValue
            if let rx { bucket.rx += rx; bucket.hasRxTx = true }
            if let tx { bucket.tx += tx; bucket.hasRxTx = true }

            if let total = doc["bytes"]?.doubleValue {
                bucket.total += total
                bucket.hasTotal = true
            }

            if let numSta = doc["num_sta"]?.doubleValue {
                bucket.numSta += numSta
                bucket.hasNumSta = true
            }

            byTime[time] = bucket
        }

        let orderedTimes = byTime.keys.sorted().suffix(500)

        var throughput: [ThroughputPoint] = []
        var clients: [ClientPoint] = []
        for time in orderedTimes {
            guard let bucket = byTime[time] else { continue }
            if bucket.hasRxTx {
                throughput.append(ThroughputPoint(time: time, series: "RX", bytes: bucket.rx))
                throughput.append(ThroughputPoint(time: time, series: "TX", bytes: bucket.tx))
            } else if bucket.hasTotal {
                throughput.append(ThroughputPoint(time: time, series: "Total", bytes: bucket.total))
            }
            if bucket.hasNumSta {
                clients.append(ClientPoint(time: time, clients: bucket.numSta))
            }
        }
        return (throughput, clients)
    }

    /// A short, single-line summary of a record's first few fields, for the
    /// no-chartable-data fallback table.
    private static func summaryLine(for doc: BSONDocument) -> String {
        doc.pairs.prefix(6)
            .map { "\($0.key)=\($0.value.displayString)" }
            .joined(separator: ", ")
    }
}
