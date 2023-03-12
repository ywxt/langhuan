import gradle.kotlin.dsl.accessors._0e8e380d08442f6907b17d5d94df1059.build
import gradle.kotlin.dsl.accessors._0e8e380d08442f6907b17d5d94df1059.javadoc

val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")

plugins {
    id("org.jetbrains.dokka")
}

tasks.withType<Javadoc>().all {
    enabled = false
}

tasks.dokkaJavadoc {
    outputDirectory.set(buildDir.resolve("javadoc"))
}

tasks.build {
    finalizedBy(tasks.dokkaHtml)
}
