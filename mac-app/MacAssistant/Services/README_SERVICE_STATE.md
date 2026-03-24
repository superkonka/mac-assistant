# 统一服务状态中心实现说明

## 概述

本次实现解决了主会话与服务管理之间的状态不同步问题，并增加了健康监控、服务发现和网络访问管理能力。

## 已实现的功能

### Phase 1: 状态同步层 ✅

**新增文件：**
- `UnifiedServiceState.swift` - 统一状态中心
- `ServiceStateParser.swift` - 服务操作结果解析器

**修改文件：**
- `ServiceManager.swift` - 添加同步接口
- `CommandRunner.swift` - 集成服务状态解析
- `ServiceRow.swift` - 使用 UnifiedServiceState
- `ServiceEntryButton.swift` - 统一状态统计

### Phase 2: 健康监控层 ✅

**新增文件：**
- `HealthMonitor/HealthMonitorEngine.swift` - 健康监控引擎
- `HealthMonitor/HealthMonitorConfig.swift` - 健康监控配置和设置视图
- `Views/Services/HealthMonitorView.swift` - 健康监控面板

**修改文件：**
- `CommandRunner.swift` - 集成健康事件通知
- `ServiceRow.swift` - 显示健康状态
- `ServiceEntryButton.swift` - 添加健康监控入口

### Phase 3: 服务发现层 ✅

**新增文件：**
- `Discovery/DiscoveredService.swift` - 发现的服务模型
- `Discovery/PortScanner.swift` - 端口扫描器
- `Discovery/ServiceDiscoveryManager.swift` - 服务发现管理器
- `Views/Services/ServiceDiscoveryView.swift` - 服务发现视图

**功能：**
- 端口扫描发现新服务（支持并发扫描）
- 常见服务端口识别（MCP、数据库、消息队列等）
- 进程信息获取
- 待确认服务管理
- 自动添加到服务管理

### Phase 4: 网络访问层 ✅

**新增文件：**
- `Network/NetworkAccessManager.swift` - 网络访问管理器
- 包含 FirewallManager - 防火墙管理器

**修改文件：**
- `ServiceRow.swift` - 显示访问按钮和复制 URL

**功能：**
- 自动检测本机 IP 地址
- 检查服务内外网访问性
- 防火墙状态检测
- 绑定地址检测（localhost vs 0.0.0.0）
- 一键修复引导（添加防火墙规则）

## 完整架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                         MacAssistant                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                     UI 层                                 │  │
│  │  ┌─────────────┐ ┌──────────────┐ ┌──────────────────┐  │  │
│  │  │ServicePanel │ │HealthMonitor │ │ServiceDiscovery  │  │  │
│  │  │   服务管理   │ │   健康监控    │ │   服务发现       │  │  │
│  │  └─────────────┘ └──────────────┘ └──────────────────┘  │  │
│  └────────────────────────┬─────────────────────────────────┘  │
│                           │                                      │
│  ┌────────────────────────▼─────────────────────────────────┐  │
│  │              UnifiedServiceState                          │  │
│  │                  (统一状态中心)                            │  │
│  └────────────────────────┬─────────────────────────────────┘  │
│                           │                                      │
│        ┌──────────────────┼──────────────────┐                   │
│        │                  │                  │                   │
│        ▼                  ▼                  ▼                   │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐        │
│  │ServiceManager│  │HealthMonitor │  │ServiceDiscovery  │        │
│  │  服务管理    │  │   健康监控    │  │   服务发现       │        │
│  └─────────────┘  └──────────────┘  └──────────────────┘        │
│        │                  │                  │                   │
│        └──────────────────┼──────────────────┘                   │
│                           │                                      │
│        ┌──────────────────┼──────────────────┐                   │
│        │                  │                  │                   │
│        ▼                  ▼                  ▼                   │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐        │
│  │NetworkAccess│  │ PortScanner  │  │ FirewallManager  │        │
│  │   网络访问   │  │   端口扫描    │  │   防火墙管理     │        │
│  └─────────────┘  └──────────────┘  └──────────────────┘        │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    CommandRunner                          │  │
│  │  - 服务状态解析                                            │  │
│  │  - 健康事件通知                                            │  │
│  │  - AI 诊断触发                                             │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## 使用指南

