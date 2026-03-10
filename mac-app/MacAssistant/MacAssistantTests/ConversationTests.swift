//
//  ConversationTests.swift
//  MacAssistantTests
//
//  对话系统自测
//

import XCTest
@testable import MacAssistant

/// 自测类 - 验证修复是否生效
class ConversationTests: XCTestCase {
    
    // MARK: - 测试 1: 意图检测敏感度
    
    func testIntentDetectionSensitivity() {
        let intelligence = ConversationIntelligence.shared
        
        // 应该检测到的明确命令
        let shouldDetect = [
            ("截图", AISkill.screenshot),
            ("截个屏", AISkill.screenshot),
            ("screenshot", AISkill.screenshot),
            ("review 代码", AISkill.codeReview),
            ("翻译成英文", AISkill.translateText),
            ("总结一下", AISkill.summarizeText),
            ("搜索一下", AISkill.webSearch),
        ]
        
        for (input, expectedSkill) in shouldDetect {
            let parsed = intelligence.analyzeInput(input)
            XCTAssertEqual(parsed.detectedSkill?.rawValue, expectedSkill.rawValue, 
                "'\(input)' 应该检测到 \(expectedSkill.name)")
        }
        
        // 不应该检测到的模糊表述
        let shouldNotDetect = [
            "截个图看看",           // 模糊，只是说说
            "不用截图",             // 否定
            "截图算了",             // 否定
            "看看这个",             // 太模糊
            "翻译一下",             // 缺少目标语言
            "帮我看看",             // 太模糊
        ]
        
        for input in shouldNotDetect {
            let parsed = intelligence.analyzeInput(input)
            XCTAssertNil(parsed.detectedSkill, 
                "'\(input)' 不应该触发任何 Skill，但检测到了 \(parsed.detectedSkill?.name ?? "")")
        }
    }
    
    // MARK: - 测试 2: 用户偏好系统
    
    func testUserPreferences() {
        let prefs = UserPreferenceStore.shared
        
        // 重置
        prefs.resetAllPreferences()
        
        // 测试记录拒绝
        prefs.recordSkillRejection(.screenshot)
        XCTAssertTrue(prefs.shouldSkipDetection(.screenshot), 
            "被拒绝的 Skill 应该跳过检测")
        
        // 测试记录接受
        prefs.recordSkillAcceptance(.translateText)
        prefs.recordSkillAcceptance(.translateText)
        prefs.recordSkillAcceptance(.translateText)
        XCTAssertTrue(prefs.shouldAutoConfirm(.translateText),
            "使用3次的 Skill 应该自动确认")
        
        // 清理
        prefs.resetAllPreferences()
    }
    
    // MARK: - 测试 3: Agent 能力检查
    
    func testAgentCapabilityCheck() {
        // 创建一个不支持 Vision 的 Agent
        let agent = Agent(
            name: "Test Agent",
            emoji: "🤖",
            description: "测试 Agent",
            provider: .ollama,
            model: "test-model",
            capabilities: [.textChat],
            isDefault: false
        )
        
        // 检查能力
        XCTAssertFalse(agent.supports(.vision), 
            "Test Agent 不应该支持 vision")
        XCTAssertFalse(agent.supportsImageAnalysis,
            "Test Agent 不应该支持图片分析")
        
        // 创建支持 Vision 的 Agent
        let visionAgent = Agent(
            name: "Vision Agent",
            emoji: "👁️",
            description: "视觉 Agent",
            provider: .openai,
            model: "gpt-4o",
            capabilities: [.textChat, .vision, .imageAnalysis],
            isDefault: false
        )
        
        XCTAssertTrue(visionAgent.supports(.vision),
            "Vision Agent 应该支持 vision")
        XCTAssertTrue(visionAgent.supportsImageAnalysis,
            "Vision Agent 应该支持图片分析")
    }
    
    // MARK: - 测试 4: 输入解析
    
    func testInputParsing() {
        let intelligence = ConversationIntelligence.shared
        
        // 测试 @提及
        let atInput = "@GPT-4V 分析图片"
        let atParsed = intelligence.analyzeInput(atInput)
        XCTAssertTrue(atParsed.hasMentions, "应该检测到 @提及")
        
        // 测试 /命令
        let slashInput = "/screenshot"
        let slashParsed = intelligence.analyzeInput(slashInput)
        XCTAssertNotNil(slashParsed.skillCommand, "应该检测到 /命令")
        
        // 测试纯净文本
        let cleanInput = "这是一段普通对话"
        let cleanParsed = intelligence.analyzeInput(cleanInput)
        XCTAssertEqual(cleanParsed.cleanText, cleanInput, "普通文本应保持不变")
        XCTAssertFalse(cleanParsed.hasMentions, "普通文本不应有提及")
    }
}

// MARK: - 模拟运行测试

class SimulationTests: XCTestCase {
    
    /// 模拟完整对话流程
    func testFullConversationFlow() {
        print("\n========== 开始模拟对话测试 ==========\n")
        
        let scenarios = [
            ("普通对话", "你好", "应该正常响应"),
            ("明确截图", "截图", "应该触发截图 Skill"),
            ("模糊输入", "截个图看看", "不应该触发（有"看看"）"),
            ("否定输入", "不用截图", "不应该触发（有"不用"）"),
            ("/命令", "/screenshot", "应该触发 Skill 命令"),
        ]
        
        var passCount = 0
        var failCount = 0
        
        for (name, input, expectation) in scenarios {
            let parsed = ConversationIntelligence.shared.analyzeInput(input)
            
            // 判断测试是否通过
            var passed = false
            var actual = ""
            
            switch name {
            case "普通对话":
                passed = !parsed.hasMentions && parsed.detectedSkill == nil
                actual = passed ? "正常文本" : "异常触发"
            case "明确截图":
                passed = parsed.detectedSkill == .screenshot
                actual = parsed.detectedSkill?.name ?? "nil"
            case "模糊输入", "否定输入":
                passed = parsed.detectedSkill == nil
                actual = parsed.detectedSkill?.name ?? "未触发（正确）"
            case "/命令":
                passed = parsed.skillCommand != nil
                actual = parsed.skillCommand?.skill.name ?? "nil"
            default:
                passed = true
                actual = "未测试"
            }
            
            if passed {
                passCount += 1
                print("✅ \(name): 通过")
            } else {
                failCount += 1
                print("❌ \(name): 失败")
            }
            print("   输入: '\(input)'")
            print("   期望: \(expectation)")
            print("   实际: \(actual)")
            print("")
        }
        
        print("========== 测试结果: \(passCount) 通过, \(failCount) 失败 ==========\n")
        
        XCTAssertEqual(failCount, 0, "所有测试应该通过")
    }
}
