import { rewriteMarkdownLinks } from "./markdown.js";
const LOCAL_PATH_WITH_EXTENSION_PATTERN = /(^|[^A-Za-z0-9_./~-])((?:file:\/\/|~\/|[A-Za-z]:[\\/]|\\\\[^\s\\]+\\[^\s\\]+|\/(?!\/))[^\r\n)\]}>]*?\.[A-Za-z0-9]{1,16})(?=$|[\s)\]}>.,;:!?])/gu;
function markdownDestinationSource(rawDestination) {
    const trimmed = rawDestination.trim();
    if (trimmed.startsWith("<")) {
        const end = trimmed.indexOf(">");
        if (end > 0)
            return trimmed.slice(1, end).trim().replace(/\\([()])/gu, "$1");
    }
    return trimmed.replace(/\\([()])/gu, "$1");
}
function isLocalSource(source) {
    return source.startsWith("file://") ||
        source.startsWith("/") ||
        source.startsWith("~/") ||
        /^[A-Za-z]:[\\/]/u.test(source) ||
        source.startsWith("\\\\");
}
function redactLocalMarkdownLinks(text) {
    return rewriteMarkdownLinks(text, ({ label, destination }) => (isLocalSource(markdownDestinationSource(destination))
        ? label.trim() || "attached file"
        : undefined));
}
export function replaceExactMediaReferences(text, replacements) {
    let safe = text;
    for (const [source, replacement] of replacements) {
        if (source)
            safe = safe.split(source).join(replacement);
    }
    return safe;
}
export function containsPrivatePathReference(text) {
    return redactPrivatePathReferences(text) !== text;
}
export function redactPrivatePathReferences(text) {
    return redactLocalMarkdownLinks(text)
        .replace(LOCAL_PATH_WITH_EXTENSION_PATTERN, (_match, prefix) => `${prefix}attached file`)
        .replace(/file:\/\/[^\s)\]}>]+/gu, "attached file")
        .replace(/(^|[^A-Za-z0-9_.~-])~\/[^\s)\]}>]+/gu, (_match, prefix) => `${prefix}attached file`)
        .replace(/(^|[^A-Za-z0-9_])[A-Za-z]:[\\/][^\s)\]}>]+/gu, (_match, prefix) => `${prefix}attached file`)
        .replace(/\\\\[^\s\\]+\\[^\s)\]}>]+/gu, "attached file")
        .replace(/(^|[^A-Za-z0-9_./-])\/(?!\/)[^\s)\]}>]+/gu, (_match, prefix) => `${prefix}attached file`);
}
export function rememberMediaReplacement(replacements, source, replacement) {
    replacements.set(source, replacement);
    try {
        const parsed = new URL(source);
        if (parsed.protocol === "file:") {
            replacements.set(decodeURIComponent(parsed.pathname), replacement);
        }
    }
    catch {
        // Non-URL local media references are already stored exactly above.
    }
}
