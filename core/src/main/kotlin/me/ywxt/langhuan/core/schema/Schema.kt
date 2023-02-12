package me.ywxt.langhuan.core.schema

import io.ktor.http.*

data class Schema(
    val id: String,
    val name: String,
    val defaultHeaders: Map<String, String>,
    val site: Url,
    val searchInterface: SearchInterface
)
