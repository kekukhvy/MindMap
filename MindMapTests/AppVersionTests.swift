import Testing
@testable import MindMap

struct AppVersionTests {
    @Test func textShowsVersionBuildAndCommit() {
        #expect(AppVersion.text(version: "1.0", build: "142", commit: "3f3fd45") == "Version 1.0 (142, 3f3fd45)")
    }

    @Test func textWithoutCommitShowsOnlyTheBuild() {
        #expect(AppVersion.text(version: "1.0", build: "1", commit: "") == "Version 1.0 (1)")
    }

    @Test func buildDetailJoinsBuildAndCommit() {
        #expect(AppVersion.buildDetail(build: "142", commit: "3f3fd45") == "142, 3f3fd45")
        #expect(AppVersion.buildDetail(build: "142", commit: "") == "142")
    }
}
