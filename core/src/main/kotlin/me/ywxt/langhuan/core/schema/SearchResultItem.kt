package me.ywxt.langhuan.core.schema

data class SearchResultItem(
    val title: String,
    val infoUrl: String,
    val author: String?,
    val description: String?,
    val extraTags: List<String>?
)
