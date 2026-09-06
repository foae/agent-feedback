#!/usr/bin/env python3
"""Publish an immutable stable tag only after CI passes on the exact commit."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="stable SemVer tag, e.g. v1.0.1")
    parser.add_argument("title", help="human-readable release name")
    parser.add_argument("notes", type=Path, help="release notes Markdown file")
    parser.add_argument("--check", action="store_true", help="verify prerequisites and CI without publishing")
    args = parser.parse_args()
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.version):
        sys.exit("Expected a stable vMAJOR.MINOR.PATCH tag")
    if not args.title.strip() or not args.notes.is_file() or not args.notes.read_text().strip():
        sys.exit("A release name and nonempty notes file are required")
    if run("git", "status", "--porcelain"):
        sys.exit("Commit all changes before releasing")
    if run("git", "branch", "--show-current") != "main":
        sys.exit("Release from main")
    sha = run("git", "rev-parse", "HEAD")
    remote = run("git", "ls-remote", "origin", "refs/heads/main").split()
    if not remote or remote[0] != sha:
        sys.exit("Push this exact commit to origin/main before releasing")
    if run("git", "tag", "--list", args.version) or run("git", "ls-remote", "origin", "refs/tags/" + args.version):
        sys.exit("Tag already exists; never replace a published version")
    repo = run("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner")
    runs = json.loads(run("gh", "run", "list", "--repo", repo, "--workflow", "ci.yml", "--event", "push", "--commit", sha,
                          "--limit", "100", "--json", "databaseId,headSha,status,conclusion"))
    if not runs or runs[0]["headSha"] != sha:
        sys.exit("No push CI run found for the exact release commit; retry after CI starts")
    ci = runs[0]
    if ci["status"] != "completed":
        subprocess.run(["gh", "run", "watch", str(ci["databaseId"]), "--repo", repo, "--exit-status"], check=True)
        ci = json.loads(run("gh", "run", "view", str(ci["databaseId"]), "--repo", repo,
                            "--json", "headSha,status,conclusion"))
    if ci["headSha"] != sha or ci["status"] != "completed" or ci["conclusion"] != "success":
        sys.exit("Exact-commit CI must succeed before publication")
    if args.check:
        print(f"Ready: {args.version} at {sha}; CI passed")
        return
    run("git", "tag", "-a", args.version, sha, "-m", f"{args.version}: {args.title}")
    subprocess.run(["git", "push", "--force-with-lease=refs/tags/" + args.version + ":", "origin", "refs/tags/" + args.version], check=True)
    subprocess.run(["gh", "release", "create", args.version, "--repo", repo, "--verify-tag", "--latest",
                    "--title", f"{args.version}: {args.title}", "--notes-file", str(args.notes)], check=True)
    release = json.loads(run("gh", "release", "view", args.version, "--repo", repo,
                             "--json", "tagName,isDraft,isPrerelease,url"))
    if release["tagName"] != args.version or release["isDraft"] or release["isPrerelease"]:
        sys.exit("Release verification failed; inspect GitHub without moving the tag")
    print(release["url"])


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Command failed (exit {exc.returncode}); inspect state before retrying. Never move an existing tag.")
