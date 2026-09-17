[CmdletBinding()]
param(
    [switch]$Configure,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$script:LogPath = $null

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.psd1'
}

function Import-PublisherConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path. Run publishNWD.bat -Configure."
    }

    $config = Import-PowerShellDataFile -LiteralPath $Path
    $requiredNames = @('NavisworksPath', 'SourceDirectory', 'SourceNwf', 'OutputNwd')

    foreach ($name in $requiredNames) {
        if (-not $config.ContainsKey($name)) {
            throw "Required setting '$name' is missing from $Path."
        }

        if ($config[$name] -isnot [string]) {
            throw "Setting '$name' in $Path must be a string."
        }
    }

    if ($config.ContainsKey('LogPath')) {
        if ($config.LogPath -isnot [string]) {
            throw "Setting 'LogPath' in $Path must be a string."
        }
    }
    else {
        $config.LogPath = 'publishNWD.log'
    }

    return $config
}

function Read-ConfiguredPath {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CurrentValue,

        [Parameter(Mandatory)]
        [ValidateSet('File', 'Directory', 'Output')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ExpectedExtension
    )

    while ($true) {
        Write-Host ''
        Write-Host $Prompt -ForegroundColor Cyan
        Write-Host "Current: $CurrentValue"
        $answer = Read-Host 'New path (press Enter to keep current)'
        $candidate = if ([string]::IsNullOrWhiteSpace($answer)) {
            $CurrentValue
        }
        else {
            $answer.Trim().Trim('"')
        }

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            Write-Warning 'A path is required.'
            continue
        }

        if ($candidate.Contains('"') -or $candidate.Contains("`r") -or $candidate.Contains("`n")) {
            Write-Warning 'The path cannot contain a double quote or a line break.'
            continue
        }

        if ($ExpectedExtension -and
            [System.IO.Path]::GetExtension($candidate) -ine $ExpectedExtension) {
            Write-Warning "The path must use the $ExpectedExtension extension."
            continue
        }

        $isValid = switch ($Kind) {
            'File' {
                Test-Path -LiteralPath $candidate -PathType Leaf
            }
            'Directory' {
                Test-Path -LiteralPath $candidate -PathType Container
            }
            'Output' {
                $parent = Split-Path -Parent $candidate
                -not [string]::IsNullOrWhiteSpace($parent) -and
                    (Test-Path -LiteralPath $parent -PathType Container)
            }
        }

        if ($isValid) {
            return $candidate
        }

        if ($Kind -eq 'Output') {
            Write-Warning 'The output file may be new, but its parent folder must already exist.'
        }
        else {
            Write-Warning "The selected $($Kind.ToLowerInvariant()) does not exist."
        }
    }
}

function Read-OptionalLogPath {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CurrentValue,

        [Parameter(Mandatory)]
        [string]$BaseDirectory
    )

    while ($true) {
        Write-Host ''
        Write-Host 'Publisher log file' -ForegroundColor Cyan
        $currentDisplay = if ([string]::IsNullOrWhiteSpace($CurrentValue)) {
            'DISABLED'
        }
        else {
            $CurrentValue
        }
        Write-Host "Current: $currentDisplay"
        $answer = Read-Host 'New path (Enter to keep current, NONE to disable)'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $CurrentValue
        }

        if ($answer.Trim() -ieq 'NONE') {
            return ''
        }

        $candidate = $answer.Trim().Trim('"')
        if ($candidate.Contains('"') -or $candidate.Contains("`r") -or $candidate.Contains("`n")) {
            Write-Warning 'The path cannot contain a double quote or a line break.'
            continue
        }

        if ([System.IO.Path]::GetExtension($candidate) -ine '.log') {
            Write-Warning 'The log path must use the .log extension.'
            continue
        }

        $resolvedPath = if ([System.IO.Path]::IsPathRooted($candidate)) {
            [System.IO.Path]::GetFullPath($candidate)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $candidate))
        }
        $parent = Split-Path -Parent $resolvedPath

        if (Test-Path -LiteralPath $parent -PathType Container) {
            return $candidate
        }

        Write-Warning "The log directory does not exist: $parent"
    }
}

function Initialize-PublisherLog {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigFilePath
    )

    if ([string]::IsNullOrWhiteSpace($Config.LogPath)) {
        $script:LogPath = $null
        return
    }

    if ([System.IO.Path]::GetExtension($Config.LogPath) -ine '.log') {
        throw "LogPath must use the .log extension: $($Config.LogPath)"
    }

    $configDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($ConfigFilePath))
    $resolvedPath = if ([System.IO.Path]::IsPathRooted($Config.LogPath)) {
        [System.IO.Path]::GetFullPath($Config.LogPath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $configDirectory $Config.LogPath))
    }

    $logDirectory = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        throw "Log directory not found: $logDirectory"
    }

    $script:LogPath = $resolvedPath
}

