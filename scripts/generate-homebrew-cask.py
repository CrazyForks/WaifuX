#!/usr/bin/env python3
"""Render and validate the WaifuX Homebrew cask from one canonical template."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "packaging/homebrew/waifux.rb.in"
DEFAULT_OUTPUT = ROOT / "packaging/homebrew/waifux.rb"
PLACEHOLDERS = ("__VERSION__", "__SHA256__")


def fail(message: str) -> None:
    raise SystemExit(f"homebrew cask validation failed: {message}")


def validate_version(version: str) -> None:
    if not re.fullmatch(r"\d+(?:\.\d+)+", version):
        fail(f"invalid version: {version!r}")


def validate_sha256(sha256: str) -> None:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
        fail(f"invalid SHA256: {sha256!r}")


def render(version: str, sha256: str) -> str:
    validate_version(version)
    validate_sha256(sha256)
    template = TEMPLATE.read_text(encoding="utf-8")
    rendered = template.replace("__VERSION__", version).replace("__SHA256__", sha256.lower())
    validate_text(rendered, version, sha256.lower(), allow_placeholders=False)
    return rendered


def validate_text(text: str, version: str | None = None, sha256: str | None = None, *, allow_placeholders: bool) -> None:
    if not text.startswith('cask "waifux" do\n'):
        fail("missing waifux cask header")
    if "#{VERSION}" in text or "#{SHA256}" in text:
        fail("legacy shell placeholders are present")
    if not allow_placeholders and any(placeholder in text for placeholder in PLACEHOLDERS):
        fail("unresolved template placeholder")
    if version is not None:
        if f'version "{version}"' not in text:
            fail("version does not match rendered cask")
    if 'url "https://github.com/jipika/WaifuX/releases/download/v#{version}/WaifuX.dmg"' not in text:
        fail("URL must interpolate the cask version")
    if sha256 is not None and f'sha256 "{sha256}"' not in text:
        fail("SHA256 does not match rendered cask")

    required_steps = (
        'run "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"',
        'run "/usr/bin/pluginkit"',
        'run "/usr/bin/killall"',
    )
    for step in required_steps:
        start = text.find(step)
        if start < 0:
            fail(f"missing postflight step: {step}")
        end = text.find("\n    run ", start + len(step))
        block = text[start:] if end < 0 else text[start:end]
        if "must_succeed: false" not in block:
            fail(f"postflight step is still fatal: {step}")
        if "print_stderr: false" not in block:
            fail(f"postflight step leaks stderr: {step}")

    if text.count("must_succeed: false") != 3:
        fail("expected exactly three non-fatal postflight steps")
    if "postflight_steps do" not in text or "  end\n\n  zap trash:" not in text:
        fail("postflight block structure is incomplete")


def check_template() -> None:
    text = TEMPLATE.read_text(encoding="utf-8")
    if text.count("__VERSION__") != 1:
        fail("template must use __VERSION__ for the version stanza")
    if text.count("__SHA256__") != 1:
        fail("template must use __SHA256__ once")
    validate_text(text, allow_placeholders=True)
    print(f"validated template: {TEMPLATE}")


def write_output(output: Path, rendered: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    output.chmod(0o644)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="release version, for example 38.0.150")
    parser.add_argument("--sha256", help="64-character DMG SHA256")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true", help="validate only the canonical template")
    parser.add_argument("--check-file", type=Path, help="validate an already rendered cask")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.check:
        check_template()
        return 0
    if args.check_file is not None:
        text = args.check_file.read_text(encoding="utf-8")
        expected_version = args.version
        expected_sha256 = args.sha256.lower() if args.sha256 is not None else None
        if expected_version is not None:
            validate_version(expected_version)
        if expected_sha256 is not None:
            validate_sha256(expected_sha256)
        validate_text(
            text,
            expected_version,
            expected_sha256,
            allow_placeholders=False,
        )
        print(f"validated cask: {args.check_file}")
        return 0
    if args.version is None or args.sha256 is None:
        fail("--version and --sha256 are required when rendering")
    rendered = render(args.version, args.sha256)
    write_output(args.output, rendered)
    digest = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    print(f"rendered cask: {args.output} (sha256={digest})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
