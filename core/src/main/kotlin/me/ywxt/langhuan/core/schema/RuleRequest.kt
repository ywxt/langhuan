package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import com.soywiz.korte.Template
import io.ktor.http.*
import io.ktor.utils.io.charsets.*
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
