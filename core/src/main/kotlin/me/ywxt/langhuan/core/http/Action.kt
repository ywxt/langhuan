package me.ywxt.langhuan.core.http

import arrow.core.Either
import io.ktor.http.*
import io.ktor.utils.io.charsets.*
import me.ywxt.langhuan.core.NetworkError
import me.ywxt.langhuan.core.utils.catchException

data class Action(val request: Request, val charset: Charset) {
    class Builder private constructor(
        private var url: String,
        private var method: HttpMethod = HttpMethod.Get,
        private var charset: Charset = Charsets.UTF_8,
        private var headers: Map<String, String>? = null,
        private var contentType: io.ktor.http.ContentType? = null,
        private var body: String? = null,
    ) {
        constructor(url: String) : this(url, HttpMethod.Get)

        fun url(url: String): Builder {
            this.url = url
            return this
        }

        fun method(method: HttpMethod): Builder {
            this.method = method
            return this
        }

        fun charset(charset: Charset): Builder {
            this.charset = charset
            return this
        }

        fun headers(headers: Map<String, String>): Builder {
            this.headers = headers
            return this
        }

        fun contentType(contentType: ContentType): Builder {
            this.contentType = when (contentType) {
                ContentType.JSON -> io.ktor.http.ContentType.Application.Json
                ContentType.FORM -> io.ktor.http.ContentType.Application.FormUrlEncoded
            }
            return this
        }

        fun body(body: String): Builder {
            this.body = body
            return this
        }

        fun build(): Either<NetworkError.InvalidUrl, Action> {
            val encodedUrl = catchException {
                Url(url)
            }.mapLeft { NetworkError.InvalidUrl(url) }
            val contentType = this.contentType
            val body = this.body
            val content = if (contentType != null && body != null) {
                Content(contentType.withCharset(charset).toString(), charset.encode(body).array())
            } else {
                null
            }
            return encodedUrl.map { Action(Request(it, method, headers, content), charset) }
        }
    }
}

data class Request(
    val url: Url,
    val method: HttpMethod,
    val headers: Map<String, String>?,
    val content: Content?,
)
