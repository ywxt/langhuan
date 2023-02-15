package me.ywxt.langhuan.core.http

import com.github.michaelbull.result.Result
import com.github.michaelbull.result.mapError
import com.github.michaelbull.result.runCatching
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

    suspend fun request(action: Action): Result<String, NetworkError.KtorError> = runCatching {
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
    }.mapError { NetworkError.KtorError(it.stackTraceToString()) }
}
