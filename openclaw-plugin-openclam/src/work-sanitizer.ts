import { createHash } from "node:crypto";
import { truncateUnicode } from "./protocol.js";
import type { WorkStep } from "./types.js";

const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/gu;
const PRIVATE_PATH = /(?:file:\/\/[^\s)\]}>]+|(?:^|\s)[A-Za-z]:[\\/][^\s)\]}>]+|\\\\[^\s\\]+\\[^\s)\]}>]+|(?:^|\s)\/(?!\/)[^\s)\]}>]+)/giu;
const SECRET_ASSIGNMENT = /\b(authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie)\s*[:=]\s*([^\s,;]+)/giu;
const BEARER = /\bbearer\s+[A-Za-z0-9._~+\/-]+=*/giu;
const TOKENISH = /\b(?:sk|xai|ghp|github_pat|eyJ)[-_A-Za-z0-9.]{20,}\b/gu;
const RELATIVE_PATH = /^(?!\/)(?![A-Za-z]:[\\/])(?!\\\\)(?!file:)(?!.*(?:^|\/)\.\.(?:\/|$))[^\u0000-\u001f\u007f]+$/u;

function compact(value: unknown): string {
  if (typeof value !== "string") return "";
  return value.replace(CONTROL, " ").replace(/\s+/gu, " ").trim();
}

export function sanitizeWorkText(value: unknown, maximum: number): string | undefined {
  let safe = compact(value);
  if (!safe) return undefined;
  safe = safe
    .replace(PRIVATE_PATH, (match) => `${match.startsWith(" ") ? " " : ""}[private path]`)
    .replace(SECRET_ASSIGNMENT, (_match, label: string) => `${label}=[REDACTED]`)
    .replace(BEARER, "Bearer [REDACTED]")
    .replace(TOKENISH, "[REDACTED]");
  safe = truncateUnicode(safe, maximum).trim();
  return safe || undefined;
}

export function sanitizeWorkPath(value: unknown): string | undefined {
  const candidate = compact(value).replaceAll("\\", "/");
  if (!candidate || candidate.length > 512 || !RELATIVE_PATH.test(candidate)) return undefined;
  return truncateUnicode(candidate, 512);
}

export function workStepId(...parts: unknown[]): string {
  const readable = parts
    .map(compact)
    .filter(Boolean)
    .join("-")
    .toLowerCase()
    .replace(/[^a-z0-9._:-]+/gu, "-")
    .replace(/^[^a-z0-9]+|[^a-z0-9]+$/gu, "")
    .slice(0, 48);
  if (readable) return readable;
  return `step-${createHash("sha256").update(JSON.stringify(parts)).digest("hex").slice(0, 12)}`;
}

export function sanitizeWorkStep(step: WorkStep): WorkStep | undefined {
  const title = sanitizeWorkText(step.title, 120);
  if (!title) return undefined;
  const detail = sanitizeWorkText(step.detail, 1_000);
  const tool = sanitizeWorkText(step.tool, 80);
  // Work is a user-facing progress projection, never a diagnostic/log stream.
  // Keep the protocol's legacy fields decodable, but do not forward raw command
  // text, host paths, or tool output even when their contents look harmless.
  return {
    stepId: workStepId(step.stepId),
    category: step.category,
    state: step.state,
    title,
    ...(detail ? { detail } : {}),
    ...(tool ? { tool } : {}),
  };
}

export function workState(value: unknown, phase?: unknown): WorkStep["state"] {
  const normalized = `${compact(value)} ${compact(phase)}`.toLowerCase();
  if (/(fail|error|denied|reject)/u.test(normalized)) return "failed";
  if (/(wait|approval|pending)/u.test(normalized)) return "waiting";
  if (/(complete|completed|done|success|finished|end)/u.test(normalized)) return "completed";
  return "running";
}
