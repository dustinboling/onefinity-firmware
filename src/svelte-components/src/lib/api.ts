type HttpMethod = "GET" | "PUT" | "POST" | "DELETE";

// P-01: the server gates the destructive / admin endpoints behind the
// controller's OS password (X-Admin-Password header, loopback exempt).
// From another browser on the LAN those calls come back 401, so on a
// 401 from a gated call we ask the operator for the password once,
// keep it for this browser session only (sessionStorage — never
// localStorage, never a cookie) and retry the call once.  A password
// that still gets a 401 is forgotten again, so a wrong entry surfaces
// as the call's normal error instead of prompting in a loop.  The
// header is attached only to gated calls, so normal machine operation
// (jog, home, run, e-stop) never carries or prompts for it.
const ADMIN_PASSWORD_KEY = "bbctrl-admin-password";
const ADMIN_PATHS = new Set([
    "reboot", "shutdown", "hostname", "network", "remote/username",
    "remote/password", "config/restore", "config/reset",
    "firmware/update", "upgrade", "screen-rotation", "time",
]);

function isAdminCall(method: HttpMethod, url: string) {
    if (method === "GET") return false;
    const path = url.split("?")[0].replace(/^\//, "");
    // FileHandler gates only DELETE; uploads and downloads stay open.
    if (path === "file" || path.startsWith("file/")) return method === "DELETE";
    return ADMIN_PATHS.has(path);
}

function storedAdminPassword() {
    try {
        return sessionStorage.getItem(ADMIN_PASSWORD_KEY) || "";
    } catch {
        return "";
    }
}

function clearAdminPassword() {
    try {
        sessionStorage.removeItem(ADMIN_PASSWORD_KEY);
    } catch {
        /* no storage */
    }
}

function askAdminPassword() {
    const password = window.prompt(
        "This action needs the controller password. Enter it to continue:");
    if (password) {
        try {
            sessionStorage.setItem(ADMIN_PASSWORD_KEY, password);
        } catch {
            /* no storage */
        }
    }
    return password || "";
}

async function doFetch(method: HttpMethod, url: string, data: any, config: RequestInit, retried = false, password = "") {
    try {
        const headers: Record<string, string> = (typeof data === "object")
            ? {
                "Content-Type": "application/json; charset=utf-8"
            }
            : {};

        if (isAdminCall(method, url)) {
            const adminPassword = password || storedAdminPassword();
            if (adminPassword) headers["X-Admin-Password"] = adminPassword;
        }

        const response = await fetch(`/api/${url}`, {
            ...config,
            method,
            cache: "no-cache",
            body: (typeof data === "object")
                ? JSON.stringify(data)
                : undefined,
            headers
        });

        if (response.status === 401 && isAdminCall(method, url)) {
            clearAdminPassword();
            const entered = retried ? "" : askAdminPassword();
            if (entered) {
                return doFetch(method, url, data, config, true, entered);
            }
        }

        // Like the legacy and React helpers: an error status is an error, whatever
        // the body looks like, and an empty body is not a JSON parse failure.
        if (!response.ok) {
            throw new Error(await response.text());
        }

        const text = await response.text();
        return text ? JSON.parse(text) : undefined;
    } catch (error) {
        console.debug(`API Error: ${url}: ${error}`);

        throw error;
    }
}

export function GET(url: string, config: RequestInit = {}) {
    return doFetch("GET", url, undefined, config);
}

export function PUT(url: string, data: any = undefined, config: RequestInit = {}) {
    return doFetch("PUT", url, data, config);
}

export function POST(url: string, data: any = undefined, config: RequestInit = {}) {
    return doFetch("POST", url, data, config);
}

export function DELETE(url: string, config = {}) {
    return doFetch("DELETE", url, undefined, config);
}
