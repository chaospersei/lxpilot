import Foundation
import CryptoKit

/// Downloads the latest stable sing-box-lx release for this Mac and verifies it against SHA256SUMS.
enum CoreInstaller {
    static let releasesAPI = "https://api.github.com/repos/Leadaxe/sing-box-lx/releases/latest"

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    static func installLatest(status: @MainActor @Sendable (String) -> Void) async throws -> String {
        await status("Запрос последнего релиза…")
        guard let apiURL = URL(string: releasesAPI) else { throw AppError("Некорректный адрес релизов.") }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LxPilot", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError("GitHub не отдал список релизов (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)

        let marker = "darwin-\(architecture)"
        guard let asset = release.assets.first(where: { $0.name.contains(marker) && $0.name.hasSuffix(".tar.gz") }),
              let assetURL = URL(string: asset.browser_download_url) else {
            throw AppError("В релизе \(release.tag_name) нет сборки \(marker).")
        }

        await status("Загрузка \(asset.name)…")
        let (downloaded, _) = try await URLSession.shared.download(from: assetURL)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("lxpilot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent(asset.name)
        try fm.moveItem(at: downloaded, to: archive)

        await status("Проверка контрольной суммы…")
        if let sums = release.assets.first(where: { $0.name == "SHA256SUMS" }), let sumsURL = URL(string: sums.browser_download_url) {
            let (sumsData, _) = try await URLSession.shared.data(from: sumsURL)
            let sumsText = String(data: sumsData, encoding: .utf8) ?? ""
            let expected = sumsText
                .components(separatedBy: .newlines)
                .first(where: { $0.contains(asset.name) })?
                .split(separator: " ").first
                .map { String($0).lowercased() }
            let digest = SHA256.hash(data: try Data(contentsOf: archive))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard let expected else {
                throw AppError("В SHA256SUMS нет записи для \(asset.name).")
            }
            guard expected == actual else {
                throw AppError("Контрольная сумма \(asset.name) не совпала с SHA256SUMS — файл не установлен.")
            }
        } else {
            throw AppError("В релизе \(release.tag_name) нет файла SHA256SUMS — установка отменена.")
        }

        await status("Распаковка…")
        let unpack = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        let tar = await Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", unpack.path])
        guard tar.ok else { throw AppError("Не удалось распаковать архив: \(tar.combined)") }

        var binary: URL?
        if let walker = fm.enumerator(at: unpack, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent == "sing-box" {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    binary = url
                    break
                }
            }
        }
        guard let binary else { throw AppError("В архиве не найден файл sing-box.") }
        try install(from: binary)
        return release.tag_name
    }

    /// Copies a binary into the app's own bin directory and makes it executable.
    static func install(from source: URL) throws {
        let fm = FileManager.default
        let target = Paths.coreBinary
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        Shell.runSync("/usr/bin/xattr", ["-d", "com.apple.quarantine", target.path])
    }
}
