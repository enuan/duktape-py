#cython: language_level=3

cimport cduk
cimport cpython

import collections.abc
import datetime
import json
import os
import threading
import sys
import struct
import uuid
import weakref
from libc.stdio cimport printf

import pytz


cdef cduk.duk_int_t _ref_map_next_id = 1


class Error(Exception):
    pass


cdef force_unicode(b):
    return b.decode()


cdef smart_str(s):
    return unicode_encode_cesu8(s) if isinstance(s, str) else s


cdef unicode_encode_cesu8(ustring):
    # python transposition of duk_unicode_encode_cesu8(duk_ucodepoint_t cp, duk_uint8_t *out)
    out = bytearray()
    for uchar in ustring:
        x = ord(uchar)
        if x < 0x80:
            out.append(x)
        elif x < 0x800:
            out.extend([0xc0 + ((x >> 6) & 0x1f),
                        0x80 + (x & 0x3f)])
        elif x < 0x10000:
            out.extend([0xe0 + ((x >> 12) & 0x0f),
                        0x80 + ((x >> 6) & 0x3f),
                        0x80 + (x & 0x3f)])
        else:
            x -= 0x10000
            out.extend([0xed,
                        0xa0 + ((x >> 16) & 0x0f),
                        0x80 + ((x >> 10) & 0x3f),
                        0xed,
                        0xb0 + ((x >> 6) & 0x0f),
                        0x80 + (x & 0x3f)])
    return out


cdef DUK_HIDDEN_SYMBOL(symbol):
    return b'\xFF' + symbol


cdef duk_get_global_dotted_string(Context pyctx, key):
    parts = key.split(b'.')
    if not cduk.duk_get_global_string(pyctx.ctx, parts[0]):
        cduk.duk_pop(pyctx.ctx)
        return False
    for part in parts[1:]:
        if not cduk.duk_get_prop_string(pyctx.ctx, -1, part):
            cduk.duk_pop_n(pyctx.ctx, 2)
            return False
        cduk.duk_remove(pyctx.ctx, -2)
    return True


cdef duk_context_dump(cduk.duk_context *ctx):
    cduk.duk_push_context_dump(ctx)
    dump = force_unicode(cduk.duk_to_string(ctx, -1))
    cduk.duk_pop(ctx)
    cduk.duk_push_pointer(ctx, <void*>ctx)
    addr = force_unicode(cduk.duk_to_string(ctx, -1))
    cduk.duk_pop(ctx)
    return '(%s) %s' % (addr, dump)


cdef duk_reraise(Context pyctx, cduk.duk_int_t rc):
    if rc:
        exc = to_python(pyctx, -1)
        stacktrace = force_unicode(cduk.duk_safe_to_stacktrace(pyctx.ctx, -1))
        cduk.duk_pop(pyctx.ctx)
        if not isinstance(exc, Exception):
            exc = Error(stacktrace)
        raise exc


cdef cduk.duk_ret_t duk_resolve_module(cduk.duk_context *ctx):
    #
    # [0]: module_id
    # [1]: parent_id
    #
    module_id = force_unicode(cduk.duk_require_string(ctx, 0))
    parent_id = force_unicode(cduk.duk_require_string(ctx, 1))

    # node.js reference:
    #
    # https://nodejs.org/api/esm.html
    # https://nodejs.org/api/modules.html#modules_all_together
    #
    if module_id.startswith('./') or module_id.startswith('../'):
        if not parent_id:
            cduk.duk_push_global_stash(ctx)
            # if parent_id is not set BUT we are loading a file using
            # Context.load we set it as parent_id, this allows correctly
            # resolving any relative import for that file
            if cduk.duk_get_prop_string(ctx, -1, b'__duktape_loading_file__'):
                parent_id = force_unicode(cduk.duk_require_string(ctx, -1))
            cduk.duk_pop_n(ctx, 2)
        module_id_path = os.path.join(os.path.dirname(parent_id), module_id)
        module_file = load_as_file(module_id_path) or load_as_dir(module_id_path)
    else:
        pyctx = duk_get_pyctx(ctx)
        for module_path in pyctx.module_paths:
            module_id_path = os.path.join(module_path, module_id)
            module_file = load_as_file(module_id_path) or load_as_dir(module_id_path)
            if module_file:
                break
        else:
            module_file = None

    if module_file and os.path.isfile(module_file):
        cduk.duk_push_string(ctx, smart_str(os.path.normpath(module_file)))
    else:
        cduk.duk_generic_error(ctx, smart_str("Cannot find module '%s'" % module_id))

    return 1


