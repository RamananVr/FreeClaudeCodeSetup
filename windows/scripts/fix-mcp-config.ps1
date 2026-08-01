<#
    fix-mcp-config.ps1
    Post-process the MCP config that `agency claude` generates for its built-in
    HTTP servers (workiq, bluebird, ...). Agency adds `"tools": ["*"]` to every
    server, but Claude Code's schema for `http` servers requires `tools` to be an
    array of OBJECTS, so it rejects the string form:
        "invalid MCP server config for \"workiq\": tools.0: expected object, received string"
    (stdio servers such as azure-devops tolerate the same string form.)

    This script finds the most recently written %TEMP%\claude-mcp-*.json (or uses the
    -Path argument) and removes any `tools` property whose entries are not objects,
    so all servers validate. It runs from the shim just before the real Claude binary
    reads the file.
#>

param(
    [string]$Path,
    # When set, the repaired config is written to this NEW file and the original
    # ($Path) is left untouched. Agency holds its generated temp config open with a
    # write lock while Claude runs, so we cannot overwrite it in place — instead we
    # emit a fixed copy and the shim rewrites --mcp-config to point here.
    [string]$OutPath
)

$ErrorActionPreference = 'SilentlyContinue'

if ($Path -and (Test-Path $Path)) {
    $cfg = Get-Item $Path
} else {
    $cfg = Get-ChildItem -Path $env:TEMP -Filter 'claude-mcp-*.json' -File |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-120) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $cfg) { return }

# Read-only open so we never contend with Agency's write lock on the original.
$raw = $null
try {
    $stream = [System.IO.File]::Open($cfg.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.StreamReader($stream)
    $raw = $reader.ReadToEnd()
    $reader.Close(); $stream.Close()
} catch {
    try { $raw = Get-Content $cfg.FullName -Raw } catch { return }
}
if (-not $raw) { return }

try {
    $json = $raw | ConvertFrom-Json
} catch { return }
if (-not $json.mcpServers) {
    # Nothing to fix, but if an OutPath was requested still hand Claude a copy.
    if ($OutPath) { $raw | Set-Content -Path $OutPath -Encoding utf8 }
    return
}

foreach ($prop in @($json.mcpServers.PSObject.Properties)) {
    $server = $prop.Value
    $tools  = $server.tools
    if ($null -ne $tools) {
        $hasNonObject = @($tools | Where-Object { $_ -isnot [System.Management.Automation.PSCustomObject] }).Count -gt 0
        if ($hasNonObject) {
            $server.PSObject.Properties.Remove('tools')
        }
    }
}

$out = $json | ConvertTo-Json -Depth 20
if ($OutPath) {
    $out | Set-Content -Path $OutPath -Encoding utf8
} else {
    $out | Set-Content -Path $cfg.FullName -Encoding utf8
}
