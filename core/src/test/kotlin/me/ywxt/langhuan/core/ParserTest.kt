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
        val titleParser = Parser("css@@div > span:nth-of-type(1)", false).get()
        val authorParser = Parser("css@@div>span:nth-of-type(2)", false).get()
        val chapterListParser = Parser("css@@div>a@@href", true).get()
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