### 1. 状态同步

无论从哪里启动服务，状态都会自动同步：
- 主会话启动 → 服务管理面板自动更新
- 服务管理启动 → 主会话可查看状态
- 外部 CLI 启动 → 服务发现后确认添加

### 2. 健康监控

```swift
// 启用健康监控
HealthMonitorEngine.shared.isEnabled = true
HealthMonitorEngine.shared.startGlobalMonitoring()

// 配置策略（不健康时自动重启）
let policy = HealthCheckPolicy(
    checkType: .tcp(port: 8080),
    interval: 30,
    unhealthyPolicy: .autoRestart(maxRetries: 3, cooldown: 300)
)
```

### 3. 服务发现

```swift
// 快速扫描已知端口
await ServiceDiscoveryManager.shared.quickScan()

// 完整扫描端口范围
await ServiceDiscoveryManager.shared.scanPorts(config: .default)

// 确认添加服务
ServiceDiscoveryManager.shared.confirmService(service, addToManagement: true)
```

### 4. 网络访问

```swift
// 检查服务访问性
await NetworkAccessManager.shared.checkServiceAccess(serviceID: "github-mcp-http")

// 获取访问信息
let info = NetworkAccessManager.shared.accessInfo(for: "github-mcp-http")
print(info?.internalAccess.url)   // http://127.0.0.1:9002
print(info?.externalAccess?.url)  // http://192.168.1.100:9002

// 复制访问 URL
NetworkAccessManager.shared.copyAccessURL(for: "github-mcp-http", preferExternal: true)
```

## 工作流程

### 服务启动流程
```
用户操作 → AI 执行 → 返回结果 → CommandRunner 解析 → 
UnifiedServiceState 更新 → ServiceManager 同步 → UI 刷新
```

### 健康监控流程
```
服务启动 → 开始监控 → 定期检查 → 发现异常 → 
策略处理 → 通知主会话 → AI 诊断（可选）
```

### 服务发现流程
```
触发扫描 → 端口检测 → 识别服务 → 显示待确认 → 
用户确认 → 添加到管理 → 开始健康监控
```

### 网络访问流程
```
服务启动 → 获取本机 IP → 检查端口 → 检查防火墙 → 
生成访问 URL → 显示访问按钮 → 一键复制
```

## 配置选项

### 健康监控策略

| 参数 | 默认值 | 说明 |
|-----|-------|------|
| interval | 30s | 检查间隔 |
| timeout | 10s | 超时时间 |
| retryCount | 3 | 失败重试次数 |
| unhealthyPolicy | notifyOnly | 不健康处理策略 |

### 端口扫描配置

| 配置 | 范围 | 超时 | 并发数 |
|-----|------|------|--------|
| quick | 3000-9000 | 1s | 100 |
| default | 3000-10000 | 2s | 50 |
| comprehensive | 1-65535 | 3s | 20 |

## 事件通知

### 健康监控事件
- `.healthMonitorAlert` - 健康告警
- `.healthMonitorAIDiagnosis` - AI 诊断请求

### 服务发现事件
- `.serviceDiscovered` - 发现新服务

## 调试日志

```swift
// 查看状态同步
LogInfo("[UnifiedServiceState] 状态更新: \(serviceID)")

// 查看健康检查
LogInfo("[HealthMonitorEngine] 服务 \(serviceName) 状态变更")

// 查看服务发现
LogInfo("[ServiceDiscoveryManager] 发现 \(count) 个新服务")

// 查看网络访问
LogInfo("[NetworkAccessManager] 网络环境更新: \(localIP)")
```

## 注意事项

1. **权限**：防火墙管理需要管理员权限
2. **性能**：端口扫描使用并发控制，避免资源占用过高
3. **安全**：外部访问默认需要用户确认
4. **兼容性**：macOS 10.15+ 支持所有功能

## 后续优化

- [ ] 支持更多服务类型识别
- [ ] 添加服务依赖管理
- [ ] 支持远程服务发现
- [ ] 添加访问统计和流量监控
