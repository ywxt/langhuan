/**
 * Copyright 2023 ywxt
 *
 * This file is part of Langhuan.
 *
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */
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
