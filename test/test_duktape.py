import os
import datetime
import gc
import random
import tempfile
import threading
import time

import duktape
import pytest
import pytz

# todo: unicode tests everywhere and strings with nulls (i.e. I'm relying on null termination)


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

    codes = map(push, [
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
    ])
    expected = [str, float, float, bool, bool, type(None), object, object, object, object]
    assert [code.as_pytype() for code in codes] == expected


def test_push_get():
    ctx = duktape.Context()
    for v in ["foo", u"foo", 123.0, 123, 123.5, True, False, [1, 2, 3], [[1]], {"a": 1, "b": 2}]:
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


def test_load_file_with_syntax_error():
    ctx = duktape.Context()
    with tempfile.NamedTemporaryFile() as tf:
        tf.write(b"var a = 10;\n"
                 b"foo=")
        tf.flush()

        try:
            ctx.load(tf.name)
        except duktape.Error, e:
            # error contains filename and line number
            assert '%s:2' % tf.name in unicode(e), e


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

    assert ctx['charCodeAt'](u'\xe0', 0) == 224
    assert ctx['codePointAt'](u'\xe0', 0) == 224

    smile_emoji = u'\U0001f600'
    assert ctx['charCodeAt'](smile_emoji, 0) == 55357
    assert ctx['charCodeAt'](smile_emoji, 1) == 56832
    assert ctx['codePointAt'](smile_emoji, 0) == 128512


def test_thread_basic():
    ctx = duktape.Context()
    ctx['foo'] = 10

    th = ctx.new_thread(False)
    assert th['foo'] is 10
    th['bar'] = 20
    assert th['bar'] == 20
    assert ctx['bar'] == 20


def test_thread_new_globalenv():
    ctx = duktape.Context()
    ctx['foo'] = 10

    th = ctx.new_thread(True)
    assert th['foo'] is None
    th['bar'] = 20
    assert th['bar'] == 20
    assert ctx['bar'] is None


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
            print s
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
    assert ctx['dt'] == datetime.datetime(2019, 11, 19, 20, 30, 15, 123000, tzinfo=pytz.utc)
    ctx.eval('dt.toISOString()') == u'2019-11-19T20:30:15.123Z'

    ctx['d'] = datetime.date(2019, 11, 19)
    assert ctx['d'] == datetime.datetime(2019, 11, 19, tzinfo=pytz.utc)
    ctx.eval('dt.toISOString()') == u'2019-11-19T00:00:00.000Z'

    ctx['t'] = datetime.time(20, 30, 15, 123456)
    assert ctx['t'] == datetime.datetime(1970, 1, 1, 20, 30, 15, 123000, tzinfo=pytz.utc)
    ctx.eval('dt.toISOString()') == u'1970-01-01T20:30:15.123Z'

    new_york_tz = pytz.timezone('America/New_York')
    ctx['dt_ny'] = new_york_tz.localize(datetime.datetime(2019, 11, 19, 10, 30, 15, 123456))
    assert ctx['dt_ny'] == datetime.datetime(2019, 11, 19, 15, 30, 15, 123000, tzinfo=pytz.utc)
    ctx.eval('dt_ny.toISOString()') == u'2019-11-19T15:30:15.123Z'
