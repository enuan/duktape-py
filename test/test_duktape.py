import gc
import tempfile

import duktape
import pytest

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
