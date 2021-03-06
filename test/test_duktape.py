import os
import datetime
import gc
import random
import tempfile
import threading
import time
import sys

import duktape
import pytest
import pytz

# todo: unicode tests everywhere and strings with nulls (i.e. I'm relying on null termination)

TEST_DIR = os.path.abspath(os.path.dirname(__file__))


def test_create():
    duktape.Context()


def test_eval_file():
    ctx = duktape.Context()
    with tempfile.NamedTemporaryFile() as tf:
        tf.write(b"var a = {a: 1, b: 2};")
        tf.flush()
        ctx.load(tf.name)


def test_stacklen_evalstring():
    "test stacklen and evalstring"
    ctx = duktape.Context()
    assert len(ctx) == 0
    ctx.eval("var a = '123';")
    assert len(ctx) == 1


def test_error_handling():
    ctx = duktape.Context()
    with pytest.raises(duktape.Error):
        ctx.eval("bad syntax bad bad bad")


def test_gc():
    ctx = duktape.Context()
    ctx._push("whatever")
    ctx.gc()


def test_push_gettype():
    "test _push and _type"
    ctx = duktape.Context()

    def push(x):
        ctx._push(x)
        return ctx._type()

    codes = list(map(push, [
        "123",
        123,
        123.,
        True,
        False,
        None,
        (1, 2, 3),
        [1, 2, 3],
        [[1]],
        {
            "a": 1,
            "b": "2",
        }
    ]))
    expected = [str, float, float, bool, bool, type(None), object, object, object, object]
    assert [code.as_pytype() for code in codes] == expected


def test_push_get():
    ctx = duktape.Context()
    for v in ["foo", "foo", 123.0, 123, 123.5, True, False, [1, 2, 3], [[1]], {"a": 1, "b": 2}]:
        ctx._push(v)
        assert v == ctx._get()


def test_push_pyfunc():
    def foo():
        return 'foo'
    def bar(x):
        return x

    ctx = duktape.Context()
    ctx['foo'] = duktape.PyFunc(foo, 0)
    ctx['bar'] = duktape.PyFunc(bar, 1)
    ctx.eval('var x = foo();')
    assert ctx['x'] == 'foo'
    ctx.eval('var y = bar("bar");')
    assert ctx['y'] == 'bar'


def test_push_plain_func():
    def foo():
        return 'foo'
    def bar(x):
        return x

    ctx = duktape.Context()
    ctx['foo'] = foo
    ctx['bar'] = bar
    ctx.eval('var x = foo();')
    assert ctx['x'] == 'foo'
    ctx.eval('var y = bar("bar");')
    assert ctx['y'] == 'bar'


def test_py_func_with_dict_arg_works():
    def foo(x):
        return x == {'foo': 1, 'bar': 2}

    ctx = duktape.Context()
    ctx['foo'] = foo
    assert ctx.eval('foo({"a": 1}) == false;')
    assert ctx.eval('foo({"foo": 1, "bar": 2}) == true;')


def test_load_file_with_syntax_error():
    ctx = duktape.Context()
    with tempfile.NamedTemporaryFile() as tf:
        tf.write(b"var a = 10;\n"
                 b"foo=")
        tf.flush()

        with pytest.raises(duktape.Error) as error:
            ctx.load(tf.name)
        err_repr = str(error.getrepr())
        # error contains filename and line number
        assert '%s:2' % tf.name in err_repr, err_repr


def test_load_file_using_this():
    ctx = duktape.Context()
    with tempfile.NamedTemporaryFile() as tf1:
        tf1.write(b"this.a = 10;");
        tf1.flush()
        ctx.load(tf1.name)
    with tempfile.NamedTemporaryFile() as tf2:
        tf2.write(b'this.b = this.a+10;');
        tf2.flush()
        ctx.load(tf2.name)

    assert ctx['a'] == 10
    assert ctx['b'] == 20