function Write-PublisherLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if (-not $script:LogPath) {
        return
    }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {
        Write-Warning "Logging has been disabled because the log could not be written: $($_.Exception.Message)"
        $script:LogPath = $null
    }
}

function ConvertTo-Psd1String {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Contains("`r") -or $Value.Contains("`n")) {
        throw 'Configuration values cannot contain line breaks.'
    }

    return "'$($Value.Replace("'", "''"))'"
}

function Save-PublisherConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Configuration directory does not exist: $parent"
    }

    $content = @(
        '@{'
        "    NavisworksPath  = $(ConvertTo-Psd1String $Config.NavisworksPath)"
        "    SourceDirectory = $(ConvertTo-Psd1String $Config.SourceDirectory)"
        "    SourceNwf       = $(ConvertTo-Psd1String $Config.SourceNwf)"
        "    OutputNwd       = $(ConvertTo-Psd1String $Config.OutputNwd)"
        "    LogPath         = $(ConvertTo-Psd1String $Config.LogPath)"
        '}'
        ''
    ) -join "`r`n"

    $operationId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $parent ('.config.{0}.tmp.psd1' -f $operationId)
    $backupPath = Join-Path $parent ('.config.{0}.backup.psd1' -f $operationId)
    try {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($temporaryPath, $content, $encoding)

        # Validate the generated data file before replacing the active config.
        $null = Import-PublisherConfig -Path $temporaryPath

        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function Invoke-Configurator {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $current = Import-PublisherConfig -Path $Path
    }
    else {
        $current = @{
            NavisworksPath  = ''
            SourceDirectory = ''
            SourceNwf       = ''
            OutputNwd       = ''
            LogPath         = 'publishNWD.log'
        }
    }

    Write-Host 'Navisworks NWD Publisher configuration' -ForegroundColor Green
    Write-Host "Configuration file: $([System.IO.Path]::GetFullPath($Path))"

    $configured = @{
        NavisworksPath = Read-ConfiguredPath `
            -Prompt 'Navisworks executable (Roamer.exe)' `
            -CurrentValue $current.NavisworksPath `
            -Kind File `
            -ExpectedExtension '.exe'
        SourceDirectory = Read-ConfiguredPath `
            -Prompt 'Folder containing source NWC/NWD files' `
            -CurrentValue $current.SourceDirectory `
            -Kind Directory `
            -ExpectedExtension ''
        SourceNwf = Read-ConfiguredPath `
            -Prompt 'Source Navisworks project' `
            -CurrentValue $current.SourceNwf `
            -Kind File `
            -ExpectedExtension '.nwf'
        OutputNwd = Read-ConfiguredPath `
            -Prompt 'Published NWD output path' `
            -CurrentValue $current.OutputNwd `
            -Kind Output `
            -ExpectedExtension '.nwd'
        LogPath = Read-OptionalLogPath `
            -CurrentValue $current.LogPath `
            -BaseDirectory (Split-Path -Parent ([System.IO.Path]::GetFullPath($Path)))
    }

    Save-PublisherConfig -Path $Path -Config $configured

    Write-Host ''
    Write-Host 'Configuration saved successfully.' -ForegroundColor Green
    Write-Host 'Run publishNWD.bat to publish when a source file is newer.'
}

function Assert-PublisherConfigPaths {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if (-not (Test-Path -LiteralPath $Config.NavisworksPath -PathType Leaf)) {
        throw "Navisworks executable not found: $($Config.NavisworksPath)"
    }
    if ([System.IO.Path]::GetExtension($Config.NavisworksPath) -ine '.exe') {
        throw "NavisworksPath must point to an .exe file: $($Config.NavisworksPath)"
    }
    if (-not (Test-Path -LiteralPath $Config.SourceDirectory -PathType Container)) {
        throw "Source directory not found: $($Config.SourceDirectory)"
    }
    if (-not (Test-Path -LiteralPath $Config.SourceNwf -PathType Leaf)) {
        throw "Source NWF not found: $($Config.SourceNwf)"
    }
    if ([System.IO.Path]::GetExtension($Config.SourceNwf) -ine '.nwf') {
        throw "SourceNwf must point to an .nwf file: $($Config.SourceNwf)"
    }
    if ([System.IO.Path]::GetExtension($Config.OutputNwd) -ine '.nwd') {
        throw "OutputNwd must use the .nwd extension: $($Config.OutputNwd)"
    }

    $outputParent = Split-Path -Parent $Config.OutputNwd
    if ([string]::IsNullOrWhiteSpace($outputParent) -or
        -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        throw "Output directory not found: $outputParent"
    }
}

