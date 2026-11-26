#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Menu','Setup','Check','Login','Rollback')][string]$Mode = 'Menu',
    [string]$TeamConfig = (Join-Path $PSScriptRoot 'team-config.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'core.ps1')
. (Join-Path $PSScriptRoot 'prerequisites.ps1')

function Confirm([string]$Question, [bool]$Default = $false) {
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer -match '^(y|yes)$'
}

function Capture([string]$Exe, [string[]]$Arguments) {
    # No transcripts, environment dumps or raw stderr saved to disk.
    $lines = @(& $Exe @Arguments 2>$null)
    return @{ Code = $LASTEXITCODE; Text = ($lines -join "`n") }
}

function Find-Tools([switch]$InstallMissing) {
    $script:Aws = Find-Dependency 'Amazon.AWSCLI'
    $script:Uv = Find-Dependency 'astral-sh.uv'
    $script:Copilot = Find-Dependency 'GitHub.Copilot'
    $missing = @()
    foreach ($item in @(@('AWS CLI', $script:Aws, 'Amazon.AWSCLI'), @('uv', $script:Uv, 'astral-sh.uv'), @('Copilot CLI', $script:Copilot, 'GitHub.Copilot'))) {
        if ($item[1]) { Write-Host ("[FOUND] {0}: {1}" -f $item[0],$item[1]) }
        else { Write-Host "[MISSING] $($item[0])" -ForegroundColor Yellow; $missing += $item[2] }
    }
    if ($missing.Count) {
        if (-not $InstallMissing) {
            Write-Host 'Choose Setup to install missing tools, or use your approved software channel.'
            return $false
        }
        Install-MissingDependencies $missing
        $script:Aws = Find-Dependency 'Amazon.AWSCLI'
        $script:Uv = Find-Dependency 'astral-sh.uv'
        $script:Copilot = Find-Dependency 'GitHub.Copilot'
        if (-not $script:Aws -or -not $script:Uv -or -not $script:Copilot) { throw 'A required tool is still unavailable after installation.' }
    }
    $version = Capture $script:Aws @('--version')
    if ($version.Code -ne 0 -or $version.Text -notmatch 'aws-cli/2\.') { throw 'The detected AWS CLI is not a working v2 installation. Resolve its version/PATH through your approved software channel; no automatic upgrade was attempted.' }
    Write-Host $version.Text
    foreach ($exe in @($script:Uv,$script:Copilot)) {
        $r = Capture $exe @('--version')
        if ($r.Code -ne 0) { throw "Could not run --version for $exe" }
        Write-Host (($r.Text -split "`n")[0])
    }
    return $true
}

function Read-Mcp {
    if (Test-Path -LiteralPath $script:ConfigPath) { return ,(Read-JsonMap $script:ConfigPath) }
    return ,([ordered]@{})
}

function Get-Profiles {
    $r = Capture $script:Aws @('configure','list-profiles')
    if ($r.Code -ne 0) { throw 'AWS CLI could not list profiles. Run aws configure list-profiles to inspect the error.' }
    return @($r.Text -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Get-AwsConfigPath {
    if ($env:AWS_CONFIG_FILE) { return [IO.Path]::GetFullPath($env:AWS_CONFIG_FILE) }
    return Join-Path $env:USERPROFILE '.aws\config'
}

function Select-Profile($Template) {
    while ($true) {
        $available = @(Get-Profiles)
        Write-Host "`nSelect $($Template.label) profile."
        for ($i = 0; $i -lt $available.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i+1), $available[$i]) }
        Write-Host '  N. Create a NEW SSO profile using the AWS wizard'
        $hint = if ($available -contains $Template.suggestedName) { "; Enter = $($Template.suggestedName)" } else { '' }
        $choice = Read-Host "Number, exact profile name, or N$hint"
        if (-not $choice -and $hint) { return $Template.suggestedName }
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $available.Count) {
            $name = $available[$number-1]; Assert-ProfileName $name; return $name
        }
        if ($available -contains $choice) { Assert-ProfileName $choice; return $choice }
        if ($choice -ieq 'n') {
            $name = Read-Host "New profile name [default: $($Template.suggestedName)]"
            if (-not $name) { $name = $Template.suggestedName }
            Assert-ProfileName $name
            if ($available -contains $name) { Write-Host 'That profile exists; select it instead.'; continue }
            if ($script:Team.ssoStartUrlHint) { Write-Host "SSO portal hint: $($script:Team.ssoStartUrlHint)" }
            Write-Host "SSO region hint: $($script:Team.ssoRegionHint). Use your assigned account and permission set."
            Write-Host 'The AWS wizard may open your browser and writes AWS config/cache. Use the same SSO session for the profiles if appropriate.'
            $awsConfig = Get-AwsConfigPath
            if (Test-Path -LiteralPath $awsConfig) {
                $backup = $awsConfig + '.before-mcp-setup-' + [guid]::NewGuid().ToString('N') + '.bak'
                Copy-Item -LiteralPath $awsConfig -Destination $backup
                Write-Host "AWS config backup: $backup"
            }
            & $script:Aws configure sso --profile $name | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'SSO wizard did not complete. Existing MCP configuration has not been changed.' }
            if (@(Get-Profiles) -notcontains $name) { throw 'The wizard did not create the requested profile.' }
            return $name
        }
        Write-Host 'Choose a listed profile or N.' -ForegroundColor Yellow
    }
}

