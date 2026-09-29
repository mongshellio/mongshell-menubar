// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mongshell-menubar",
    platforms: [
        .macOS(.v14)
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
