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
import io.kotest.matchers.shouldNotBe
import io.kotest.matchers.types.shouldBeInstanceOf
import io.ktor.http.*
import korlibs.template.Template
import me.ywxt.langhuan.core.schema.*

class ChapterInterfaceTest : FunSpec({
    test("Test ChapterInfoInterface build action") {
        val ruleRequest = RuleRequest(
            url = Template("https://ywxt.me/{{chapter_url}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("css@@div.bottom2 > a:nth-child(4)@@text").get(),
                Template("""{{result == "下一页"}}""")
            ),
            nextPageUrl = ParsableField(
                Parser("css@@div.bottom2 > a:nth-child(4)@@href").get(),
                Template("{{result}}")
            ),
        )
        val paraRule = ParagraphRule(
            ruleRequest,
            paragraph = ParsableField(Parser("css@@#content@@para").get(), Template("{{result}}")),
            nextPage = nextPageRule,
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://ywxt.me"))
            setVariable(Variables.CHARSET, charset("GBK"))
            setHeader("Refer", "https://ywxt.me")
        }
        val chapterInterface = ChapterInterface(paraRule)
        env.setVariable(Variables.CHAPTER_URL, "book/36889/")
        chapterInterface.init(env)
        val action = chapterInterface.buildAction(env).get()
        action.apply {
            request.content shouldBe null
            request.url.toString() shouldBe "https://ywxt.me/book/36889/"
            request.method shouldBe HttpMethod.Get
            request.headers shouldNotBe null
            request.headers!!.size shouldBe 2

            charset shouldBe charset("GBK")
        }
    }
    test("Test ChapterInfoInterface parse") {
        val ruleRequest = RuleRequest(
            url = Template("https://ywxt.me/{{chapter_url}}", templateConfig),
            headers = mapOf("User-Agent" to "langhuan client")
        )
        val nextPageRule = NextPageRule(
            hasNextPage = ParsableField(
                Parser("css@@div.bottom2 > a:nth-child(4)@@text").get(),
                Template("""{{result == "下一页"}}""")
            ),
            nextPageUrl = ParsableField(
                Parser("css@@div.bottom2 > a:nth-child(4)@@href").get(),
                Template("{{result}}")
            ),
        )
        val paraRule = ParagraphRule(
            ruleRequest,
            paragraph = ParsableField(Parser("css@@#content@@para-text").get(), Template("{{result}}")),
            nextPage = nextPageRule,
        )
        val env = InterfaceEnvironment(null).apply {
            setVariable(Variables.SCHEMA_ID, "me.ywxt")
            setVariable(Variables.SCHEMA_NAME, "test schema")
            setVariable(Variables.SCHEMA_SITE, Url("https://ywxt.me"))
            setVariable(Variables.CHARSET, charset("GBK"))
            setHeader("Refer", "https://ywxt.me")
        }
        val chapterInterface = ChapterInterface(paraRule)
        env.setVariable(Variables.CHAPTER_URL, "book/36889/")
        chapterInterface.init(env)
        val sources1 = ParsedSources(
            """
            <div class="bookname"><h1>Name</h1></div>       
            <div id="content">&nbsp;&nbsp;&nbsp;&nbsp;Hello<br />
<br />
&nbsp;&nbsp;&nbsp;&nbsp;Hello<br />         
<br /></div>
<div class="bottom2">
                    <a rel="prev" href="/bi/1894/1319808.html">上一章</a> 
        <a rel="index" href="/bi/1894/" disable="disabled">章节目录</a>
        <a href="javascript:addbookcase()" class="addbookcase_r">加入书签</a>
                    <a rel="next" href="/bi/1894/1319817_2.html">下一页</a>
            </div>       
        """
        )
        val value1 = chapterInterface.process(env, sources1).get()
        value1.shouldBeInstanceOf<ResourceValue.List<ParagraphInfo>>()
        value1.nextPageUrl shouldBe "/bi/1894/1319817_2.html"
        val paraList = value1.list
        paraList.size shouldBe 2
        paraList[0].content shouldBe "    Hello"
        val source2 = ParsedSources(
            """
            <div class="bookname"><h1>Name</h1></div>       
            <div id="content">&nbsp;&nbsp;&nbsp;&nbsp;Hello<br />
<br />
&nbsp;&nbsp;&nbsp;&nbsp;Hello<br /> </div>
                 <div class="bottom2">
                    <a rel="prev" href="/bi/1894/1319808.html">上一章</a> 
        <a rel="index" href="/bi/1894/" disable="disabled">章节目录</a>
        <a href="javascript:addbookcase()" class="addbookcase_r">加入书签</a>
                    <a rel="next" href="/bi/1894/1319817_2.html">下一章</a>
            </div> 
        """
        )
        val value2 = chapterInterface.process(env, source2).get()
        value2.shouldBeInstanceOf<ResourceValue.List<ParagraphInfo>>()
        value2.nextPageUrl shouldBe null
        value2.list.size shouldBe 2
    }
})
