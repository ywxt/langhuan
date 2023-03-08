package me.ywxt.langhuan.core

import com.soywiz.korte.Template
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import io.kotest.matchers.types.shouldBeInstanceOf
import io.ktor.http.*
import me.ywxt.langhuan.core.schema.*

class SearchInterfaceTest : FunSpec({
    test("Test SearchInterface build action") {
        val ruleRequest = RuleRequest(
            url = Template("https://ywxt.me/search?q={{query | url_encode}}&page={{page + 1}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val searchRule = SearchRule(
            ruleRequest,
            area = Parser("css@@#main > div.novelslistss > li", true).get(),
            title = ParsableField(Parser("css@@span.s2 > a", false).get(), Template("{{result}}")),
            infoUrl = ParsableField(Parser("css@@span.s2 > a@@href", false).get(), Template("{{result}}")),
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
        action.apply {
            request.content shouldBe null
            request.url.toString() shouldBe "https://ywxt.me/search?q=%D6%D8%C9%FA&page=1"
            request.method shouldBe HttpMethod.Get
            request.headers shouldNotBe null
            request.headers!!.size shouldBe 2

            charset shouldBe charset("GBK")
        }
    }
    test("Test SearchInterface parse") {
        val ruleRequest = RuleRequest(
            url = Template("https://ywxt.me/search?q={{query | url_encode}}&page={{page + 1}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val searchRule = SearchRule(
            ruleRequest,
            area = Parser("css@@#main > div.novelslistss > li", true).get(),
            title = ParsableField(Parser("css@@span.s2 > a", false).get(), Template("{{result}}")),
            infoUrl = ParsableField(Parser("css@@span.s2 > a@@href", false).get(), Template("{{result}}")),
            author = ParsableField(Parser("css@@span.s4", false).get(), Template("{{result}}"))
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
        val sources = ParsedSources(
            """
            <div id="main"><div class="novelslistss"><h2>重生的搜索结果</h2>       
            <li><span class="s1">修真小说</span><span class="s2">
            <a href="https://www.xbiquge.so/book/36889/">重生都市仙帝</a></span><span class="s3">            
            <a href="https://www.xbiquge.so/book/36889/40042666.html" target="_blank"> 第4055章 公孙康</a></span>            
            <span class="s4">万鲤鱼</span><span class="s5">23-03-07</span><span class="s7"></span></li>           
            <li><span class="s1">都市小说</span><span class="s2">           
            <a href="https://www.xbiquge.so/book/55674/">重生农门小福妻</a></span><span class="s3">          
            <a href="https://www.xbiquge.so/book/55674/40042620.html" target="_blank"> 第3097章 宁霁祸，要生了</a></span>          
            <span class="s4">风十里</span><span class="s5">23-03-07</span><span class="s7"></span></li>
            </div></div>
        """
        )
        val result = searchInterface.parse(sources, env).get()
        result.shouldBeInstanceOf<NextIndication<ResourceValue<SearchResultItem>>>()
        val value = result.value;
        value.shouldBeInstanceOf<ResourceValue.List<SearchResultItem>>()
        val list = value.list;
        list.size shouldBe 2
        list[0].author shouldBe "万鲤鱼"
        list[0].title shouldBe "重生都市仙帝"
        list[0].infoUrl shouldBe "https://www.xbiquge.so/book/36889/"

    }

})
