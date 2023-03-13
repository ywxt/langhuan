package me.ywxt.langhuan.core.http

import arrow.core.Either
import io.ktor.client.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import me.ywxt.langhuan.core.NetworkError
import me.ywxt.langhuan.core.utils.catchException

private const val TIMEOUT_MILLIS = 5000L

class HttpClient : AutoCloseable {
    private val client = HttpClient(CIO) {
        expectSuccess = true
        install(HttpTimeout) {
            requestTimeoutMillis = TIMEOUT_MILLIS
        }
    }

    override fun close() {
        client.close()
    }

    suspend fun request(action: Action): Either<NetworkError.KtorError, String> = catchException {
        val response = client.request(action.request.url) {
            method = action.request.method
            action.request.headers?.forEach { entry ->
                headers.append(entry.key, entry.value)
            }
            val content = action.request.content
            if (content != null) {
                headers.append(HttpHeaders.ContentType, content.type)
                setBody(content.body)
            }
        }
        response.bodyAsText(action.charset)
    }.mapLeft { NetworkError.KtorError(it.stackTraceToString()) }
}
