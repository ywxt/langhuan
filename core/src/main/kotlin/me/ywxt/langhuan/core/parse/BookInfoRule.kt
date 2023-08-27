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
package me.ywxt.langhuan.core.parse

import arrow.core.Either
import arrow.core.raise.either
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.config.BookInfoSection

data class BookInfoRule(
    val request: RequestRule,
    val title: ParsableField,
    val contentsUrl: ParsableField,
    val author: ParsableField? = null,
    val description: ParsableField? = null,
    val extraTags: ParsableField? = null,
) {
    companion object {
        suspend fun fromConfig(bookInfo: BookInfoSection): Either<ConfigParsingError, BookInfoRule> = either {
            BookInfoRule(
                request = RequestRule.fromConfig(bookInfo.request).bind(),
                title = ParsableField.fromConfig(bookInfo.title).bind(),
                contentsUrl = ParsableField.fromConfig(bookInfo.contentsUrl).bind(),
                author = bookInfo.author?.let { ParsableField.fromConfig(it).bind() },
                description = bookInfo.description?.let { ParsableField.fromConfig(it).bind() },
            )
        }
    }
}
