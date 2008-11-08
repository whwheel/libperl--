CXX = g++
ACK = ack-grep
PERL = perl
#WARNINGS = -Wall -Weffc++ -Wshadow -Wno-non-virtual-dtor
WARNINGS = -Wall -Wshadow
PERLCXX := $(shell $(PERL) -MExtUtils::Embed -e ccopts)
DEBUG = -ggdb3 -DDEBUG
DFLAGS = -fPIC $(PERLCXX) 
CXXFLAGS = $(DEBUG) $(WARNINGS) $(DFLAGS)
ACXXFLAGS = $(DEBUG) $(WARNINGS)
#CXXFLAGS = -Os -fomit-frame-pointer $(DFLAGS)
LDFLAGS = -L. -lperl++
LIBLDFLAGS := $(shell $(PERL) -MExtUtils::Embed -e ldopts)
PWD := $(shell pwd)
LIBRARY_VAR=LD_LIBRARY_PATH

LIB = libperl++.so

HDRS := $(wildcard *.h)
SRCS := array.C call.C evaluate.C exporter.C glob.C hash.C handle.C helpers.C interpreter.C primitives.C reference.C regex.C scalar.C tap++.C
OBJS := $(patsubst %.C,%.o,$(SRCS))

TODEL := $(wildcard *.o) $(wildcard t/*.t)

TEST_SRCS := $(wildcard t/*.C)
TEST_OBJS := $(patsubst %.C,%.t,$(TEST_SRCS))
TEST_GOALS = $(TEST_OBJS)

all: $(LIB) example

ppport.h:
	perl -MDevel::PPPort -eDevel::PPPort::WriteFile

#$(LIB): $(OBJS)
#	ar -cr $(LIB) $(OBJS)
#	ranlib $(LIB)

$(LIB): definitions.h $(OBJS)
	gcc -shared -o $@ -Wl,-soname,$@ $(OBJS) $(LIBLDFLAGS)

%.o: %.C 
	$(CXX) $(CXXFLAGS) -c $< 

%.C: %.h

%.t: %.C
	$(CXX) $(ACXXFLAGS) -I $(PWD) -L $(PWD) -lperl++ -o $@ $< 

evaluate.C: evaluate.pl
	perl $< > $@

config.h: config.pre
	cpp $(PERLCXX) $< > $@

example: example.C
	$(CXX) -o $@ $(ACXXFLAGS) $< $(LDFLAGS)

testbuild: $(LIB) $(TEST_GOALS)

test: testbuild
	@echo run_tests.pl $(TEST_GOALS)
	@$(LIBRARY_VAR)=$(PWD) ./run_tests.pl $(TEST_GOALS)

prove: testbuild
	@echo prove $(TEST_GOALS)
	@$(LIBRARY_VAR)=$(PWD) prove -e"sh -c" $(TEST_GOALS)

#%.o: perl++.h

clean:
	-rm $(LIB) tap_tester example ppport.h config.C definitions.h $(TODEL) 2>/dev/null

testclean:
	-rm $(TEST_OBJS) 2>/dev/null

again: clean all

love:
	@echo Not war?

lines:
	@wc -l `ls *.[Ch] | grep -v ppport.h` | sort -gr
linesh:
	@wc -l `ls *.h | grep -v ppport.h` | sort -gr
linesC:
	@wc -l *.C | sort -gr

install: $(LIB)
	cp -a libperl++.so /usr/local/lib/

.PHONY: wordsC wordsh words lines linesh linesC todo install test prove testbuild

words: 
	@make -s wordsC wordsh | sort -gr | column -t

wordsC:
	@(for i in *.C; do cpp -fpreprocessed $$i | sed 's/[_a-zA-Z0-9][_a-zA-Z0-9]*/x/g' | tr -d ' \012' | wc -c | tr "\n" " " ; echo $$i; done) | sort -gr | column -t;
wordsh:
	@(for i in `ls *.h | grep -v ppport.h`; do cat $$i | sed 's/[_a-zA-Z0-9][_a-zA-Z0-9]*/x/g' | tr -d ' \012' | wc -c | tr "\n" " " ; echo $$i; done) | sort -gr | column -t;

todo:
	@for i in FIX''ME XX''X TO''DO; do echo -n "$$i: "; $(ACK) $$i | wc -l; done;

apicount: libperl++.so
	@echo -n "Number of entries: "
	@nm libperl++.so -C --defined-only | egrep -i " [TW] perl::" | wc -l
