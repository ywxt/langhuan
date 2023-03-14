package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable

@Serializable
data class BookInfoSection(
    val request: RequestSection,
    val title: ParsableSection,
    val contentsUrl: ParsableSection,
    val author: ParsableSection? = null,
    val description: ParsableSection? = null,
    val extraTags: ParsableSection? = null,
)