cdef load_as_file(x):
    for item in [x,
                 x + '.js',
                 x + '.json']:
        if os.path.isfile(item):
            return item


cdef load_index(x):
    for item in [os.path.join(x, 'index.js'),
                 os.path.join(x, 'index.json')]:
        if os.path.isfile(item):
            return item


cdef load_as_dir(x):
    pkg_json_path = os.path.join(x, 'package.json')
    if os.path.isfile(pkg_json_path):
        with open(pkg_json_path) as pkg_json_file:
            pkg_json = json.load(pkg_json_file)
            pkg_main = pkg_json.get('main')
            if pkg_main:
                m = os.path.join(x, pkg_main)
                return load_as_file(m) or load_index(m)
    return load_index(x)


cdef cduk.duk_ret_t duk_load_module(cduk.duk_context *ctx):
    #
    # [0]: resolved_id
    # [1]: exports
    # [2]: module
    #
    resolved_id = force_unicode(cduk.duk_require_string(ctx, 0))
    if resolved_id.endswith('.json'):
        # treat a JSON file as an object
        cduk.duk_push_string(ctx, b"module.exports = ")
        cduk.fileio_push_file_string(ctx, smart_str(resolved_id))
        cduk.duk_concat(ctx, 2)
    else:
        pyctx = duk_get_pyctx(ctx)
        if pyctx.force_strict:
            # force strict mode for loaded modules
            cduk.duk_push_string(ctx, b"'use strict';")
            cduk.fileio_push_file_string(ctx, smart_str(resolved_id))
            cduk.duk_concat(ctx, 2)
        else:
            cduk.fileio_push_file_string(ctx, smart_str(resolved_id))
    return 1


class PyFunc:

    def __init__(self, func, nargs=None):
        self.func = func
        self.nargs = nargs


cdef to_python_string(Context pyctx, cduk.duk_idx_t idx):
    return force_unicode(to_python_bytes(pyctx, idx))


cdef to_python_bytes(Context pyctx, cduk.duk_idx_t idx):
    cdef cduk.duk_context *ctx = pyctx.ctx
    cdef cduk.duk_size_t strlen
    cdef const char *buf = cduk.duk_get_lstring(ctx, idx, &strlen)
    return buf[:strlen]


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
    while cduk.duk_next(ctx, -1, 1):
        ret[to_python(pyctx, -2)] = to_python(pyctx, -1)
        cduk.duk_pop_n(ctx, 2)
    cduk.duk_pop_n(ctx, 1)
    return ret


cdef to_python_proxy(Context pyctx, cduk.duk_idx_t idx, pojo_only=True):
    global _ref_map_next_id

    cdef cduk.duk_context *ctx = pyctx.ctx
    cdef cduk.duk_int_t _ref_id = _ref_map_next_id
    _ref_map_next_id += 1

    norm_idx = cduk.duk_normalize_index(ctx, idx)

    cduk.duk_push_global_stash(ctx)  # [ ... stash ]
    cduk.duk_get_prop_string(ctx, -1, b"_ref_map")  # [ ... stash _ref_map ]
    cduk.duk_push_int(ctx, _ref_id)  # [ ... stash _ref_map id ]
    cduk.duk_dup(ctx, norm_idx)  # [ ... stash _ref_map id func ]
    cduk.duk_put_prop(ctx, -3)  # [ ... stash _ref_map ]
    cduk.duk_pop_n(ctx, 2)

    if cduk.duk_is_function(ctx, idx):
        return JsFunc(pyctx, _ref_id)
    elif cduk.duk_is_array(ctx, idx):
        return JsArray(pyctx, _ref_id)
    elif duk_is_plain_object(pyctx, idx) or \
            (not pojo_only and cduk.duk_is_object(pyctx.ctx, idx)):
        return JsObject(pyctx, _ref_id)

    raise TypeError("not proxable")


cdef duk_is_plain_object(Context pyctx, cduk.duk_idx_t idx):
    # https://masteringjs.io/tutorials/fundamentals/pojo
    if not cduk.duk_is_object(pyctx.ctx, idx):
        return False

    cduk.duk_get_prototype(pyctx.ctx, idx)
    if cduk.duk_is_undefined(pyctx.ctx, -1):
        # check if the object has no prototype
        # (its a "bare object" Object.create(null))
        cduk.duk_pop(pyctx.ctx)
        return True

    assert duk_get_global_dotted_string(pyctx, b'Object.prototype')
    eq = cduk.duk_strict_equals(pyctx.ctx, -1, -2)
    cduk.duk_pop_n(pyctx.ctx, 2)
    return bool(eq)


