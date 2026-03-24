//
//  RuntimeDoctorView.swift
//  MacAssistant
//
//  运行时健康状态视图（原生运行时 + 兼容层）
//

import SwiftUI

struct RuntimeStatusEntry: View {
    @ObservedObject var doctor: RuntimeDoctor
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
        case .fallback:
            return .orange
        case .needsAttention:
            return .orange
        case .missingRuntime:
            return .red
        }
    }
}

struct RuntimeDoctorPanelView: View {
    @ObservedObject var doctor: RuntimeDoctor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    
                    if !doctor.snapshot.availableProviders.isEmpty {
                        providersSection
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 400)
        .background(Color(NSColor.controlBackgroundColor))
        .task {
            doctor.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: doctor.snapshot.status.iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("运行时状态")
                    .font(.system(size: 17, weight: .semibold))
                Text(doctor.snapshot.status.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
            }

            Spacer()

            Button {
                doctor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("重新检查运行时状态")
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
                statusTag(title: doctor.snapshot.runtimeType, icon: "cpu")
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
    
    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("可用提供商")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            
            // 简化为垂直列表
            VStack(alignment: .leading, spacing: 6) {
                ForEach(doctor.snapshot.availableProviders.prefix(5), id: \.self) { provider in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text(provider)
                            .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        case .fallback:
            return .orange
        case .needsAttention:
            return .orange
        case .missingRuntime:
            return .red
        }
    }
}

// 兼容旧名称
@available(*, deprecated, renamed: "RuntimeStatusEntry")
typealias OpenClawStatusEntry = RuntimeStatusEntry

@available(*, deprecated, renamed: "RuntimeDoctorPanelView")
typealias OpenClawDoctorPanelView = RuntimeDoctorPanelView
