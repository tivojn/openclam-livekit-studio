#!/usr/bin/env python3
"""Classify one local pre-submission diagnostic, never authorize a release.

macOS 26 can report only a generic main-executable Notary Error before a
Developer ID app has its first ticket.  This classifier accepts that *unresolved*
preflight condition only with independent signature and Gatekeeper evidence.
It is not used after submission, for distribution, or by the installer.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys


MAX_REPORT_BYTES = 16 * 1024 * 1024
MAX_IDENTITY_BYTES = 256 * 1024
MAX_SPCTL_BYTES = 64 * 1024
GENERIC_NOTARY_ERROR = (
    "Gatekeeper rejected this file. If there isn't a more descriptive error "
    "elsewhere in this output, please file a Feedback through Feedback "
    "Assistant.app so we can continue to improve syspolicy_check. Please "
    "include the app bundle you are checking and a sysdiagnose taken "
    "immediately after running syspolicy_check."
)
DOCUMENTATION_URL = "https://developer.apple.com/forums/thread/706442"
FAILURE_MARKER = "App has failed one or more pre-notarization checks."
FIELD_NAMES = (
    "File", "Severity", "Full Error", "Type", "Suggested Fix",
    "Documentation", "NSError.userInfo",
)


class PreflightRejected(ValueError):
    """A local assessment is not the narrowly identified bootstrap case."""


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise PreflightRejected(reason)


def normalized(value: str) -> str:
    return " ".join(value.split())


def read_report(path: pathlib.Path, limit: int) -> str:
    require(path.is_file() and not path.is_symlink(), "missing or symlinked report")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(0 < len(data) <= limit, "empty or oversized report")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise PreflightRejected("report is not UTF-8") from exc
    require("\0" not in text, "report contains NUL")
    return text


def parse_findings(report: str) -> list[dict[str, str]]:
    """Parse the actual structured trailer, not severity words in progress text."""
    require(report.count(FAILURE_MARKER) == 1, "missing or repeated failure trailer")
    require(len(re.findall(r"^Passed amfi_preflight\s*$", report, re.M)) == 1,
            "AMFI preflight did not pass exactly once")
    require(not re.search(r"^(?:Failed|Failing|Error).*amfi_preflight", report, re.M),
            "AMFI preflight reported failure")
    progress, trailer = report.split(FAILURE_MARKER, 1)
    # The observed verbose progress contains only checks/paths and their pass
    # messages. Any independent diagnostic there is outside the single known
    # structured finding, even if the tool omitted its Severity field.
    require(not re.search(r"\b(?:error|warning|fatal|failed|failing)\b", progress, re.I),
            "unparsed diagnostic before structured findings")
    trailer = trailer.strip()
    parts = re.split(r"(?m)^-{10,}\s*$", trailer)
    require(len(parts) >= 3 and not parts[0].strip() and not parts[-1].strip(),
            "malformed structured finding delimiters")
    findings: list[dict[str, str]] = []
    for part in parts[1:-1]:
        lines = part.strip().splitlines()
        require(bool(lines), "empty structured finding")
        title = lines[0]
        require(title == title.strip() and bool(title), "malformed finding title")
        fields: dict[str, str] = {"title": title}
        order: list[str] = []
        current = ""
        for line in lines[1:]:
            match = re.fullmatch(r" {4}([A-Za-z.]+(?: [A-Za-z.]+)*):(?: (.*))?", line)
            if match:
                name, value = match.group(1), match.group(2) or ""
                require(name in FIELD_NAMES and name not in fields,
                        "unknown or repeated structured field")
                fields[name] = value
                order.append(name)
                current = name
            else:
                require(bool(current) and line.startswith("        ") and bool(line.strip()),
                        "malformed structured field continuation")
                fields[current] += " " + line.strip()
        require(tuple(order) == FIELD_NAMES, "missing or reordered structured fields")
        for name in FIELD_NAMES:
            fields[name] = normalized(fields[name])
        require(all(fields[name] for name in ("File", "Severity", "Full Error", "Type")),
                "empty required structured field")
        findings.append(fields)
    require(bool(findings), "no structured findings")
    require(len(re.findall(r"^\s*Severity:", report, re.M)) == len(findings),
            "extra severity outside parsed findings")
    return findings


def parse_ns_error(value: str) -> dict[str, str]:
    """NSError's printed dictionary is not JSON; validate its exact seven fields."""
    require(value.startswith("[") and value.endswith("]"), "malformed NSError dictionary")
    body = value[1:-1]
    matches = list(re.finditer(r'"([A-Za-z]+)":\s*', body))
    require(bool(matches) and not body[:matches[0].start()].strip(),
            "malformed NSError keys")
    values: dict[str, str] = {}
    for index, match in enumerate(matches):
        name = match.group(1)
        require(name not in values, "repeated NSError key")
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        item = body[match.end():end].strip()
        if index + 1 < len(matches):
            require(item.endswith(","), "malformed NSError separator")
            item = item[:-1].strip()
        values[name] = normalized(item)
    return values


