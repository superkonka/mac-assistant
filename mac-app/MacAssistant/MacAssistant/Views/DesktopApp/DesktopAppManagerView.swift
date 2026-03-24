//
//  DesktopAppManagerView.swift
//  MacAssistant
//
//  桌面应用管理视图 - AI智能体控制Mac应用的可视化界面
//

import SwiftUI

struct DesktopAppManagerView: View {
    @StateObject private var launcher = DesktopAppLauncher.shared
    @State private var searchText = ""
    @State private var selectedCategory: DesktopAppInfo.AppCategory?
    @State private var selectedApp: DesktopAppInfo?
    @State private var showingActionSheet = false
    
    private var filteredApps: [DesktopAppInfo] {
        var result = launcher.installedApps
        
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }
        
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                ($0.bundleIdentifier?.lowercased().contains(query) ?? false)
            }
        }
        
        return result
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            categoryTabs
            Divider()
            appList
        }
        .background(Color(.windowBackgroundColor))
    }
    
    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("桌面应用")
                        .font(.system(size: 16, weight: .semibold))
                    Text("已安装 \(launcher.installedApps.count) 个应用")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索应用...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 160)
                
                Button {
                    launcher.scanInstalledApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
    }
    
    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                DesktopAppCategoryTab(title: "全部", icon: "square.grid.2x2", isSelected: selectedCategory == nil, count: launcher.installedApps.count) {
                    selectedCategory = nil
                }
                
                ForEach(DesktopAppInfo.AppCategory.allCases, id: \.self) { category in
                    DesktopAppCategoryTab(title: category.displayName, icon: "app", isSelected: selectedCategory == category, count: launcher.apps(in: category).count) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
    
    private var appList: some View {
        List(filteredApps) { app in
            AppRow(app: app, isRunning: launcher.isRunning(app), onLaunch: {
                Task { _ = await launcher.launchApp(app) }
            }, onQuit: {
                Task { await launcher.quitApp(app) }
            }, onActivate: {
                _ = launcher.activateApp(app)
            })
        }
        .listStyle(.plain)
    }
}

private struct DesktopAppCategoryTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.3) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.blue : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct AppRow: View {
    let app: DesktopAppInfo
    let isRunning: Bool
    let onLaunch: () -> Void
    let onQuit: () -> Void
    let onActivate: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isRunning ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: isRunning ? "checkmark.circle.fill" : "app")
                    .font(.system(size: 14))
                    .foregroundColor(isRunning ? .green : .secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 13, weight: .semibold))
                
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Circle().fill(isRunning ? Color.green : Color.gray).frame(width: 6, height: 6)
                        Text(isRunning ? "运行中" : "已停止").font(.system(size: 10))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((isRunning ? Color.green : Color.gray).opacity(0.12))
                    .foregroundColor(isRunning ? .green : .secondary)
                    .clipShape(Capsule())
                }
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                if isRunning {
                    Button { onActivate() } label: {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                    }.buttonStyle(.borderless)
                    
                    Button { onQuit() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11)).foregroundColor(.red)
                    }.buttonStyle(.borderless)
                } else {
                    Button { onLaunch() } label: {
                        Image(systemName: "play.fill").font(.system(size: 11))
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct DesktopAppManagerView_Previews: PreviewProvider {
    static var previews: some View {
        DesktopAppManagerView().frame(width: 600, height: 500)
    }
}
