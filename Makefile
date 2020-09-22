duktape.c: duktape.pyx cduk.pxd
	cython duktape.pyx

build: duktape.c
	python setup.py build_ext --inplace

test: build
	py.test -xv test/

clean:
	rm -rf build/ duktape*.so *.egg-info .cache

configure:
	@echo "Configuring release $${duktape:?pass the Duktape release to configure using \"make configure duktape=/PATH/TO/duktape-2.x.x\"}"
	rm -rf duktape_c/
	python2 $(duktape)/tools/configure.py --source-directory=$(duktape)/src-input/ --output-directory duktape_c/ --option-file=duktape_options.yaml
	cp $(duktape)/extras/module-node/duk_module_node.* duktape_c/

index:
	git checkout-index --prefix=index-checkout/ --force --all
	$(MAKE) -C index-checkout -B build
	$(MAKE) -C index-checkout test
	mv duktape.c duktape.c.tmp
	mv index-checkout/duktape.c duktape.c
	git add duktape.c
	mv duktape.c.tmp duktape.c
	rm -rf index-checkout

.PHONY: build clean configure index