def test_load_file_using_strict():
    ctx = duktape.Context()
    with tempfile.NamedTemporaryFile() as tf1:
        tf1.write(b"var a = 10;");
        tf1.flush()
        ctx.load(tf1.name)
    with tempfile.NamedTemporaryFile() as tf2:
        tf2.write(b'"use strict"; var b = a+10;');
        tf2.flush()
        ctx.load(tf2.name)

    assert ctx['a'] == 10
    assert ctx['b'] == 20


def test_load_file_using_strict_and_this():
    ctx = duktape.Context()
    with tempfile.NamedTemporaryFile() as tf1:
        tf1.write(b"this.a = 10;");
        tf1.flush()
        ctx.load(tf1.name)
    with tempfile.NamedTemporaryFile() as tf2:
        tf2.write(b'"use strict"; this.b = this.a+10;');
        tf2.flush()
        ctx.load(tf2.name)

    assert ctx['a'] == 10
    assert ctx['b'] == 20


def test_module_loading():
    with tempfile.NamedTemporaryFile(suffix='.js') as tf:
        tf.write(b"module.exports = 'Hello world!'; ");
        tf.flush()
        ctx = duktape.Context(module_path=os.path.dirname(tf.name))
        ctx.eval('var msg = require("' + os.path.basename(tf.name) + '");')

    assert ctx['msg'] == 'Hello world!'


def test_node_module_loading():
    ctx = duktape.Context(module_path=os.path.join(TEST_DIR, 'node_modules'))

    ctx.eval('const a = require("a")')
    assert ctx['a']['foo'] == 'a'
    assert ctx['a']['fruit'] == 'Apple'

    ctx.eval('const b = require("b")')
    assert ctx['b']['foo'] == 'b'
    assert ctx['b']['fruit'] == 'Apple'

    ctx.eval('const c = require("c")')
    assert ctx['c']['foo'] == 'c'
    assert ctx['c']['fruit'] == 'Apple'


def test_required_inside_load():
    ctx = duktape.Context(module_path=os.path.join(TEST_DIR, 'node_modules'))

    with tempfile.NamedTemporaryFile(suffix='.js', dir=TEST_DIR) as tf:
        tf.write(b"const baz = require('./node_modules/b'); ");
        tf.flush()
        ctx.load(os.path.join(tf.name))

    assert ctx['baz']['foo'] == 'b'
    assert ctx['baz']['fruit'] == 'Apple'


def test_force_strict_true():
    ctx = duktape.Context(force_strict=True)

    ctx['x'] = 17
    assert ctx.eval('var x = 42; x;') == 42
    assert ctx['x'] == 17


    with pytest.raises(duktape.Error) as error:
         ctx.eval('var y; delete y;')
    err_repr = str(error.getrepr())
    assert "SyntaxError" in err_repr, err_repr
    assert "cannot delete identifier" in err_repr, err_repr

    with tempfile.NamedTemporaryFile(suffix='.js', dir=TEST_DIR) as tf:
        tf.write(b"""const foo = function(x) {
            bar = x;
        }""")
        tf.flush()

        ctx.load(os.path.join(tf.name))
        with pytest.raises(duktape.Error) as error:
            ctx.eval('foo(10)')
        err_repr = str(error.getrepr())
        assert "ReferenceError" in err_repr, err_repr
        assert "identifier 'bar' undefined" in err_repr, err_repr


def test_force_strict_false():
    ctx = duktape.Context(force_strict=False)

    ctx['x'] = 17
    assert ctx.eval('var x = 42; x;') == 42
    assert ctx['x'] == 42

    ctx.eval('var y; delete y;')

    with tempfile.NamedTemporaryFile(suffix='.js', dir=TEST_DIR) as tf:
        tf.write(b"""const foo = function(x) {
            bar = x;
        }""")
        tf.flush()

        ctx.load(os.path.join(tf.name))
        ctx.eval('foo(10)')
        assert ctx['bar'] == 10


def test_js_func_invocation_after_context_gc():
    ctx = duktape.Context()
    ctx.eval("function foo(x) { return x*2; }")
    foo = ctx['foo']
    del ctx
    gc.collect()

    assert foo(10) == 20


