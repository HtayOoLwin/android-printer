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
$patterns = @(
    @('(?m)^(\s*applicationId\s*=\s*)"[^"]*"', '"' + $appId + '"'),
    @('(?m)^(\s*compileSdk\s*=\s*).*$', '36'),
    @('(?m)^(\s*targetSdk\s*=\s*).*$', '36')
)
foreach ($pair in $patterns) {
    $pattern = $pair[0]
    $replacement = $pair[1]
    if (-not [regex]::IsMatch($g, $pattern)) { throw "Missing Gradle setting: $pattern" }
    $g = [regex]::Replace($g, $pattern, {
        param($m)
        return $m.Groups[1].Value + $replacement
    })
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
