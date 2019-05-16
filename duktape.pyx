cimport cduk
cimport cpython

import os
import threading
import sys
from libc.stdio cimport printf


cdef cduk.duk_int_t _ref_map_next_id = 1


class Error(Exception):
    pass


cdef force_unicode(b):
    return b.decode("utf-8")


cdef smart_str(s):
    return s.encode("utf-8") if isinstance(s, unicode) else s


cdef duk_context_dump(cduk.duk_context *ctx):
    cduk.duk_push_context_dump(ctx)
    dump = force_unicode(cduk.duk_to_string(ctx, -1))
    cduk.duk_pop(ctx)
    cduk.duk_push_pointer(ctx, <void*>ctx)
    addr = force_unicode(cduk.duk_to_string(ctx, -1))
    cduk.duk_pop(ctx)
    return '(%s) %s' % (addr, dump)


cdef duk_reraise(cduk.duk_context *ctx, cduk.duk_int_t rc):
    if rc:
        if cduk.duk_is_error(ctx, -1):
            cduk.duk_get_prop_string(ctx, -1, "stack")
            stack_trace = cduk.duk_safe_to_string(ctx, -1)
            cduk.duk_pop(ctx)
            raise Error(force_unicode(stack_trace))
        else:
            raise Error(force_unicode(cduk.duk_safe_to_string(ctx, -1)))


cdef cduk.duk_ret_t duk_mod_search(cduk.duk_context *ctx):
    cduk.duk_push_current_function(ctx)
    cduk.duk_get_prop_string(ctx, -1, '__duktape_module_path__')
    mod_path = cduk.duk_require_string(ctx, -1)
    cduk.duk_pop_n(ctx, 2)

    mod_file = os.path.join(mod_path, cduk.duk_require_string(ctx, -1))
    if not mod_file.endswith('.js'):
        mod_file += '.js'
    cduk.fileio_push_file_string(ctx, smart_str(mod_file))
    return 1


class PyFunc:

    def __init__(self, func, nargs=None):
        self.func = func
        self.nargs = nargs


cdef to_python_string(Context pyctx, cduk.duk_idx_t idx):
    cdef cduk.duk_context *ctx = pyctx.ctx
    cdef cduk.duk_size_t strlen
    cdef const char *buf = cduk.duk_get_lstring(ctx, idx, &strlen)
    return force_unicode(buf[:strlen])


cdef to_python_list(Context pyctx, cduk.duk_idx_t idx):
    cdef cduk.duk_context *ctx = pyctx.ctx
    ret = []
    for i in range(cduk.duk_get_length(ctx, idx)):
        cduk.duk_get_prop_index(ctx, idx, i)
        ret.append(to_python(pyctx, -1))
        cduk.duk_pop(ctx)
    return ret


cdef to_python_dict(Context pyctx, cduk.duk_idx_t idx):
    cdef cduk.duk_context *ctx = pyctx.ctx
    ret = {}
    cduk.duk_enum(ctx, idx, cduk.DUK_ENUM_OWN_PROPERTIES_ONLY)
    while cduk.duk_next(ctx, idx, 1):
        ret[to_python(pyctx, -2)] = to_python(pyctx, -1)
        cduk.duk_pop_n(ctx, 2)
    cduk.duk_pop_n(ctx, 1)
    return ret


cdef to_python_func(Context pyctx, cduk.duk_idx_t idx):
    global _ref_map_next_id

    cdef cduk.duk_context *ctx = pyctx.ctx
    cdef cduk.duk_int_t _ref_id = _ref_map_next_id
    _ref_map_next_id += 1

    fidx = cduk.duk_normalize_index(ctx, idx)

    cduk.duk_push_global_stash(ctx)  # [ ... stash ]
    cduk.duk_get_prop_string(ctx, -1, "_ref_map")  # [ ... stash _ref_map ]
    cduk.duk_push_int(ctx, _ref_id)  # [ ... stash _ref_map id ]
    cduk.duk_dup(ctx, fidx)  # [ ... stash _ref_map id func ]
    cduk.duk_put_prop(ctx, -3)  # [ ... stash _ref_map ]
    cduk.duk_pop_n(ctx, 2)

    f = Func(pyctx)
    f._ref_id = _ref_id
    return f


cdef class Func:

    cdef Context pyctx
    cdef cduk.duk_int_t _ref_id

    def __init__(self, Context pyctx):
        self.pyctx = pyctx

    def __call__(self, *args):
        cdef cduk.duk_context *ctx = self.pyctx.ctx

        cduk.duk_push_global_stash(ctx)  # -> [ ... stash ]
        cduk.duk_get_prop_string(ctx, -1, "_ref_map")  # -> [ ... stash _ref_map ]
        cduk.duk_push_int(ctx, self._ref_id)  # -> [ ... stash _ref_map _ref_id ]
        cduk.duk_get_prop(ctx, -2)  # -> [ ... stash _ref_map func ]
        for arg in args:
            to_js(self.pyctx, arg)
        duk_reraise(ctx, cduk.duk_pcall(ctx, len(args)))  # -> [ ... stash _ref_map retval ]
        ret = to_python(self.pyctx, -1)
        cduk.duk_pop_n(ctx, 3)
        return ret