def push_and_pop_proxy(f):
    def wrapper(JsProxy self, *args, **kwargs):
        try:
            self.push_proxy_ref()
            return f(self, *args, **kwargs)
        finally:
            self.pop_proxy_ref()
    return wrapper


cdef class JsProxy:

    cdef Context pyctx
    cdef cduk.duk_int_t _ref_id

    def __init__(self, Context pyctx, ref_id):
        self.pyctx = pyctx
        self._ref_id = ref_id

    cdef push_proxy_ref(self):
        cduk.duk_push_global_stash(self.pyctx.ctx)  # -> [ ... stash ]
        cduk.duk_get_prop_string(self.pyctx.ctx, -1, b"_ref_map")  # -> [ ... stash _ref_map ]
        cduk.duk_push_int(self.pyctx.ctx, self._ref_id)  # -> [ ... stash _ref_map _ref_id ]
        cduk.duk_get_prop(self.pyctx.ctx, -2)  # -> [ ... stash _ref_map obj ]
        cduk.duk_remove(self.pyctx.ctx, -2) # -> [ ... stash obj ]
        cduk.duk_remove(self.pyctx.ctx, -2) # -> [ ... obj ]

    cdef pop_proxy_ref(self):
        cduk.duk_pop(self.pyctx.ctx)

    @push_and_pop_proxy
    def to_python(self):
        return cduk.duk_json_encode(self.pyctx.ctx, -1).decode()


class JsObject(object):

    def __init__(self, pyctx, ref_id):
        self.__dict__['_proxy'] = ObjectProxy(pyctx, ref_id)

    def __str__(self):
        return 'JsObject(%s)' % self._proxy.to_python()
    __repr__ = __str__

    def __dir__(self):
        return list(self._proxy.keys())

    def __getattr__(self, k):
        return self._proxy.getitem(k)
    __getitem__ = __getattr__

    def __setattr__(self, k, v):
        self._proxy.setitem(k, v)
    __setitem__ = __setattr__

    def __delattr__(self, k):
        self._proxy.delitem(k)
    __delitem__ = __delattr__

    def _asdict(self):
        return JsDict(self._proxy)


class JsDict(collections.abc.MutableMapping):

    def __init__(self, proxy):
        self._proxy = proxy

    def __str__(self):
        return 'JsDict(%s)' % self._proxy.to_python()
    __repr__ = __str__

    def __getitem__(self, k):
        return self._proxy.getitem(k)

    def __setitem__(self, k, v):
        self._proxy.setitem(k, v)

    def __delitem__(self, k):
        self._proxy.delitem(k)

    def __iter__(self):
        return self._proxy.keys()

    def __len__(self):
        return self._proxy.length()


cdef class ObjectProxy(JsProxy):

    @push_and_pop_proxy
    def getitem(self, key):
        cduk.duk_get_prop_string(self.pyctx.ctx, -1, smart_str(key))
        try:
            return to_python_proxy(self.pyctx, -1)
        except TypeError:
            return to_python(self.pyctx, -1)
        finally:
            cduk.duk_pop(self.pyctx.ctx)

    @push_and_pop_proxy
    def setitem(self, key, value):
        to_js(self.pyctx, value)
        cduk.duk_put_prop_string(self.pyctx.ctx, -2, smart_str(key))

    @push_and_pop_proxy
    def delitem(self, key):
        cduk.duk_del_prop_string(self.pyctx.ctx, -1, smart_str(key))

    def keys(self):
        self.push_proxy_ref()
        cduk.duk_enum(self.pyctx.ctx, -1, cduk.DUK_ENUM_OWN_PROPERTIES_ONLY)
        while cduk.duk_next(self.pyctx.ctx, -1, 0):
            yield to_python(self.pyctx, -1)
            cduk.duk_pop(self.pyctx.ctx)
        cduk.duk_pop(self.pyctx.ctx)
        self.pop_proxy_ref()

    def length(self):
        return sum(1 for x in self.keys())


class JsArray(collections.abc.MutableSequence):

    def __init__(self, pyctx, ref_id):
        self._proxy = ArrayProxy(pyctx, ref_id)

    def __str__(self):
        return 'JsArray(%s)' % self._proxy.to_python()
    __repr__ = __str__

    def __getitem__(self, i):
        return self._proxy.get(i)

    def __setitem__(self, i, v):
        self._proxy.put(i, v)

    def __delitem__(self, i):
        self._proxy.delete(i)

    def __len__(self):
        return self._proxy.length()

    def insert(self, i, v):
        self._proxy.insert(i, v)


