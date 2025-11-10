"""Pytest configuration and fixtures."""

import pytest


@pytest.fixture
def sample_pr_data() -> dict:
    """Sample PR data for testing."""
    return {
        "number": 123,
        "title": "Test PR",
        "headRefName": "feature/test",
        "headRefOid": "abc123def456",
        "author": {"login": "testuser"},
        "additions": 100,
        "deletions": 50,
    }


@pytest.fixture
def sample_issue_data() -> dict:
    """Sample issue data for testing."""
    return {
        "agent": "claude",
        "priority": "P0",
        "file": "test.py",
        "line": 10,
        "commit_id": "abc123",
        "category": "bug",
        "description": "Test issue",
        "proposed_fix": "Test fix",
    }
