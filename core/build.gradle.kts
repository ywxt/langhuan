plugins {
    id("kotlin-conventions")
    id("testing-conventions")
    id("dokka-conventions")
}



dependencies {
    implementation(libs.bundles.result)
    implementation(libs.bundles.kotlinLogging)

    implementation(libs.bundles.ktorClient)
    implementation(libs.bundles.coroutines)
}
