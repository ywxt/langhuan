package me.ywxt.langhuan.core

sealed class LanghuanError

sealed class NetworkError : LanghuanError() {
    class InvalidUrl(val url: String) : NetworkError() {
        override fun toString(): String {
            return "Invalid url: $url"
        }
    }

    class KtorError(val message: String) : NetworkError() {
        override fun toString(): String = message
    }
}

sealed class InterfaceError : LanghuanError() {
    class InvalidVariable(val message: String) : InterfaceError()
    class ParsingError(val message: String) : InterfaceError()
}

class ConfigParsingError(val message: String) : LanghuanError()
