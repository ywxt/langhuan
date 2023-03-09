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
    val searchRule: SearchRule,
    val bookInfoRule: BookInfoRule,
) {
    private val schemaContext by lazy {
        val context = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, id)
            setVariable(Variables.SCHEMA_NAME, name)
            setVariable(Variables.SCHEMA_SITE, site)
            setVariable(Variables.CHARSET, charset)
            defaultHeaders.forEach { (header, value) -> setHeader(header, value) }
        }
        context
    }

    fun initialEnvironment() = InterfaceEnvironment(schemaContext)
}
