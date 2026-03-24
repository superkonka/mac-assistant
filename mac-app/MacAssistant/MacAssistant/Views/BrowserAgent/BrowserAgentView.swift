//
//  BrowserAgentView.swift
//  MacAssistant
//
//  兼容壳：统一转到新的系统浏览器协同面板
//

import SwiftUI

@available(*, deprecated, message: "Use SimpleBrowserAgentView instead.")
struct BrowserAgentView: View {
    var body: some View {
        SimpleBrowserAgentView()
    }
}

struct BrowserAgentView_Previews: PreviewProvider {
    static var previews: some View {
        BrowserAgentView()
            .frame(width: 760, height: 560)
    }
}
