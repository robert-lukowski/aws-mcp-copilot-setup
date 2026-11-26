# AWS MCP Copilot Setup

An interactive Windows setup assistant for **AWS MCP + GitHub Copilot CLI**, using IAM Identity Center profiles and SigV4 authentication.

Select two or more AWS profiles, verify the accounts, and let setup configure the local proxy. Missing tools can be installed through WinGet after confirmation. Existing MCP servers are preserved and the managed entry can be rolled back.

**Status: community beta, v0.2.1.** Offline tests cover configuration, prerequisites and workflow behavior. The installer still needs an end-to-end Windows pilot; see [validation results](TEST_RESULTS.txt). This is an independent community project, not an official AWS or GitHub product.

This installs/reuses the AWS MCP Proxy locally, selects two or more AWS profiles and configures Copilot CLI to launch the proxy executable directly. It uses proxy package `2.0.0` and a Copilot server `timeout` of `120000` milliseconds by default. It does not install Docker, switch to OAuth or configure VS Code Chat.

## Quick start

1. Download this repository using **Code → Download ZIP** (or clone it), then extract the **entire ZIP** into a local directory.
2. Close existing Copilot CLI sessions.
3. Double-click **setup.bat**, choose **1** and follow the prompts.
4. By default, choose two profiles. For 3, 4, 5 or more, add entries to `profiles` in `team-config.json` before starting setup (see below). Choose each profile when prompted. Use any existing profile names, such as `sandbox` and `production`, or `readonly` and `operator`; they do not need to be renamed. The suggested names for new profiles are `profile-1` and `profile-2`.
5. Complete SSO in your own browser if required. Verify the account and role shown for each profile. The first selected profile is the default.
6. Confirm installation/configuration. Reopen Copilot CLI in your usual project and check `/mcp`.
7. Use the prompt printed by setup to check all selected identities **through MCP**.

Setup first reuses installed tools and offers to install only missing prerequisites through WinGet. It then reuses existing profiles. If a profile is missing, choose **N** to open the AWS CLI SSO configuration wizard. The wizard lets the user choose their assigned account and role. It may open a browser. Separate SSO portals/sessions are supported by configuring each profile through the wizard. Administrator access is not a prerequisite.

The package intentionally does not bundle account IDs, corporate SSO addresses or personal paths. An administrator may populate `team-config.json` before distributing an internal copy.

## Prerequisites

- Windows with **PowerShell 7.2 or later** (`pwsh`) for the main installer. If PowerShell 7 is missing, the BAT runs a small Windows PowerShell 5.1 bootstrap to offer its installation through WinGet.
- AWS CLI **v2**, `uv`, and GitHub Copilot CLI. Setup offers WinGet installation if they are missing.
- Copilot access for the user. GitHub/Copilot sign-in is separate from AWS SSO; run `copilot login` if needed.
- Existing IAM Identity Center assignments to the intended accounts and roles.
- Network access required by AWS SSO, AWS MCP and the package sources used by `uv`.

Official installation instructions:

