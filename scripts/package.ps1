param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $ProjectRoot
$version = [regex]::Match([IO.File]::ReadAllText((Join-Path $ProjectRoot 'pubspec.yaml')), '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Groups[1].Value
if (!$version) { throw 'No release version found in pubspec.yaml.' }
$release = Join-Path $ProjectRoot 'build/windows/x64/runner/Release'
$apk = Join-Path $ProjectRoot 'build/app/outputs/flutter-apk/app-release.apk'
if (!(Test-Path -LiteralPath (Join-Path $release 'hongguo_studio.exe'))) { throw 'Build Windows release first.' }
if (!(Test-Path -LiteralPath (Join-Path $release 'runtime/node.exe'))) { throw 'Bundled signing runtime is missing.' }
if (!(Test-Path -LiteralPath (Join-Path $release 'runtime/openhongguo-playback.exe'))) { throw 'Bundled playback component is missing.' }
if (!(Test-Path -LiteralPath $apk)) { throw 'Build Android release first.' }
$dist = Join-Path $ProjectRoot 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$staging = Join-Path $dist ('Hongputao-Windows-' + $version)
if (Test-Path -LiteralPath $staging) { throw 'Package staging directory exists. Choose a new version or archive the existing package.' }
New-Item -ItemType Directory $staging | Out-Null
$packages = Get-Content -LiteralPath '.dart_tool/package_config.json' -Raw | ConvertFrom-Json
if ($packages.packages.name -contains 'jni') { throw 'A JVM-linked native dependency has returned. Audit it before publishing a standalone Windows package.' }
# An incremental build may retain a DLL from the former JNI dependency. It is not part of the current package graph.
Get-ChildItem -LiteralPath $release | Where-Object { $_.Extension -ne '.pdb' -and $_.Name -ne 'dartjni.dll' } | Copy-Item -Destination $staging -Recurse
# App-local CRT: the destination computer need not have Visual Studio or VC++ redistributables installed.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$crt = Get-ChildItem -LiteralPath (Join-Path $vs 'VC/Redist/MSVC') -Directory | Sort-Object Name -Descending | ForEach-Object {
    Get-ChildItem -Path (Join-Path $_.FullName 'x64/Microsoft.VC*.CRT') -Directory -ErrorAction SilentlyContinue
} | Select-Object -First 1
if ($null -eq $crt) { throw 'Visual C++ app-local runtime was not found.' }
Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' | Copy-Item -Destination $staging
Copy-Item -LiteralPath 'licenses/Node-LICENSE.txt' -Destination (Join-Path $staging 'runtime/LICENSE.txt')
Copy-Item -LiteralPath 'README.md','THIRD_PARTY_NOTICES.md','LICENSE' -Destination $staging
New-Item -ItemType Directory -Force (Join-Path $staging 'licenses') | Out-Null
Get-ChildItem -LiteralPath 'licenses' | Copy-Item -Destination (Join-Path $staging 'licenses') -Recurse -Force
New-Item -ItemType Directory -Force (Join-Path $staging 'docs') | Out-Null
Get-ChildItem -LiteralPath 'docs' | Copy-Item -Destination (Join-Path $staging 'docs') -Recurse -Force
Compress-Archive -LiteralPath $staging -DestinationPath (Join-Path $dist "Hongputao-Windows-$version.zip")
Copy-Item -LiteralPath $apk -Destination (Join-Path $dist "Hongputao-Android-arm64-$version.apk")
# Git's ignore rules exclude generated data, recordings, device identities and signing keys.
$files = @(git ls-files --cached --others --exclude-standard) | Sort-Object -Unique
Add-Type -AssemblyName System.IO.Compression
$sourceZip = Join-Path $dist "Hongputao-Source-$version.zip"
$archive = [IO.Compression.ZipFile]::Open($sourceZip,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in $files) {
        if ($relative -match '(^|/)(\.git|\.local|build|dist|\.dart_tool)/|key\.properties$|\.(jks|keystore)$') { continue }
        $full = Join-Path $ProjectRoot $relative
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$full,$relative,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
} finally { $archive.Dispose() }
& (Join-Path $ProjectRoot 'scripts/build-installer.ps1') -ProjectRoot $ProjectRoot
# The installer build already wrote checksums for this version's artifacts.
Write-Output 'Windows installer, portable backup, Android APK, source and SHA256 hashes packaged under dist/.'
