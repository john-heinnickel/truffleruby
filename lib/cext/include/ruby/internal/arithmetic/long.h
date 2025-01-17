#ifndef RBIMPL_ARITHMETIC_LONG_H                     /*-*-C++-*-vi:se ft=cpp:*/
#define RBIMPL_ARITHMETIC_LONG_H
/**
 * @file
 * @author     Ruby developers <ruby-core@ruby-lang.org>
 * @copyright  This  file  is   a  part  of  the   programming  language  Ruby.
 *             Permission  is hereby  granted,  to  either redistribute  and/or
 *             modify this file, provided that  the conditions mentioned in the
 *             file COPYING are met.  Consult the file for details.
 * @warning    Symbols   prefixed  with   either  `RBIMPL`   or  `rbimpl`   are
 *             implementation details.   Don't take  them as canon.  They could
 *             rapidly appear then vanish.  The name (path) of this header file
 *             is also an  implementation detail.  Do not expect  it to persist
 *             at the place it is now.  Developers are free to move it anywhere
 *             anytime at will.
 * @note       To  ruby-core:  remember  that   this  header  can  be  possibly
 *             recursively included  from extension  libraries written  in C++.
 *             Do not  expect for  instance `__VA_ARGS__` is  always available.
 *             We assume C99  for ruby itself but we don't  assume languages of
 *             extension libraries. They could be written in C++98.
 * @brief      Arithmetic conversion between C's `long` and Ruby's.
 *
 * ### Q&A ###
 *
 * - Q: Why are INT2FIX etc. here, not in `int.h`?
 *
 * - A: Because they  are in fact  handling `long`.   It seems someone  did not
 *      understand the difference of `int`  and `long` when they designed those
 *      macros.
 */
#include "ruby/internal/config.h"
#include "ruby/internal/arithmetic/fixnum.h"   /* FIXABLE */
#include "ruby/internal/arithmetic/intptr_t.h" /* rb_int2big etc.*/
#include "ruby/internal/assume.h"
#include "ruby/internal/attr/artificial.h"
#include "ruby/internal/attr/cold.h"
#include "ruby/internal/attr/const.h"
#include "ruby/internal/attr/constexpr.h"
#include "ruby/internal/attr/noreturn.h"
#include "ruby/internal/cast.h"
#include "ruby/internal/dllexport.h"
#include "ruby/internal/special_consts.h"      /* FIXNUM_FLAG */
#include "ruby/internal/value.h"
#include "ruby/assert.h"

#define FIX2LONG     RB_FIX2LONG
#define FIX2ULONG    RB_FIX2ULONG
#define INT2FIX      RB_INT2FIX
#define LONG2FIX     RB_INT2FIX
#define LONG2NUM     RB_LONG2NUM
#define NUM2LONG     RB_NUM2LONG
#define NUM2ULONG    RB_NUM2ULONG
#ifdef TRUFFLERUBY
#define RB_FIX2LONG(x) ((long)polyglot_as_i64(rb_tr_unwrap(x)))
#else
#define RB_FIX2LONG  rb_fix2long
#endif
#define RB_FIX2ULONG rb_fix2ulong
#ifdef TRUFFLERUBY
#define RB_LONG2FIX(i) (VALUE)rb_tr_longwrap((long)(i))
#else
#define RB_LONG2FIX  RB_INT2FIX
#endif
#define RB_LONG2NUM  rb_long2num_inline
#define RB_NUM2LONG  rb_num2long_inline
#define RB_NUM2ULONG rb_num2ulong_inline
#define RB_ULONG2NUM rb_ulong2num_inline
#define ULONG2NUM    RB_ULONG2NUM
#define rb_fix_new   RB_INT2FIX
#ifdef TRUFFLERUBY
#define rb_long2int  rb_long2int
#else
#define rb_long2int  rb_long2int_inline
#endif

/** @cond INTERNAL_MACRO */
#define RB_INT2FIX RB_INT2FIX
/** @endcond */

RBIMPL_SYMBOL_EXPORT_BEGIN()

RBIMPL_ATTR_NORETURN()
RBIMPL_ATTR_COLD()
void rb_out_of_int(SIGNED_VALUE num);

long rb_num2long(VALUE num);
unsigned long rb_num2ulong(VALUE num);
#ifdef TRUFFLERUBY
int rb_long2int(long value);
#endif
RBIMPL_SYMBOL_EXPORT_END()

RBIMPL_ATTR_CONST_UNLESS_DEBUG()
RBIMPL_ATTR_CONSTEXPR_UNLESS_DEBUG(CXX14)
RBIMPL_ATTR_ARTIFICIAL()
static inline VALUE
RB_INT2FIX(long i)
{
    RBIMPL_ASSERT_OR_ASSUME(RB_FIXABLE(i));

    /* :NOTE: VALUE can be wider than long.  As j being unsigned, 2j+1 is fully
     * defined. Also it can be compiled into a single LEA instruction. */
    const unsigned long j = i;
    const unsigned long k = 2 * j + RUBY_FIXNUM_FLAG;
    const long          l = k;
    const SIGNED_VALUE  m = l; /* Sign extend */
    const VALUE         n = m;

    RBIMPL_ASSERT_OR_ASSUME(RB_FIXNUM_P(n));
    return n;
}

#ifndef TRUFFLERUBY
static inline int
rb_long2int_inline(long n)
{
    int i = RBIMPL_CAST((int)n);

    if /* constexpr */ (sizeof(long) <= sizeof(int)) {
        RBIMPL_ASSUME(i == n);
    }

    if (i != n)
        rb_out_of_int(n);

    return i;
}
#endif

