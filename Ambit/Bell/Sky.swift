import Foundation

// MARK: - Weather snapshot

struct Weather: Equatable {
    var temp: Double = 56        // °F
    var wind: Double = 7         // mph
    var humidity: Double = 70    // %
    var precip: Double = 35      // chance, %
    var pressure: Double = 1011  // hPa
    var cloud: Double = 80       // %
}

// MARK: - Sun and moon (low precision, as in the web version)

enum Astro {
    /// Days since J2000.0
    static func days(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1000 / 864e5 + 2_440_587.5 - 2_451_545
    }

    /// Altitude (degrees) and hour angle (radians, −π…π, 0 at transit) of a body at
    /// ecliptic longitude λ (radians, zero ecliptic latitude).
    static func position(eclipticLongitude lam: Double, date: Date, lat: Double, lon: Double)
        -> (alt: Double, ha: Double) {
        let n = days(date)
        let rad = Double.pi / 180
        let eps = (23.439 - 4e-7 * n) * rad
        let dec = asin(sin(eps) * sin(lam))
        let ra = atan2(cos(eps) * sin(lam), cos(lam))
        let gmst = (280.46061837 + 360.98564736629 * n) * rad
        var ha = gmst + lon * rad - ra
        ha = atan2(sin(ha), cos(ha))
        let phi = lat * rad
        let alt = asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(ha))
        return (alt / rad, ha)
    }

    static func sunLongitude(_ date: Date) -> Double {
        let n = days(date)
        let rad = Double.pi / 180
        let L = (280.460 + 0.9856474 * n) * rad
        let g = (357.528 + 0.9856003 * n) * rad
        return L + (1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
    }

    static func sun(_ date: Date, lat: Double, lon: Double) -> (alt: Double, ha: Double) {
        position(eclipticLongitude: sunLongitude(date), date: date, lat: lat, lon: lon)
    }

    /// 0 = new, 0.5 = full
    static func moonPhase(_ date: Date) -> Double {
        let ref = Date(timeIntervalSince1970: 947_182_440)   // 2000-01-06 18:14 UTC
        let syn = 29.530588853
        var x = (date.timeIntervalSince(ref) / 86_400).truncatingRemainder(dividingBy: syn)
        if x < 0 { x += syn }
        return x / syn
    }

    static func moon(_ date: Date, lat: Double, lon: Double) -> (alt: Double, ha: Double) {
        position(eclipticLongitude: sunLongitude(date) + moonPhase(date) * 2 * .pi,
                 date: date, lat: lat, lon: lon)
    }

    /// Mean solar hour: UTC hour + longitude / 15 (no equation of time).
    static func solarHour(_ date: Date, lon: Double) -> Double {
        let utc = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 3600
        var h = (utc + lon / 15).truncatingRemainder(dividingBy: 24)
        if h < 0 { h += 24 }
        return h
    }

    static func dayOfYear(_ date: Date) -> Double {
        Double(Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: date) ?? 1)
    }
}

// MARK: - Open-Meteo

private struct OpenMeteo: Decodable {
    struct Current: Decodable {
        let time: String?
        let temperature_2m: Double?
        let relative_humidity_2m: Double?
        let precipitation: Double?
        let pressure_msl: Double?
        let wind_speed_10m: Double?
        let cloud_cover: Double?
    }
    struct Hourly: Decodable {
        let time: [String]?
        let precipitation_probability: [Double?]?
    }
    let current: Current
    let hourly: Hourly?
}

enum WeatherService {
    enum Failure: Error { case badData }

