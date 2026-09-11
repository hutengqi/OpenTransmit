import Foundation
import Observation

@MainActor @Observable final class LibraryStore {
    var servers: [ServerProfile] = []
    var workspaces: [Workspace] = []
    var error: String?
    private struct Library: Codable { var servers: [ServerProfile]; var workspaces: [Workspace] }
    init() {
        guard let data = UserDefaults.standard.data(forKey: "library.v1") else { return }
        do {
            let saved = try JSONDecoder().decode(Library.self, from: data)
            servers = saved.servers
            workspaces = saved.workspaces
        } catch { self.error = "无法读取保存的资料：\(error.localizedDescription)" }
    }
    func deleteServer(_ server: ServerProfile) {
        do {
            try CredentialVault(server: server).removeAll()
            servers.removeAll { $0.id == server.id }
            save()
        } catch { self.error = error.localizedDescription }
    }
    func save() {
        do {
            let data = try JSONEncoder().encode(Library(servers: servers, workspaces: workspaces))
            UserDefaults.standard.set(data, forKey: "library.v1")
        } catch { self.error = error.localizedDescription }
    }
}
