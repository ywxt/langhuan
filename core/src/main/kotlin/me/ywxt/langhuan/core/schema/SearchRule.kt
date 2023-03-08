package me.ywxt.langhuan.core.schema

import io.ktor.http.*

data class SearchRule(
    val request: RuleRequest,
    val area: Parser,
    val title: ParsableField,
    val infoUrl: ParsableField,
    val hasNextPage: ParsableField? = null,
    val author: ParsableField? = null,
    val description: ParsableField? = null,
    val extraTags: ParsableField? = null,
)
