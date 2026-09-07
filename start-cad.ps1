# Start LucasCad on Windows.
#
#   .\start-cad.ps1              set up if needed, then run
#   .\start-cad.ps1 -SetupOnly   install dependencies and exit
#   .\start-cad.ps1 -NoOpen      do not open a browser
#
# Environment overrides: LUCASCAD_PYTHON, LUCASCAD_WEB_PORT, LUCASCAD_API_PORT.

[CmdletBinding()]
param(
    [switch]$SetupOnly,
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$venvDir = Join-Path $projectRoot ".venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$toolingDir = Join-Path $projectRoot ".tooling"
$stampDir = Join-Path $toolingDir "stamps"

$webPort = if ($env:LUCASCAD_WEB_PORT) { [int]$env:LUCASCAD_WEB_PORT } else { 4310 }
$apiPort = if ($env:LUCASCAD_API_PORT) { [int]$env:LUCASCAD_API_PORT } else { 4311 }

$minNodeMajor = 22
$minNodeMinor = 13

function Say  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- python -----

# Native tools write to stderr for ordinary "not installed" answers -- `py -3.13`
# prints "No suitable Python runtime found" -- and with $ErrorActionPreference
# set to Stop, PowerShell promotes that to a terminating error. Probes go
# through here so they are judged by exit code alone.
function Test-NativeCommand ([string]$exe, [string[]]$commandArgs) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $exe @commandArgs 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    }
    catch { return $false }
    finally { $ErrorActionPreference = $previous }
}

# CadQuery 2.8 declares Requires-Python >=3.11 and cadquery-ocp caps at <3.15.
function Test-SupportedPython ($exe) {
    if (-not $exe) { return $false }
    # A bare "python" on a clean Windows install is usually the Microsoft Store
    # execution alias, which opens the Store instead of running anything.
    if ($exe -like "*\WindowsApps\*") { return $false }
    return Test-NativeCommand $exe @("-c", "import sys; sys.exit(0 if (3,11) <= sys.version_info < (3,15) else 1)")
}

function Find-Python {
    if ($env:LUCASCAD_PYTHON) {
        if (-not (Test-SupportedPython $env:LUCASCAD_PYTHON)) {
            Die "LUCASCAD_PYTHON=$($env:LUCASCAD_PYTHON) is not a Python 3.11-3.14 interpreter."
        }
        return $env:LUCASCAD_PYTHON
    }
    # The py launcher is the reliable way to select a version on Windows. It
    # writes to stderr when a version is absent, so swallow every stream and
    # judge only by the exit code.
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($version in @("3.13", "3.12", "3.11")) {
            if (Test-NativeCommand "py" @("-$version", "-c", "import sys; sys.exit(0 if (3,11) <= sys.version_info < (3,15) else 1)")) {
                return @("py", "-$version")
            }
        }
    }
    foreach ($name in @("python3", "python")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and (Test-SupportedPython $cmd.Source)) { return @($cmd.Source) }
    }
    return $null
}

function Get-FileHashHex ($path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }

function Initialize-Venv ($requirements) {
    if (-not (Test-Path -LiteralPath $venvPython)) {
        $python = Find-Python
        if (-not $python) {
            Write-Host @"
LucasCad needs Python 3.11-3.14 (CadQuery 2.8 requires >= 3.11).

Install it from https://www.python.org/downloads/windows/ or with winget:

    winget install Python.Python.3.12

Then re-run this script.
"@ -ForegroundColor Yellow
            Die "no supported Python interpreter found"
        }
        Say "Creating virtualenv with $($python -join ' ')"
        & $python[0] @($python[1..($python.Length - 1)] + @("-m", "venv", $venvDir))
        if ($LASTEXITCODE -ne 0) { Die "could not create $venvDir" }
    }
    elseif (-not (Test-SupportedPython $venvPython)) {
        Warn "$venvDir uses an unsupported Python; rebuilding it"
        Remove-Item -Recurse -Force -LiteralPath $venvDir
        Initialize-Venv $requirements
        return
    }

    New-Item -ItemType Directory -Force -Path $stampDir | Out-Null
    $stamp = Join-Path $stampDir ("python-" + (Split-Path -Leaf $requirements))
    $hash = Get-FileHashHex $requirements
    if ((Test-Path -LiteralPath $stamp) -and ((Get-Content -Raw $stamp).Trim() -eq $hash)) { return }

    Say "Installing Python dependencies from $(Split-Path -Leaf $requirements) (first run downloads ~400 MB of Open CASCADE)"
    & $venvPython -m pip install --quiet --upgrade pip
    if ($LASTEXITCODE -ne 0) { Die "pip self-upgrade failed" }
    & $venvPython -m pip install --quiet -r $requirements
    if ($LASTEXITCODE -ne 0) { Die "installing $requirements failed" }
    Test-GeometryKernel
    Set-Content -LiteralPath $stamp -Value $hash -NoNewline
}