def verified_identity(
    details: str, *, app_path: str, executable: str, app_id: str,
    identity: str, team_id: str, signature_exit: int, metadata_exit: int,
) -> str:
    require(signature_exit == 0 and metadata_exit == 0,
            "deep/strict signature verification or identity inspection failed")
    rows = details.splitlines()

    def field(name: str) -> str:
        values = [row[len(name) + 1:] for row in rows if row.startswith(name + "=")]
        require(len(values) == 1 and bool(values[0]), "missing or repeated signing identity field")
        return values[0]

    require(field("Executable") == f"{app_path}/Contents/MacOS/{executable}",
            "signature describes a different executable")
    require(field("Identifier") == app_id and field("TeamIdentifier") == team_id,
            "wrong bundle identifier or signing team")
    authorities = [row.removeprefix("Authority=") for row in rows if row.startswith("Authority=")]
    require(authorities == [identity, "Developer ID Certification Authority", "Apple Root CA"],
            "wrong Developer ID certificate chain")
    timestamp = field("Timestamp").strip()
    require(bool(timestamp) and timestamp.lower() != "none", "secure signing timestamp missing")
    directories = [row for row in rows if row.startswith("CodeDirectory ")]
    require(len(directories) == 1, "missing or repeated CodeDirectory")
    flags = re.search(r"\bflags=0x([0-9a-fA-F]+)\(([^)]*)\)", directories[0])
    require(flags is not None and int(flags.group(1), 16) & 0x10000 != 0
            and "runtime" in flags.group(2).split(","), "hardened runtime missing")
    digest = field("CDHash")
    require(re.fullmatch(r"[0-9a-f]{40}", digest) is not None, "invalid main-executable CDHash")
    require(not any(row.startswith("Signature=adhoc") for row in rows), "ad-hoc signature")
    return digest


