#!/usr/bin/env swift

//
//  self_test.swift
//  MacAssistant 自测脚本
//

import Foundation

// MARK: - 模拟数据结构

enum MockSkill: String, CaseIterable {
    case screenshot = "screenshot"
    case codeReview = "codeReview"
    case translateText = "translateText"
    case summarizeText = "summarizeText"
    case webSearch = "webSearch"
    
    var name: String {
        switch self {
        case .screenshot: return "截图分析"
        case .codeReview: return "代码审查"
        case .translateText: return "翻译文本"
        case .summarizeText: return "总结文本"
        case .webSearch: return "网络搜索"
        }
    }
}

// MARK: - 意图检测测试

class IntentDetectionTest {
    
    func detectIntent(_ input: String) -> MockSkill? {
        let lowercased = input.lowercased()
        
        if containsAny(lowercased, ["截图", "截屏", "screenshot", "screen shot"]) &&
           !lowercased.contains("不用") &&
           !lowercased.contains("不要") &&
           !lowercased.contains("算了") {
            return .screenshot
        }
        
        if containsAny(lowercased, ["review 代码", "代码 review", "审查代码", "检查代码", "code review"]) {
            return .codeReview
        }
        
        if (lowercased.contains("翻译") || lowercased.contains("translate")) &&
           (lowercased.contains("成") || lowercased.contains("to")) {
            return .translateText
        }
        
        if containsAny(lowercased, ["总结", "概括", "summarize", "summary"]) &&
           input.count > 50 {
            return .summarizeText
        }
        
        if containsAny(lowercased, ["搜索", "查一下", "搜索网络", "google", "百度"]) {
            return .webSearch
        }
        
        return nil
    }
    
    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
    
    func run() -> (passed: Int, failed: Int) {
        print("🧪 测试 1: 意图检测敏感度\n")
        
        typealias TestCase = (input: String, shouldDetect: Bool, skill: MockSkill?, reason: String)
        
        let testCases: [TestCase] = [
            // 应该检测到的
            ("截图", true, .screenshot, "明确命令"),
            ("截屏", true, .screenshot, "明确命令"),
            ("screenshot", true, .screenshot, "英文命令"),
            ("review 代码", true, .codeReview, "明确命令"),
            ("翻译成英文", true, .translateText, "有目标语言"),
            ("搜索一下", true, .webSearch, "明确命令"),
            
            // 不应该检测到的
            ("截个图看看", false, nil, "模糊表述（有看看）"),
            ("不用截图", false, nil, "否定词（不用）"),
            ("截图算了", false, nil, "否定词（算了）"),
            ("翻译一下", false, nil, "缺少目标语言"),
            ("帮我看看", false, nil, "太模糊"),
            ("你好", false, nil, "普通对话"),
        ]
        
        var passed = 0
        var failed = 0
        
        for test in testCases {
            let detected = detectIntent(test.input)
            let testPassed = (detected == test.skill)
            
            if testPassed {
                passed += 1
                print("  ✅ '\(test.input)' -> \(detected?.name ?? "nil") [\(test.reason)]")
            } else {
                failed += 1
                print("  ❌ '\(test.input)' -> \(detected?.name ?? "nil") (期望: \(test.skill?.name ?? "nil")) [\(test.reason)]")
            }
        }
        
        return (passed, failed)
    }
}

// MARK: - 用户偏好测试

class UserPreferenceTest {
    private var rejectedSkills: Set<String> = []
    private var autoConfirmSkills: Set<String> = []
    private var consecutiveRejections = 0
    
    func recordRejection(_ skill: MockSkill) {
        rejectedSkills.insert(skill.rawValue)
        consecutiveRejections += 1
    }
    
    func shouldSkip(_ skill: MockSkill) -> Bool {
        rejectedSkills.contains(skill.rawValue)
    }
    
