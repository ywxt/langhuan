package me.ywxt.langhuan.core

import com.soywiz.korte.Template
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import io.kotest.matchers.types.shouldBeInstanceOf
import io.ktor.http.*
import me.ywxt.langhuan.core.schema.*

class BookInterfaceTest : FunSpec({
    test("Test BookInfoInterface build action") {
        val ruleRequest = RuleRequest(
            url = Template("https://ywxt.me/{{book_url}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val bookRule = BookInfoRule(
            ruleRequest,
            title = ParsableField(Parser("css@@span.s2 > a", false).get(), Template("{{result}}")),
            contentsUrl = ParsableField(Parser("css@@span.s2 > a@@href", false).get(), Template("{{result}}")),
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://ywxt.me"))
            setVariable(Variables.CHARSET, charset("GBK"))
            setHeader("Refer", "https://ywxt.me")
        }
        val bookInterface = BookInterface(bookRule)
        env.setVariable(Variables.BOOK_URL, "book/36889/")
        bookInterface.init(env)
        val action = bookInterface.buildAction(env).get()
        action.apply {
            request.content shouldBe null
            request.url.toString() shouldBe "https://ywxt.me/book/36889/"
            request.method shouldBe HttpMethod.Get
            request.headers shouldNotBe null
            request.headers!!.size shouldBe 2

            charset shouldBe charset("GBK")
        }
    }
    test("Test BookInfoInterface parse") {
        val ruleRequest = RuleRequest(
            url = Template("https://ywxt.me/{{book_url}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val bookRule = BookInfoRule(
            ruleRequest,
            title = ParsableField(Parser("css@@span.s2 > a", false).get(), Template("{{result}}")),
            contentsUrl = ParsableField(Parser("", false).get(), Template("https://ywxt.me/{{book_url}}")),
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://ywxt.me"))
            setVariable(Variables.CHARSET, charset("GBK"))
            setHeader("Refer", "https://ywxt.me")
        }
        val bookInterface = BookInterface(bookRule)
        env.setVariable(Variables.BOOK_URL, "book/36889/")
        bookInterface.init(env)
        val sources = ParsedSources(
            """
            <div id="main"><div class="novelslistss"><h2>重生的搜索结果</h2>       
            <li><span class="s1">修真小说</span><span class="s2">
            <a href="https://ywxt.me/book/36889/">重生都市仙帝</a></span><span class="s3">            
            <a href="https://ywxt.me/book/36889/40042666.html" target="_blank"> 第4055章 公孙康</a></span>            
            <span class="s4">万鲤鱼</span><span class="s5">23-03-07</span><span class="s7"></span></li>
            </div></div>        
        """
        )
        val value = bookInterface.process(env, sources).get()
        value.shouldBeInstanceOf<ResourceValue.Item<BookInfo>>()
        val bookInfo = value.value
        bookInfo.title shouldBe "重生都市仙帝"
        bookInfo.contentsUrl shouldBe "https://ywxt.me/book/36889/"
    }
})
