/*
 * Copyright (c) 2016, 2021 Oracle and/or its affiliates. All rights reserved. This
 * code is released under a tri EPL/GPL/LGPL license. You can use it,
 * redistribute it and/or modify it under the terms of the:
 *
 * Eclipse Public License version 2.0, or
 * GNU General Public License version 2, or
 * GNU Lesser General Public License version 2.1.
 */

package org.truffleruby.builtins;

import org.truffleruby.language.RubyContextSourceNode;
import org.truffleruby.language.NotProvided;

import com.oracle.truffle.api.dsl.GenerateNodeFactory;

@GenerateNodeFactory
public abstract class PrimitiveNode extends RubyContextSourceNode {

    // The same as "undefined" in Ruby code
    protected static final Object FAILURE = NotProvided.INSTANCE;

    public PrimitiveNode() {
    }

}
