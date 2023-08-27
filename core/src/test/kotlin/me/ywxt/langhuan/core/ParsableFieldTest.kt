package me.ywxt.langhuan.core

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.ktor.http.*
import me.ywxt.langhuan.core.parse.Context
import me.ywxt.langhuan.core.parse.RequestRule
import me.ywxt.langhuan.core.parse.TemplateWithConfig
import me.ywxt.langhuan.core.parse.buildAction

class ParsableFieldTest : FunSpec({
    test("Test buildAction") {
        data class TestContext(val url: String)

        val context = Context(
            id = "test",
            name = "test",
            headers = mapOf(),
            site = Url("https://ywxt.me"),
            charset = charset("gbk"),
            local = TestContext("https://ywxt.me"),
        )
        val urlTemplate = TemplateWithConfig("{{local.url}}").get()
        val requestRule = RequestRule(url = urlTemplate)
        val request = requestRule.buildAction(context).get()
        request.request.url.toString() shouldBe "https://ywxt.me"
    }
})