# CadQuery's compiled extensions (nlopt, OCP) are built with MSVC and need the
# Visual C++ runtime, which a clean Windows install does not ship. Python's own
# installer supplies vcruntime140.dll for CPython but not the C++ runtime these
# wheels link against, so the failure surfaces as a bare "DLL load failed".
#
# The success marker matters: on Windows, Open CASCADE corrupts the heap while
# the interpreter tears down, so `python -c "import cadquery"` returns 0xC0000374
# even when the import itself worked. Judging by exit code would reject a
# perfectly good install, so trust what the probe printed instead.
function Test-GeometryKernel {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $output = & $venvPython -c "import cadquery; print('LUCASCAD_KERNEL_OK')" 2>&1 | Out-String }
    finally { $ErrorActionPreference = $previous }
    if ($output -match "LUCASCAD_KERNEL_OK") { return }

    if ($output -match "DLL load failed") {
        Write-Host @"

CadQuery could not load its compiled extensions:

$($output.Trim())

This almost always means the Microsoft Visual C++ Redistributable is missing.
Install it, then re-run this script:

    winget install Microsoft.VCRedist.2015+.x64

or download it from https://aka.ms/vs/17/release/vc_redist.x64.exe
"@ -ForegroundColor Yellow
        Die "CadQuery could not be imported"
    }
    Write-Host $output.Trim() -ForegroundColor Yellow
    Die "CadQuery could not be imported"
}

# ------------------------------------------------------------ node / pnpm -----

# Retain the portable Codex runtime as a fallback for machines that have no
# system-wide Node, matching the behaviour this launcher had before.
function Add-CodexRuntimeToPath {
    if (Get-Command node -ErrorAction SilentlyContinue) { return }
    $runtime = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\codex-runtimes\codex-primary-runtime\dependencies'
    $nodeBin = Join-Path $runtime 'node\bin'
    if (Test-Path -LiteralPath $nodeBin) { $env:Path = "$nodeBin;$env:Path" }
}

function Initialize-Node {
    Add-CodexRuntimeToPath
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Host @"
LucasCad needs Node >= $minNodeMajor.$minNodeMinor.0 (package.json "engines").

Install it from https://nodejs.org/ or with winget:

    winget install OpenJS.NodeJS.LTS

Then re-run this script.
"@ -ForegroundColor Yellow
        Die "node not found"
    }
    $version = (& node --version).TrimStart("v").Split(".")
    $major = [int]$version[0]
    $minor = [int]$version[1]
    if ($major -lt $minNodeMajor -or ($major -eq $minNodeMajor -and $minor -lt $minNodeMinor)) {
        Die "node $(& node --version) is too old; LucasCad needs >= $minNodeMajor.$minNodeMinor.0"
    }
}

# pnpm reads lockfiles and the build-script allowlist differently across majors,
# so honour the version pinned by packageManager rather than whatever is on PATH.
function Resolve-Pnpm {
    $pinned = (Get-Content -Raw (Join-Path $projectRoot "package.json") | ConvertFrom-Json).packageManager
    if (-not $pinned -or -not $pinned.StartsWith("pnpm@")) { Die 'package.json is missing a "packageManager" pin for pnpm' }
    $want = $pinned.Substring(5).Split("+")[0]
    $wantMajor = $want.Split(".")[0]

    $onPath = Get-Command pnpm -ErrorAction SilentlyContinue
    if ($onPath) {
        $have = (& pnpm --version)
        if ($have.Split(".")[0] -eq $wantMajor) { return $onPath.Source }
        Warn "pnpm $have is on PATH but this project is pinned to pnpm $want; using a private copy"
    }

    $localRoot = Join-Path $toolingDir "pnpm-$want"
    $localPnpm = Join-Path $localRoot "node_modules\pnpm\bin\pnpm.cjs"
    if (Test-Path -LiteralPath $localPnpm) { return $localPnpm }

    if (Get-Command corepack -ErrorAction SilentlyContinue) {
        & corepack prepare "pnpm@$want" --activate 2>$null
        $onPath = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($onPath -and (& pnpm --version) -eq $want) { return $onPath.Source }
    }

    Say "Installing pnpm $want into .tooling"
    New-Item -ItemType Directory -Force -Path $localRoot | Out-Null
    & npm install --silent --prefix $localRoot "pnpm@$want" | Out-Null
    if (-not (Test-Path -LiteralPath $localPnpm)) { Die "could not install pnpm $want" }
    return $localPnpm
}

