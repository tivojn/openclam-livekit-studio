"""Provider-free classification and shell-flow tests; never sign or submit an app."""

import importlib.util
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CLASSIFIER = ROOT / "scripts/classify-notary-preflight.py"
SPEC = importlib.util.spec_from_file_location("notary_preflight", CLASSIFIER)
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)
APP = "/private/tmp/release-test/OpenClam Studio.app"
EXECUTABLE = "OpenClam Studio"
IDENTITY = "Developer ID Application: THE GREAT LIONHEART PTE. LTD. (X7R8N6MMSU)"
TEAM = "X7R8N6MMSU"
APP_ID = "com.lionheart.openclam.macos"
DIVIDER = "-" * 63


def identity_report(app=APP):
    return f"""Executable={app}/Contents/MacOS/{EXECUTABLE}
Identifier={APP_ID}
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=456 flags=0x10000(runtime) hashes=3+7 location=embedded
CDHash=567c00e6e275c26a40109983114bc2da934cb0e5
Signature size=9009
Authority={IDENTITY}
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Aug 31, 2026 at 7:36:23 PM
TeamIdentifier={TEAM}
Runtime Version=26.4.0
Sealed Resources version=2 rules=13 files=6951
"""


def finding(app=APP, *, severity="Fatal", reverse_dictionary=False):
    dictionary = {
        "SyspolicyCheckErrorLevel": severity,
        "SyspolicyCheckShortError": "Codesign Error",
        "SyspolicyCheckAdvice": "",
        "SyspolicyCheckAdditionalInformation": "",
        "SyspolicyCheckErrorFile": f"{app}/Contents/MacOS/{EXECUTABLE}",
        "SyspolicyCheckDocumentationLink": preflight.DOCUMENTATION_URL,
        "SyspolicyCheckLongError": preflight.GENERIC_NOTARY_ERROR,
    }
    items = list(dictionary.items())
    if reverse_dictionary:
        items.reverse()
    ns_error = "[" + ", ".join(f'"{key}": {value}' for key, value in items) + "]"
    fields = {
        "File": f"OpenClam Studio.app/Contents/MacOS/{EXECUTABLE}",
        "Severity": severity,
        "Full Error": preflight.GENERIC_NOTARY_ERROR,
        "Type": "Notary Error",
        "Suggested Fix": "",
        "Documentation": preflight.DOCUMENTATION_URL,
        "NSError.userInfo": ns_error,
    }
    lines = ["Codesign Error"]
    for key, value in fields.items():
        if value:
            lines.append(textwrap.fill(value, width=78, initial_indent=f"    {key}: ",
                                       subsequent_indent="        ", break_long_words=False,
                                       break_on_hyphens=False))
        else:
            lines.append(f"    {key}:")
    return "\n".join(lines)


def report(app=APP, **kwargs):
    return "\n".join([
        "Checking validity", "Starting amfi_preflight", "Passed amfi_preflight",
        preflight.FAILURE_MARKER, DIVIDER, finding(app, **kwargs), DIVIDER, "",
    ])


def options(app=APP):
    return dict(
        report=report(app), details=identity_report(app),
        spctl=f"{app}: rejected\nsource=Unnotarized Developer ID\n",
        mode="notary-submission", assessment_exit=70, app_path=app,
        executable=EXECUTABLE, app_id=APP_ID, identity=IDENTITY, team_id=TEAM,
        signature_exit=0, metadata_exit=0, spctl_exit=3,
    )


