package me.ywxt.langhuan.core.schema

import com.soywiz.korte.Template
import io.ktor.http.*

data class SearchRule(
    val url: Template,
    val method: HttpMethod = HttpMethod.Get,
    val headers: Map<String, String>?,
    val area: Parser,
    val title: ParsableField,
    val infoUrl: ParsableField,
    val author: ParsableField?,
    val description: ParsableField?,
    val extraTags: ParsableField?
)
