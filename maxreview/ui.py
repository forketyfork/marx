"""Terminal UI and output formatting using rich."""

from rich.console import Console
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.table import Table

console = Console()


def print_info(message: str) -> None:
    """Print an info message."""
    console.print(f"[cyan]ℹ️  {message}[/cyan]")


def print_success(message: str) -> None:
    """Print a success message."""
    console.print(f"[green]✅ {message}[/green]")


def print_error(message: str) -> None:
    """Print an error message."""
    console.print(f"[red]❌ {message}[/red]")


def print_warning(message: str) -> None:
    """Print a warning message."""
    console.print(f"[yellow]⚠️  {message}[/yellow]")


def print_header(message: str) -> None:
    """Print a header message."""
    console.print(f"\n[bold magenta]{message}[/bold magenta]\n")


def create_progress() -> Progress:
    """Create a progress bar for long-running operations."""
    return Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    )


def display_pr_table(prs: list[dict]) -> None:
    """Display a table of pull requests."""
    table = Table(title="Available PRs", show_header=True, header_style="bold blue")
    table.add_column("#", style="green", justify="right")
    table.add_column("PR", style="yellow")
    table.add_column("Title", style="bold")
    table.add_column("Author", style="cyan")
    table.add_column("Branch", style="magenta")
    table.add_column("Reviewers", style="blue")
    table.add_column("Lines", style="dim")

    for idx, pr in enumerate(prs, 1):
        table.add_row(
            str(idx),
            f"#{pr['number']}",
            pr["title"],
            pr["author"],
            pr["branch"],
            pr["reviewers"],
            f"+{pr['additions']} -{pr['deletions']}",
        )

    console.print(table)


def display_review_summary(
    pr_title: str,
    descriptions: list[dict[str, str]],
    p0_count: int,
    p1_count: int,
    p2_count: int,
    total_issues: int,
) -> None:
    """Display the review summary."""
    print_header("📋 PR Summary")
    console.print(f"[bold]Title:[/bold] {pr_title}\n")

    print_header("📝 Descriptions from Each AI Model")
    for desc in descriptions:
        agent = desc["agent"].upper()
        description = desc["description"]
        console.print(f"🤖 [bold magenta]{agent}[/bold magenta]: {description}")
    console.print()

    print_header(f"📊 Issues Found: {total_issues}")

    if total_issues == 0:
        print_success("No issues found! Code looks great! ✨")
        return

    console.print(f"[red bold]🔴 P0 (Critical):[/red bold] {p0_count}")
    console.print(f"[yellow bold]🟡 P1 (Important):[/yellow bold] {p1_count}")
    console.print(f"[blue bold]🔵 P2 (Suggestions):[/blue bold] {p2_count}")
    console.print()


def display_issue(issue: dict, priority_emoji: str) -> None:
    """Display a single issue."""
    agent = issue.get("agent", "unknown").upper()
    file_path = issue.get("file", "unknown")
    line = issue.get("line", "?")
    category = issue.get("category", "unspecified")
    description = issue.get("description", "No description")
    proposed_fix = issue.get("proposed_fix", "No fix suggested")

    panel_content = (
        f"🤖 Agent: [bold magenta]{agent}[/bold magenta]\n"
        f"📁 [bold cyan]{file_path}:{line}[/bold cyan]\n"
        f"🏷️  [bold]{category}[/bold]\n\n"
        f"[bold]Issue:[/bold] {description}\n\n"
        f"[bold green]💡 Fix:[/bold green] {proposed_fix}"
    )

    console.print(
        Panel(
            panel_content,
            border_style="dim",
            padding=(0, 1),
        )
    )


def confirm(prompt: str, default: bool = False) -> bool:
    """Ask for user confirmation."""
    default_str = "Y/n" if default else "y/N"
    response = console.input(f"[bold cyan]{prompt} [{default_str}]:[/bold cyan] ")
    if not response:
        return default
    return response.lower() in ("y", "yes")


def prompt_for_selection(max_value: int) -> int:
    """Prompt user to select from a numbered list."""
    while True:
        try:
            selection = console.input(f"[bold cyan]Select a PR [1-{max_value}]:[/bold cyan] ")
            value = int(selection)
            if 1 <= value <= max_value:
                return value
            print_error(f"Please enter a number between 1 and {max_value}")
        except ValueError:
            print_error("Please enter a valid number")
        except KeyboardInterrupt:
            raise
