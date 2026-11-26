# Pure configuration helpers. No external commands or changes on import.
Set-StrictMode -Version Latest

function Read-JsonMap([string]$Path) {
    $value = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop |
        ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    if ($value -isnot [System.Collections.IDictionary]) { throw "Expected a JSON object: $Path" }
    return ,$value
}

function Copy-JsonValue($Value) {
    return ,(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100 -Compress -WarningAction Stop) -AsHashtable -Depth 100)
}

function Get-TextHash([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-EntryHash($Entry) {
    return Get-TextHash (ConvertTo-Json -InputObject $Entry -Depth 100 -Compress -WarningAction Stop)
}

function Get-FileFingerprint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-ProfileName([string]$Name) {
    # Proxy allowlist is whitespace-separated. Limit names used by this installer.
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
        throw 'Profile names must use letters, digits, dots, underscores or hyphens, and start with a letter or digit.'
    }
}

function Resolve-AwsPaths($Original, [string]$ServerName, $ProcessPaths) {
    $resolved = [ordered]@{}
    foreach ($key in @('AWS_CONFIG_FILE','AWS_SHARED_CREDENTIALS_FILE')) {
        $value = $ProcessPaths[$key]
        if (-not $value -and $Original.Contains('mcpServers') -and
            $Original.mcpServers -is [System.Collections.IDictionary] -and $Original.mcpServers.Contains($ServerName)) {
            $entry = $Original.mcpServers[$ServerName]
            if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('env') -and
                $entry.env -is [System.Collections.IDictionary] -and $entry.env.Contains($key)) { $value = $entry.env[$key] }
        }
        if ($value) {
            if ($value -isnot [string] -or $value.Contains('$') -or $value.Contains('%') -or -not [IO.Path]::IsPathFullyQualified($value)) {
                throw "Use a literal absolute path for $key before running setup."
            }
            $resolved[$key] = $value
        }
    }
    return ,$resolved
}

