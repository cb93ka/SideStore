//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        if let data = await fetchFromMac() {
            return data
        }
        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Attempting On-Device Anisette (ODA)...")
            do {
                let data = try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
                debugLog("[AnisetteProvider] On-Device Anisette succeeded.")
                return data
            } catch {
                debugLog("[AnisetteProvider] On-Device Anisette failed (\(error.localizedDescription)). Seamlessly falling back to remote Anisette servers...")
                return try await fetchRemote(handler: handler)
            }
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await fetchRemote(handler: handler)
        }
    }

    /// A Mac on the same network running mac-anisette (an _http._tcp Bonjour service named "MacAnisette-…") serves its
    /// own anisette, which Apple accepts where it refuses the remote servers' identities. nil when there is none.
    private static func fetchFromMac() async -> ALTAnisetteData? {
        guard let found = await BonjourDiscoveryManager.resolveFirstService(ofType: "_http._tcp", namePrefix: "MacAnisette", timeout: 2) else {
            return nil
        }
        let host = found.host.strippingInterfaceScope
        guard let url = URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(found.port)/") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let headers = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                debugLog("[AnisetteProvider] Mac anisette at \(url.absoluteString) gave no headers")
                return nil
            }
            let anisette = try SideSign.AnisetteDataManager.validateAndCreateAnisetteData(from: headers)
            debugLog("[AnisetteProvider] Using this network's Mac anisette from \(url.absoluteString) (\(anisette.clientInfo))")
            return anisette
        } catch {
            debugLog("[AnisetteProvider] Mac anisette at \(url.absoluteString) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        let servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0

        let provider = SideSign.AnisetteDataManager.shared
        let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }
        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()
        let headers = await AnisetteConfigManager.shared.makeRequestHeaders()

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            onError: { error in
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            },
            onSuccess: { successfulServer in
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(successfulServer.absoluteString)")
            }
        )

        if let freshBlob = newAdiBlob {
            AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
        }

        return anisetteData
    }
}
