# BCN Printer Worker Play release setup - Windows PowerShell.
# Uses existing private android/key.properties and keystore.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$appId = 'com.bcncl.androidprinteroc'
$keyProps = Join-Path $root 'android/key.properties'
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter not found in PATH.'
}
if (-not (Test-Path $keyProps)) {
    throw 'android/key.properties missing. Refusing to generate a debug-signed release.'
}
$properties = @{}
Get-Content $keyProps | ForEach-Object {
    $entry = $_.Trim()
    if ($entry -and -not $entry.StartsWith('#') -and $entry.Contains('=')) {
        $parts = $entry.Split('=', 2)
        $properties[$parts[0].Trim()] = $parts[1].Trim()
    }
}
foreach ($name in @('storeFile','storePassword','keyAlias','keyPassword')) {
    if (-not $properties.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($properties[$name])) {
        throw "Missing signing configuration field: $name"
    }
}
$keystorePath = $properties['storeFile'].Replace('\\', '\')
if (-not [System.IO.Path]::IsPathRooted($keystorePath)) {
    $keystorePath = Join-Path (Join-Path $root 'android/app') $keystorePath
}
if (-not (Test-Path $keystorePath)) {
    throw 'The keystore file specified in storeFile does not exist.'
}
$manifestPath = Join-Path $root 'android/app/src/main/AndroidManifest.xml'
$manifestBackup = if (Test-Path $manifestPath) { [System.IO.File]::ReadAllText($manifestPath) } else { $null }
$gradlePath = Join-Path $root 'android/app/build.gradle.kts'
if (-not (Test-Path $gradlePath)) {
    & flutter create --platforms=android --project-name android_printer --org com.bcncl .
    if ($LASTEXITCODE -ne 0) { throw 'flutter create failed.' }
}
if ($null -ne $manifestBackup) {
    [System.IO.File]::WriteAllText($manifestPath, $manifestBackup, (New-Object System.Text.UTF8Encoding($false)))
}
if (-not (Test-Path $gradlePath)) { throw 'Expected android/app/build.gradle.kts.' }
$g = [System.IO.File]::ReadAllText($gradlePath)
# Replace whole Gradle assignment lines, including an earlier broken quote.
# Avoid script-block callbacks and variable expansion in replacement groups.
if ($g -notmatch '(?m)^\s*applicationId\s*=') {
    throw 'applicationId assignment not found.'
}
if ($g -notmatch '(?m)^\s*compileSdk\s*=') {
    throw 'compileSdk assignment not found.'
}
if ($g -notmatch '(?m)^\s*targetSdk\s*=') {
    throw 'targetSdk assignment not found.'
}
$g = [regex]::Replace(
    $g, '(?m)^\s*applicationId\s*=.*$',
    ('        applicationId = "' + $appId + '"')
)
$g = [regex]::Replace(
    $g, '(?m)^\s*compileSdk\s*=.*$',
    '    compileSdk = 36'
)
$g = [regex]::Replace(
    $g, '(?m)^\s*targetSdk\s*=.*$',
    '        targetSdk = 36'
)
if ($g -notmatch '(?m)^\s*applicationId\s*=\s*"com\.bcncl\.androidprinteroc"\s*$') {
    throw 'Play applicationId validation failed.'
}
if (-not $g.Contains('keystorePropertiesFile')) {
    $header = @'
import java.io.FileInputStream
import java.util.Properties

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
check(keystorePropertiesFile.exists()) { "Missing android/key.properties" }
keystoreProperties.load(FileInputStream(keystorePropertiesFile))

'@
    $g = $header + $g
}
if (-not ($g.Contains('create("release")') -or $g.Contains('getByName("release") {'))) {
    $signing = @'
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

'@
    if (-not $g.Contains('android {')) { throw 'Android Gradle block is missing.' }
    $g = $g.Replace('android {', 'android {' + [char]13 + [char]10 + $signing)
}
$debugSigning = 'signingConfig = signingConfigs.getByName("debug")'
$releaseSigning = 'signingConfig = signingConfigs.getByName("release")'
if ($g.Contains($debugSigning)) {
    $g = $g.Replace($debugSigning, $releaseSigning)
}
if (-not $g.Contains($releaseSigning)) {
    throw 'release signingConfig not found; review build.gradle.kts.'
}
[System.IO.File]::WriteAllText($gradlePath, $g, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Release package ID: $appId"
Write-Host 'Target API: 36; private upload keystore configured.'
Write-Host 'Run: flutter pub get; flutter analyze; flutter test; flutter build appbundle --release'
