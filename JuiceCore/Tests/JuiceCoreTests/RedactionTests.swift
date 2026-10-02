import Foundation
import Testing
@testable import JuiceCore

/// Spec §8.3: CLI text can end up in readings.json and in Diagnostics, so anything token-shaped in it is masked
/// before it is stored or shown. Every string here is invented for the test; none is a real credential.
@Test func redactionMasksEveryTokenShape() {
    #expect(ReadError.redact("key sk-ant-api03-AaBbCc_12-34 here") == "key ‹redacted› here")
    #expect(ReadError.redact("sk-proj-AbCdEfGh1234") == "‹redacted›")
    #expect(ReadError.redact("authorization: Bearer abc.def-ghi") == "authorization: ‹redacted›")
    #expect(ReadError.redact("header: bearer   qrs456") == "header: ‹redacted›")
    #expect(ReadError.redact("token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl end") == "token ‹redacted› end")
    #expect(ReadError.redact("two eyJhbGciOiJIUzI1NiJ9.payload done") == "two ‹redacted› done")
    // A bearer token that is itself an API key collapses to a single mark.
    #expect(ReadError.redact("Bearer sk-ant-api03-AaBbCc_12-34") == "‹redacted›")
}

@Test func redactionLeavesOrdinaryTextAlone() {
    let plain = "Read failed: exit 2 · 77% left, week · resets Fri · usage 13.5% of the weekly limit"
    #expect(ReadError.redact(plain) == plain)
    #expect(ReadError.redact("") == "")
    #expect(ReadError.redact("100% used, retry-after: 60") == "100% used, retry-after: 60")
}

@Test func classifyStoresTheMaskedFormOfCLIOutput() {
    let stderr = "  request failed: authorization: Bearer sk-ant-api03-AaBbCc_12-34 · HTTP 500  "
    guard case .failed(let detail) = ReadError.classify(exitStatus: 1, stdout: "", stderr: stderr) else {
        Issue.record("expected .failed"); return
    }
    #expect(!detail.contains("sk-ant"))
    #expect(detail.lowercased().contains("bearer") == false)
    #expect(detail.contains("‹redacted›"))
    #expect(detail.contains("HTTP 500"))
}

@Test func cliUpdateNeededIsMaskedToo() {
    let stderr = "error: unknown option '--json' (sent with Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln)"
    guard case .cliUpdateNeeded(let detail) = ReadError.classify(exitStatus: 2, stdout: "", stderr: stderr) else {
        Issue.record("expected .cliUpdateNeeded"); return
    }
    #expect(!detail.contains("eyJ"))
    #expect(detail.contains("unknown option"))
    #expect(detail.contains("‹redacted›"))
}
