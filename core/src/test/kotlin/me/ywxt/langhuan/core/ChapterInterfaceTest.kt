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
package me.ywxt.langhuan.core

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.ints.shouldBeGreaterThan
import io.kotest.matchers.string.shouldStartWith
import io.ktor.http.*
import korlibs.template.Template
import me.ywxt.langhuan.core.http.HttpClient
import me.ywxt.langhuan.core.schema.*

class ChapterInterfaceTest : FunSpec({
    test("Test ChapterInfoInterface parse") {
        val requestRule = RequestRule(
            url = Template("{{site}}{{local.url}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("").get(),
                Template("""false""")
            )
        )
        val paraRule = ParagraphRule(
            requestRule,
            paragraph = ParsableField(Parser("css@@#content@@para").get(), Template("{{result}}")),
            nextPage = nextPageRule,
        )
        val http = HttpClient()
        val schema = SchemaConfig(
            id = "test",
            name = "test",
            site = Url("https://www.biquge.co"),
            charset = charset("gbk"),
            defaultHeaders = mapOf("User-Agent" to "langhuan client"),
        )
        val chapterInterface = ChapterInterface(paraRule, schema, http)
        val args = ChapterArgs(
            url = "/3_3120/1249269.html",
        )
        val value = chapterInterface.processTotal(args).get()
        value.size shouldBeGreaterThan 3
        value[0].content.trim() shouldStartWith "新书"
    }
})
