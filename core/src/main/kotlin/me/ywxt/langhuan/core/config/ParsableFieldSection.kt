package me.ywxt.langhuan.core.config

import kotlinx.serialization.Serializable
@Serializable
data class ParsableFieldSection(
    val expression: String = "",
    val eval: String = "{{result}}",
)
