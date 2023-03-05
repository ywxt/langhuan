package me.ywxt.langhuan.core.http

import com.github.michaelbull.result.Err
import com.github.michaelbull.result.Ok
import com.github.michaelbull.result.Result
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
        fun parse(type: String): Result<ContentType, InvalidContentType> =
            if (type.compareTo("json", true) == 0) {
                Ok(JSON)
            } else if (type.compareTo("form", true) == 0) {
                Ok(FORM)
            } else {
                Err(InvalidContentType(type))
            }
    }
}
