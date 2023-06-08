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

import arrow.core.Either
import arrow.core.continuations.either
import io.ktor.http.*
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.config.SchemaSection
import me.ywxt.langhuan.core.utils.catchException
import kotlin.text.charset

data class Schema(
    val config: SchemaConfig,
    val searchRule: SearchRule,
    val bookInfoRule: BookInfoRule,
    val contentsRule: ContentsRule,
    val chapterRule: ParagraphRule,
) {
    companion object {
        suspend fun fromConfig(config: SchemaSection): Either<ConfigParsingError, Schema> = either {
            Schema(
                config = SchemaConfig(
                    id = config.id,
                    name = config.name,
                    charset = catchException { charset(config.charset) }.mapLeft {
                        ConfigParsingError(
                            it.stackTraceToString()
                        )
                    }
                        .bind(),
                    site = catchException { Url(config.site) }.mapLeft { ConfigParsingError(it.stackTraceToString()) }
                        .bind(),
                    defaultHeaders = config.headers,
                ),
                searchRule = SearchRule.fromConfig(config.search).bind(),
                bookInfoRule = BookInfoRule.fromConfig(config.bookInfo).bind(),
                contentsRule = ContentsRule.fromConfig(config.contents).bind(),
                chapterRule = ParagraphRule.fromConfig(config.chapter).bind(),
            )
        }
    }
}
