plugins {
    id("kotlin-conventions")
    id("testing-conventions")
    id("dokka-conventions")
    id("version-conventions")
}



dependencies {
    implementation(libs.bundles.kotlinLogging)
}
