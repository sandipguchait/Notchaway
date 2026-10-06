import SwiftUI

/// Live scores from ESPN's public scoreboard feed.
@MainActor
final class LiveScoresService: ObservableObject {
    struct League: Identifiable, Hashable {
        let id: String
        let sport: String
        let league: String
        let name: String
    }

    struct Side: Equatable {
        let abbreviation: String
        let name: String
        let logo: URL?
        let score: String
        let isWinner: Bool
    }

    struct Match: Identifiable, Equatable {
        let id: String
        let home: Side
        let away: Side
        let state: String
        let detail: String
        let date: Date?

        var isLive: Bool { state == "in" }
        var isUpcoming: Bool { state == "pre" }
    }

    static let leagues: [League] = [
        League(id: "eng.1", sport: "soccer", league: "eng.1", name: "Premier League"),
        League(id: "esp.1", sport: "soccer", league: "esp.1", name: "LaLiga"),
        League(id: "uefa.champions", sport: "soccer", league: "uefa.champions", name: "Champions League"),
        League(id: "usa.1", sport: "soccer", league: "usa.1", name: "MLS"),
        League(id: "nba", sport: "basketball", league: "nba", name: "NBA"),
        League(id: "nfl", sport: "football", league: "nfl", name: "NFL"),
        League(id: "mlb", sport: "baseball", league: "mlb", name: "MLB"),
        League(id: "nhl", sport: "hockey", league: "nhl", name: "NHL")
    ]

    @Published var leagueID: String {
        didSet {
            UserDefaults.standard.set(leagueID, forKey: "scores.league")
            refresh()
        }
    }
    @Published var favoriteTeam: String {
        didSet {
            UserDefaults.standard.set(favoriteTeam, forKey: "scores.favorite")
            refresh()
        }
    }
    @Published private(set) var match: Match?
    @Published private(set) var matchCount = 0
    @Published private(set) var message: String?

    private var timer: Timer?
    private var clients = 0

    init() {
        leagueID = UserDefaults.standard.string(forKey: "scores.league") ?? "eng.1"
        favoriteTeam = UserDefaults.standard.string(forKey: "scores.favorite") ?? ""
    }

    var league: League {
        Self.leagues.first { $0.id == leagueID } ?? Self.leagues[0]
    }

    func beginMonitoring() {
        clients += 1
        guard clients == 1 else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func endMonitoring() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let league = self.league
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.sport)/\(league.league)/scoreboard") else { return }
        let favorite = favoriteTeam.trimmingCharacters(in: .whitespaces).lowercased()

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let board = data.flatMap { try? JSONDecoder().decode(Scoreboard.self, from: $0) }
            let matches = board?.events.compactMap(Self.makeMatch) ?? []
            Task { @MainActor in
                guard let self else { return }
                guard board != nil else {
                    self.message = "Scores unavailable"
                    return
                }
                let relevant = favorite.isEmpty ? matches : matches.filter { match in
                    [match.home, match.away].contains { side in
                        side.abbreviation.lowercased() == favorite || side.name.lowercased().contains(favorite)
                    }
                }
                self.matchCount = relevant.count
                self.match = relevant.first(where: \.isLive)
                    ?? relevant.filter(\.isUpcoming).min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
                    ?? relevant.last
                self.message = self.match == nil ? "No \(league.name) games right now" : nil
            }
        }.resume()
    }

    // MARK: Decoding

    private struct Scoreboard: Decodable {
        let events: [Event]
    }

    private struct Event: Decodable {
        let id: String
        let date: String?
        let status: Status
        let competitions: [Competition]
    }

    private struct Status: Decodable {
        struct Kind: Decodable {
            let state: String
            let shortDetail: String?
        }
        let type: Kind
    }

    private struct Competition: Decodable {
        let competitors: [Competitor]
    }

    private struct Competitor: Decodable {
        let homeAway: String?
        let score: FlexibleString?
        let winner: Bool?
        let team: Team?
    }

    private struct Team: Decodable {
        let abbreviation: String?
        let displayName: String?
        let shortDisplayName: String?
        let logo: String?
    }

    /// ESPN sends scores as strings for most sports but as objects or numbers for some.
    private struct FlexibleString: Decodable {
        let value: String

        private struct Object: Decodable { let displayValue: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let number = try? container.decode(Double.self) {
                value = String(Int(number))
            } else if let object = try? container.decode(Object.self) {
                value = object.displayValue ?? ""
            } else {
                value = ""
            }
        }
    }

    nonisolated private static func makeMatch(_ event: Event) -> Match? {
        guard let competitors = event.competitions.first?.competitors, competitors.count >= 2 else { return nil }
        let home = competitors.first { $0.homeAway == "home" } ?? competitors[0]
        let away = competitors.first { $0.homeAway == "away" } ?? competitors[1]

        func side(_ competitor: Competitor) -> Side {
            Side(abbreviation: competitor.team?.abbreviation ?? "—",
                 name: competitor.team?.shortDisplayName ?? competitor.team?.displayName ?? "",
                 logo: competitor.team?.logo.flatMap(URL.init(string:)),
                 score: competitor.score?.value ?? "",
                 isWinner: competitor.winner ?? false)
        }

        return Match(id: event.id, home: side(home), away: side(away), state: event.status.type.state,
                     detail: event.status.type.shortDetail ?? "", date: event.date.flatMap(parseDate))
    }

    nonisolated private static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmX"
        return formatter.date(from: string)
    }
}

struct ScoresCard: View {
    @EnvironmentObject private var scores: LiveScoresService

    var body: some View {
        LiveCard(glow: scores.match?.isLive == true ? .red : LuminousCardTheme.azure) {
            if let match = scores.match {
                HStack(spacing: 8) {
                    TeamBadge(side: match.home)
                    Spacer(minLength: 0)
                    VStack(spacing: 5) {
                        Text(scores.league.name.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        if match.isUpcoming {
                            BigNumber(text: match.date.map(Format.time) ?? "—", size: 24)
                        } else {
                            HStack(spacing: 6) {
                                BigNumber(text: match.home.score, size: 32)
                                Text(":").font(.system(size: 26, weight: .bold)).foregroundStyle(.secondary)
                                BigNumber(text: match.away.score, size: 32)
                            }
                        }
                        HStack(spacing: 4) {
                            if match.isLive {
                                Image(systemName: "dot.radiowaves.left.and.right")
                            }
                            Text(match.isUpcoming ? (match.date.map { Format.relative($0) } ?? match.detail) : match.detail)
                                .lineLimit(1)
                        }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(match.isLive ? Color.red : Color.white.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                    TeamBadge(side: match.away)
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    CardHeader(title: scores.league.name, symbol: "sportscourt.fill", tint: .red)
                    Text(scores.message ?? "Loading scores…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { scores.beginMonitoring() }
        .onDisappear { scores.endMonitoring() }
    }
}

private struct TeamBadge: View {
    let side: LiveScoresService.Side

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(Color.white.opacity(0.1))
                AsyncImage(url: side.logo) { image in
                    image.resizable().aspectRatio(contentMode: .fit).padding(8)
                } placeholder: {
                    Text(side.abbreviation.prefix(3))
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .frame(width: 54, height: 54)
            Text(side.abbreviation)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(side.isWinner ? .white : .white.opacity(0.75))
        }
        .frame(maxWidth: 70)
    }
}