class NotaryPreflightClassifierTests(unittest.TestCase):
    def assert_rejected(self, **changes):
        args = options()
        args.update(changes)
        with self.assertRaises(preflight.PreflightRejected):
            preflight.classify(**args)

    def test_exact_bootstrap_is_unresolved_not_a_release_or_gatekeeper_pass(self):
        result = preflight.classify(**options())
        self.assertEqual(result["disposition"], "unresolved_pre_submission_notary_error")
        self.assertIs(result["notarization_accepted"], False)
        self.assertIs(result["gatekeeper_accepted"], False)
        self.assertEqual(result["finding_count"], 1)
        self.assertIn("Apple Accepted", result["required_next_gates"])
        self.assertIn("distribution exit 0", result["required_next_gates"])

    def test_ns_dictionary_order_and_wrapped_real_fields_are_not_semantic_changes(self):
        args = options()
        args["report"] = report(reverse_dictionary=True)
        self.assertEqual(preflight.classify(**args)["finding_count"], 1)

    def test_only_pre_submission_mode_and_observed_exit_status(self):
        for mode in ("distribution", "execute", "", "notary-submission "):
            with self.subTest(mode=mode):
                self.assert_rejected(mode=mode)
        for status in (0, 1, 3, 69, 71, -1):
            with self.subTest(status=status):
                self.assert_rejected(assessment_exit=status)

    def test_warning_only_preflight_retained_but_never_mixed_with_fatal(self):
        args = options()
        args["report"] = report(severity="Warning")
        self.assertEqual(preflight.classify(**args)["disposition"], "warning_only_pre_submission")
        for extra in (finding(), finding(severity="Warning"), finding(severity="Error")):
            self.assert_rejected(report=report() + extra + "\n" + DIVIDER + "\n")

    def test_every_independent_signature_or_gatekeeper_failure_blocks(self):
        for key in ("signature_exit", "metadata_exit"):
            for status in (1, 70, -1):
                with self.subTest(key=key, status=status):
                    self.assert_rejected(**{key: status})
        for status in (0, 1, 2, 70):
            self.assert_rejected(spctl_exit=status)
        for text in (
            "", f"{APP}: accepted\nsource=Notarized Developer ID\n",
            f"{APP}: rejected\nsource=no usable signature\n",
            f"{APP}: rejected\nsource=Unnotarized Developer ID\nmalware found\n",
            f"{APP}/wrong.app: rejected\nsource=Unnotarized Developer ID\n",
        ):
            self.assert_rejected(spctl=text)

    def test_pinned_identity_runtime_timestamp_and_main_executable_required(self):
        details = identity_report()
        mutations = [
            details.replace(IDENTITY, "Developer ID Application: Someone Else (OTHERTEAM)"),
            details.replace(f"TeamIdentifier={TEAM}", "TeamIdentifier=OTHERTEAM"),
            details.replace(f"Identifier={APP_ID}", "Identifier=com.example.other"),
            details.replace("flags=0x10000(runtime)", "flags=0x0(none)"),
            details.replace("flags=0x10000(runtime)", "flags=0x0(runtime)"),
            details.replace("Timestamp=Aug 31, 2026 at 7:36:23 PM", "Timestamp=none"),
            details.replace("Timestamp=Aug 31, 2026 at 7:36:23 PM", "Timestamp=  "),
            details.replace("Executable=" + APP, "Executable=/wrong/app"),
            details.replace("CDHash=567c00e6e275c26a40109983114bc2da934cb0e5", "CDHash=bad"),
            details + f"TeamIdentifier={TEAM}\n",
            details + "Signature=adhoc\n",
            details.replace("Authority=Apple Root CA\n", ""),
        ]
        for value in mutations:
            with self.subTest(value=value[-100:]):
                self.assert_rejected(details=value)

    def test_missing_malformed_extra_and_specific_errors_cannot_match(self):
        original = report()
        mutations = [
            "", "a tool crashed", original.replace("Passed amfi_preflight", "Failed amfi_preflight"),
            original.replace("Passed amfi_preflight", ""),
            "A code signature error occurred in a nested framework.\n" + original,
            "Warning: an independent check could not finish.\n" + original,
            original + "Severity: Fatal\n", original + "another unstructured failure\n",
            original.replace("    Type: Notary Error", "    Type: Signature Error"),
            original.replace("    Severity: Fatal", "    Severity: Error"),
            original.replace("Codesign Error\n", "AMFI Error\n", 1),
            original.replace("    Suggested Fix:", "    Suggested Fix: Re-sign the app"),
            original.replace("        sysdiagnose", "        different sysdiagnose"),
            original.replace("    Type: Notary Error\n", ""),
            original.replace("    Type: Notary Error", "    Type: Notary Error\n    Type: Notary Error"),
            original.replace("    Type: Notary Error", "    Unknown: Notary Error"),
            original.replace(DIVIDER, "---", 1),
            original.replace(preflight.DOCUMENTATION_URL, "https://example.com"),
            original.replace('"SyspolicyCheckAdditionalInformation": ,',
                             '"SyspolicyCheckAdditionalInformation": revoked certificate,'),
            original.replace("OpenClam Studio.app/Contents/MacOS/OpenClam Studio",
                             "OpenClam Studio.app/Contents/Frameworks/Python"),
        ]
        for value in mutations:
            with self.subTest(value=value[:160]):
                self.assert_rejected(report=value)

    def test_report_reader_is_bounded_strict_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory(prefix="openclam-classifier-test-") as temp:
            file = pathlib.Path(temp) / "report"
            for content in (b"", b"12345", b"\xff", b"a\0b"):
                file.write_bytes(content)
                with self.assertRaises(preflight.PreflightRejected):
                    preflight.read_report(file, 4)
            file.write_text("okay", encoding="utf-8")
            self.assertEqual(preflight.read_report(file, 4), "okay")
            link = pathlib.Path(temp) / "link"
            link.symlink_to(file)
            with self.assertRaises(preflight.PreflightRejected):
                preflight.read_report(link, 4)


def shell_function(name):
    source = (ROOT / "scripts/release-macos.sh").read_text(encoding="utf-8")
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}\n", source, re.S | re.M)
    if match is None:
        raise AssertionError(f"Missing shell function {name}")
    return match.group(0)