cdef class ArrayProxy(JsProxy):

    @push_and_pop_proxy
    def get(self, index):
        if isinstance(index, slice):
            length = self.length()
            return [self.get(i) for i in
                    xrange(index.start if index.start else 0,
                           min(index.stop if index.stop else length, length),
                           index.step if index.step else 1)]
        try:
            if index < 0:
                index = self.length() + index
            if cduk.duk_get_prop_index(self.pyctx.ctx, -1, index):
                try:
                    return to_python_proxy(self.pyctx, -1)
                except TypeError, e:
                    return to_python(self.pyctx, -1)
            else:
                raise IndexError('index out of range')
        finally:
            cduk.duk_pop(self.pyctx.ctx)

    @push_and_pop_proxy
    def put(self, index, item):
        if index >= self.length():
            raise IndexError('index out of range')
        to_js(self.pyctx, item)
        if not cduk.duk_put_prop_index(self.pyctx.ctx, -2, index):
            raise IndexError('index out of range')

    @push_and_pop_proxy
    def delete(self, index):
        if index >= self.length():
            raise IndexError('index out of range')
        cduk.duk_push_string(self.pyctx.ctx, "splice")
        cduk.duk_push_number(self.pyctx.ctx, index)
        cduk.duk_push_number(self.pyctx.ctx, 1)
        cduk.duk_pcall_prop(self.pyctx.ctx, -4, 2)
        cduk.duk_pop(self.pyctx.ctx)

    @push_and_pop_proxy
    def length(self):
        cduk.duk_get_prop_string(self.pyctx.ctx, -1, "length")
        ret = to_python(self.pyctx, -1)
        cduk.duk_pop(self.pyctx.ctx)
        return ret

    @push_and_pop_proxy
    def insert(self, index, item):
        cduk.duk_push_string(self.pyctx.ctx, "splice")
        cduk.duk_push_number(self.pyctx.ctx, index)
        cduk.duk_push_number(self.pyctx.ctx, 0)
        to_js(self.pyctx, item)
        cduk.duk_pcall_prop(self.pyctx.ctx, -5, 3)
        cduk.duk_pop(self.pyctx.ctx)


cdef class JsFunc(JsProxy):

    def __call__(self, *args):
        self.push_proxy_ref()
        for arg in args:
            to_js(self.pyctx, arg)
        duk_reraise(self.pyctx, cduk.duk_pcall(self.pyctx.ctx, len(args)))
        try:
            return to_python(self.pyctx, -1)
        finally:
            self.pop_proxy_ref()


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
        return to_python_proxy(pyctx, idx)
    elif cduk.duk_is_object(ctx, idx):
        def instanceof(name):
            norm_idx = cduk.duk_normalize_index(ctx, idx)
            if not duk_get_global_dotted_string(pyctx, smart_str(name)):
                return False
            try:
                return bool(cduk.duk_instanceof(ctx, norm_idx, -1))
            finally:
                cduk.duk_pop(ctx)

        if instanceof(b"Date"):
            cduk.duk_get_prop_string(pyctx.ctx, -1, DUK_HIDDEN_SYMBOL(b'epoch_usec'))
            if not cduk.duk_is_undefined(ctx, -1):
                epoch_s = struct.unpack('q', to_python_bytes(pyctx, -1))[0] / 1e6
                cduk.duk_pop(ctx)
            else:
                cduk.duk_pop(ctx)
                cduk.duk_push_string(ctx, b"getTime")
                cduk.duk_pcall_prop(ctx, -2, 0)
                epoch_s = cduk.duk_get_number(ctx, idx) / 1e3
                cduk.duk_pop(ctx)
            return datetime.datetime.utcfromtimestamp(epoch_s)
        else:
            dct = to_python_dict(pyctx, idx)
            if pyctx.to_py_hook:
                to_py_hook_result = pyctx.to_py_hook(dct, instanceof)
                if to_py_hook_result:
                    return to_py_hook_result
            return dct

    return 'unknown'
    # raise TypeError("not_coercible", cduk.duk_get_type(ctx, idx))


cdef duk_get_pyctx(cduk.duk_context *ctx):
    cduk.duk_push_thread_stash(ctx, ctx)
    cduk.duk_get_prop_string(ctx, -1, b"_pythr_pointer")
    if cduk.duk_is_undefined(ctx, -1):
        cduk.duk_pop_n(ctx, 2)
        cduk.duk_push_global_stash(ctx)
        cduk.duk_get_prop_string(ctx, -1, b"_pyctx_pointer")
        pyctx = <Context>cduk.duk_get_pointer(ctx, -1)
    else:
        pyctx = <ThreadContext>cduk.duk_get_pointer(ctx, -1)
    cduk.duk_pop_n(ctx, 2)
    return pyctx


