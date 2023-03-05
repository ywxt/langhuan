package me.ywxt.langhuan.core.schema

import com.github.michaelbull.result.*
import com.github.michaelbull.result.coroutines.binding.binding
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

suspend fun RuleRequest.buildAction(env: InterfaceEnvironment): Result<Action, InterfaceError> = binding {
    val variables = env.getAllVariables()
    val url =
        runCatching { url(variables) }.mapError { InterfaceError.ParsingError(it.stackTraceToString()) }
            .bind()
    val charset = runCatching {
        env.getVariable("charset") as Charset
    }.mapError { InterfaceError.InvalidVariable("charset") }.bind()
    val builder = Action.Builder(url).charset(charset)
    val headers = env.getAllHeaders()
    builder.headers(headers).method(method)
    if (body != null) {
        builder.contentType(body.first).body(body.second)
    }

    builder.build().mapError { InterfaceError.NetworkError(it) }.bind()
}
