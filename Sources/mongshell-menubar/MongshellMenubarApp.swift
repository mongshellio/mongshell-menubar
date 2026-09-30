import SwiftUI

@main
struct MongshellMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The UI lives in the status item + popover (managed by AppDelegate).
        // An empty Settings scene satisfies the App protocol; the real settings
        // window is AppDelegate's.
        //
        // A Settings scene makes macOS add a "Settings…" command on ⌘,. Left
        // alone, that opens this empty scene as a blank window titled
        // "mongshell-menubar Settings", so the command is replaced with one
        // that opens the real settings window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("설정…") { delegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
