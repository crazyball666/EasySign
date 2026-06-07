import Foundation

/// 已配对设备列表持久化(UserDefaults,JSON)。
final class PairedPeerStore {
    private let defaults = UserDefaults.standard
    private let key = "transfer.pairedPeers"

    func all() -> [PairedPeer] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([PairedPeer].self, from: data)
        else { return [] }
        return list
    }
    func peer(forFingerprint fp: String) -> PairedPeer? {
        all().first { $0.fingerprint == fp }
    }
    func upsert(_ peer: PairedPeer) {
        var list = all().filter { $0.deviceId != peer.deviceId }
        list.append(peer)
        save(list)
    }
    func remove(deviceId: String) {
        save(all().filter { $0.deviceId != deviceId })
    }
    func removeAll() {
        defaults.removeObject(forKey: key)
    }
    private func save(_ list: [PairedPeer]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}
