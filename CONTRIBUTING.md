# Contributing

Keep changes small and explain the user problem they solve. Preserve existing MCP entries, AWS profile choices and user restrictions. Do not introduce automatic approval, policy bypasses or cloud resource changes into the installer.

## Offline checks

Run these from the repository root with PowerShell 7.2 or later:

```powershell
pwsh -NoProfile -File ./tests/core.tests.ps1
pwsh -NoProfile -File ./tests/workflow.tests.ps1
pwsh -NoProfile -File ./tests/prerequisites.tests.ps1
```

External AWS, WinGet, uv and Copilot operations in the workflow tests are mocked. Passing these tests is not proof that SSO or MCP works on a workstation.

## Windows pilot checklist

Use a test workstation and two AWS accounts you are authorized to access:

- Start with existing prerequisites, then separately test a machine missing prerequisites.
- Test an existing npm Copilot install; setup should not add another Copilot copy.
- Select existing profiles and, separately, configure new profiles with the AWS wizard.
- Confirm both STS identities and the displayed DEV/TEST mapping.
- Check that unrelated MCP servers and existing restrictions survive setup.
- Start Copilot twice, then repeat after a workstation restart.
- Verify both identities through MCP using the README prompt.
- Run setup again and exercise rollback; check unrelated later edits survive.
- Exercise installation refusal, unavailable WinGet and expired SSO.

Report OS, tool versions, the scenario and sanitized errors. Do not include account IDs, user ARNs, portal addresses, credentials, tokens, local backup files or complete debug logs in public issues.

## Scope

The first version supports Windows, Copilot CLI, SigV4 and exactly two profiles for two different AWS accounts. Additional clients, operating systems and dependency lock files are future work, not current features.
