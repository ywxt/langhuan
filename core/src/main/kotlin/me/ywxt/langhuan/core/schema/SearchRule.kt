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
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.config.SearchSection

data class SearchRule(
    val request: RuleRequest,
    val area: ParsableField,
    val title: ParsableField,
    val infoUrl: ParsableField,
    val nextPage: NextPageRule,
    val author: ParsableField? = null,
    val description: ParsableField? = null,
    val extraTags: ParsableField? = null,
) {
    companion object {
        suspend fun fromConfig(config: SearchSection): Either<ConfigParsingError, SearchRule> = either {
            SearchRule(
                request = RuleRequest.fromConfig(config.request).bind(),
                area = ParsableField.fromConfig(config.item.area).bind(),
                title = ParsableField.fromConfig(config.item.title).bind(),
                infoUrl = ParsableField.fromConfig(config.item.infoUrl).bind(),
                nextPage = NextPageRule.fromConfig(config.nextPage).bind(),
                author = config.item.author?.let { ParsableField.fromConfig(it).bind() },
                description = config.item.description?.let { ParsableField.fromConfig(it).bind() },
                extraTags = config.item.extraTags?.let { ParsableField.fromConfig(it).bind() },
            )
        }
    }
}
