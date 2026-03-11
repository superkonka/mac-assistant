import SwiftUI

struct OpenClawStatusEntry: View {
    @ObservedObject var doctor: OpenClawDoctor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: doctor.snapshot.status.iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(doctor.snapshot.status.shortLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if doctor.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .foregroundColor(statusColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(statusColor.opacity(0.12))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(statusColor.opacity(0.22), lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(doctor.snapshot.summary)
    }

    private var statusColor: Color {
        switch doctor.snapshot.status {
        case .checking:
            return .secondary
        case .healthy:
            return .green
        case .externalHealthy:
            return .orange
        case .needsRepair:
            return .orange
        case .missingBundle:
            return .red
        case .repairing, .reinstalling:
            return .blue
        }
    }
}

struct OpenClawDoctorPanelView: View {
    @ObservedObject var doctor: OpenClawDoctor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    actionRow
                    pathSection

                    if let excerpt = doctor.snapshot.logExcerpt {
                        logSection(excerpt: excerpt)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 500)
        .background(AppColors.controlBackground)
        .task {
            doctor.refresh(allowAutoRepair: false)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: doctor.snapshot.status.iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("OpenClaw 运行时")
                    .font(.system(size: 17, weight: .semibold))
                Text(doctor.snapshot.status.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
            }

            Spacer()

            Button {
                doctor.refresh(allowAutoRepair: false)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("重新检查 OpenClaw 状态")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(doctor.snapshot.summary)
                .font(.system(size: 14, weight: .semibold))

            Text(doctor.snapshot.detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("建议：\(doctor.snapshot.recommendation)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            HStack(spacing: 10) {
                statusTag(title: doctor.snapshot.sourceLabel, icon: "shippingbox")
                if let version = doctor.snapshot.version, !version.isEmpty {
                    statusTag(title: version, icon: "tag")
                }
                statusTag(title: doctor.snapshot.readinessDescription, icon: "waveform.path.ecg")
            }

            if let lastCheckedAt = doctor.snapshot.lastCheckedAt {
                Text("最后检查：\(lastCheckedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(statusColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusColor.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("操作")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button {
                    doctor.repair()
                } label: {
                    Label(
                        doctor.isRepairing ? "修复中..." : "自动修复",
                        systemImage: "wrench.and.screwdriver"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!doctor.snapshot.canRepair || doctor.isRepairing || doctor.isReinstalling)

                Button {
                    doctor.reinstall()
                } label: {
                    Label(
                        doctor.isReinstalling ? "重装中..." : "重装 Claw",
                        systemImage: "arrow.down.circle"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!doctor.snapshot.canReinstall || doctor.isRepairing || doctor.isReinstalling)
            }

            HStack(spacing: 10) {
                Button("打开运行时目录") {
                    doctor.openRuntimeDirectory()
                }
                .buttonStyle(.borderless)

                Button("打开配置文件") {
                    doctor.openConfigFile()
                }
                .buttonStyle(.borderless)

                Button("打开日志目录") {
                    doctor.openLogDirectory()
                }
                .buttonStyle(.borderless)
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运行信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            detailRow(label: "可执行文件", value: doctor.snapshot.executablePath ?? "未解析到")
            detailRow(label: "运行目录", value: doctor.snapshot.runtimeDirectory)
            detailRow(label: "配置文件", value: doctor.snapshot.configPath)
            detailRow(label: "日志文件", value: doctor.snapshot.logPath)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func logSection(excerpt: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近日志")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(excerpt)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func statusTag(title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.55))
        .clipShape(Capsule(style: .continuous))
    }

    private var statusColor: Color {
        switch doctor.snapshot.status {
        case .checking:
            return .secondary
        case .healthy:
            return .green
        case .externalHealthy:
            return .orange
        case .needsRepair:
            return .orange
        case .missingBundle:
            return .red
        case .repairing, .reinstalling:
            return .blue
        }
    }
}
