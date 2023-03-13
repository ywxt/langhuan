package me.ywxt.langhuan.core

import arrow.core.Either
import com.soywiz.korte.Template
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.collections.shouldEndWith
import io.kotest.matchers.collections.shouldHaveAtLeastSize
import io.kotest.matchers.collections.shouldHaveSize
import io.kotest.matchers.collections.shouldStartWith
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import io.kotest.matchers.string.shouldStartWith
import io.kotest.matchers.types.shouldBeInstanceOf
import io.ktor.http.*
import kotlinx.coroutines.flow.toList
import me.ywxt.langhuan.core.http.HttpClient
import me.ywxt.langhuan.core.schema.*

class ResourceClientTest : FunSpec({
    test("List test: multiply pages") {
        val ruleRequest = RuleRequest(
            url = Template("{{${Variables.SCHEMA_SITE}}}{{${Variables.CHAPTER_URL}}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("css@@#wrapper > article > div.bottem2 > a:nth-child(4)@@text").get(),
                Template("""{{result == "下一页"}}"""),
            ),
            nextPageUrl = ParsableField(
                Parser("css@@#wrapper > article > div.bottem2 > a:nth-child(4)@@href").get(),
                Template("{{result}}")
            )
        )
        val paragraphRule = ParagraphRule(
            ruleRequest,
            content = ParsableField(Parser("css@@#booktxt > p@@text").get(), Template("{{result}}", templateConfig)),
            nextPage = nextPageRule,
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://biqudi.cc"))
            setVariable(Variables.CHARSET, Charsets.UTF_8)
            setHeader("Refer", "https://biqudi.cc")
        }
        val chapterInterface = ChapterInterface(paragraphRule)
        env.setVariable(Variables.CHAPTER_URL, "/bi/5214/3516273.html")
        val client = ResourceClient(chapterInterface, HttpClient())
        val paragraphs = client.fetch(env).toList()
        paragraphs shouldHaveAtLeastSize 1
        val first = paragraphs.first()
        first.shouldBeInstanceOf<Either.Right<ParagraphInfo>>()
        first.value.content shouldStartWith "《遮天之九天书》"
        val last = paragraphs.last()
        last.shouldBeInstanceOf<Either.Right<ParagraphInfo>>()
        last.value.content shouldStartWith "姜望道放缓速度"
    }
    test("List test: single page") {
        val ruleRequest = RuleRequest(
            url = Template("{{${Variables.SCHEMA_SITE}}}{{${Variables.CONTENTS_URL}}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("").get(),
                Template("false"),
            ),
        )
        val contentsRule = ContentsRule(
            ruleRequest,
            area = ParsableField(Parser("css@@#newlist > dd").get(), Template("{{result}}", templateConfig)),
            title = ParsableField(Parser("css@@a@@text").get(), Template("{{result}}", templateConfig)),
            chapterUrl = ParsableField(
                Parser("css@@a@@href").get(),
                Template("{{result}}"),
            ),
            nextPage = nextPageRule,
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://biqudi.cc"))
            setVariable(Variables.CHARSET, Charsets.UTF_8)
            setHeader("Refer", "https://biqudi.cc")
        }
        val contentsInterface = ContentsInterface(contentsRule)
        env.setVariable(Variables.CONTENTS_URL, "/bi/5214/")
        val client = ResourceClient(contentsInterface, HttpClient())
        val contents = client.fetch(env).toList()
        contents shouldHaveSize 186
        contents shouldStartWith Either.Right(ContentsItem("第一章 姜望道和九天书", "/bi/5214/3516273.html"))
        contents shouldEndWith Either.Right(ContentsItem("第一百八十五章 混沌种青莲", "/bi/5214/5972490.html"))
    }
    test("Value test") {
        val ruleRequest = RuleRequest(
            url = Template("{{${Variables.SCHEMA_SITE}}}{{${Variables.BOOK_URL}}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val bookRule = BookInfoRule(
            ruleRequest,
            title = ParsableField(Parser("css@@#info > h1@@text").get(), Template("{{result}}")),
            contentsUrl = ParsableField(
                Parser("").get(),
                Template("{{${Variables.BOOK_URL}}}")
            ),
            author = ParsableField(Parser("css@@#info > p:nth-child(2) > a@@text").get(), Template("{{result}}")),
            description = ParsableField(Parser("css@@#intro@@text").get(), Template("{{result}}")),
            extraTags = ParsableField(Parser("css@@#info > p.visible-xs@@text").get(), Template("{{result}}")),
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://biqudi.cc"))
            setVariable(Variables.CHARSET, Charsets.UTF_8)
            setHeader("Refer", "https://biqudi.cc")
        }
        val bookInterface = BookInterface(bookRule)
        env.setVariable(Variables.BOOK_URL, "/bi/5214/")
        val client = ResourceClient(bookInterface, HttpClient())
        val bookInfo = client.fetch(env).toList()
        bookInfo.size shouldBe 1
        val info = bookInfo.first()
        info.shouldBeInstanceOf<Either.Right<BookInfo>>()
        info.value.apply {
            title shouldBe "遮天之九天书"
            contentsUrl shouldBe "/bi/5214/"
            author shouldBe "青天有鱼"
            description shouldStartWith "遮天之九天书小说简介"
            extraTags shouldNotBe null
            extraTags!!.shouldHaveSize(3)
        }
    }
})
