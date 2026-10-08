// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import CoreBluetooth
import Foundation
import PocketCore

/// Link state shown on the Device page.
enum LinkState: String {
    case off, unauthorized, scanning, connecting, connected, pairing, ready, failed
}

/// CoreBluetooth central for the Passport (docs/ble-protocol.md §4–§6), with state restoration
/// so iOS relaunches the app for Passport traffic after a reboot or a memory kill.
///
/// Every delegate callback runs on `queue`, the engine's queue. Per notification the work is a
/// PDU decode and a hand-off; nothing touches UI.
final class PassportLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let restoreID = "dev.openduo.pocket.central"

    let queue: DispatchQueue
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private let serviceUUID = CBUUID(string: PocketConstants.serviceUUID)
    private let txUUID = CBUUID(string: PocketConstants.txCharacteristicUUID)
    private let rxUUID = CBUUID(string: PocketConstants.rxCharacteristicUUID)
    private var decoder = DeviceLinkDecoder()

    /// Outgoing messages not yet handed to CoreBluetooth, and the fragments of the one in flight.
    private var outbox: [PhoneMessage] = []
    private var inFlight: [Data] = []

    // Callbacks into the engine, all on `queue`.
    var onMessage: ((DeviceMessage) -> Void)?
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onState: ((LinkState, String?) -> Void)?

    private(set) var state = LinkState.off
    /// Passport that answered our stored key with "no bond". Reconnecting to it can only fail
    /// again, and each attempt occupies the Passport's single connection, so the bonded phone
    /// cannot get in. Cleared by forget(), the next launch, or the app coming to the foreground
    /// (one attempt each time, so a re-pair done in the meantime is picked up).
    private var staleBond: UUID?
    private(set) var peripheralName: String?
    private(set) var attPayload = 0

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    /// Must run before application(_:didFinishLaunchingWithOptions:) returns, or iOS does not
    /// deliver the restored central.
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    private func set(_ s: LinkState, _ detail: String? = nil) {
        state = s
        AppLog.shared.log("link", ["state": s.rawValue, "detail": detail ?? "", "app": AppPhase.value])
        onState?(s, detail)
    }

    // MARK: send

    /// Queues a message for the device; dropped when no link is up. Returns whether it was queued.
    @discardableResult
    func send(_ m: PhoneMessage) -> Bool {
        guard state == .ready else { return false }
        // Replace semantics: a newer partial text for the same reply supersedes a queued one.
        if case .reply(let id, false, _) = m,
           let i = outbox.firstIndex(where: { if case .reply(id, false, _) = $0 { true } else { false } }) {
            outbox[i] = m
        } else {
            outbox.append(m)
        }
        flush()
        return true
    }

    private func flush() {
        guard let p = peripheral, let ch = rx, p.state == .connected else { return }
        while true {
            if inFlight.isEmpty {
                guard !outbox.isEmpty else { return }
                let m = outbox.removeFirst()
                attPayload = p.maximumWriteValueLength(for: .withoutResponse)
                do {
                    inFlight = try m.fragments(attPayload: attPayload)
                } catch {
                    AppLog.shared.log("send_drop", ["err": "\(error)", "type": m.kind.rawValue])
                    continue
                }
            }
            guard p.canSendWriteWithoutResponse else { return } // resumes in peripheralIsReady
            p.writeValue(inFlight.removeFirst(), for: ch, type: .withoutResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { flush() }

    // MARK: central

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        AppLog.shared.log("ble_restore", ["peripherals": ps.map(\.identifier.uuidString),
                                          "states": ps.map(\.state.rawValue), "app": AppPhase.value])
        if let p = ps.first {
            peripheral = p
            p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: connectKnownOrScan()
        case .unauthorized: set(.unauthorized)
        default: set(.off, "\(c.state.rawValue)")
        }
    }

    private var savedID: UUID? {
        UserDefaults.standard.string(forKey: Keys.savedPeripheral).flatMap(UUID.init(uuidString:))
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        peripheralName = p.name
    }

    private func connectKnownOrScan() {
        if let p = peripheral {
            switch p.state {
            case .connected:
                set(.connected, "restored")
                p.discoverServices([serviceUUID])
                return
            case .connecting:
                set(.connecting, "restored")
                return
            default:
                break
            }
        }
        if let p = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            adopt(p)
            central.connect(p)
            set(.connecting, "system-connected")
            return
        }
        if let id = savedID, id != staleBond, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            // A pending connect never times out: iOS completes it when the Passport is in range.
            adopt(p)
            central.connect(p)
            set(.connecting, "saved")
        }
        // Scan as well: a never-paired Passport, or a simulator whose address rotates.
        // Background scanning requires the service filter.
        central.scanForPeripherals(withServices: [serviceUUID])
        if peripheral == nil { set(.scanning) }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if let cur = peripheral, cur.state == .connected { c.stopScan(); return }
        if p.identifier == staleBond { return }
        // Prefer the saved Passport; take another one only when none is saved.
        if let id = savedID, p.identifier != id, peripheral?.identifier == id { return }
        AppLog.shared.log("discover", ["id": p.identifier.uuidString, "rssi": rssi.intValue,
                                       "name": p.name ?? ""])
        c.stopScan()
        if let cur = peripheral, cur.identifier != p.identifier { c.cancelPeripheralConnection(cur) }
        adopt(p)
        c.connect(p)
        set(.connecting, "discovered")
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Keys.savedPeripheral)
        peripheralName = p.name
        set(.connected)
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if (error as? CBError)?.code == .peerRemovedPairingInformation {
            // The Passport no longer has this phone's bond (it was re-paired with another phone).
            // Retrying fails within milliseconds and repeats forever, so stop until the user acts.
            staleBond = p.identifier
            AppLog.shared.log("stale_bond", ["id": p.identifier.uuidString])
            set(.failed, String(localized: "Passport 已不认这部手机：在「设置 › 蓝牙」里忽略它，再在设备上重新配对"))
            return
        }
        set(.failed, error?.localizedDescription)
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        rx = nil
        decoder.reset()
        outbox.removeAll()
        inFlight.removeAll()
        set(.connecting, "disconnected: \(error?.localizedDescription ?? "-")")
        onDisconnected?()
        guard p.identifier == peripheral?.identifier else { return }
        c.connect(p)
    }

    /// Called on `queue` when the app comes to the foreground.
    func retryStaleBond() {
        guard staleBond != nil else { return }
        staleBond = nil
        if central.state == .poweredOn { connectKnownOrScan() }
    }

    /// Forget the saved Passport (Device page). The bond itself lives in iOS Settings.
    func forget() {
        queue.async { [self] in
            UserDefaults.standard.removeObject(forKey: Keys.savedPeripheral)
            staleBond = nil
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil
            peripheralName = nil
            if central.state == .poweredOn { connectKnownOrScan() }
        }
    }

    // MARK: peripheral

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            set(.failed, "service missing: \(error?.localizedDescription ?? "-")")
            return
        }
        p.discoverCharacteristics([txUUID, rxUUID], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        for ch in svc.characteristics ?? [] {
            if ch.uuid == rxUUID { rx = ch }
            // TX requires an encrypted link: the first subscribe of an unbonded Passport starts
            // LE Secure Connections pairing (numeric comparison in an iOS alert and on the device).
            if ch.uuid == txUUID {
                set(.pairing)
                p.setNotifyValue(true, for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error {
            // Insufficient authentication/encryption: pairing was declined or the bond is stale.
            set(.failed, "subscribe: \(error.localizedDescription)")
            return
        }
        if ch.isNotifying, rx != nil {
            attPayload = p.maximumWriteValueLength(for: .withoutResponse)
            AppLog.shared.log("link_ready", ["att_payload": attPayload])
            set(.ready)
            onReady?()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == txUUID, let v = ch.value else { return }
        do {
            if let m = try decoder.push(v) { onMessage?(m) }
        } catch {
            AppLog.shared.log("pdu_error", ["err": "\(error)", "len": v.count])
        }
    }
}
