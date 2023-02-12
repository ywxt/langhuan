package me.ywxt.langhuan.core.http

import com.github.michaelbull.result.Result
import com.github.michaelbull.result.mapError
import com.github.michaelbull.result.runCatching
import io.ktor.client.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.api.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import me.ywxt.langhuan.core.NetworkError
import kotlin.collections.Map
import kotlin.collections.component1
import kotlin.collections.component2
import kotlin.collections.forEach

class HeaderPluginConfig(var headers: Map<String, Any>? = null)

val HeaderPlugin = createClientPlugin("HeaderPlugin", ::HeaderPluginConfig) {
    onRequest { request, _ ->
        this@createClientPlugin.pluginConfig.headers?.forEach { (name, value) ->
            if (!request.headers.contains(name)) {
                request.headers.append(
                    name, value.toString()
                )
            }
        }
    }
}

class HttpClient(private val defaultHeaders: Map<String, Any>? = null) : AutoCloseable {
    private val client = HttpClient(CIO) {
        expectSuccess = true
        install(HeaderPlugin) {
            headers = defaultHeaders
        }
    }

    override fun close() {
        client.close()
    }

    suspend fun request(resource: Resource): Result<String, NetworkError.KtorError> = runCatching {
        val response = client.request(resource.request.url) {
            method = resource.request.method
            val content = resource.request.content
            if (content != null) {
                headers.append(HttpHeaders.ContentType, content.type)
                setBody(content.body)
            }
        }
        response.bodyAsText(resource.charset)

    }.mapError { NetworkError.KtorError(it.stackTraceToString()) }


}


