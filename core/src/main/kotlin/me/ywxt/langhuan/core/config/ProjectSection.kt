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
package me.ywxt.langhuan.core.config

import arrow.core.Either
import com.charleskorn.kaml.Yaml
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.utils.catchException

@Serializable
data class ProjectSection(
    val name: String,
    val id: String,
    val author: String,
    val schemas: List<SchemaSection>,
) {
    companion object {
        fun fromString(config: String): Either<ConfigParsingError, ProjectSection> = catchException {
            Yaml.default.decodeFromString(serializer(), config)
        }.mapLeft {
            ConfigParsingError(
                it.message ?: "Cannot parse the config `$config` as a ProjectSection.",
                it.stackTrace.toList()
            )
        }
    }

    fun encodeToString(): Either<ConfigParsingError, String> = catchException {
        Yaml.default.encodeToString(this)
    }.mapLeft { ConfigParsingError(it.message ?: "Cannot encode the ProjectSection(`$name`).", it.stackTrace.toList()) }
}
