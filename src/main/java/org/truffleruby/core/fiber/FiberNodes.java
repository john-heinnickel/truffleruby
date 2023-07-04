/*
 * Copyright (c) 2013, 2023 Oracle and/or its affiliates. All rights reserved. This
 * code is released under a tri EPL/GPL/LGPL license. You can use it,
 * redistribute it and/or modify it under the terms of the:
 *
 * Eclipse Public License version 2.0, or
 * GNU General Public License version 2, or
 * GNU Lesser General Public License version 2.1.
 */
package org.truffleruby.core.fiber;

import com.oracle.truffle.api.dsl.GenerateCached;
import com.oracle.truffle.api.dsl.GenerateInline;
import com.oracle.truffle.api.frame.VirtualFrame;
import com.oracle.truffle.api.nodes.Node;
import com.oracle.truffle.api.profiles.InlinedBranchProfile;
import com.oracle.truffle.api.profiles.InlinedConditionProfile;
import com.oracle.truffle.api.strings.TruffleString;
import org.truffleruby.annotations.CoreMethod;
import org.truffleruby.annotations.CoreModule;
import org.truffleruby.annotations.Primitive;
import org.truffleruby.builtins.CoreMethodArrayArgumentsNode;
import org.truffleruby.builtins.PrimitiveArrayArgumentsNode;
import org.truffleruby.core.array.RubyArray;
import org.truffleruby.core.cast.SingleValueCastNode;
import org.truffleruby.core.encoding.Encodings;
import org.truffleruby.core.exception.RubyException;
import org.truffleruby.core.fiber.RubyFiber.FiberStatus;
import org.truffleruby.core.klass.RubyClass;
import org.truffleruby.core.proc.RubyProc;
import org.truffleruby.core.string.RubyString;
import org.truffleruby.core.thread.RubyThread;
import org.truffleruby.language.Nil;
import org.truffleruby.annotations.Visibility;
import org.truffleruby.language.RubyBaseNode;
import org.truffleruby.language.arguments.ArgumentsDescriptor;
import org.truffleruby.language.arguments.EmptyArgumentsDescriptor;
import org.truffleruby.language.arguments.RubyArguments;
import org.truffleruby.language.control.RaiseException;

import com.oracle.truffle.api.CompilerDirectives;
import com.oracle.truffle.api.CompilerDirectives.TruffleBoundary;
import com.oracle.truffle.api.dsl.Cached;
import com.oracle.truffle.api.dsl.Specialization;
import org.truffleruby.language.objects.AllocationTracing;

@CoreModule(value = "Fiber", isClass = true)
public abstract class FiberNodes {

    public abstract static class FiberTransferNodeAST extends CoreMethodArrayArgumentsNode {

        @Specialization
        protected Object transfer(
                RubyFiber currentFiber,
                RubyFiber toFiber,
                FiberOperation operation,
                ArgumentsDescriptor descriptor,
                Object[] args,
                @Cached FiberTransferNode fiberTransferNode) {
            return fiberTransferNode.execute(this, currentFiber, toFiber, operation, descriptor, args);
        }

    }

    @GenerateCached(false)
    @GenerateInline
    public abstract static class FiberTransferNode extends RubyBaseNode {

        public abstract Object execute(Node node, RubyFiber currentFiber, RubyFiber toFiber, FiberOperation operation,
                ArgumentsDescriptor descriptor, Object[] args);

        @Specialization
        protected static Object transfer(
                Node node,
                RubyFiber currentFiber,
                RubyFiber toFiber,
                FiberOperation operation,
                ArgumentsDescriptor descriptor,
                Object[] args,
                @Cached SingleValueCastNode singleValueCastNode,
                @Cached InlinedBranchProfile errorProfile) {

            if (toFiber.isTerminated()) {
                errorProfile.enter(node);
                throw new RaiseException(getContext(node), coreExceptions(node).deadFiberCalledError(node));
            }

            if (toFiber.rubyThread != currentFiber.rubyThread) {
                errorProfile.enter(node);
                throw new RaiseException(
                        getContext(node),
                        coreExceptions(node).fiberError("fiber called across threads", node));
            }

            var descriptorAndArgs = getContext(node).fiberManager.transferControlTo(currentFiber, toFiber, operation,
                    descriptor, args, node);
            // Ignore the descriptor like CRuby here, see https://bugs.ruby-lang.org/issues/18621
            return singleValueCastNode.executeSingleValue(descriptorAndArgs.args);
        }

    }