def classify(
    report: str, details: str, spctl: str, *, mode: str, assessment_exit: int,
    app_path: str, executable: str, app_id: str, identity: str, team_id: str,
    signature_exit: int, metadata_exit: int, spctl_exit: int,
) -> dict[str, object]:
    require(mode == "notary-submission", "exception is pre-submission only")
    require(assessment_exit == 70, "unexpected assessment exit status")
    require(pathlib.PurePosixPath(app_path).is_absolute() and app_path.endswith(".app")
            and "\n" not in app_path and "\r" not in app_path,
            "invalid application path")
    require(bool(executable) and executable not in (".", "..") and "/" not in executable
            and "\n" not in executable and "\r" not in executable,
            "invalid executable name")
    findings = parse_findings(report)
    digest = verified_identity(
        details, app_path=app_path, executable=executable, app_id=app_id,
        identity=identity, team_id=team_id, signature_exit=signature_exit,
        metadata_exit=metadata_exit,
    )
    # Preserve the existing preflight-only all-warning policy, but never accept
    # a mixture of this fatal and a warning (or an unparsed extra diagnostic).
    warning_only = all(item["Severity"] == "Warning" for item in findings)
    if warning_only:
        disposition = "warning_only_pre_submission"
    else:
        require(len(findings) == 1, "more than the single allowed finding")
        finding = findings[0]
        expected_file = f"{pathlib.PurePosixPath(app_path).name}/Contents/MacOS/{executable}"
        require(finding["title"] == "Codesign Error" and finding["Severity"] == "Fatal"
                and finding["Type"] == "Notary Error", "unrecognized fatal diagnostic")
        require(finding["File"] == expected_file, "finding is not for the main executable")
        require(finding["Full Error"] == GENERIC_NOTARY_ERROR,
                "not the exact generic pre-submission diagnostic")
        require(finding["Suggested Fix"] == "" and finding["Documentation"] == DOCUMENTATION_URL,
                "unexpected advice or diagnostic documentation")
        require(parse_ns_error(finding["NSError.userInfo"]) == {
            "SyspolicyCheckErrorLevel": "Fatal",
            "SyspolicyCheckShortError": "Codesign Error",
            "SyspolicyCheckAdvice": "",
            "SyspolicyCheckAdditionalInformation": "",
            "SyspolicyCheckErrorFile": f"{app_path}/Contents/MacOS/{executable}",
            "SyspolicyCheckDocumentationLink": DOCUMENTATION_URL,
            "SyspolicyCheckLongError": GENERIC_NOTARY_ERROR,
        }, "NSError fields do not match the exact diagnostic")
        require(spctl_exit == 3 and spctl.splitlines() == [
            f"{app_path}: rejected", "source=Unnotarized Developer ID",
        ], "Gatekeeper rejection is not solely Unnotarized Developer ID")
        disposition = "unresolved_pre_submission_notary_error"
    return {
        "disposition": disposition,
        "assessment_exit": assessment_exit,
        "finding_count": len(findings),
        "amfi_preflight_passed": True,
        "deep_strict_signature_verified": True,
        "main_executable_cdhash": digest,
        "notarization_accepted": False,
        "gatekeeper_accepted": False,
        "required_next_gates": [
            "Apple Accepted", "staple and validate", "deep/strict codesign",
            "Gatekeeper accepted", "notary-submission exit 0", "distribution exit 0",
            "signed/notarized/stapled DMG", "mounted-app verification",
        ],
        "report_sha256": hashlib.sha256(report.encode("utf-8")).hexdigest(),
        "identity_sha256": hashlib.sha256(details.encode("utf-8")).hexdigest(),
        "spctl_sha256": hashlib.sha256(spctl.encode("utf-8")).hexdigest(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("report", "identity-report", "spctl-report"):
        parser.add_argument(f"--{flag}", type=pathlib.Path, required=True)
    for flag in ("assessment-exit", "signature-exit", "metadata-exit", "spctl-exit"):
        parser.add_argument(f"--{flag}", type=int, required=True)
    for flag in ("mode", "app-path", "executable", "app-id", "identity", "team-id"):
        parser.add_argument(f"--{flag}", required=True)
    args = parser.parse_args()
    try:
        result = classify(
            read_report(args.report, MAX_REPORT_BYTES),
            read_report(args.identity_report, MAX_IDENTITY_BYTES),
            read_report(args.spctl_report, MAX_SPCTL_BYTES),
            mode=args.mode, assessment_exit=args.assessment_exit, app_path=args.app_path,
            executable=args.executable, app_id=args.app_id, identity=args.identity,
            team_id=args.team_id, signature_exit=args.signature_exit,
            metadata_exit=args.metadata_exit, spctl_exit=args.spctl_exit,
        )
    except (OSError, ValueError) as exc:
        # Error messages are classifier reasons, not copies of tool output or
        # any environment/authentication information.
        reason = str(exc) if isinstance(exc, PreflightRejected) else "cannot read diagnostic reports"
        print(json.dumps({"disposition": "reject", "reason": reason}, sort_keys=True))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
