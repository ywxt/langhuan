package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable

@Serializable
data class ChapterSection(
    val request: RequestSection,
    val paragraph: ParsableSection,
    val nextPage: NextPageSection,
)