    static func fetch(lat: Double, lon: Double) async throws -> Weather {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", lat)),
            .init(name: "longitude", value: String(format: "%.4f", lon)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,precipitation,pressure_msl,wind_speed_10m,cloud_cover"),
            .init(name: "hourly", value: "precipitation_probability"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "wind_speed_unit", value: "mph"),
            .init(name: "precipitation_unit", value: "inch"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = c.url else { throw Failure.badData }
        var req = URLRequest(url: url)
        req.timeoutInterval = 9
        let (data, _) = try await URLSession.shared.data(for: req)
        let r = try JSONDecoder().decode(OpenMeteo.self, from: data)
        let cur = r.current
        guard let t = cur.temperature_2m, let h = cur.relative_humidity_2m, let p = cur.pressure_msl,
              let w = cur.wind_speed_10m, let cl = cur.cloud_cover,
              t.isFinite, h.isFinite, p.isFinite, w.isFinite, cl.isFinite else { throw Failure.badData }
        // Precipitation is a *chance*: this hour's probability, raised if it's falling right now.
        var chance = 0.0
        if let now = cur.time, let times = r.hourly?.time, let probs = r.hourly?.precipitation_probability {
            let key = String(now.prefix(13))
            if let i = times.firstIndex(where: { $0.prefix(13) == key }), i < probs.count, let v = probs[i] {
                chance = v
            }
        }
        if (cur.precipitation ?? 0) > 0 { chance = max(chance, 65) }
        return Weather(temp: t, wind: w, humidity: h, precip: chance, pressure: p, cloud: cl)
    }
}

// MARK: - Simulated sky (Markov chain of weather regimes)

struct SimulatedSky {
    struct Regime {
        let wind, hum, precip, pres, cloud, t: Double
    }
    static let regimes: [String: Regime] = [
        "clear":    Regime(wind: 4, hum: 42, precip: 2, pres: 1022, cloud: 8, t: 3),
        "fair":     Regime(wind: 8, hum: 55, precip: 8, pres: 1016, cloud: 38, t: 1),
        "overcast": Regime(wind: 9, hum: 72, precip: 18, pres: 1010, cloud: 92, t: -1),
        "drizzle":  Regime(wind: 7, hum: 88, precip: 45, pres: 1007, cloud: 95, t: -2),
        "rain":     Regime(wind: 15, hum: 93, precip: 85, pres: 1000, cloud: 100, t: -3),
        "storm":    Regime(wind: 27, hum: 90, precip: 96, pres: 993, cloud: 100, t: 0),
        "fog":      Regime(wind: 2, hum: 98, precip: 10, pres: 1018, cloud: 100, t: -2),
        "windy":    Regime(wind: 28, hum: 50, precip: 12, pres: 1004, cloud: 55, t: 0),
    ]
    static let next: [String: [String]] = [
        "clear": ["fair", "fair", "windy", "fog"],
        "fair": ["clear", "overcast", "fair", "windy"],
        "overcast": ["drizzle", "fair", "rain", "fog"],
        "drizzle": ["rain", "overcast", "fog", "drizzle"],
        "rain": ["storm", "drizzle", "overcast", "rain"],
        "storm": ["rain", "windy", "overcast"],
        "fog": ["overcast", "clear", "drizzle"],
        "windy": ["fair", "overcast", "storm", "clear"],
    ]

    var regime: String = ["overcast", "drizzle", "rain", "fair"].randomElement() ?? "overcast"
    var regimeEnds: Date = Date().addingTimeInterval(Double.random(in: 240...540))

    mutating func step(_ w: inout Weather, dt: Double, date: Date, lat: Double, lon: Double) {
        if date >= regimeEnds {
            regime = SimulatedSky.next[regime]?.randomElement() ?? "fair"
            regimeEnds = date.addingTimeInterval(Double.random(in: 240...600))
        }
        guard let R = SimulatedSky.regimes[regime] else { return }
        let doy = Astro.dayOfYear(date)
        let hr = Astro.solarHour(date, lon: lon)
        let sign: Double = lat >= 0 ? 1 : -1
        let tTarget = 52 - 28 * cos(2 * .pi * (doy - 15) / 365) * sign - abs(lat) * 0.15
            + 8 * cos(2 * .pi * (hr - 15) / 24) + R.t * 2.5
        let k = 1 - exp(-dt / 45)
        let sq = sqrt(dt)
        func move(_ x: inout Double, _ tgt: Double, _ noise: Double, _ lo: Double, _ hi: Double) {
            x += (tgt - x) * k + Double.random(in: -1...1) * noise * sq
            x = min(hi, max(lo, x))
        }
        move(&w.temp, tTarget, 0.12, -10, 105)
        move(&w.wind, R.wind, 0.5, 0, 50)
        move(&w.humidity, R.hum, 0.4, 0, 100)
        move(&w.precip, R.precip, 1.0, 0, 100)
        move(&w.pressure, R.pres, 0.08, 980, 1040)
        move(&w.cloud, R.cloud, 0.9, 0, 100)
    }
}

// MARK: - Small helpers shared by the model and views

@inline(__always) func lin(_ v: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
    c + min(1, max(0, (v - a) / (b - a))) * (d - c)
}
@inline(__always) func smoothstep(_ t: Double) -> Double {
    let x = min(1, max(0, t))
    return x * x * (3 - 2 * x)
}
