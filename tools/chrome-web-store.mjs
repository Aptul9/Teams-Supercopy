import { appendFileSync, cpSync, existsSync, mkdirSync, readFileSync } from "node:fs"
import { join, resolve } from "node:path"
import { pathToFileURL } from "node:url"
import { setTimeout as delay } from "node:timers/promises"

export const extensionDirectory = "browser-extension"

export function parseVersion(value) {
    const parts = String(value ?? "").split(".")
    if (parts.length < 1 || parts.length > 4 || parts.some(part => !/^(0|[1-9]\d*)$/.test(part) || Number(part) > 65535)) {
        throw new Error(`Invalid Chrome extension version: ${value}`)
    }
    return parts.map(Number)
}

export function compareVersions(a, b) {
    const left = parseVersion(a)
    const right = parseVersion(b)
    for (let index = 0; index < 4; index++) {
        const difference = (left[index] ?? 0) - (right[index] ?? 0)
        if (difference) return Math.sign(difference)
    }
    return 0
}

// The store version is the manifest version as written; a release is cut by raising it in a pull request.
export function stagePackage(root) {
    const source = join(root, extensionDirectory)
    const manifest = JSON.parse(readFileSync(join(source, "manifest.json"), "utf8"))
    parseVersion(manifest.version)
    const destination = join(root, ".release", "extension")
    // Error on an existing stage instead of overwriting files from an earlier run.
    mkdirSync(destination, { recursive: false })
    cpSync(source, destination, { recursive: true })
    if (existsSync(join(root, "LICENSE"))) cpSync(join(root, "LICENSE"), join(destination, "LICENSE"))
    return manifest.version
}

function versions(status) {
    return status?.distributionChannels?.map(channel => channel.crxVersion).filter(Boolean) ?? []
}

export function submissionDecision(status, version) {
    if (status.takenDown || status.warned) throw new Error("Store policy warning or takedown requires attention in the dashboard")
    const published = versions(status.publishedItemRevisionStatus)
    if (published.includes(version)) return "published"
    const submitted = status.submittedItemRevisionStatus
    const pending = submitted?.state === "PENDING_REVIEW"
    if (pending && versions(submitted).includes(version)) return "in_review"
    if (submitted?.state === "STAGED") throw new Error("A staged release requires a dashboard decision before automatic publishing")
    if (submitted?.state === "REJECTED" && versions(submitted).includes(version)) throw new Error("This version was rejected; fix the cause before resubmitting")
    const known = [...published, ...(pending ? versions(submitted) : [])]
    if (known.some(storeVersion => compareVersions(version, storeVersion) <= 0)) return "not_newer"
    if (pending) return "deferred"
    return "upload"
}

export async function publishPackage({ publisherId, itemId, token, version, archive, fetchImpl = fetch, wait = delay }) {
    if (!/^[a-zA-Z0-9-]+$/.test(publisherId ?? "")) throw new Error("CWS_PUBLISHER_ID is required")
    if (!/^[a-p]{32}$/.test(itemId ?? "")) throw new Error("CWS_ITEM_ID must be the existing extension ID")
    if (!token) throw new Error("CWS_ACCESS_TOKEN is required")
    if (!/^\d+(\.\d+){0,3}$/.test(version ?? "")) throw new Error("RELEASE_VERSION is required")
    const name = `publishers/${publisherId}/items/${itemId}`
    const api = `https://chromewebstore.googleapis.com/v2/${name}`
    const request = async (url, options = {}) => {
        const response = await fetchImpl(url, {
            ...options,
            headers: { Authorization: `Bearer ${token}`, ...options.headers },
            signal: AbortSignal.timeout(30000)
        })
        if (!response.ok) {
            // Keep Google's diagnostic fields, never the full body, headers or reflected credential.
            const body = await response.json().catch(() => ({}))
            const error = body?.error
            const fields = [error?.status, error?.message, ...(Array.isArray(error?.details) ? error.details.map(detail => detail?.reason) : [])]
            const detail = fields.filter(field => typeof field === "string").join("; ")
                .replaceAll(token, "[redacted]").replaceAll(encodeURIComponent(token), "[redacted]")
                .replace(/Bearer\s+[^\s;]+/gi, "Bearer [redacted]").replace(/[\r\n]/g, " ").slice(0, 2000)
            throw new Error(`Chrome Web Store ${options.method ?? "GET"} failed: HTTP ${response.status}${detail ? ` (${detail})` : ""}`)
        }
        return response.json()
    }
    let status = await request(`${api}:fetchStatus`)
    const decision = submissionDecision(status, version)
    if (decision !== "upload") return { result: decision, version }
    const uploaded = await request(`https://chromewebstore.googleapis.com/upload/v2/${name}:upload`, {
        method: "POST",
        headers: { "Content-Type": "application/zip" },
        body: archive
    })
    let uploadState = uploaded.uploadState
    for (let attempt = 0; ["IN_PROGRESS", "UPLOAD_IN_PROGRESS"].includes(uploadState) && attempt < 40; attempt++) {
        await wait(2000)
        status = await request(`${api}:fetchStatus`)
        uploadState = status.lastAsyncUploadState
    }
    if (uploadState !== "SUCCEEDED") throw new Error(`Package upload did not succeed: ${uploadState ?? "missing state"}`)
    if (uploaded.crxVersion && uploaded.crxVersion !== version) throw new Error("Uploaded version does not match the package version")
    const published = await request(`${api}:publish`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ publishType: "DEFAULT_PUBLISH", skipReview: false, blockOnWarnings: true })
    })
    if (!["PENDING_REVIEW", "PUBLISHED", "PUBLISHED_TO_TESTERS"].includes(published.state)) {
        throw new Error(`Unexpected submission state: ${published.state ?? "missing state"}`)
    }
    const observed = await request(`${api}:fetchStatus`)
    const confirmed = submissionDecision(observed, version)
    if (!["published", "in_review"].includes(confirmed)) throw new Error("Store read-back did not confirm the submitted version")
    return { result: confirmed, version }
}

