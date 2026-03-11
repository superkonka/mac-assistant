#!/bin/bash
# Bundle a complete OpenClaw runtime prefix into the app resources.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENCLAW_CORE="$PROJECT_ROOT/openclaw-core"
BUILD_DIR="$SCRIPT_DIR/bundled"
RESOURCES_DIR="$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant/Resources"
RUNTIME_DIR_NAME="openclaw-runtime"
RESOURCES_RUNTIME_DIR="$RESOURCES_DIR/$RUNTIME_DIR_NAME"
MANIFEST_NAME=".bundle-manifest"
NODE_VERSION="${OPENCLAW_NODE_VERSION:-22.22.0}"

log() {
    printf '%s\n' "$1"
}

fail() {
    printf '❌ %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1"
}

runtime_wrapper_path() {
    printf '%s/bin/openclaw' "$1"
}

manifest_matches() {
    local manifest_path="$1"
    [[ -f "$manifest_path" ]] || return 1

    grep -qx "OPENCLAW_VERSION=$OPENCLAW_VERSION" "$manifest_path" || return 1
    grep -qx "OPENCLAW_COMMIT=$OPENCLAW_COMMIT" "$manifest_path" || return 1
    grep -qx "NODE_VERSION=$NODE_VERSION" "$manifest_path" || return 1
    grep -qx "NODE_ARCH=$NODE_DIST_ARCH" "$manifest_path" || return 1
}

runtime_is_valid() {
    local root="$1"
    local wrapper
    wrapper="$(runtime_wrapper_path "$root")"
    [[ -x "$wrapper" ]] || return 1
    "$wrapper" --version >/dev/null 2>&1
}

write_manifest() {
    local target_root="$1"
    cat > "$target_root/$MANIFEST_NAME" <<EOF
OPENCLAW_VERSION=$OPENCLAW_VERSION
OPENCLAW_COMMIT=$OPENCLAW_COMMIT
NODE_VERSION=$NODE_VERSION
NODE_ARCH=$NODE_DIST_ARCH
EOF
}

install_node_runtime() {
    local prefix_root="$1"
    local work_dir="$2"
    local tarball_name="node-v${NODE_VERSION}-darwin-${NODE_DIST_ARCH}.tar.gz"
    local tarball_url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball_name}"
    local shasums_url="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
    local tarball_path="$work_dir/$tarball_name"
    local shasums_path="$work_dir/SHASUMS256.txt"
    local node_target_dir="$prefix_root/tools/node-v${NODE_VERSION}"
    local expected_sha
    local actual_sha

    log "⬇️  下载 Node.js v${NODE_VERSION} (${NODE_DIST_ARCH})..."
    curl -fsSL "$shasums_url" -o "$shasums_path"
    curl -fsSL "$tarball_url" -o "$tarball_path"

    expected_sha="$(awk -v name="$tarball_name" '$2 == name { print $1 }' "$shasums_path")"
    [[ -n "$expected_sha" ]] || fail "无法从 SHASUMS256.txt 找到 $tarball_name"

    actual_sha="$(shasum -a 256 "$tarball_path" | awk '{print $1}')"
    [[ "$expected_sha" == "$actual_sha" ]] || fail "Node.js tarball 校验失败"

    mkdir -p "$node_target_dir"
    tar -xzf "$tarball_path" -C "$node_target_dir" --strip-components=1
    ln -sfn "node-v${NODE_VERSION}" "$prefix_root/tools/node"
}

install_openclaw_package() {
    local prefix_root="$1"
    local work_dir="$2"
    local tarball_name
    local tarball_path
    local package_root="$prefix_root/lib/node_modules/openclaw"

    log "📦 打包本地 openclaw-core..."
    tarball_name="$(cd "$OPENCLAW_CORE" && npm pack --ignore-scripts --pack-destination "$work_dir" | tail -n 1)"
    tarball_path="$work_dir/$tarball_name"
    [[ -f "$tarball_path" ]] || fail "npm pack 未生成 tarball"

    log "📦 安装 OpenClaw 到受控前缀..."
    npm install \
        -g \
        --omit=dev \
        --no-package-lock \
        --prefix "$prefix_root" \
        "$tarball_path" >/dev/null

    [[ -f "$package_root/openclaw.mjs" ]] || fail "缺少 openclaw.mjs"
    [[ -d "$package_root/dist" ]] || fail "缺少 dist 目录"
}

