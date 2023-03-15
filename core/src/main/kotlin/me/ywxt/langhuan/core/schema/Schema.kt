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

import io.ktor.http.*
import io.ktor.utils.io.charsets.*

data class Schema(
    val id: String,
    val name: String,
    val defaultHeaders: Map<String, String>,
    val site: Url,
    val charset: Charset = Charsets.UTF_8,
    val searchRule: SearchRule,
    val bookInfoRule: BookInfoRule,
) {
    private val schemaContext by lazy {
        val context = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, id)
            setVariable(Variables.SCHEMA_NAME, name)
            setVariable(Variables.SCHEMA_SITE, site)
            setVariable(Variables.CHARSET, charset)
            setHeader(Headers.REFERER_NAME, site.toString())
            defaultHeaders.forEach { (header, value) -> setHeader(header, value) }
        }
        context
    }

    fun initialEnvironment() = InterfaceEnvironment(schemaContext)
}
