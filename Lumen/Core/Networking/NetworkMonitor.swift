import Foundation
import Network
import Observation

/// Observes reachability with NWPathMonitor. Used to skip pointless refreshes while offline,
/// to tune buffering on cellular/Low Data Mode, and to reconnect streams when the network returns.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isConnected = true
    private(set) var isExpensive = false
    private(set) var isConstrained = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.update(connected: connected, expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.lumen.network-monitor", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    /// Suspends until the network is reachable (returns immediately if it already is).
    func waitForConnection() async {
        guard !isConnected else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func update(connected: Bool, expensive: Bool, constrained: Bool) {
        let restored = connected && !isConnected
        if isConnected != connected { isConnected = connected }
        if isExpensive != expensive { isExpensive = expensive }
        if isConstrained != constrained { isConstrained = constrained }
        if connected, !waiters.isEmpty {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
        if restored {
            NotificationCenter.default.post(name: .lumenNetworkRestored, object: nil)
        }
    }
}
