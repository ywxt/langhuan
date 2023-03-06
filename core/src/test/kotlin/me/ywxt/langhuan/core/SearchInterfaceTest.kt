package me.ywxt.langhuan.core

import com.soywiz.korte.Template
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.should
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import io.ktor.http.*
import me.ywxt.langhuan.core.schema.*

class SearchInterfaceTest : FunSpec({

    test("Test SearchInterface build action") {
        val request = RuleRequest(
            url = Template("https://ywxt.me/search?q={{query | url_encode}}&page={{page + 1}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val searchRule = SearchRule(
            request,
            area = Parser("css@@#main > div.novelslistss > li", true).get(),
            title = ParsableField(Parser("css@@span.s2 > a", false).get(), Template("{}")),
            infoUrl = ParsableField(Parser("css@@span.s2 > a@@href", false).get(), Template("{}")),
        )
        val schema = Schema(
            id = "me.ywxt",
            name = "test schema",
            defaultHeaders = mapOf("Refer" to "https://ywxt.me"),
            site = Url("https://ywxt.me"),
            charset = charset("GBK"),
            searchRule,
        )
        val env = schema.initialEnvironment()
        val searchInterface = SearchInterface(searchRule)
        searchInterface.init(env)
        env.setVariable("query", "重生")
        val action = searchInterface.buildAction(env).get()
        action should {
            it.request.content shouldBe null
            it.request.url.toString() shouldBe "https://ywxt.me/search?q=%D6%D8%C9%FA&page=1"
            it.request.method shouldBe HttpMethod.Get
            it.request.headers shouldNotBe null
            it.request.headers!!.size shouldBe 2

            it.charset shouldBe charset("GBK")
        }
    }
})
