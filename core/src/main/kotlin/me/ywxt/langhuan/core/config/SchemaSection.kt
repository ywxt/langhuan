package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable
import me.ywxt.langhuan.core.schema.SCHEMA_DEFAULT_ENCODING_NAME
import me.ywxt.langhuan.core.schema.schemaDefaultHeaders

@Serializable
data class SchemaSection(
    val name: String,
    val id: String,
    val site: String,
    val headers: Map<String, String> = schemaDefaultHeaders,
    val charset: String = SCHEMA_DEFAULT_ENCODING_NAME,
    val search: SearchSection,
)
