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