function Test-Identity([string]$Profile, [bool]$AllowLogin) {
    $requestArgs = @('sts','get-caller-identity','--profile',$Profile,'--output','json','--no-cli-pager','--cli-connect-timeout','15','--cli-read-timeout','30')
    $r = Capture $script:Aws $requestArgs
    if ($r.Code -ne 0 -and $AllowLogin) {
        Write-Host "STS did not succeed for '$Profile'. The cause may be SSO expiry, connectivity or permissions."
        if (Confirm "Run browser SSO login for '$Profile'?" $true) {
            & $script:Aws sso login --profile $Profile --no-cli-pager | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'SSO login failed. Resolve it in AWS CLI before continuing.' }
            $r = Capture $script:Aws $requestArgs
        }
    }
    if ($r.Code -ne 0) { throw "STS failed for '$Profile'. Run aws sts get-caller-identity --profile $Profile to inspect locally; MCP config is not validated." }
    $identity = $r.Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($identity -isnot [System.Collections.IDictionary] -or -not $identity.Contains('Account') -or -not $identity.Contains('Arn') -or $identity.Account -notmatch '^\d{12}$' -or -not $identity.Arn) { throw 'Unexpected STS response.' }
    return ,$identity
}

function Ensure-Proxy {
    $r = Capture $script:Uv @('tool','dir','--bin')
    if ($r.Code -ne 0 -or -not $r.Text.Trim()) { throw 'Cannot determine uv tool executable directory.' }
    $proxy = Join-Path $r.Text.Trim() 'mcp-proxy-for-aws-cli.exe'
    $wanted = $script:Team.proxyVersion
    if (Test-Path -LiteralPath $proxy) {
        $help = Capture $proxy @('--help')
        if ($help.Code -eq 0 -and $help.Text -match ('MCP Proxy for AWS v' + [regex]::Escape($wanted) + '(\s|$)')) {
            Write-Host "[OK] Proxy $wanted already installed: $proxy"
            return $proxy
        }
        if (-not (Confirm "Installed proxy is not verified as $wanted. Replace the uv-managed tool with $wanted?")) { throw 'Proxy installation cancelled.' }
    }
    Write-Host "Installing proxy $wanted (first run and bytecode compilation can take several minutes)."
    & $script:Uv tool install --compile-bytecode "mcp-proxy-for-aws-cli==$wanted" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Proxy install failed. No force/reinstall attempted; inspect the uv message above.' }
    if (-not (Test-Path -LiteralPath $proxy)) { throw "Expected executable not found: $proxy" }
    $help = Capture $proxy @('--help')
    if ($help.Code -ne 0 -or $help.Text -notmatch ('MCP Proxy for AWS v' + [regex]::Escape($wanted) + '(\s|$)')) { throw 'Proxy version verification failed.' }
    return $proxy
}

