package me.ywxt.langhuan.core.schema

data class BookInfo(
    val title: String,
    val contentsUrl: String,
    val author: String?,
    val description: String?,
    val extraTags: List<String>?,
)
