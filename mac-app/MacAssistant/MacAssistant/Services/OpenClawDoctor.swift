import AppKit
import Foundation

@MainActor
final class OpenClawDoctor: ObservableObject {
    enum Status: Equatable {
        case checking
        case healthy
        case externalHealthy
        case needsRepair
        case missingBundle
        case repairing
        case reinstalling

        var title: String {
            switch self {
            case .checking:
                return "检查中"
            case .healthy:
                return "运行正常"
            case .externalHealthy:
                return "兼容运行"
            case .needsRepair:
                return "需要修复"
            case .missingBundle:
                return "缺少运行时"
            case .repairing:
                return "正在修复"
            case .reinstalling:
                return "正在重装"
            }
        }

        var shortLabel: String {
            switch self {
            case .checking:
                return "Claw 检查中"
            case .healthy:
                return "Claw 正常"
            case .externalHealthy:
                return "Claw 兼容"
            case .needsRepair:
                return "Claw 异常"
            case .missingBundle:
                return "Claw 缺失"
            case .repairing:
                return "Claw 修复中"
            case .reinstalling:
                return "Claw 重装中"
            }
        }

        var iconName: String {
            switch self {
            case .checking:
                return "arrow.triangle.2.circlepath"
            case .healthy:
                return "checkmark.circle.fill"
            case .externalHealthy:
                return "checkmark.circle"
            case .needsRepair:
                return "wrench.and.screwdriver.fill"
            case .missingBundle:
                return "exclamationmark.triangle.fill"
            case .repairing:
                return "stethoscope"
            case .reinstalling:
                return "arrow.down.circle.fill"
            }
        }
    }

    struct Snapshot: Equatable {
        let status: Status
        let summary: String
        let detail: String
        let recommendation: String
        let sourceLabel: String
        let executablePath: String?
        let version: String?
        let readinessDescription: String
        let runtimeDirectory: String
        let configPath: String
        let logPath: String
        let logExcerpt: String?
        let lastCheckedAt: Date?
        let canRepair: Bool
        let canReinstall: Bool
    }

    static let shared = OpenClawDoctor()

    @Published private(set) var snapshot = Snapshot(
        status: .checking,
        summary: "正在检查 OpenClaw 运行状态。",
        detail: "应用会优先使用内置的 OpenClaw 运行时，并在需要时自动修复。",
        recommendation: "稍候会自动刷新状态。",
        sourceLabel: "--",
        executablePath: nil,
        version: nil,
        readinessDescription: "未检查",
        runtimeDirectory: "--",
        configPath: "--",
        logPath: "--",
        logExcerpt: nil,
        lastCheckedAt: nil,
        canRepair: false,
        canReinstall: false
    )

    @Published private(set) var isRefreshing = false
    @Published private(set) var isRepairing = false
    @Published private(set) var isReinstalling = false

    private let dependencyManager = DependencyManager.shared
    private let runtimeManager = OpenClawGatewayRuntimeManager.shared

    private var refreshTimer: Timer?
    private var hasStarted = false
    private var lastAutoRepairAt = Date.distantPast
    private var lastOperationMessage: String?
    private let autoRepairCooldown: TimeInterval = 90

