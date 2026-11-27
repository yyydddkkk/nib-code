[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($arch -ne 'AMD64' -or $env:OS -ne 'Windows_NT') { throw 'The nib Windows preview requires Windows x64.' }

$asset = 'nib-x86_64-windows-preview.zip'
$release = 'https://github.com/yyydddkkk/nib-code/releases'
$base = "$release/latest/download"
if ($env:NIB_VERSION) {
    if ($env:NIB_VERSION -cnotmatch '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'Invalid NIB_VERSION.' }
    $base = "$release/download/v$($env:NIB_VERSION.TrimStart('v'))"
}
if ($env:NIB_DOWNLOAD_BASE) { $base = $env:NIB_DOWNLOAD_BASE.TrimEnd('/') }
$install = if ($env:NIB_INSTALL_DIR) { $env:NIB_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'nib\bin' }
$install = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($install)
$work = Join-Path ([IO.Path]::GetTempPath()) ('nib-' + [guid]::NewGuid().ToString('N'))
$stage = $null
$protocol = [Net.ServicePointManager]::SecurityProtocol

function Get-ReleaseFile($name, $destination) {
    $uri = [uri]"$base/$name"
    if ($uri.Scheme -eq 'file') {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $destination
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $destination
    }
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
    }
    [void][IO.Directory]::CreateDirectory($work)
    $zipPath = Join-Path $work $asset
    Get-ReleaseFile $asset $zipPath
    if ($env:NIB_SKIP_VERIFY -ne '1') {
        $sums = Join-Path $work 'SHA256SUMS'
        Get-ReleaseFile 'SHA256SUMS' $sums
        $pattern = '^(?<hash>[0-9a-fA-F]{64})[ \t]+\*?' + [regex]::Escape($asset) + '[ \t]*$'
        $entries = @(Get-Content -LiteralPath $sums | ForEach-Object { if ($_ -cmatch $pattern) { $Matches.hash } })
        if ($entries.Count -ne 1) { throw "Missing or invalid checksum: $asset" }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $stream = [IO.File]::OpenRead($zipPath)
            try { $actual = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '') }
            finally { $stream.Dispose() }
        } finally { $algorithm.Dispose() }
        if ($actual -ne $entries[0]) { throw "Checksum mismatch: $asset" }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        if ($zip.Entries.Count -ne 1 -or $zip.Entries[0].FullName -cne 'nib.exe' -or
            $zip.Entries[0].Length -gt 64MB) { throw "Invalid archive: $asset" }
        [void][IO.Directory]::CreateDirectory($install)
        $stage = Join-Path $install ('.nib-install-' + [guid]::NewGuid().ToString('N') + '.exe')
        [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.Entries[0], $stage)
    } finally { $zip.Dispose() }
    $version = & $stage --version
    if ($LASTEXITCODE -ne 0 -or "$version" -cnotmatch '^nib [0-9]+\.[0-9]+\.[0-9]+$') { throw "Invalid executable: $asset" }
    if ($env:NIB_VERSION -and "$version" -cne "nib $($env:NIB_VERSION.TrimStart('v'))") { throw 'Downloaded nib version does not match NIB_VERSION.' }

    $target = Join-Path $install 'nib.exe'
    if ([IO.File]::Exists($target)) {
        [IO.File]::Replace($stage, $target, [NullString]::Value)
    } else {
        [IO.File]::Move($stage, $target)
    }
    $stage = $null
    Write-Output "$version installed at $target"
    if (($env:Path -split ';') -notcontains $install) {
        Write-Output "Add to your user PATH: $install"
    }
} finally {
    if ($stage) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::SecurityProtocol = $protocol
}
