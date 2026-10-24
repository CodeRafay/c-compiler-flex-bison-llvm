#ifndef SYMBOL_TABLE_H
#define SYMBOL_TABLE_H

#include <llvm/IR/Value.h>
#include <llvm/IR/Function.h>
#include <string>

enum SymbolType {
    TYPE_INT,
    TYPE_FLOAT,
    TYPE_BOOL,
    TYPE_VOID
};

enum SymbolKind {
    VAR,
    FUNC
};

struct Param {
    char* name;
    SymbolType type;
    llvm::Value* value;
    struct Param* next;
};

struct Symbol {
    char* name;
    SymbolType type;
    SymbolKind kind;
    int scope;
    int defined; // For functions: 1 if defined, 0 if declared
    llvm::Value* value; // For variables
    llvm::Function* function; // For functions
    struct Param* params; // For function parameters
    struct Symbol* next;
};

void initSymbolTable();
Symbol* lookup(const char* name);
Symbol* lookupFunction(const char* name);
void insertVariable(const char* name, SymbolType type, int scope, llvm::Value* value);
void insertFunction(const char* name, SymbolType returnType, Param* params, int isDefinition, llvm::Function* function);
void exitScope(int scope);
int checkFunctionCallArgs(const char* funcName, Param* passedArgs);
void printSymbolTable();
void freeSymbolTable();

#endif