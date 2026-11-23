import SwiftUI

/// 设置页：引导总开关 + 规则说明
struct SettingsView: View {
    @AppStorage("guidanceEnabled") private var guidanceEnabled = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("构图引导", isOn: $guidanceEnabled)
                } footer: {
                    Text("关闭后 App 将和普通相机一样，不显示任何构图提示。")
                }

                Section("当前启用的构图规则") {
                    Label("三分法：主体靠近三分交叉点", systemImage: "grid")
                    Label("水平线：位置接近上/下三分线，且不倾斜", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    Label("主体大小：避免过小或占满全屏", systemImage: "person.crop.rectangle")
                    Label("顶部留白：主体不贴画面顶边", systemImage: "arrow.down.to.line")
                }

                Section("关于") {
                    LabeledContent("版本", value: "0.2 (M1-M2 预写)")
                    LabeledContent("分析方式", value: "端侧离线，不上传照片")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}
