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

import kotlinx.serialization.Serializable
import me.ywxt.langhuan.core.parse.SCHEMA_DEFAULT_ENCODING_NAME
import me.ywxt.langhuan.core.parse.schemaDefaultHeaders

@Serializable
data class SchemaSection(
    val name: String,
    val id: String,
    val site: String,
    val headers: Map<String, String> = schemaDefaultHeaders,
    val charset: String = SCHEMA_DEFAULT_ENCODING_NAME,
    val search: SearchSection,
    val bookInfo: BookInfoSection,
    val contents: ContentsSection,
    val chapter: ChapterSection,
)
