package me.ywxt.langhuan.core.config

import arrow.core.Either
import com.charleskorn.kaml.Yaml
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.utils.catchException

@Serializable
data class ProjectSection(
    val name: String,
    val id: String,
    val author: String,
    val schemas: List<SchemaSection>,
) {
    companion object {
        fun fromString(config: String): Either<ConfigParsingError, ProjectSection> = catchException {
            Yaml.default.decodeFromString(serializer(), config)
        }.mapLeft { ConfigParsingError(it.stackTraceToString()) }
    }

    fun encodeToString(): Either<ConfigParsingError, String> = catchException {
        Yaml.default.encodeToString(this)
    }.mapLeft { ConfigParsingError(it.stackTraceToString()) }
}
