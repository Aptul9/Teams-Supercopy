import { test } from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { cpSync, existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, relative } from "node:path"
import { fileURLToPath } from "node:url"
import { compareVersions, parseVersion, publishPackage, stagePackage, submissionDecision, verifyAuthentication } from "../tools/chrome-web-store.mjs"

const version = "1.0.1"
const itemId = "a".repeat(32)
const revision = (state, value = version) => ({ state, distributionChannels: [{ crxVersion: value }] })
const published = (value = "1.0.0") => ({ publishedItemRevisionStatus: revision("PUBLISHED", value) })

function fixture(responses) {
    const calls = []
    const waits = []
    return {
        calls,
        waits,
        run: (overrides = {}) => publishPackage({
            publisherId: "publisher-id", itemId, token: "fixture-token", version,
            archive: Buffer.from("fixture-zip"),
            wait: async ms => waits.push(ms),
            fetchImpl: async (url, options) => {
                calls.push({ url, ...options })
                assert.ok(responses.length, "Unexpected API request")
                const next = responses.shift()
                return { ok: !next.httpError, status: next.httpError ?? 200, json: async () => next }
            },
            ...overrides
        })
    }
}

function files(directory) {
    return readdirSync(directory, { recursive: true, withFileTypes: true })
        .filter(entry => entry.isFile())
        .map(entry => relative(directory, join(entry.parentPath, entry.name)).replaceAll("\\", "/"))
        .sort()
}

test("versions follow Chrome's one to four integer parts and compare numerically", () => {
    assert.deepEqual(parseVersion("1.0.1"), [1, 0, 1])
    for (const bad of ["", "1.0.1.2.3", "01.0.0", "1.0.65536", "1.0.x", "1..0"]) assert.throws(() => parseVersion(bad))
    assert.equal(compareVersions("1.0.1", "1.0.0"), 1)
    assert.equal(compareVersions("1.0.10", "1.0.9"), 1)
    assert.equal(compareVersions("1.0", "1.0.0"), 0)
    assert.equal(compareVersions("1.0.0", "1.0.0.1"), -1)
})

test("staging copies the extension unchanged, adds a licence only when present and refuses an existing stage", () => {
    const root = mkdtempSync(join(process.env.TEMP ?? tmpdir(), "cws-test-"))
    mkdirSync(join(root, "browser-extension", "icons"), { recursive: true })
    mkdirSync(join(root, ".release"))
    const manifest = JSON.stringify({ manifest_version: 3, name: "Fixture", version: "1.2.3" })
    writeFileSync(join(root, "browser-extension", "manifest.json"), manifest)
    writeFileSync(join(root, "browser-extension", "icons", "icon16.png"), "png")
    assert.equal(stagePackage(root), "1.2.3")
    assert.equal(readFileSync(join(root, ".release", "extension", "manifest.json"), "utf8"), manifest)
    assert.deepEqual(files(join(root, ".release", "extension")), ["icons/icon16.png", "manifest.json"])
    assert.throws(() => stagePackage(root))

    const licensed = mkdtempSync(join(process.env.TEMP ?? tmpdir(), "cws-licence-"))
    cpSync(join(root, "browser-extension"), join(licensed, "browser-extension"), { recursive: true })
    writeFileSync(join(licensed, "LICENSE"), "MIT License fixture")
    mkdirSync(join(licensed, ".release"))
    stagePackage(licensed)
    assert.equal(readFileSync(join(licensed, ".release", "extension", "LICENSE"), "utf8"), "MIT License fixture")
})

