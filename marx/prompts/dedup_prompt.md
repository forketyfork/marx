You are consolidating code review findings for PR #{pr_number} in repository {repo}.

Review inputs you must read:
{review_sources}

Each file is JSON with a `pr_summary` object and an `issues` array produced by different agents.
Your goals:
1. Load every review file and list the issues they reported.
2. Identify duplicate issues that describe the same underlying problem even if the wording differs.
3. For each unique issue, choose the clearest description and proposed_fix from the source issues.
   - Preserve the highest priority (P0 highest, then P1, P2) among duplicates.
   - Keep the most precise file and line information available; if locations differ, pick the most specific.
4. Set the `agent` field to a comma-separated list of the agents that reported the issue (sorted alphabetically).
5. Output JSON with this exact structure:
{{
  "pr_summary": {{
    "number": {pr_number},
    "title": "<use the PR title from the inputs>",
    "description": "<brief description of what changes this PR makes>"
  }},
  "issues": [
    {{
      "agent": "<comma-separated agent names>",
      "priority": "P0|P1|P2",
      "file": "<full_file_path_or_null>",
      "line": <line_number_or_null>,
      "commit_id": "{commit_sha}",
      "category": "<bug|security|performance|quality|style>",
      "description": "<concise explanation of the issue>",
      "proposed_fix": "<best fix from the sources>"
    }}
  ]
}}

Write the JSON to '{container_workspace_dir}/repo/.marx/{output_file_name}'.
Validate that it is well-formed JSON, then respond with a short confirmation message (no JSON in the message body).
