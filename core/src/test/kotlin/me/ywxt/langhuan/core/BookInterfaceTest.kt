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
import me.ywxt.langhuan.core.http.HttpClient
import me.ywxt.langhuan.core.schema.*

class BookInterfaceTest : FunSpec({
    test("Test BookInfoInterface parse") {
        val requestRule = RequestRule(
            url = TemplateWithConfig("{{local.url}}").get(),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val bookRule = BookInfoRule(
            requestRule,
            title = ParsableField(Parser("css@@#info > h1@@text").get(), TemplateWithConfig("{{result}}").get()),
            author = ParsableField(
                Parser("css@@#info > p:nth-child(2)@@text").get(),
                TemplateWithConfig("{{result | substring(4)}}").get()
            ),
            contentsUrl = ParsableField(Parser("").get(), TemplateWithConfig("{{local.url}}").get()),
        )
        val http = HttpClient()
        val schema = SchemaConfig(
            id = "test",
            name = "test",
            site = Url("https://www.biquge.co"),
            charset = charset("gbk"),
            defaultHeaders = mapOf("User-Agent" to "langhuan client"),
        )
        val bookInterface = BookInterface(bookRule, schema, http)
        val args = BookInfoArgs(
            url = "https://www.biquge.co/3_3120/",
        )
        val bookInfo = bookInterface.processSingle(args).get()
        bookInfo.title shouldBe "剑来"
        bookInfo.author shouldBe "烽火戏诸侯"
        bookInfo.contentsUrl shouldBe "https://www.biquge.co/3_3120/"
    }
})