- [PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [uv](https://docs.astral.sh/uv/getting-started/installation/)
- [Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)

### Optional prerequisite installation (new in 0.2.0)

Setup lists missing programs and asks once before installing them from the explicit `winget` source:

| Tool | WinGet package ID |
|---|---|
| AWS CLI v2 | `Amazon.AWSCLI` |
| GitHub Copilot CLI | `GitHub.Copilot` |
| uv | `astral-sh.uv` |
| PowerShell 7 (bootstrap only) | `Microsoft.PowerShell` |

The command uses `--exact --source winget --no-upgrade --interactive`. License/source prompts remain visible. The requested package version is the current stable version available in that source; proxy remains pinned separately to `2.0.0`. Existing tools are not automatically upgraded, and an existing npm Copilot installation is reused instead of adding a WinGet copy. If a detected executable is broken or AWS CLI is v1, setup stops for manual correction rather than replacing it.

Installation is offered only in **Setup** mode. Check/Login do not install missing prerequisites. On machines without PowerShell 7, the bootstrap must install it before any menu can run; that also requires confirmation. An existing PowerShell older than 7.2 is not automatically upgraded.

Some packages, including AWS CLI/PowerShell system installers, may require Windows administrator approval. The BAT itself does not elevate. No policy bypass, forced retries, forced reboot or alternate installer source is used. If WinGet is missing/blocked, use Company Portal/Software Center or your IT team. Failed or cancelled installations stop setup before MCP configuration changes; packages installed earlier in the attempt remain installed.

After an installation, setup refreshes **only the current process PATH**, re-resolves the executable, and checks tool versions before continuing. Reopen the terminal or restart Windows if the package installer requests it. Rollback restores MCP configuration only; it does not uninstall prerequisite packages.

Scripts must be permitted by your organization's execution policy. `setup.bat` does **not** use `ExecutionPolicy Bypass`, change policy, disable certificate checks or modify antivirus settings. Use your approved script signing/deployment process if execution is blocked. These scripts are not Authenticode-signed.

## Menu and commands

| Mode | Action |
|---|---|
| 1 / Setup | Select or create profiles, check identities, install/reuse proxy, back up and merge MCP configuration |
| 2 / Check | Inspect installed tools and local MCP configuration; does not log in, call AWS or start MCP |
| 3 / Login | Call STS for configured profiles, offer SSO login on failure, report account/ARN |
| 4 / Rollback | Restore only a server entry managed by a previous setup run |

Mode 3 displays the actual identities; it does not re-confirm the profile-to-account mapping against team defaults. Use Setup to enforce the configured expected account IDs again.

From PowerShell 7, optional direct commands are:

```powershell
.\setup.ps1 -Mode Setup
.\setup.ps1 -Mode Check
.\setup.ps1 -Mode Login
.\setup.ps1 -Mode Rollback
```

No `copilot -p` invocation or paid AI prompt is run automatically. Version checks invoke `copilot --version`; they do not prove Copilot authentication or MCP connectivity.

## What to set once for the team

Edit `team-config.json` before distributing the package:

| Field | Meaning / where to find it |
|---|---|
| `serverName` | Defaults to `aws-mcp`. Use another name if an unrelated remote/OAuth entry already uses this name. |
| `proxyVersion` | Exact approved package version; default `2.0.0`. Avoid `latest` for a tested rollout. |
| `timeoutMs` | Copilot server budget; default `120000`. This is not proof of a fix for the internal discovery probe. |
| `mcpRegion` | Supported AWS MCP endpoint region; default `eu-central-1`. |
| `defaultAwsRegion` | Default AWS operation region; may differ from the endpoint region. |
| `ssoStartUrlHint` | Optional corporate AWS access portal URL, supplied by your cloud team. Displayed as a wizard hint only. |
| `ssoRegionHint` | Identity Center directory region, not necessarily the resource region. Displayed as a hint. |
| `profiles[].label` | Display label in setup; defaults to `Profile 1` and `Profile 2`. Customize freely. |
| `profiles[].suggestedName` | Suggested local profile name; users can choose an existing alternative. |
| `profiles[].expectedAccountId` | Optional 12-digit ID from the AWS access portal/account inventory. Wrong identities stop setup. Blank means the user must confirm the mapping. |

The JSON intentionally has blank account IDs and no assumed permission-set name. This installer supports two or more distinct profile names. They may refer to different accounts or different roles in the same account. Names with whitespace are not accepted because the proxy profile allowlist is whitespace-separated.

The first selected profile is the default when an MCP call omits `aws_profile`. Always name the target account/profile in agent tasks. MCP configuration does not reduce or expand IAM permissions; `tools: ["*"]` on a new entry does not imply read-only access. Existing `tools` restrictions are retained.

## Adding more profiles later

### Using the installer

The default `team-config.json` contains two profile templates. To select three, four, five or more profiles, add entries to its `profiles` array. For example, replace that array with:

```json
"profiles": [
  { "label": "Profile 1", "suggestedName": "profile-1", "expectedAccountId": "" },
  { "label": "Profile 2", "suggestedName": "profile-2", "expectedAccountId": "" },
  { "label": "Profile 3", "suggestedName": "profile-3", "expectedAccountId": "" },
  { "label": "Profile 4", "suggestedName": "profile-4", "expectedAccountId": "" },
  { "label": "Profile 5", "suggestedName": "profile-5", "expectedAccountId": "" }
]
```

This is a JSON fragment, not a complete file. Keep the other fields in `team-config.json`. Remove unused entries for a three- or four-profile setup. Labels and suggested names can be customized; setup still lets you select existing names.

Close Copilot CLI, run `setup.bat` and choose **1 (Setup)**. Select every profile you want to keep, including the existing ones. Setup verifies every identity, backs up the MCP configuration and writes the complete allowlist. The first selected profile remains the default.

### Editing an existing MCP configuration manually

1. Configure a missing profile with `aws configure sso --profile profile-3`, or choose one from `aws configure list-profiles`.
2. Log in when needed with `aws sso login --profile profile-3`. Run `aws sts get-caller-identity --profile profile-3` and verify its account and role. Repeat for each additional profile. Substitute your own profile names.
3. Close Copilot CLI and make a backup of its `mcp-config.json` (normally `%USERPROFILE%\.copilot\mcp-config.json`, or inside your configured `COPILOT_HOME`).
4. In the existing `mcpServers` → `aws-mcp` → `env` object, update only this value, retaining every profile you want available:

```json
"AWS_MCP_PROXY_PROFILES": "profile-1 profile-2 profile-3 profile-4 profile-5"
```

Use the actual server name if you customized it. Separate names with spaces, not commas; do not duplicate names. Keep other environment variables, command, args, timeout and tool restrictions intact. The first name is the default when a call omits `aws_profile`. Adding a profile does not grant IAM permissions.

5. Start a fresh Copilot CLI session so the proxy loads the new allowlist. Check `/mcp`, then ask it to call STS GetCallerIdentity **through MCP** for each listed profile using explicit `aws_profile` values. AWS CLI STS success alone does not verify MCP.

If you use the installer again, update `team-config.json` to include all profiles you want to retain; Setup writes the profiles selected during that run. Manual edits also cause an older installer rollback to refuse overwriting the modified entry. Use your manual backup to undo a manual change.

## Changes and rollback

Setup performs the following local work:

- Installs/reuses `mcp-proxy-for-aws-cli==2.0.0` with `uv tool install --compile-bytecode`. It may download packages and a Python runtime through `uv`. A different existing proxy version prompts before attempting replacement; no `--force` retry is used.
- Obtains the executable directory from `uv tool dir --bin`. No personal installation path is hard-coded.
- Updates only the named entry inside `mcpServers` in `%USERPROFILE%\.copilot\mcp-config.json`, or the directory selected by `COPILOT_HOME`.
- Sets direct execution, the regional endpoint, metadata region, profile allowlist and timeout. Other servers/root settings and existing local entry settings are preserved. The managed command and standard proxy arguments are replaced. Custom proxy flags or metadata and remote/auth-specific entries are refused rather than silently discarded; use a different `serverName` or migrate them manually.
- Uses UTF-8 without BOM and an atomic same-directory replacement; detects a changed file before writing. Invalid JSON stops setup. Formatting/comments are not preserved by JSON serialization; keep a standard JSON file.
- If `AWS_CONFIG_FILE` or `AWS_SHARED_CREDENTIALS_FILE` is explicitly set in the launching environment, it is used for both verification and MCP. Otherwise existing overrides on the managed entry are used. Overrides must be literal absolute paths to existing files.
- SSO login and STS may refresh the AWS cache. New profiles are created only through the official AWS wizard, with an AWS config backup if one existed.

Before an MCP write, setup stores a backup and rollback manifest under:

```text
%LOCALAPPDATA%\AwsMcpSetup\backups\<unique-run-id>\
```

These are **private local backups**. They can contain existing configuration from other MCP servers; do not publish them or put them in your repository. They inherit permissions from your user-local directory; the installer does not change ACLs.

Rollback restores only the affected server entry and keeps unrelated later edits. If the managed entry itself changed after installation, rollback refuses to overwrite it; compare backups manually. When setup created the entry, rollback removes that entry, leaving the config file in place. It does not uninstall proxy/Python packages, remove AWS profiles, restore the AWS config or delete SSO cache. A separate pre-rollback backup is also created.

Repeated Setup with the same effective configuration does not duplicate entries or write redundant MCP backups. It still asks you to select and verify profiles.

## Final verification in Copilot

The installer uses AWS CLI STS to verify credentials and account mapping. **That is not an MCP test.** Reopen Copilot and check `/mcp`. Once connected, use a prompt such as the following, replacing `profile-1` and `profile-2` with your selected names:

> Use only MCP aws-mcp. Call STS GetCallerIdentity separately with aws_profile=profile-1 and aws_profile=profile-2. Return account and ARN for each. Do not use shell or AWS CLI. Do not modify AWS resources.

Substitute the actual server/profile names. Normal Copilot usage may be billed for this prompt.

Before team rollout, verify two fresh CLI starts, a workstation reboot and a second workstation. Test with the roles actually assigned to developers; successful authentication alone does not establish permission for every AWS service.

## Troubleshooting

| Symptom | Next action |
|---|---|
| BAT closes or script is blocked | Run `pwsh -NoProfile -File .\setup.ps1` from a terminal to see the error. Follow company script-trust policy; do not bypass it. |
| Tool not found | Choose Setup to install missing prerequisites via WinGet. If WinGet is blocked/missing, use your approved company channel. Existing tools are not automatically upgraded. |
| Profile missing | Choose N in Setup and use the AWS SSO wizard. Browser-only SSO does not create a local CLI profile. |
| STS fails | Review the profile, connectivity and SSO assignment. Setup offers browser login, then retries STS once. It does not assume every failure is token expiry. |
| Wrong account | Stop; correct your profile or the team mapping. Do not bypass the mismatch. |
| Existing custom proxy flags or metadata | Use a different `serverName` or migrate the entry manually; setup refuses to remove custom restrictions. |
| Existing remote/OAuth `aws-mcp` entry | Choose a new `serverName` or intentionally migrate that entry outside this installer. |
| `-32022` during MCP startup | Check the actual Copilot version, direct proxy command and `timeout: 120000`. Preserve the log; no automatic downgrade, dependency patching or DEBUG workaround is applied. |
| Green MCP status but operations fail | Check the requested `aws_profile`, operation region and IAM authorization. |
| Re-running setup produces a conflict | Close other config editors/CLI sessions, review the current file and retry. |

Direct proxy execution plus a 120-second budget restored connectivity in the original Windows pilot. The cause of the intermittent `-32022` error was **not conclusively established**. This package standardizes that observed configuration; it cannot guarantee that all client/proxy compatibility issues are fixed.

An exact proxy version does **not** freeze all transitive Python dependencies. The original pilot used Copilot CLI `1.0.115`, proxy `2.0.0`, Python MCP SDK `2.3.0` and FastMCP `4.2.0`. Setup prints the actual CLI/proxy versions but does not automatically downgrade or pin the Copilot installation. A fully locked dependency build and organization-wide package deployment are possible later enhancements.

### Fixed in 0.2.1: SSO login succeeded but Account property was missing

AWS CLI login/wizard output could leak into function return values and cause an `Account` property error after successful browser login. Version 0.2.1 routes interactive CLI output to the console separately from returned identities, profile names and proxy paths. Download the updated package and repeat option 3; do not delete existing AWS profiles or MCP configuration.

## Included files and tests

- `setup.bat`: double-click launcher; no execution-policy override.
- `bootstrap.ps1`: Windows PowerShell 5.1 bootstrap for missing PowerShell 7.
- `prerequisites.ps1`: detection, WinGet installation and process PATH refresh.
- `setup.ps1`: interactive setup/check/login/rollback.
- `core.ps1`: configuration merge, path resolution and guarded write helpers.
- `team-config.json`: non-secret team defaults.
- `tests/core.tests.ps1`: offline tests of merge, rollback, validation and file writes.
- `tests/workflow.tests.ps1`: setup/rollback workflow tests with external tools mocked.
- `tests/prerequisites.tests.ps1`: missing/existing tool, install-failure, refusal and reboot handling tests.
- `TEST_RESULTS.txt`: verification evidence and limits.

Run offline tests with:

```powershell
pwsh -NoProfile -File .\tests\core.tests.ps1
pwsh -NoProfile -File .\tests\workflow.tests.ps1
pwsh -NoProfile -File .\tests\prerequisites.tests.ps1
pwsh -NoProfile -File .\tests\native-output.tests.ps1
```

The code was tested with PowerShell 7 on Linux for syntax and configuration behavior. It has **not been run end-to-end on a Windows workstation with corporate SSO**. Test this pilot package on one workstation before sharing it broadly.

## Contributing and license

Bug reports and small improvements are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for test instructions and the Windows validation checklist. Include sanitized version/error information; never upload credentials, SSO cache, private configuration or unredacted logs.

The setup scripts are licensed under [MIT](LICENSE). AWS CLI, AWS MCP Proxy, GitHub Copilot CLI, PowerShell, uv and their dependencies are separate projects under their respective licenses and terms. This repository distributes setup code, not those vendor binaries. Users supply their own AWS access and Copilot entitlement.

## References

- [AWS CLI SSO configuration](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)
- [uv tools](https://docs.astral.sh/uv/guides/tools/)
- [Copilot CLI configuration reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)
- [WinGet install options](https://learn.microsoft.com/en-us/windows/package-manager/winget/install)
- [AWS MCP Proxy releases](https://github.com/aws/mcp-proxy-for-aws/releases)