cdef to_python(Context pyctx, cduk.duk_idx_t idx):
    cdef cduk.duk_context *ctx = pyctx.ctx
    if cduk.duk_is_boolean(ctx, idx):
        return bool(cduk.duk_get_boolean(ctx, idx))
    elif cduk.duk_is_nan(ctx, idx):
        return float("nan")
    elif cduk.duk_is_null_or_undefined(ctx, idx):
        return None
    elif cduk.duk_is_number(ctx, idx):
        num = float(cduk.duk_get_number(ctx, idx))
        return int(num) if num.is_integer() else num
    elif cduk.duk_is_string(ctx, idx):
        return to_python_string(pyctx, idx)
    elif cduk.duk_is_array(ctx, idx):
        return to_python_list(pyctx, idx)
    elif cduk.duk_is_function(ctx, idx):
        return to_python_func(pyctx, idx)
    elif cduk.duk_is_object(ctx, idx):
        return to_python_dict(pyctx, idx)
    else:
        return 'unknown'
        # raise TypeError("not_coercible", cduk.duk_get_type(ctx, idx))


cdef cduk.duk_ret_t js_func_wrapper(cduk.duk_context *ctx):
    # [ args... ]
    cdef cduk.duk_int_t nargs

    cduk.duk_push_global_stash(ctx)
    cduk.duk_get_prop_string(ctx, -1, "_pyctx_pointer")
    pyctx = <Context>cduk.duk_get_pointer(ctx, -1)
    cduk.duk_pop_n(ctx, 2)

    nargs = cduk.duk_get_top(ctx)
    cduk.duk_push_current_function(ctx)

    if cduk.duk_has_prop_string(ctx, -1, "__duktape_cfunc_nargs__"):
        cduk.duk_get_prop_string(ctx, -1, "__duktape_cfunc_nargs__")
        nargs = cduk.duk_require_int(ctx, -1)
        cduk.duk_pop(ctx)

    cduk.duk_get_prop_string(ctx, -1, "__duktape_cfunc_pointer__")
    func = <object>cduk.duk_get_pointer(ctx, -1)
    cduk.duk_pop(ctx)

    cduk.duk_pop(ctx)

    args = [to_python(pyctx, idx) for idx in range(nargs)]
    to_js(pyctx, func(*args))
    return 1


cdef cduk.duk_ret_t js_func_finalizer(cduk.duk_context *ctx):
    cduk.duk_get_prop_string(ctx, 0, "__duktape_cfunc_pointer__")
    func = <object>cduk.duk_get_pointer(ctx, -1)
    cduk.duk_pop(ctx)
    cpython.Py_DECREF(func)
    return 0


cdef to_js_func(Context pyctx, pyfunc):
    cdef cduk.duk_context *ctx = pyctx.ctx

    func, nargs = pyfunc.func, pyfunc.nargs
    cpython.Py_INCREF(func)
    cduk.duk_push_c_function(ctx, js_func_wrapper, -1)  # [ ... js_func_wrapper ]
    cduk.duk_push_c_function(ctx, js_func_finalizer, -1)  # [ ... js_func_wrapper js_func_finalizer ]
    cduk.duk_set_finalizer(ctx, -2)  # [ ... js_func_wrapper ]
    cduk.duk_push_pointer(ctx, <void*>func)  # [ ... js_func_wrapper func ]
    cduk.duk_put_prop_string(ctx, -2, "__duktape_cfunc_pointer__")  # [ ... js_func_wrapper ]
    if nargs is not None:
        cduk.duk_push_number(ctx, nargs)  # [ ... js_func_wrapper nargs ]
        cduk.duk_put_prop_string(ctx, -2, "__duktape_cfunc_nargs__")   # [ ... js_func_wrapper ]


cdef to_js_array(Context pyctx, lst):
    cdef cduk.duk_context *ctx = pyctx.ctx

    cduk.duk_push_array(ctx)
    for i, value in enumerate(lst):
        to_js(pyctx, value)
        cduk.duk_put_prop_index(ctx, -2, i)


cdef to_js_dict(Context pyctx, dct):
    cdef cduk.duk_context *ctx = pyctx.ctx

    cduk.duk_push_object(ctx)
    for key, value in dct.items():
        to_js(pyctx, value)
        cduk.duk_put_prop_string(ctx, -2, smart_str(key))


