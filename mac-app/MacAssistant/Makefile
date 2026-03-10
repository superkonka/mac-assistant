# MacAssistant Makefile

APP_NAME = MacAssistant
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES_DIR = $(CONTENTS)/Resources

# Swift 文件
SWIFT_FILES = $(shell find MacAssistant -name "*.swift")

.PHONY: all clean install build-app

all: build-app

# 创建应用包结构
build-app: $(APP_BUNDLE)
	@echo "✅ 构建完成: $(APP_BUNDLE)"

$(APP_BUNDLE): $(SWIFT_FILES)
	@echo "🔨 创建应用包..."
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	
	@echo "📋 复制资源文件..."
	@cp MacAssistant/Info.plist $(CONTENTS)/
	
	@echo "🔨 编译 Swift 文件..."
	@swiftc \
		-o $(MACOS_DIR)/$(APP_NAME) \
		-emit-executable \
		-sdk $(shell xcrun --show-sdk-path --sdk macosx) \
		-F $(shell xcrun --show-sdk-path --sdk macosx)/System/Library/Frameworks \
		-framework Foundation \
		-framework SwiftUI \
		-framework AppKit \
		-framework UserNotifications \
		-framework IOKit \
		$(SWIFT_FILES) \
		2>&1 | tee $(BUILD_DIR)/build.log || { echo "❌ 编译失败"; exit 1; }
	
	@echo "📝 创建 PkgInfo..."
	@echo "APPL????" > $(CONTENTS)/PkgInfo
	
	@echo "✅ 应用构建成功!"

install: build-app
	@echo "📦 安装到 /Applications..."
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "✅ 安装完成!"

run: build-app
	@echo "🚀 启动应用..."
	@open $(APP_BUNDLE)

clean:
	@echo "🧹 清理构建文件..."
	@rm -rf $(BUILD_DIR)
	@echo "✅ 清理完成!"

# 快速测试构建（不安装）
test: build-app
	@echo "🧪 测试运行应用..."
	@$(MACOS_DIR)/$(APP_NAME) &

.PHONY: help
help:
	@echo "MacAssistant 构建工具"
	@echo ""
	@echo "可用命令:"
	@echo "  make build-app  - 构建应用"
	@echo "  make install    - 安装到 /Applications"
	@echo "  make run        - 构建并运行"
	@echo "  make clean      - 清理构建文件"
	@echo "  make test       - 构建并测试运行"
