import CoreLocation
import SwiftUI

/// Current conditions and hourly UV from Open-Meteo (free, no API key). Location comes from
/// Core Location, or from a city typed in Settings.
@MainActor
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Hour: Identifiable, Equatable {
        let id: Int
        let hour: Int
        let uv: Double
        let temperature: Double
    }

    @Published private(set) var temperature: Double?
    @Published private(set) var code = 0
    @Published private(set) var uvNow: Double = 0
    @Published private(set) var hours: [Hour] = []
    @Published private(set) var currentHour = Calendar.current.component(.hour, from: Date())
    @Published private(set) var placeName: String?
    @Published private(set) var message: String?

    @Published var manualCity: String {
        didSet {
            UserDefaults.standard.set(manualCity, forKey: "weather.city")
            refresh(force: true)
        }
    }
    @Published var useFahrenheit: Bool {
        didSet {
            UserDefaults.standard.set(useFahrenheit, forKey: "weather.fahrenheit")
            refresh(force: true)
        }
    }

    private let manager = CLLocationManager()
    private var lastFetch: Date?
    private var timer: Timer?

    override init() {
        manualCity = UserDefaults.standard.string(forKey: "weather.city") ?? ""
        useFahrenheit = UserDefaults.standard.bool(forKey: "weather.fahrenheit")
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
    }

    func refresh(force: Bool = false) {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < 600 { return }
        let city = manualCity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty {
            geocode(city)
            return
        }
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .denied || status == .restricted {
            message = "Allow Location or set a city in Settings"
        } else {
            manager.requestLocation()
        }
    }

    var symbol: String { Self.symbol(for: code) }
    var condition: String { Self.condition(for: code) }
    var uvLabel: String { Self.uvLabel(uvNow) }

    // MARK: Location

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        Task { @MainActor in
            self.fetch(latitude: coordinate.latitude, longitude: coordinate.longitude)
            self.reverseGeocode(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.message = "Location unavailable — set a city in Settings" }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.manager.authorizationStatus != .notDetermined { self.refresh(force: true) }
        }
    }

    private func reverseGeocode(_ location: CLLocation) {
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            let name = placemarks?.first?.locality ?? placemarks?.first?.name
            Task { @MainActor in self?.placeName = name }
        }
    }

    // MARK: Network

    private struct GeocodeResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
        }
        let results: [Result]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let uv_index: Double?
        }
        struct Hourly: Decodable {
            let time: [String]
            let uv_index: [Double?]
            let temperature_2m: [Double?]
        }
        let current: Current
        let hourly: Hourly
        let utc_offset_seconds: Int
    }

    private func geocode(_ city: String) {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let result = data.flatMap { try? JSONDecoder().decode(GeocodeResponse.self, from: $0) }?.results?.first
            Task { @MainActor in
                guard let self else { return }
                guard let result else {
                    self.message = "Couldn't find \"\(city)\""
                    return
                }
                self.placeName = result.name
                self.fetch(latitude: result.latitude, longitude: result.longitude)
            }
        }.resume()
    }

    private func fetch(latitude: Double, longitude: Double) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,uv_index"),
            URLQueryItem(name: "hourly", value: "uv_index,temperature_2m"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: useFahrenheit ? "fahrenheit" : "celsius")
        ]
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let decoded = data.flatMap { try? JSONDecoder().decode(ForecastResponse.self, from: $0) }
            Task { @MainActor in
                guard let self else { return }
                guard let decoded else {
                    self.message = "Weather unavailable"
                    return
                }
                self.apply(decoded)
            }
        }.resume()
    }

    private func apply(_ response: ForecastResponse) {
        lastFetch = Date()
        message = nil
        temperature = response.current.temperature_2m
        code = response.current.weather_code
        uvNow = response.current.uv_index ?? 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: response.utc_offset_seconds) ?? .current
        currentHour = calendar.component(.hour, from: Date())

        hours = response.hourly.time.enumerated().compactMap { index, time in
            guard time.count >= 13, let hour = Int(time.dropFirst(11).prefix(2)) else { return nil }
            return Hour(id: index,
                        hour: hour,
                        uv: response.hourly.uv_index[safe: index].flatMap { $0 } ?? 0,
                        temperature: response.hourly.temperature_2m[safe: index].flatMap { $0 } ?? 0)
        }
    }

    // MARK: Mapping

    static func uvLabel(_ uv: Double) -> String {
        switch uv {
        case ..<3: return "Low"
        case ..<6: return "Moderate"
        case ..<8: return "High"
        case ..<11: return "Very High"
        default: return "Extreme"
        }
    }

    static func uvColor(_ uv: Double) -> Color {
        switch uv {
        case ..<3: return .green
        case ..<6: return .yellow
        case ..<8: return .orange
        case ..<11: return .red
        default: return .purple
        }
    }

    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func condition(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorm"
        default: return "—"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct WeatherCard: View {
    @EnvironmentObject private var weather: WeatherService

    var body: some View {
        LiveCard(glow: LuminousCardTheme.violet) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(weather.hours.isEmpty ? "Weather" : "UV \(weather.uvLabel)")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    if let temperature = weather.temperature {
                        Text("\(Int(temperature.rounded()))°\(weather.useFahrenheit ? "F" : "C")")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                    }
                    Image(systemName: weather.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 14))
                }

                if weather.hours.isEmpty {
                    Text(weather.message ?? "Loading weather…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    UVChart(hours: weather.hours, currentHour: weather.currentHour)
                }

                Text([weather.placeName, weather.condition].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onAppear { weather.refresh() }
    }
}

private struct UVChart: View {
    let hours: [WeatherService.Hour]
    let currentHour: Int

    var body: some View {
        GeometryReader { proxy in
            let barWidth = max(3, (proxy.size.width - CGFloat(hours.count - 1) * 3) / CGFloat(max(hours.count, 1)))
            let chartHeight = proxy.size.height - 12
            VStack(spacing: 2) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(hours) { hour in
                        let isPast = hour.hour <= currentHour
                        let height = max(4, CGFloat(min(hour.uv, 11) / 11) * chartHeight)
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Color.white.opacity(0.06))
                            Capsule()
                                .fill(isPast ? WeatherService.uvColor(hour.uv) : WeatherService.uvColor(hour.uv).opacity(0.3))
                                .frame(height: height)
                        }
                        .frame(width: barWidth)
                        .overlay(alignment: .top) {
                            if hour.hour == currentHour {
                                Image(systemName: "arrowtriangle.down.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .offset(y: -8)
                            }
                        }
                    }
                }
                .frame(height: chartHeight)

                HStack {
                    ForEach([6, 9, 12, 15, 18], id: \.self) { hour in
                        Text(hour == 12 ? "12PM" : (hour < 12 ? "\(hour)AM" : "\(hour - 12)PM"))
                        if hour != 18 { Spacer() }
                    }
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, barWidth * 5)
            }
        }
    }
}
