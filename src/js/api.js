"use strict";

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

function isAdminCall(method, url) {
    if (method === "GET") return false;
    const path = url.split("?")[0].replace(/^\//, "");
    // FileHandler gates only DELETE; uploads and downloads stay open.
    if (path === "file" || path.startsWith("file/")) return method === "DELETE";
    return ADMIN_PATHS.has(path);
}

function storedAdminPassword() {
    try {
        return sessionStorage.getItem(ADMIN_PASSWORD_KEY) || "";
    } catch (error) {
        return "";
    }
}

function clearAdminPassword() {
    try {
        sessionStorage.removeItem(ADMIN_PASSWORD_KEY);
    } catch (error) {
        // No storage available; nothing to clear.
    }
}

function askAdminPassword() {
    const password = window.prompt(
        "This action needs the controller password. Enter it to continue:");
    if (password) {
        try {
            sessionStorage.setItem(ADMIN_PASSWORD_KEY, password);
        } catch (error) {
            // No storage available; the retry still carries it once.
        }
    }
    return password || "";
}

// Raw fetch against /api/ with the P-01 prompt-and-retry behaviour.
// Returns the Response itself for callers that handle it their own way.
async function callApiRaw(url, options = {}, retried = false, password = "") {
    const method = (options.method || "GET").toUpperCase();
    const headers = Object.assign({}, options.headers);

    if (isAdminCall(method, url)) {
        const adminPassword = password || storedAdminPassword();
        if (adminPassword) headers["X-Admin-Password"] = adminPassword;
    }

    const response = await fetch(`/api/${url}`, Object.assign({}, options, {
        method,
        headers,
    }));

    if (response.status === 401 && isAdminCall(method, url)) {
        clearAdminPassword();
        const entered = retried ? "" : askAdminPassword();
        if (entered) {
            return callApiRaw(url, options, true, entered);
        }
    }

    return response;
}

async function callApi(method, url, data) {
    try {
        const headers = {};
        let body = undefined;

        if (data) {
            if (data instanceof FormData) {
                body = data;
            } else {
                headers["Content-Type"] = "application/json; charset=utf-8";
                body = JSON.stringify(data);
            }
        }

        const response = await callApiRaw(url, {
            method,
            headers,
            body,
            cache: "no-cache",
        });

        if (response.ok) {
            return await response.json();
        }

        throw new Error(await response.text());
    } catch (error) {
        console.debug(`API Error: ${url}: ${error}`);

        throw error;
    }
}

module.exports = {
    get: function(url) {
        return callApi("GET", url);
    },

    put: function(url, body = undefined) {
        return callApi("PUT", url, body);
    },

    delete: function(url) {
        return callApi("DELETE", url);
    },

    fetch: function(url, options = {}) {
        return callApiRaw(url, options);
    }
};
