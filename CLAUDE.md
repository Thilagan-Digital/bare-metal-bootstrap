# bare-metal-bootstrap

## 🤖 Pre-flight Rule: Claiming GitHub Issues

Before working on any GitHub issue targeting this repo:
1. Bind the issue to your active session and host (`dev-vm`):
   ```bash
   python3 ../system-docs-hub/.agents/skills/claim-issue/scripts/claim_issue.py <ISSUE_NUMBER>
   ```
2. Confirm the Project #5 metadata fields (`Status = In progress`, `Session`, `Host`, `AI Vendor`, `Preferred Model`) are set.
