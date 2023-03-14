package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable

@Serializable
data class NextPageSection(
    val hasNextPage: ParsableSection,
    val nextPageUrl: ParsableSection? = null,
)
