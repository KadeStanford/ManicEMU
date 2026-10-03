param(
    [Parameter(Mandatory = $true)][string]$InputIpa,
    [Parameter(Mandatory = $true)][string]$CoreBinary,
    [Parameter(Mandatory = $true)][string]$OutputIpa
)

$ErrorActionPreference = 'Stop'
$entryName = 'Payload/ManicEmuSideload.app/Frameworks/azahar.libretro.framework/azahar.libretro'
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sevenZip)) { throw '7-Zip is required for this packaging script.' }

$inputPath = (Resolve-Path -LiteralPath $InputIpa).Path
$corePath = (Resolve-Path -LiteralPath $CoreBinary).Path
$outputPath = [IO.Path]::GetFullPath($OutputIpa)
if ($inputPath -eq $outputPath) { throw 'OutputIpa must differ from InputIpa.' }
if (Test-Path -LiteralPath $outputPath) { throw 'OutputIpa already exists.' }

Add-Type -AssemblyName System.IO.Compression
$before = [IO.Compression.ZipFile]::OpenRead($inputPath)
try {
    $original = @($before.Entries | Where-Object { $_.FullName -replace '\\','/' -eq $entryName })
    if ($original.Count -ne 1) { throw "Expected one Azahar core in input IPA; found $($original.Count)." }
    $entryCount = $before.Entries.Count
} finally { $before.Dispose() }

$staging = Join-Path ([IO.Path]::GetTempPath()) ('manic-azahar-' + [Guid]::NewGuid().ToString('N'))
$stagedCore = Join-Path $staging ($entryName -replace '/', [IO.Path]::DirectorySeparatorChar)
try {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stagedCore)) | Out-Null
    Copy-Item -LiteralPath $corePath -Destination $stagedCore
    Copy-Item -LiteralPath $inputPath -Destination $outputPath
    Push-Location $staging
    try {
        & $sevenZip u -tzip -mx=9 $outputPath $entryName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip update failed with exit code $LASTEXITCODE." }
    } finally { Pop-Location }

    $after = [IO.Compression.ZipFile]::OpenRead($outputPath)
    try {
        if ($after.Entries.Count -ne $entryCount) { throw 'The IPA entry count changed unexpectedly.' }
        $replaced = @($after.Entries | Where-Object { $_.FullName -replace '\\','/' -eq $entryName })
        if ($replaced.Count -ne 1) { throw "Expected one Azahar core in output IPA; found $($replaced.Count)." }
        $expectedHash = (Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash
        $hash = [Security.Cryptography.SHA256]::Create()
        try {
            $stream = $replaced[0].Open()
            try { $actualHash = [Convert]::ToHexString($hash.ComputeHash($stream)) }
            finally { $stream.Dispose() }
        } finally { $hash.Dispose() }
        if ($actualHash -ne $expectedHash) { throw 'The packaged core hash does not match the source binary.' }
    } finally { $after.Dispose() }
    Write-Output "Packaged Azahar core: $outputPath"
    Write-Output "Core SHA-256: $expectedHash"
} catch {
    if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
    throw
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedStaging = [IO.Path]::GetFullPath($staging)
    if ($resolvedStaging.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedStaging)) {
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
    }
}