    func startMonitoring() {
        guard !hasStarted else { return }
        hasStarted = true

        refresh(allowAutoRepair: true)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(allowAutoRepair: true)
            }
        }
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hasStarted = false
    }

    func refresh(allowAutoRepair: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            let binary = await dependencyManager.inspectOpenClawInstallation()
            let gateway = await runtimeManager.inspectGatewayState(preferredExecutablePath: binary.executablePath)
            let logExcerpt = Self.tailLog(at: gateway.logPath)
            let updatedSnapshot = buildSnapshot(binary: binary, gateway: gateway, logExcerpt: logExcerpt)

            self.snapshot = updatedSnapshot
            self.isRefreshing = false

            if allowAutoRepair {
                maybeAutoRepair(for: updatedSnapshot)
            }
        }
    }

    func repair() {
        guard !isRepairing, !isReinstalling else { return }

        isRepairing = true
        lastOperationMessage = nil
        snapshot = snapshotWithTransientStatus(.repairing)

        Task {
            do {
                _ = try await dependencyManager.ensureOpenClawAvailable()

                do {
                    _ = try await runtimeManager.prepareGatewayWithDependencies()
                } catch {
                    LogError("OpenClaw 轻修复失败，准备重建运行时后重试", error: error)
                    try await runtimeManager.resetRuntimeState(preserveWorkspace: true)
                    _ = try await dependencyManager.ensureOpenClawAvailable()
                    _ = try await runtimeManager.prepareGatewayWithDependencies()
                }

                lastOperationMessage = "已完成自动修复，OpenClaw 已重新检查。"
            } catch {
                LogError("OpenClaw 自动修复失败", error: error)
                lastOperationMessage = error.localizedDescription
            }

            isRepairing = false
            refresh(allowAutoRepair: false)
        }
    }

    func reinstall() {
        guard !isRepairing, !isReinstalling else { return }

        isReinstalling = true
        lastOperationMessage = nil
        snapshot = snapshotWithTransientStatus(.reinstalling)

        Task {
            do {
                try await runtimeManager.stopGateway()
                try await runtimeManager.resetRuntimeState(preserveWorkspace: true)
                _ = try await dependencyManager.reinstallManagedOpenClaw()
                _ = try await runtimeManager.prepareGatewayWithDependencies()
                lastOperationMessage = "已完成 OpenClaw 重装，workspace 和 skills 已保留。"
            } catch {
                LogError("OpenClaw 重装失败", error: error)
                lastOperationMessage = error.localizedDescription
            }

            isReinstalling = false
            refresh(allowAutoRepair: false)
        }
    }

    func openRuntimeDirectory() {
        NSWorkspace.shared.open(runtimeManager.profileDirectory())
    }

    func openLogDirectory() {
        NSWorkspace.shared.open(runtimeManager.gatewayLogPath().deletingLastPathComponent())
    }

    func openConfigFile() {
        NSWorkspace.shared.open(runtimeManager.configPath())
    }

    private func maybeAutoRepair(for snapshot: Snapshot) {
        guard snapshot.canRepair else { return }
        guard snapshot.status == .needsRepair else { return }
        guard Date().timeIntervalSince(lastAutoRepairAt) >= autoRepairCooldown else { return }

        lastAutoRepairAt = Date()
        repair()
    }

    private func buildSnapshot(
        binary: OpenClawBinaryInspection,
        gateway: OpenClawGatewayRuntimeManager.GatewayInspection,
        logExcerpt: String?
    ) -> Snapshot {
        let runtimeDirectory = gateway.profileDirectory.path
        let configPath = gateway.configPath.path
        let logPath = gateway.logPath.path
        let detailSuffix = lastOperationMessage.map { "\n\($0)" } ?? ""

        if isRepairing {
            return Snapshot(
                status: .repairing,
                summary: "正在重建 OpenClaw 运行时并重启 gateway。",
                detail: "应用会优先保留 workspace 和 skills，只重建运行配置。\(detailSuffix)",
                recommendation: "请稍候，修复完成后会自动刷新。",
                sourceLabel: binary.source.displayName,
                executablePath: binary.executablePath,
                version: binary.version,
                readinessDescription: gateway.readinessDescription,
                runtimeDirectory: runtimeDirectory,
                configPath: configPath,
                logPath: logPath,
                logExcerpt: logExcerpt,
                lastCheckedAt: Date(),
                canRepair: false,
                canReinstall: false
            )
        }

        if isReinstalling {
            return Snapshot(
                status: .reinstalling,
                summary: "正在使用 App Bundle 里的 OpenClaw 重新安装运行时。",
                detail: "这会替换应用管理的 OpenClaw 副本，但会保留 workspace 和 skills。\(detailSuffix)",
                recommendation: "请稍候，完成后会自动重新启动 gateway。",
                sourceLabel: binary.source.displayName,
                executablePath: binary.executablePath,
                version: binary.version,
                readinessDescription: gateway.readinessDescription,
                runtimeDirectory: runtimeDirectory,
                configPath: configPath,
                logPath: logPath,
                logExcerpt: logExcerpt,
                lastCheckedAt: Date(),
                canRepair: false,
                canReinstall: false
            )
        }

        if binary.source == .missing {
            return Snapshot(
                status: .missingBundle,
                summary: "当前 App Bundle 里没有可用的 OpenClaw，无法在本机自愈安装。",
                detail: "这通常说明安装包不完整，或当前产物没有打入 `openclaw` 资源。\n\(binary.issue ?? "请重新下载或替换正确的安装包。")\(detailSuffix)",
                recommendation: "重新下载带有 OpenClaw runtime 的安装包后再试。",
                sourceLabel: binary.source.displayName,
                executablePath: nil,
                version: nil,
                readinessDescription: gateway.readinessDescription,
                runtimeDirectory: runtimeDirectory,
                configPath: configPath,
                logPath: logPath,
                logExcerpt: logExcerpt,
                lastCheckedAt: Date(),
                canRepair: false,
                canReinstall: false
            )
        }

        if let issue = binary.issue {
            return Snapshot(
                status: .needsRepair,
                summary: "OpenClaw 可执行文件存在，但当前不可用。",
                detail: "\(issue)\n应用会优先修复到受控运行时副本。\(detailSuffix)",
                recommendation: binary.canInstallFromBundle
                    ? "可以先点“自动修复”；如果仍失败，再执行“重装 Claw”。"
                    : "当前没有 bundle 可重装，只能替换安装包。",
                sourceLabel: binary.source.displayName,
                executablePath: binary.executablePath ?? binary.managedInstallPath,
                version: binary.version,
                readinessDescription: gateway.readinessDescription,
                runtimeDirectory: runtimeDirectory,
                configPath: configPath,
                logPath: logPath,
                logExcerpt: logExcerpt,
                lastCheckedAt: Date(),
                canRepair: true,
                canReinstall: binary.canInstallFromBundle
            )
        }

        if binary.source == .bundledOnly {
            return Snapshot(
                status: .needsRepair,
                summary: "App Bundle 已携带 OpenClaw，但本机运行时副本还没有安装好。",
                detail: "这类情况通常可以直接通过自动修复安装到应用运行时目录。\(detailSuffix)",
                recommendation: "点“自动修复”即可安装并启动 OpenClaw。",
                sourceLabel: binary.source.displayName,
                executablePath: nil,
                version: nil,
                readinessDescription: gateway.readinessDescription,
                runtimeDirectory: runtimeDirectory,
                configPath: configPath,
                logPath: logPath,
                logExcerpt: logExcerpt,
                lastCheckedAt: Date(),
                canRepair: true,
                canReinstall: true
            )
        }

        if !gateway.configExists {
            return Snapshot(
                status: .needsRepair,
                summary: "OpenClaw 二进制可用，但 wrapper 配置还没准备好。",
                detail: "配置文件当前缺失：\(configPath)\n自动修复会重建配置并启动 gateway。\(detailSuffix)",
                recommendation: "点“自动修复”重建 runtime 配置。",
                sourceLabel: binary.source.displayName,
                executablePath: binary.executablePath,
                version: binary.version,
                readinessDescription: gateway.readinessDescription,
                runtimeDirectory: runtimeDirectory,
                configPath: configPath,
                logPath: logPath,
                logExcerpt: logExcerpt,
                lastCheckedAt: Date(),
                canRepair: true,
                canReinstall: binary.canInstallFromBundle
            )
        }

        if gateway.healthCheckSucceeded {
            if binary.isExternalSource {
                return Snapshot(
                    status: .externalHealthy,
                    summary: "OpenClaw 当前可用，但运行在外部安装源上。",
                    detail: "当前来源：\(binary.source.displayName)\n为了跨设备更稳定，建议迁移到应用自管运行时。\(detailSuffix)",
                    recommendation: binary.canInstallFromBundle
                        ? "可选：点“重装 Claw”迁移到应用管理版本。"
                        : "当前兼容模式可继续使用。",
                    sourceLabel: binary.source.displayName,
                    executablePath: binary.executablePath,
                    version: binary.version,
                    readinessDescription: gateway.readinessDescription,
                    runtimeDirectory: runtimeDirectory,
                    configPath: configPath,
                    logPath: logPath,
                    logExcerpt: logExcerpt,
                    lastCheckedAt: Date(),
                    canRepair: false,
                    canReinstall: binary.canInstallFromBundle
                )
            }

            return Snapshot(
                status: .healthy,
                summary: "OpenClaw gateway 运行正常，当前请求会优先走受控 runtime。",
                detail: "来源：\(binary.source.displayName)\n状态：\(gateway.readinessDescription)\(detailSuffix)",
                recommendation: "如果你怀疑是环境问题，可以查看 runtime 目录和 gateway 日志。",
                sourceLabel: binary.source.displayName,
                executablePath: binary.executablePath,
                version: binary.version,
                readinessDescription: gateway.readinessDescription,
                runtimeDirectory: runtimeDirectory,
                configPath: configPath,
                logPath: logPath,
                logExcerpt: logExcerpt,
                lastCheckedAt: Date(),
                canRepair: false,
                canReinstall: binary.canInstallFromBundle
            )
        }

        let healthOutput = gateway.healthCheckOutput.isEmpty ? "没有拿到 gateway 健康返回。" : gateway.healthCheckOutput
        let processDescription = gateway.processRunning ? "gateway 进程仍在，但健康检查失败。" : "gateway 当前没有正常响应。"
        return Snapshot(
            status: .needsRepair,
            summary: "OpenClaw 二进制可用，但 gateway 当前没有通过健康检查。",
            detail: "\(processDescription)\n\(healthOutput)\(detailSuffix)",
            recommendation: binary.canInstallFromBundle
                ? "先点“自动修复”；如果仍失败，再点“重装 Claw”。"
                : "当前没有 bundle 可重装，只能先执行自动修复或替换安装包。",
            sourceLabel: binary.source.displayName,
            executablePath: binary.executablePath,
            version: binary.version,
            readinessDescription: gateway.readinessDescription,
            runtimeDirectory: runtimeDirectory,
            configPath: configPath,
            logPath: logPath,
            logExcerpt: logExcerpt,
            lastCheckedAt: Date(),
            canRepair: true,
            canReinstall: binary.canInstallFromBundle
        )
    }

    private func snapshotWithTransientStatus(_ status: Status) -> Snapshot {
        Snapshot(
            status: status,
            summary: snapshot.summary,
            detail: snapshot.detail,
            recommendation: snapshot.recommendation,
            sourceLabel: snapshot.sourceLabel,
            executablePath: snapshot.executablePath,
            version: snapshot.version,
            readinessDescription: snapshot.readinessDescription,
            runtimeDirectory: snapshot.runtimeDirectory,
            configPath: snapshot.configPath,
            logPath: snapshot.logPath,
            logExcerpt: snapshot.logExcerpt,
            lastCheckedAt: Date(),
            canRepair: false,
            canReinstall: false
        )
    }

    private static func tailLog(at url: URL, maxLines: Int = 10) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .map(String.init)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return lines.isEmpty ? nil : lines
    }
}
