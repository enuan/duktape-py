cimport cduk
cimport cpython

import datetime
import os
import threading
import sys
from libc.stdio cimport printf

import pytz


cdef cduk.duk_int_t _ref_map_next_id = 1


class Error(Exception):
    pass


cdef force_unicode(b):
    return b.decode("utf-8")


cdef smart_str(s):
    return unicode_encode_cesu8(s) if isinstance(s, unicode) else s


cdef unicode_encode_cesu8(ustring):
    # python transposition of duk_unicode_encode_cesu8(duk_ucodepoint_t cp, duk_uint8_t *out)
    out = []
    for uchar in ustring:
        x = ord(uchar)
        if x < 0x80:
            out.extend([chr(x)])
        elif x < 0x800:
            out.extend([chr(0xc0 + ((x >> 6) & 0x1f)),
                        chr(0x80 + (x & 0x3f))])
        elif x < 0x10000:
            out.extend([chr(0xe0 + ((x >> 12) & 0x0f)),
                        chr(0x80 + ((x >> 6) & 0x3f)),
                        chr(0x80 + (x & 0x3f))])
        else:
            x -= 0x10000
            out.extend([chr(0xed),
                        chr(0xa0 + ((x >> 16) & 0x0f)),
                        chr(0x80 + ((x >> 10) & 0x3f)),
                        chr(0xed),
                        chr(0xb0 + ((x >> 6) & 0x0f)),
                        chr(0x80 + (x & 0x3f))])
    return ''.join(out)


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
            stacktrace = cduk.duk_safe_to_stacktrace(ctx, -1)
            cduk.duk_pop(ctx)
            raise Error(force_unicode(stacktrace))
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
        if cduk.duk_get_global_string(ctx, "Date") and cduk.duk_instanceof(ctx, idx-1, -1):
            cduk.duk_pop(ctx)
            cduk.duk_push_string(ctx, "getTime")
            cduk.duk_pcall_prop(ctx, -2, 0)
            epoch_ms = cduk.duk_get_number(ctx, idx)
            cduk.duk_pop(ctx)
            # always return an UTC datetime
            return pytz.utc.localize(datetime.datetime.utcfromtimestamp(epoch_ms/1e3))
        else:
            cduk.duk_pop(ctx)
        return to_python_dict(pyctx, idx)
    else:
        return 'unknown'
        # raise TypeError("not_coercible", cduk.duk_get_type(ctx, idx))


cdef cduk.duk_ret_t js_func_wrapper(cduk.duk_context *ctx):
    # [ args... ]
    cdef cduk.duk_int_t nargs

    cduk.duk_push_thread_stash(ctx, ctx)
    cduk.duk_get_prop_string(ctx, -1, "_pythr_pointer")
    if cduk.duk_is_undefined(ctx, -1):
        cduk.duk_pop_n(ctx, 2)
        cduk.duk_push_global_stash(ctx)
        cduk.duk_get_prop_string(ctx, -1, "_pyctx_pointer")
        pyctx = <Context>cduk.duk_get_pointer(ctx, -1)
    else:
        pyctx = <ThreadContext>cduk.duk_get_pointer(ctx, -1)
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
    cduk.duk_push_c_function(ctx, js_func_wrapper,
                             nargs if nargs is not None else cduk.DUK_VARARGS)  # [ ... js_func_wrapper ]
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


UNIX_EPOCH = datetime.datetime.utcfromtimestamp(0)

cdef to_js_datetime(Context pyctx, value):
    cdef cduk.duk_context *ctx = pyctx.ctx
    cduk.duk_get_global_string(ctx, "Date")         # [ ... Date ]
    if isinstance(value, datetime.datetime):
        # if tzinfo is None we assume UTC as timezone
        if value.tzinfo:
            # otherwise we localize to UTC
            value = value.astimezone(pytz.utc).replace(tzinfo=None)
    elif isinstance(value, datetime.date):
        # push date as YYYY-MM-DD 00:00:00
        value = datetime.datetime.combine(value, datetime.time.min)
    elif isinstance(value, datetime.time):
        # push time as 1970-01-01 HH:MM:SS
        value = datetime.datetime.combine(UNIX_EPOCH.date(), value)
    epoch_s = (value - UNIX_EPOCH).total_seconds()
    cduk.duk_push_number(ctx, epoch_s*1e3)          # [ ... Date epoch_s ]
    duk_reraise(ctx, cduk.duk_pnew(ctx, 1))         # [ ... retval ]