export async function verifyAuthentication({ token, serviceAccount, fetchImpl = fetch }) {
    if (!token || !serviceAccount) throw new Error("Google token and service-account email are required")
    const query = new URLSearchParams({ access_token: token })
    const response = await fetchImpl(`https://oauth2.googleapis.com/tokeninfo?${query}`, { signal: AbortSignal.timeout(30000) })
    if (!response.ok) throw new Error(`Google token verification failed: HTTP ${response.status}`)
    const info = await response.json()
    const scope = "https://www.googleapis.com/auth/chromewebstore"
    if (!info.scope?.split(" ").includes(scope)) throw new Error("Google token lacks the Chrome Web Store scope")
    if (!Number.isFinite(Number(info.expires_in)) || Number(info.expires_in) <= 0) throw new Error("Google token is expired")
    if (info.email && info.email !== serviceAccount) throw new Error("Google token belongs to a different service account")
    return { result: "authenticated", serviceAccount, tokenEmail: info.email ?? null, scope }
}

function report(result) {
    console.log(JSON.stringify(result))
    if (process.env.GITHUB_STEP_SUMMARY) {
        appendFileSync(process.env.GITHUB_STEP_SUMMARY, `Chrome Web Store${result.version ? ` version ${result.version}` : " authentication"}: ${result.result}.\n`)
        if (result.result === "deferred") appendFileSync(process.env.GITHUB_STEP_SUMMARY, "Another version is under review. No submission was cancelled; the scheduled run retries latest main.\n")
        if (result.result === "not_newer") appendFileSync(process.env.GITHUB_STEP_SUMMARY, "The store already has this or a later version. Raise the manifest version to publish.\n")
    }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    try {
        if (process.argv[2] === "package") {
            mkdirSync(".release")
            const version = stagePackage(process.cwd())
            if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `version=${version}\n`)
            report({ result: "packaged", version })
        }
        else if (process.argv[2] === "verify-auth") {
            report(await verifyAuthentication({ token: process.env.CWS_ACCESS_TOKEN, serviceAccount: process.env.CWS_SERVICE_ACCOUNT }))
        }
        else if (process.argv[2] === "publish") {
            const version = process.env.RELEASE_VERSION
            report(await publishPackage({
                publisherId: process.env.CWS_PUBLISHER_ID,
                itemId: process.env.CWS_ITEM_ID,
                token: process.env.CWS_ACCESS_TOKEN,
                version,
                archive: readFileSync(join(".release", `Teams Supercopy ${version}.zip`))
            }))
        }
        else throw new Error("Usage: node tools/chrome-web-store.mjs package|verify-auth|publish")
    }
    catch (error) {
        console.error(error.message)
        process.exitCode = 1
    }
}
