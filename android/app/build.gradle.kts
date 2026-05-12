import java.io.FileInputStream
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// --- Release signing ---
// Read signing credentials from android/key.properties (gitignored).
// If the file is absent the release APK is produced unsigned; Google Play
// will reject unsigned APKs, which is the safe default.
// See SECURITY.md for instructions on setting up release signing.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    FileInputStream(keyPropertiesFile).use { keyProperties.load(it) }
}

android {
    namespace = "app.icsportals.ics_messenger_app"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "app.icsportals.ics_messenger_app"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = 23
        versionName = "6.6"
    }

    signingConfigs {
        if (keyPropertiesFile.exists()) {
            create("release") {
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
                storeFile = file(keyProperties["storeFile"] as String)
                storePassword = keyProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (keyPropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "[WARN] android/key.properties not found. " +
                            "Release APK will be UNSIGNED and cannot be published to Google Play. " +
                            "See SECURITY.md for release signing setup instructions."
                )
            }

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

tasks.withType<KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:32.1.1"))
    implementation("com.google.firebase:firebase-messaging")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.squareup.okhttp3:okhttp:4.11.0")
}

flutter {
    source = "../.."
}