cdef cduk.duk_ret_t js_func_wrapper(cduk.duk_context *ctx):
    # [ args... ]
    cdef cduk.duk_int_t nargs

    pyctx = duk_get_pyctx(ctx)
    nargs = cduk.duk_get_top(ctx)
    cduk.duk_push_current_function(ctx)

    if cduk.duk_has_prop_string(ctx, -1, b"__duktape_cfunc_nargs__"):
        cduk.duk_get_prop_string(ctx, -1, b"__duktape_cfunc_nargs__")
        nargs = cduk.duk_require_int(ctx, -1)
        cduk.duk_pop(ctx)

    cduk.duk_get_prop_string(ctx, -1, b"__duktape_cfunc_pointer__")
    func = <object>cduk.duk_get_pointer(ctx, -1)
    cduk.duk_pop(ctx)

    cduk.duk_pop(ctx)

    args = [to_python(pyctx, idx) for idx in range(nargs)]
    try:
        to_js(pyctx, func(*args))
    except Exception, e:
        try:
            to_js(pyctx, e)
        except TypeError, e:
            cduk.duk_generic_error(ctx, smart_str(str(e)))
        cduk.duk_throw(ctx)
    return 1


cdef cduk.duk_ret_t js_func_finalizer(cduk.duk_context *ctx):
    cduk.duk_get_prop_string(ctx, 0, b"__duktape_cfunc_pointer__")
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
    cduk.duk_put_prop_string(ctx, -2, b"__duktape_cfunc_pointer__")  # [ ... js_func_wrapper ]
    if nargs is not None:
        cduk.duk_push_number(ctx, nargs)  # [ ... js_func_wrapper nargs ]
        cduk.duk_put_prop_string(ctx, -2, b"__duktape_cfunc_nargs__")   # [ ... js_func_wrapper ]


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
USECS_IN_SEC = int(1e6)
USECS_IN_DAY = 24 * 60 * 60 * USECS_IN_SEC


cdef to_epoch_usec(dt):
    assert dt.tzinfo is None
    delta = dt - UNIX_EPOCH
    return delta.days    * USECS_IN_DAY + \
           delta.seconds * USECS_IN_SEC + \
           delta.microseconds


cdef to_js_date(Context pyctx, value):
    cdef cduk.duk_context *ctx = pyctx.ctx
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
    epoch_usec = to_epoch_usec(value)
    cduk.duk_get_global_string(ctx, b"Date")                            # [ ... Date ]
    cduk.duk_push_number(ctx, epoch_usec/1e3)                           # [ ... Date epoch_s ]
    duk_reraise(pyctx, cduk.duk_pnew(ctx, 1))                           # [ ... date ]
    cduk.duk_push_lstring(ctx, <bytes>struct.pack('q', epoch_usec), 8)  # [ ... date usec]
    cduk.duk_put_prop_string(ctx, -2, DUK_HIDDEN_SYMBOL(b'epoch_usec')) # [ ... date ]
    cduk.duk_push_object(ctx)                                           # [ ... date handler ]
    cduk.duk_push_c_function(ctx, js_date_proxy_get_handler, 3)         # [ ... date handler get_handler ]
    cduk.duk_put_prop_string(ctx, -2, "get")                            # [ ... date handler ]
    cduk.duk_push_proxy(ctx, 0)                                         # [ ... proxy ]


cdef cduk.duk_ret_t js_date_proxy_get_handler(cduk.duk_context *ctx):
    # 'this' binding: handler
    #
    # [0]: target
    # [1]: prop
    # [2]: receiver
    #

    if cduk.duk_has_prop_string(ctx, -1, DUK_HIDDEN_SYMBOL(b'epoch_usec')) and \
            not cduk.duk_is_symbol(ctx, 1) and cduk.duk_get_string(ctx, 1).startswith(b'set'):
        cduk.duk_push_c_function(ctx, js_date_proxy_set_wrapper,
                                 cduk.DUK_VARARGS)
        cduk.duk_dup(ctx, 0)
        cduk.duk_put_prop_string(ctx, -2, DUK_HIDDEN_SYMBOL(b"date_target"))
        cduk.duk_dup(ctx, 1)
        cduk.duk_put_prop_string(ctx, -2, DUK_HIDDEN_SYMBOL(b"date_prop"))
    else:
        cduk.duk_pop(ctx)
        cduk.duk_get_prop(ctx, 0)
        if cduk.duk_is_function(ctx, -1):
            cduk.duk_push_string(ctx, b"bind")
            cduk.duk_dup(ctx, 0)
            cduk.duk_pcall_prop(ctx, -3, 1)

    return 1


