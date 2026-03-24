# AI 驱动服务管理架构设计

## 核心理念

服务管理由 AI 主导，而非硬编码逻辑。AI 根据服务配置和当前状态，自主决定如何部署、启动、停止服务。

## 架构图

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   UI (SwiftUI)  │────▶│  ServiceManager  │────▶│   AI (Kimi)     │
│                 │     │   (协调者)        │     │   (执行者)       │
└─────────────────┘     └──────────────────┘     └─────────────────┘
         │                       │                        │
         │                       ▼                        ▼
         │              ┌──────────────────┐     ┌─────────────────┐
         │              │  services.json   │     │  Shell/Process  │
         │              │  (配置中心)       │     │  (实际操作)      │
         │              └──────────────────┘     └─────────────────┘
         │                       ▲
         └───────────────────────┘
              (状态同步)
```

## 工作流程

### 1. 启动服务

```
用户点击"启动"按钮
    │
    ▼
ServiceManager.startService(serviceId)
    │
    ▼
构建 AI 提示词:
"请帮我启动 [服务名]
配置信息: [services.json 中的配置]
当前状态: [检查当前进程/端口状态]"
    │
    ▼
AI 分析并执行:
- 检查服务类型 (MCP/App/Process)
- 检查依赖 (如 OpenD 需要先启动)
- 执行启动命令 (cd path && ./start.sh)
- 等待健康检查通过
- 报告结果
    │
    ▼
更新 UI 状态
```

### 2. 停止服务

```
用户点击"停止"按钮
    │
    ▼
ServiceManager.stopService(serviceId)
    │
    ▼
构建 AI 提示词:
"请帮我停止 [服务名]
配置信息: [services.json 中的配置]
当前 PID: [xxx]"
    │
    ▼
AI 分析并执行:
- 查找进程
- 优雅停止 (SIGTERM)
- 强制停止 (SIGKILL，如果需要)
- 确认端口释放
    │
    ▼
更新 UI 状态
```

## 技能设计

### ServiceManagementSkill

```yaml
name: service-management
version: 1.0.0
description: 服务生命周期管理

functions:
  - name: start_service
    description: 启动指定服务
    parameters:
      - service_id: string
      - service_config: object (来自 services.json)
    
  - name: stop_service
    description: 停止指定服务
    parameters:
      - service_id: string
      - service_config: object
      - current_pid: number (可选)
    
  - name: restart_service
    description: 重启指定服务
    parameters:
      - service_id: string
      - service_config: object
    
  - name: check_service_status
    description: 检查服务状态
    parameters:
      - service_id: string
      - service_config: object
    
  - name: deploy_service
    description: 部署新服务
    parameters:
      - service_config: object
```

## 配置扩展

services.json 支持更丰富的配置：

```json
{
  "id": "xiaohongshu-mcp",
  "name": "小红书 MCP",
  "category": "mcp",
  "type": "http",
  "deployment": {
    "method": "binary",      // binary | docker | script | app
    "dependencies": [],       // 依赖的其他服务
    "healthCheckTimeout": 30  // 健康检查超时时间
  },
  "commands": {
    "status": "pgrep -x xiaohongshu-mcp-darwin-arm64",
    "logs": "tail -100 ~/workspace/xiaohongshu-mcp/logs/app.log"
  }
}
```

## 状态管理

```swift
class ServiceManager {
    // 只负责：
    // 1. 加载配置
    // 2. 触发 AI 操作
    // 3. 接收状态更新并同步到 UI
    // 4. 定期检查状态（本地健康检查）
    
    // 不再直接操作进程！
}
```

## AI 提示词模板

### 启动服务提示词

```
你是一个服务管理专家。请帮我启动以下服务：

服务名称: {{service.name}}
服务ID: {{service.id}}
工作目录: {{service.path}}
启动命令: {{service.startCommand}}
健康检查: {{service.healthCheck.type}} {{service.healthCheck.endpoint}}

当前环境信息:
- 工作目录存在: {{directoryExists}}
- 启动脚本存在: {{scriptExists}}
- 端口占用情况: {{portStatus}}

请按以下步骤执行：
1. 切换到工作目录: cd {{service.path}}
2. 检查是否有残留进程，如果有先停止
3. 执行启动命令: {{service.startCommand}}
4. 等待 {{healthCheckTimeout}} 秒让服务启动
5. 执行健康检查确认服务正常运行
6. 返回结果: 是否成功、进程PID、错误信息（如果有）
```

## 实现步骤

1. **创建 Skill 定义** - 让 Kimi 知道如何管理服务
2. **修改 ServiceManager** - 从"执行者"变为"协调者"
3. **更新 UI** - 按钮触发 AI 操作
4. **测试验证** - 确保各种服务类型都能正常管理
