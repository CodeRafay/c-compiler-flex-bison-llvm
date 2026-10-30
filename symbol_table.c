#include "symbol_table.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Symbol* symbolTable = NULL;

void initSymbolTable() {
    symbolTable = NULL;
}

Symbol* lookup(const char* name) {
    Symbol* current = symbolTable;
    while (current != NULL) {
        if (strcmp(current->name, name) == 0 && current->kind == VAR) {
            return current;
        }
        current = current->next;
    }
    return NULL;
}

Symbol* lookupFunction(const char* name) {
    Symbol* current = symbolTable;
    while (current != NULL) {
        if (strcmp(current->name, name) == 0 && current->kind == FUNC) {
            return current;
        }
        current = current->next;
    }
    return NULL;
}

// Returns 1 if inserted, 0 if the name is already declared in this scope
// (the caller reports the error, since it knows the line number).
int insertVariable(const char* name, SymbolType type, int scope, llvm::Value* value, int arraySize) {
    Symbol* current = symbolTable;
    while (current != NULL) {
        if (strcmp(current->name, name) == 0 && current->scope == scope && current->kind == VAR) {
            return 0;
        }
        current = current->next;
    }
    Symbol* sym = (Symbol*)malloc(sizeof(Symbol));
    sym->name = strdup(name);
    sym->type = type;
    sym->kind = VAR;
    sym->scope = scope;
    sym->value = value;
    sym->arraySize = arraySize;
    sym->function = NULL;
    sym->params = NULL;
    sym->next = symbolTable;
    symbolTable = sym;
    return 1;
}

void insertFunction(const char* name, SymbolType returnType, Param* params, int isDefinition, llvm::Function* function) {
    Symbol* current = symbolTable;
    while (current != NULL) {
        if (strcmp(current->name, name) == 0 && current->kind == FUNC && current->defined) {
            fprintf(stderr, "Error: Function '%s' already defined\n", name);
            return;
        }
        current = current->next;
    }
    Symbol* sym = (Symbol*)malloc(sizeof(Symbol));
    sym->name = strdup(name);
    sym->type = returnType;
    sym->kind = FUNC;
    sym->scope = 0; // Functions are global
    sym->defined = isDefinition;
    sym->value = NULL;
    sym->arraySize = 0;
    sym->function = function;
    sym->params = params;
    sym->next = symbolTable;
    symbolTable = sym;
}

// Called when a block or function ends: every variable declared at this
// scope level (or deeper) is no longer visible, so remove it. Functions are
// global (scope 0) and are never removed.
void exitScope(int scope) {
    Symbol* prev = NULL;
    Symbol* current = symbolTable;
    while (current != NULL) {
        Symbol* next = current->next;
        if (current->kind == VAR && current->scope >= scope) {
            // Unlink it from the list, then free it
            if (prev != NULL) {
                prev->next = next;
            } else {
                symbolTable = next;
            }
            free(current->name);
            free(current);
        } else {
            prev = current;
        }
        current = next;
    }
}

int checkFunctionCallArgs(const char* funcName, Param* passedArgs) {
    Symbol* func = lookupFunction(funcName);
    if (!func) {
        fprintf(stderr, "Error: Function '%s' not declared\n", funcName);
        return 0;
    }
    Param* expected = func->params;
    Param* actual = passedArgs;
    while (expected && actual) {
        if (expected->type != actual->type) {
            fprintf(stderr, "Error: Type mismatch in arguments for function '%s'\n", funcName);
            return 0;
        }
        expected = expected->next;
        actual = actual->next;
    }
    if (expected || actual) {
        fprintf(stderr, "Error: Incorrect number of arguments for function '%s'\n", funcName);
        return 0;
    }
    return 1;
}

void printSymbolTable() {
    Symbol* current = symbolTable;
    printf("\nSymbol Table:\n");
    while (current != NULL) {
        printf("Name: %s, Type: %d, Kind: %s, Scope: %d\n",
               current->name,
               current->type,
               current->kind == VAR ? "VAR" : "FUNC",
               current->scope);
        current = current->next;
    }
}

void freeSymbolTable() {
    Symbol* current = symbolTable;
    while (current != NULL) {
        Symbol* temp = current;
        current = current->next;
        Param* param = temp->params;
        while (param != NULL) {
            Param* ptemp = param;
            param = param->next;
            free(ptemp->name);
            free(ptemp);
        }
        free(temp->name);
        free(temp);
    }
    symbolTable = NULL;
}