package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable

@Serializable
data class ProjectSection(
    val name: String,
    val id: String,
    val author: String,
    val list: List<SchemaSection>,
)
