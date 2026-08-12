param(
    [string]$Version = $env:AXON_VERSION
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Repository = 'bleugreen/axon'
$ApiUrl = "https://api.github.com/repos/$Repository/releases/latest"
$ReleasesUrl = "https://github.com/$Repository/releases/download"

function Fail([string]$Message) {
    throw "Axon install failed: $Message"
}

if ($env:OS -ne 'Windows_NT') {
    Fail "unsupported platform; install.ps1 supports only windows/x86_64"
}
$Architecture = $env:PROCESSOR_ARCHITEW6432
if ([string]::IsNullOrEmpty($Architecture)) {
    $Architecture = $env:PROCESSOR_ARCHITECTURE
}
if ($Architecture -ne 'AMD64') {
    Fail "unsupported platform windows/$($Architecture.ToLowerInvariant()); release binaries exist only for macos/aarch64, linux/x86_64, and windows/x86_64"
}

$Pinned = -not [string]::IsNullOrWhiteSpace($Version)
if ($Pinned) {
    $Version = $Version.Trim().TrimStart('v')
} else {
    try {
        $Release = Invoke-RestMethod -Uri $ApiUrl -Headers @{
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
    } catch {
        Fail "could not resolve the latest release from $ApiUrl; check your network or pass -Version with a published version. $($_.Exception.Message)"
    }
    $Version = ([string]$Release.tag_name).TrimStart('v')
}
if ([string]::IsNullOrWhiteSpace($Version) -or $Version -notmatch '^[0-9A-Za-z._+-]+$') {
    Fail "invalid version '$Version'; use a release version such as 0.3.1"
}

$Archive = "axon-win-$Version-windows-x86_64.zip"
$ContentDirectory = "axon-win-$Version-windows-x86_64"
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Axon'
$InstallDirectory = Join-Path $InstallRoot $Version
$Executable = Join-Path $InstallDirectory 'axon-win.exe'
$Marker = Join-Path $InstallDirectory '.axon-install-complete'

if ((Test-Path -LiteralPath $Marker -PathType Leaf) -and (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    Write-Host "Axon $Version is already installed at $InstallDirectory; reconciling daemon and PATH state."
    & $Executable daemon install
    if ($LASTEXITCODE -ne 0) {
        Fail "axon-win.exe daemon install exited with code $LASTEXITCODE; review its message above and retry after correcting the reported problem"
    }
    $CliExecutable = Join-Path $InstallDirectory 'axon.exe'
    if (-not (Test-Path -LiteralPath $CliExecutable -PathType Leaf)) {
        New-Item -ItemType HardLink -Path $CliExecutable -Target $Executable | Out-Null
    }
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $PathEntries = @($UserPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        -not $_.TrimEnd('\').StartsWith($InstallRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)
    })
    $NewUserPath = (@($InstallDirectory) + $PathEntries) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $NewUserPath, 'User')
    Write-Host "Axon $Version is installed and registered."
    exit 0
}

$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("axon-install-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDirectory | Out-Null
try {
    $ArchivePath = Join-Path $TempDirectory $Archive
    $ChecksumPath = "$ArchivePath.sha256"
    $BaseUrl = "$ReleasesUrl/v$Version"

    Write-Host "Downloading Axon $Version for windows/x86_64..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$Archive" -OutFile $ArchivePath
    } catch {
        Fail "could not download $Archive; confirm that version $Version has a windows/x86_64 release at $BaseUrl. $($_.Exception.Message)"
    }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$Archive.sha256" -OutFile $ChecksumPath
    } catch {
        Fail "could not download $Archive.sha256; the archive was not installed. $($_.Exception.Message)"
    }

    $ChecksumText = (Get-Content -LiteralPath $ChecksumPath -Raw).Trim()
    $ExpectedHash = ($ChecksumText -split '\s+')[0]
    if ($ExpectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
        Fail "the published checksum for $Archive is malformed; the archive was not installed"
    }
    $ActualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    if ($ActualHash -ine $ExpectedHash) {
        Fail "checksum verification failed for $Archive; expected $ExpectedHash but downloaded $ActualHash"
    }
    Write-Host "Verified SHA-256: $ActualHash"

    $ExtractDirectory = Join-Path $TempDirectory 'extracted'
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDirectory
    } catch {
        Fail "could not unpack $Archive with Expand-Archive. $($_.Exception.Message)"
    }
    $SourceDirectory = Join-Path $ExtractDirectory $ContentDirectory
    $SourceExecutable = Join-Path $SourceDirectory 'axon-win.exe'
    if (-not (Test-Path -LiteralPath $SourceExecutable -PathType Leaf)) {
        Fail "$Archive did not contain the expected executable $ContentDirectory\axon-win.exe"
    }

    $Signature = Get-AuthenticodeSignature -LiteralPath $SourceExecutable
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        $ReleaseVersion = $null
        $SigningStart = [version]'0.3.0'
        $IsUnsignedLegacyPin = $Pinned -and
            [version]::TryParse($Version, [ref]$ReleaseVersion) -and
            $ReleaseVersion -lt $SigningStart -and
            $Signature.Status -eq [System.Management.Automation.SignatureStatus]::NotSigned
        if ($IsUnsignedLegacyPin) {
            Write-Warning "Axon $Version predates the Windows signing pipeline and carries no Authenticode signature; its SHA-256 checksum is valid, but Windows cannot verify its publisher."
        } else {
            Fail "Authenticode verification failed for axon-win.exe: $($Signature.Status) - $($Signature.StatusMessage). Use a signed release or verify that the download was not modified"
        }
    } else {
        Write-Host "Verified Authenticode signer: $($Signature.SignerCertificate.Subject)"
    }

    $StagedInstall = "$InstallDirectory.installing"
    if (Test-Path -LiteralPath $StagedInstall) {
        Remove-Item -LiteralPath $StagedInstall -Recurse -Force
    }
    New-Item -ItemType Directory -Path $StagedInstall | Out-Null
    Copy-Item -Path (Join-Path $SourceDirectory '*') -Destination $StagedInstall -Recurse -Force
    $StagedExecutable = Join-Path $StagedInstall 'axon-win.exe'
    if (-not (Test-Path -LiteralPath $StagedExecutable -PathType Leaf)) {
        Fail "the staged executable is missing at $StagedExecutable"
    }
    try {
        New-Item -ItemType HardLink -Path (Join-Path $StagedInstall 'axon.exe') -Target $StagedExecutable | Out-Null
    } catch {
        Fail "could not create the axon.exe CLI link in $StagedInstall. $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $InstallDirectory) {
        Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
    }
    Move-Item -LiteralPath $StagedInstall -Destination $InstallDirectory
    $CliExecutable = Join-Path $InstallDirectory 'axon.exe'

    Write-Host "Registering the daemon from permanent path $Executable..."
    & $Executable daemon install
    if ($LASTEXITCODE -ne 0) {
        Fail "axon-win.exe daemon install exited with code $LASTEXITCODE; review its message above and retry after correcting the reported problem"
    }

    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $PathEntries = @($UserPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        -not $_.TrimEnd('\').StartsWith($InstallRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)
    })
    $NewUserPath = (@($InstallDirectory) + $PathEntries) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $NewUserPath, 'User')
    if (($env:Path -split ';') -notcontains $InstallDirectory) {
        $env:Path = "$InstallDirectory;$env:Path"
    }
    Set-Content -LiteralPath $Marker -Value $Version -NoNewline

    Write-Host "`nAxon $Version installed successfully."
    Write-Host "CLI: $CliExecutable -> $Executable"
    Write-Host 'The versioned install directory was added to your user PATH; open a new terminal to use axon.'
    Write-Host "`nRegister Axon with an MCP client:"
    Write-Host '  claude mcp add axon -- axon mcp'
    Write-Host '  codex mcp add axon -- axon mcp'
} finally {
    Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}