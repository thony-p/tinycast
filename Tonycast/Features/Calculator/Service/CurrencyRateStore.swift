import Foundation

/// The cacheless exchange-rate fetcher. See docs/features/calculator.md#exchange-rates.
@MainActor
@Observable
final class CurrencyRateStore {
    /// One keyless endpoint serving fiat and crypto in a single table, quoted per 1 USD.
    private nonisolated static let endpoint = URL(
        string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json")!
    /// Daily, measured from `completedAt`, so relaunching never re-fetches a snapshot still fresh.
    private static let refreshInterval: TimeInterval = 24 * 3600
    /// Shorter retry, so a machine offline at launch picks rates up soon after it reconnects.
    private static let retryInterval: TimeInterval = 30 * 60

    /// The newest snapshot, nil until the first one lands.
    private(set) var rates: CurrencyRates?

    private let fileURL: URL
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var completedAt: Date?

    init() {
        fileURL = AppPaths.caches().appendingPathComponent("currency-rates.json")
        guard let data = try? Data(contentsOf: fileURL),
            let cached = try? JSONDecoder().decode(CurrencyRates.self, from: data)
        else { return }
        rates = cached
        completedAt = cached.fetchedAt
    }

    func start() {
        // Replace rather than bail: an exited loop leaves a non-nil task that would block restart.
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled, let self {
                // Clamped, so a future-stamped snapshot can't park the loop past one interval.
                let age = max(0, self.completedAt.map { Date().timeIntervalSince($0) } ?? .infinity)
                guard age >= Self.refreshInterval else {
                    try? await Task.sleep(for: .seconds(Self.refreshInterval - age))
                    continue
                }
                let ok = await self.fetchAndStore()
                try? await Task.sleep(for: .seconds(ok ? Self.refreshInterval : Self.retryInterval))
            }
        }
    }

    private func fetchAndStore() async -> Bool {
        guard let result = await Self.fetch() else { return false }
        rates = result
        // The clock runs from the feed's own date, so a CDN serving a stale copy is re-fetched.
        let published = CurrencyFeed.publishedAt(result.feedDate)
        let anchor = published.map { min($0, result.fetchedAt) } ?? result.fetchedAt
        completedAt = anchor
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return published.map { result.fetchedAt.timeIntervalSince($0) < CurrencyFeed.staleAfter } ?? true
    }

    /// Cacheless, never `URLSession.shared`, so the snapshot on disk stays the only copy.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Off-main; only the plain-value `CurrencyRates` crosses back. A decoded-count floor in
    /// `CurrencyFeed.snapshot` beats a byte floor, which whitespace padding would defeat.
    private nonisolated static func fetch() async -> CurrencyRates? {
        let request = URLRequest(url: endpoint, timeoutInterval: 20)
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return try? CurrencyFeed.snapshot(payload: data, now: Date())
    }
}
