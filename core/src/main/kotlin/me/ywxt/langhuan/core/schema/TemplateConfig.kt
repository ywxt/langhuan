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
package me.ywxt.langhuan.core.schema

import com.soywiz.korte.AutoEscapeMode
import com.soywiz.korte.Filter
import com.soywiz.korte.TemplateConfig
import io.ktor.utils.io.charsets.*
import java.net.URLDecoder
import java.net.URLEncoder

val urlEncodingFilter = Filter("url_encode") {

    val charset =
        args.firstOrNull()?.run { charset(toDynamicString()) } ?: this.context.scope.get(Variables.CHARSET)
            ?.run { this as Charset }
            ?: Charsets.UTF_8

    URLEncoder.encode(subject.toDynamicString(), charset)
}

val urlDecodingFilter = Filter("url_decode") {
    val charset =
        args.firstOrNull()?.run { charset(toDynamicString()) } ?: this.context.scope.get(Variables.CHARSET)
            ?.run { this as Charset }
            ?: Charsets.UTF_8
    URLDecoder.decode(subject.toDynamicString(), charset)
}

val intFilter = Filter("int") {
    subject.toDynamicInt()
}

val templateConfig =
    TemplateConfig(
        extraFilters = listOf(urlDecodingFilter, urlEncodingFilter, intFilter),
        autoEscapeMode = AutoEscapeMode.RAW
    )