function Invoke-NwdPublisher {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    Assert-PublisherConfigPaths -Config $Config

    $outputFullPath = [System.IO.Path]::GetFullPath($Config.OutputNwd)
    $latestSource = Get-ChildItem -LiteralPath $Config.SourceDirectory -File |
        Where-Object {
            $_.Extension -iin @('.nwc', '.nwd') -and
            -not [string]::Equals(
                $_.FullName,
                $outputFullPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latestSource) {
        throw "Source folder contains no NWC or NWD files: $($Config.SourceDirectory)"
    }

    $publishedNwd = Get-Item -LiteralPath $Config.OutputNwd -ErrorAction SilentlyContinue
    $publishedTime = if ($publishedNwd) {
        $publishedNwd.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
    else {
        'FILE DOES NOT EXIST'
    }

    Write-PublisherLog -Message (
        'Latest source: {0} ({1:o}); published NWD: {2}' -f `
            $latestSource.FullName,
            $latestSource.LastWriteTimeUtc,
            $publishedTime
    )

    Write-Host '============================================================'
    Write-Host "Latest source : $($latestSource.Name)"
    Write-Host "Modified      : $($latestSource.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "Published NWD : $publishedTime"
    Write-Host '============================================================'

    if ($publishedNwd -and $publishedNwd.LastWriteTimeUtc -ge $latestSource.LastWriteTimeUtc) {
        Write-PublisherLog -Message 'Published NWD is already up to date.'
        Write-Host ''
        Write-Host 'Published NWD is already up to date.' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host 'Publishing is required.' -ForegroundColor Yellow
    Write-Host ''
    Write-PublisherLog -Message 'Publishing is required. Starting Navisworks.'

    $outputTimeBefore = if ($publishedNwd) {
        $publishedNwd.LastWriteTimeUtc
    }
    else {
        $null
    }

    $navisworksArguments = @(
        '-licensing'
        'AdLM'
        '-NoGui'
        '-nwd'
        ('"{0}"' -f $Config.OutputNwd)
        ('"{0}"' -f $Config.SourceNwf)
    )

    $navisworksProcess = Start-Process `
        -FilePath $Config.NavisworksPath `
        -ArgumentList $navisworksArguments `
        -Wait `
        -PassThru

    Write-PublisherLog -Message "Navisworks exited with code $($navisworksProcess.ExitCode)."

    if ($navisworksProcess.ExitCode -ne 0) {
        throw "Navisworks publishing failed with exit code $($navisworksProcess.ExitCode)."
    }

    $publishedAfter = Get-Item -LiteralPath $Config.OutputNwd -ErrorAction SilentlyContinue
    if (-not $publishedAfter) {
        throw "Navisworks completed without creating the output file: $($Config.OutputNwd)"
    }

    if ($outputTimeBefore -and $publishedAfter.LastWriteTimeUtc -le $outputTimeBefore) {
        throw 'Navisworks completed successfully, but the output NWD was not updated.'
    }

    if ($publishedAfter.LastWriteTimeUtc -lt $latestSource.LastWriteTimeUtc) {
        throw 'The published NWD is still older than the latest source file.'
    }

    Write-Host ''
    Write-Host 'Publishing completed successfully.' -ForegroundColor Green
    Write-PublisherLog -Message "Publishing completed successfully: $($publishedAfter.FullName)"
}

try {
    if ($Configure) {
        Invoke-Configurator -Path $ConfigPath
    }
    else {
        $lockPath = Join-Path $PSScriptRoot 'publishNWD.lock'
        try {
            $lockStream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            throw 'Another publisher instance is already running.'
        }

        try {
            $config = Import-PublisherConfig -Path $ConfigPath
            Initialize-PublisherLog -Config $config -ConfigFilePath $ConfigPath
            Write-PublisherLog -Message 'Publisher started.'
            Invoke-NwdPublisher -Config $config
            Write-PublisherLog -Message 'Publisher finished.'
        }
        finally {
            if ($lockStream) {
                $lockStream.Dispose()
            }
        }
    }
}
catch {
    Write-PublisherLog -Message $_.Exception.Message -Level ERROR
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
