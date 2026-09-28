// zmkbat: print battery levels of a connected ZMK split keyboard.
// Central (left) = BAS without user description; peripherals = "Peripheral N" (ZMK central_bas_proxy).
import CoreBluetooth
import Foundation

let bas = CBUUID(string: "180F"), level = CBUUID(string: "2A19"), cud = CBUUID(string: "2901")
let nameFilter = CommandLine.arguments.dropFirst().first ?? "Corne"

final class Reader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var target: CBPeripheral?
    var pending = 0
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
        for s in p.services ?? [] { p.discoverCharacteristics([level], for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == level {
            pending += 1
            p.discoverDescriptors(for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error: Error?) {
        if let d = ch.descriptors?.first(where: { $0.uuid == cud }) {
            p.readValue(for: d)
        } else {
            p.readValue(for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor d: CBDescriptor, error: Error?) {
        p.readValue(for: d.characteristic!)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let desc = ch.descriptors?.first(where: { $0.uuid == cud })?.value as? String
        let label = desc.map { $0.contains("Peripheral 0") ? "R" : $0 } ?? "L"
        if let v = ch.value?.first { levels[label] = Int(v) }
        pending -= 1
        if pending == 0 { done() }
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
