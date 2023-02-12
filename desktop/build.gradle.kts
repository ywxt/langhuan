plugins {
    id("kotlin-conventions")
    id("testing-conventions")
    id("dokka-conventions")
}

val kotlinLoggingVersion: String by rootProject.extra

dependencies {
    implementation(libs.bundles.kotlinLogging)
}
