plugins {
    id("kotlin-conventions")
    id("testing-conventions")
    id("dokka-conventions")
}



dependencies {
    implementation(libs.bundles.result)
    implementation(libs.bundles.kotlinLogging)
    implementation(libs.bundles.korte)
    implementation(libs.bundles.jsoup)

    implementation(libs.bundles.ktorClient)
    implementation(libs.bundles.coroutines)
}
