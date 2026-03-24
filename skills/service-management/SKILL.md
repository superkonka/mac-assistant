# Service Management Skill

服务生命周期管理技能，用于启动、停止、重启和监控各种服务。

## 概述

此技能使 AI 能够管理用户的本地服务，包括：
- MCP 服务器（HTTP/STDIO 模式）
- 桌面应用程序
- 后台进程
- Docker 容器

## 配置

服务配置存储在 `~/workspace/service-management/services.json`：

```json
{
  "id": "service-id",
  "name": "服务名称",
  "category": "mcp|desktop|other",
  "type": "http|stdio|app|process",
  "description": "服务描述",
  "path": "~/workspace/service/",
  "port": 8080,
  "startCommand": "./start.sh",
  "stopCommand": "./stop.sh",
  "healthCheck": {
    "type": "http|port|process",
    "endpoint": "/health"
  }
}
```

## 功能

### 1. 启动服务

启动服务时的执行流程：

1. 读取服务配置
2. 检查当前状态（端口占用、进程存在）
3. 切换到工作目录
4. 执行启动命令
5. 等待健康检查通过
6. 返回结果（成功/失败、PID、错误信息）

### 2. 停止服务

1. 查找服务进程
2. 尝试优雅停止（SIGTERM）
3. 等待进程退出
4. 如需要，强制停止（SIGKILL）
5. 确认端口释放

### 3. 检查状态

- HTTP 健康检查端点
- 端口监听检查（`lsof -Pi :port`）
- 进程存在检查（`pgrep -x processName`）

## 执行规范

### 启动服务

```bash
# 1. 切换到工作目录
cd "<expanded_path>"

# 2. 检查是否已运行
lsof -Pi :<port> -sTCP:LISTEN  # 端口检查
pgrep -x <process_name>         # 进程检查

# 3. 执行启动命令（后台运行并捕获PID）
nohup <startCommand> > /dev/null 2>&1 &
echo $!  # 输出PID

# 4. 等待健康检查
for i in {1..10}; do
    curl -s http://127.0.0.1:<port><endpoint> && break
    sleep 1
done
```

### 停止服务

```bash
# 1. 使用 stopCommand（如果有）
<stopCommand>

# 2. 或使用 PID
kill <pid>          # SIGTERM
sleep 5
kill -9 <pid>       # SIGKILL（如果需要）

# 3. 确认停止
! pgrep -x <process_name> && echo "已停止"
```

## 错误处理

- **端口被占用**: 检查占用进程，询问用户
- **启动脚本不存在**: 检查路径配置
- **健康检查超时**: 查看日志分析原因
- **权限问题**: 提示用户可能需要 sudo

## 返回格式

所有操作返回 JSON 格式：

```json
{
  "success": true,
  "serviceId": "service-id",
  "action": "start|stop|restart|status",
  "pid": 12345,
  "status": "running|stopped|error",
  "message": "操作结果描述",
  "error": "错误信息（如果有）"
}
```