RBIMPL_ATTR_CONST_UNLESS_DEBUG()
RBIMPL_ATTR_CONSTEXPR_UNLESS_DEBUG(CXX14)
static inline long
rbimpl_fix2long_by_idiv(VALUE x)
{
    RBIMPL_ASSERT_OR_ASSUME(RB_FIXNUM_P(x));

    /* :NOTE: VALUE  can be wider  than long.  (x-1)/2 never  overflows because
     * RB_FIXNUM_P(x)  holds.   Also it  has  no  portability issue  like  y>>1
     * below. */
    const SIGNED_VALUE y = x - RUBY_FIXNUM_FLAG;
    const SIGNED_VALUE z = y / 2;
    const long         w = RBIMPL_CAST((long)z);

    RBIMPL_ASSERT_OR_ASSUME(RB_FIXABLE(w));
    return w;
}

RBIMPL_ATTR_CONST_UNLESS_DEBUG()
RBIMPL_ATTR_CONSTEXPR_UNLESS_DEBUG(CXX14)
static inline long
rbimpl_fix2long_by_shift(VALUE x)
{
    RBIMPL_ASSERT_OR_ASSUME(RB_FIXNUM_P(x));

    /* :NOTE: VALUE can be wider than long.  If right shift is arithmetic, this
     * is noticeably faster than above. */
    const SIGNED_VALUE y = x;
    const SIGNED_VALUE z = y >> 1;
    const long         w = RBIMPL_CAST((long)z);

    RBIMPL_ASSERT_OR_ASSUME(RB_FIXABLE(w));
    return w;
}

RBIMPL_ATTR_CONST()
RBIMPL_ATTR_CONSTEXPR(CXX11)
static inline bool
rbimpl_right_shift_is_arithmetic_p(void)
{
    return (-1 >> 1) == -1;
}

RBIMPL_ATTR_CONST_UNLESS_DEBUG()
#ifndef TRUFFLERUBY
RBIMPL_ATTR_CONSTEXPR_UNLESS_DEBUG(CXX14)
#endif
static inline long
rb_fix2long(VALUE x)
{
#ifdef TRUFFLERUBY
    return ((long)polyglot_as_i64(rb_tr_unwrap(x)));
#else
    if /* constexpr */ (rbimpl_right_shift_is_arithmetic_p()) {
        return rbimpl_fix2long_by_shift(x);
    }
    else {
        return rbimpl_fix2long_by_idiv(x);
    }
#endif
}

RBIMPL_ATTR_CONST_UNLESS_DEBUG()
RBIMPL_ATTR_CONSTEXPR_UNLESS_DEBUG(CXX14)
static inline unsigned long
rb_fix2ulong(VALUE x)
{
    RBIMPL_ASSERT_OR_ASSUME(RB_FIXNUM_P(x));
    return rb_fix2long(x);
}

static inline long
rb_num2long_inline(VALUE x)
{
    if (RB_FIXNUM_P(x))
        return RB_FIX2LONG(x);
    else
        return rb_num2long(x);
}

static inline unsigned long
rb_num2ulong_inline(VALUE x)
{
    /* This (negative fixnum would become  a large unsigned long while negative
     * bignum is  an exception) has been  THE behaviour of NUM2ULONG  since the
     * beginning.  It is strange,  but we can no longer change  how it works at
     * this moment.  We have to get by with it.  See also:
     * https://bugs.ruby-lang.org/issues/9089 */
    if (RB_FIXNUM_P(x))
        return RB_FIX2ULONG(x);
    else
        return rb_num2ulong(x);
}

static inline VALUE
rb_long2num_inline(long v)
{
    if (RB_FIXABLE(v))
        return RB_LONG2FIX(v);
    else
        return rb_int2big(v);
}

static inline VALUE
rb_ulong2num_inline(unsigned long v)
{
    if (RB_POSFIXABLE(v))
        return RB_LONG2FIX(v);
    else
#ifdef TRUFFLERUBY
        return rb_tr_wrap(polyglot_invoke(RUBY_CEXT, "rb_ulong2num", (long) v));
#else
        return rb_uint2big(v);
#endif
}

/**
 * @cond INTERNAL_MACRO
 *
 * Following overload is necessary because sometimes  INT2FIX is used as a enum
 * value (e.g. `enum {  FOO = INT2FIX(0) };`).  THIS IS NG  in theory because a
 * VALUE does not fit into an enum (which must be a signed int).  But we cannot
 * break existing codes.
 */
#if RBIMPL_HAS_ATTR_CONSTEXPR_CXX14
# /* C++ can write constexpr as enum values. */

#elif ! defined(HAVE_BUILTIN___BUILTIN_CHOOSE_EXPR_CONSTANT_P)
# undef INT2FIX
# define INT2FIX(i) (RBIMPL_CAST((VALUE)(i)) << 1 | RUBY_FIXNUM_FLAG)

#else
# undef INT2FIX
# define INT2FIX(i)                                     \
    __builtin_choose_expr(                              \
        __builtin_constant_p(i),                        \
        RBIMPL_CAST((VALUE)(i)) << 1 | RUBY_FIXNUM_FLAG, \
        RB_INT2FIX(i))
#endif
/** @endcond */

#endif /* RBIMPL_ARITHMETIC_LONG_H */
