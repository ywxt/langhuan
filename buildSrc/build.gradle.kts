val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")

plugins {
    // Support convention plugins written in Kotlin. Convention plugins are build scripts in 'src/main'
    // that automatically become available as plugins in the main build.
    `kotlin-dsl`
}

repositories {
    // Use the plugin portal to apply community plugins in convention plugins.
    gradlePluginPortal()
    mavenCentral()
}

dependencies {
    // buildSrc in combination with this plugin ensures that the version set here
    // will be set to the same for all other Kotlin dependencies / plugins in the project.
    add("implementation", libs.findLibrary("kotlin-gradle").get())

   
    // https://github.com/Kotlin/dokka
    // Dokka is a documentation engine for Kotlin like JavaDoc for Java
    add("implementation", libs.findLibrary("dokka-gradle").get())

    // https://detekt.dev/docs/gettingstarted/gradle/
    // A static code analyzer for Kotlin
    add("implementation", libs.findLibrary("detekt-gradle").get())

}
