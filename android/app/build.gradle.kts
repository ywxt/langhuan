import groovy.json.JsonSlurper
import org.gradle.api.GradleException
import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

data class RustlsPlatformVerifierAndroid(
    val mavenRepo: String,
    val version: String,
)

fun findRustlsPlatformVerifierAndroid(): RustlsPlatformVerifierAndroid {
    val dependencyText = providers.exec {
        workingDir = file("../")
        commandLine(
            "cargo",
            "metadata",
            "--format-version",
            "1",
            "--filter-platform",
            "aarch64-linux-android",
            "--manifest-path",
            "../native/hub/Cargo.toml",
        )
    }.standardOutput.asText.get()

    @Suppress("UNCHECKED_CAST")
    val packages = (JsonSlurper().parseText(dependencyText) as Map<String, Any?>)["packages"]
        as? List<Map<String, Any?>>
        ?: throw GradleException("cargo metadata did not return a packages array")

    val packageInfo = packages
        .firstOrNull { it["name"] == "rustls-platform-verifier-android" }
        ?: throw GradleException("rustls-platform-verifier-android was not found in cargo metadata")

    val manifestPath = packageInfo["manifest_path"] as? String
        ?: throw GradleException("rustls-platform-verifier-android was not found in cargo metadata")

    val version = packageInfo["version"] as? String
        ?: throw GradleException("rustls-platform-verifier-android version was not found in cargo metadata")

    return RustlsPlatformVerifierAndroid(
        mavenRepo = File(File(manifestPath).parentFile, "maven").path,
        version = version,
    )
}

val rustlsPlatformVerifierAndroid = findRustlsPlatformVerifierAndroid()

repositories {
    maven {
        url = uri(rustlsPlatformVerifierAndroid.mavenRepo)
        metadataSources {
            mavenPom()
            artifact()
        }
    }
}

android {
    namespace = "org.eu.ywxt.langhuan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.eu.ywxt.langhuan"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation("rustls:rustls-platform-verifier:${rustlsPlatformVerifierAndroid.version}")
}

flutter {
    source = "../.."
}
