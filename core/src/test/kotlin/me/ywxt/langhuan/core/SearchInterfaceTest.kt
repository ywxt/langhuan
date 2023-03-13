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
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("css@@#pagelink > strong@@text").get(),
                Template("{{ result|int > page + 1}}", templateConfig)
            ),
            nextPageUrl = ParsableField(
                Parser("").get(),
                Template("/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page={{page + 2}}")
            ),
        )
        val searchRule = SearchRule(
            ruleRequest,
            area = ParsableField(
                Parser("css@@#main > div.novelslistss > li").get(),
                Template("{{result}}", templateConfig)
            ),
            title = ParsableField(Parser("css@@span.s2 > a@@text").get(), Template("{{result}}")),
            infoUrl = ParsableField(Parser("css@@span.s2 > a@@href").get(), Template("{{result}}")),
            nextPage = nextPageRule,
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://ywxt.me"))
            setVariable(Variables.CHARSET, charset("GBK"))
            setHeader("Refer", "https://ywxt.me")
        }
        val searchInterface = SearchInterface(searchRule)
        searchInterface.init(env)
        env.setVariable(Variables.SEARCH_QUERY, "重生")
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
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("css@@#pagelink > strong@@text").get(),
                Template("{{ result|int > page + 1}}", templateConfig)
            ),
            nextPageUrl = ParsableField(
                Parser("").get(),
                Template("/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page={{page + 2}}")
            ),
        )
        val searchRule = SearchRule(
            ruleRequest,
            area = ParsableField(
                Parser("css@@#main > div.novelslistss > li").get(),
                Template("{{result}}", templateConfig)
            ),
            title = ParsableField(Parser("css@@span.s2 > a@@text").get(), Template("{{result}}")),
            infoUrl = ParsableField(Parser("css@@span.s2 > a@@href").get(), Template("{{result}}")),
            author = ParsableField(Parser("css@@span.s4@@text").get(), Template("{{result}}")),
            nextPage = nextPageRule
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://ywxt.me"))
            setVariable(Variables.CHARSET, charset("GBK"))
            setHeader("Refer", "https://ywxt.me")
        }
        val searchInterface = SearchInterface(searchRule)
        searchInterface.init(env)
        val sources = ParsedSources(
            """
            <div id="main"><div class="novelslistss"><h2>重生的搜索结果</h2>       
            <li><span class="s1">修真小说</span><span class="s2">
            <a href="https://ywxt.me/book/36889/">重生都市仙帝</a></span><span class="s3">            
            <a href="https://ywxt.me/book/36889/40042666.html" target="_blank"> 第4055章 公孙康</a></span>            
            <span class="s4">万鲤鱼</span><span class="s5">23-03-07</span><span class="s7"></span></li>           
            <li><span class="s1">都市小说</span><span class="s2">           
            <a href="https://ywxt.me/book/55674/">重生农门小福妻</a></span><span class="s3">          
            <a href="https://ywxt.me/book/55674/40042620.html" target="_blank"> 第3097章 宁霁祸，要生了</a></span>          
            <span class="s4">风十里</span><span class="s5">23-03-07</span><span class="s7"></span></li>
            </div></div>
            <div class="pagelink" id="pagelink"><em id="pagestats">6/6</em>           
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=1" class="first">1</a>           
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=1" class="pgroup">&lt;&lt;</a>           
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=5" class="prev">&lt;</a>          
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=1">1</a>           
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=2">2</a>           
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=3">3</a>           
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=4">4</a>           
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=5">5</a>          
            <strong>6</strong>         
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=6" class="ngroup">&gt;&gt;</a>            
            <a href="/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=6" class="last">6</a></div>
        """
        )
        val value = searchInterface.process(env, sources).get()
        value.shouldBeInstanceOf<ResourceValue.List<SearchResultItem>>()
        value.nextPageUrl shouldBe "/modules/article/search.php?searchkey=%D6%D8%C9%FA&amp;page=2"
        val list = value.list
        list.size shouldBe 2
        list[0].author shouldBe "万鲤鱼"
        list[0].title shouldBe "重生都市仙帝"
        list[0].infoUrl shouldBe "https://ywxt.me/book/36889/"
    }
})
