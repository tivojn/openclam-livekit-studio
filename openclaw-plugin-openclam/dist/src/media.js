import { detectMime, extensionForMime, getAgentScopedMediaLocalRootsForSources, } from "openclaw/plugin-sdk/media-runtime";
import { loadOutboundMediaFromUrl } from "openclaw/plugin-sdk/outbound-media";
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
    const mediaLocalRoots = getAgentScopedMediaLocalRootsForSources({
        cfg: params.cfg,
        agentId: params.agentId,
        mediaSources: [params.source],
    });
    const loaded = await loadOutboundMediaFromUrl(params.source, {
        maxBytes: MAX_ATTACHMENT_BYTES,
        mediaLocalRoots,
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