cdef to_js(Context pyctx, value):
    cdef cduk.duk_context *ctx = pyctx.ctx

    if value is None:
        cduk.duk_push_null(ctx)
    elif isinstance(value, basestring):
        if isinstance(value, unicode):
            value = unicode_encode_cesu8(value)
        cduk.duk_push_string(ctx, value)
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
    elif isinstance(value, (datetime.datetime,
                            datetime.date,
                            datetime.time)):
        to_js_datetime(pyctx, value)
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
        cduk.duk_push_object(self.ctx)
        cduk.duk_put_prop_string(self.ctx, -2, "_threads")
        cduk.duk_pop(self.ctx)

        if self.module_path:
            cduk.duk_module_duktape_init(self.ctx)
            cduk.duk_get_global_string(self.ctx, 'Duktape')
            cduk.duk_push_c_function(self.ctx, duk_mod_search, 1)
            cduk.duk_push_string(self.ctx, self.module_path)
            cduk.duk_put_prop_string(self.ctx, -2, "__duktape_module_path__")
            cduk.duk_put_prop_string(self.ctx, -2, 'modSearch')
            cduk.duk_pop(self.ctx)

    def __bool__(self):
        return True

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

    def new_thread(self, new_globalenv):
        return ThreadContext(self, new_globalenv)


cdef class ThreadContext(Context):

    cdef Context parent_pyctx

    def __init__(self, Context parent_pyctx, new_globalenv):
        self.parent_pyctx = parent_pyctx
        self.module_path = parent_pyctx.module_path
        cduk.duk_push_global_stash(self.parent_pyctx.ctx)                   # [ ... stash ]
        cduk.duk_get_prop_string(self.parent_pyctx.ctx, -1, "_threads")     # [ ... stash _threads ]
        if new_globalenv:
            thr_idx = cduk.duk_push_thread_new_globalenv(parent_pyctx.ctx)  # [ ... stash _threads thread ]
            self.ctx = cduk.duk_get_context(parent_pyctx.ctx, thr_idx)
            self.setup()
        else:
            thr_idx = cduk.duk_push_thread(parent_pyctx.ctx)                # [ ... stash _threads thread ]
            self.ctx = cduk.duk_get_context(parent_pyctx.ctx, thr_idx)
            cduk.duk_push_thread_stash(self.ctx, self.ctx)
            cduk.duk_push_pointer(self.ctx, <void*>self)
            cduk.duk_put_prop_string(self.ctx, -2, "_pythr_pointer")
            cduk.duk_pop(self.ctx)
        # Store a reference to the thread so that it is reachable from a
        # garbage collection point of view
        cduk.duk_put_prop_string(self.parent_pyctx.ctx, -2, str(id(self)))  # [ ... stash _threads ]
        cduk.duk_pop_n(self.parent_pyctx.ctx, 2) # [ ... ]

    def __dealloc__(self):
        # Cython: When subclassing extension types, be aware that the
        # __dealloc__() method of the superclass will always be called, even if
        # it is overridden. This is in contrast to typical Python behavior
        # where superclass methods will not be executed unless they are
        # explicitly called by the subclass.
        #
        # We MUST prevent destroying the parent pyctx context heap by setting
        # self.ctx to NULL:
        #
        #   duk_destroy_heap: If ctx is NULL, the call is a no-op.
        #
        # Make the thread unreachable so that it can be garbage collected
        # (assuming there are no other references to it)
        cduk.duk_push_global_stash(self.parent_pyctx.ctx)                   # [ ... stash ]
        cduk.duk_get_prop_string(self.parent_pyctx.ctx, -1, "_threads")     # [ ... stash _threads ]
        cduk.duk_del_prop_string(self.parent_pyctx.ctx, -1, str(id(self)))
        cduk.duk_pop_n(self.parent_pyctx.ctx, 2)                            # [ ... ]
        self.ctx = NULL

    def suspend(self):
        state = ThreadState()
        cduk.duk_suspend(self.ctx, &state.ts)
        return state

    def resume(self, ThreadState state):
        cduk.duk_resume(self.ctx, &state.ts)


cdef class ThreadState(object):

    cdef cduk.duk_thread_state ts
