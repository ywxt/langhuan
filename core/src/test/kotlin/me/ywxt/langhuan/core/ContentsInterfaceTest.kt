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
import io.kotest.matchers.shouldBe
import io.ktor.http.*
import korlibs.template.Template
import me.ywxt.langhuan.core.http.HttpClient
import me.ywxt.langhuan.core.parse.*

class ContentsInterfaceTest : FunSpec({
    test("Test ChapterInfoInterface parse") {
        val requestRule = RequestRule(
            url = Template("{{local.url}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("").get(),
                Template("""false""")
            )
        )
        val contentsRule = ContentsRule(
            requestRule,
            area = ParsableField(
                Parser("css@@#list > dl > dt:nth-of-type(2) ~ dd").get(),
                Template("{{result}}", templateConfig)
            ),
            title = ParsableField(Parser("css@@a@@text").get(), Template("{{result}}", templateConfig)),
            chapterUrl = ParsableField(
                Parser("css@@a@@href").get(),
                Template("{{result}}"),
            ),
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
        val contentsInterface = ContentsInterface(contentsRule, schema, http)
        val args = ContentsArgs(url = "https://www.biquge.co/3_3120/")
        val value = contentsInterface.processTotal(args).get()
        value.size shouldBe 882
        value[0].title shouldBe "新书感言"
        value[0].chapterUrl shouldBe "/3_3120/1249269.html"
    }
})
