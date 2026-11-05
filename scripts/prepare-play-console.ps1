# BCN Printer Worker - prepare Android app for Play Console (Windows PowerShell)
# Existing key.properties and keystore are reused; never commit them.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$appId = 'com.bcncl.androidprinteroc'
$manifestPath = Join-Path $root 'android/app/src/main/AndroidManifest.xml'
$manifestBackup = if (Test-Path $manifestPath) { [System.IO.File]::ReadAllText($manifestPath) } else { $null }

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter executable not found in PATH.'
}
$gradlePath = Join-Path $root 'android/app/build.gradle.kts'
if (-not (Test-Path $gradlePath)) {
    Write-Host 'Generating missing Android platform scaffold ...'
    & flutter create --platforms=android --project-name android_printer --org com.bcncl .
    if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
}
if ($null -ne $manifestBackup) {
    [System.IO.File]::WriteAllText($manifestPath, $manifestBackup, (New-Object System.Text.UTF8Encoding($false)))
}
if (-not (Test-Path $gradlePath)) {
    throw 'Expected android/app/build.gradle.kts. Check Flutter-generated Android scaffold.'
}
$g = [System.IO.File]::ReadAllText($gradlePath)
$g = [regex]::Replace($g, '(?m)^([ \t]*namespace\s*=\s*)".*?"', ('${1}"' + $appId + '"'))
$g = [regex]::Replace($g, '(?m)^([ \t]*applicationId\s*=\s*)".*?"', ('${1}"' + $appId + '"'))
$g = [regex]::Replace($g, '(?m)^([ \t]*compileSdk\s*=\s*).*$', '${1}36')
$g = [regex]::Replace($g, '(?m)^([ \t]*targetSdk\s*=\s*).*$', '${1}36')
if ($g -notmatch [regex]::Escape('applicationId = "' + $appId + '"')) {
    throw 'applicationId not found; edit android/app/build.gradle.kts manually.'
}
if ($g -notmatch 'keystorePropertiesFile') {
    $header = @'
import java.io.FileInputStream
import java.util.Properties

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

'@
    $g = $header + $g
}
if ($g -notmatch 'create\("release"\)') {
    $signingConfig = @'
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }
'@
    if (-not $g.Contains('android {')) { throw 'Android Gradle block missing.' }
    $g = $g.Replace('android {', "android {`r`n" + $signingConfig)
}
$debugConfig = 'signingConfig = signingConfigs.getByName("debug")'
$releaseConfig = 'signingConfig = signingConfigs.getByName("release")'
if ($g.Contains($debugConfig)) {
    $g = $g.Replace($debugConfig, $releaseConfig)
}
if (-not $g.Contains($releaseConfig)) {
    throw 'Release signing assignment not found; review build.gradle.kts.'
}
[System.IO.File]::WriteAllText($gradlePath, $g, (New-Object System.Text.UTF8Encoding($false)))
$keyProps = Join-Path $root 'android/key.properties'
if (Test-Path $keyProps) {
    Write-Host 'Existing android/key.properties found. Reusing existing signing configuration.'
} else {
    Write-Warning 'android/key.properties not found in this checkout. Copy existing file locally; DO NOT commit it.'
}
Write-Host "Prepared package ID: $appId"
Write-Host 'Target SDK: 36'
Write-Host 'Review signing details locally, then run:'
Write-Host 'flutter pub get'
Write-Host 'flutter analyze'
Write-Host 'flutter test'
Write-Host 'flutter build appbundle --release'