def test_cesu8_push_string():
    ctx = duktape.Context()
    ctx.eval("""
    function charCodeAt(str, idx) {
        return str.charCodeAt(idx);
    }
    function codePointAt(str, idx) {
        return str.codePointAt(idx);
    }""")

    assert ctx['charCodeAt']('\xe0', 0) == 224
    assert ctx['codePointAt']('\xe0', 0) == 224

    smile_emoji = '\U0001f600'
    assert ctx['charCodeAt'](smile_emoji, 0) == 55357
    assert ctx['charCodeAt'](smile_emoji, 1) == 56832
    assert ctx['codePointAt'](smile_emoji, 0) == 128512

    ctx['smile'] = smile_emoji
    assert ctx.eval('smile.charCodeAt(0)') == 55357
    assert ctx.eval('smile.charCodeAt(1)') == 56832
    assert ctx.eval('smile.codePointAt(0)') == 128512
    assert ctx['smile'] == smile_emoji

    assert ctx.eval("'\uD83D\uDE00'") == smile_emoji
    assert ctx.eval('String.fromCharCode(0x1f600)') == smile_emoji


def test_thread_basic():
    ctx = duktape.Context()
    ctx['foo'] = 10

    th = ctx.new_thread(False)
    assert th['foo'] == 10
    th['bar'] = 20
    assert th['bar'] == 20
    assert th.eval('foo + bar') == 30

    assert ctx['bar'] == 20


def test_thread_new_globalenv():
    ctx = duktape.Context()
    ctx['foo'] = 5

    th = ctx.new_thread(True)
    assert th['foo'] is None
    th['foo'] = 10
    assert th['foo'] == 10
    th['bar'] = 20
    assert th['bar'] == 20
    assert th.eval('foo + bar') == 30

    assert ctx['foo'] == 5
    assert ctx['bar'] is None


def test_thread_deallocation():
    # CPython implementation detail: It is possible for a reference cycle to
    # prevent the reference count of an object from going to zero. In this
    # case, the cycle will be later detected and deleted by the cyclic garbage
    # collector. A common cause of reference cycles is when an exception has
    # been caught in a local variable. The frame’s locals then reference the
    # exception, which references its own traceback, which references the
    # locals of all frames caught in the traceback.
    ctx = duktape.Context()
    th = ctx.new_thread(False)
    caught_err = None
    try:
        th.eval('foo')
    except duktape.Error as err:
        caught_err = err


def test_thread_garbage_collection():

    class Sum(object):
        collected = False
        def __call__(self, x, y): return x+y
        def __del__(self): Sum.collected = True

    ctx = duktape.Context()
    th = ctx.new_thread(True)
    th['sum'] = Sum()
    assert th.eval('sum(1,2)') == 3

    del th
    # force duktape garbage collection
    ctx.gc()
    assert Sum.collected is True


def test_thread_suspend_and_resume():
    ctx = duktape.Context()
    done_set = set()

    def worker(thctx, i):
        def sleep():
            # without suspend/resume this test fails with a fatal error:
            # *** longjmp causes uninitialized stack frame ***
            state = thctx.suspend()
            time.sleep(random.uniform(0, 1))
            thctx.resume(state)
        thctx['sleep'] = sleep
        def done(s):
            print(s)
            done_set.add(i)
        thctx['done'] = done

        # inspired by duktape/tests/api/test-suspend-resume.c
        # test_suspend_resume_reterr_basic
        thctx.eval("""
            sleep();
            try {
                throw 'worker %s executing';
            } catch (e) {
                done(e);
            }""" % i);

    workers = list()
    for i in range(1, 11):
        t = threading.Thread(target=worker, args=(ctx.new_thread(True), i))
        workers.append(t)
        t.start()
    for t in workers:
        t.join()

    assert done_set == set(range(1, 11))


