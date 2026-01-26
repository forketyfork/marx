You are consolidating code review findings for PR #{pr_number} in repository {repo}.

Review inputs you must read:
{review_sources}

Each file is a structured text review with a PR summary header and repeated ISSUE blocks.
Your goals:
1. Load every review file and list the issues they reported.
2. Identify duplicate issues that describe the same underlying problem even if the wording differs.
3. For each unique issue, choose the clearest description and proposed_fix from the source issues.
   - Preserve the highest priority (P0 highest, then P1, P2) among duplicates.
   - Keep the most precise file and line information available; if locations differ, pick the most specific.
4. Set the `agent` field to a comma-separated list of the agents that reported the issue
   (sorted alphabetically).
5. Output the merged review using this exact text format:
PR_NUMBER: {pr_number}
PR_TITLE: "<use the PR title from the inputs>"
PR_DESCRIPTION:
  <brief description of what changes this PR makes>

--- ISSUE ---
agent: "<comma-separated agent names>"
priority: "P0|P1|P2"
path: "<repo-relative file path or null>"
line: <line_number_or_null>
commit_id: "{commit_sha}"
category: "<bug|security|performance|quality|style>"
description:
  <concise explanation of the issue>
proposed_fix:
  <best fix from the sources>

Write the output to '{container_workspace_dir}/repo/.marx/{output_file_name}'.
Re-open the file and verify it follows the format above, then respond with a short confirmation message.
