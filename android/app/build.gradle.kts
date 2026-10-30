import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use(signingProperties::load)
}

fun signingValue(property: String, environment: String): String? =
    System.getenv(environment)?.takeIf(String::isNotBlank)
        ?: signingProperties.getProperty(property)?.takeIf(String::isNotBlank)

android {
    namespace = "org.eu.ywxt.langhuan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
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

    signingConfigs {
        create("release") {
            signingValue("storeFile", "LANGHUAN_ANDROID_KEYSTORE")?.let {
                storeFile = rootProject.file(it)
            }
            storePassword = signingValue("storePassword", "LANGHUAN_ANDROID_STORE_PASSWORD")
            keyAlias = signingValue("keyAlias", "LANGHUAN_ANDROID_KEY_ALIAS")
            keyPassword = signingValue("keyPassword", "LANGHUAN_ANDROID_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            // A release without all four signing values fails instead of silently
            // producing an artifact with the machine-specific debug certificate.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
