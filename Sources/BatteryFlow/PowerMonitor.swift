import Foundation
import SwiftUI
import AppKit
import IOKit.ps

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var snapshot = PowerSnapshot.empty
    @Published private(set) var health = BatteryHealthSnapshot()
    @Published private(set) var isRefreshingHealth = false
    @Published private(set) var isLowPowerMode = false
    let history: HistoryStore
    private let reader: any TelemetryReading
    private let healthReader: any HealthReading
    private let clock: any MonitorClock
    private let preferences: AppPreferences?
    private var pollingTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var events: PowerEvents?
    private var panelVisible = false
    private var suspended = false
    private var isRunning = false
    private var isReading = false
    private var refreshPending = false
    private var healthAttempt: Date?

    init(history: HistoryStore, reader: any TelemetryReading = BatteryTelemetryReader(),
         healthReader: any HealthReading = SystemProfilerHealthReader(), clock: any MonitorClock = SystemMonitorClock(),
         preferences: AppPreferences? = nil) {
        self.history = history
        self.reader = reader
        self.healthReader = healthReader
        self.clock = clock
        self.preferences = preferences
        if let cached = preferences?.cachedHealth { health = cached }
    }

    static func interval(panelVisible: Bool, lowPowerMode: Bool) -> TimeInterval {
        panelVisible ? (lowPowerMode ? 2 : 1) : (lowPowerMode ? 60 : 30)
    }

    func start(observeSystem: Bool = true) {
        guard !isRunning else { return }
        isRunning = true
        if observeSystem {
            isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            events = PowerEvents(onPowerChange: { [weak self] in self?.powerChanged() },
                onModeChange: { [weak self] in self?.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled) },
                onSleep: { [weak self] in self?.setSleeping(true) },
                onWake: { [weak self] in self?.setSleeping(false) })
        }
        Task { [weak self] in await self?.history.load() }
        refreshHealth()
        reschedule()
    }

    func stop() {
        isRunning = false
        pollingTask?.cancel()
        healthTask?.cancel()
        eventTask?.cancel()
        events?.stop()
        events = nil
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        reschedule()
    }

    func setLowPowerMode(_ enabled: Bool) {
        guard isLowPowerMode != enabled else { return }
        isLowPowerMode = enabled
        reschedule()
    }

    func setSleeping(_ asleep: Bool) {
        suspended = asleep
        if asleep {
            pollingTask?.cancel()
            eventTask?.cancel()
            eventTask = nil
            snapshot = snapshot.stale(message: "Waiting for the Mac to wake.")
        } else {
            snapshot = snapshot.stale(message: "Refreshing after wake.")
            reschedule()
        }
    }

    func refresh() async {
        guard !suspended else { return }
        guard !isReading else { refreshPending = true; return }
        isReading = true
        defer {
            isReading = false
            if refreshPending && isRunning && !suspended {
                refreshPending = false
                Task { [weak self] in await self?.refresh() }
            }
        }
        repeat {
            refreshPending = false
            do {
                var raw = try await reader.read()
                guard !Task.isCancelled, !suspended else { return }
                raw.timestamp = clock.now
                let next = PowerMath.snapshot(from: raw)
                snapshot = PowerMath.smooth(next, previous: snapshot)
                if raw.healthCondition != nil || raw.healthEstimate != nil {
                    health.condition = BatteryHealthSnapshot.nonempty(raw.healthCondition)
                    health.estimate = BatteryHealthSnapshot.nonempty(raw.healthEstimate)
                    health.conditionUpdatedAt = raw.timestamp
                }
                if let cycles = next.cycleCount { health.cycleCount = cycles }
                await history.record(next)
            } catch {
                if !Task.isCancelled {
                    snapshot = snapshot.stale(message: error.localizedDescription)
                    // Persistence retries and retention also continue during telemetry failure.
                    await history.retry()
                }
            }
            if isRunning { refreshHealth() }
        } while refreshPending && !suspended && !Task.isCancelled
    }

    func refreshHealth(force: Bool = false) {
        guard !isRefreshingHealth else { return }
        guard force || healthAttempt.map({ clock.now.timeIntervalSince($0) >= 3600 }) ?? true else { return }
        healthAttempt = clock.now
        isRefreshingHealth = true
        let healthReader = self.healthReader
        healthTask = Task { [weak self] in
            defer { self?.isRefreshingHealth = false }
            do {
                let report = try await healthReader.readHealth()
                guard !Task.isCancelled, let self else { return }
                if let percent = report.maximumCapacityPercent {
                    health.maximumCapacityPercent = percent
                    health.capacityUpdatedAt = clock.now
                    health.errorMessage = nil
                } else {
                    health.errorMessage = "macOS did not provide maximum capacity on this refresh."
                }
                if let condition = report.condition {
                    // The detailed OS report can retain a service warning while IOPS temporarily says Good.
                    health.profiledCondition = condition
                    health.profiledConditionUpdatedAt = clock.now
                }
                if let cycles = report.cycleCount { health.cycleCount = cycles }
                preferences?.cachedHealth = health
            } catch {
                guard !Task.isCancelled else { return }
                self?.health.errorMessage = error.localizedDescription
            }
        }
    }

    private func reschedule() {
        guard isRunning, !suspended else { return }
        pollingTask?.cancel()
        let clock = self.clock
        let interval = Self.interval(panelVisible: panelVisible, lowPowerMode: isLowPowerMode)
        pollingTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                do { try await clock.sleep(seconds: interval) } catch { break }
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }
    private func powerChanged() {
        guard eventTask == nil, !suspended, isRunning else { return }
        let clock = self.clock
        eventTask = Task { [weak self] in
            do { try await clock.sleep(seconds: 0.5) } catch { return }
            self?.eventTask = nil
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
}

@MainActor
private final class PowerEvents {
    private var source: CFRunLoopSource?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private let onPowerChange: @MainActor () -> Void

    init(onPowerChange: @escaping @MainActor () -> Void, onModeChange: @escaping @MainActor () -> Void,
         onSleep: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void) {
        self.onPowerChange = onPowerChange
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<PowerEvents>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in observer.onPowerChange() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        observe(.default, name: .NSProcessInfoPowerStateDidChange, action: onModeChange)
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification, action: onSleep)
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification, action: onWake)
    }
    private func observe(_ center: NotificationCenter, name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        tokens.append((center, token))
    }
    func stop() {
        if let source { CFRunLoopSourceInvalidate(source) }
        source = nil
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }
}
