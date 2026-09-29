import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var openClaw: OpenClawModel
    @ObservedObject var claude: ClaudeSettingsModel
    @ObservedObject var loginItem: LoginItemModel

    private let intervals = [180, 300, 600, 900]
    private let openClawIntervals = [30, 60, 120]

    /// Mirrors the live menu bar (same `showsOpenClaw` rule).
    private var openClawPreviewColor: Color? {
        prefs.showsOpenClaw ? openClaw.health.dotColor : nil
    }

    var body: some View {
        Form {
            Section("일반") {
                // The system's Login Items list is the SSOT; the model only
                // caches it, so the toggle reads through the model and writes
                // through its method (no direct binding to flip).
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Palette.errorText)
                }
            }

            Section("메뉴바") {
                // Live preview of the bar content with the current settings.
                LabeledContent("미리보기") {
                    MenuBarContent(fiveHourUsed: model.snapshot.fiveHourPercent,
                                   weeklyUsed: model.snapshot.weeklyAllPercent,
                                   showRemaining: prefs.showRemaining,
                                   colorCoding: prefs.colorCoding,
                                   showPercent: prefs.showPercent,
                                   fiveHourReset: TimeText.clockShort(model.snapshot.fiveHourResetAt),
                                   openClawDotColor: openClawPreviewColor)
                }

                Toggle("사용량 3단계 색상", isOn: $prefs.colorCoding)
                Toggle("사용량 게이지·퍼센트 표시", isOn: $prefs.showPercent)
                Toggle("남은 양으로 표시 (기본: 사용한 양)", isOn: $prefs.showRemaining)
                Toggle("90% 이상일 때 아이콘 맥동", isOn: $prefs.pulseWhenCritical)
            }

            Section("업데이트") {
                Picker("폴링 간격", selection: $prefs.pollIntervalSeconds) {
                    ForEach(intervals, id: \.self) { s in
                        Text(s < 600 ? "\(s / 60)분\(s % 60 == 0 ? "" : "")" : "\(s / 60)분").tag(s)
                    }
                }
                Text("최소 3분 — 더 짧으면 서버가 요청을 제한합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("25/50/75/90% 도달 알림", isOn: $prefs.notifyThresholds)
            }

            Section("Claude Code") {
                ClaudeSettingsSection(claude: claude)
            }

            Section("openclaw") {
                openClawSection
            }

            Section("계정") {
                accountRow
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 700)
    }

    /// openclaw controls. When openclaw isn't installed, the picker is locked
    /// to `Claude만` and everything else is hidden behind an explanatory note.
    @ViewBuilder private var openClawSection: some View {
        let installed = prefs.openClawStatusURLValue != nil

        Picker("메뉴바 표시", selection: $prefs.menuBarTargetRaw) {
            ForEach(MenuBarTarget.allCases, id: \.rawValue) { target in
                Text(target.displayName).tag(target.rawValue)
            }
        }
        .disabled(!installed)

        if !installed {
            Text("openclaw가 설치되어 있지 않습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            LabeledContent("상태") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(openClaw.health.dotColor)
                        .frame(width: 8, height: 8)
                    Text(openClaw.health.settingsLabel)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("openclaw 확인 간격", selection: $prefs.openClawPollSeconds) {
                ForEach(openClawIntervals, id: \.self) { s in
                    Text("\(s)초").tag(s)
                }
            }
            .disabled(prefs.menuBarTarget == .claudeOnly)
        }
    }

    @ViewBuilder private var accountRow: some View {
        switch model.loadState {
        case .loaded(.oauthLogin):
            LabeledContent("상태", value: "로그인됨 (OAuth)")
            Button("로그아웃") { model.signOut() }
        case .loaded(.claudeCodeCLI):
            LabeledContent("상태", value: "Claude Code 계정 사용 중")
            Button("이 앱 계정으로 로그인") { Task { await model.signIn() } }
        default:
            LabeledContent("상태", value: "로그아웃됨")
            Button("Claude 계정으로 로그인") { Task { await model.signIn() } }
        }
    }
}