function Show-FinalPrompt([string[]]$Profiles) {
    Write-Host "`nNEXT: Start a fresh Copilot CLI session in your usual project and open /mcp." -ForegroundColor Cyan
    Write-Host 'No paid prompt or Copilot session has been launched by this installer.'
    Write-Host 'Once connected, paste this prompt (normal Copilot usage charges may apply):'
    Write-Host "Use only MCP $($script:Team.serverName). Call STS GetCallerIdentity separately for every profile in this list, setting aws_profile explicitly: $($Profiles -join ', '). Return account and ARN for each. Do not use shell or AWS CLI. Do not modify AWS resources."
    Write-Host 'Setup/STS success does NOT prove that Copilot MCP negotiation works.' -ForegroundColor Yellow
}

function Run-Setup {
    if (-not (Find-Tools -InstallMissing)) { throw 'Required tools are missing.' }
    Write-Host "`nClose running Copilot CLI sessions before configuration changes."
    if (-not (Confirm 'Are the sessions closed?' $true)) { return }
    $fingerprint = Get-FileFingerprint $script:ConfigPath
    $original = Read-Mcp
    $processPaths = @{}
    foreach ($key in @('AWS_CONFIG_FILE','AWS_SHARED_CREDENTIALS_FILE')) {
        $processPaths[$key] = [Environment]::GetEnvironmentVariable($key)
    }
    $effectivePaths = Resolve-AwsPaths $original $script:Team.serverName $processPaths
    foreach ($key in $effectivePaths.Keys) {
        if (-not (Test-Path -LiteralPath $effectivePaths[$key] -PathType Leaf)) { throw "File specified by $key does not exist." }
        Write-Host "AWS configuration override used for BOTH verification and MCP: $key=$($effectivePaths[$key])"
        [Environment]::SetEnvironmentVariable($key,$effectivePaths[$key])
    }
    $selected = @()
    foreach ($template in $script:Team.profiles) {
        $profile = Select-Profile $template
        if ($selected -contains $profile) { throw 'Choose distinct profile names.' }
        $identity = Test-Identity $profile $true
        Write-Host "$($template.label): profile=$profile; account=$($identity.Account)"
        Write-Host "Role/session ARN: $($identity.Arn)"
        if ($template.expectedAccountId -and $template.expectedAccountId -ne $identity.Account) {
            throw "Account mismatch for $($template.label). Expected $($template.expectedAccountId); received $($identity.Account)."
        }
        if (-not $template.expectedAccountId -and -not (Confirm "Confirm this is the intended $($template.label) account")) { throw 'Account mapping not confirmed.' }
        $selected += $profile
    }
    Write-Host "`nDefault profile: $($selected[0]). Available profiles: $($selected -join ', ')."
    Write-Host "Endpoint: https://aws-mcp.$($script:Team.mcpRegion).api.aws/mcp"
    Write-Host "Proxy: $($script:Team.proxyVersion); timeout: $($script:Team.timeoutMs) ms."
    Write-Host "Target: $script:ConfigPath (only '$($script:Team.serverName)' is managed)."
    Write-Host 'IAM permissions remain those of your selected roles. A read-only prompt is not an IAM restriction.'
    if (-not (Confirm 'Install/reuse proxy and apply this MCP configuration?' $true)) { return }
    $proxy = Ensure-Proxy
    $next = New-McpConfig $original $script:Team.serverName $proxy $selected $script:Team
    foreach ($key in @('AWS_CONFIG_FILE','AWS_SHARED_CREDENTIALS_FILE')) {
        $path = [Environment]::GetEnvironmentVariable($key)
        if ($path) { $next.mcpServers[$script:Team.serverName].env[$key] = [IO.Path]::GetFullPath($path) }
    }
    if ((Get-EntryHash $original) -eq (Get-EntryHash $next)) {
        Write-Host '[OK] MCP configuration already matches; no new backup or write needed.'
        Show-FinalPrompt $selected; return
    }
    $runDir = Join-Path $script:StateRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    [IO.Directory]::CreateDirectory($runDir) | Out-Null
    if ((Get-FileFingerprint $script:ConfigPath) -ne $fingerprint) { throw 'MCP config changed during setup. Rerun; no overwrite performed.' }
    if ($fingerprint -ne 'MISSING') { Copy-Item -LiteralPath $script:ConfigPath -Destination (Join-Path $runDir 'mcp-config.before.json') }
    $hadEntry = $original.Contains('mcpServers') -and $original.mcpServers.Contains($script:Team.serverName)
    $before = if ($hadEntry) { $original.mcpServers[$script:Team.serverName] } else { $null }
    $manifest = [ordered]@{
        schemaVersion=1; configPath=$script:ConfigPath; serverName=$script:Team.serverName
        beforeEntryExisted=$hadEntry; beforeEntry=$before
        afterEntryHash=(Get-EntryHash $next.mcpServers[$script:Team.serverName])
        status='prepared'; createdUtc=[DateTime]::UtcNow.ToString('o')
    }
    $manifestPath = Join-Path $runDir 'manifest.json'
    Write-JsonAtomic $manifestPath $manifest 'MISSING'
    Write-JsonAtomic $script:ConfigPath $next $fingerprint
    $manifest.status = 'applied'
    Write-JsonAtomic $manifestPath $manifest (Get-FileFingerprint $manifestPath)
    Write-Host "[OK] Configuration saved. Rollback record: $manifestPath" -ForegroundColor Green
    Show-FinalPrompt $selected
}

