package me.ywxt.langhuan.core.http

import com.github.michaelbull.result.Result
import com.github.michaelbull.result.map
import com.github.michaelbull.result.mapError
import com.github.michaelbull.result.runCatching
import io.ktor.http.*
import io.ktor.utils.io.charsets.*
import me.ywxt.langhuan.core.NetworkError
import java.net.URLEncoder

data class Resource(val request: Request, val charset: Charset)

data class Request(val url: Url, val method: HttpMethod, val content: Content?)

fun Resource(
    url: String,
    method: HttpMethod,
    charset: Charset = Charset.forName("UTF-8"),
    contentType: ContentType? = null,
    body: String? = null
): Result<Resource, NetworkError.InvalidUrl> {
    val safeUrl = URLEncoder.encode(url, charset)
    val encodedUrl = runCatching {
        Url(safeUrl)
    }.mapError { NetworkError.InvalidUrl(url) }
    val content = if (contentType != null && body != null) {
        Content(contentType.withCharset(charset).toString(), charset.encode(body).array())
    } else {
        null
    }
    return encodedUrl.map { Resource(Request(it, method, content), charset) }
}