def test_push_datetime():
    ctx = duktape.Context()

    ctx['dt'] = datetime.datetime(2019, 11, 19, 20, 30, 15, 123456)
    ctx.eval('dt.toISOString()') == '2019-11-19T20:30:15.123Z'
    assert ctx['dt'] == datetime.datetime(2019, 11, 19, 20, 30, 15, 123456)

    ctx.eval('dt.setDate(10)') == '2019-11-19T20:30:15.123Z'
    ctx.eval('dt.toISOString()') == '2019-11-10T20:30:15.123Z'
    # once modified a date will loose (on the py side) the microsecond resolution
    assert ctx['dt'] == datetime.datetime(2019, 11, 10, 20, 30, 15, 123000)

    ctx['d'] = datetime.date(2019, 11, 19)
    assert ctx.eval('d.toISOString()') == '2019-11-19T00:00:00.000Z'
    assert ctx['d'] == datetime.date(2019, 11, 19)
    ctx.eval('d.setTime(d.getTime())')
    assert ctx.eval('d.toISOString()') == '2019-11-19T00:00:00.000Z'
    # once modified a date will come back as a datetime
    assert ctx['d'] == datetime.datetime(2019, 11, 19)

    ctx['t'] = datetime.time(20, 30, 15, 123456)
    assert ctx.eval('t.toISOString()') == '1970-01-01T20:30:15.123Z'
    assert ctx['t'] == datetime.time(20, 30, 15, 123456)
    ctx.eval('t.setTime(t.getTime())')
    assert ctx.eval('t.toISOString()') == '1970-01-01T20:30:15.123Z'
    # once modified a time will come back as a datetime
    assert ctx['t'] == datetime.datetime(1970, 1, 1, 20, 30, 15, 123000)

    ny_tz = pytz.timezone('America/New_York')
    ny_dt = ny_tz.localize(datetime.datetime(2019, 11, 19, 10, 30, 15, 123456))
    ctx['dt_ny'] = ny_dt
    # date to js are ALWAYS in the UTC time zone
    assert ctx.eval('dt_ny.toISOString()') == '2019-11-19T15:30:15.123Z'
    # date to py are naive datetime ALWAYS in the UTC time zone
    assert ctx['dt_ny'] == ny_dt.astimezone(pytz.utc).replace(tzinfo=None)


def test_pushed_datetime_not_proxied():
    ctx = duktape.Context()
    ctx.eval('var foo = {}')
    foo = ctx.proxy('foo')
    now = datetime.datetime.now()
    foo['dt'] = now
    assert isinstance(foo['dt'], datetime.datetime)
    assert foo['dt'] == now


def test_obj_proxy_asobject():
    ctx = duktape.Context()
    ctx.eval('var foo = {a: 1, b: 2, c:3};')

    foo = ctx.proxy('foo').asobject()
    foo['d'] = 4
    assert ctx.eval('foo.d == 4')
    assert foo['d'] == 4
    assert foo.d == 4
    ctx.eval('foo.e = 5')
    assert foo['e'] == 5
    assert foo.e == 5

    with pytest.raises(AttributeError):
        foo.f
    with pytest.raises(AttributeError):
        del foo.f


def test_obj_proxy():
    ctx = duktape.Context()
    ctx.eval('var foo = {a: 1, b: 2, c:3};')

    foo = ctx.proxy('foo')
    assert foo == {'a': 1, 'b': 2, 'c': 3}
    foo['d'] = 4
    assert ctx.eval('foo.d == 4')
    assert foo['d'] == 4
    ctx.eval('foo.e = 5')
    assert foo['e'] == 5
    assert foo == {'a': 1, 'b': 2, 'c': 3, 'd': 4, 'e': 5}

    with pytest.raises(KeyError):
        foo['f']
    with pytest.raises(KeyError):
        del foo['f']
    with pytest.raises(KeyError):
        foo.pop('f')

