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

data class BookInfoArgs(val url: String)

class BookInterface(private val rule: BookInfoRule, private val schema: SchemaConfig, private val http: HttpClient) :
    ResourceInterface<BookInfo, BookInfoArgs> {
    private data class LocalContext(val url: String)

    override suspend fun process(
        args: BookInfoArgs,
    ): Flow<Either<InterfaceError, BookInfo>> {
        val localContext = LocalContext(args.url)
        return processHttpOne(schema, localContext, rule.request, http) { context, sources ->
            either {
                val title = rule.title.parseNonNullableFiled(context, sources).bind()
                val contentsUrl =
                    rule.contentsUrl.parseNonNullableFiled(context, sources).bind()
                val author = rule.author?.parseField(context, sources)?.bind()
                val description = rule.description?.parseField(context, sources)?.bind()
                val extraTags = rule.extraTags?.parseList(context, sources)?.bind()?.toList()
                BookInfo(title, contentsUrl, author, description, extraTags)
            }
        }
    }
}
