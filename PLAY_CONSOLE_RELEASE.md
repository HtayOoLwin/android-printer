# BCN Printer Worker — Google Play release preparation

Desired app label: **BCN Printer Worker**  
Required applicationId: **com.bcncl.androidprinter**  
Branch: `release/play-console-signing-20261021`

## IMPORTANT: Android scaffolding is absent from this GitHub branch

Currently the repo tracks only `android/app/src/main/AndroidManifest.xml`; it has no `android/app/build.gradle.kts`, `android/settings.gradle.kts`, `android/gradle/wrapper`, or MainActivity source. Therefore signing and AAB cannot be verified from this checkout yet. **Do not upload or claim a completed release.**

### Restore a complete Flutter Android project locally

1. First back up the existing `android/app/src/main/AndroidManifest.xml` (it contains Bluetooth, connectivity, notification and connected-device foreground service declarations). Also back up your local Android files, if any.
2. From repository root, run `flutter create --platforms=android --org com.bcncl .` using the Flutter SDK version you'll build with. This typically generates ID `com.bcncl.android_printer` from project name; **that is not the required Play package ID**.
3. Set `applicationId = "com.bcncl.androidprinter"` and `namespace = "com.bcncl.androidprinter"` in generated `android/app/build.gradle.kts`. Update the Kotlin MainActivity package declaration/path accordingly.
4. Restore/merge all original manifest permissions and the `flutter_background_service` service element. Keep app label `BCN Printer Worker`. Check Android 13+ notification permission behavior and Android 14+ connectedDevice foreground service policy.
5. Apply secure release signing as in the sample below, and commit only safe Gradle/scaffolding files, not passwords/keystore.

### Local keystore
```powershell
keytool -genkeypair -v -keystore android/upload-keystore.jks -keyalg RSA -keysize 3072 -validity 10000 -alias upload
Copy-Item android/key.properties.example android/key.properties
```

Fill in local `android/key.properties` passwords. Place the JKS at `android/upload-keystore.jks`. Never commit the JKS, `android/key.properties` or passwords. `.gitignore` covers them.

### Gradle Kotlin DSL signing snippet

Use these imports at the start of `android/app/build.gradle.kts`:

```kotlin
import java.io.FileInputStream
import java.util.Properties

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
```

Inside the existing `android { ... }` block, add a release signing config and use it for release:

```kotlin
signingConfigs {
    if (keystorePropertiesFile.exists()) create("release") {
        keyAlias = keystoreProperties.getProperty("keyAlias")
        keyPassword = keystoreProperties.getProperty("keyPassword")
        storePassword = keystoreProperties.getProperty("storePassword")
        storeFile = file(keystoreProperties.getProperty("storeFile"))
    }
}
buildTypes {
    release {
        if (keystorePropertiesFile.exists()) {
            signingConfig = signingConfigs.getByName("release")
        } else if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }) {
            throw GradleException("Release signing requires android/key.properties.")
        }
    }
}
```

Verify this compiles with your generated Gradle/Flutter version before release.

### Build and test

```powershell
flutter pub get
flutter analyze
flutter test
flutter build appbundle --release
```

AAB expected at `build/app/outputs/bundle/release/app-release.aab`. Verify the package ID, Play-required target API, runtime notification, background printing permissions, auto-print lifecycle and signed AAB before submitting. Install app and run Wi-Fi/Bluetooth printer tests on actual Android hardware; Test Track is strongly recommended before Production.
