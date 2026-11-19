"""Export named screenshot attachments from the Xcode results bundle."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

NAME = re.compile(r"^(store-(?:zh-Hans|zh-Hant|en)-\d{2}-[a-z-]+|paid-01-paywall)(?=[_.]|$)")


def copy_named_screenshots(folder):
    folder = folder.resolve()
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    names = set()
    for test in manifest:
        for attachment in test["attachments"]:
            match = NAME.match(attachment.get("suggestedHumanReadableName", ""))
            source = (folder / attachment["exportedFileName"]).resolve()
            if not match or source.suffix.lower() != ".png":
                continue
            if not source.is_relative_to(folder):
                raise ValueError(f"Screenshot attachment is outside the output folder: {source}")
            target = folder / (match[1] + ".png")
            if not source.is_file():
                raise FileNotFoundError(source)
            if source.resolve() != target.resolve():
                shutil.copy2(source, target)
            names.add(target.name)
    return names


def main():
    result, output = sys.argv[1:3]
    folder = Path(output)
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                    "--output-path", str(folder)], check=True)
    names = copy_named_screenshots(folder)
    if not names:
        sys.exit("No named store or paywall screenshots were exported.")
    print(f"Exported {len(names)} named screenshots to {folder}.")


if __name__ == "__main__":
    main()