function Get-ConfiguredProfiles {
    $config = Read-Mcp
    $name = $script:Team.serverName
    if (-not $config.Contains('mcpServers') -or -not $config.mcpServers.Contains($name)) { throw 'Server not configured yet; run Setup first.' }
    $entry = $config.mcpServers[$name]
    if (-not $entry.Contains('env') -or -not $entry.env.Contains('AWS_MCP_PROXY_PROFILES')) { throw 'Server has no profile allowlist.' }
    $profiles = @($entry.env.AWS_MCP_PROXY_PROFILES -split '\s+' | Where-Object { $_ })
    foreach ($p in $profiles) { Assert-ProfileName $p }
    return $profiles
}

function Run-Check([bool]$Login) {
    if (-not (Find-Tools)) { throw 'Required tools are missing.' }
    $config = Read-Mcp
    $profiles = @(Get-ConfiguredProfiles)
    $entry = $config.mcpServers[$script:Team.serverName]
    Write-Host "`nConfig: $script:ConfigPath"
    Write-Host "Command: $($entry.command)"
    if (-not (Test-Path -LiteralPath $entry.command -PathType Leaf)) { throw 'Configured executable does not exist.' }
    if ($entry.Contains('timeout')) { Write-Host "Timeout: $($entry.timeout) ms" }
    Write-Host "Profile allowlist: $($profiles -join ', ')"
    if ($Login) {
        # Honor custom paths from the MCP entry so CLI validation uses the same files.
        $saved = @{}
        try {
            foreach ($key in @('AWS_CONFIG_FILE','AWS_SHARED_CREDENTIALS_FILE')) {
                $saved[$key] = [Environment]::GetEnvironmentVariable($key)
                if ($entry.env.Contains($key)) { [Environment]::SetEnvironmentVariable($key, $entry.env[$key]) }
            }
            foreach ($p in $profiles) {
                $id = Test-Identity $p $true
                Write-Host "[STS OK] $p -> $($id.Account) | $($id.Arn)"
            }
        } finally {
            foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
        }
    } else { Write-Host 'Local check only: no AWS login, API call or MCP connection attempted.' }
    Show-FinalPrompt $profiles
}

