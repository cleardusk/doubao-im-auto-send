import CFNetwork
import Foundation

enum HTTPTransportSupport {
    struct ProxySpec {
        let host: String
        let port: Int
        let isSOCKS: Bool
    }

    static func makeEphemeralSession(environment: [String: String]) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxyDictionary = proxyDictionary(from: environment) {
            configuration.connectionProxyDictionary = proxyDictionary
        }
        return URLSession(configuration: configuration)
    }

    static func proxyDictionary(from environment: [String: String]) -> [AnyHashable: Any]? {
        let httpProxy = parseProxy(
            environment["HTTP_PROXY"] ??
            environment["http_proxy"] ??
            environment["ALL_PROXY"] ??
            environment["all_proxy"]
        )
        let httpsProxy = parseProxy(
            environment["HTTPS_PROXY"] ??
            environment["https_proxy"] ??
            environment["ALL_PROXY"] ??
            environment["all_proxy"] ??
            environment["HTTP_PROXY"] ??
            environment["http_proxy"]
        )

        var dictionary: [AnyHashable: Any] = [:]

        if let httpProxy {
            if httpProxy.isSOCKS {
                dictionary[kCFNetworkProxiesSOCKSEnable as String] = 1
                dictionary[kCFNetworkProxiesSOCKSProxy as String] = httpProxy.host
                dictionary[kCFNetworkProxiesSOCKSPort as String] = httpProxy.port
            } else {
                dictionary[kCFNetworkProxiesHTTPEnable as String] = 1
                dictionary[kCFNetworkProxiesHTTPProxy as String] = httpProxy.host
                dictionary[kCFNetworkProxiesHTTPPort as String] = httpProxy.port
            }
        }

        if let httpsProxy {
            if httpsProxy.isSOCKS {
                dictionary[kCFNetworkProxiesSOCKSEnable as String] = 1
                dictionary[kCFNetworkProxiesSOCKSProxy as String] = httpsProxy.host
                dictionary[kCFNetworkProxiesSOCKSPort as String] = httpsProxy.port
            } else {
                dictionary[kCFNetworkProxiesHTTPSEnable as String] = 1
                dictionary[kCFNetworkProxiesHTTPSProxy as String] = httpsProxy.host
                dictionary[kCFNetworkProxiesHTTPSPort as String] = httpsProxy.port
            }
        }

        return dictionary.isEmpty ? nil : dictionary
    }

    static func parseProxy(_ value: String?) -> ProxySpec? {
        guard let value, !value.isEmpty, let components = URLComponents(string: value), let host = components.host else {
            return nil
        }

        let scheme = components.scheme?.lowercased() ?? "http"
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return ProxySpec(host: host, port: port, isSOCKS: scheme.hasPrefix("socks"))
    }
}
