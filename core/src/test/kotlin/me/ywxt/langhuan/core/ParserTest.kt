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
import io.kotest.matchers.should
import io.kotest.matchers.shouldBe
import me.ywxt.langhuan.core.schema.ParsedSources
import me.ywxt.langhuan.core.schema.Parser

class ParserTest : FunSpec({
    test("Test selectorParser parse") {
        val sources = ParsedSources(
            """<body>
            |<div>
            | <a href="https://ywxt.me">link</a>
            | <a href="https://ywxt.me">link</a>
            | <a href="https://ywxt.me">link</a>
            |</div>
            | <div>
            | <span>title</span>
            | <span>author</span>
            | </div>
            |</body>
            """.trimMargin()
        )
        val titleParser = Parser("css@@div > span:nth-of-type(1)@@text").get()
        val authorParser = Parser("css@@div>span:nth-of-type(2)@@text").get()
        val chapterListParser = Parser("css@@div>a@@href").get()
        titleParser.parse(sources).toList().should {
            it.size shouldBe 1
            it[0] shouldBe "title"
        }
        authorParser.parse(sources).toList().should {
            it.size shouldBe 1
            it[0] shouldBe "author"
        }
        chapterListParser.parse(sources).toList().should {
            it.size shouldBe 3
            it.forEach { link -> link shouldBe "https://ywxt.me" }
        }
    }
})
