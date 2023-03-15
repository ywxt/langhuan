/**
 * Copyright 2023 ywxt
 *
 * This file is part of Langhuan.
 *
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */
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

    add("implementation", libs.findLibrary("gradle-versions").get())

    add("implementation", libs.findLibrary("kotlin-serialization").get())

    add("implementation", libs.findLibrary("gradle-license").get())

}
