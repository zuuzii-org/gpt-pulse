import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: PulseSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginService

    let requestNotificationAuthorization: @MainActor () async -> Void

    var body: some View {
        Form {
            Section("触边") {
                Toggle("启用右侧边缘触发", isOn: $settings.edgeTriggerEnabled)
                Toggle("全屏应用和游戏中禁用", isOn: $settings.disableInFullScreen)

                LabeledContent("触发区域", value: "鼠标所在屏幕右侧中间 60%")
                LabeledContent("停留时间", value: "200 ms")
                LabeledContent("侧边栏", value: "\(Int(settings.panelWidth)) px · 全高")
            }

            Section("通知") {
                Toggle("任务状态通知", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        Task { await requestNotificationAuthorization() }
                    }
                Toggle("播放通知声音", isOn: $settings.notificationSoundEnabled)
                    .disabled(!settings.notificationsEnabled)
            }

            Section("系统") {
                Toggle("登录时启动 GPT Pulse", isOn: launchAtLoginBinding)

                if launchAtLogin.requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Label("需要在系统设置中允许登录项。", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开系统设置") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section("隐私") {
                Text("V1 只读取本机 Codex 桌面版任务数据。GPT Pulse 仅写入自己的未查看状态与偏好设置，不修改 Codex 任务记录。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 430, idealHeight: 470)
        .navigationTitle("GPT Pulse 设置")
        .onAppear {
            launchAtLogin.refresh()
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { enabled in
                Task { await launchAtLogin.setEnabled(enabled) }
            }
        )
    }
}