    @CoreMethod(names = { "__allocate__", "__layout_allocate__" }, constructor = true, visibility = Visibility.PRIVATE)
    public abstract static class AllocateNode extends CoreMethodArrayArgumentsNode {

        @Specialization
        protected RubyFiber allocate(RubyClass rubyClass) {
            if (getContext().getOptions().BACKTRACE_ON_NEW_FIBER) {
                getContext().getDefaultBacktraceFormatter().printBacktraceOnEnvStderr("fiber: ", this);
            }

            final RubyThread thread = getLanguage().getCurrentThread();
            final RubyFiber fiber = new RubyFiber(
                    rubyClass,
                    getLanguage().fiberShape,
                    getContext(),
                    getLanguage(),
                    thread,
                    FiberStatus.CREATED,
                    "<uninitialized>");
            AllocationTracing.trace(fiber, this);
            return fiber;
        }
    }

    @Primitive(name = "fiber_initialize")
    public abstract static class InitializeNode extends PrimitiveArrayArgumentsNode {

        @TruffleBoundary
        @Specialization
        protected Object initialize(RubyFiber fiber, boolean blocking, RubyProc block) {
            if (!getContext().getEnv().isCreateThreadAllowed()) {
                // Because TruffleThreadBuilder#build denies it already, before the thread is even started.
                // The permission is called allowCreateThread, so it kind of makes sense.
                throw new RaiseException(getContext(),
                        coreExceptions().securityError("fibers not allowed with allowCreateThread(false)", this));
            }

            getContext().fiberManager.initialize(fiber, blocking, block, this);
            return nil;
        }

        @Specialization
        protected Object noBlock(RubyFiber fiber, boolean blocking, Nil block) {
            throw new RaiseException(getContext(), coreExceptions().argumentErrorProcWithoutBlock(this));
        }

    }

    @CoreMethod(names = "transfer", rest = true)
    public abstract static class TransferNode extends CoreMethodArrayArgumentsNode {

        @Specialization
        protected Object transfer(VirtualFrame frame, RubyFiber toFiber, Object[] rawArgs,
                @Cached FiberTransferNode fiberTransferNode,
                @Cached SingleValueCastNode singleValueCastNode,
                @Cached InlinedConditionProfile sameFiberProfile,
                @Cached InlinedBranchProfile errorProfile) {

            if (toFiber.resumingFiber != null) {
                errorProfile.enter(this);
                throw new RaiseException(getContext(), coreExceptions()
                        .fiberError("attempt to transfer to a resuming fiber", this));
            }

            if (toFiber.yielding) {
                errorProfile.enter(this);
                throw new RaiseException(getContext(), coreExceptions()
                        .fiberError("attempt to transfer to a yielding fiber", this));
            }

            final RubyFiber currentFiber = getLanguage().getCurrentFiber();

            if (sameFiberProfile.profile(this, currentFiber == toFiber)) {
                // A Fiber can transfer to itself
                return singleValueCastNode.executeSingleValue(rawArgs);
            }

            return fiberTransferNode.execute(this, currentFiber, toFiber, FiberOperation.TRANSFER,
                    RubyArguments.getDescriptor(frame), rawArgs);
        }

    }


    public abstract static class FiberResumeNode extends CoreMethodArrayArgumentsNode {

        public static FiberResumeNode create() {
            return FiberNodesFactory.FiberResumeNodeFactory.create(null);
        }