def test_array_proxy():
    ctx = duktape.Context()
    ctx.eval('var foo = [1,2,3];')

    foo = ctx.proxy('foo')
    assert len(foo) == 3
    foo.append(4)
    assert len(foo) == 4
    assert foo[3] == 4
    ctx.eval('foo.push(5)')
    assert len(foo) == 5
    assert foo[4] == 5

    assert list(foo) == [1, 2, 3, 4, 5]
    assert foo[:] == [1, 2, 3, 4, 5]
    assert foo[3:] == [4, 5]
    assert foo[::2] == [1, 3, 5]

    foo.insert(1, 10)
    assert foo[1] == 10

    del foo[0]
    assert len(foo) == 5

    with pytest.raises(IndexError):
        foo[6]

    assert foo[-1] == 5
    assert foo[-4] == 2


def test_proxy_recursive():
    ctx = duktape.Context()
    ctx.eval('''var foo = {
        a: [1,2,3],
        b: {
            a: {
                a: [1,2,3],
                b: {a: 1, b: 2}
            },
            b: [
                {a: 1, b: 2}
            ]
        }
    };''')

    foo = ctx.proxy('foo').asobject()
    assert len(foo.a) == 3
    foo.a.append(4)
    assert len(foo.a) == 4
    assert ctx.eval('foo.a[foo.a.length - 1] == 4')
    ctx.eval('foo.a.push(5)')
    assert list(foo.a) == [1,2,3,4,5]

    assert list(foo.b['a']['a']) == [1,2,3]
    foo.b['a']['a'].append(4)
    assert list(foo.b['a']['a']) == [1,2,3,4]
    ctx.eval('foo.b.a.a.push(5)')
    assert list(foo.b['a']['a']) == [1,2,3,4,5]

    assert foo.b['a']['b']['a'] == 1
    assert foo.b['a']['b']['b'] == 2
    foo.b['a']['b']['c'] = 3
    assert ctx.eval('foo.b.a.b.c == 3')
    ctx.eval('foo.b.a.b.d = 4')
    assert foo.b['a']['b']['d'] == 4

    assert len(foo['b']['b']) == 1
    assert foo.b['b'][0] == {'a': 1, 'b': 2}
    foo.b['b'][0]['c'] = 3
    assert ctx.eval('foo.b.b[0].c == 3')
    ctx.eval('foo.b.b[0].d = 4')
    assert foo.b['b'][0]['d'] == 4


def test_proxy_non_pojo():
    ctx = duktape.Context()
    ctx.eval("""var Foo = function(x, y) {
        this.x = x;
        this.y = y;
    }""")
    ctx.eval('var foo = new Foo(1, 2)')

    foo = ctx.proxy('foo').asobject()
    assert foo.x == 1
    assert foo.y == 2
    foo.x, foo.y = 10, 20
    assert ctx.eval('foo.x == 10')
    assert ctx.eval('foo.y == 20')


class Foo(object):
    def __init__(self, x, y):
        self.x = x
        self.y = y


class Bar(object):
    def __init__(self, value):
        self.value = value


class FooBar(object): pass


def init_ctx_with_hooks():

    def to_js(obj, helper):
        if isinstance(obj, Foo):
            return helper.new('ns.Foo', obj.x, obj.y)
        elif isinstance(obj, Bar):
            return helper.new('ns.Bar', obj.value)
        elif isinstance(obj, FooBar):
            return helper.new('ns.FooBar')

    def to_py(obj, helper):
        if helper.instanceof('ns.FooBar'):
            raise ValueError('should never pass')
        elif helper.instanceof('ns.Foo'):
            return Foo(**obj)
        elif helper.instanceof('ns.Bar'):
            return Bar(**obj)

    ctx = duktape.Context(to_js_hook=to_js,
                          to_py_hook=to_py)
    ctx.eval("""var ns = {};
    ns.Foo = function(x, y) {
        this.x = x;
        this.y = y;
    }
    ns.Bar = function(value) {
        this.value = value;
    }""")

    return ctx


