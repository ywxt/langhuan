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
