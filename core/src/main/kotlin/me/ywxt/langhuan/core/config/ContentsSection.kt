package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable

@Serializable
data class ContentsSection(
    val request: RequestSection,
    val item: ContentsItemSection,
    val nextPage: NextPageSection,
)

@Serializable
data class ContentsItemSection(
    val area: ParsableSection,
    val title: ParsableSection,
    val chapterUrl: ParsableSection,
)
