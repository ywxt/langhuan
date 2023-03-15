/**
 * Copyright 2023 ywxt
 *
 * This file is part of Langhuan.
 *
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Lesser Public License for more details.
 *
 * You should have received a copy of the GNU General Lesser Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/lgpl-3.0.html>.
 *
 */
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
