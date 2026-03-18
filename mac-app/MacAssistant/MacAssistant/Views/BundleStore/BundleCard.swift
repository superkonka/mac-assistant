import SwiftUI

// MARK: - Bundle 卡片

struct BundleCard: View {
    let bundle: BundleMetadata
    let installStatus: BundleInstallStatus
    let isInstalled: Bool
    let onInstall: () -> Void
    let onSelect: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部
            HStack {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(bundleTypeColor.opacity(0.2))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: bundle.type.icon)
                        .font(.title2)
                        .foregroundColor(bundleTypeColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundle.name)
                        .font(.headline)
                    
                    Text("v\(bundle.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 官方徽章
                if bundle.isOfficial {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.blue)
                        .help("官方 Bundle")
                }
                
                // 评分
                if let rating = bundle.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", rating))
                            .font(.caption)
                    }
                }
            }
            
            // 描述
            Text(bundle.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            // 能力标签
            FlowLayout(spacing: 6) {
                ForEach(bundle.capabilities.prefix(3), id: \.self) { capability in
                    CapabilityTag(capability: capability)
                }
                
                if bundle.capabilities.count > 3 {
                    Text("+\(bundle.capabilities.count - 3)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                }
            }
            
            Spacer()
            
            // 底部操作区
            HStack {
                // 安装数
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                    Text("\(formatCount(bundle.installCount))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                
                Spacer()
                
                // 安装按钮
                installButton
            }
        }
        .padding()
        .frame(height: 200)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .onTapGesture {
            onSelect()
        }
    }
    
    @ViewBuilder
    private var installButton: some View {
        switch installStatus {
        case .notInstalled:
            Button(action: onInstall) {
                Text("安装")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
        case .installing(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 60)
            
        case .installed:
            Label("已安装", systemImage: "checkmark")
                .font(.caption)
                .foregroundColor(.green)
            
        case .updating:
            ProgressView()
                .controlSize(.small)
            
        case .uninstalling:
            ProgressView()
                .controlSize(.small)
            
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .help(message)
        }
    }
    
    private var bundleTypeColor: Color {
        switch bundle.type {
        case .codex:
            return .green
        case .claude:
            return .orange
        case .cursor:
            return .purple
        case .custom:
            return .gray
        }
    }
    
    private func formatCount(_ count: Int) -> String {
        if count >= 10000 {
            return String(format: "%.1fw", Double(count) / 10000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        } else {
            return "\(count)"
        }
    }
}

// MARK: - 推荐卡片

struct RecommendedBundleCard: View {
    let bundle: BundleMetadata
    let onTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: bundle.type.icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                Spacer()
                
                if bundle.isOfficial {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.blue)
                }
            }
            
            Text(bundle.name)
                .font(.headline)
            
            Text(bundle.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            Spacer()
            
            HStack {
                ForEach(bundle.capabilities.prefix(2), id: \.self) { capability in
                    Image(systemName: capability.icon)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 200, height: 150)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.1), Color(NSColor.controlBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .onTapGesture(perform: onTap)
    }
}

// MARK: - 紧凑卡片

struct CompactBundleCard: View {
    let bundle: BundleMetadata
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: bundle.type.icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Text(bundle.type.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 180, height: 70)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onTapGesture(perform: onTap)
    }
}

// MARK: - 能力标签

struct CapabilityTag: View {
    let capability: BundleCapability
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: capability.icon)
                .font(.caption2)
            Text(capability.displayName)
                .font(.caption)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.1))
        .foregroundColor(.accentColor)
        .cornerRadius(4)
    }
}

// MARK: - 已安装 Bundle 行

struct InstalledBundleRow: View {
    let bundle: BundleInstance
    let onToggle: () -> Void
    let onUpdate: (() -> Void)?
    let onUninstall: () -> Void
    
    @State private var showingUninstallConfirm = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 图标
            Image(systemName: bundle.metadata.type.icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(bundle.metadata.name)
                        .font(.headline)
                    
                    if bundle.metadata.isOfficial {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                    
                    Text("v\(bundle.metadata.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 8) {
                    // 沙箱指示器
                    if let sandbox = bundle.metadata.sandboxConfig {
                        Label(sandbox.type.rawValue, systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // 安装时间
                    Text("安装于 \(bundle.installedAt, style: .date)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // 操作按钮
            HStack(spacing: 8) {
                // 启用/禁用开关
                Toggle("", isOn: .init(
                    get: { bundle.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                
                // 更新按钮
                if let onUpdate = onUpdate {
                    Button(action: onUpdate) {
                        Image(systemName: "arrow.up.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("更新")
                }
                
                // 卸载按钮
                Button(action: { showingUninstallConfirm = true }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("卸载")
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "确认卸载 \(bundle.metadata.name)?",
            isPresented: $showingUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("卸载", role: .destructive, action: onUninstall)
            Button("取消", role: .cancel) {}
        } message: {
            Text("卸载后，与此 Bundle 关联的 Agent 和技能将不再可用。")
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}

// MARK: - 预览

#Preview("Bundle Cards") {
    ScrollView {
        VStack(spacing: 20) {
            BundleCard(
                bundle: BundleMetadata.samples[0],
                installStatus: .notInstalled,
                isInstalled: false,
                onInstall: {},
                onSelect: {}
            )
            
            BundleCard(
                bundle: BundleMetadata.samples[1],
                installStatus: .installed(version: "2.0.1"),
                isInstalled: true,
                onInstall: {},
                onSelect: {}
            )
            
            RecommendedBundleCard(
                bundle: BundleMetadata.samples[0],
                onTap: {}
            )
            
            CompactBundleCard(
                bundle: BundleMetadata.samples[1],
                onTap: {}
            )
        }
        .padding()
    }
    .frame(width: 400)
}
