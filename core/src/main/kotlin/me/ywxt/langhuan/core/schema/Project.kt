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
package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.raise.either
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.config.ProjectSection

data class Project(
    val name: String,
    val id: String,
    val author: String,
    val schemas: List<Schema>,
) {
    companion object {
        suspend fun fromConfig(config: ProjectSection): Either<ConfigParsingError, Project> = either {
            Project(
                name = config.name,
                id = config.id,
                author = config.author,
                schemas = config.schemas.map { Schema.fromConfig(it).bind() }
            )
        }
    }
}
