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
$manifestPath = $outputPath + '.verification.json'
if ($inputPath -eq $outputPath) { throw 'OutputIpa must differ from InputIpa.' }
if (Test-Path -LiteralPath $outputPath) { throw 'OutputIpa already exists.' }
if (Test-Path -LiteralPath $manifestPath) { throw 'Verification manifest already exists.' }

function Get-EntryHashes([IO.Compression.ZipArchive]$archive) {
    $hashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($entry in $archive.Entries) {
            if ($hashes.ContainsKey($entry.FullName)) { throw "Duplicate IPA entry: $($entry.FullName)" }
            $stream = $entry.Open()
            try { $hashes.Add($entry.FullName, [Convert]::ToHexString($sha256.ComputeHash($stream))) }
            finally { $stream.Dispose() }
        }
    } finally { $sha256.Dispose() }
    return $hashes
}

Add-Type -AssemblyName System.IO.Compression
$before = [IO.Compression.ZipFile]::OpenRead($inputPath)
try {
    $original = @($before.Entries | Where-Object { $_.FullName -replace '\\','/' -eq $entryName })
    if ($original.Count -ne 1) { throw "Expected one Azahar core in input IPA; found $($original.Count)." }
    $entryCount = $before.Entries.Count
    $beforeHashes = Get-EntryHashes $before
    $oldCoreHash = $beforeHashes[$entryName]
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
        $afterHashes = Get-EntryHashes $after
        $actualHash = $afterHashes[$entryName]
        if ($actualHash -ne $expectedHash) { throw 'The packaged core hash does not match the source binary.' }
        foreach ($name in $beforeHashes.Keys) {
            if (-not $afterHashes.ContainsKey($name)) { throw "IPA entry disappeared: $name" }
            if ($name -ne $entryName -and $beforeHashes[$name] -ne $afterHashes[$name]) {
                throw "Unexpected IPA content change: $name"
            }
        }
    } finally { $after.Dispose() }
    & $sevenZip t -tzip $outputPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Output IPA CRC check failed with exit code $LASTEXITCODE." }
    $manifest = [ordered]@{
        input_ipa = [IO.Path]::GetFileName($inputPath)
        input_sha256 = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
        output_ipa = [IO.Path]::GetFileName($outputPath)
        output_sha256 = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
        archive_crc_passed = $true
        entry_count = $entryCount
        unchanged_entries = $entryCount - 1
        replaced_entry = $entryName
        previous_core_sha256 = $oldCoreHash
        replacement_core_sha256 = $expectedHash
        signing = 'unsigned; re-sign app and all embedded frameworks'
    }
    $manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Write-Output "Packaged Azahar core: $outputPath"
    Write-Output "Core SHA-256: $expectedHash"
    Write-Output "Verification manifest: $manifestPath"
} catch {
    if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    throw
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedStaging = [IO.Path]::GetFullPath($staging)
    if ($resolvedStaging.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedStaging)) {
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
    }
}
