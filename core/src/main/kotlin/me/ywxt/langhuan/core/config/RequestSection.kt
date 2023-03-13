package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable

@Serializable
data class RequestSection(
    val url: String,
    val method: RequestMethod = RequestMethod.GET,
    val headers: Map<String, String>? = null,
    val content: ContentSection? = null,
)

@Serializable
data class ContentSection(
    val contentType: ContentType,
    val body: String,
)

@Serializable
enum class RequestMethod {
    GET,
    POST,
    PUT,
    DELETE,
}

@Serializable
enum class ContentType {
    JSON,
    FORM,
}
