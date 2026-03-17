#!/bin/bash
# 修复 Swift 6.2 兼容性问题的脚本

echo "正在修复 Swift 6.2 兼容性问题..."

cd "$(dirname "$0")/mac-app/MacAssistant"

# 修复 swiftui-math 库
KEYBOX_FILE=".build/checkouts/swiftui-math/Sources/SwiftUIMath/Internal/Helpers/KeyBox.swift"
if [ -f "$KEYBOX_FILE" ]; then
    chmod 666 "$KEYBOX_FILE" 2>/dev/null
    cat > "$KEYBOX_FILE" << 'EOF'
import Foundation

final class KeyBox<Value: Hashable>: NSObject {
  let wrappedValue: Value

  init(_ wrappedValue: Value) {
    self.wrappedValue = wrappedValue
  }

  @objc(hash)
  var hashValue_: Int {
    var hasher = Hasher()
    hasher.combine(wrappedValue)
    return hasher.finalize()
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? KeyBox<Value> else {
      return false
    }
    return wrappedValue == other.wrappedValue
  }
}
EOF
    echo "✓ 修复 swiftui-math/KeyBox.swift"
fi

# 修复 textual 库中的 Box.swift
BOX_FILE=".build/checkouts/textual/Sources/Textual/Internal/Helpers/Box.swift"
if [ -f "$BOX_FILE" ]; then
    chmod 666 "$BOX_FILE" 2>/dev/null
    sed -i '' 's/override var hash: Int/@objc(hash) var hashValue_: Int/' "$BOX_FILE"
    echo "✓ 修复 textual/Box.swift"
fi

# 修复 textual 库中的 TransferableText.swift
TRANSFERABLE_FILE=".build/checkouts/textual/Sources/Textual/Internal/Formatting/TransferableText.swift"
if [ -f "$TRANSFERABLE_FILE" ]; then
    chmod 666 "$TRANSFERABLE_FILE" 2>/dev/null
    sed -i '' 's/static var writableTypeIdentifiersForItemProvider/@objc static var writableTypeIdentifiersForItemProvider/' "$TRANSFERABLE_FILE"
    echo "✓ 修复 textual/TransferableText.swift"
fi

echo ""
echo "修复完成。现在可以运行以下命令来编译："
echo "  cd mac-app/MacAssistant && swift build -c release"
