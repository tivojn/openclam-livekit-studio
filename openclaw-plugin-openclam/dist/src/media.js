import { detectMime, extensionForMime, getAgentScopedMediaLocalRootsForSources, } from "openclaw/plugin-sdk/media-runtime";
import { loadOutboundMediaFromUrl, } from "openclaw/plugin-sdk/outbound-media";
import { rewriteMarkdownLinks } from "./markdown.js";
import { truncateUnicode } from "./protocol.js";
export const MAX_ATTACHMENT_BYTES = 32 * 1_024 * 1_024;
export const MAX_ATTACHMENTS_PER_TURN = 8;
export const MAX_ATTACHMENT_BYTES_PER_TURN = 64 * 1_024 * 1_024;
const SUPPORTED_MEDIA_TYPES = new Set([
    "application/json",
    "application/msword",
    "application/pdf",
    "application/rtf",
    "application/vnd.ms-excel",
    "application/vnd.ms-powerpoint",
    "application/vnd.oasis.opendocument.presentation",
    "application/vnd.oasis.opendocument.spreadsheet",
    "application/vnd.oasis.opendocument.text",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/zip",
    "audio/flac",
    "audio/mp4",
    "audio/mpeg",
    "audio/ogg",
    "audio/wav",
    "audio/webm",
    "audio/x-wav",
    "image/gif",
    "image/jpeg",
    "image/png",
    "image/webp",
    "text/csv",
    "text/markdown",
    "text/plain",
    "video/mp4",
    "video/quicktime",
    "video/webm",
]);
const SUPPORTED_LOCAL_LINK_EXTENSIONS = new Set([
    "csv",
    "doc",
    "docx",
    "flac",
    "gif",
    "jpeg",
    "jpg",
    "json",
    "m4a",
    "md",
    "mov",
    "mp3",
    "mp4",
    "odp",
    "ods",
    "odt",
    "ogg",
    "pdf",
    "png",
    "ppt",
    "pptx",
    "rtf",
    "txt",
    "wav",
    "webm",
    "webp",
    "xls",
    "xlsx",
    "zip",
]);
function localLinkSource(rawDestination) {
    const trimmed = rawDestination.trim();
    const source = (trimmed.startsWith("<") && trimmed.endsWith(">")
        ? trimmed.slice(1, -1).trim()
        : trimmed).replace(/\\([()])/gu, "$1");
    if (!source || /\s["']/u.test(source))
        return undefined;
    const local = source.startsWith("file://") ||
        source.startsWith("/") ||
        source.startsWith("~/") ||
        /^[A-Za-z]:[\\/]/u.test(source) ||
        source.startsWith("\\\\");
    if (!local)
        return undefined;
    let pathname = source;
    try {
        if (source.startsWith("file://"))
            pathname = decodeURIComponent(new URL(source).pathname);
    }
    catch {
        return undefined;
    }
    const withoutQuery = pathname.split(/[?#]/u, 1)[0] ?? "";
    const extension = withoutQuery.slice(withoutQuery.lastIndexOf(".") + 1).toLowerCase();
    return SUPPORTED_LOCAL_LINK_EXTENSIONS.has(extension) ? source : undefined;
}
export function promoteLocalAttachmentLinks(text) {
    const sources = [];
    const safeText = rewriteMarkdownLinks(text, ({ label, destination }) => {
        const source = localLinkSource(destination);
        if (!source)
            return undefined;
        sources.push(source);
        return label.trim() || "Attached file";
    });
    return { text: safeText, sources: [...new Set(sources)] };
}
function basename(value) {
    const normalized = value.replace(/\\/gu, "/");
    return normalized.slice(normalized.lastIndexOf("/") + 1);
}
function sourceName(source) {
    try {
        return basename(decodeURIComponent(new URL(source).pathname));
    }
    catch {
        return basename(source);
    }
}
function safeFileName(candidate, source, mediaType) {
    const raw = basename(candidate?.trim() || sourceName(source))
        .replace(/[\u0000-\u001f\u007f]/gu, "")
        .trim();
    const fallbackExtension = extensionForMime(mediaType);
    const fallback = `attachment${fallbackExtension ? `.${fallbackExtension}` : ""}`;
    const safe = raw && raw !== "." && raw !== ".." ? raw : fallback;
    return truncateUnicode(safe, 160);
}
export async function loadOpenClamMedia(params) {
    const mediaLocalRoots = params.mediaLocalRoots ?? (params.mediaAccess === undefined
        ? getAgentScopedMediaLocalRootsForSources({
            cfg: params.cfg,
            agentId: params.agentId,
            mediaSources: [params.source],
        })
        : undefined);
    const loaded = await loadOutboundMediaFromUrl(params.source, {
        maxBytes: MAX_ATTACHMENT_BYTES,
        ...(params.mediaAccess === undefined ? {} : { mediaAccess: params.mediaAccess }),
        ...(mediaLocalRoots === undefined ? {} : { mediaLocalRoots }),
        ...(params.mediaReadFile === undefined ? {} : { mediaReadFile: params.mediaReadFile }),
    });
    if (loaded.buffer.byteLength < 1 || loaded.buffer.byteLength > MAX_ATTACHMENT_BYTES) {
        throw new Error("attachment_size_invalid");
    }
    const mediaType = await detectMime({
        buffer: loaded.buffer,
        headerMime: loaded.contentType,
        filePath: loaded.fileName ?? params.source,
    });
    if (mediaType === undefined || !SUPPORTED_MEDIA_TYPES.has(mediaType)) {
        throw new Error("attachment_type_unsupported");
    }
    return {
        buffer: loaded.buffer,
        fileName: safeFileName(loaded.fileName, params.source, mediaType),
        mediaType,
    };
}
export function uniqueMediaSources(mediaUrl, mediaUrls) {
    const values = [mediaUrl, ...(mediaUrls ?? [])]
        .filter((value) => typeof value === "string" && value.trim().length > 0)
        .map((value) => value.trim());
    return [...new Set(values)];
}