write_runtime_wrapper() {
    local prefix_root="$1"
    local wrapper_path
    wrapper_path="$(runtime_wrapper_path "$prefix_root")"

    mkdir -p "$(dirname "$wrapper_path")"
    rm -f "$wrapper_path"

    cat > "$wrapper_path" <<'EOF'
#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PREFIX_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
NODE_BIN="$PREFIX_DIR/tools/node/bin/node"
CLI_ENTRY="$PREFIX_DIR/lib/node_modules/openclaw/openclaw.mjs"

if [ ! -x "$NODE_BIN" ]; then
  echo "openclaw runtime missing node binary: $NODE_BIN" >&2
  exit 1
fi

if [ ! -f "$CLI_ENTRY" ]; then
  echo "openclaw runtime missing entrypoint: $CLI_ENTRY" >&2
  exit 1
fi

export PATH="$PREFIX_DIR/tools/node/bin:$PREFIX_DIR/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
exec "$NODE_BIN" "$CLI_ENTRY" "$@"
EOF

    chmod 755 "$wrapper_path"
}

copy_runtime_into_resources() {
    local source_root="$1"

    rm -rf "$RESOURCES_RUNTIME_DIR"
    mkdir -p "$RESOURCES_DIR"
    ditto "$source_root" "$RESOURCES_RUNTIME_DIR"
}

require_command curl
require_command npm
require_command node
require_command pnpm
require_command shasum
require_command tar
require_command ditto

[[ -d "$OPENCLAW_CORE" ]] || fail "openclaw-core 目录不存在: $OPENCLAW_CORE"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)
        NODE_DIST_ARCH="arm64"
        ;;
    x86_64)
        NODE_DIST_ARCH="x64"
        ;;
    *)
        fail "不支持的架构: $ARCH"
        ;;
esac

OPENCLAW_VERSION="$(node -p "require('$OPENCLAW_CORE/package.json').version")"
OPENCLAW_COMMIT="$(git -C "$OPENCLAW_CORE" rev-parse HEAD 2>/dev/null || echo unknown)"

log "🦞 OpenClaw Runtime Bundler"
log "==========================="
log "OpenClaw version: $OPENCLAW_VERSION"
log "OpenClaw commit : $OPENCLAW_COMMIT"
log "Node version    : $NODE_VERSION"
log "Target arch     : $NODE_DIST_ARCH"
log ""

mkdir -p "$BUILD_DIR"
mkdir -p "$RESOURCES_DIR"

if manifest_matches "$RESOURCES_RUNTIME_DIR/$MANIFEST_NAME" && runtime_is_valid "$RESOURCES_RUNTIME_DIR"; then
    log "✅ 已存在可用的 openclaw-runtime，跳过重新打包"
    log "   位置: $RESOURCES_RUNTIME_DIR"
    exit 0
fi

KEEP_WORK_DIR="${KEEP_WORK_DIR:-0}"
WORK_DIR="$(mktemp -d "$BUILD_DIR/openclaw-runtime.XXXXXX")"
PREFIX_ROOT="$WORK_DIR/$RUNTIME_DIR_NAME"
trap 'if [[ "$KEEP_WORK_DIR" != "1" ]]; then rm -rf "$WORK_DIR"; else echo "ℹ️  保留临时目录: $WORK_DIR"; fi' EXIT

log "📦 检查 openclaw-core 依赖和构建产物..."
if [[ ! -d "$OPENCLAW_CORE/node_modules" ]]; then
    log "   安装 pnpm 依赖..."
    (cd "$OPENCLAW_CORE" && pnpm install --no-frozen-lockfile --config.node-linker=hoisted >/dev/null)
else
    log "   复用现有 node_modules"
fi

if [[ ! -f "$OPENCLAW_CORE/dist/entry.js" && ! -f "$OPENCLAW_CORE/dist/entry.mjs" ]]; then
    log "   构建 OpenClaw dist..."
    (cd "$OPENCLAW_CORE" && pnpm build >/dev/null)
else
    log "   复用现有 dist"
fi

mkdir -p "$PREFIX_ROOT"
install_node_runtime "$PREFIX_ROOT" "$WORK_DIR"
install_openclaw_package "$PREFIX_ROOT" "$WORK_DIR"
write_runtime_wrapper "$PREFIX_ROOT"
write_manifest "$PREFIX_ROOT"

log "🧪 验证运行时..."
VERSION_OUTPUT="$("$PREFIX_ROOT/bin/openclaw" --version 2>&1)" || fail "打包后的 openclaw-runtime 验证失败: $VERSION_OUTPUT"

copy_runtime_into_resources "$PREFIX_ROOT"

FILE_SIZE="$(du -sh "$RESOURCES_RUNTIME_DIR" | awk '{print $1}')"
VERSION_OUTPUT="$(printf '%s' "$VERSION_OUTPUT" | head -n 1 | tr -d '\r')"

log "✅ OpenClaw runtime 已写入: $RESOURCES_RUNTIME_DIR"
log "   大小: $FILE_SIZE"
log "   版本: $VERSION_OUTPUT"
