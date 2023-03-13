plugins {
    id("kotlin-conventions")
    id("testing-conventions")
    id("dokka-conventions")
    id("version-conventions")

    kotlin("plugin.serialization")
}


dependencies {
    implementation(libs.bundles.arrow)
    implementation(libs.bundles.kotlinLogging)
    implementation(libs.bundles.korte)
    implementation(libs.bundles.jsoup)
    implementation(libs.bundles.kaml)

    implementation(libs.bundles.ktorClient)
    implementation(libs.bundles.coroutines)
}