function Assert-TeamConfig($Team) {
    foreach ($key in @('serverName','proxyVersion','timeoutMs','mcpRegion','defaultAwsRegion','ssoStartUrlHint','ssoRegionHint','profiles')) {
        if (-not $Team.Contains($key)) { throw "Missing team-config field: $key" }
    }
    if ($Team.serverName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { throw 'Invalid serverName.' }
    if ($Team.proxyVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Use an exact stable proxyVersion, not latest.' }
    foreach ($region in @($Team.mcpRegion, $Team.defaultAwsRegion, $Team.ssoRegionHint)) {
        if ($region -notmatch '^[a-z]{2}(-[a-z]+)+-\d+$') { throw "Invalid region: $region" }
    }
    if ($Team.timeoutMs -isnot [long] -and $Team.timeoutMs -isnot [int]) { throw 'timeoutMs must be an integer.' }
    if ($Team.timeoutMs -lt 60000 -or $Team.timeoutMs -gt 600000) { throw 'Use timeoutMs between 60000 and 600000.' }
    if (@($Team.profiles).Count -lt 2) { throw 'Configure at least two profiles.' }
    foreach ($item in $Team.profiles) {
        if (-not $item.label -or -not $item.suggestedName -or -not $item.Contains('expectedAccountId')) { throw 'Incomplete profile template.' }
        Assert-ProfileName $item.suggestedName
        if ($item.expectedAccountId -and $item.expectedAccountId -notmatch '^\d{12}$') { throw 'Expected account IDs must be blank or 12 digits.' }
    }
}

function Assert-ExistingProxyInvocation($Entry, [string]$ServerName) {
    # Replacing arbitrary args could silently remove --read-only or another
    # restriction. Migrate only the baseline invocations this installer knows.
    $message = "Existing '$ServerName' uses a custom or unrecognized proxy invocation. Its command and arguments were not replaced. Choose another serverName in team-config.json or migrate this entry manually, preserving all required flags and settings."
    if (-not $Entry.Contains('command') -or $Entry.command -isnot [string] -or
        -not $Entry.Contains('args') -or $Entry.args -isnot [array]) { throw $message }
    foreach ($argument in $Entry.args) { if ($argument -isnot [string]) { throw $message } }
    $offset = 0
    if ($Entry.command -match '(^|[\\/])uvx(\.exe)?$') {
        if ($Entry.args.Count -ne 4 -or
            $Entry.args[0] -cnotmatch '^mcp-proxy-for-aws-cli(?:(?:@(?:latest|\d+\.\d+\.\d+))|(?:==\d+\.\d+\.\d+))?$') { throw $message }
        $offset = 1
    } elseif ($Entry.command -match '(^|[\\/])mcp-proxy-for-aws-cli(\.exe)?$') {
        if ($Entry.args.Count -ne 3) { throw $message }
    } else { throw $message }
    if ($Entry.args[$offset] -cnotmatch '^https://aws-mcp\.[a-z]{2}(?:-[a-z]+)+-\d+\.api\.aws/mcp$' -or
        $Entry.args[$offset + 1] -cne '--metadata' -or
        $Entry.args[$offset + 2] -cnotmatch '^AWS_REGION=[a-z]{2}(?:-[a-z]+)+-\d+$') { throw $message }
}

function New-McpConfig($Original, [string]$ServerName, [string]$ProxyPath, [string[]]$Profiles, $Team) {
    if ($Profiles.Count -lt 2 -or @($Profiles | Sort-Object -Unique).Count -ne $Profiles.Count) { throw 'Choose at least two distinct profiles.' }
    foreach ($p in $Profiles) { Assert-ProfileName $p }
    $result = Copy-JsonValue $Original
    if (-not $result.Contains('mcpServers')) { $result['mcpServers'] = [ordered]@{} }
    if ($result.mcpServers -isnot [System.Collections.IDictionary]) { throw 'mcpServers must be a JSON object.' }
    $entry = [ordered]@{}
    if ($result.mcpServers.Contains($ServerName)) {
        if ($result.mcpServers[$ServerName] -isnot [System.Collections.IDictionary]) { throw 'Existing server entry must be an object.' }
        $entry = Copy-JsonValue $result.mcpServers[$ServerName]
        # Refuse silent migration of remote/auth-specific server settings.
        foreach ($key in @('url','headers','oauthClientId','oauthScopes','oauthGrantType','oidc')) {
            if ($entry.Contains($key)) { throw "Existing '$ServerName' has remote/auth setting '$key'. Use a different serverName in team-config.json." }
        }
        Assert-ExistingProxyInvocation $entry $ServerName
    }
    $entry['type'] = 'local'
    $entry['command'] = $ProxyPath
    $entry['args'] = @("https://aws-mcp.$($Team.mcpRegion).api.aws/mcp", '--metadata', "AWS_REGION=$($Team.defaultAwsRegion)")
    $entry['timeout'] = $Team.timeoutMs
    if (-not $entry.Contains('env')) { $entry['env'] = [ordered]@{} }
    if ($entry.env -isnot [System.Collections.IDictionary]) { throw 'Existing env must be a JSON object.' }
    $entry.env['AWS_MCP_PROXY_PROFILES'] = $Profiles -join ' '
    # Existing restrictions are preserved, never expanded to '*'.
    if (-not $entry.Contains('tools')) { $entry['tools'] = @('*') }
    $result.mcpServers[$ServerName] = $entry
    return ,$result
}

function Write-JsonAtomic([string]$Path, $Value, [string]$ExpectedFingerprint) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $tmp = Join-Path $parent ('.mcp-setup-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $text = ConvertTo-Json -InputObject $Value -Depth 100 -WarningAction Stop
        $null = ConvertFrom-Json -InputObject $text -Depth 100 -AsHashtable
        [IO.File]::WriteAllText($tmp, $text + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        if ((Get-FileFingerprint $Path) -ne $ExpectedFingerprint) {
            throw 'Configuration changed while setup was running. Nothing was overwritten; rerun setup.'
        }
        if ($ExpectedFingerprint -eq 'MISSING') { [IO.File]::Move($tmp, $Path) }
        else { [IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Restore-McpEntry($Current, $Manifest) {
    $result = Copy-JsonValue $Current
    $name = $Manifest.serverName
    if (-not $result.Contains('mcpServers') -or $result.mcpServers -isnot [System.Collections.IDictionary] -or
        -not $result.mcpServers.Contains($name)) { throw 'Managed server is absent; refusing automatic rollback.' }
    if ((Get-EntryHash $result.mcpServers[$name]) -ne $Manifest.afterEntryHash) {
        throw 'This server was changed after setup. Refusing automatic rollback; compare the backups manually.'
    }
    if ($Manifest.beforeEntryExisted) { $result.mcpServers[$name] = Copy-JsonValue $Manifest.beforeEntry }
    else { $result.mcpServers.Remove($name) | Out-Null }
    return ,$result
}
