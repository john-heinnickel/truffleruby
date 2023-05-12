/*
 * Copyright (c) 2015, 2023 Oracle and/or its affiliates. All rights reserved. This
 * code is released under a tri EPL/GPL/LGPL license. You can use it,
 * redistribute it and/or modify it under the terms of the:
 *
 * Eclipse Public License version 2.0, or
 * GNU General Public License version 2, or
 * GNU Lesser General Public License version 2.1.
 */
package org.truffleruby.language.constants;

import com.oracle.truffle.api.nodes.Node;
import org.truffleruby.core.module.ModuleOperations;
import org.truffleruby.core.module.RubyModule;
import org.truffleruby.language.RubyBaseNode;
import org.truffleruby.language.WarnNode;

import com.oracle.truffle.api.CompilerDirectives;
import com.oracle.truffle.api.CompilerDirectives.TruffleBoundary;
import com.oracle.truffle.api.source.SourceSection;

public abstract class LookupConstantBaseNode extends RubyBaseNode {

    @Child private WarnNode warnNode;

    protected void warnDeprecatedConstant(RubyModule module, String name) {
        if (warnNode == null) {
            CompilerDirectives.transferToInterpreterAndInvalidate();
            warnNode = insert(new WarnNode());
        }

        if (warnNode.shouldWarnForDeprecation()) {
            warnNode.warningMessage(getSection(this), formatMessage(this, module, name));
        }
    }

    protected static void warnDeprecatedConstant(Node node, WarnNode warnNode, RubyModule module, String name) {
        if (warnNode.shouldWarnForDeprecation()) {
            warnNode.warningMessage(getSection(node), formatMessage(node, module, name));
        }
    }

    @TruffleBoundary
    private static SourceSection getSection(Node node) {
        return getContext(node).getCallStack().getTopMostUserSourceSection(node.getEncapsulatingSourceSection());
    }

    @TruffleBoundary
    private static String formatMessage(Node node, RubyModule module, String name) {
        return "constant " + ModuleOperations.constantName(getContext(node), module, name) + " is deprecated";
    }

    protected int getCacheLimit() {
        return getLanguage().options.CONSTANT_CACHE;
    }

}