cdef cduk.duk_ret_t js_date_proxy_set_wrapper(cduk.duk_context *ctx):
    # [ args... ]

    cdef cduk.duk_int_t nargs

    nargs = cduk.duk_get_top(ctx)
    cduk.duk_push_current_function(ctx)
    cduk.duk_get_prop_string(ctx, -1, DUK_HIDDEN_SYMBOL(b"date_target"))
    cduk.duk_get_prop_string(ctx, -2, DUK_HIDDEN_SYMBOL(b"date_prop"))
    cduk.duk_insert(ctx, 0)
    cduk.duk_insert(ctx, 0)
    cduk.duk_pop(ctx)
    cduk.duk_pcall_prop(ctx, 0, nargs)
    cduk.duk_del_prop_string(ctx, 0, DUK_HIDDEN_SYMBOL(b'epoch_usec'))

    return 1


cdef to_js(Context pyctx, value):
    cdef cduk.duk_context *ctx = pyctx.ctx

    if value is None:
        cduk.duk_push_null(ctx)
        return
    elif isinstance(value, str):
        cduk.duk_push_string(ctx, smart_str(value))
        return
    elif isinstance(value, bool):
        if value:
            cduk.duk_push_true(ctx)
        else:
            cduk.duk_push_false(ctx)
        return
    elif isinstance(value, int):
        cduk.duk_push_int(ctx, value)
        return
    elif isinstance(value, float):
        cduk.duk_push_number(ctx, value)
        return
    elif isinstance(value, (list, tuple)):
        to_js_array(pyctx, value)
        return
    elif isinstance(value, dict):
        to_js_dict(pyctx, value)
        return
    elif isinstance(value, (datetime.datetime,
                            datetime.date,
                            datetime.time)):
        to_js_date(pyctx, value)
        return
    elif isinstance(value, JsNew):
        value(pyctx)
        return
    elif callable(value):
        to_js_func(pyctx, PyFunc(value))
        return
    elif isinstance(value, PyFunc):
        to_js_func(pyctx, value)
        return
    elif pyctx.to_js_hook:
        to_js_hook_result = pyctx.to_js_hook(value, JsNew)
        if to_js_hook_result:
            to_js(pyctx, to_js_hook_result)
            return

    raise TypeError("to_js failed for %s" % value.__class__.__name__)


class JsNew:

    def __init__(self, name, *args):
        self.name = name
        self.args = args

    def __call__(self, Context pyctx):
        if not duk_get_global_dotted_string(pyctx, smart_str(self.name)):
            raise ValueError("'%s' is undefined" % self.name)
        for arg in self.args:
            to_js(pyctx, arg)
        duk_reraise(pyctx, cduk.duk_pnew(pyctx.ctx, len(self.args)))


cdef cduk.duk_ret_t thread_only_constructor(cduk.duk_context *ctx):
    if not cduk.duk_is_constructor_call(ctx):
        return cduk.DUK_RET_TYPE_ERROR

    cduk.duk_dup(ctx, 0)
    if cduk.duk_pnew(ctx, 0):
        # silenty ignore error and push an empty object as target
        cduk.duk_pop(ctx)
        cduk.duk_push_object(ctx)
    cduk.duk_dup(ctx, 0)
    cduk.duk_put_prop_string(ctx, -2, DUK_HIDDEN_SYMBOL(b'type'))
    cduk.duk_get_prop_string(ctx, 0, b'name')
    cduk.duk_put_prop_string(ctx, -2, DUK_HIDDEN_SYMBOL(b'name'))
    cduk.duk_push_string(ctx, smart_str(str(uuid.uuid4())))
    cduk.duk_put_prop_string(ctx, -2, DUK_HIDDEN_SYMBOL(b'id'))
    cduk.duk_push_object(ctx)  # [ ... target handler ]
    cduk.duk_push_c_function(ctx, thread_only_get_handler, 3)
    cduk.duk_put_prop_string(ctx, -2, "get")
    cduk.duk_push_c_function(ctx, thread_only_set_handler, 4)
    cduk.duk_put_prop_string(ctx, -2, "set")
    cduk.duk_push_proxy(ctx, 0)  # [ ... target handler ] -> [ ... proxy ]

    # Return the 'result' object: replaces the default instance.
    return 1;


