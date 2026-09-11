import Combine
import Darwin
import Foundation

struct TemperatureSample: Identifiable, Equatable, Sendable {
    let date: Date
    let celsius: Double

    var id: Date { date }
}

struct TemperatureSensorReading: Equatable, Sendable {
    let name: String
    let celsius: Double
}

enum TemperatureAlertLevel: Equatable, Sendable {
    case none
    case elevated
    case critical

    static let elevatedCelsius: Double = 80
    static let criticalCelsius: Double = 95

    static func level(for celsius: Double?, isEnabled: Bool) -> TemperatureAlertLevel {
        guard isEnabled, let celsius else { return .none }
        if celsius >= criticalCelsius { return .critical }
        if celsius >= elevatedCelsius { return .elevated }
        return .none
    }
}

enum TemperatureAggregator {
    static let historyWindow: TimeInterval = 60 * 60
    static let validRange: ClosedRange<Double> = 0...120

    static func computerTemperature(from readings: [TemperatureSensorReading]) -> Double? {
        let valid = readings.filter { Self.validRange.contains($0.celsius) }
        let preferred = valid.filter { isDieSensor($0.name) }
        let source = preferred.isEmpty ? valid : preferred
        return source.map(\.celsius).max()
    }

    static func pruningSamples(_ samples: [TemperatureSample], now: Date) -> [TemperatureSample] {
        samples.filter { now.timeIntervalSince($0.date) <= historyWindow }
    }

    static func isDieSensor(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("battery") || lower.contains("nand") || lower.contains("tcal") {
            return false
        }
        return lower.contains("tdie")
            || lower.contains("cpu")
            || lower.contains("soc")
            || lower.contains("gpu")
            || lower.contains("mtr temp")
    }
}

@MainActor
protocol TemperatureReading: AnyObject {
    func readCelsius() -> Double?
}

@MainActor
final class HIDTemperatureReader: TemperatureReading {
    private typealias EventSystemClient = OpaquePointer
    private typealias ServiceClient = OpaquePointer
    private typealias Event = OpaquePointer
    private typealias CreateFn = @convention(c) (CFAllocator?) -> EventSystemClient?
    private typealias SetMatchingFn = @convention(c) (EventSystemClient?, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (EventSystemClient?) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (ServiceClient?, Int64, Int32, Int64) -> Event?
    private typealias GetFloatFn = @convention(c) (Event?, Int32) -> Double
    private typealias CopyPropertyFn = @convention(c) (ServiceClient?, CFString) -> Unmanaged<CFTypeRef>?

    private static let eventTypeTemperature: Int32 = 15
    private static let appleVendorPage = 0xff00
    private static let temperatureUsage = 0x0005

    private let client: EventSystemClient
    private let copyServices: CopyServicesFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let copyProperty: CopyPropertyFn

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard let create: CreateFn = symbol("IOHIDEventSystemClientCreate"),
              let setMatching: SetMatchingFn = symbol("IOHIDEventSystemClientSetMatching"),
              let copyServices: CopyServicesFn = symbol("IOHIDEventSystemClientCopyServices"),
              let copyEvent: CopyEventFn = symbol("IOHIDServiceClientCopyEvent"),
              let getFloat: GetFloatFn = symbol("IOHIDEventGetFloatValue"),
              let copyProperty: CopyPropertyFn = symbol("IOHIDServiceClientCopyProperty"),
              let client = create(kCFAllocatorDefault) else {
            return nil
        }

        setMatching(client, [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureUsage
        ] as CFDictionary)

        self.client = client
        self.copyServices = copyServices
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.copyProperty = copyProperty
    }

    func readCelsius() -> Double? {
        TemperatureAggregator.computerTemperature(from: readSensors())
    }

    private func readSensors() -> [TemperatureSensorReading] {
        guard let services = copyServices(client)?.takeRetainedValue() else { return [] }
        let count = CFArrayGetCount(services)
        var readings: [TemperatureSensorReading] = []
        readings.reserveCapacity(count)

        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = OpaquePointer(raw)
            var name = "unknown"
            if let product = copyProperty(service, "Product" as CFString)?.takeUnretainedValue() {
                name = String(describing: product)
            }
            guard let event = copyEvent(service, Int64(Self.eventTypeTemperature), 0, 0) else {
                continue
            }
            readings.append(
                TemperatureSensorReading(
                    name: name,
                    celsius: getFloat(event, Self.eventTypeTemperature << 16)
                )
            )
        }

        return readings
    }
}

@MainActor
protocol TemperatureSettingsStoring: AnyObject {
    var isHighTemperatureAlertEnabled: Bool { get set }
}

@MainActor
final class UserDefaultsTemperatureSettingsStore: TemperatureSettingsStoring {
    private enum Key {
        static let highTemperatureAlertEnabled = "temperature.highTemperatureAlertEnabled"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isHighTemperatureAlertEnabled: Bool {
        get {
            guard userDefaults.object(forKey: Key.highTemperatureAlertEnabled) != nil else {
                return true
            }
            return userDefaults.bool(forKey: Key.highTemperatureAlertEnabled)
        }
        set {
            userDefaults.set(newValue, forKey: Key.highTemperatureAlertEnabled)
        }
    }
}

@MainActor
final class TemperatureStore: ObservableObject {
    static let sampleInterval: Duration = .seconds(15)

    @Published private(set) var currentCelsius: Double?
    @Published private(set) var samples: [TemperatureSample] = []
    @Published var isHighTemperatureAlertEnabled: Bool {
        didSet {
            settingsStore.isHighTemperatureAlertEnabled = isHighTemperatureAlertEnabled
        }
    }

    private let reader: (any TemperatureReading)?
    private let settingsStore: any TemperatureSettingsStoring
    private var refreshTask: Task<Void, Never>?

    init(
        reader: (any TemperatureReading)? = HIDTemperatureReader(),
        settingsStore: any TemperatureSettingsStoring = UserDefaultsTemperatureSettingsStore()
    ) {
        self.reader = reader
        self.settingsStore = settingsStore
        self.isHighTemperatureAlertEnabled = settingsStore.isHighTemperatureAlertEnabled
    }

    var menuBarText: String? {
        guard let currentCelsius else { return nil }
        return String(format: "%.0f°C", currentCelsius.rounded())
    }

    var alertLevel: TemperatureAlertLevel {
        TemperatureAlertLevel.level(
            for: currentCelsius,
            isEnabled: isHighTemperatureAlertEnabled
        )
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                do {
                    try await Task.sleep(for: Self.sampleInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(now: Date = Date()) {
        guard let celsius = reader?.readCelsius() else { return }
        record(celsius, at: now)
    }

    func record(_ celsius: Double, at date: Date = Date()) {
        currentCelsius = celsius
        samples.append(TemperatureSample(date: date, celsius: celsius))
        samples = TemperatureAggregator.pruningSamples(samples, now: date)
    }
}