class ReleasePreflightShellTests(unittest.TestCase):
    def assess(self, *, policy="strict", mode="notary-submission", status=70,
               content=None, notarized=0, signature_fails=0, label="app-notary-submission"):
        with tempfile.TemporaryDirectory(prefix="openclam-preflight-shell-") as temp:
            work = pathlib.Path(temp)
            app = str(work / "OpenClam Studio.app")
            (work / "fixture.txt").write_text(content or report(app), encoding="utf-8")
            (work / f"codesign-{label}-bootstrap-evidence.txt").write_text(
                identity_report(app), encoding="utf-8")
            body = shell_function("verify_syspolicy")
            body = body.replace("/usr/bin/syspolicy_check", "fake_assessment")
            body = body.replace("/usr/sbin/spctl", "fake_spctl")
            body = body.replace("/usr/bin/plutil", "fake_plutil")
            values = {
                "WORK_DIR": temp, "APP_PATH": app, "APP_NOTARIZED": str(notarized),
                "APP_STAPLED": "0", "AUDIT_PYTHON": sys.executable,
                "PREFLIGHT_CLASSIFIER": str(CLASSIFIER), "PRODUCT_NAME": EXECUTABLE,
                "APP_ID": APP_ID, "SIGN_IDENTITY": IDENTITY, "TEAM_ID": TEAM,
                "FAKE_STATUS": str(status), "FAKE_SIGNATURE_FAILS": str(signature_fails),
            }
            setup = "\n".join(f"{key}={shlex.quote(value)}" for key, value in values.items())
            script = setup + r'''
set -Eeuo pipefail
fail() { printf '%s\n' "$*" >&2; exit 1; }
fake_assessment() { "$AUDIT_PYTHON" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text(),end="")' "$WORK_DIR/fixture.txt"; return "$FAKE_STATUS"; }
verify_signature_identity() { echo signature >> "$WORK_DIR/calls"; [[ "$FAKE_SIGNATURE_FAILS" -eq 0 ]] || fail 'signature rejected'; }
fake_spctl() { echo spctl >> "$WORK_DIR/calls"; printf '%s: rejected\nsource=Unnotarized Developer ID\n' "$APP_PATH"; return 3; }
fake_plutil() { "$AUDIT_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["disposition"])' "${!#}"; }
preserve_release_diagnostics() { echo preserved >> "$WORK_DIR/calls"; }
''' + body
            script += "\nverify_syspolicy " + " ".join(map(shlex.quote, [mode, app, label, policy]))
            result = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True)
            calls = (work / "calls").read_text() if (work / "calls").exists() else ""
            receipt_path = work / f"preflight-{label}.json"
            receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
            return result, calls, receipt

    def test_only_explicit_initial_preflight_can_permit_submission(self):
        result, calls, receipt = self.assess(policy="initial-preflight")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "signature\nspctl\npreserved\n")
        self.assertEqual(receipt["disposition"], "unresolved_pre_submission_notary_error")
        self.assertIn("NOT a passed release gate", result.stdout)

    def test_post_staple_fatal_or_warning_stops_before_classifier(self):
        for mode in ("notary-submission", "distribution"):
            for content in (None, report(severity="Warning")):
                result, calls, receipt = self.assess(mode=mode, content=content)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, "")
                self.assertIsNone(receipt)

    def test_initial_policy_cannot_be_reused_after_apple_acceptance_or_for_distribution(self):
        for changes in ({"notarized": 1}, {"mode": "distribution"}, {"label": "mounted-app"},
                        {"policy": "ignore-fatal"}):
            args = {"policy": "initial-preflight"}
            args.update(changes)
            result, calls, _ = self.assess(**args)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, "")

    def test_strict_zero_and_initial_signature_failure(self):
        result, calls, _ = self.assess(status=0, content="App passed all checks.\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "")
        result, calls, receipt = self.assess(policy="initial-preflight", signature_fails=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "signature\n")
        self.assertIsNone(receipt)

    def test_cleanup_preserves_only_public_diagnostics_in_private_external_directory(self):
        with tempfile.TemporaryDirectory(prefix="openclam-diagnostic-copy-test-") as temp:
            root = pathlib.Path(temp)
            work = root / "release-work"
            work.mkdir()
            (work / "syspolicy-test.txt").write_text("failure evidence")
            (work / "codesign-test.txt").write_text("public signature metadata")
            (work / "notary-app.json").write_text('{"status":"Invalid"}')
            (work / "notary-profile.json").write_text("private profile history must not copy")
            (work / "artifact.zip").write_text("do not copy artifacts")
            (work / "codesign-link.txt").symlink_to(work / "notary-profile.json")
            script = "\n".join([
                "set -Eeuo pipefail", "umask 077", f"TMPDIR={shlex.quote(temp)}",
                f"WORK_DIR={shlex.quote(str(work))}", "DIAGNOSTICS_DIR=''", "MOUNTED=0",
                shell_function("preserve_release_diagnostics"), shell_function("cleanup"),
                "trap cleanup EXIT", "exit 7",
            ])
            result = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertFalse(work.exists())
            directories = list(root.glob("openclam-release-diagnostics.*"))
            self.assertEqual(len(directories), 1)
            preserved = directories[0]
            self.assertEqual(preserved.stat().st_mode & 0o777, 0o700)
            self.assertEqual({item.name for item in preserved.iterdir()},
                             {"syspolicy-test.txt", "codesign-test.txt", "notary-app.json"})
            self.assertNotIn("private profile history", result.stderr)


if __name__ == "__main__":
    unittest.main()