# `pnpm exec` re-invokes `pnpm install` through PATH to verify the dependency
# tree is current. A private .tooling copy is not on PATH, so that nested call
# fails with "Command failed with exit code 1: pnpm install" and the dev server
# never starts. Publish the shim directory before running anything via pnpm.
function Publish-PnpmOnPath ($pnpm) {
    $binDir = if ($pnpm -like "*\node_modules\pnpm\bin\*") {
        Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $pnpm))) ".bin"
    } else {
        Split-Path -Parent $pnpm
    }
    if ((Test-Path -LiteralPath $binDir) -and ($env:Path -notlike "*$binDir*")) {
        $env:Path = "$binDir;$env:Path"
    }
}

function Invoke-Pnpm ($pnpm, [string[]]$pnpmArgs) {
    # A .cjs path from the local install has to go through node.
    if ($pnpm.EndsWith(".cjs")) { & node $pnpm @pnpmArgs } else { & $pnpm @pnpmArgs }
}

function Initialize-NodeModules ($pnpm) {
    New-Item -ItemType Directory -Force -Path $stampDir | Out-Null
    $stamp = Join-Path $stampDir "pnpm-lock"
    $hash = Get-FileHashHex (Join-Path $projectRoot "pnpm-lock.yaml")
    if ((Test-Path -LiteralPath (Join-Path $projectRoot "node_modules")) -and
        (Test-Path -LiteralPath $stamp) -and
        ((Get-Content -Raw $stamp).Trim() -eq $hash)) { return }

    Say "Installing Node dependencies with pnpm"
    Push-Location $projectRoot
    try {
        $env:CI = "true"
        Invoke-Pnpm $pnpm @("install")
        if ($LASTEXITCODE -ne 0) { Die "pnpm install failed" }
    }
    finally { Pop-Location }
    Set-Content -LiteralPath $stamp -Value $hash -NoNewline
}

# ----------------------------------------------------------------- ports -----

# The web server binds IPv4 loopback, and "lucascad.localhost" does not resolve
# to IPv4 on every platform. Advertise it only where it actually does.
function Get-UiHost ($name) {
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($name)
        if ($addresses | Where-Object { $_.AddressFamily -eq "InterNetwork" }) { return $name }
    }
    catch { }
    return "127.0.0.1"
}

function Assert-PortFree ($port, $label) {
    $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($listener) {
        $owner = ""
        $process = Get-Process -Id $listener[0].OwningProcess -ErrorAction SilentlyContinue
        if ($process) { $owner = " It is held by $($process.ProcessName) (pid $($process.Id))." }
        Die @"
port $port ($label) is already in use.$owner
Stop that process, or pick another port:
    `$env:LUCASCAD_WEB_PORT=5310; `$env:LUCASCAD_API_PORT=5311; .\start-cad.ps1
"@
    }
}

# ------------------------------------------------------------------ main -----

Initialize-Node
Initialize-Venv (Join-Path $projectRoot "backend\requirements.txt")
$pnpm = Resolve-Pnpm
Publish-PnpmOnPath $pnpm
Initialize-NodeModules $pnpm

if ($SetupOnly) {
    Say "Setup complete. Run .\start-cad.ps1 to launch LucasCad."
    exit 0
}

Assert-PortFree $apiPort "geometry service"
Assert-PortFree $webPort "web UI"

Say "Starting geometry service on 127.0.0.1:$apiPort"
$api = Start-Process -FilePath $venvPython `
    -ArgumentList "-m", "uvicorn", "backend.server:app", "--host", "127.0.0.1", `
                  "--port", $apiPort, "--reload", "--reload-dir", "backend" `
    -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru

try {
    # Importing Open CASCADE takes several seconds on a cold cache, so poll the
    # health endpoint instead of sleeping for a fixed interval.
    Say "Waiting for the geometry kernel to load"
    $ready = $false
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if ($api.HasExited) { Die "the geometry service exited during startup" }
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$apiPort/api/health" `
                -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) { $ready = $true; break }
        }
        catch { Start-Sleep -Milliseconds 400 }
    }
    if (-not $ready) { Die "timed out waiting for the geometry service to report healthy" }

    $url = "http://$(Get-UiHost 'lucascad.localhost'):$webPort/"
    Say "LucasCad is ready at $url"
    if (-not $NoOpen) { Start-Process $url | Out-Null }

    Push-Location $projectRoot
    try {
        $env:CI = "true"
        Invoke-Pnpm $pnpm @("exec", "vinext", "dev", "--hostname", "127.0.0.1", "--port", "$webPort")
    }
    finally { Pop-Location }
}
finally {
    if ($api -and -not $api.HasExited) {
        Stop-Process -Id $api.Id -Force -ErrorAction SilentlyContinue
    }
}
