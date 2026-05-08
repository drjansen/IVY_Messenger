plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
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

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
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