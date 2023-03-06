package me.ywxt.langhuan.core.http

import arrow.core.Either
import me.ywxt.langhuan.core.InvalidContentType

data class Content(val type: String, val body: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as Content

        if (type != other.type) return false
        if (!body.contentEquals(other.body)) return false

        return true
    }

    override fun hashCode(): Int {
        var result = type.hashCode()
        result = 31 * result + body.contentHashCode()
        return result
    }
}

enum class ContentType {
    JSON,
    FORM;

    companion object {
        fun parse(type: String): Either<InvalidContentType, ContentType> =
            if (type.compareTo("json", true) == 0) {
                Either.Right(JSON)
            } else if (type.compareTo("form", true) == 0) {
                Either.Right(FORM)
            } else {
                Either.Left(InvalidContentType(type))
            }
    }
}
