package me.ywxt.langhuan.core

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import me.ywxt.langhuan.core.utils.paragraphs
import org.jsoup.Jsoup

class JsoupTest : FunSpec({
    test("Test Jsoup textContent") {
        val doc = Jsoup.parse(
            """&nbsp;&nbsp;&nbsp;&nbsp;He llo   <br />
<br />
&nbsp;&nbsp;&nbsp;&nbsp;He llo  <br />
<br />
        """
        )
        doc.paragraphs().forEach {
            it shouldBe "    He llo "
        }
    }
})
