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

@Suppress("NOTHING_TO_INLINE")
inline fun getStackTrace(): List<StackTraceElement> {
    val stackTrace = Throwable("Ignored message").stackTrace
    return stackTrace.toList()
}

sealed class LanghuanError(val message: String, val stackTrace: List<StackTraceElement>) {
    override fun toString(): String = "$message\n at \n ${stackTrace.joinToString("\n")}"
}

sealed class NetworkError(message: String, stackTrace: List<StackTraceElement>) : LanghuanError(message, stackTrace) {
    class InvalidUrl(val url: String, stackTrace: List<StackTraceElement>) :
        NetworkError("Invalid url: $url", stackTrace)

    class KtorError(message: String, stackTrace: List<StackTraceElement>) : NetworkError(message, stackTrace)
}

sealed class SchemaError(message: String, stackTrace: List<StackTraceElement>) : LanghuanError(message, stackTrace)

sealed class InterfaceError(message: String, stackTrace: List<StackTraceElement>) : SchemaError(message, stackTrace) {
    class ParsingError(message: String, stackTrace: List<StackTraceElement>) : InterfaceError(message, stackTrace)

    class NetworkError(causedBy: me.ywxt.langhuan.core.NetworkError, stackTrace: List<StackTraceElement>) :
        InterfaceError(causedBy.message, stackTrace)

    class NotSingleError(stackTrace: List<StackTraceElement>) : InterfaceError("Empty result.", stackTrace)
}

class ConfigParsingError(message: String, stackTrace: List<StackTraceElement>) : SchemaError(message, stackTrace)

class InvalidContentType(contentType: String, stackTrace: List<StackTraceElement>) :
    SchemaError("Invalid content type: $contentType", stackTrace)
