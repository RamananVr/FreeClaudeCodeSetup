<#
.SYNOPSIS
  Ensure an x64 Node.js toolchain is available and return which node/npm the caller
  should use. On x64 hosts this is a no-op (returns bare "node"/"npm"). On ARM64 hosts
  it provisions a pinned, portable x64 Node under $HOME\.omniroute\node-x64 and returns
  absolute paths to it.

.DESCRIPTION
  OmniRoute's native deps (wreq-js) ship no win32-arm64 binary, so the server fails when
  run under an arm64 Node. This helper downloads the official x64 Node portable zip from
  nodejs.org, verifies its SHA-256, extracts it, and self-checks that it reports x64.

  Callers (setup-omniroute.ps1) prepend the returned .Dir to $env:Path for their own
  process and bake .NodeExe into the generated shims, so nothing on the machine's global
  PATH is changed.

  Idempotent: a previously provisioned, valid x64 Node is reused with no re-download.

.PARAMETER X64NodeVersion
  Node.js version to provision on arm64 (portable x64 zip). Default: current LTS.

.PARAMETER InstallRoot
  Directory the portable Node is extracted into (default: $HOME\.omniroute\node-x64).

.OUTPUTS
  [pscustomobject] with NodeExe, NpmCmd, Dir. On x64: NodeExe="node", NpmCmd="npm",
  Dir=$null. On arm64: absolute paths into the provisioned toolchain.
#>
[CmdletBinding()]
param(
  [string]$X64NodeVersion = "20.18.1",
  [string]$InstallRoot = (Join-Path $env:USERPROFILE ".omniroute\node-x64")
)

$ErrorActionPreference = "Stop"
function Info($m) { Write-Host "  [*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }

# Detect host architecture. Prefer Node's own report; fall back to the env var when Node
# is not yet on PATH.
$arch = $null
try { $arch = (node -p "process.arch" 2>$null) } catch { $arch = $null }
if (-not $arch) {
  if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -match 'ARM64') {
    $arch = 'arm64'
  } else {
    $arch = 'x64'
  }
}

if ($arch -ne 'arm64') {
  # x64 (or anything non-arm64): use the host Node as-is.
  return [pscustomobject]@{ NodeExe = "node"; NpmCmd = "npm"; Dir = $null }
}

Info "ARM64 host detected. Ensuring a portable x64 Node (v$X64NodeVersion)..."

$folderName = "node-v$X64NodeVersion-win-x64"
$dir = Join-Path $InstallRoot $folderName
$exe = Join-Path $dir "node.exe"
$npm = Join-Path $dir "npm.cmd"

function Test-IsX64Node([string]$nodeExe) {
  if (-not (Test-Path $nodeExe)) { return $false }
  try { return ((& $nodeExe -p "process.arch" 2>$null) -eq 'x64') } catch { return $false }
}

# Reuse a valid prior install (idempotent).
if (Test-IsX64Node $exe) {
  Ok "Reusing provisioned x64 Node at $dir"
  return [pscustomobject]@{ NodeExe = $exe; NpmCmd = $npm; Dir = $dir }
}

$zipName = "$folderName.zip"
$baseUrl = "https://nodejs.org/dist/v$X64NodeVersion"
$zipUrl  = "$baseUrl/$zipName"
$shaUrl  = "$baseUrl/SHASUMS256.txt"

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$tmpZip = Join-Path $InstallRoot $zipName

try {
  Info "Downloading $zipUrl ..."
  Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing

  Info "Verifying SHA-256..."
  $shaText = (Invoke-WebRequest -Uri $shaUrl -UseBasicParsing).Content
  $expected = $null
  foreach ($line in ($shaText -split "`n")) {
    # SHASUMS256.txt lines: "<hash>  <filename>"
    if ($line -match "^\s*([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($zipName))\s*$") {
      $expected = $Matches[1].ToLower(); break
    }
  }
  if (-not $expected) { throw "Could not find a SHA-256 entry for $zipName in SHASUMS256.txt." }

  $actual = (Get-FileHash -Path $tmpZip -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $expected) {
    Remove-Item $tmpZip -ErrorAction SilentlyContinue
    throw "SHA-256 mismatch for $zipName (expected $expected, got $actual). Aborting."
  }
  Ok "Checksum verified."

  # Remove any stale partial extraction, then expand. The zip contains the
  # node-v..-win-x64 folder at its root, so extract into $InstallRoot.
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
  Info "Extracting..."
  Expand-Archive -Path $tmpZip -DestinationPath $InstallRoot -Force
  Remove-Item $tmpZip -ErrorAction SilentlyContinue
}
catch {
  Warn "Failed to provision x64 Node automatically."
  Warn "Download $zipUrl manually, extract it to:"
  Warn "  $InstallRoot"
  Warn "so that $exe exists, then re-run setup."
  throw
}

if (-not (Test-IsX64Node $exe)) {
  throw "Provisioned Node at $exe did not self-check as x64. Aborting."
}

Ok "Provisioned x64 Node at $dir"
return [pscustomobject]@{ NodeExe = $exe; NpmCmd = $npm; Dir = $dir }
