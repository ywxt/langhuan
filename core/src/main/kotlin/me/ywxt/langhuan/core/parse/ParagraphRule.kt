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
import me.ywxt.langhuan.core.config.ChapterSection

data class ParagraphRule(
    val request: RequestRule,
    val paragraph: ParsableField,
    val nextPage: NextPageRule,
) {
    companion object {
        suspend fun fromConfig(chapter: ChapterSection): Either<ConfigParsingError, ParagraphRule> = either {
            ParagraphRule(
                request = RequestRule.fromConfig(chapter.request).bind(),
                paragraph = ParsableField.fromConfig(chapter.paragraph).bind(),
                nextPage = NextPageRule.fromConfig(chapter.nextPage).bind(),
            )
        }
    }
}
