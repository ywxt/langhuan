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
import kotlinx.coroutines.flow.Flow
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.HttpClient

data class ChapterArgs(val url: String)

class ChapterInterface(
    private val rule: ParagraphRule,
    private val schema: SchemaConfig,
    private val http: HttpClient,
) : ResourceInterface<ParagraphInfo, ChapterArgs> {
    private data class LocalContext(var url: String?, var page: Int, var items: List<ParagraphInfo>? = null)

    override suspend fun process(
        args: ChapterArgs,
    ): Flow<Either<InterfaceError, ParagraphInfo>> {
        val localContext = LocalContext(args.url, 0)
        return processHttpList(
            schema,
            localContext,
            rule.request,
            http,
            rule.paragraph,
            rule.nextPage,
            { context, items ->
                run {
                    context.local.items = items
                }
            },
            { context, url ->
                run {
                    context.local.url = url
                    context.local.page++
                }
            }
        ) { _, sources ->
            Either.Right(ParagraphInfo(sources.document))
        }
    }
}
