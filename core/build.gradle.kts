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
plugins {
    id("kotlin-conventions")
    id("testing-conventions")
    id("dokka-conventions")
    id("version-conventions")
    id("license-conventions")
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