cdef cduk.duk_ret_t thread_only_get_handler(cduk.duk_context *ctx):
    # 'this' binding: handler
    # [0]: target
    # [1]: prop
    # [2]: receiver (proxy)
    #
    cduk.duk_push_thread_stash(ctx, ctx)
    cduk.duk_get_prop_string(ctx, 0, DUK_HIDDEN_SYMBOL(b'id'))
    cduk.duk_get_prop(ctx, -2)
    if cduk.duk_is_undefined(ctx, -1):
        cduk.duk_pop(ctx)
        cduk.duk_generic_error(ctx, smart_str("ThreadOnly has not been initialized!"))
        return 1

    local_idx = cduk.duk_normalize_index(ctx, -1)
    cduk.duk_dup(ctx, 1)
    cduk.duk_get_prop(ctx, local_idx)
    if cduk.duk_is_function(ctx, -1):
        cduk.duk_push_string(ctx, "bind")
        cduk.duk_dup(ctx, local_idx)
        cduk.duk_pcall_prop(ctx, -3, 1)

    return 1


cdef cduk.duk_ret_t thread_only_set_handler(cduk.duk_context *ctx):
    # 'this' binding: handler
    # [0]: target
    # [1]: prop
    # [2]: val
    # [3]: receiver (proxy)
    #

    cduk.duk_push_thread_stash(ctx, ctx)
    cduk.duk_get_prop_string(ctx, 0, DUK_HIDDEN_SYMBOL(b'id'))
    cduk.duk_get_prop(ctx, -2)
    if cduk.duk_is_undefined(ctx, -1):
        cduk.duk_pop(ctx)
        cduk.duk_generic_error(ctx, smart_str("ThreadOnly has not been initialized!"))
        return 1

    cduk.duk_dup(ctx, 1)
    cduk.duk_dup(ctx, 2)
    cduk.duk_put_prop(ctx, -3)

    return 1


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
    cdef object to_js_hook
    cdef object to_py_hook
    cdef object force_strict

    def __init__(self, module_path=None, to_js_hook=None, to_py_hook=None, force_strict=False):
        self.ctx = cduk.duk_create_heap_default()
        self.module_path = module_path
        self.to_js_hook = to_js_hook
        self.to_py_hook = to_py_hook
        self.force_strict = force_strict
        self.setup()

    @property
    def force_strict(self):
        return self.force_strict

    @property
    def module_paths(self):
        if isinstance(self.module_path, list):
            return self.module_path
        else:
            return [self.module_path]

    def __dealloc__(self):
        if self.ctx:
            cduk.duk_destroy_heap(self.ctx)
            self.ctx = NULL

    def setup(self):
        cduk.duk_push_global_stash(self.ctx)
        cduk.duk_push_pointer(self.ctx, <void*>self)
        cduk.duk_put_prop_string(self.ctx, -2, b"_pyctx_pointer")
        cduk.duk_push_object(self.ctx)
        cduk.duk_put_prop_string(self.ctx, -2, b"_ref_map")
        cduk.duk_push_object(self.ctx)
        cduk.duk_put_prop_string(self.ctx, -2, b"_threads")
        cduk.duk_pop(self.ctx)

        if self.module_path:
            cduk.duk_push_object(self.ctx);
            cduk.duk_push_c_function(self.ctx, duk_resolve_module, cduk.DUK_VARARGS);
            cduk.duk_put_prop_string(self.ctx, -2, b"resolve");
            cduk.duk_push_c_function(self.ctx, duk_load_module, cduk.DUK_VARARGS);
            cduk.duk_put_prop_string(self.ctx, -2, b"load");
            cduk.duk_module_node_init(self.ctx)

        # ThreadOnly constructor
        cduk.duk_push_c_function(self.ctx, thread_only_constructor, 1)
        cduk.duk_push_object(self.ctx)
        cduk.duk_put_prop_string(self.ctx, -2, "prototype")
        cduk.duk_put_global_string(self.ctx, "ThreadOnly")

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
        cduk.duk_push_global_stash(self.ctx)
        cduk.duk_push_string(self.ctx, smart_str(filename))
        # used by duk_resolve_module
        cduk.duk_put_prop_string(self.ctx, -2, b"__duktape_loading_file__")
        cduk.duk_pop(self.ctx)
        try:
            cduk.fileio_push_file_string(self.ctx, smart_str(filename)) # [ ... source ]
            cduk.duk_push_string(self.ctx, smart_str(filename)) # [ ... source filename ]
            compile_flags = 0
            if self.force_strict:
                compile_flags |= cduk.DUK_COMPILE_STRICT
            duk_reraise(self, cduk.duk_pcompile(self.ctx, compile_flags)) # [ ... func ]
            # bind 'this' to global object
            cduk.duk_push_global_object(self.ctx)  # [ ... func global ]
            duk_reraise(self, cduk.duk_pcall_method(self.ctx, 0)) # [ ... retval ]
            cduk.duk_pop(self.ctx)
        finally:
            cduk.duk_push_global_stash(self.ctx)
            cduk.duk_del_prop_string(self.ctx, -1, b"__duktape_loading_file__")
            cduk.duk_pop(self.ctx)


    def eval(self, js):
        # Eval code: compiles into a function with zero arguments, which
        # executes like an ECMAScript eval call
        cduk.duk_push_string(self.ctx, smart_str(js))       # [ ... source ]
        cduk.duk_push_string(self.ctx, b"eval")             # [ ... source eval ]
        compile_flags = cduk.DUK_COMPILE_EVAL
        if self.force_strict:
            compile_flags |= cduk.DUK_COMPILE_STRICT
        duk_reraise(self, cduk.duk_pcompile(self.ctx, compile_flags)) # [ ... func ]
        duk_reraise(self, cduk.duk_pcall(self.ctx, 0)) # [ ... retval ]
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
        if new_globalenv:
            thr_idx = cduk.duk_push_thread_new_globalenv(self.ctx)
        else:
            thr_idx = cduk.duk_push_thread(self.ctx)
        thr = ThreadContext(self, thr_idx, new_globalenv)
        thr_id = str(id(thr))

        # Store a reference to the thread so that it is reachable from a
        # garbage collection point of view
        cduk.duk_push_global_stash(self.ctx)                            # [ ... thr stash ]
        cduk.duk_get_prop_string(self.ctx, -1, b"_threads")             # [ ... thr stash _threads ]
        cduk.duk_dup(self.ctx, thr_idx)                                 # [ ... thr stash _threads thr ]
        cduk.duk_put_prop_string(self.ctx, -2, smart_str(thr_id))       # [ ... thr stash _threads ]
        cduk.duk_pop_n(self.ctx, 3)                                     # [ ... ]

        def finalize_thread(thr_id):
            # Make the thread unreachable so that it can be garbage collected
            # (assuming there are no other references to it)
            cduk.duk_push_global_stash(self.ctx)                        # [ ... stash ]
            cduk.duk_get_prop_string(self.ctx, -1, b"_threads")         # [ ... stash _threads ]
            cduk.duk_del_prop_string(self.ctx, -1, smart_str(thr_id))
            cduk.duk_pop_n(self.ctx, 2)                                 # [ ... ]
        weakref.finalize(thr, finalize_thread, thr_id)

        return thr

    def proxy(self, key):
        if not duk_get_global_dotted_string(self, smart_str(key)):
            # XXX raise Error?
            return
        try:
            return to_python_proxy(self, -1, pojo_only=False)
        finally:
            cduk.duk_pop(self.ctx)


