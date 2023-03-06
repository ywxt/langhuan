package me.ywxt.langhuan.core.http

import arrow.core.Either
import io.ktor.client.*
import io.ktor.client.engine.cio.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import me.ywxt.langhuan.core.NetworkError

class HttpClient : AutoCloseable {
    private val client = HttpClient(CIO) {
        expectSuccess = true
    }

    override fun close() {
        client.close()
    }

    suspend fun request(action: Action): Either<NetworkError.KtorError, String> = Either.catch {
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
