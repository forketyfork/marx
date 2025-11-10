"""Custom exceptions for MaxReview."""


class MaxReviewError(Exception):
    """Base exception for all MaxReview errors."""


class DependencyError(MaxReviewError):
    """Raised when a required dependency is missing."""


class GitHubAPIError(MaxReviewError):
    """Raised when GitHub API interactions fail."""


class DockerError(MaxReviewError):
    """Raised when Docker operations fail."""


class ReviewError(MaxReviewError):
    """Raised when review processing fails."""


class ValidationError(MaxReviewError):
    """Raised when validation fails."""
