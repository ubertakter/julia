// This file is a part of Julia. License is MIT: https://julialang.org/license

// RUN: clang -D__clang_gcanalyzer__ --analyze -Xanalyzer -analyzer-output=text -Xclang -load -Xclang libGCCheckerPlugin%shlibext -Xclang -verify -I%julia_home/src -I%julia_home/src/support -I%julia_home/usr/include ${CLANGSA_FLAGS} ${CLANGSA_CXXFLAGS} ${CPPFLAGS} ${CFLAGS} -Xclang -analyzer-checker=core,julia.GCChecker --analyzer-no-default-checks -x c++ %s

#include "julia.h"
#include <string>

void missingPop() {
  jl_value_t *x = NULL;
  JL_GC_PUSH1(&x); // expected-note{{GC frame changed here}}
} // expected-warning@-1{{Non-popped GC frame present at end of function}}
  // expected-note@-2{{Non-popped GC frame present at end of function}}


void missingPop2() {
  jl_value_t **x;
  JL_GC_PUSHARGS(x, 2); // expected-note{{GC frame changed here}}
} // expected-warning@-1{{Non-popped GC frame present at end of function}}
  // expected-note@-2{{Non-popped GC frame present at end of function}}

void superfluousPop() {
  JL_GC_POP(); // expected-warning{{JL_GC_POP without corresponding push}}
}              // expected-note@-1{{JL_GC_POP without corresponding push}}

// From gc.c, jl_gc_push_arraylist creates a custom stack frame.
extern void jl_gc_push_arraylist(jl_ptls_t ptls, arraylist_t *list);
extern void run_finalizer(jl_ptls_t ptls, jl_value_t *o, jl_value_t *ff);
void jl_gc_run_finalizers_in_list(jl_ptls_t ptls, arraylist_t *list)
{
    size_t len = list->len;
    jl_value_t **items = (jl_value_t**)list->items;
    jl_gc_push_arraylist(ptls, list);
    (void)len; (void)items;
    //for (size_t i = 2;i < len;i += 2)
    //    run_finalizer(ptls, items[i], items[i + 1]);
    JL_GC_POP();
}

bool testfunc1() JL_NOTSAFEPOINT
{
    struct implied_struct1 { // expected-note{{Tried to call method defined here}}
        std::string s;
        struct implied_constructor { } x;
    } x; // expected-warning{{Calling potential safepoint as CXXConstructorCall from function annotated JL_NOTSAFEPOINT}}
         // expected-note@-1{{Calling potential safepoint as CXXConstructorCall from function annotated JL_NOTSAFEPOINT}}
    return 1;
}
bool testfunc2() JL_NOTSAFEPOINT
{
    struct implied_struct2 { // expected-note{{Tried to call method defined here}}
        std::string s;
    } x{""};
    return 1; // expected-warning{{Calling potential safepoint as CXXDestructorCall from function annotated JL_NOTSAFEPOINT}}
              // expected-note@-1{{Calling potential safepoint as CXXDestructorCall from function annotated JL_NOTSAFEPOINT}}
}
