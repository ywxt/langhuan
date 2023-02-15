package me.ywxt.langhuan.core.schema

import io.ktor.http.*

data class SearchResultItem(
    val title: String,
    val infoUrl: Url,
    val author: String?,
    val description: String?,
    val extraTags: Map<String, String>?
)
