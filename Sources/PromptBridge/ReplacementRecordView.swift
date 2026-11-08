import DraftCore
import SwiftUI

struct ReplacementRecordView: View {
    let record: ReplacementRecord
    let copy: (String) -> Void
    let close: () -> Void

    private var status: String {
        switch record.status {
        case .pending: "正在确认替换结果…"
        case .confirmed: "已确认替换成功"
        case .cancelled: "已取消，原文未替换"
        case .blocked: "已停止，原文未替换"
        case .unknown: "原文可能已被替换，请到原应用检查。不会自动重试或恢复原文。"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("替换记录").font(.title2)
            Text(status).font(.callout).foregroundStyle(.secondary)
            Text("每个草稿来源保留最近一次替换记录，退出应用后清空。继续编辑草稿不会改变这份记录。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Text("读取时的原文"); Spacer(); Button("复制原文") { copy(record.originalText) } }
            ScrollView { Text(record.originalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 140).padding(8).background(.quaternary.opacity(0.3))
            HStack { Text("本次译文"); Spacer(); Button("复制译文") { copy(record.writtenText) } }
            ScrollView { Text(record.writtenText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 140).padding(8).background(.quaternary.opacity(0.3))
            HStack { Spacer(); Button("关闭", action: close) }
        }.padding(20).frame(width: 480)
    }
}