        public abstract Object executeResume(FiberOperation operation, RubyFiber fiber, ArgumentsDescriptor descriptor,
                Object[] args);

        @Specialization
        protected Object resume(
                FiberOperation operation, RubyFiber toFiber, ArgumentsDescriptor descriptor, Object[] args,
                @Cached FiberTransferNode fiberTransferNode,
                @Cached InlinedBranchProfile errorProfile) {

            final RubyFiber currentFiber = getLanguage().getCurrentFiber();

            if (toFiber.isTerminated()) {
                errorProfile.enter(this);
                throw new RaiseException(
                        getContext(),
                        coreExceptions().fiberError("attempt to resume a terminated fiber", this));
            } else if (toFiber == currentFiber) {
                errorProfile.enter(this);
                throw new RaiseException(
                        getContext(),
                        coreExceptions().fiberError("attempt to resume the current fiber", this));
            } else if (toFiber.lastResumedByFiber != null) {
                errorProfile.enter(this);
                throw new RaiseException(
                        getContext(),
                        coreExceptions().fiberError("attempt to resume a resumed fiber (double resume)", this));
            } else if (toFiber.resumingFiber != null) {
                errorProfile.enter(this);
                throw new RaiseException(
                        getContext(),
                        coreExceptions().fiberError("attempt to resume a resuming fiber", this));
            } else if (toFiber.lastResumedByFiber == null &&
                    (!toFiber.yielding && toFiber.status != FiberStatus.CREATED)) {
                errorProfile.enter(this);
                throw new RaiseException(
                        getContext(),
                        coreExceptions().fiberError("attempt to resume a transferring fiber", this));
            }

            return fiberTransferNode.execute(this, currentFiber, toFiber, operation, descriptor, args);
        }

    }


    @Primitive(name = "fiber_raise")
    public abstract static class FiberRaiseNode extends PrimitiveArrayArgumentsNode {

        @Child private FiberResumeNode fiberResumeNode;

        @Specialization
        protected Object raise(RubyFiber fiber, RubyException exception,
                @Cached FiberTransferNode fiberTransferNode,
                @Cached InlinedBranchProfile errorProfile) {
            if (fiber.resumingFiber != null) {
                errorProfile.enter(this);
                throw new RaiseException(
                        getContext(),
                        coreExceptions().fiberError("attempt to raise a resuming fiber", this));
            } else if (fiber.status == FiberStatus.CREATED) {
                errorProfile.enter(this);
                throw new RaiseException(
                        getContext(),
                        coreExceptions().fiberError("cannot raise exception on unborn fiber", this));
            }

            if (fiber.status == FiberStatus.SUSPENDED && !fiber.yielding) {
                final RubyFiber currentFiber = getLanguage().getCurrentFiber();
                return fiberTransferNode.execute(
                        this,
                        currentFiber,
                        fiber,
                        FiberOperation.RAISE,
                        EmptyArgumentsDescriptor.INSTANCE,
                        new Object[]{ exception });
            } else {
                return getResumeNode().executeResume(FiberOperation.RAISE, fiber,
                        EmptyArgumentsDescriptor.INSTANCE, new Object[]{ exception });
            }
        }

        private FiberResumeNode getResumeNode() {
            if (fiberResumeNode == null) {
                CompilerDirectives.transferToInterpreterAndInvalidate();
                fiberResumeNode = insert(FiberResumeNode.create());
            }
            return fiberResumeNode;
        }

    }

    @CoreMethod(names = "resume", rest = true)
    public abstract static class ResumeNode extends CoreMethodArrayArgumentsNode {

        @Child private FiberResumeNode fiberResumeNode = FiberResumeNode.create();

        @Specialization
        protected Object resume(VirtualFrame frame, RubyFiber fiber, Object[] rawArgs) {
            return fiberResumeNode.executeResume(FiberOperation.RESUME, fiber,
                    RubyArguments.getDescriptor(frame), rawArgs);
        }

    }

