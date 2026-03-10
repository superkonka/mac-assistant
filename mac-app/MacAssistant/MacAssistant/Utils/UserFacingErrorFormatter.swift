//
//  UserFacingErrorFormatter.swift
//  MacAssistant
//
//  将底层技术错误转换成可操作的用户提示
//

import Foundation

enum UserFacingErrorFormatter {
    static func isAuthenticationError(_ error: Error) -> Bool {
        classify(error: error).kind == .authentication
    }

    static func isStreamInterruptedError(_ error: Error) -> Bool {
        classify(error: error).kind == .streamInterrupted
    }

    static func chatMessage(for error: Error, agentName: String, providerName: String) -> String {
        let context = classify(error: error)

        switch context.kind {
        case .authentication:
            if isKimiCLIProvider(providerName) {
                return """
                我刚刚尝试让 \(agentName) 调用 Kimi CLI，但检测到这次登录状态已经失效，所以请求被拒绝了。

                这类情况通常不用重配 Agent。本地终端里重新执行一次 `kimi login`，按网页授权完成登录后，再把刚才的问题发一次就可以了。
                """
            }
            return """
            我刚刚尝试用 \(agentName) 调用 \(providerName)，但这次没有通过认证，所以服务端拒绝了请求。

            我已经先把这个 Agent 暂时跳过，避免后续请求继续撞到同一个鉴权错误。你可以打开 Agent 管理，重新配置这个 Agent；如果你不确定现有的 API Key 还是否有效，直接生成一把新的再贴进去更稳。配好后，把刚才的问题再发一次，我会继续处理。
            """
        case .missingConfiguration:
            return """
            这个 \(agentName) 还没有配置完整，我现在拿不到它可用的认证信息，所以没法继续替你发起请求。

            你可以打开 Agent 管理，把这个 Agent 重新配置一遍。配置完成后，把刚才的问题再发一次就可以了。
            """
        case .timeout:
            return """
            我已经把请求发给 \(providerName) 了，但它这次长时间没有返回，所以暂时没拿到结果。

            你可以稍等一下再试一次；如果连续几次都这样，先检查网络，或者先切换到别的 Agent 继续。
            """
        case .network:
            return """
            我刚刚在连接 \(providerName) 的时候遇到了网络问题，所以这次没有成功拿到回复。

            你可以先检查一下网络连接，或者稍后重试；如果这个问题反复出现，重新配置这个 Agent 往往更省事。
            """
        case .serviceBusy:
            return """
            我已经请求了 \(providerName)，但它现在看起来正处于限流、服务繁忙，或者暂时不可用的状态，所以这次没有顺利返回结果。

            你可以先等一会儿再试；如果你手头还有别的 Agent，也可以先切过去继续。
            """
        case .invalidPrompt:
            return """
            我刚刚尝试继续处理你的请求，但这次没有拿到有效输入，所以服务没有真正开始生成结果。

            你可以直接把问题再发一次；如果你刚刚附带了截图或文件，也建议一起重新发送。
            """
        case .streamInterrupted:
            return """
            我已经把这次请求交给 \(agentName) 和 OpenClaw 继续处理了，但最后没有等到完整的收尾事件。

            我已经把这次任务的上下文和最近输出保存在本地了，稍后会自动回查；你也可以直接在任务卡片里点“继续处理”。像部署服务、打开授权页、启动本地进程这类长任务，有时任务本身已经执行到一半甚至已经完成，只是结果没有顺利回传到主会话。
            """
        case .unknown:
            if context.detail.isEmpty {
                return """
                我刚刚尝试用 \(agentName) 处理你的问题，但这次请求没有顺利完成。

                你可以先再试一次；如果还是不行，我建议你重新配置这个 Agent，然后把刚才的问题重新发给我。
                """
            }

            return """
            我刚刚尝试用 \(agentName) 处理你的问题，但过程中遇到了一点状况。

            系统返回的信息是：\(context.detail)

            你可以先再试一次；如果这个问题持续出现，重新配置这个 Agent 通常是最快的处理方式。
            """
        }
    }

