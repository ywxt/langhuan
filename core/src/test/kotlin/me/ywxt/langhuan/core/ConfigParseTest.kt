package me.ywxt.langhuan.core

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import me.ywxt.langhuan.core.config.ProjectSection

class ConfigParseTest : FunSpec({
    test("Parse project config test") {
        val project = ProjectSection.fromString("""
        name: Test
        id: Test ID
        author: ywxt
        schemas:
          - name: Test 1
            id: Test ID 1
            site: https://ywxt.me
            headers:
              User-Agent: Langhuan Client
            search:
              request: 
                url: https://ywxt.me/search?query={{query|url_encode}}&page={{page+1}}
              item:
                area: 
                  expression: css@div.item
                title:
                  expression: css@span.title@@text
                infoUrl:
                  expression: css@span.title@@href
              nextPage:
                hasNextPage: 
                  expression: css@@div.span@@text
                  eval: "{{result == '下一页'}}"
                nextPageUrl: 
                  expression: css@@div.span@@href
            bookInfo:
              request:
                url: https://ywxt.me/book/{{book_url}}
              title: 
                expression: css@span.title@@text
              contentsUrl: 
                eval: "{{book_url}}"
            contents:
              request:
                url: https://ywxt.me/book/{{contents_url}}
              item:
                area:
                  expression: css@div.item
                title:
                  expression: css@span.title@@text
                chapterUrl:
                  expression: css@span.title@@href
              nextPage:
                hasNextPage:
                  expression: css@@div.span@@text
                  eval: "{{result == '下一页'}}"
                nextPageUrl:
                  expression: css@@div.span@@href
            chapter:
              request:
                url: https://ywxt.me/book/{{chapter_url}}
              paragraph:
                expression: css@@div#content@@para-text
              nextPage:
                hasNextPage:
                  expression: css@@div.span@@text
                  eval: "{{result == '下一页'}}"
                nextPageUrl:
                  expression: css@@div.span@@href
        """.trimIndent()).get()
        project.id shouldBe "Test ID"
        project.name shouldBe "Test"
        project.author shouldBe "ywxt"
    }
})