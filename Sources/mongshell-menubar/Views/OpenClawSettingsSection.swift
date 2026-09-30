import SwiftUI

/// The openclaw rows of the settings form. The URL field is always shown: a
/// remote server can't be detected from here, so this field is the only way in.
/// Everything else appears once a URL is applied.
struct OpenClawSettingsSection: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var openClaw: OpenClawModel

    private let intervals = [30, 60, 120]

    // `@State` 를 손으로 펼친 것 (Decision #11-2, `MenuBarIconView.pulsing` 참조).
    // 입력 중인 주소는 여기에만 두고 "적용" 때 모델로 넘긴다 — 타이핑 도중의
    // 반쪽 주소로 폴링이 돌지 않게.
    private var _draftURL: State<String>
    private var draftURL: String {
        get { _draftURL.wrappedValue }
        nonmutating set { _draftURL.wrappedValue = newValue }
    }
    private var _urlError = State<String?>(initialValue: nil)
    private var urlError: String? {
        get { _urlError.wrappedValue }
        nonmutating set { _urlError.wrappedValue = newValue }
    }

    init(prefs: Preferences, openClaw: OpenClawModel) {
        self.prefs = prefs
        self.openClaw = openClaw
        _draftURL = State(initialValue: prefs.openClawStatusURL)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { draftURL }, set: { draftURL = $0 })
    }

    private var isDraftApplied: Bool {
        draftURL.trimmingCharacters(in: .whitespacesAndNewlines) == prefs.openClawStatusURL
    }

    var body: some View {
        TextField("상태 URL", text: draftBinding,
                  prompt: Text("https://…ts.net:8443/…"))
            .autocorrectionDisabled()
            .onSubmit(apply)

        HStack {
            Spacer()
            Button("지우기", action: clear)
                .disabled(draftURL.isEmpty && prefs.openClawStatusURL.isEmpty)
            Button("적용", action: apply)
                .disabled(isDraftApplied)
        }

        if let urlError {
            Text(urlError)
                .font(.caption)
                .foregroundStyle(Palette.errorText)
        }

        if prefs.openClawStatusURLValue != nil {
            Picker("메뉴바 표시", selection: $prefs.menuBarTargetRaw) {
                ForEach(MenuBarTarget.allCases, id: \.rawValue) { target in
                    Text(target.displayName).tag(target.rawValue)
                }
            }

            LabeledContent("openclaw") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(openClaw.health.dotColor)
                        .frame(width: 8, height: 8)
                    Text(openClaw.health.settingsLabel)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("마지막 확인", value: openClaw.checkedClockText ?? "없음")

            Picker("확인 간격", selection: $prefs.openClawPollSeconds) {
                ForEach(intervals, id: \.self) { s in
                    Text("\(s)초").tag(s)
                }
            }

            // Read-only: auto-heal is a server install flag now (Decision #25).
            LabeledContent("자동 복구", value: autoHealText)
        }
    }

    private var autoHealText: String {
        switch openClaw.reading.lastSuccess?.autoHeal {
        case true?:  return "서버에서 켜짐"
        case false?: return "서버에서 꺼짐"
        case nil:    return "알 수 없음"
        }
    }

    private func apply() {
        do {
            try openClaw.applyStatusURL(draftURL)
            draftURL = prefs.openClawStatusURL
            urlError = nil
        } catch {
            urlError = error.errorDescription
        }
    }

    private func clear() {
        draftURL = ""
        apply()
    }
}
