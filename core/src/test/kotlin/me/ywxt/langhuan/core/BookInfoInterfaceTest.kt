package me.ywxt.langhuan.core

import com.soywiz.korte.Template
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import io.ktor.http.*
import me.ywxt.langhuan.core.schema.*

class BookInfoInterfaceTest : FunSpec({
    test("Test BookInfoInterface build action") {
        val ruleRequest = RuleRequest(
            url = Template("https://ywxt.me/{{url}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val bookRule = BookInfoRule(
            ruleRequest,
            title = ParsableField(Parser("css@@span.s2 > a", false).get(), Template("{{result}}")),
            contentsUrl = ParsableField(Parser("css@@span.s2 > a@@href", false).get(), Template("{{result}}")),
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable("schema_id", "me.ywxt")
            setVariable("schema_name", "test schema")
            setVariable("schema_site", Url("https://ywxt.me"))
            setVariable("charset", charset("GBK"))
            setHeader("Refer", "https://ywxt.me")
        }
        val bookInfoInterface = BookInfoInterface(bookRule)
        bookInfoInterface.init(env)
        env.setVariable("url", "book/36889/")
        val action = bookInfoInterface.buildAction(env).get()
        action.apply {
            request.content shouldBe null
            request.url.toString() shouldBe "https://ywxt.me/book/36889/"
            request.method shouldBe HttpMethod.Get
            request.headers shouldNotBe null
            request.headers!!.size shouldBe 2

            charset shouldBe charset("GBK")
        }
    }
})
