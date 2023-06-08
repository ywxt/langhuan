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

import io.ktor.http.*
import java.nio.charset.Charset

data class Context<T>(
    val id: String,
    val name: String,
    val headers: Map<String, String>,
    val site: Url,
    val charset: Charset = Charsets.UTF_8,
    val local: T,
)

fun <T> SchemaConfig.toContext(local: T, request: RequestRule): Context<T> = Context(
    id = this.id,
    name = this.name,
    site = this.site,
    charset = this.charset,
    headers = if (request.headers == null) this.defaultHeaders else this.defaultHeaders + request.headers,
    local = local,
)

internal data class ResultContext<T>(
    val id: String,
    val name: String,
    val headers: Map<String, String>,
    val site: Url,
    val charset: Charset = Charsets.UTF_8,
    val result: String,
    val local: T,
)

internal fun <T> Context<T>.toResultContext(result: String): ResultContext<T> = ResultContext(
    id = this.id,
    name = this.name,
    headers = this.headers,
    site = this.site,
    charset = this.charset,
    result = result,
    local = this.local,
)
