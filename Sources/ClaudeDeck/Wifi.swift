import CoreWLAN
import Foundation

/// Link quality for the Wi-Fi interface, so a long agent run that dies mid-tool-call has a
/// visible explanation rather than looking like a Claude Code failure.
struct WifiStatus: Sendable, Equatable {
    /// False on a machine with no Wi-Fi hardware, where the section is hidden entirely.
    var present = false
    var connected = false
    var rssi = 0
    var noise = 0
    var transmitRate = 0.0

    /// Signal-to-noise ratio in dB. Below ~15 the link is usable but retransmitting.
    var snr: Int { rssi - noise }

    /// RSSI thresholds are the usual 802.11 ones: -55 excellent, -67 the floor for
    /// sustained throughput, -75 the floor for a usable link.
    var bars: Int {
        guard connected else { return 0 }
        if rssi >= -55 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }

    var label: String {
        switch bars {
        case 4: "excellent"
        case 3: "good"
        case 2: "fair"
        case 1: "weak"
        default: "offline"
        }
    }

    nonisolated static func read() -> WifiStatus {
        guard let interface = CWWiFiClient.shared().interface() else { return WifiStatus() }
        let rssi = interface.rssiValue()
        // A powered-on interface that is not associated reports an RSSI of 0.
        let connected = interface.powerOn() && interface.interfaceMode() == .station && rssi != 0
        return WifiStatus(
            present: true,
            connected: connected,
            rssi: rssi,
            noise: interface.noiseMeasurement(),
            transmitRate: interface.transmitRate()
        )
    }
}
