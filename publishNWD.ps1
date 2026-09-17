[CmdletBinding()]
param(
    [switch]$Configure,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

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
        '}'
        ''
    ) -join "`r`n"

    $temporaryPath = Join-Path $parent ('.config.{0}.tmp.psd1' -f [guid]::NewGuid().ToString('N'))
    try {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($temporaryPath, $content, $encoding)

        # Validate the generated data file before replacing the active config.
        $null = Import-PublisherConfig -Path $temporaryPath

        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $fullPath, $null)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
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

    Write-Host '============================================================'
    Write-Host "Latest source : $($latestSource.Name)"
    Write-Host "Modified      : $($latestSource.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "Published NWD : $publishedTime"
    Write-Host '============================================================'

    if ($publishedNwd -and $publishedNwd.LastWriteTimeUtc -ge $latestSource.LastWriteTimeUtc) {
        Write-Host ''
        Write-Host 'Published NWD is already up to date.' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host 'Publishing is required.' -ForegroundColor Yellow
    Write-Host ''

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
            Invoke-NwdPublisher -Config $config
        }
        finally {
            if ($lockStream) {
                $lockStream.Dispose()
            }
        }
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
