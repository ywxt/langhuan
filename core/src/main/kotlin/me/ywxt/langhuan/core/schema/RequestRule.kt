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

data class RequestRule(
    val url: Template,
    val method: RequestMethod = RequestMethod.GET,
    val headers: Map<String, String>? = null,
    val body: Pair<ContentType, Template>? = null,
) {
    companion object {
        suspend fun fromConfig(request: RequestSection): Either<ConfigParsingError, RequestRule> = either {
            RequestRule(
                url = TemplateWithConfig(request.url).bind(),
                method = request.method,
                headers = request.headers,
                body = request.content?.let { it.contentType to TemplateWithConfig(it.body).bind() }
            )
        }
    }
}

internal fun RequestMethod.transformHttpMethod() = when (this) {
    RequestMethod.GET -> HttpMethod.Get
    RequestMethod.POST -> HttpMethod.Post
    RequestMethod.PUT -> HttpMethod.Put
    RequestMethod.DELETE -> HttpMethod.Delete
}

private fun ContentType.transformContentType(): me.ywxt.langhuan.core.http.ContentType =
    when (this@transformContentType) {
        ContentType.JSON -> me.ywxt.langhuan.core.http.ContentType.JSON
        ContentType.FORM -> me.ywxt.langhuan.core.http.ContentType.FORM
    }

suspend fun RequestRule.buildAction(context: Context<*>): Either<InterfaceError, Action> = either {
    val url =
        catchException { url.render(context) }.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }.bind()
    val charset = context.charset
    val builder = Action.Builder(url).charset(charset)
    val headers = context.headers
    builder.headers(headers).method(method)
    catchException {
        body?.apply { builder.contentType(first.transformContentType()).body(second.render(context)) }
    }.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }.bind()
    builder.build().mapLeft { InterfaceError.NetworkError(it) }.bind()
}
