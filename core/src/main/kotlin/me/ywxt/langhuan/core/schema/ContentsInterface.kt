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
import arrow.core.raise.either
import kotlinx.coroutines.flow.Flow
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.HttpClient

data class ContentsArgs(val url: String)
class ContentsInterface(
    private val rule: ContentsRule,
    private val schema: SchemaConfig,
    private val http: HttpClient,
) : ResourceInterface<ContentsItem, ContentsArgs> {
    private data class LocalContext(
        var url: String?,
        var page: Int,
        var items: List<ContentsItem>? = null,
    )

    override suspend fun process(args: ContentsArgs): Flow<Either<InterfaceError, ContentsItem>> {
        val localContext = LocalContext(args.url, 0)
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
                val chapterUrl = rule.chapterUrl.parseNonNullableFiled(context, sources).bind()
                ContentsItem(title, chapterUrl)
            }
        }
    }
}
