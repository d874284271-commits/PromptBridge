import DraftCore
import SwiftUI

struct TranslationPreferencesView: View {
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var session: SettingsEditingSession
    @State private var languageIsComposing = false
    @State private var templateIsComposing = false
    let reload: () -> Void
    let close: () -> Void

    private var template: Binding<String> {
        Binding(get: { session.preferencesDraft.template(for: session.preferencesIntent) }, set: {
            if session.preferencesIntent == .translate { session.preferencesDraft.translationTemplate = $0 }
            else { session.preferencesDraft.optimizationTemplate = $0 }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("翻译与浮窗").font(.system(size: 20, weight: .semibold))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("默认目标语言").font(.callout.weight(.medium))
                            LanguageComboBox(text: $session.preferencesDraft.targetLanguage,
                                onCompositionChange: { languageIsComposing = $0 })
                                .frame(height: 26).disabled(templateIsComposing)
                            Text("用于新草稿。浮窗中提交目标语言，也会更新此默认值。原文语言自动识别。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            error(at: .language)
                        }.id(SettingsEditingSession.PreferenceErrorLocation.language)
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Auto：翻译后自动替换原文", isOn: $session.preferencesDraft.automaticTranslationAndReplacement)
                                .disabled(session.isComposing)
                            Text("适用于桌面应用和 CLI。开启后自动读取、翻译并替换；关闭后先检查译文，再确认替换。全程不发送消息。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("浮窗显示", selection: $session.preferencesDraft.launcherMode) {
                                Text("始终显示").tag(LauncherMode.persistent)
                                Text("编辑支持的输入框时显示").tag(LauncherMode.focusedInput)
                            }.disabled(session.isComposing)
                            Text("浮窗出现时不读取正文；点击浮窗或按 ⌥T 后才读取。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        #if !PROMPTBRIDGE_TESTING
                        DesktopInstallationView()
                        #endif
                        Divider()
                        DisclosureGroup("提示词模板", isExpanded: Binding(get: { session.showsTemplates }, set: {
                            if !session.isComposing { session.showsTemplates = $0 }
                        })) { templateEditor.padding(.top, 8) }
                            .id(SettingsEditingSession.PreferenceErrorLocation.template)
                        DisclosureGroup("配置文件", isExpanded: $session.showsPreferenceFile) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(settings.preferencesFileURL?.path ?? "隔离测试（不写文件）")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let notice = settings.preferencesNotice {
                                    Text(notice).foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                                }
                                error(at: .file)
                                Button("重新加载设置", action: reload).font(.caption).disabled(session.isComposing)
                            }.padding(.top, 8)
                        }.disabled(session.isComposing).id(SettingsEditingSession.PreferenceErrorLocation.file)
                    }.padding(24)
                }
                .onChange(of: session.preferencesError) { _, _ in
                    guard let location = session.preferencesErrorLocation else { return }
                    DispatchQueue.main.async { proxy.scrollTo(location, anchor: .center) }
                }
            }
            Divider()
            HStack {
                Button("完成", action: close).disabled(session.isComposing)
                if let notice = session.preferencesNotice, !session.preferencesHaveChanges {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存设置") { session.savePreferences() }
                    .buttonStyle(PrimaryActionStyle()).disabled(session.isComposing)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .onChange(of: session.preferencesIntent) { _, _ in session.templateDocumentID = UUID() }
        .onChange(of: languageIsComposing) { _, _ in session.preferencesIsComposing = languageIsComposing || templateIsComposing }
        .onChange(of: templateIsComposing) { _, _ in session.preferencesIsComposing = languageIsComposing || templateIsComposing }
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("提示词模板类型", selection: $session.preferencesIntent) {
                Text("翻译").tag(DraftIntent.translate)
                Text("翻译并优化表达").tag(DraftIntent.optimize)
            }.pickerStyle(.segmented).disabled(session.isComposing)
            NativeEditor(value: template.wrappedValue, documentID: session.templateDocumentID,
                         isEditable: !languageIsComposing) { value, marked in
                template.wrappedValue = value
                templateIsComposing = marked
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: InterfaceTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: InterfaceTheme.cornerRadius).stroke(.quaternary))
            .accessibilityLabel("系统提示词模板")
            error(at: .template)
            Text("请保留 {{target_language}}，调用模型时会替换为目标语言。原文单独提交，不附带会话历史。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("恢复默认模板") {
                template.wrappedValue = TranslationPreferences().template(for: session.preferencesIntent)
                session.templateDocumentID = UUID()
            }.font(.caption).disabled(session.isComposing)
            DisclosureGroup("预览发送给模型的提示词", isExpanded: $session.showsTemplatePreview) {
                Text(preview).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(session.isComposing)
        }
    }

    @ViewBuilder private func error(at location: SettingsEditingSession.PreferenceErrorLocation) -> some View {
        if session.preferencesErrorLocation == location, let error = session.preferencesError {
            Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preview: String {
        do { return try session.preferencesDraft.render(intent: session.preferencesIntent, targetLanguage: session.preferencesDraft.targetLanguage) }
        catch { return error.localizedDescription }
    }
}
