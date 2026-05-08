import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

buildscript {
    repositories {
        google()           // ✅ Required for Firebase & Android plugins
        mavenCentral()
    }
    dependencies {
        // Firebase “google-services” plugin
        classpath("com.google.gms:google-services:4.4.3")
        // Desugaring support for Java 8+ APIs (enables coreLibraryDesugaring in modules)
        classpath("com.android.tools:desugar_jdk_libs:2.1.5")
        // 🆕 Add Kotlin Gradle plugin for Kotlin 2.0+
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.0.0")
        // ↑↑↑ Upgrade this version as needed if other plugins require 2.1.x or 2.2.x
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ── Custom build directory for monorepo style projects ──
val newBuildDir: Directory = rootProject
    .layout
    .buildDirectory
    .dir("../../build")
    .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    project.evaluationDependsOn(":app")
}

// ── Override JVM target for Kotlin *and* Java globally ──
subprojects {
    tasks.withType<JavaCompile>().configureEach {
        sourceCompatibility = "17"
        targetCompatibility = "17"

    }
    tasks.withType<KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}