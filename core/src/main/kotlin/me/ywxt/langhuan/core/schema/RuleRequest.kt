package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import com.soywiz.korte.Template
import io.ktor.http.*
import io.ktor.utils.io.charsets.*
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action
import me.ywxt.langhuan.core.http.ContentType

data class RuleRequest(
    val url: Template,
    val method: HttpMethod = HttpMethod.Get,
    val headers: Map<String, String>? = null,
    val body: Pair<ContentType, String>? = null,
)

suspend fun RuleRequest.buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> = either {
    val variables = env.getAllVariables()
    val url =
        Either.catch { url(variables) }.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }
            .bind()
    val charset = Either.catch {
        env.getVariable("charset") as Charset
    }.mapLeft { InterfaceError.InvalidVariable("charset") }.bind()
    val builder = Action.Builder(url).charset(charset)
    val headers = env.getAllHeaders()
    builder.headers(headers).method(method)
    if (body != null) {
        builder.contentType(body.first).body(body.second)
    }

    builder.build().mapLeft { InterfaceError.NetworkError(it) }.bind()
}
