import Foundation

final class LocalKimiCLIService {
    static let shared = LocalKimiCLIService()

    private init() {}

    func sendMessage(
        text: String,
        attachments: [String],
        sessionKey: String?,
        timeout: TimeInterval = 180
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            if let attachmentError = self.unsupportedAttachmentMessage(for: attachments) {
                throw NSError(
                    domain: "LocalKimiCLIService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: attachmentError]
                )
            }

            guard let executablePath = self.resolveExecutablePath() else {
                throw NSError(
                    domain: "LocalKimiCLIService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "未找到 `kimi` 命令，请先安装 Kimi CLI。"]
                )
            }

            let prompt = self.composePrompt(text: text, attachments: attachments)
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = self.arguments(sessionKey: sessionKey)
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = self.commandSearchPath()
            environment["KIMI_NO_COLOR"] = "1"
            environment["LANG"] = "zh_CN.UTF-8"
            process.environment = environment

            let promptData = Data(prompt.utf8)
            var didTimeout = false
            let timeoutWorkItem = DispatchWorkItem {
                didTimeout = true
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
                try inputPipe.fileHandleForWriting.write(contentsOf: promptData)
                try inputPipe.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let rawOutput = String(data: outputData, encoding: .utf8) ?? ""
                let output = self.sanitizedOutput(rawOutput)

                if didTimeout {
                    throw NSError(
                        domain: NSURLErrorDomain,
                        code: URLError.timedOut.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "Kimi CLI 响应超时。"]
                    )
                }

                if UserFacingErrorFormatter.isAuthenticationError(
                    NSError(
                        domain: "LocalKimiCLIService",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: rawOutput]
                    )
                ) || rawOutput.lowercased().contains("invalid_authentication_error") {
                    throw NSError(
                        domain: "LocalKimiCLIService",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: rawOutput]
                    )
                }

                if process.terminationStatus != 0 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw NSError(
                        domain: "LocalKimiCLIService",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)]
                    )
                }

                return UserFacingErrorFormatter.normalizeCLIOutput(output.isEmpty ? rawOutput : output, providerName: "本地 Kimi CLI")
            } catch {
                timeoutWorkItem.cancel()
                throw error
            }
        }.value
    }

    private func arguments(sessionKey: String?) -> [String] {
        var arguments = [
            "--quiet",
            "-y",
            "--print",
            "--input-format", "text",
            "--output-format", "text",
            "--final-message-only",
        ]

        if let sessionKey = normalizedSessionKey(sessionKey) {
            arguments.append(contentsOf: ["--session", sessionKey])
        }

        return arguments
    }

    private func normalizedSessionKey(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return trimmed
            .lowercased()
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private func composePrompt(text: String, attachments: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentBlock = attachments.compactMap(readTextAttachment).joined(separator: "\n\n")

        if attachmentBlock.isEmpty {
            return trimmed.isEmpty ? "你好" : trimmed
        }

        if trimmed.isEmpty {
            return attachmentBlock
        }

        return "\(attachmentBlock)\n\n\(trimmed)"
    }

    private func readTextAttachment(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let textExtensions = Set([
            "txt", "md", "markdown", "json", "yaml", "yml", "xml",
            "swift", "py", "js", "ts", "tsx", "jsx", "html", "css",
            "sh", "zsh", "bash", "log", "csv"
        ])

        guard textExtensions.contains(url.pathExtension.lowercased()),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return "附件文件: \(path)\n\(content)"
    }

    private func unsupportedAttachmentMessage(for attachments: [String]) -> String? {
        let imageExtensions = Set(["png", "jpg", "jpeg", "webp", "gif", "heic", "bmp", "tiff"])
        let hasImageAttachment = attachments.contains { path in
            imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }

        return hasImageAttachment
            ? "当前本地 Kimi CLI 不支持图片附件分析，因此无法直接查看截图。请切换到支持视觉的 API Agent。"
            : nil
    }

    private func resolveExecutablePath() -> String? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kimi").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin/kimi").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pyenv/shims/kimi").path,
            "/opt/homebrew/bin/kimi",
            "/usr/local/bin/kimi",
            "/usr/bin/kimi",
        ]

        if let directMatch = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return directMatch
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "kimi"]
        task.standardOutput = pipe
        task.standardError = pipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = commandSearchPath()
        task.environment = environment

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private func commandSearchPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entries = [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.pyenv/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/sbin",
            "/usr/sbin"
        ]

        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private func sanitizedOutput(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isBenignShellNoiseLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isBenignShellNoiseLine(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        return normalized.contains("command not found: pyenv") ||
            normalized.contains("pyenv:") && normalized.contains("command not found") ||
            normalized.contains("compdef: command not found") ||
            normalized.contains("zsh compinit:")
    }
}
