$ErrorActionPreference = 'Stop'
$previewArgs = $args
$preview = Join-Path $PSScriptRoot 'preview.py'
$candidate = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue
if ($candidate -and $candidate.Source -notlike '*\Microsoft\WindowsApps\*') {
    & $candidate.Source -c 'import sys; sys.exit(sys.version_info < (3, 10))'
    if ($LASTEXITCODE -eq 0) {
        & $candidate.Source $preview @previewArgs
        exit $LASTEXITCODE
    }
}

$cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$hostKey = "Windows-$cpu"
$entry = Get-Content (Join-Path $PSScriptRoot 'python-runtime.txt') |
    Where-Object { ($_ -split '\s+')[0] -eq $hostKey }
if (-not $entry) { throw "Automatic Python setup is unavailable for $hostKey. Install Python 3.10+ and retry." }
$parts = $entry -split '\s+'
$build = $parts[1]
$checksum = $parts[2]
$cacheDir = if ($env:FIGMA_PREVIEW_CACHE_DIR) { $env:FIGMA_PREVIEW_CACHE_DIR } else {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'figma-hardware-preview'
}
$target = Join-Path $cacheDir "python-3.13.18-$hostKey"
$python = Join-Path $target 'python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    [IO.Directory]::CreateDirectory($cacheDir) | Out-Null
    $staging = Join-Path $cacheDir ('.python-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        $version = '20261110'
        $url = "https://github.com/astral-sh/python-build-standalone/releases/download/$version/cpython-3.13.18%2B$version-$build-install_only_stripped.tar.gz"
        $archive = Join-Path $staging 'python.tar.gz'
        Write-Host 'Downloading portable Python from Astral'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 240 -Uri $url -OutFile $archive
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $checksum) {
            throw 'Python archive failed SHA-256 verification.'
        }
        & tar.exe -xzf $archive -C $staging
        if ($LASTEXITCODE -ne 0) { throw 'Could not extract Python.' }
        $extracted = Join-Path $staging 'python'
        if (-not (Test-Path -LiteralPath (Join-Path $extracted 'python.exe') -PathType Leaf)) {
            throw 'Python archive does not contain python.exe.'
        }
        try { [IO.Directory]::Move($extracted, $target) }
        catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw }
        }
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
& $python $preview @previewArgs
exit $LASTEXITCODE