    static func setupMessage(for error: Error, providerName: String) -> String {
        let context = classify(error: error)

        switch context.kind {
        case .authentication:
            if isKimiCLIProvider(providerName) {
                return """
                我已经尝试验证 \(providerName) 的 CLI 运行时，但当前登录状态没有通过认证。

                请先在终端执行 `kimi login`，按网页授权完成登录；如果 CLI 里提示你选择 provider 或填写 API Key，也按它的引导完成，然后再回来点一次“测试连接”。
                """
            }
            return """
            我已经尝试验证 \(providerName) 的配置，但服务端没有通过认证。

            通常是 API Key 复制不完整、已经失效，或者这把 key 不属于 \(providerName)。你可以重新生成一把 key 再贴入，然后再点一次“测试连接”。
            """
        case .missingConfiguration:
            return """
            当前这组 \(providerName) 配置还不完整，所以我现在还没法帮你验证它。

            你可以把 API Key 和模型配置补全后，再重新测试一次。
            """
        case .timeout:
            return """
            我已经尝试连接 \(providerName)，但这次等待超时了，所以还不能确认配置是否可用。

            你可以先检查网络，然后再点一次“测试连接”；如果多次都这样，稍后再试通常更稳。
            """
        case .network:
            return """
            我刚刚在连接 \(providerName) 时遇到了网络问题，所以这次没法完成配置校验。

            你可以先确认网络可用，然后再重新测试；如果问题持续出现，也可以晚一点再试。
            """
        case .serviceBusy:
            return """
            我已经尝试连接 \(providerName)，但它当前看起来在限流或服务繁忙，所以这次校验没有完成。

            你可以稍后再点一次“测试连接”，或者临时先配置别的 Agent。
            """
        case .invalidPrompt:
            return """
            这次配置校验没有拿到有效请求内容，所以服务没有正常返回结果。

            你可以直接再点一次“测试连接”；如果还是出现，重新填写这组配置更稳。
            """
        case .streamInterrupted:
            return """
            我已经尝试完成这次 \(providerName) 配置校验，但最后没有等到完整的收尾事件。

            如果这是一个需要浏览器授权或本地服务启动的流程，配置本身可能已经执行到一半。你可以先确认授权、进程和本地端口状态，然后再重新测试一次。
            """
        case .unknown:
            if context.detail.isEmpty {
                return """
                我已经尝试验证 \(providerName) 的配置，但这次没有顺利完成。

                你可以先再试一次；如果还是不行，建议重新填写这组配置后再测试。
                """
            }

            return """
            我已经尝试验证 \(providerName) 的配置，但过程中遇到了一点状况。

            系统返回的信息是：\(context.detail)

            你可以先再试一次；如果问题持续出现，重新填写这组配置通常更快。
            """
        }
    }

    static func inlineMessage(for error: Error, providerName: String) -> String {
        let context = classify(error: error)

        switch context.kind {
        case .authentication:
            if isKimiCLIProvider(providerName) {
                return "我刚刚尝试调用 \(providerName)，但检测到 CLI 登录已经失效。先在终端执行 `kimi login` 完成网页登录授权，再试一次就可以了。"
            }
            return "我刚刚尝试调用 \(providerName)，但认证没有通过。你可以重新配置这个 Agent，或者换一把新的 API Key 再试。"
        case .missingConfiguration:
            return "这个 Agent 现在还没有配置完整，所以我还不能继续替你发起请求。先把配置补全，再试一次就可以了。"
        case .timeout:
            return "我已经发起请求了，但 \(providerName) 这次长时间没有返回。你可以稍后再试，或者先切换到别的 Agent。"
        case .network:
            return "我刚刚连接 \(providerName) 时遇到了网络问题，所以这次没有成功拿到结果。你可以先检查网络，再试一次。"
        case .serviceBusy:
            return "\(providerName) 当前可能在限流或服务繁忙，所以这次请求没有顺利完成。稍后再试通常就能恢复。"
        case .invalidPrompt:
            return "这次没有拿到有效输入，所以服务没有真正开始处理请求。你可以把问题重新发一次。"
        case .streamInterrupted:
            return "这次任务没有等到 OpenClaw 的完整收尾事件，但现场已经保存在本地。你可以先检查刚才创建的文件、服务或授权状态，也可以直接继续处理。"
        case .unknown:
            if context.detail.isEmpty {
                return "这次请求没有顺利完成。你可以先再试一次；如果连续出现，重新配置这个 Agent 往往更快。"
            }
            return "这次请求没有顺利完成。系统返回的信息是：\(context.detail)。你可以先再试一次。"
        }
    }

    static func normalizeCLIOutput(_ output: String, providerName: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "服务已经返回了，但这次没有拿到可显示的内容。你可以把问题再发一次。"
        }