function Run-Rollback {
    $records = @()
    if (Test-Path -LiteralPath $script:StateRoot) {
        foreach ($file in (Get-ChildItem -LiteralPath $script:StateRoot -Filter manifest.json -Recurse -File | Sort-Object FullName -Descending)) {
            try {
                $m = Read-JsonMap $file.FullName
                if ($m.status -in @('applied','prepared') -and $m.configPath -eq $script:ConfigPath) { $records += @{ Path=$file.FullName; Data=$m } }
            } catch { Write-Warning 'Skipped an unreadable rollback record.' }
        }
    }
    if (-not $records.Count) { Write-Host 'No rollback records for this Copilot config.'; return }
    for ($i=0; $i -lt $records.Count; $i++) { Write-Host ("{0}. {1} / {2}" -f ($i+1),$records[$i].Data.createdUtc,$records[$i].Data.serverName) }
    $choice=0
    if (-not [int]::TryParse((Read-Host 'Select rollback number (or Enter to cancel)'),[ref]$choice) -or $choice -lt 1 -or $choice -gt $records.Count) { return }
    $record = $records[$choice-1]; $m = $record.Data
    $fingerprint = Get-FileFingerprint $script:ConfigPath
    $restored = Restore-McpEntry (Read-Mcp) $m
    if (-not (Confirm "Restore only '$($m.serverName)'? Other server entries will be preserved.")) { return }
    $backup = Join-Path (Split-Path -Parent $record.Path) ('before-rollback-' + [guid]::NewGuid().ToString('N') + '.json')
    Copy-Item -LiteralPath $script:ConfigPath -Destination $backup
    Write-JsonAtomic $script:ConfigPath $restored $fingerprint
    $m.status='rolledBack'
    Write-JsonAtomic $record.Path $m (Get-FileFingerprint $record.Path)
    Write-Host '[OK] MCP entry restored. Restart Copilot. Proxy installation and AWS profiles were not removed.'
}

$initialPaths = @{}
foreach ($key in @('AWS_CONFIG_FILE','AWS_SHARED_CREDENTIALS_FILE')) {
    $initialPaths[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    if (-not $IsWindows) { throw 'This launcher targets Windows. Core configuration tests can run cross-platform.' }
    $script:Team = Read-JsonMap $TeamConfig
    Assert-TeamConfig $script:Team
    $copilotDir = if ($env:COPILOT_HOME) { [IO.Path]::GetFullPath($env:COPILOT_HOME) } else { Join-Path $env:USERPROFILE '.copilot' }
    $script:ConfigPath = Join-Path $copilotDir 'mcp-config.json'
    $script:StateRoot = Join-Path $env:LOCALAPPDATA 'AwsMcpSetup\backups'
    Write-Host "`nAWS MCP / Copilot CLI setup - pilot 0.2.1" -ForegroundColor Cyan
    Write-Host 'Direct proxy executable; tested package version; 120-second connection budget by default.'
    if ($Mode -eq 'Menu') {
        Write-Host "`n1. Set up MCP with AWS profiles`n2. Check local configuration (no AWS calls)`n3. Check AWS identities / log in if needed`n4. Roll back MCP configuration`n0. Exit"
        $Mode = switch (Read-Host 'Choose [1-4, 0]') { '1' {'Setup'} '2' {'Check'} '3' {'Login'} '4' {'Rollback'} default {'Exit'} }
    }
    switch ($Mode) {
        'Setup' { Run-Setup }
        'Check' { Run-Check $false }
        'Login' { Run-Check $true }
        'Rollback' { Run-Rollback }
    }
    exit 0
} catch {
    Write-Host "`n[STOPPED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'No automatic security-policy changes or forced retries were made. Installed packages, if any, remain installed. See README.md.'
    exit 1
} finally {
    foreach ($key in $initialPaths.Keys) { [Environment]::SetEnvironmentVariable($key,$initialPaths[$key]) }
}
