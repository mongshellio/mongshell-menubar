// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mongshell-menubar",
    platforms: [
        // 두 타깃 모두에 적용된다. `swift build` 는 이 값을 바이너리의 SDK
        // 버전으로도 찍고, macOS 는 그 값으로 호환 동작을 고른다. 14 였을 때는
        // macOS 27 에서 앱을 실행할 때마다 빈 Settings 창이 떴다 (Decision #40).
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "mongshell-menubar",
            path: "Sources/mongshell-menubar",
            // 하네스 문서 파일 (영역별 CLAUDE.md) — 빌드 대상이 아니므로 unhandled-file 경고를 막기 위해 제외
            exclude: [
                "Models/CLAUDE.md",
                "Services/CLAUDE.md",
                "Views/CLAUDE.md"
            ]
        ),
        // Headless watchdog for the always-on server mac: probes openclaw,
        // auto-heals it, and writes a JSON status file that `tailscale funnel`
        // serves to the menubar clients. Installed by server/install.sh.
        .executableTarget(
            name: "mongshell-openclaw-agent",
            path: "Sources/mongshell-openclaw-agent"
        )
        // NOTE: no SwiftPM test target on purpose — `swift test` needs XCTest or
        // swift-testing, and neither ships with the Command Line Tools this
        // project builds against. `scripts/test.sh` compiles Tests/ against the
        // real sources instead. See README § 개발용.
    ]
)
