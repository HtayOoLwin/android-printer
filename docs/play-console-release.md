# BCN Printer Worker — Google Play Console release

This repository currently includes Flutter source and a custom `android/app/src/main/AndroidManifest.xml`, **not a complete Gradle Android scaffold**. Do not upload an APK or commit a private signing keystore.

## 1. Prepare the existing app

For an **existing Play Console listing**, determine the exact **Application ID** and current **versionCode** from Play Console first. Keep the same package ID and original upload keystore. A different package ID creates a different app; a lost upload key may require an upload-key reset.

On Windows PowerShell:

```powershell
git checkout main
git pull origin main
flutter doctor -v
flutter create --project-name android_printer .
flutter pub get
```

**Important:** `flutter create .` can generate Android files using a default application ID. Before building, edit the generated `android/app/build.gradle.kts` (or `build.gradle`) to match the existing Play Console app. Preserve the existing `android/app/src/main/AndroidManifest.xml` permissions, app label, and the foreground-service declaration. If Flutter has overwritten that manifest, restore and merge it from Git.

Requested Android package ID: `com.bcncl.androidprinteroc`. Confirm it matches the Play Console listing before building an update.

## 2. Android SDK level and version

As of November 2026, Google Play requires **targetSdk 36 or higher** for new Android phone apps and updates. Install the Android 16 / API 36 SDK and use a Flutter/Android Gradle toolchain that supports it.

Inside `android/app/build.gradle.kts`:

```kotlin
android {
    namespace = "com.bcncl.androidprinteroc" // only if verified
    compileSdk = 36
    defaultConfig {
        applicationId = "com.bcncl.androidprinteroc" // only if verified
        targetSdk = 36
        // Keep or choose a minSdk compatible with your plugins/devices.
    }
}
```

Check the locally generated configuration before editing: do not duplicate an existing `android` block. If an older package ID is registered in Play Console, retain it instead.

In `pubspec.yaml`, `version: 0.1.0+1` is currently checked in. Choose a **versionCode greater than the highest code already uploaded**. For example, `version: 1.0.1+2` only if code 2 is unused. Change the version manually after confirming the Console value.

## 3. Configure the original upload signing key

For an existing app, **reuse the original upload signing key**. If you already have `android/key.properties` and its matching `.jks` keystore, **reuse both**. Do not regenerate signing keys. Only for a brand-new app with no key, create a private key:

```powershell
keytool -genkeypair -v -keystore "$env:USERPROFILE\bcn-printer-upload.jks" -alias upload -keyalg RSA -keysize 3072 -validity 10000
```

Create `android/key.properties` locally (this filename and `*.jks` are gitignored):

```properties
storePassword=YOUR_PRIVATE_PASSWORD
keyPassword=YOUR_PRIVATE_PASSWORD
keyAlias=upload
storeFile=C:\\Users\\YOUR_WINDOWS_USER\\bcn-printer-upload.jks
```

Do not commit this file or share its content.

In a generated Kotlin Gradle script `android/app/build.gradle.kts`, add at the top:

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
```

Inside the existing `android { ... }` block:

```kotlin
signingConfigs {
    create("release") {
        keyAlias = keystoreProperties.getProperty("keyAlias")
        keyPassword = keystoreProperties.getProperty("keyPassword")
        storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
        storePassword = keystoreProperties.getProperty("storePassword")
    }
}
buildTypes {
    getByName("release") {
        signingConfig = signingConfigs.getByName("release")
    }
}
```

Do not keep the generated `signingConfig = signingConfigs.getByName("debug")` in release.

## 4. Validate and build an AAB

```powershell
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build appbundle --release
```

The signed bundle should appear at `build/app/outputs/bundle/release/app-release.aab`. Check that the build output confirms the correct signing configuration and targetSdk.

Before rollout, install a signed test build on a dedicated Android printer device and verify:
- Same ERPNext login and saved printer configuration after updating the existing app
- Bluetooth and Wi-Fi printing
- Foreground-service notification and 5-second polling while app is backgrounded
- Normal cashier receipt and Daily Sales Report **REPRINT** receipt
- Job acknowledgement `Pending → Processing → Printed` (and printer failure reporting)

## 5. Upload to Play Console

Visit https://play.google.com/console → select **BCN Printer Worker** → **Testing → Internal testing** → **Create new release** → upload the `.aab`. Fill release notes, review errors and submit rollout. Once verified, promote to production through the Console workflow and complete any required declarations (foreground service, Bluetooth permissions, data safety, app access, privacy policy).

Do not upload a new package as an update to a previously created Play Console app. Do not create a new keystore for an update unless the original upload key was reset officially.

See the official guides:
- https://docs.flutter.dev/deployment/android
- https://support.google.com/googleplay/android-developer/answer/11926878
