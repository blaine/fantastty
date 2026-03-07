import Foundation

class SSHHostStore {
    private let fileURL: URL
    private(set) var hosts: [SSHHostInfo] = []

    convenience init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fantastty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("ssh-hosts.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func add(_ host: SSHHostInfo) {
        guard !hosts.contains(host) else { return }
        hosts.append(host)
        save()
    }

    func remove(_ host: SSHHostInfo) {
        hosts.removeAll { $0 == host }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SSHHostInfo].self, from: data) else { return }
        hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
