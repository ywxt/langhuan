/**
 * Copyright 2023 ywxt
 *
 * This file is part of Langhuan.
 *
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Lesser Public License for more details.
 *
 * You should have received a copy of the GNU General Lesser Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/lgpl-3.0.html>.
 *
 */
package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class BookInterface(private val rule: BookInfoRule) : ResourceInterface<BookInfo> {
    override fun init(env: InterfaceEnvironment) {
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun process(
        env: InterfaceEnvironment,
        sources: ParsedSources,
    ): Either<InterfaceError, ResourceValue<BookInfo>> = either {
        val title = rule.title.parseNonNullableFiled(env, sources).bind()
        val contentsUrl =
            rule.contentsUrl.parseNonNullableFiled(env, sources).bind()
        val author = rule.author?.parseField(env, sources)?.bind()
        val description = rule.description?.parseField(env, sources)?.bind()
        val extraTags = rule.extraTags?.parseList(env, sources)?.bind()?.toList()
        ResourceValue.Item(BookInfo(title, contentsUrl, author, description, extraTags))
    }
}
