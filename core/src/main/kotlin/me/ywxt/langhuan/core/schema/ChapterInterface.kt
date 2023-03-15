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
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class ChapterInterface(private val rule: ParagraphRule) : ResourceInterface<ParagraphInfo> {
    override fun init(env: InterfaceEnvironment) {
        env.initPage()
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun process(
        env: InterfaceEnvironment,
        sources: ParsedSources,
    ): Either<InterfaceError, ResourceValue<ParagraphInfo>> = either {
        val content = rule.paragraph.parseList(env, sources).bind().map {
            ParagraphInfo(it)
        }
        env.setVariable(Variables.EMPTY_RESULT, content.isEmpty())
        val nextPageUrl = rule.nextPage.nextPageUrl(env, sources).bind()
        val value = ResourceValue.List(content, nextPageUrl)
        afterParse(env, value)
        value
    }

    private fun afterParse(env: InterfaceEnvironment, value: ResourceValue<ParagraphInfo>) {
        env.incPage()
        env.setNextPageUrl(Variables.CHAPTER_URL, value)
    }
}
