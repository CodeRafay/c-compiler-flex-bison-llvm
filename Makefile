CC = g++
LEX = flex
YACC = bison
LLVM_CONFIG = llvm-config

CFLAGS = -g -Wall -Wno-unused-function -Wno-unused-variable `$(LLVM_CONFIG) --cxxflags`

LDFLAGS = `$(LLVM_CONFIG) --ldflags --libs core analysis native scalaropts`

.PHONY: all clean test

all: compiler

compiler: lex.yy.c parser.tab.c symbol_table.o llvm_ir.o
	$(CC) $(CFLAGS) -o compiler lex.yy.c parser.tab.c symbol_table.o llvm_ir.o $(LDFLAGS)

lex.yy.c: lexical.l parser.tab.h
	$(LEX) lexical.l

parser.tab.c parser.tab.h: parser.y
	$(YACC) -d parser.y

symbol_table.o: symbol_table.c symbol_table.h
	$(CC) $(CFLAGS) -c symbol_table.c

llvm_ir.o: llvm_ir.c llvm_ir.h
	$(CC) $(CFLAGS) -c llvm_ir.c

# Build, then run every test in tests/ (see tests/run_tests.sh)
test: compiler
	./tests/run_tests.sh

clean:
	rm -f compiler lexer lex.yy.c parser.tab.c parser.tab.h parser.output *.o output.ll output.bc