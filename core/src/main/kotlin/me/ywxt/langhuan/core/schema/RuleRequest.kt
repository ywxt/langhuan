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
import io.ktor.http.*
import korlibs.template.Template
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.config.ContentType
import me.ywxt.langhuan.core.config.RequestMethod
import me.ywxt.langhuan.core.config.RequestSection
import me.ywxt.langhuan.core.http.Action
import me.ywxt.langhuan.core.utils.catchException

data class RuleRequest(
    val url: Template,
    val method: HttpMethod = HttpMethod.Get,
    val headers: Map<String, String>? = null,
    val body: Pair<me.ywxt.langhuan.core.http.ContentType, Template>? = null,
) {
    companion object {
        suspend fun fromConfig(request: RequestSection): Either<ConfigParsingError, RuleRequest> = either {
            RuleRequest(
                url = TemplateWithConfig(request.url).bind(),
                method = transformHTTPMethod(request.method),
                headers = request.headers,
                body = request.content?.let { transformContentType(it.contentType, it.body).bind() }
            )
        }
    }
}

private fun transformHTTPMethod(method: RequestMethod) = when (method) {
    RequestMethod.GET -> HttpMethod.Get
    RequestMethod.POST -> HttpMethod.Post
    RequestMethod.PUT -> HttpMethod.Put
    RequestMethod.DELETE -> HttpMethod.Delete
}

private suspend fun transformContentType(
    contentType: ContentType,
    body: String,
): Either<ConfigParsingError, Pair<me.ywxt.langhuan.core.http.ContentType, Template>> =
    either {
        when (contentType) {
            ContentType.JSON -> Pair(me.ywxt.langhuan.core.http.ContentType.JSON, TemplateWithConfig(body).bind())
            ContentType.FORM -> Pair(me.ywxt.langhuan.core.http.ContentType.FORM, TemplateWithConfig(body).bind())
        }
    }

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