cdef class ThreadContext(Context):

    cdef Context parent_pyctx
    cdef object __weakref__

    def __init__(self, Context parent_pyctx, thr_idx, new_globalenv):
        self.parent_pyctx = parent_pyctx
        self.module_path = parent_pyctx.module_path
        self.to_js_hook = parent_pyctx.to_js_hook
        self.to_py_hook = parent_pyctx.to_py_hook
        self.force_strict = parent_pyctx.force_strict
        if new_globalenv:
            self.ctx = cduk.duk_get_context(parent_pyctx.ctx, thr_idx)
            self.setup()
        else:
            self.ctx = cduk.duk_get_context(parent_pyctx.ctx, thr_idx)
            cduk.duk_push_thread_stash(self.ctx, self.ctx)
            cduk.duk_push_pointer(self.ctx, <void*>self)
            cduk.duk_put_prop_string(self.ctx, -2, b"_pythr_pointer")
            cduk.duk_pop(self.ctx)

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
        self.ctx = NULL

    def suspend(self):
        state = ThreadState()
        cduk.duk_suspend(self.ctx, &state.ts)
        return state

    def resume(self, ThreadState state):
        cduk.duk_resume(self.ctx, &state.ts)

    def init_thread_only(self, key, *args):
        duk_get_global_dotted_string(self, smart_str(key))
        cduk.duk_push_thread_stash(self.ctx, self.ctx)
        cduk.duk_get_prop_string(self.ctx, -2, DUK_HIDDEN_SYMBOL(b'id'))
        cduk.duk_get_prop_string(self.ctx, 0, DUK_HIDDEN_SYMBOL(b'type'))
        for arg in args:
            to_js(self, arg)
        duk_reraise(self, cduk.duk_pnew(self.ctx, len(args)))
        cduk.duk_put_prop(self.ctx, -3)


cdef class ThreadState(object):

    cdef cduk.duk_thread_state ts