        let context = classify(detail: trimmed, code: nil, domain: nil)
        switch context.kind {
        case .authentication, .missingConfiguration, .timeout, .network, .serviceBusy, .invalidPrompt, .streamInterrupted:
            return inlineMessage(forKind: context.kind, detail: context.detail, providerName: providerName)
        case .unknown:
            return trimmed
        }
    }

    private static func inlineMessage(forKind kind: ErrorKind, detail: String, providerName: String) -> String {
        switch kind {
        case .authentication:
            if isKimiCLIProvider(providerName) {
                return "我刚刚尝试调用 \(providerName)，但检测到 CLI 登录已经失效。先在终端执行 `kimi login`，完成网页登录授权后再试一次。"
            }
            return "我刚刚尝试调用 \(providerName)，但认证没有通过。你可以重新配置这个 Agent，或者换一把新的 API Key 再试。"
        case .missingConfiguration:
            return "这个 Agent 现在还没有配置完整，所以我还不能继续替你发起请求。先把配置补全，再试一次就可以了。"
        case .timeout:
            return "我已经发起请求了，但 \(providerName) 这次长时间没有返回。你可以稍后再试，或者先切换到别的 Agent。"
        case .network:
            return "我刚刚连接 \(providerName) 时遇到了网络问题，所以这次没有成功拿到结果。你可以先检查网络，再试一次。"
        case .serviceBusy:
            return "\(providerName) 当前可能在限流或服务繁忙，所以这次请求没有顺利完成。稍后再试通常就能恢复。"
        case .invalidPrompt:
            return "这次没有拿到有效输入，所以服务没有真正开始处理请求。你可以把问题重新发一次。"
        case .streamInterrupted:
            return "这次任务没有等到完整的收尾事件，但现场已经保存在本地。你可以先检查本地状态，再决定是否继续。"
        case .unknown:
            if detail.isEmpty {
                return "这次请求没有顺利完成。你可以先再试一次。"
            }
            return "这次请求没有顺利完成。系统返回的信息是：\(detail)。你可以先再试一次。"
        }
    }

    private static func classify(error: Error) -> ErrorContext {
        let nsError = error as NSError
        return classify(
            detail: nsError.localizedDescription,
            code: nsError.code,
            domain: nsError.domain
        )
    }

    private static func classify(detail: String, code: Int?, domain: String?) -> ErrorContext {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalizedDetail.lowercased()

        if let domain,
           domain == NSURLErrorDomain,
           let code {
            let urlError = URLError.Code(rawValue: code)
            switch urlError {
            case .timedOut:
                return ErrorContext(kind: .timeout, detail: normalizedDetail)
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
                return ErrorContext(kind: .network, detail: normalizedDetail)
            default:
                break
            }
        }

        if code == 401 || code == 403 || containsAny(lowercased, [
            "invalid authentication",
            "authentication failed",
            "unauthorized",
            "invalid api key",
            "invalid_api_key",
            "api key is invalid",
            "鉴权失败",
            "未授权"
        ]) {
            return ErrorContext(kind: .authentication, detail: normalizedDetail)
        }

        if containsAny(lowercased, [
            "缺少认证配置",
            "api key 为空",
            "missing api key",
            "missing authentication",
            "not configured",
            "未配置",
            "重新配置该 agent"
        ]) {
            return ErrorContext(kind: .missingConfiguration, detail: normalizedDetail)
        }

        if code == 408 || containsAny(lowercased, [
            "timeout",
            "timed out",
            "请求超时",
            "超时"
        ]) {
            return ErrorContext(kind: .timeout, detail: normalizedDetail)
        }

        if containsAny(lowercased, [
            "could not connect",
            "failed to connect",
            "network",
            "network connection lost",
            "无法连接",
            "网络错误",
            "dns"
        ]) {
            return ErrorContext(kind: .network, detail: normalizedDetail)
        }

        if code == 429 || (500...504).contains(code ?? -1) || containsAny(lowercased, [
            "rate limit",
            "too many requests",
            "quota",
            "insufficient_quota",
            "temporarily unavailable",
            "service unavailable",
            "overloaded",
            "繁忙",
            "限流"
        ]) {
            return ErrorContext(kind: .serviceBusy, detail: normalizedDetail)
        }

        if containsAny(lowercased, [
            "usage: kimi",
            "prompt cannot be empty",
            "prompt is empty",
            "invalid value for --prompt",
            "empty prompt"
        ]) {
            return ErrorContext(kind: .invalidPrompt, detail: normalizedDetail)
        }

        if containsAny(lowercased, [
            "openclaw 事件流意外结束",
            "event stream ended unexpectedly",
            "stream ended unexpectedly"
        ]) {
            return ErrorContext(kind: .streamInterrupted, detail: normalizedDetail)
        }

        return ErrorContext(kind: .unknown, detail: normalizedDetail)
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static func isKimiCLIProvider(_ providerName: String) -> Bool {
        let normalized = providerName.lowercased()
        return normalized.contains("kimi") && normalized.contains("cli")
    }
}

private struct ErrorContext {
    let kind: ErrorKind
    let detail: String
}

private enum ErrorKind {
    case authentication
    case missingConfiguration
    case timeout
    case network
    case serviceBusy
    case invalidPrompt
    case streamInterrupted
    case unknown
}
