#!/bin/bash
# Mac Assistant 后台服务管理脚本
# Mac Assistant 后台服务管理脚本

set -e

SERVICE_NAME="com.mac-assistant.backend"
PLIST_SOURCE="$HOME/code/mac-assistant/daemon/${SERVICE_NAME}.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"
LOG_DIR="$HOME/code/mac-assistant/daemon"

color_green='\033[0;32m'
color_red='\033[0;31m'
color_yellow='\033[1;33m'
color_nc='\033[0m'

log_info() {
    echo -e "${color_green}[INFO]${color_nc} $1"
}

log_warn() {
    echo -e "${color_yellow}[WARN]${color_nc} $1"
}

log_error() {
    echo -e "${color_red}[ERROR]${color_nc} $1"
}

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."
    
    if [ ! -d "$HOME/code/mac-assistant/backend/.venv" ]; then
        log_error "后端虚拟环境不存在，请先运行 ./scripts/setup.sh"
        exit 1
    fi
    
    log_info "✓ 依赖检查通过"
}

# 安装服务
install_service() {
    log_info "安装后台服务..."
    
    # 创建日志目录
    mkdir -p "$LOG_DIR"
    
    # 复制 plist 文件
    cp "$PLIST_SOURCE" "$PLIST_DEST"
    
    # 加载服务
    launchctl load "$PLIST_DEST" 2>/dev/null || true
    
    log_info "✓ 服务已安装"
    log_info "  配置文件: $PLIST_DEST"
    log_info "  日志文件: $LOG_DIR/backend.log"
}

# 启动服务
start_service() {
    log_info "启动后台服务..."
    
    if [ ! -f "$PLIST_DEST" ]; then
        install_service
    fi
    
    launchctl start "$SERVICE_NAME" 2>/dev/null || {
        # 如果启动失败，尝试重新加载
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
        launchctl load "$PLIST_DEST"
        launchctl start "$SERVICE_NAME"
    }
    
    # 等待服务启动
    sleep 2
    
    if check_status_quiet; then
        log_info "✓ 服务已启动 (端口: 8765)"
    else
        log_error "✗ 服务启动失败，请检查日志: $LOG_DIR/backend.error.log"
        exit 1
    fi
}

# 停止服务
stop_service() {
    log_info "停止后台服务..."
    
    launchctl stop "$SERVICE_NAME" 2>/dev/null || true
    
    # 也尝试卸载
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    
    log_info "✓ 服务已停止"
}

# 重启服务
restart_service() {
    log_info "重启后台服务..."
    stop_service
    sleep 1
    start_service
}

# 检查状态（带输出）
check_status() {
    log_info "检查服务状态..."
    
    if [ ! -f "$PLIST_DEST" ]; then
        log_warn "服务未安装"
        return 1
    fi
    
    if launchctl list | grep -q "$SERVICE_NAME"; then
        PID=$(launchctl list | grep "$SERVICE_NAME" | awk '{print $1}')
        log_info "✓ 服务运行中 (PID: $PID)"
        
        # 检查端口
        if lsof -Pi :8765 -sTCP:LISTEN -t >/dev/null 2>&1; then
            log_info "✓ 端口 8765 监听正常"
        else
            log_warn "✗ 端口 8765 未监听"
        fi
        
        return 0
    else
        log_warn "✗ 服务未运行"
        return 1
    fi
}

# 安静检查状态
check_status_quiet() {
    if launchctl list | grep -q "$SERVICE_NAME"; then
        if curl -s http://127.0.0.1:8765/health >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# 查看日志
view_logs() {
    log_info "查看日志 (按 Ctrl+C 退出)..."
    echo ""
    
    if [ -f "$LOG_DIR/backend.log" ]; then
        tail -f "$LOG_DIR/backend.log" "$LOG_DIR/backend.error.log" 2>/dev/null
    else
        log_warn "日志文件不存在"
    fi
}

# 卸载服务
uninstall_service() {
    log_info "卸载后台服务..."
    
    stop_service
    
    rm -f "$PLIST_DEST"
    
    log_info "✓ 服务已卸载"
}

# 自动修复
repair_service() {
    log_info "尝试修复服务..."
    
    # 停止并卸载
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    
    # 清理可能残留的进程
    pkill -f "mac-assistant/backend/main.py" 2>/dev/null || true
    
    sleep 1
    
    # 重新安装并启动
    install_service
    start_service
    
    log_info "✓ 修复完成"
}

# 使用说明
usage() {
    echo "Mac Assistant 后台服务管理"
    echo ""
    echo "用法: $0 {install|start|stop|restart|status|logs|repair|uninstall}"
    echo ""
    echo "命令:"
    echo "  install     安装并启动服务"
    echo "  start       启动服务"
    echo "  stop        停止服务"
    echo "  restart     重启服务"
    echo "  status      查看服务状态"
    echo "  logs        查看实时日志"
    echo "  repair      修复服务问题"
    echo "  uninstall   完全卸载服务"
    echo ""
    echo "示例:"
    echo "  $0 install    # 首次安装"
    echo "  $0 restart    # 重启服务"
    echo "  $0 logs       # 查看日志"
}

# 主入口
case "$1" in
    install)
        check_dependencies
        install_service
        start_service
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    status)
        check_status
        ;;
    logs)
        view_logs
        ;;
    repair)
        repair_service
        ;;
    uninstall)
        uninstall_service
        ;;
    *)
        usage
        exit 1
        ;;
esac
