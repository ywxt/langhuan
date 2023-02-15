package me.ywxt.langhuan.core.schema

import io.ktor.http.*
import io.ktor.utils.io.charsets.*
import io.ktor.utils.io.charsets.Charsets

data class Schema(
    val id: String,
    val name: String,
    val defaultHeaders: Map<String, String>,
    val site: Url,
    val charset: Charset = Charsets.UTF_8,
    val searchRule: SearchRule
) {
    private val schemaContext by lazy {
        val context = InterfaceEnvironment(null).apply {
            setVariable("schema_id", id)
            setVariable("schema_name", name)
            setVariable("schema_site", site)
            setVariable("charset", charset)
            defaultHeaders.forEach { (header, value) -> setHeader(header, value) }
        }
        context
    }

    fun initialContext() = InterfaceEnvironment(schemaContext)
}