test("the real package is exactly the tracked browser-extension files", () => {
    const repo = fileURLToPath(new URL("..", import.meta.url))
    const root = mkdtempSync(join(process.env.TEMP ?? tmpdir(), "cws-real-"))
    cpSync(join(repo, "browser-extension"), join(root, "browser-extension"), { recursive: true })
    if (existsSync(join(repo, "LICENSE"))) cpSync(join(repo, "LICENSE"), join(root, "LICENSE"))
    mkdirSync(join(root, ".release"))
    const staged = stagePackage(root)
    assert.equal(staged, JSON.parse(readFileSync(join(repo, "browser-extension", "manifest.json"), "utf8")).version)
    const tracked = execFileSync("git", ["ls-files", "browser-extension"], { cwd: repo, encoding: "utf8" })
        .trim().split("\n").map(path => path.replace(/^browser-extension\//, ""))
    if (existsSync(join(repo, "LICENSE"))) tracked.push("LICENSE")
    assert.deepEqual(files(join(root, ".release", "extension")), tracked.sort())
})

test("published and submitted versions are idempotent", () => {
    assert.equal(submissionDecision({ publishedItemRevisionStatus: revision("PUBLISHED") }, version), "published")
    assert.equal(submissionDecision({ submittedItemRevisionStatus: revision("PENDING_REVIEW") }, version), "in_review")
    assert.equal(submissionDecision({ ...published(), submittedItemRevisionStatus: revision("PENDING_REVIEW", "1.0.0.5") }, version), "deferred")
})

test("only a version higher than every store version is uploaded", () => {
    assert.equal(submissionDecision(published("1.0.0"), version), "upload")
    assert.equal(submissionDecision(published("1.0.2"), version), "not_newer")
    assert.equal(submissionDecision({ ...published("1.0.0"), submittedItemRevisionStatus: revision("PENDING_REVIEW", "1.0.2") }, version), "not_newer")
    assert.equal(submissionDecision({ ...published("1.0.0"), submittedItemRevisionStatus: revision("REJECTED", "1.0.2") }, version), "upload")
})

test("policy warnings, staged releases and rejected same version block submission", () => {
    for (const state of [{ takenDown: true }, { warned: true }, { submittedItemRevisionStatus: revision("STAGED") }, { submittedItemRevisionStatus: revision("REJECTED") }]) {
        assert.throws(() => submissionDecision(state, version))
    }
})

test("an old rejected version can be replaced with a fixed release", () => {
    assert.equal(submissionDecision({ ...published(), submittedItemRevisionStatus: revision("REJECTED", "1.0.0.9") }, version), "upload")
})

test("pending review is deferred without upload, cancellation or publish", async () => {
    const f = fixture([{ ...published(), submittedItemRevisionStatus: revision("PENDING_REVIEW", "1.0.0.9") }])
    assert.deepEqual(await f.run(), { result: "deferred", version })
    assert.equal(f.calls.length, 1)
    assert.ok(f.calls[0].url.endsWith(":fetchStatus"))
})

test("published or older manifest version requires no write request", async () => {
    for (const [status, result] of [[published(version), "published"], [published("1.1.0"), "not_newer"]]) {
        const f = fixture([status])
        assert.deepEqual(await f.run(), { result, version })
        assert.equal(f.calls.length, 1)
    }
})

test("successful upload is submitted for review and read back", async () => {
    const f = fixture([published(), { uploadState: "SUCCEEDED", crxVersion: version }, { state: "PENDING_REVIEW" }, { ...published(), submittedItemRevisionStatus: revision("PENDING_REVIEW") }])
    assert.deepEqual(await f.run(), { result: "in_review", version })
    assert.equal(f.calls[0].url, `https://chromewebstore.googleapis.com/v2/publishers/publisher-id/items/${itemId}:fetchStatus`)
    assert.equal(f.calls[0].headers.Authorization, "Bearer fixture-token")
    assert.match(f.calls[1].url, /^https:\/\/chromewebstore\.googleapis\.com\/upload\/v2\/publishers\/publisher-id\/items\/a{32}:upload$/)
    assert.equal(f.calls[1].method, "POST")
    assert.equal(f.calls[1].headers["Content-Type"], "application/zip")
    assert.equal(f.calls[1].body.toString(), "fixture-zip")
    assert.ok(f.calls[2].url.endsWith(":publish"))
    assert.deepEqual(JSON.parse(f.calls[2].body), { publishType: "DEFAULT_PUBLISH", skipReview: false, blockOnWarnings: true })
    assert.ok(f.calls[3].url.endsWith(":fetchStatus"))
})

test("asynchronous uploads wait for the upload state before publishing", async () => {
    const f = fixture([{}, { uploadState: "IN_PROGRESS" }, { lastAsyncUploadState: "IN_PROGRESS" }, { lastAsyncUploadState: "SUCCEEDED" }, { state: "PENDING_REVIEW" }, { submittedItemRevisionStatus: revision("PENDING_REVIEW") }])
    assert.equal((await f.run()).result, "in_review")
    assert.deepEqual(f.waits, [2000, 2000])
})

test("failed uploads cannot publish", async () => {
    const f = fixture([{}, { uploadState: "FAILED" }])
    await assert.rejects(f.run(), /upload did not succeed/)
    assert.equal(f.calls.length, 2)
})

test("stuck asynchronous upload has a deadline", async () => {
    const f = fixture([{}, { uploadState: "IN_PROGRESS" }, ...Array.from({ length: 40 }, () => ({ lastAsyncUploadState: "IN_PROGRESS" }))])
    await assert.rejects(f.run(), /upload did not succeed/)
    assert.equal(f.waits.length, 40)
    assert.ok(!f.calls.some(call => call.url.endsWith(":publish")))
})

test("authentication errors are explicit and do not include the token", async () => {
    const f = fixture([{ httpError: 401 }])
    await assert.rejects(f.run(), error => /HTTP 401/.test(error.message) && !error.message.includes("fixture-token"))
    assert.equal(f.calls.length, 1)
})

test("store rejection includes the Google reason without reflecting the access token", async () => {
    const f = fixture([{ httpError: 403, error: { status: "PERMISSION_DENIED", message: "Missing publisher access: fixture-token", details: [{ reason: "ACCESS_DENIED" }] } }])
    await assert.rejects(f.run(), error => /HTTP 403/.test(error.message) && /ACCESS_DENIED/.test(error.message) && /Missing publisher access/.test(error.message) && !error.message.includes("fixture-token"))
    assert.equal(f.calls.length, 1)
})

test("unreadable Google error bodies retain the HTTP error", async () => {
    const f = fixture([])
    await assert.rejects(f.run({ fetchImpl: async () => ({ ok: false, status: 502, json: async () => { throw Error("not JSON") } }) }), /HTTP 502/)
})

test("uploaded package version must match expected version", async () => {
    const f = fixture([{}, { uploadState: "SUCCEEDED", crxVersion: "1.0.2" }])
    await assert.rejects(f.run(), /does not match/)
    assert.equal(f.calls.length, 2)
})

test("publish state alone is insufficient without version read-back", async () => {
    const f = fixture([{}, { uploadState: "SUCCEEDED" }, { state: "PENDING_REVIEW" }, {}])
    await assert.rejects(f.run(), /read-back did not confirm/)
})

test("invalid configuration makes no network calls", async () => {
    for (const overrides of [{ token: "" }, { itemId: "missing" }, { publisherId: "../wrong" }, { version: "" }, { version: "1.0.x" }]) {
        const f = fixture([])
        await assert.rejects(f.run(overrides))
        assert.equal(f.calls.length, 0)
    }
})

test("publishing to trusted testers is confirmed as a publication", async () => {
    const f = fixture([{}, { uploadState: "SUCCEEDED" }, { state: "PUBLISHED_TO_TESTERS" }, { publishedItemRevisionStatus: revision("PUBLISHED_TO_TESTERS") }])
    assert.equal((await f.run()).result, "published")
})

test("authentication check validates scope, lifetime and returned identity without store calls", async () => {
    const expected = "publisher@project.iam.gserviceaccount.com"
    const result = await verifyAuthentication({
        token: "fixture-token", serviceAccount: expected,
        fetchImpl: async url => {
            assert.ok(url.startsWith("https://oauth2.googleapis.com/tokeninfo?"))
            return { ok: true, json: async () => ({ scope: "https://www.googleapis.com/auth/chromewebstore", expires_in: 300, email: expected }) }
        }
    })
    assert.equal(result.result, "authenticated")
    assert.equal(result.tokenEmail, expected)
    assert.ok(!JSON.stringify(result).includes("fixture-token"))
})

test("authentication check rejects wrong scope, expired token and wrong identity", async () => {
    const valid = { scope: "https://www.googleapis.com/auth/chromewebstore", expires_in: 300 }
    for (const info of [{ ...valid, scope: "other" }, { ...valid, expires_in: 0 }, { ...valid, email: "other@project.iam.gserviceaccount.com" }]) {
        await assert.rejects(verifyAuthentication({
            token: "fixture-token", serviceAccount: "publisher@project.iam.gserviceaccount.com",
            fetchImpl: async () => ({ ok: true, json: async () => info })
        }))
    }
})