    @CoreMethod(names = "yield", onSingleton = true, rest = true)
    public abstract static class YieldNode extends CoreMethodArrayArgumentsNode {


        @Specialization
        protected Object fiberYield(VirtualFrame frame, Object[] rawArgs,
                @Cached FiberTransferNode fiberTransferNode,
                @Cached InlinedBranchProfile errorProfile) {

            final RubyFiber currentFiber = getLanguage().getCurrentFiber();

            final RubyFiber fiberYieldedTo = getContext().fiberManager
                    .getReturnFiber(currentFiber, this, errorProfile);

            return fiberTransferNode.execute(
                    this,
                    currentFiber,
                    fiberYieldedTo,
                    FiberOperation.YIELD,
                    RubyArguments.getDescriptor(frame),
                    rawArgs);
        }

    }

    @CoreMethod(names = "alive?")
    public abstract static class AliveNode extends CoreMethodArrayArgumentsNode {

        @Specialization
        protected boolean alive(RubyFiber fiber) {
            return fiber.status != FiberStatus.TERMINATED;
        }

    }

    @CoreMethod(names = "current", onSingleton = true)
    public abstract static class CurrentNode extends CoreMethodArrayArgumentsNode {

        @Specialization
        protected RubyFiber current() {
            return getLanguage().getCurrentFiber();
        }

    }

    @Primitive(name = "fiber_source_location")
    public abstract static class FiberSourceLocationNode extends PrimitiveArrayArgumentsNode {
        @Specialization
        protected RubyString sourceLocation(RubyFiber fiber,
                @Cached TruffleString.FromJavaStringNode fromJavaStringNode) {
            return createString(fromJavaStringNode, fiber.sourceLocation, Encodings.UTF_8);
        }
    }

    @Primitive(name = "fiber_status")
    public abstract static class FiberStatusNode extends PrimitiveArrayArgumentsNode {
        @Specialization
        protected RubyString status(RubyFiber fiber,
                @Cached TruffleString.FromJavaStringNode fromJavaStringNode) {
            return createString(fromJavaStringNode, fiber.status.label, Encodings.UTF_8);
        }
    }

    @Primitive(name = "fiber_thread")
    public abstract static class FiberThreadNode extends PrimitiveArrayArgumentsNode {
        @Specialization
        protected RubyThread thread(RubyFiber fiber) {
            return fiber.rubyThread;
        }
    }

    @Primitive(name = "fiber_get_catch_tags")
    public abstract static class FiberGetCatchTagsNode extends PrimitiveArrayArgumentsNode {

        @Specialization
        protected RubyArray getCatchTags() {
            final RubyFiber currentFiber = getLanguage().getCurrentFiber();
            return currentFiber.catchTags;
        }
    }


    @CoreMethod(names = "blocking?")
    public abstract static class IsBlockingInstanceNode extends CoreMethodArrayArgumentsNode {

        @Specialization
        protected boolean isBlocking(RubyFiber fiber) {
            return fiber.blocking;
        }

    }

    @CoreMethod(names = "blocking?", onSingleton = true)
    public abstract static class IsBlockingNode extends CoreMethodArrayArgumentsNode {

        @Specialization
        protected Object isBlocking() {
            RubyFiber currentFiber = getLanguage().getCurrentFiber();
            if (currentFiber.blocking) {
                return 1;
            } else {
                return false;
            }
        }

    }

    @Primitive(name = "fiber_c_global_variables")
    public abstract static class FiberCGlobalVariablesNode extends PrimitiveArrayArgumentsNode {
        @Specialization
        protected Object cGlobalVariables() {
            RubyFiber currentFiber = getLanguage().getCurrentFiber();
            var cGlobalVariablesDuringInitFunction = currentFiber.cGlobalVariablesDuringInitFunction;
            if (cGlobalVariablesDuringInitFunction == null) {
                return nil;
            } else {
                return cGlobalVariablesDuringInitFunction;
            }
        }
    }

}
