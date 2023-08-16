/*
 * Copyright (c) 2013, 2023 Oracle and/or its affiliates. All rights reserved. This
 * code is released under a tri EPL/GPL/LGPL license. You can use it,
 * redistribute it and/or modify it under the terms of the:
 *
 * Eclipse Public License version 2.0, or
 * GNU General Public License version 2, or
 * GNU Lesser General Public License version 2.1.
 */
package org.truffleruby.core.cast;

import com.oracle.truffle.api.CompilerDirectives.TruffleBoundary;
import com.oracle.truffle.api.dsl.Specialization;
import org.truffleruby.core.exception.RubyException;
import org.truffleruby.core.numeric.BigIntegerOps;
import org.truffleruby.core.numeric.RubyBignum;
import org.truffleruby.language.RubyBaseNode;
import org.truffleruby.language.control.RaiseException;

import java.math.BigInteger;

/** Casts a value into a BigInteger. */
public abstract class BigIntegerCastNode extends RubyBaseNode {

    public abstract BigInteger execute(Object value);

    @Specialization
    protected BigInteger doInt(int value) {
        return BigIntegerOps.valueOf(value);
    }

    @Specialization
    protected BigInteger doLong(long value) {
        return BigIntegerOps.valueOf(value);
    }

    @Specialization
    protected BigInteger doBignum(RubyBignum value) {
        return value.value;
    }

    @Specialization(guards = "!isRubyInteger(value)")
    protected BigInteger doBasicObject(Object value) {
        throw new RaiseException(getContext(), notAnInteger(value));
    }

    @TruffleBoundary
    private RubyException notAnInteger(Object object) {
        return coreExceptions().typeErrorIsNotA(
                object.toString(),
                "Integer",
                this);
    }

}
