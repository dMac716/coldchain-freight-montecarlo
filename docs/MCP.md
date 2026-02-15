# MCP Configuration

This repository includes optional MCP configuration for GitHub Copilot agents.

## Purpose
MCP is used for GitHub operations that complement local development:
- repository browsing/search
- issue and PR inspection
- issue/PR creation and comments

## Configuration
- File: `.github/mcp.json`
- Server reference: `github/github-mcp-server` (official GitHub MCP server)
- Transport type: `stdio`
- Tool access: explicit allowlist via `tools` array

If your Copilot environment expects a different MCP config path/schema, adapt this file to that client while keeping the same least-privilege policy.

## Enablement
Typical requirements (depends on your Copilot environment):
- repo/org admin enabling MCP integration
- Docker runtime available for `stdio` server launch
- credentials/token scoped for only required repo actions

## Security
- Keep the tool allowlist minimal.
- Prefer read-only tools by default; include write tools only when needed.
- Do not store long-lived high-privilege tokens in repo files.

MCP is optional; the repository works without MCP enabled.
