plugins {
    id("org.jetbrains.dokka")
}

tasks.withType<Javadoc>().all {
    enabled = false
}

tasks.dokkaJavadoc {
    outputDirectory.set(buildDir.resolve("javadoc"))
}

tasks.named("build") {
    finalizedBy(tasks.dokkaHtml)
}
