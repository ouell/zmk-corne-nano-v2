// zmkbat: print battery levels of a connected ZMK split keyboard.
// Central (left) = BAS without user description; peripherals = "Peripheral N" (ZMK central_bas_proxy).
import CoreBluetooth
import Foundation

let bas = CBUUID(string: "180F"), level = CBUUID(string: "2A19"), cud = CBUUID(string: "2901")
let nameFilter = CommandLine.arguments.dropFirst().first ?? "Corne"

final class Reader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var target: CBPeripheral?
    var servicesPending = 0  // Battery Services still discovering characteristics
    var pending = 0          // battery level reads in flight
    var levels: [String: Int] = [:]  // label -> percent

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            if c.state == .unauthorized { fail("bluetooth not authorized") }
            if c.state == .poweredOff { fail("bluetooth off") }
            return
        }
        guard let p = c.retrieveConnectedPeripherals(withServices: [bas])
            .first(where: { ($0.name ?? "").contains(nameFilter) })
        else { fail("\(nameFilter) not connected") }
        target = p
        p.delegate = self
        c.connect(p)  // already connected at OS level; this just opens our GATT session
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([bas])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("service discovery: \(error.localizedDescription)") }
        let services = p.services ?? []
        if services.isEmpty { fail("no battery service") }
        servicesPending = services.count
        for s in services { p.discoverCharacteristics([level], for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let error { fail("characteristic discovery: \(error.localizedDescription)") }
        servicesPending -= 1
        for ch in s.characteristics ?? [] where ch.uuid == level {
            pending += 1
            p.discoverDescriptors(for: ch)
        }
        finishIfDone()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error: Error?) {
        if let error { fail("descriptor discovery: \(error.localizedDescription)") }
        if let d = ch.descriptors?.first(where: { $0.uuid == cud }) {
            p.readValue(for: d)
        } else {
            p.readValue(for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor d: CBDescriptor, error: Error?) {
        if let error { fail("descriptor read: \(error.localizedDescription)") }
        p.readValue(for: d.characteristic!)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let desc = ch.descriptors?.first(where: { $0.uuid == cud })?.value as? String
        let label = desc.map { $0.contains("Peripheral 0") ? "R" : $0 } ?? "L"
        if let error { fail("battery read (\(label)): \(error.localizedDescription)") }
        guard let v = ch.value?.first else { fail("battery read (\(label)): no value") }
        levels[label] = Int(v)
        pending -= 1
        finishIfDone()
    }

    // Done only when every service was explored and every read came back.
    func finishIfDone() {
        guard servicesPending == 0, pending == 0 else { return }
        if levels.isEmpty { fail("no battery level characteristic") }
        done()
    }

    func done() {
        let order = ["L", "R"]
        let keys = levels.keys.sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
        print(keys.map { "\($0):\(levels[$0]!)%" }.joined(separator: " "))
        exit(0)
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let reader = Reader()
DispatchQueue.main.asyncAfter(deadline: .now() + 8) { fail("timeout") }
RunLoop.main.run()
