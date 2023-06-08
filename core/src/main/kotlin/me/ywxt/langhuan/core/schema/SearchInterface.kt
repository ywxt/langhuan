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
import kotlinx.coroutines.flow.Flow
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.HttpClient

data class SearchArgs(
    val keyword: String,
)

class SearchInterface(
    private val rule: SearchRule,
    private val schema: SchemaConfig,
    private val http: HttpClient,
) : ResourceInterface<SearchResultItem, SearchArgs> {

    private data class LocalContext(
        var keyword: String,
        var page: Int,
        var url: String? = null,
        var items: List<SearchResultItem>? = null,
    )

    override suspend fun process(
        args: SearchArgs,
    ): Flow<Either<InterfaceError, SearchResultItem>> {
        val localContext = LocalContext(args.keyword, 0)
        return processHttpList(schema, localContext, rule.request, http, rule.area, rule.nextPage, { context, items ->
            run {
                context.local.items = items
            }
        }, { context, url ->
            run {
                context.local.url = url
                context.local.page++
            }
        }) { context, sources ->
            either {
                val title = rule.title.parseNonNullableFiled(context, sources).bind()
                val infoUrl = rule.infoUrl.parseNonNullableFiled(context, sources).bind()
                val author = rule.author?.parseField(context, sources)?.bind()
                val description = rule.description?.parseField(context, sources)?.bind()
                val extraTags = rule.extraTags?.parseList(context, sources)?.bind()?.toList()
                SearchResultItem(title, infoUrl, author, description, extraTags)
            }
        }
    }
}
