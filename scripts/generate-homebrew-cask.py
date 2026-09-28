#!/usr/bin/env python3
"""Render and validate the WaifuX Homebrew cask from one canonical template.

Since the architecture split (arm64 / x86_64 DMGs), the cask carries two
arch-specific url/sha256 pairs inside on_arm / on_intel stanzas.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "packaging/homebrew/waifux.rb.in"
DEFAULT_OUTPUT = ROOT / "packaging/homebrew/waifux.rb"
PLACEHOLDERS = ("__VERSION__", "__SHA256_ARM__", "__SHA256_INTEL__")

URL_ARM = 'url "https://github.com/jipika/WaifuX/releases/download/v#{version}/WaifuX-arm64.dmg"'
URL_INTEL = 'url "https://github.com/jipika/WaifuX/releases/download/v#{version}/WaifuX-x86_64.dmg"'


def fail(message: str) -> None:
    raise SystemExit(f"homebrew cask validation failed: {message}")


def validate_version(version: str) -> None:
    if not re.fullmatch(r"\d+(?:\.\d+)+", version):
        fail(f"invalid version: {version!r}")


def validate_sha256(sha256: str) -> None:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
        fail(f"invalid SHA256: {sha256!r}")


def render(version: str, sha256_arm: str, sha256_intel: str) -> str:
    validate_version(version)
    validate_sha256(sha256_arm)
    validate_sha256(sha256_intel)
    template = TEMPLATE.read_text(encoding="utf-8")
    rendered = (
        template.replace("__VERSION__", version)
        .replace("__SHA256_ARM__", sha256_arm.lower())
        .replace("__SHA256_INTEL__", sha256_intel.lower())
    )
    validate_text(rendered, version, sha256_arm.lower(), sha256_intel.lower(), allow_placeholders=False)
    return rendered


def validate_text(
    text: str,
    version: str | None = None,
    sha256_arm: str | None = None,
    sha256_intel: str | None = None,
    *,
    allow_placeholders: bool,
) -> None:
    if not text.startswith('cask "waifux" do\n'):
        fail("missing waifux cask header")
    if "#{VERSION}" in text or "#{SHA256}" in text:
        fail("legacy shell placeholders are present")
    if not allow_placeholders and any(placeholder in text for placeholder in PLACEHOLDERS):
        fail("unresolved template placeholder")
    if version is not None:
        if f'version "{version}"' not in text:
            fail("version does not match rendered cask")

    # 按架构分发：两个架构 URL 都必须插值 cask 版本，且各自有独立 sha256 块
    for label, url in (("arm64", URL_ARM), ("x86_64", URL_INTEL)):
        start = text.find(url)
        if start < 0:
            fail(f"{label} URL must interpolate the cask version and match the architecture-split name")
        block_start = text.rfind("on_arm do", 0, start) if label == "arm64" else text.rfind("on_intel do", 0, start)
        block_end = text.find("\n  end", start)
        if block_start < 0 or block_end < 0:
            fail(f"{label} URL must live inside its on_arm/on_intel stanza")
        block = text[block_start:block_end]
        if label == "arm64" and "on_intel do" in block:
            fail("arm64 stanza boundary broken")
        if label == "x86_64" and "on_arm do" in block:
            fail("x86_64 stanza boundary broken")
        if "sha256 " not in block:
            fail(f"{label} stanza is missing its sha256")

    if "url \"https://github.com/jipika/WaifuX/releases/download/v#{version}/WaifuX.dmg\"" in text:
        fail("legacy universal WaifuX.dmg URL is present; use the architecture-split names")

    if sha256_arm is not None and f'sha256 "{sha256_arm}"' not in text:
        fail("arm64 SHA256 does not match rendered cask")
    if sha256_intel is not None and f'sha256 "{sha256_intel}"' not in text:
        fail("x86_64 SHA256 does not match rendered cask")

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
    if text.count("__SHA256_ARM__") != 1:
        fail("template must use __SHA256_ARM__ once")
    if text.count("__SHA256_INTEL__") != 1:
        fail("template must use __SHA256_INTEL__ once")
    validate_text(text, allow_placeholders=True)
    print(f"validated template: {TEMPLATE}")


def write_output(output: Path, rendered: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    output.chmod(0o644)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="release version, for example 38.0.150")
    parser.add_argument("--sha256-arm", help="64-character arm64 DMG SHA256")
    parser.add_argument("--sha256-intel", help="64-character x86_64 DMG SHA256")
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
        expected_arm = args.sha256_arm.lower() if args.sha256_arm is not None else None
        expected_intel = args.sha256_intel.lower() if args.sha256_intel is not None else None
        if expected_version is not None:
            validate_version(expected_version)
        if expected_arm is not None:
            validate_sha256(expected_arm)
        if expected_intel is not None:
            validate_sha256(expected_intel)
        validate_text(
            text,
            expected_version,
            expected_arm,
            expected_intel,
            allow_placeholders=False,
        )
        print(f"validated cask: {args.check_file}")
        return 0
    if args.version is None or args.sha256_arm is None or args.sha256_intel is None:
        fail("--version, --sha256-arm and --sha256-intel are required when rendering")
    rendered = render(args.version, args.sha256_arm, args.sha256_intel)
    write_output(args.output, rendered)
    digest = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    print(f"rendered cask: {args.output} (sha256={digest})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
