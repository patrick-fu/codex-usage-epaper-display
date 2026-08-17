# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- Create, read, comment on, label, and close issues with `gh issue`.
- Infer the repository from `git remote -v`.
- PRs as a request surface: no.
- When a skill says “publish to the issue tracker”, create a GitHub issue.
- When a skill says “fetch the relevant ticket”, read the issue and comments.

## Wayfinding operations

- The map is one issue labelled `wayfinder:map`.
- Tickets are GitHub sub-issues, labelled `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`.
- Use native GitHub issue dependencies for blocking.
- The frontier is the map’s open, unblocked, unassigned child issues.
- Claim a ticket by assigning it before work.
- Resolve by commenting with the answer, closing it, then linking its gist from the map.
