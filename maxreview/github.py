"""GitHub API client for PR operations."""

import json
import re
import subprocess
from typing import Any

from maxreview.exceptions import GitHubAPIError


class GitHubClient:
    """Client for interacting with GitHub via gh CLI."""

    def __init__(self, repo: str | None = None) -> None:
        """Initialize GitHub client."""
        self.repo = repo or self._detect_repository()

    def _run_gh_command(
        self,
        args: list[str],
        check: bool = True,
        capture_stderr: bool = False,
        input_data: str | None = None,
    ) -> tuple[str, str]:
        """Run a gh CLI command and return stdout and stderr."""
        cmd = ["gh"] + args
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=check,
                input=input_data,
            )
            return result.stdout.strip(), result.stderr.strip()
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr.strip() if e.stderr else str(e)
            raise GitHubAPIError(f"GitHub CLI command failed: {error_msg}") from e
        except FileNotFoundError as e:
            raise GitHubAPIError("gh CLI not found. Please install GitHub CLI.") from e

    def _detect_repository(self) -> str:
        """Detect repository from environment or git remote."""
        import os

        repo = os.environ.get("MAXREVIEW_REPO")
        if repo:
            return repo

        try:
            stdout, _ = self._run_gh_command(
                ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                check=False,
            )
            if stdout:
                return stdout
        except GitHubAPIError:
            pass

        try:
            result = subprocess.run(
                ["git", "remote", "get-url", "origin"],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                remote_url = result.stdout.strip()
                repo_slug = self._extract_repo_slug(remote_url)
                if repo_slug:
                    return repo_slug
        except Exception:
            pass

        raise GitHubAPIError(
            "Unable to determine repository. Set MAXREVIEW_REPO environment variable."
        )

    @staticmethod
    def _extract_repo_slug(url: str) -> str | None:
        """Extract owner/repo from a git URL."""
        patterns = [
            r"^git@([^:]+):(.+)$",
            r"^ssh://git@([^/]+)/(.+)$",
            r"^https?://[^/]+/(.+)$",
        ]

        for pattern in patterns:
            match = re.match(pattern, url)
            if match:
                slug = match.group(2) if len(match.groups()) > 1 else match.group(1)
                slug = slug.removesuffix(".git").strip("/")
                return slug

        return None

    def get_current_user(self) -> str:
        """Get the current GitHub username."""
        try:
            stdout, _ = self._run_gh_command(["api", "user", "--jq", ".login"])
            if not stdout:
                raise GitHubAPIError("GitHub CLI returned an empty username")
            return stdout
        except GitHubAPIError as e:
            raise GitHubAPIError(
                "Could not get GitHub username. Make sure gh CLI is authenticated."
            ) from e

    def list_prs(self, limit: int = 100) -> list[dict[str, Any]]:
        """List open PRs with reviewer information."""
        stdout, _ = self._run_gh_command(
            [
                "pr",
                "list",
                "--repo",
                self.repo,
                "--state",
                "open",
                "--json",
                "number,title,headRefName,author,reviewRequests,reviews,additions,deletions",
                "--limit",
                str(limit),
            ]
        )
        return json.loads(stdout)  # type: ignore[no-any-return]

    def filter_prs_for_user(self, prs: list[dict[str, Any]], username: str) -> list[dict[str, Any]]:
        """Filter PRs to exclude those authored by or assigned to user."""
        filtered = []

        for pr in prs:
            author = pr.get("author", {}).get("login")
            if author == username:
                continue

            review_requests = pr.get("reviewRequests", [])
            reviews = pr.get("reviews", [])

            requested_reviewers = self._extract_reviewer_logins(review_requests)
            review_authors = self._extract_reviewer_logins(reviews, key="author")

            all_reviewers = requested_reviewers + review_authors

            if not all_reviewers:
                continue

            if username in all_reviewers:
                continue

            filtered.append(pr)

        return filtered

    @staticmethod
    def _extract_reviewer_logins(items: list[dict] | dict, key: str | None = None) -> list[str]:
        """Extract reviewer logins from review requests or reviews."""
        if isinstance(items, dict):
            if "nodes" in items:
                items = items["nodes"]
            else:
                return []

        if not isinstance(items, list):
            return []

        logins = []
        for item in items:
            if key and key in item:
                login = item[key].get("login")
            elif "requestedReviewer" in item:
                login = item["requestedReviewer"].get("login")
            elif "login" in item:
                login = item["login"]
            else:
                continue

            if login:
                logins.append(login)

        return logins

    def get_pr(self, pr_number: int) -> dict[str, Any]:
        """Get detailed information about a specific PR."""
        stdout, _ = self._run_gh_command(
            [
                "pr",
                "view",
                str(pr_number),
                "--repo",
                self.repo,
                "--json",
                "number,title,headRefName,headRefOid,author,additions,deletions",
            ]
        )
        return json.loads(stdout)  # type: ignore[no-any-return]

    def get_pr_comments(self, pr_number: int) -> list[dict[str, Any]]:
        """Get all comments on a PR."""
        stdout, _ = self._run_gh_command(
            ["api", f"repos/{self.repo}/pulls/{pr_number}/comments", "--paginate"]
        )
        return json.loads(stdout)  # type: ignore[no-any-return]

    def get_pr_files(self, pr_number: int) -> list[dict[str, Any]]:
        """Get files changed in a PR with patch information."""
        stdout, _ = self._run_gh_command(
            ["api", f"repos/{self.repo}/pulls/{pr_number}/files", "--paginate", "--jq", "."]
        )
        pages = []
        for line in stdout.split("\n"):
            if line.strip():
                pages.extend(json.loads(line))
        return pages

    def create_review(
        self,
        pr_number: int,
        body: str | None = None,
        comments: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        """Create a pending review on a PR."""
        payload: dict[str, Any] = {"event": "COMMENT"}

        if body:
            payload["body"] = body

        if comments:
            payload["comments"] = comments

        payload_json = json.dumps(payload)

        try:
            stdout, _ = self._run_gh_command(
                [
                    "api",
                    "--method",
                    "POST",
                    f"repos/{self.repo}/pulls/{pr_number}/reviews",
                    "--input",
                    "-",
                ],
                input_data=payload_json,
            )
            return json.loads(stdout)  # type: ignore[no-any-return]
        except GitHubAPIError as e:
            raise GitHubAPIError(f"Failed to create pending GitHub review: {e}") from e

    def get_valid_inline_positions(self, pr_number: int) -> dict[str, list[int]]:
        """Get valid line positions for inline comments based on PR diff."""
        files = self.get_pr_files(pr_number)
        return self._parse_diff_positions(files)

    @staticmethod
    def _parse_diff_positions(files: list[dict[str, Any]]) -> dict[str, list[int]]:
        """Parse diff hunks to extract valid line numbers for comments."""
        pattern = re.compile(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
        result: dict[str, list[int]] = {}

        for file_info in files:
            patch = file_info.get("patch")
            if not patch:
                continue

            filename = file_info.get("filename", "")
            valid_lines: set[int] = set()
            current_line: int | None = None

            for line in patch.splitlines():
                if line.startswith("@@"):
                    match = pattern.match(line)
                    if match:
                        current_line = int(match.group(1))
                    else:
                        current_line = None
                    continue

                if current_line is None:
                    continue

                if line.startswith("+") and not line.startswith("+++"):
                    valid_lines.add(current_line)
                    current_line += 1
                elif line.startswith("-") and not line.startswith("---"):
                    continue
                else:
                    valid_lines.add(current_line)
                    current_line += 1

            if valid_lines:
                result[filename] = sorted(valid_lines)

        return result
