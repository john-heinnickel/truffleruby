/*
 * Copyright (c) 2021, 2021 Oracle and/or its affiliates. All rights reserved. This
 * code is released under a tri EPL/GPL/LGPL license. You can use it,
 * redistribute it and/or modify it under the terms of the:
 *
 * Eclipse Public License version 2.0, or
 * GNU General Public License version 2, or
 * GNU Lesser General Public License version 2.1.
 */
package org.truffleruby.core.cast;

import org.truffleruby.core.encoding.RubyEncoding;
import org.truffleruby.core.regexp.RubyRegexp;
import org.truffleruby.core.string.ImmutableRubyString;
import org.truffleruby.core.string.RubyString;
import org.truffleruby.core.symbol.RubySymbol;
import org.truffleruby.language.RubyContextNode;

import com.oracle.truffle.api.dsl.Fallback;
import com.oracle.truffle.api.dsl.Specialization;

/** Take a Ruby object that has an encoding and extracts the Java-level encoding object. */
public abstract class ToRubyEncodingNode extends RubyContextNode {

    public static ToRubyEncodingNode create() {
        return ToRubyEncodingNodeGen.create();
    }

    public abstract RubyEncoding executeToEncoding(Object value);

    @Specialization
    protected RubyEncoding stringToEncoding(RubyString value) {
        return value.encoding;
    }

    @Specialization
    protected RubyEncoding immutableStringToEncoding(ImmutableRubyString value) {
        return value.getEncoding();
    }

    @Specialization
    protected RubyEncoding symbolToEncoding(RubySymbol value) {
        return getContext().getEncodingManager().getRubyEncoding(value.getRope().getEncoding());
    }

    @Specialization
    protected RubyEncoding regexpToEncoding(RubyRegexp value) {
        return getContext().getEncodingManager().getRubyEncoding(value.regex.getEncoding());
    }

    @Specialization
    protected RubyEncoding rubyEncodingToEncoding(RubyEncoding value) {
        return value;
    }

    @Fallback
    protected RubyEncoding failure(Object value) {
        return null;
    }
}