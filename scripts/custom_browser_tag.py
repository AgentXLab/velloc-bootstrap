#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO_ORDER = ("root", "docs", "src", "custom_browser")
MANIFEST_REPOS = ("root", "src", "custom_browser")
REPOS = {
    "root": ROOT,
    "docs": ROOT / "docs",
    "src": ROOT / "src",
    "custom_browser": ROOT / "src" / "custom_browser",
}

CHROME_VERSION_PATH = ROOT / "src" / "chrome" / "VERSION"
CUSTOM_VERSION_PATH = ROOT / "src" / "custom_browser" / "VERSION"
MANIFEST_PATH = ROOT / "release_manifest.json"
TAG_PREFIX = "custom_browser-"


class CommandError(RuntimeError):
    pass


def _stream_pipe(pipe, target, buffer) -> None:
    for line in iter(pipe.readline, ""):
        target.write(line)
        target.flush()
        if buffer is not None:
            buffer.append(line)
    pipe.close()


def run(cmd: list[str], cwd: Path | None = None, capture: bool = True) -> str:
    if not capture:
        result = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            text=True,
        )
        if result.returncode != 0:
            raise CommandError(f"Command failed: {' '.join(cmd)}")
        return ""

    process = subprocess.Popen(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout_buffer = [] if capture else None
    stderr_buffer = [] if capture else None

    threads = []
    if process.stdout is not None:
        threads.append(
            threading.Thread(
                target=_stream_pipe, args=(process.stdout, sys.stdout, stdout_buffer), daemon=True
            )
        )
    if process.stderr is not None:
        threads.append(
            threading.Thread(
                target=_stream_pipe, args=(process.stderr, sys.stderr, stderr_buffer), daemon=True
            )
        )

    for thread in threads:
        thread.start()

    returncode = process.wait()
    for thread in threads:
        thread.join()

    if returncode != 0:
        stderr = "".join(stderr_buffer).strip() if stderr_buffer is not None else ""
        message = f"Command failed: {' '.join(cmd)}"
        if stderr:
            message = f"{message}\n{stderr}"
        raise CommandError(message)

    return "".join(stdout_buffer).strip() if stdout_buffer is not None else ""


def run_quiet(cmd: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        message = f"Command failed: {' '.join(cmd)}"
        if stderr:
            message = f"{message}\n{stderr}"
        raise CommandError(message)
    return result.stdout.strip()


def git(repo: Path, *args: str) -> str:
    return run(["git", "-C", str(repo), *args], capture=True)


def iter_repos():
    for name in REPO_ORDER:
        yield name, REPOS[name]


def get_repo_head(repo: Path) -> str:
    return git(repo, "rev-parse", "HEAD")


def parse_version_file(path: Path) -> dict[str, int]:
    if not path.exists():
        raise CommandError(f"Missing version file: {path}")
    data: dict[str, int] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise CommandError(f"Invalid line in {path}: {raw}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not re.fullmatch(r"\d+", value):
            raise CommandError(f"Non-numeric value in {path}: {raw}")
        data[key] = int(value)
    return data


def update_version_file(path: Path, updates: dict[str, int]) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines()
    changed = False
    found = {key: False for key in updates}
    new_lines: list[str] = []
    for raw in lines:
        line = raw
        stripped = raw.strip()
        if "=" in stripped and not stripped.startswith("#"):
            key = stripped.split("=", 1)[0].strip()
            if key in updates:
                line = f"{key}={updates[key]}"
                found[key] = True
                if line != raw:
                    changed = True
        new_lines.append(line)
    missing = [k for k, v in found.items() if not v]
    if missing:
        raise CommandError(f"Missing keys in {path}: {', '.join(missing)}")
    if changed:
        path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    return changed


def ensure_git_repo(repo: Path) -> None:
    try:
        git(repo, "rev-parse", "--is-inside-work-tree")
    except CommandError as exc:
        raise CommandError(f"Not a git repo: {repo}") from exc


def ensure_clean(repo: Path, ignore_submodules: bool = False) -> None:
    args = ["status", "--porcelain"]
    if ignore_submodules:
        args.append("--ignore-submodules=all")
    status = git(repo, *args)
    if status.strip():
        raise CommandError(f"Repo not clean: {repo}")


def check_detached(repo: Path) -> bool:
    branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    return branch.strip() == "HEAD"


def tag_exists(repo: Path, tag: str) -> bool:
    tags = git(repo, "tag", "--list", tag)
    return bool(tags.strip())


def list_tags(repo: Path, pattern: str | None = None) -> list[str]:
    args = ["tag", "--list"]
    if pattern:
        args.append(pattern)
    output = run_quiet(["git", "-C", str(repo), *args])
    return [line.strip() for line in output.splitlines() if line.strip()]


def collect_tag_map(pattern: str | None = None) -> dict[str, list[str]]:
    tag_map: dict[str, list[str]] = {}
    for name, repo in iter_repos():
        for tag in list_tags(repo, pattern):
            tag_map.setdefault(tag, []).append(name)
    return tag_map


def remote_tag_exists(repo: Path, remote: str, tag: str) -> bool:
    try:
        output = run_quiet(
            ["git", "-C", str(repo), "ls-remote", "--tags", remote, tag]
        )
    except CommandError as exc:
        raise CommandError(f"Failed to query remote '{remote}' for {repo}: {exc}") from exc
    return bool(output.strip())


def commit_if_needed(repo: Path, paths: list[Path], message: str) -> bool:
    run(["git", "-C", str(repo), "add", *[str(p) for p in paths]], capture=True)
    diff = git(repo, "diff", "--cached", "--name-only")
    if not diff.strip():
        return False
    run(["git", "-C", str(repo), "commit", "-m", message], capture=True)
    return True


def format_tag(major: int, minor: int, build: int, patch: int) -> str:
    return f"{TAG_PREFIX}v{major}.{minor}.{build}.{patch}"


def prompt_choice() -> str:
    print("Choose how to set the tag version:")
    print("1) Increase CUSTOM_BROWSER_BUILD")
    print("2) Increase CUSTOM_BROWSER_PATCH")
    print("3) Keep current")
    print("4) User input")
    while True:
        choice = input("Select [1-4]: ").strip()
        if choice in {"1", "2", "3", "4"}:
            return choice
        print("Invalid choice. Enter 1, 2, 3, or 4.")


def prompt_version_input(current: dict[str, int]) -> tuple[int, int, int]:
    prompt = (
        "Enter CUSTOM_BROWSER_MINOR.BUILD.PATCH "
        f"(current {current['CUSTOM_BROWSER_MINOR']}."
        f"{current['CUSTOM_BROWSER_BUILD']}."
        f"{current['CUSTOM_BROWSER_PATCH']}): "
    )
    while True:
        raw = input(prompt).strip()
        if not raw:
            print("Please enter a value.")
            continue
        parts = re.split(r"[.\s]+", raw)
        if len(parts) != 3 or not all(re.fullmatch(r"\d+", p) for p in parts):
            print("Expected format like 1.2.3 or '1 2 3'.")
            continue
        return (int(parts[0]), int(parts[1]), int(parts[2]))


def prompt_yes_no(question: str, default_no: bool = True) -> bool:
    suffix = " [y/N]: " if default_no else " [Y/n]: "
    while True:
        raw = input(question + suffix).strip().lower()
        if not raw:
            return not default_no
        if raw in {"y", "yes"}:
            return True
        if raw in {"n", "no"}:
            return False
        print("Please answer y or n.")


def repo_relpath(repo: Path) -> str:
    rel = repo.relative_to(ROOT)
    return "." if rel.parts == () else str(rel)


def write_manifest(
    tag: str,
    major: int,
    minor: int,
    build: int,
    patch: int,
    repo_heads: dict[str, str],
    path: Path,
) -> None:
    manifest = {
        "tag": tag,
        "created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "versions": {
            "chrome_major": major,
            "custom_browser_minor": minor,
            "custom_browser_build": build,
            "custom_browser_patch": patch,
        },
        "repos": [
            {
                "name": name,
                "path": repo_relpath(REPOS[name]),
                "tag": tag,
                "head": repo_heads.get(name),
            }
            for name in MANIFEST_REPOS
        ],
    }
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")




def create_release(args: argparse.Namespace) -> None:
    for _, repo in iter_repos():
        ensure_git_repo(repo)

    for name, repo in iter_repos():
        ensure_clean(repo, ignore_submodules=(name == "src"))

    detached = [name for name, repo in iter_repos() if check_detached(repo)]
    if detached:
        print("Warning: detached HEAD in: " + ", ".join(detached))
        if not prompt_yes_no("Continue anyway?", default_no=True):
            raise CommandError("Aborted due to detached HEAD.")

    chrome_version = parse_version_file(CHROME_VERSION_PATH)
    custom_version = parse_version_file(CUSTOM_VERSION_PATH)

    if "MAJOR" not in chrome_version:
        raise CommandError(f"Missing MAJOR in {CHROME_VERSION_PATH}")
    for key in ("CUSTOM_BROWSER_MINOR", "CUSTOM_BROWSER_BUILD", "CUSTOM_BROWSER_PATCH"):
        if key not in custom_version:
            raise CommandError(f"Missing {key} in {CUSTOM_VERSION_PATH}")

    major = chrome_version["MAJOR"]
    minor = custom_version["CUSTOM_BROWSER_MINOR"]
    build = custom_version["CUSTOM_BROWSER_BUILD"]
    patch = custom_version["CUSTOM_BROWSER_PATCH"]

    print(f"Current version: {major}.{minor}.{build}.{patch}")
    print(f"Current tag: {format_tag(major, minor, build, patch)}")

    choice = prompt_choice()
    if choice == "1":
        build += 1
    elif choice == "2":
        patch += 1
    elif choice == "4":
        minor, build, patch = prompt_version_input(custom_version)

    tag = format_tag(major, minor, build, patch)
    print(f"Proposed tag: {tag}")

    existing_tags = [name for name, repo in iter_repos() if tag_exists(repo, tag)]
    if existing_tags:
        print("Tag already exists in: " + ", ".join(existing_tags))
        if prompt_yes_no("Delete existing local tags and continue?", default_no=True):
            for name in existing_tags:
                run(["git", "-C", str(REPOS[name]), "tag", "-d", tag], capture=True)
                print(f"Deleted existing tag in {name}.")
        else:
            raise CommandError("Aborted due to existing tag.")

    if not prompt_yes_no("Proceed with version update, commit, and tag?", default_no=True):
        raise CommandError("Aborted by user.")

    version_updated = update_version_file(
        CUSTOM_VERSION_PATH,
        {
            "CUSTOM_BROWSER_MINOR": minor,
            "CUSTOM_BROWSER_BUILD": build,
            "CUSTOM_BROWSER_PATCH": patch,
        },
    )

    if version_updated:
        committed = commit_if_needed(
            REPOS["custom_browser"],
            [CUSTOM_VERSION_PATH],
            f"Update custom browser version to {major}.{minor}.{build}.{patch}",
        )
        if committed:
            print("Committed version update in custom_browser.")
        else:
            print("No staged changes for custom_browser version update.")
    else:
        print("No version file changes needed.")

    repo_heads = {name: get_repo_head(repo) for name, repo in iter_repos()}

    write_manifest(tag, major, minor, build, patch, repo_heads, MANIFEST_PATH)
    manifest_committed = commit_if_needed(
        REPOS["root"],
        [MANIFEST_PATH],
        f"Release manifest for {tag}",
    )
    if manifest_committed:
        print("Committed release manifest in root repo.")
    else:
        print("No changes to release manifest.")

    tag_message = f"Release {tag}"
    tag_args = ["tag", "-a", tag, "-m", tag_message]
    for name, repo in iter_repos():
        run(["git", "-C", str(repo), *tag_args], capture=True)
        print(f"Tagged {name} with {tag}.")

    if prompt_yes_no("Push tags to remote now?", default_no=True):
        remote = input("Remote name (default: origin): ").strip() or "origin"
        for name, repo in iter_repos():
            run(["git", "-C", str(repo), "push", remote, tag], capture=True)
            print(f"Pushed tag to {name}:{remote}.")



def delete_release(args: argparse.Namespace) -> None:
    tag = args.tag
    if not tag:
        tag_map = collect_tag_map(f"{TAG_PREFIX}*")
        if tag_map:
            print("Available release tags:")
            for listed_tag in sorted(tag_map.keys(), reverse=True):
                repos = ", ".join(tag_map[listed_tag])
                print(f" - {listed_tag} ({repos})")
        else:
            print(f"No tags found matching {TAG_PREFIX}* in any repo.")
        tag = input("Enter tag to delete: ").strip()
    if not tag:
        raise CommandError("Tag is required.")

    repos_with_tag = [name for name, repo in iter_repos() if tag_exists(repo, tag)]
    if not repos_with_tag:
        raise CommandError(f"Tag not found in any repo: {tag}")

    print("Tag will be deleted in: " + ", ".join(repos_with_tag))
    first = input(f"Type the tag name to confirm deletion ({tag}): ").strip()
    if first != tag:
        raise CommandError("Tag confirmation mismatch.")
    second = input("Type DELETE to proceed: ").strip()
    if second != "DELETE":
        raise CommandError("Deletion confirmation failed.")

    for name in repos_with_tag:
        repo = REPOS[name]
        run(["git", "-C", str(repo), "tag", "-d", tag], capture=True)
        print(f"Deleted tag in {name}.")

    remote = input("Remote name to delete tag from (default: origin): ").strip() or "origin"
    for name in repos_with_tag:
        repo = REPOS[name]
        if remote_tag_exists(repo, remote, tag):
            run(["git", "-C", str(repo), "push", remote, "--delete", tag], capture=True)
            print(f"Deleted tag from {name}:{remote}.")
        else:
            print(f"Remote tag not found in {name}:{remote}; skipping.")



def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Tag custom browser release across multiple repos."
    )
    subparsers = parser.add_subparsers(dest="command")

    create = subparsers.add_parser("create", help="Create commit(s) and tag release.")
    delete = subparsers.add_parser("delete", help="Delete tag from repos.")
    delete.add_argument("--tag", help="Tag to delete.")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if not args.command:
        args.command = "create"

    try:
        if args.command == "create":
            create_release(args)
        elif args.command == "delete":
            delete_release(args)
        else:
            raise CommandError(f"Unknown command: {args.command}")
        return 0
    except CommandError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
