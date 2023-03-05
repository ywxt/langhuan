package me.ywxt.langhuan.core

sealed class LanghuanError(val message: String) {
    override fun toString(): String = message
}

sealed class NetworkError(message: String) : LanghuanError(message) {
    class InvalidUrl(val url: String) : NetworkError("Invalid url: $url")

    class KtorError(message: String) : NetworkError(message)
}

sealed class SchemaError(message: String) : LanghuanError(message)

sealed class InterfaceError(message: String) : SchemaError(message) {
    class InvalidVariable(message: String) : InterfaceError(message)
    class ParsingError(message: String) : InterfaceError(message)

    class NetworkError(causedBy: me.ywxt.langhuan.core.NetworkError) : InterfaceError(causedBy.message)
}

class ConfigParsingError(message: String) : SchemaError(message)

class InvalidContentType(contentType: String) : SchemaError("Invalid content type: $contentType")
