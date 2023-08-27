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
import io.kotest.matchers.shouldBe
import io.ktor.http.*
import korlibs.template.Template
import me.ywxt.langhuan.core.config.ContentType
import me.ywxt.langhuan.core.config.RequestMethod
import me.ywxt.langhuan.core.http.HttpClient
import me.ywxt.langhuan.core.parse.*

class SearchInterfaceTest : FunSpec({
    test("Test SearchInterface parse") {
        val requestRule = RequestRule(
            url = Template("https://www.biquge.co/modules/article/search.php", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client"),
            method = RequestMethod.POST,
            body = ContentType.FORM to TemplateWithConfig(
                "searchkey={{local.keyword | url_encode}}&searchtype=articlename&page={{local.page+1}}"
            ).get()
        )
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("css@@#pagelink > a.last@@text").get(),
                TemplateWithConfig("{{ result|int > page + 1}}").get()
            ),
        )
        val searchRule = SearchRule(
            requestRule,
            area = ParsableField(
                Parser("css@@#content > table > tr:nth-of-type(n+2)").get(),
                TemplateWithConfig("{{result}}").get()
            ),
            title = ParsableField(
                Parser("css@@#nr > td:nth-child(1) > a@@text").get(),
                TemplateWithConfig("{{result}}").get()
            ),
            infoUrl = ParsableField(
                Parser("css@@#nr > td:nth-child(1) > a@@href").get(),
                TemplateWithConfig("{{result}}").get()
            ),
            author = ParsableField(
                Parser("css@@#nr > td:nth-child(3)@@text").get(),
                TemplateWithConfig("{{result}}").get()
            ),
            nextPage = nextPageRule
        )
        val http = HttpClient()
        val schema = SchemaConfig(
            id = "test",
            name = "test",
            site = Url("https://www.biquge.co"),
            charset = charset("gbk"),
            defaultHeaders = mapOf("User-Agent" to "langhuan client"),
        )
        val searchInterface = SearchInterface(searchRule, schema, http)
        val args = SearchArgs("序列")
        val value = searchInterface.processTotal(args).get()
        value.size shouldBeGreaterThan 0
        value[0].author shouldBe "会说话的肘子"
        value[0].title shouldBe "第一序列"
        value[0].infoUrl shouldBe "https://www.biquge.co/0_410/"
    }
})
