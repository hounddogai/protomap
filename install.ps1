# Installs the ProtoMap CLI on Windows from its GitHub releases, in PowerShell. The latest release:
#
#   irm https://raw.githubusercontent.com/hounddogai/protomap/main/install.ps1 | iex
#
# Or a version, such as the one a ProtoMap server runs, which its platform's install command names:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/hounddogai/protomap/main/install.ps1))) 0.1.0
#
# The CLI installs to %LOCALAPPDATA%\protomap\bin, or to PROTOMAP_INSTALL_DIR, and the folder goes first on the user's
# PATH. Releases have builds for Windows on x86_64 and aarch64, named protomap-windows-<arch>.exe, and a SHA256SUMS file
# that each download must match before it replaces the installed CLI. Linux and macOS install with install.sh instead.
#
# PROTOMAP_RELEASES_URL replaces https://github.com/hounddogai/protomap/releases, such as with a mirror or a test's
# server, which serves the same paths: <url>/latest/download/<file> and <url>/download/<version>/<file>.

# The installation runs in a script block of its own, so that iex leaves no variables or preferences behind in the
# session that runs it.
& {
    param([string]$Version)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    # The progress bar slows downloads in Windows PowerShell several times over.
    $ProgressPreference = 'SilentlyContinue'

    $ScriptUrl = 'https://raw.githubusercontent.com/hounddogai/protomap/main'
    # A version is a release's tag, such as 1.2.3 or 1.2.3-beta.1. \z ends the match at the very end, where $ would
    # also allow a line break.
    if ($Version -and $Version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\z') {
        throw "$Version is not a version of the ProtoMap CLI, such as 1.2.3 or 1.2.3-beta.1."
    }
    if ($env:OS -ne 'Windows_NT') {
        $Command = "curl -fsSL $ScriptUrl/install.sh | sh"
        if ($Version) {
            $Command += " -s -- $Version"
        }
        throw "This script installs the ProtoMap CLI on Windows. On Linux and macOS, run: $Command"
    }
    # A 32-bit PowerShell on 64-bit Windows finds the computer's architecture in PROCESSOR_ARCHITEW6432.
    $Machine = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $Arch = switch ($Machine) {
        'AMD64' { 'x86_64' }
        'ARM64' { 'aarch64' }
        default { throw "The ProtoMap CLI runs on x86_64 and aarch64; this computer is $Machine." }
    }
    $Releases = 'https://github.com/hounddogai/protomap/releases'
    if ($env:PROTOMAP_RELEASES_URL) {
        $Releases = $env:PROTOMAP_RELEASES_URL.TrimEnd('/')
    }
    if ($Version) {
        $Files = "$Releases/download/$Version"
        $Release = "ProtoMap CLI $Version"
    } else {
        $Files = "$Releases/latest/download"
        $Release = 'the latest ProtoMap CLI release'
    }
    $Asset = "protomap-windows-$Arch.exe"

    # Downloads the release's file named $Name to $Path, or fails with $Missing when the release does not have it.
    function Get-ReleaseFile([string]$Name, [string]$Path, [string]$Missing) {
        $Url = "$Files/$Name"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
        } catch {
            $Response = $_.Exception.PSObject.Properties['Response']
            if ($Response -and $Response.Value -and [int]$Response.Value.StatusCode -eq 404) {
                throw $Missing
            }
            throw "Cannot download $Url`: $($_.Exception.Message)"
        }
    }

    $Directory = $env:PROTOMAP_INSTALL_DIR
    if (-not $Directory) {
        $Directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'protomap\bin'
    }
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
    # A drive's root keeps its separator, since C: alone names the drive's current folder.
    if ($Directory -notmatch '^[A-Za-z]:\\$') {
        $Directory = $Directory.TrimEnd('\')
    }
    # A semicolon splits a PATH's folders, and Windows reads %NAME% in one as a variable.
    if ($Directory -match '[;%]') {
        throw "A PATH cannot hold $Directory, whose name has a semicolon or a percent sign. Choose another folder " +
            'with PROTOMAP_INSTALL_DIR.'
    }
    $Binary = Join-Path $Directory 'protomap.exe'
    # One installation into the folder at a time, so none deletes the files another is using. The lock file goes when
    # its handle closes, also when PowerShell ends.
    try {
        # Typed arguments, since PowerShell would read the options as a Boolean and pick another constructor.
        $Lock = [IO.FileStream]::new((Join-Path $Directory '.protomap.lock'), [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
    } catch {
        $Cause = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        # 32 is ERROR_SHARING_VIOLATION: another installation holds the lock.
        if (($Cause.HResult -band 0xFFFF) -eq 32) {
            throw "Another installation of the ProtoMap CLI into $Directory is running. Run this again once it ends."
        }
        throw
    }
    # Download beside the destination and rename, so a failed download never replaces a working CLI.
    $Download = Join-Path $Directory ".protomap-$([Guid]::NewGuid().ToString('N')).exe"
    $Sums = Join-Path $Directory ".protomap-$([Guid]::NewGuid().ToString('N')).sums"
    try {
        # What an earlier installation left: a CLI that was running as it was replaced, or a download it did not finish.
        Get-ChildItem -LiteralPath $Directory -Filter '.protomap-*' -Force |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Downloading $Release for Windows on $Arch from $Releases"
        Get-ReleaseFile 'SHA256SUMS' $Sums "Cannot find $Release, or its SHA256SUMS. See the releases at $Releases"
        Get-ReleaseFile $Asset $Download ("There is no build for Windows on $Arch in $Release. See the releases at " +
            $Releases)
        # SHA256SUMS lists each file as <checksum>  <name>, or <checksum> *<name> in binary mode.
        $Expected = $null
        foreach ($Line in Get-Content -LiteralPath $Sums) {
            if ($Line -match '^([0-9A-Fa-f]{64}) [ *](.+)$' -and $Matches[2] -ceq $Asset) {
                $Expected = $Matches[1]
                break
            }
        }
        if (-not $Expected) {
            throw "The SHA256SUMS of $Release has no checksum for $Asset."
        }
        # -ne compares regardless of case, since Get-FileHash answers in upper case.
        if ((Get-FileHash -LiteralPath $Download -Algorithm SHA256).Hash -ne $Expected) {
            throw "The download of $Asset does not match its checksum in SHA256SUMS, so the installed CLI stays as " +
                'it was. Run this again; if it fails again, the download is damaged on its way to this computer.'
        }
        # Windows cannot replace a program while it runs, such as the CLI a coding agent runs as its MCP server, but it
        # can rename it. The running CLI moves aside, and the next installation deletes it.
        $Previous = $null
        if (Test-Path -LiteralPath $Binary) {
            $Previous = Join-Path $Directory ".protomap-$([Guid]::NewGuid().ToString('N')).old"
            Move-Item -LiteralPath $Binary -Destination $Previous
        }
        try {
            Move-Item -LiteralPath $Download -Destination $Binary
        } catch {
            if ($Previous) {
                Move-Item -LiteralPath $Previous -Destination $Binary
            }
            throw
        }
        if ($Previous) {
            Remove-Item -LiteralPath $Previous -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $Download, $Sums -Force -ErrorAction SilentlyContinue
        $Lock.Dispose()
    }
    Write-Host "Installed $Release to $Binary."

    # The folder goes first on the user's PATH, which the registry holds with its variables unexpanded, such as
    # %USERPROFILE%, and which they keep. Terminals opened from now on find the CLI, and so does this session.
    $IsOther = { param($Entry) $Entry -and $Entry.TrimEnd('\') -ine $Directory.TrimEnd('\') }
    $Key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $UserPath = [string]$Key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        $NewPath = (@($Directory) + @($UserPath.Split(';') | Where-Object { & $IsOther $_ })) -join ';'
        if ($NewPath -ne $UserPath) {
            # A PATH stored as plain text stays plain, so a % in one of its folders' names keeps meaning a %.
            $Kind = if ($Key.GetValueNames() -contains 'Path') { $Key.GetValueKind('Path') } else { 'ExpandString' }
            $Key.SetValue('Path', $NewPath, $Kind)
            # Setting a variable through .NET tells running programs, such as Explorer, that the environment changed,
            # so the terminals they open read the new PATH.
            $Notice = "PROTOMAP_$([Guid]::NewGuid().ToString('N'))"
            [Environment]::SetEnvironmentVariable($Notice, '1', 'User')
            [Environment]::SetEnvironmentVariable($Notice, [NullString]::Value, 'User')
            Write-Host "Added $Directory to your PATH."
        }
    } finally {
        $Key.Dispose()
    }
    $env:Path = (@($Directory) + @($env:Path.Split(';') | Where-Object { & $IsOther $_ })) -join ';'

    Write-Host "Log in with: protomap login --server=<your ProtoMap server's address>"
    Write-Host 'Then add ProtoMap to your coding agent, such as Claude Code, so it reads the graph with your changes'
    Write-Host 'laid over it:'
    Write-Host '  claude mcp add protomap -- protomap mcp serve'
    Write-Host 'Other coding agents run protomap mcp serve from the repository''s folder, over standard input and output.'
} @args
