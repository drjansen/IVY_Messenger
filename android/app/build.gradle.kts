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
val keyProperties = java.util.Properties()
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
}

android {
    namespace     = "app.icsportals.ics_messenger_app"
    compileSdk    = 36
    ndkVersion    = "27.0.12077973"

    compileOptions {
        // Compile & target Java 17 bytecode (supported by Kotlin & AGP)
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true

    }
    kotlin {
        jvmToolchain(17)
    }

    defaultConfig {
        applicationId = "app.icsportals.ics_messenger_app"
        minSdk = flutter.minSdkVersion
        targetSdk     = 35
        versionCode   = 23
        versionName   = "6.6"
    }

    signingConfigs {
        if (keyPropertiesFile.exists()) {
            create("release") {
                keyAlias     = keyProperties["keyAlias"]     as String
                keyPassword  = keyProperties["keyPassword"]  as String
                storeFile    = file(keyProperties["storeFile"] as String)
                storePassword = keyProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the release signing config only when key.properties is present.
            // Do NOT fall back to the debug signing config — debug keys must never
            // be used to sign production releases.
            if (keyPropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Emit a visible warning so developers know the APK will be unsigned.
                // Google Play will reject unsigned APKs, so this must be resolved
                // before publishing. See SECURITY.md for setup instructions.
                logger.warn(
                    "[WARN] android/key.properties not found. " +
                    "Release APK will be UNSIGNED and cannot be published to Google Play. " +
                    "See SECURITY.md for release signing setup instructions."
                )
                signingConfig = null
            }
            // Use ProGuard files for release, appending missing rules if needed
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// --- Modern JVM Toolchain support for ultimate JVM target consistency ---
java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

// --- Modern Kotlin JVM Target (recommended, outside android block) ---
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:32.1.1"))
    implementation("com.google.firebase:firebase-messaging")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // --- Add explicit OkHttp dependency for R8/proguard compatibility ---
    implementation("com.squareup.okhttp3:okhttp:4.11.0")
}

flutter {
    source = "../.."
}