cdef to_js(Context pyctx, value):
    cdef cduk.duk_context *ctx = pyctx.ctx

    if value is None:
        cduk.duk_push_null(ctx)
    elif isinstance(value, basestring):
        cduk.duk_push_string(ctx, smart_str(value))
    elif isinstance(value, bool):
        if value:
            cduk.duk_push_true(ctx)
        else:
            cduk.duk_push_false(ctx)
    elif isinstance(value, int):
        cduk.duk_push_int(ctx, value)
    elif isinstance(value, float):
        cduk.duk_push_number(ctx, value)
    elif isinstance(value, (list, tuple)):
        to_js_array(pyctx, value)
    elif isinstance(value, dict):
        to_js_dict(pyctx, value)
    elif callable(value):
        to_js_func(pyctx, PyFunc(value))
    elif isinstance(value, PyFunc):
        to_js_func(pyctx, value)


class Type:

    mapping = {
        cduk.DUK_TYPE_NONE: "missing",
        cduk.DUK_TYPE_UNDEFINED: "undefined",
        cduk.DUK_TYPE_NULL: type(None),
        cduk.DUK_TYPE_BOOLEAN: bool,
        cduk.DUK_TYPE_NUMBER: float,
        cduk.DUK_TYPE_STRING: str,
        cduk.DUK_TYPE_OBJECT: object,
    }

    def __init__(self, value):
        self.value = value

    def as_pytype(self):
        return self.mapping[self.value]

    def __repr__(self):
        return "<duktape.Type {0} {1}>".format(self.value, self.as_pytype())


cdef class Context:

    cdef cduk.duk_context *ctx
    cdef object module_path

    def __init__(self, module_path=None):
        self.ctx = cduk.duk_create_heap_default()
        self.module_path = module_path
        self.setup()

    def __dealloc__(self):
        if self.ctx:
            cduk.duk_destroy_heap(self.ctx)
            self.ctx = NULL

    def setup(self):
        cduk.duk_push_global_stash(self.ctx)
        cduk.duk_push_pointer(self.ctx, <void*>self)
        cduk.duk_put_prop_string(self.ctx, -2, "_pyctx_pointer")
        cduk.duk_push_object(self.ctx)
        cduk.duk_put_prop_string(self.ctx, -2, "_ref_map")
        cduk.duk_pop(self.ctx)

        if self.module_path:
            cduk.duk_module_duktape_init(self.ctx)
            cduk.duk_get_global_string(self.ctx, 'Duktape')
            cduk.duk_push_c_function(self.ctx, duk_mod_search, 1)
            cduk.duk_push_string(self.ctx, self.module_path)
            cduk.duk_put_prop_string(self.ctx, -2, "__duktape_module_path__")
            cduk.duk_put_prop_string(self.ctx, -2, 'modSearch')
            cduk.duk_pop(self.ctx)

    def __setitem__(self, key, value):
        to_js(self, value)
        cduk.duk_put_global_string(self.ctx, smart_str(key))

    def __getitem__(self, key):
        cduk.duk_get_global_string(self.ctx, smart_str(key))
        return to_python(self, -1)

    def __len__(self):
        return cduk.duk_get_top(self.ctx)

    def load(self, filename):
        # Global code: compiles into a function with zero arguments, which
        # executes like a top level ECMAScript program
        #
        # "use strict" causes global lookup failure #163
        # https://github.com/svaarala/duktape/issues/163
        #
        # Strict eval code cannot establish global bindings through
        # variable/function declarations; this is part of the Ecmascript
        # standard.
        # If you want a script file to be strict and establish global
        # bindings, you can compile and run the script as a program code
        # (default, flags=0) instead of eval code. You can do so by using
        # duk_pcompile() and duk_pcall() instead of duk_peval() (which is a
        # convenience call for eval code).
        # Current duk_(p)eval() won't supply a this binding.
        cduk.fileio_push_file_string(self.ctx, smart_str(filename)) # [ ... source ]
        cduk.duk_push_string(self.ctx, smart_str(filename)) # [ ... source filename ]
        duk_reraise(self.ctx, cduk.duk_pcompile(self.ctx, 0)) # [ ... func ]
        # bind 'this' to global object
        cduk.duk_push_global_object(self.ctx)  # [ ... func global ]
        duk_reraise(self.ctx, cduk.duk_pcall_method(self.ctx, 0)) # [ ... retval ]
        cduk.duk_pop(self.ctx)

    def eval(self, js):
        # Eval code: compiles into a function with zero arguments, which
        # executes like an ECMAScript eval call
        duk_reraise(self.ctx, cduk.duk_peval_string(self.ctx, smart_str(js)))
        return to_python(self, -1)

    loads = eval

    def gc(self):
        cduk.duk_gc(self.ctx, 0)

    def _get(self):
        return to_python(self, -1)

    def _push(self, value):
        to_js(self, value)

    def _type(self, idx=-1):
        return Type(cduk.duk_get_type(self.ctx, idx))
