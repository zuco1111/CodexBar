import CodexBarCore
import Foundation
import Testing

struct CodexUsageFetcherFallbackTests {
    @Test
    func `CLI usage falls back from RPC decode mismatch to TTY status`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])
        let snapshot = try await fetcher.loadLatestUsage()

        #expect(snapshot.primary?.usedPercent == 12)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.secondary?.windowMinutes == 10080)
    }

    @Test
    func `CLI credits fall back from RPC decode mismatch to TTY status`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])
        let credits = try await fetcher.loadLatestCredits()

        #expect(credits.remaining == 42)
    }

    private func makeDecodeMismatchStubCodexCLI() throws -> String {
        let script = """
        #!/usr/bin/python3
        import json
        import sys

        args = sys.argv[1:]
        if "app-server" in args:
            for line in sys.stdin:
                if not line.strip():
                    continue
                message = json.loads(line)
                method = message.get("method")
                if method == "initialized":
                    continue

                identifier = message.get("id")
                if method == "initialize":
                    payload = {"id": identifier, "result": {}}
                elif method == "account/rateLimits/read":
                    payload = {
                        "id": identifier,
                        "error": {
                            "message": "failed to fetch codex rate limits: Decode error for https://chatgpt.com/backend-api/wham/usage: unknown variant `prolite`"
                        }
                    }
                elif method == "account/read":
                    payload = {
                        "id": identifier,
                        "result": {
                            "account": {
                                "type": "chatgpt",
                                "email": "stub@example.com",
                                "planType": "prolite"
                            },
                            "requiresOpenaiAuth": False
                        }
                    }
                else:
                    payload = {"id": identifier, "result": {}}

                print(json.dumps(payload), flush=True)
        else:
            for line in sys.stdin:
                if "/status" in line:
                    break
            print("Credits: 42 credits", flush=True)
            print("5h limit: [#####] 88% left", flush=True)
            print("Weekly limit: [##] 75% left", flush=True)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fallback-stub-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