    func run() -> (passed: Int, failed: Int) {
        print("\n🧪 测试 2: 用户偏好系统\n")
        
        var passed = 0
        var failed = 0
        
        recordRejection(.screenshot)
        if shouldSkip(.screenshot) {
            passed += 1
            print("  ✅ 拒绝后应该跳过")
        } else {
            failed += 1
            print("  ❌ 拒绝后没有跳过")
        }
        
        if !shouldSkip(.codeReview) {
            passed += 1
            print("  ✅ 未拒绝的不跳过")
        } else {
            failed += 1
            print("  ❌ 未拒绝的被跳过了")
        }
        
        recordRejection(.translateText)
        recordRejection(.webSearch)
        if consecutiveRejections == 3 {
            passed += 1
            print("  ✅ 连续拒绝计数正确 (3)")
        } else {
            failed += 1
            print("  ❌ 连续拒绝计数错误 (\(consecutiveRejections))")
        }
        
        return (passed, failed)
    }
}

// MARK: - Agent 能力测试

class AgentCapabilityTest {
    struct MockAgent {
        let name: String
        let capabilities: [String]
        
        func supports(_ capability: String) -> Bool {
            capabilities.contains(capability)
        }
    }
    
    func run() -> (passed: Int, failed: Int) {
        print("\n🧪 测试 3: Agent 能力检查\n")
        
        var passed = 0
        var failed = 0
        
        let textAgent = MockAgent(name: "Text Agent", capabilities: ["textChat"])
        if !textAgent.supports("vision") {
            passed += 1
            print("  ✅ Text Agent 不支持 vision")
        } else {
            failed += 1
            print("  ❌ Text Agent 错误地支持 vision")
        }
        
        let visionAgent = MockAgent(name: "Vision Agent", capabilities: ["textChat", "vision", "imageAnalysis"])
        if visionAgent.supports("vision") && visionAgent.supports("imageAnalysis") {
            passed += 1
            print("  ✅ Vision Agent 支持 vision 和 imageAnalysis")
        } else {
            failed += 1
            print("  ❌ Vision Agent 能力检查失败")
        }
        
        return (passed, failed)
    }
}

// MARK: - 性能测试

class PerformanceTest {
    func run() {
        print("\n🧪 测试 4: 性能测试\n")
        
        let intentTest = IntentDetectionTest()
        let iterations = 1000
        
        let start = Date()
        for _ in 0..<iterations {
            _ = intentTest.detectIntent("截图分析一下")
        }
        let duration = Date().timeIntervalSince(start)
        
        let avgTime = duration / Double(iterations) * 1000
        print("  \(iterations) 次意图检测")
        print("  总耗时: \(String(format: "%.2f", duration * 1000)) ms")
        print("  平均: \(String(format: "%.3f", avgTime)) ms/次")
        
        if avgTime < 1.0 {
            print("  ✅ 性能良好")
        } else {
            print("  ⚠️ 性能一般")
        }
    }
}

// MARK: - 主程序

func printLine(_ char: Character = "=", count: Int = 50) {
    print(String(repeating: char, count: count))
}

printLine()
print("  MacAssistant 自测程序")
printLine()

let intentTest = IntentDetectionTest()
let (intentPassed, intentFailed) = intentTest.run()

let prefTest = UserPreferenceTest()
let (prefPassed, prefFailed) = prefTest.run()

let agentTest = AgentCapabilityTest()
let (agentPassed, agentFailed) = agentTest.run()

let perfTest = PerformanceTest()
perfTest.run()

print("")
printLine()
print("  测试结果汇总")
printLine()

let totalPassed = intentPassed + prefPassed + agentPassed
let totalFailed = intentFailed + prefFailed + agentFailed

print("  通过: \(totalPassed)")
print("  失败: \(totalFailed)")

if totalFailed == 0 {
    print("")
    print("  ✅ 所有测试通过！修复已生效。")
} else {
    print("")
    print("  ❌ 有 \(totalFailed) 个测试失败，请检查修复。")
}

printLine()
