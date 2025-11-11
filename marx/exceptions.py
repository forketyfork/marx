"""Custom exceptions for Marx."""


class MarxError(Exception):
    """Base exception for all Marx errors."""


class DependencyError(MarxError):
    """Raised when a required dependency is missing."""


class GitHubAPIError(MarxError):
    """Raised when GitHub API interactions fail."""


class DockerError(MarxError):
    """Raised when Docker operations fail."""


class ReviewError(MarxError):
    """Raised when review processing fails."""


class ValidationError(MarxError):
    """Raised when validation fails."""
