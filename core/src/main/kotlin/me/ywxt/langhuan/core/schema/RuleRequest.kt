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
import arrow.core.continuations.either
import com.soywiz.korte.Template
import io.ktor.http.*
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action
import me.ywxt.langhuan.core.http.ContentType
import me.ywxt.langhuan.core.utils.catchException

data class RuleRequest(
    val url: Template,
    val method: HttpMethod = HttpMethod.Get,
    val headers: Map<String, String>? = null,
    val body: Pair<ContentType, Template>? = null,
)

suspend fun RuleRequest.buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> = either {
    val variables = env.getAllVariables()
    val url = catchException { url(variables) }.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }.bind()
    val charset = env.getCharset().bind()
    val builder = Action.Builder(url).charset(charset)
    val headers = env.getAllHeaders()
    builder.headers(headers).method(method)
    catchException {
        body?.apply { builder.contentType(first).body(second(env.getAllVariables())) }
    }.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }.bind()
    builder.build().mapLeft { InterfaceError.NetworkError(it) }.bind()
}
