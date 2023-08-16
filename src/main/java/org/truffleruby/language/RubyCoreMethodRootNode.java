/*
 * Copyright (c) 2021 Oracle and/or its affiliates. All rights reserved. This
 * code is released under a tri EPL/GPL/LGPL license. You can use it,
 * redistribute it and/or modify it under the terms of the:
 *
 * Eclipse Public License version 2.0, or
 * GNU General Public License version 2, or
 * GNU Lesser General Public License version 2.1.
 */
package org.truffleruby.language;

import com.oracle.truffle.api.TruffleSafepoint;
import com.oracle.truffle.api.nodes.RootNode;
import org.truffleruby.RubyLanguage;
import org.truffleruby.language.control.ReturnID;
import org.truffleruby.language.methods.Arity;
import org.truffleruby.language.methods.SharedMethodInfo;
import org.truffleruby.language.methods.Split;
import org.truffleruby.language.methods.TranslateExceptionNode;

import com.oracle.truffle.api.CompilerDirectives;
import com.oracle.truffle.api.frame.FrameDescriptor;
import com.oracle.truffle.api.frame.VirtualFrame;
import com.oracle.truffle.api.source.SourceSection;

public class RubyCoreMethodRootNode extends RubyCheckArityRootNode {

    @Child private TranslateExceptionNode translateExceptionNode;

    public RubyCoreMethodRootNode(
            RubyLanguage language,
            SourceSection sourceSection,
            FrameDescriptor frameDescriptor,
            SharedMethodInfo sharedMethodInfo,
            RubyNode body,
            Split split,
            ReturnID returnID,
            Arity arityForCheck) {
        super(language, sourceSection, frameDescriptor, sharedMethodInfo, body, split, returnID, arityForCheck);
    }

    @Override
    public Object execute(VirtualFrame frame) {
        TruffleSafepoint.poll(this);

        checkArity(frame);

        try {
            return body.execute(frame);
        } catch (Throwable t) {
            if (translateExceptionNode == null) {
                CompilerDirectives.transferToInterpreterAndInvalidate();
                translateExceptionNode = insert(TranslateExceptionNode.create());
            }
            throw translateExceptionNode.executeTranslation(t);
        }
    }

    @Override
    protected RootNode cloneUninitialized() {
        return new RubyCoreMethodRootNode(
                getLanguage(),
                getSourceSection(),
                getFrameDescriptor(),
                getSharedMethodInfo(),
                body.cloneUninitialized(),
                getSplit(),
                returnID,
                arityForCheck);
    }

}
