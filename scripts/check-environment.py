#!/usr/bin/env python3
"""Read-only M0 checks. Never records audio, invokes models, or persists credentials/account IDs."""
import argparse
import datetime
import json
import pathlib
import plistlib
import shutil
import subprocess


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=40)
    if result.returncode:
        # Do not include raw stderr: credential helpers can print private paths or sensitive diagnostics.
        raise RuntimeError(f"{args[0]} command failed (exit {result.returncode})")
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="default")
    parser.add_argument("--region", default="us-west-2")
    parser.add_argument("--aws", action="store_true", help="Also run read-only STS/Bedrock metadata checks")
    parser.add_argument("--output", type=pathlib.Path)
    options = parser.parse_args()
    result = {
        "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "macOS": command(["sw_vers", "-productVersion"]),
        "swift": command(["xcrun", "swift", "--version"]).splitlines()[0],
        "applications": {},
        "aws": {"profile": options.profile, "region": options.region, "checked": False},
        "notVerified": [
            "Teams/Zoom/Feishu/Tencent Meeting/DingTalk actual scoped dual-track capture and permission prompts",
            "Mixed-language + diarization + simultaneous Transcribe streams",
            "Four models' inference authorization and medium request parameters",
            "Speaker attribution quality, external-speaker echo, device switching",
            "Two-hour stability, network gaps, cache recovery and replay",
        ],
    }
    for name in ("Microsoft Teams", "zoom.us", "Lark", "TencentMeeting", "DingTalk"):
        info = pathlib.Path("/Applications") / f"{name}.app/Contents/Info.plist"
        if info.exists():
            with info.open("rb") as file:
                data = plistlib.load(file)
            result["applications"][name] = {
                "bundleID": data.get("CFBundleIdentifier"),
                "version": data.get("CFBundleShortVersionString"),
            }
        else:
            result["applications"][name] = {"installed": False}
    if options.aws:
        aws = shutil.which("aws")
        if not aws:
            result["aws"]["error"] = "AWS CLI is not installed"
        else:
            common = ["--profile", options.profile, "--region", options.region,
                      "--cli-connect-timeout", "5", "--cli-read-timeout", "15", "--output", "json"]
            try:
                # Only a boolean leaves the CLI. The account number and ARN are never printed or saved.
                verified = json.loads(command([aws, "sts", "get-caller-identity", "--query",
                                                "length(Account) > `0`", *common]))
                result["aws"]["credentialsValid"] = verified
                models = json.loads(command([aws, "bedrock", "list-foundation-models", "--by-provider", "OpenAI",
                    "--query", "modelSummaries[].{id:modelId,name:modelName}", *common]))
                result["aws"]["listedModels"] = [
                    model for model in models if any(term in model["id"] for term in ("astra", "sol", "terra", "luna"))
                ]
                result["aws"]["checked"] = True
                result["aws"]["note"] = "Listing a model does not validate inference access, routing, or reasoning compatibility."
            except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
                result["aws"]["error"] = type(error).__name__ + ": read-only check failed; inspect the selected profile locally"
    output = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if options.output:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(output)
    print(output, end="")


if __name__ == "__main__":
    main()
