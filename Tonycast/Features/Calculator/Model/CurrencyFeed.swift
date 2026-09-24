import Foundation

/// Decodes the rate feed into one snapshot. Pure, so the harness covers it; the store does the IO.
enum CurrencyFeed {
    /// One base, one flat map: 1 unit of `base` buys this many of each code.
    private struct Payload: Decodable {
        /// The feed's own publish date, `YYYY-MM-DD`; a CDN can serve a copy a day old.
        let date: String?
        let rates: [String: Double]

        enum CodingKeys: String, CodingKey {
            case date
            case rates = "usd"
        }
    }

    /// The endpoint is `.../currencies/usd.json`, so the base is fixed by the URL, not the payload.
    static let base = "USD"

    /// The feed serves 339 keys; below this a body is a CDN stub or error object, not a snapshot.
    static let minimumRates = 150

    /// One units-per-`base` table, or a throw. `minimumRates` lets a fixture skip 150 real rates.
    static func snapshot(
        payload: Data, now: Date, minimumRates: Int = CurrencyFeed.minimumRates
    ) throws -> CurrencyRates {
        let decoded = try JSONDecoder().decode(Payload.self, from: payload)

        var rates: [String: Double] = [:]
        rates.reserveCapacity(decoded.rates.count)
        // Fiat codes are three letters; the hand-written crypto table runs to four (USDT, SHIB).
        for (code, rate) in decoded.rates {
            let upper = code.uppercased()
            // A base quoted against itself would let a one-key body clear the floor below.
            guard upper != base, (3...4).contains(upper.count), upper.allSatisfy(\.isLetter),
                usable(rate)
            else { continue }
            rates[upper] = rate
        }
        guard rates.count >= minimumRates else { throw URLError(.cannotParseResponse) }
        // Set last, so the base is the one the endpoint names rather than anything the feed claims.
        rates[base] = 1

        return CurrencyRates(base: base, rates: rates, fetchedAt: now, feedDate: decoded.date)
    }

    /// Older than this, a served snapshot is not trusted for another full interval.
    static let staleAfter: TimeInterval = 48 * 3600

    /// The feed's publish date as an instant, or nil when it is absent or unparseable.
    static func publishedAt(_ feedDate: String?) -> Date? {
        guard let feedDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: feedDate)
    }

    private static func usable(_ rate: Double) -> Bool {
        rate > 0 && rate.isFinite
    }
}
