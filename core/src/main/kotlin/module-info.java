/**
 * Copyright 2023 ywxt
 * <p>
 * This file is part of Langhuan.
 * <p>
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 * <p>
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * <p>
 * You should have received a copy of the GNU General Public
 * License along with this program.  If not, see
 * <<a href="http://www.gnu.org/licenses/">http://www.gnu.org/licenses/</a>>.
 */
open module langhuan.core {
    requires org.jsoup;
    requires kotlin.stdlib;
    requires io.ktor.client.core;
    requires io.ktor.http;
    requires io.ktor.client.cio;
    requires io.ktor.io;
    requires arrow.core.jvm;
    requires kotlinx.coroutines.core;
    requires korte.jvm;
    requires kotlinx.serialization.core;
    requires kaml.jvm;


    exports me.ywxt.langhuan.core.http;
    exports me.ywxt.langhuan.core.schema;
    exports me.ywxt.langhuan.core.utils;
    exports me.ywxt.langhuan.core.config;
    exports me.ywxt.langhuan.core;

}