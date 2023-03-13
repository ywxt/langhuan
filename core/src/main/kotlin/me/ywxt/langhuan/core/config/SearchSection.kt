package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable

@Serializable
data class SearchSection(
    val request: RequestSection,
    val item: SearchItemSection,
)

@Serializable
data class SearchItemSection(
    val area: ParsableFieldSection,
    val title: ParsableFieldSection,
    val infoUrl: ParsableFieldSection,
    val nextPage: ParsableFieldSection,
    val author: ParsableFieldSection? = null,
    val description: ParsableFieldSection? = null,
    val extraTags: ParsableFieldSection? = null,
)