def test_custom_hooks():
    ctx = init_ctx_with_hooks()

    ctx['foo'] = Foo(Bar(10), Bar(20))

    assert ctx.eval('foo instanceof ns.Foo')
    assert ctx.eval('foo.x instanceof ns.Bar')
    assert ctx.eval('foo.y instanceof ns.Bar')
    assert ctx.eval('foo.x.value == 10')
    assert ctx.eval('foo.y.value == 20')

    foo = ctx['foo']
    assert isinstance(foo, Foo)
    assert isinstance(foo.x, Bar)
    assert isinstance(foo.y, Bar)
    assert foo.x.value == 10
    assert foo.y.value == 20

    with pytest.raises(ValueError) as error:
        ctx['foobar'] = FooBar()
    assert "'ns.FooBar' is undefined" in str(error.value)


def test_custom_hooks_with_proxy():
    # NOTE proxy are not applied to nested objects
    # if they are not POJO(s) (Plain Old Javascript Object(s))
    # ONLY the "first level" object is a proxy (even if it's not a POJO)

    ctx = init_ctx_with_hooks()

    ctx['foo'] = Foo(Bar(10), Bar(20))

    foo = ctx.proxy('foo').asobject()
    assert isinstance(foo.x, Bar)
    assert isinstance(foo.y, Bar)
    assert foo.x.value == 10
    assert foo.y.value == 20

    assert not isinstance(foo, Foo)
    assert isinstance(foo, duktape.JsObject)
    foo.x.value = 100
    assert ctx.eval('foo.x.value == 10')

    ctx.eval('bar = [new ns.Foo(1, 2)]')
    bar = ctx.proxy('bar')
    assert len(bar) == 1
    assert isinstance(bar[0], Foo)
    assert bar[0].x == 1
    assert bar[0].y == 2
    bar[0].x = 10
    assert ctx.eval('bar[0].x == 1')
    f = Foo(3, 4)
    bar.append(f)
    assert len(bar) == 2
    assert ctx.eval('bar.length == 2')
    assert ctx.eval('bar[1] instanceof ns.Foo')
    assert ctx.eval('bar[1].x == 3')
    assert ctx.eval('bar[1].y == 4')
    assert ctx.eval('bar[1].x = 30')
    assert f.x == 3


def test_custom_hooks_for_exceptions():

    class CustomError(Exception):
        def __init__(self, x):
            self.x = x

    def to_js(obj, helper):
        if isinstance(obj, CustomError):
            return helper.new('CustomError', obj.x)

    def to_py(obj, helper):
        if helper.instanceof('CustomError'):
            return CustomError(obj['x'])
        return obj

    ctx = duktape.Context(to_js_hook=to_js,
                          to_py_hook=to_py)
    ctx.eval("""var CustomError = function(x) {
        this.x = x;
    };
    CustomError.prototype = Object.create(Error.prototype);""")

    with pytest.raises(CustomError) as error:
        ctx.eval("throw (new CustomError('foo'))")
    assert error.value.x == 'foo'

    def raise_foo_error(x):
        raise CustomError(x)
    ctx['raise'] = raise_foo_error

    ctx.eval("""try {
        raise('bar');
    } catch (e) {
        if (e instanceof CustomError) {
            foo_err = e.x;
        }
    }""")
    assert ctx['foo_err'] == 'bar'


def test_custom_hooks_args():
    ctx = init_ctx_with_hooks()

    def bar(f):
        return f.x*f.y

    ctx['foo'] = Foo(10, 20)
    ctx['bar'] = bar

    assert ctx.eval('foo instanceof ns.Foo')
    assert ctx.eval('bar(foo) == 200')


