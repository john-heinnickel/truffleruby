/*
 * Copyright (c) 2013, 2021 Oracle and/or its affiliates. All rights reserved. This
 * code is released under a tri EPL/GPL/LGPL license. You can use it,
 * redistribute it and/or modify it under the terms of the:
 *
 * Eclipse Public License version 2.0, or
 * GNU General Public License version 2, or
 * GNU Lesser General Public License version 2.1.
 */
package org.truffleruby.language;

import com.oracle.truffle.api.CompilerDirectives;
import com.oracle.truffle.api.RootCallTarget;
import com.oracle.truffle.api.dsl.NodeFactory;
import com.oracle.truffle.api.instrumentation.InstrumentableNode.WrapperNode;
import com.oracle.truffle.api.nodes.Node;
import com.oracle.truffle.api.nodes.NodeUtil;
import com.oracle.truffle.api.nodes.RootNode;
import org.truffleruby.RubyLanguage;
import org.truffleruby.builtins.ReRaiseInlinedExceptionNode;
import org.truffleruby.language.control.ReturnID;
import org.truffleruby.language.methods.SharedMethodInfo;

import com.oracle.truffle.api.frame.FrameDescriptor;
import com.oracle.truffle.api.frame.VirtualFrame;
import com.oracle.truffle.api.source.SourceSection;
import org.truffleruby.language.methods.Split;
import org.truffleruby.options.Options;
import org.truffleruby.parser.ParentFrameDescriptor;

import java.util.ArrayList;
import java.util.List;

public class RubyRootNode extends RubyBaseRootNode {

    public static RubyRootNode of(RootCallTarget callTarget) {
        return (RubyRootNode) callTarget.getRootNode();
    }

    private final SharedMethodInfo sharedMethodInfo;
    private Split split;
    public final ReturnID returnID;

    @Child protected RubyNode body;
    @Child protected RubyNode bodyCopy;

    public RubyRootNode(
            RubyLanguage language,
            SourceSection sourceSection,
            FrameDescriptor frameDescriptor,
            SharedMethodInfo sharedMethodInfo,
            RubyNode body,
            Split split,
            ReturnID returnID) {
        super(language, frameDescriptor, sourceSection);
        assert sourceSection != null;
        assert body != null;

        this.sharedMethodInfo = sharedMethodInfo;
        this.body = body;
        this.split = split;
        this.returnID = returnID;

        // Ensure the body node is instrument-able, which requires a non-null SourceSection
        if (!body.hasSource()) {
            body.unsafeSetSourceSection(getSourceSection());
        }

        body.unsafeSetIsCall();
        body.unsafeSetIsRoot();

        Options options = getContext().getOptions();
        if (options.CHECK_CLONE_UNINITIALIZED_CORRECTNESS) {
            this.bodyCopy = copyBody();
        }
    }

    @Override
    public Object execute(VirtualFrame frame) {
        return body.execute(frame);
    }

    @Override
    public FrameDescriptor getParentFrameDescriptor() {
        var info = getFrameDescriptor().getInfo();
        if (info instanceof ParentFrameDescriptor) {
            return ((ParentFrameDescriptor) info).getDescriptor();
        } else {
            return null;
        }
    }

    @Override
    public boolean isCloningAllowed() {
        return split != Split.NEVER;
    }

    public boolean shouldAlwaysClone() {
        return split == Split.ALWAYS;
    }

    public Split getSplit() {
        return split;
    }

    public void setSplit(Split split) {
        this.split = split;
    }

    @Override
    public String getName() {
        return sharedMethodInfo.getParseName();
    }

    @Override
    public String toString() {
        return sharedMethodInfo.getParseName();
    }

    public SharedMethodInfo getSharedMethodInfo() {
        return sharedMethodInfo;
    }

    public NodeFactory<? extends RubyBaseNode> getAlwaysInlinedNodeFactory() {
        return ((ReRaiseInlinedExceptionNode) body).nodeFactory;
    }

    public RubyNode copyBody() {
        return NodeUtil.cloneNode(body);
    }

    @Override
    protected boolean isCloneUninitializedSupported() {
        return true;
    }

    @Override
    protected RootNode cloneUninitialized() {
        if (getClass() != RubyRootNode.class) {
            throw CompilerDirectives.shouldNotReachHere(
                    "TODO need to implement cloneUninitialized() on a subclass of RubyRootNode " + getClass());
        }

        return new RubyRootNode(getLanguage(), getSourceSection(), getFrameDescriptor(), sharedMethodInfo,
                body.cloneUninitialized(), split, returnID);
    }

    protected void ensureCloneUninitializedCorrectness(RubyRootNode clone) {
        if (!isClonedCorrectly(bodyCopy, clone.bodyCopy)) {
            System.err.println();
            System.err.println("Original copy of body (bodyCopy) AST:");
            NodeUtil.printCompactTree(System.err, bodyCopy);

            System.err.println("Cloned body (clone.bodyCopy) AST:");
            NodeUtil.printCompactTree(System.err, clone.bodyCopy);

            throw new Error("#cloneUninitialized for RubyRootNode " + getName() + " created not identical AST");
        }
    }

    private boolean isClonedCorrectly(Node original, Node clone) {
        // A clone should be a new instance
        if (original == clone) {
            return false;
        }

        // Ignore instrumental wrappers (e.g. RubyNodeWrapper)
        if (WrapperNode.class.isInstance(original)) {
            return isClonedCorrectly(((WrapperNode) original).getDelegateNode(), clone);
        }

        // Should be instances of the same class
        if (original.getClass() != clone.getClass()) {
            return false;
        }

        Node[] originalChildren = childrenToArray(original);
        Node[] cloneChildren = childrenToArray(clone);

        // Should have the same number of children
        if (cloneChildren.length != originalChildren.length) {
            return false;
        }

        // Should have the same children
        for (int i = 0; i < cloneChildren.length; i++) {
            if (!isClonedCorrectly(originalChildren[i], cloneChildren[i])) {
                return false;
            }
        }

        return true;
    }

    private Node[] childrenToArray(Node node) {
        final List<Node> childrenList = new ArrayList<>();
        for (Node child : node.getChildren()) {
            childrenList.add(child);
        }

        final Object[] arrayOfObjects = childrenList.toArray();
        final Node[] array = new Node[arrayOfObjects.length];

        for (int i = 0; i < array.length; i++) {
            array[i] = (Node) arrayOfObjects[i];
        }

        return array;
    }
}
