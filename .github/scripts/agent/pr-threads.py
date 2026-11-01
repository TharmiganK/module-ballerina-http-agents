#!/usr/bin/env python3
"""Lists the review threads of a pull request and classifies them for the bug fixer.

For each thread: its GraphQL id (for resolving), resolution state, location, comments (with REST ids, which the reply
API uses), the source of the thread (`maintainer`: started by a user with write access, `qa`: started by the QA agent,
`other`: anyone else, including third-party bots), and whether it is `actionable`: unresolved, from a maintainer or
the QA agent, and the last word is not the bug fixer's.

Usage: pr-threads.py <owner/repo> <pr>   prints a JSON array
"""
import json
import subprocess
import sys

QUERY = """
query($owner: String!, $name: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line
          comments(first: 100) {
            nodes { databaseId body createdAt authorAssociation author { login } }
          }
        }
      }
    }
  }
}"""
WRITE_ACCESS = {"OWNER", "MEMBER", "COLLABORATOR"}
ACTIONS_BOT = {"github-actions", "github-actions[bot]"}
BUG_FIXER_MARKERS = ("Posted by the bug fixer", "<!-- bug-fixer:reply -->")
QA_MARKER = "<!-- qa:key="


def fetch(repo, pr):
    owner, name = repo.split("/", 1)
    threads, cursor = [], None
    while True:
        args = ["gh", "api", "graphql", "-f", f"query={QUERY}", "-F", f"owner={owner}", "-F", f"name={name}",
                "-F", f"pr={pr}"]
        if cursor:
            args += ["-F", f"cursor={cursor}"]
        data = json.loads(subprocess.run(args, capture_output=True, text=True, check=True).stdout)
        page = data["data"]["repository"]["pullRequest"]["reviewThreads"]
        threads += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            return threads
        cursor = page["pageInfo"]["endCursor"]


def classify(thread):
    comments = [{
        "id": c["databaseId"],
        "author": (c["author"] or {}).get("login", "ghost"),
        "association": c["authorAssociation"],
        "created_at": c["createdAt"],
        "body": c["body"],
    } for c in thread["comments"]["nodes"]]
    first, last = comments[0], comments[-1]
    if first["author"] in ACTIONS_BOT and QA_MARKER in first["body"]:
        source = "qa"
    elif first["author"] not in ACTIONS_BOT and first["association"] in WRITE_ACCESS:
        source = "maintainer"
    else:
        source = "other"
    last_is_bug_fixer = last["author"] in ACTIONS_BOT and any(m in last["body"] for m in BUG_FIXER_MARKERS)
    return {
        "thread_id": thread["id"],
        "resolved": thread["isResolved"],
        "outdated": thread["isOutdated"],
        "path": thread["path"],
        "line": thread["line"],
        "source": source,
        "actionable": not thread["isResolved"] and source in ("qa", "maintainer") and not last_is_bug_fixer,
        "comments": comments,
    }


if __name__ == "__main__":
    print(json.dumps([classify(t) for t in fetch(sys.argv[1], int(sys.argv[2]))], indent=2))
