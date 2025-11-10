"""Tests for GitHub API client."""

import pytest

from maxreview.github import GitHubClient


def test_extract_repo_slug_ssh() -> None:
    """Test extracting repo slug from SSH URLs."""
    url = "git@github.com:owner/repo.git"
    slug = GitHubClient._extract_repo_slug(url)
    assert slug == "owner/repo"


def test_extract_repo_slug_https() -> None:
    """Test extracting repo slug from HTTPS URLs."""
    url = "https://github.com/owner/repo.git"
    slug = GitHubClient._extract_repo_slug(url)
    assert slug == "owner/repo"


def test_extract_repo_slug_ssh_protocol() -> None:
    """Test extracting repo slug from ssh:// URLs."""
    url = "ssh://git@github.com/owner/repo.git"
    slug = GitHubClient._extract_repo_slug(url)
    assert slug == "owner/repo"


def test_extract_repo_slug_no_git_suffix() -> None:
    """Test extracting repo slug without .git suffix."""
    url = "https://github.com/owner/repo"
    slug = GitHubClient._extract_repo_slug(url)
    assert slug == "owner/repo"


def test_extract_repo_slug_invalid() -> None:
    """Test extracting repo slug from invalid URL."""
    url = "not-a-valid-url"
    slug = GitHubClient._extract_repo_slug(url)
    assert slug is None


def test_extract_reviewer_logins_flat_array() -> None:
    """Test extracting reviewer logins from flat array."""
    items = [{"login": "user1"}, {"login": "user2"}]
    logins = GitHubClient._extract_reviewer_logins(items)
    assert logins == ["user1", "user2"]


def test_extract_reviewer_logins_with_key() -> None:
    """Test extracting reviewer logins with author key."""
    items = [{"author": {"login": "user1"}}, {"author": {"login": "user2"}}]
    logins = GitHubClient._extract_reviewer_logins(items, key="author")
    assert logins == ["user1", "user2"]


def test_extract_reviewer_logins_with_requested_reviewer() -> None:
    """Test extracting reviewer logins with requestedReviewer."""
    items = [
        {"requestedReviewer": {"login": "user1"}},
        {"requestedReviewer": {"login": "user2"}},
    ]
    logins = GitHubClient._extract_reviewer_logins(items)
    assert logins == ["user1", "user2"]


def test_extract_reviewer_logins_empty() -> None:
    """Test extracting reviewer logins from empty list."""
    items: list = []
    logins = GitHubClient._extract_reviewer_logins(items)
    assert logins == []


def test_parse_diff_positions() -> None:
    """Test parsing diff positions from file patches."""
    files = [
        {
            "filename": "test.py",
            "patch": """@@ -1,3 +1,4 @@
 def foo():
+    print("hello")
     return 42
 """,
        }
    ]

    positions = GitHubClient._parse_diff_positions(files)
    assert "test.py" in positions
    assert 2 in positions["test.py"]
    assert 3 in positions["test.py"]


def test_parse_diff_positions_no_patch() -> None:
    """Test parsing diff positions when no patch available."""
    files = [{"filename": "test.py"}]

    positions = GitHubClient._parse_diff_positions(files)
    assert positions == {}


def test_run_gh_command_with_input(monkeypatch: pytest.MonkeyPatch) -> None:
    """Test that _run_gh_command passes input_data to subprocess."""
    import subprocess
    from unittest.mock import MagicMock, Mock

    mock_run = MagicMock(return_value=Mock(stdout='{"result": "success"}', stderr="", returncode=0))
    monkeypatch.setattr(subprocess, "run", mock_run)

    client = GitHubClient(repo="owner/repo")
    input_json = '{"key": "value"}'

    client._run_gh_command(["api", "endpoint", "--input", "-"], input_data=input_json)

    mock_run.assert_called_once()
    call_kwargs = mock_run.call_args.kwargs
    assert call_kwargs.get("input") == input_json
    assert call_kwargs.get("text") is True
    assert call_kwargs.get("capture_output") is True