def test_thread_only():
    ctx = duktape.Context()

    ctx.eval("""function Foo(x) {
        this.x = x;
    }
    Foo.prototype.bar = function() {
        return this.x;
    }
    var foo = new ThreadOnly(Foo, 'foo')""")

    with pytest.raises(duktape.Error) as error:
        ctx.eval('foo.x')
    assert "foo has not been initialized" in str(error.value)

    th1 = ctx.new_thread(False)
    th1_state = th1.suspend()
    th2 = ctx.new_thread(False)
    th2_state = th2.suspend()

    th1.resume(th1_state)
    with pytest.raises(duktape.Error) as error:
        th1.eval('foo.x')
    assert "foo has not been initialized" in str(error.value)
    th1.init_thread_only('foo', 'bob')
    assert th1.eval('foo.x == "bob"')
    assert th1.eval('foo.bar() == "bob"')
    th1_state = th1.suspend()

    th2.resume(th2_state)
    with pytest.raises(duktape.Error) as error:
        th2.eval('foo.x')
    assert "foo has not been initialized" in str(error.value)
    th2.init_thread_only('foo', 'alice')
    assert th2.eval('foo.x == "alice"')
    assert th2.eval('foo.bar() == "alice"')
    th2_state = th2.suspend()

    th1.resume(th1_state)
    th1.eval('foo.x = 10')
    assert th1.eval('foo.x = 10')
    assert th1.eval('foo.bar() == 10')
    th1_state = th1.suspend()

    th2.resume(th2_state)
    assert th2.eval('foo.x == "alice"')
    th2.eval('foo.x = 20')
    th2_state = th2.suspend()

    th1.resume(th1_state)
    assert th1.eval('foo.x = 10')
    th1_state = th1.suspend()

    th2.resume(th2_state)
    assert th2.eval('foo.x = 20')
    assert th2.eval('foo.bar() == 20')
    th2_state = th2.suspend()


def test_python_exc_cleared():
    ctx = duktape.Context()

    def test(s):
        raise ValueError(s)
    ctx['test'] = test

    try:
        ctx.eval("test('1')");
    except Exception:
        pass

    assert sys.exc_info() == (None, None, None)

    try:
        ctx.eval("test('2')")
    except Exception:
        pass

    assert sys.exc_info() == (None, None, None)


class MyError(Exception): pass


def test_python_error():
    ctx = duktape.Context()

    def trigger_value_error(msg):
        raise ValueError(msg)
    ctx['trigger_value_error'] = trigger_value_error

    def trigger_my_error(msg):
        raise MyError(msg)
    ctx['trigger_my_error'] = trigger_my_error

    ctx.eval("""try {
        trigger_value_error("test");
    } catch (e) {
        if (!(e instanceof PythonError)) {
            throw "not a PythonError";
        }
        if (e.name !== "PythonError(ValueError)") {
            throw "name is not PythonError(ValueError) => " + e.name;
        }
        if (e.pyName !== "ValueError") {
            throw "pyName is not ValueError => " + e.pyName;
        }
        if (e.message !== "test") {
            throw "message is different => " + e.message;
        }
    }""")

    with pytest.raises(ValueError) as error:
        ctx.eval('trigger_value_error("test")')
    err_repr = str(error.getrepr())
    assert "PythonError(ValueError)" in err_repr, err_repr
    assert error.value.args == ('test', )

    ctx.eval("""try {
        trigger_my_error("test");
    } catch (e) {
        if (!(e instanceof PythonError)) {
            throw "not a PythonError";
        }
        if (e.name !== "PythonError(test.test_duktape.MyError)") {
            throw "name is not PythonError(test.test_duktape.MyError) => " + e.name;
        }
        if (e.pyName !== "test.test_duktape.MyError") {
            throw "e.name is not MyError => " + e.pyName;
        }
        if (e.message !== "test") {
            throw "e.message is wrong => " + e.message;
        }
    }""")

    with pytest.raises(MyError) as error:
        ctx.eval('trigger_my_error("test")')
    err_repr = str(error.getrepr())
    assert "PythonError(test.test_duktape.MyError)" in err_repr, err_repr
    assert error.value.args == ('test', )


def test_push_js_proxy():
    ctx = duktape.Context()
    ctx.eval('foo = {a: 1}')
    foo = ctx.proxy('foo')
    ctx['bar'] = foo
    ctx.eval('bar.b = 2')
    assert foo['b'] == 2
    assert ctx.eval('foo.b === 2')
    assert ctx.eval('bar.b === 2')
